import Foundation
import CryptoKit

/// A key held in its own allocation: overwritten with random bytes and then zeros on `wipe()` (idempotent) and when the object is
/// released. A reader gets the bytes only inside `withBytes`; after the wipe there is nothing to read. Copies that a caller makes
/// of the bytes (a `Data` value, a CryptoKit key) are outside this object.
public final class ChainKeyBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: UnsafeMutableRawPointer?
    public let count: Int

    public init(copying data: Data) {
        let n = data.count
        count = n
        let p = UnsafeMutableRawPointer.allocate(byteCount: max(n, 1), alignment: 1)
        data.withUnsafeBytes { raw in
            if n > 0, let base = raw.baseAddress { p.copyMemory(from: base, byteCount: n) }
        }
        storage = p
    }

    deinit {
        wipe()
    }

    /// The bytes, or nil after the wipe.
    public func withBytes<R>(_ body: (UnsafeRawBufferPointer) -> R) -> R? {
        lock.lock()
        defer { lock.unlock() }
        guard let p = storage else { return nil }
        return body(UnsafeRawBufferPointer(start: p, count: count))
    }

    /// A copy of the bytes as `Data` (the copy is the caller's to wipe), or nil after the wipe.
    func copyData() -> Data? {
        withBytes { Data($0) }
    }

    /// A second buffer with the same bytes (its own allocation), or nil after the wipe. No `Data` copy is made.
    func duplicate() -> ChainKeyBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard let p = storage else { return nil }
        return ChainKeyBuffer(duplicatingBytesOf: p, count: count)
    }

    private init(duplicatingBytesOf source: UnsafeMutableRawPointer, count n: Int) {
        count = n
        let p = UnsafeMutableRawPointer.allocate(byteCount: max(n, 1), alignment: 1)
        if n > 0 { p.copyMemory(from: UnsafeRawPointer(source), byteCount: n) }
        storage = p
    }

    public var isWipedForTesting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage == nil
    }

    public func wipe() {
        lock.lock()
        defer { lock.unlock() }
        guard let p = storage else { return }
        var generator = SystemRandomNumberGenerator()
        for offset in 0 ..< count {
            p.storeBytes(of: UInt8.random(in: 0 ... 255, using: &generator), toByteOffset: offset, as: UInt8.self)
        }
        p.initializeMemory(as: UInt8.self, repeating: 0, count: max(count, 1))
        p.deallocate()
        storage = nil
    }
}

/// Chained rekeys: the pure derivations and the decision on the `chainBase` member of a rekey OFFER.
public enum RekeyChain {

    /// Largest epoch: `rekeyRound <= 2^31 - 1`, `E = rekeyRound - 1`.
    public static let maxEpoch: Int32 = Int32.max - 1

