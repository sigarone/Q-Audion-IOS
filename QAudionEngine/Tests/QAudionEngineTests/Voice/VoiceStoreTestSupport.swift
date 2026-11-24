import XCTest
import Foundation
import CryptoKit
@testable import QAudionEngine

/// The key vault of the tests: the key lives in memory, and a test can make the vault fail the way a locked keychain does.
final class VoiceMemoryVault: VoiceKeyVault {
    private let lock = NSLock()
    private var key: [UInt8]?
    private(set) var addCount = 0
    private(set) var removeCount = 0
    private(set) var readCount = 0
    /// While set, every read fails with the error of a keychain that is not available.
    var unavailable = false
    /// The number of reads that answer "no key" before the real answer (a read that comes back empty for a moment).
    var emptyReads = 0

    init(key: [UInt8]? = nil) { self.key = key }

    var current: [UInt8]? { lock.withLock { key } }

    func read() throws -> [UInt8]? {
        try lock.withLock {
            readCount += 1
            if unavailable { throw VoiceStoreError(.key, "keychain not available") }
            if emptyReads > 0 {
                emptyReads -= 1
                return nil
            }
            return key
        }
    }

    func add(_ key: [UInt8]) throws {
        try lock.withLock {
            if unavailable { throw VoiceStoreError(.key, "keychain not available") }
            self.key = key
            addCount += 1
        }
    }

    func remove() throws {
        try lock.withLock {
            if unavailable { throw VoiceStoreError(.key, "keychain not available") }
            key = nil
            removeCount += 1
        }
    }

    /// A different key in place of the stored one.
    func replaceKey() {
        lock.withLock { key = SymmetricKey(size: .bits256).withUnsafeBytes { [UInt8]($0) } }
    }
}

/// An AEAD that fails to open the way a platform key store does when it has a transient fault: always `.key`, never `.auth`.
final class VoiceFaultyAead: VoiceAead {
    let inner: VoiceAead
    var failOpen = false
    private(set) var deleteKeyCalls = 0

    init(_ inner: VoiceAead) { self.inner = inner }

    func seal(_ plaintext: [UInt8], aad: [UInt8]) throws -> [UInt8] { try inner.seal(plaintext, aad: aad) }

    func open(_ sealed: [UInt8], aad: [UInt8]) throws -> [UInt8] {
        if failOpen { throw VoiceStoreError(.key, "keystore fault") }
        return try inner.open(sealed, aad: aad)
    }

    func deleteKey() throws {
        deleteKeyCalls += 1
        try inner.deleteKey()
    }
}

enum VoiceStoreFixtures {
    static func axis(_ i: Int) -> [Float] {
        var v = [Float](repeating: 0, count: 512)
        v[i] = 1
        return v
    }

    static func keyBytes(_ key: SymmetricKey) -> [UInt8] {
        key.withUnsafeBytes { [UInt8]($0) }
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-store-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func record(_ cfg: VoiceStateConstants, state: Int = TemplateState.enrolled, last: Int = 1_790_000_000) -> TemplateRecord {
        let r = TemplateRecord(state: state, modelId: cfg.modelId, constantsVersion: cfg.constantsVersion,
                               frontendVersion: cfg.frontendVersion)
        r.lastVerifiedCallS = last
        r.updatedS = last
        r.anchor = axis(3)
        r.adaptive = axis(3)
        r.sessions.append(TemplateSession(speechMs: 40_000, dayIndex: 20717, startS: last - 900, endS: last, deviceTag: 7,
                                          routeClass: 1, inConsensus: true, nWindows: 20, centroid: nil))
        return r
    }
}