    /// Maps only the bytes 0x41 ... 0x5A to 0x61 ... 0x7A. Never `lowercased()`: any other byte stays as it is.
    public static func asciiLower(_ text: String) -> String {
        var bytes = Array(text.utf8)
        for index in 0 ..< bytes.count where bytes[index] >= 0x41 && bytes[index] <= 0x5A {
            bytes[index] += 0x20
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func lp16(_ bytes: [UInt8]) -> Data {
        var out = Data([UInt8((bytes.count >> 8) & 0xFF), UInt8(bytes.count & 0xFF)])
        out.append(contentsOf: bytes)
        return out
    }

    private static func be32(_ value: UInt32) -> Data {
        Data([UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    /// `ck_E = HKDF-Expand(PRK = sessionKey_E, info = label || LP16(callIdL) || BE32(E), L = 32)`. Expand only, no extract.
    /// nil for a session key that is not 32 bytes, an empty id, or an epoch outside `0 ... maxEpoch`.
    public static func deriveChainKey(sessionKey: Data, callIdL: String, epoch: Int32) -> Data? {
        let id = Array(callIdL.utf8)
        guard sessionKey.count == 32, !id.isEmpty, id.count <= 0xFFFF, epoch >= 0, epoch <= maxEpoch else { return nil }
        var info = HkdfLabels.rekeyChainKeyV1
        info.append(lp16(id))
        info.append(be32(UInt32(epoch)))
        let okm = HKDF<SHA256>.expand(pseudoRandomKey: SymmetricKey(data: sessionKey), info: info, outputByteCount: 32)
        return okm.withUnsafeBytes { Data($0) }
    }

    /// The HKDF salt of the session key: the PSK when there is one, else the hybrid salt. One rule for the chained and the
    /// unchained derivation.
    static func sessionKeySalt(psk: Data?) -> Data {
        if let psk = psk, !psk.isEmpty { return psk }
        return HkdfLabels.hybridPqcSaltV1
    }

    /// `sessionKey_E = HKDF-SHA256(IKM = pqcSS || x25519SS || ck_B, salt, info = label || BE32(B) || acceptHash, L = 32)`.
    /// nil when any input has the wrong size, or when the chain key was wiped.
    public static func deriveSessionKeyChained(
        pqcSharedSecret: Data, x25519Shared: Data, ckB: ChainKeyBuffer, base: Int32, psk: Data?, acceptHash: Data
    ) -> Data? {
        guard pqcSharedSecret.count == 32, x25519Shared.count == 32, ckB.count == 32, acceptHash.count == 32,
              base >= 0, base <= maxEpoch else { return nil }
        guard let ck = ckB.copyData() else { return nil }
        var ikm = Data(capacity: 96)
        ikm.append(pqcSharedSecret)
        ikm.append(x25519Shared)
        ikm.append(ck)
        var info = HkdfLabels.sessionKeyChainedV1
        info.append(be32(UInt32(base)))
        info.append(acceptHash)
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: sessionKeySalt(psk: psk),
            info: info,
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }

    // MARK: - The chainBase member

    /// Why a chained rekey OFFER is refused. The raw values are the numbers of the log line.
    public enum Refusal: Int, Equatable, Sendable {
        case missing = 1
        case malformed = 2
        case duplicate = 3
        case notBelow = 4
        case noCk = 5
        case noRecord = 6
    }

    public enum Decision: Equatable, Sendable {
        case accept(base: Int32)
        case refuse(Refusal)
        /// The member is not read: a round-1 OFFER, an ACCEPT, or a call that did not negotiate the tag.
        case ignored
    }

    /// Reads `chainBase` from the validated member list of the OFFER (`StrictBundleJSON`), never from a typed decode.
    /// Exactly one member whose unescaped name is `chainBase`; its raw token must be `0|[1-9][0-9]*` with at most ten digits;
    /// `0 <= B < E <= maxEpoch`; this side has a chain record of the call and holds `ck_B`. `applies` is false for a round-1
    /// OFFER, an ACCEPT and a call without the tag: then the member is ignored whatever it holds.
    public static func decideChainBase(
        members: [StrictBundleJSON.Member], epoch: Int32, hasRecord: Bool, holdsCk: (Int32) -> Bool, applies: Bool
    ) -> Decision {
        decideChainBase(tokens: chainBaseTokens(of: members), epoch: epoch, hasRecord: hasRecord, holdsCk: holdsCk, applies: applies)
    }

    /// The raw tokens of the members named `chainBase` (names compared after unescaping), in document order.
    public static func chainBaseTokens(of members: [StrictBundleJSON.Member]) -> [[UInt8]] {
        let name = Array("chainBase".utf16)
        return members.filter { !$0.badName && $0.nameUnits == name }.map { Array($0.valueBytes) }
    }

    public static func decideChainBase(
        tokens: [[UInt8]], epoch: Int32, hasRecord: Bool, holdsCk: (Int32) -> Bool, applies: Bool
    ) -> Decision {
        guard applies else { return .ignored }
        if tokens.isEmpty { return .refuse(.missing) }
        if tokens.count > 1 { return .refuse(.duplicate) }
        let token = tokens[0]
        guard !token.isEmpty, token.count <= 10, token.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              !(token.count > 1 && token[0] == 0x30) else { return .refuse(.malformed) }
        var value: Int64 = 0
        for digit in token { value = value * 10 + Int64(digit - 0x30) }
        guard epoch >= 1, epoch <= maxEpoch, value < Int64(epoch) else { return .refuse(.notBelow) }
        guard hasRecord else { return .refuse(.noRecord) }
        let base = Int32(value)
        guard holdsCk(base) else { return .refuse(.noCk) }
        return .accept(base: base)
    }
}

/// Only the caller rekeys (D11): a rekey OFFER that arrives at the caller of a call that negotiated chained rekeys, with a round
/// above 1 and the exact id of the call, is dropped silently.
public enum RekeyOffererRule {
    public static func dropsCalleeRekeyOffer(liveIsChainedOfferer: Bool, exactIdMatches: Bool, round: Int?) -> Bool {
        guard liveIsChainedOfferer, exactIdMatches, let round = round else { return false }
        return round != 1
    }
}
