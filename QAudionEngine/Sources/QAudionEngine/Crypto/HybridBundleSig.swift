import Foundation
import CryptoKit

/// The second signature of a handshake bundle: `sigEd[64] || sigPq[4627]` over HT (`Pqsig.encodeHT`), sent in every OFFER and
/// ACCEPT of a build that advertises the tag. The byte layout is that of `Pqsig`; this file only decides what goes into HT for a
/// bundle and how a received one is checked.

/// Signs the bundles of this device. Holds the second private key (derived from the identity seed) only while the object lives.
///
/// Signing needs a large stack (about 108 KB): call it from a Task or a dispatch queue, never from a small custom thread.
public final class HybridBundleSigner: @unchecked Sendable {
    private let edSeed: Data
    private let edPub: Data
    private let key: Pqsig.MlDsaPrivateKey
    /// SHA-256 of this device's second public key.
    public let keyId: Data

    /// Nil when `edSeed` is not the seed of `edPub` or the key cannot be derived.
    public init?(edSeed: Data, edPub: Data) {
        guard let derived = Pqsig.keyFromIdentity(edSeed: edSeed, edPub: edPub, gen: 0) else { return nil }
        self.edSeed = edSeed
        self.edPub = edPub
        self.key = derived
        self.keyId = derived.publicKey.keyId()
    }

    /// The 4691-byte signature of the bundle whose OFFER_v6 / ACCEPT_v6 bytes are `transcript`, or nil on any failure.
    /// `capsx` and `extx` are those of THIS bundle as it will be sent. `dtlsFpPeer` is the offerer's fingerprint for an ACCEPT
    /// and ignored for an OFFER.
    func sign(kind: UInt8, transcript: Data, dtlsFpSelf: Data, dtlsFpPeer: Data?, capsx: Data, extx: Data) -> Data? {
        let fields = Pqsig.HtFields(
            kind: kind, bundleHash: Data(SHA256.hash(data: transcript)), edPub: edPub, mldsaKeyId: keyId,
            dtlsFpSelf: dtlsFpSelf, dtlsFpPeer: kind == Pqsig.kindOffer ? Data() : (dtlsFpPeer ?? Data()),
            capsx: capsx, extx: extx)
        guard let ht = Pqsig.encodeHT(fields),
              let sig = Pqsig.signHybrid(ht, edSeed: edSeed, pq: key),
              sig.count == Pqsig.hybridSigSize else { return nil }
        return sig
    }
}

/// Checks a received bundle's second signature (design section 5.5, steps 1 to 3). Never throws.
public enum HybridBundleVerifier {

    public struct Outcome: Equatable, Sendable {
        public let result: PqSigResult
        /// Lowercase hex of the key id the check ran under: set for `valid` and `invalid` when the claim decoded and a key was
        /// found, else nil.
        public let keyId: String?
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// - Parameters:
    ///   - signerEdPub: the Ed25519 key that verified this bundle's `sigV6` (never a self-asserted key).
    ///   - peer: the CAPSX / EXTX analysis of the bundle exactly as received.
    ///   - resolveKey: the second public key of that device whose certificate verified against `signerEdPub`, the peer uuid and
    ///     the sending device, for the key id named by the bundle; nil if there is none.
    static func verify(
        kind: UInt8, transcript: Data, signerEdPub: Data, dtlsFpSelf: Data, dtlsFpPeer: Data?, peer: BundleCapsBind,
        mldsaKeyIdB64: String?, sigHybridB64: String?,
        resolveKey: (_ keyId: Data) async -> Pqsig.MlDsaPublicKey?
    ) async -> Outcome {
        guard let sigText = sigHybridB64 else { return Outcome(result: .absent, keyId: nil) }
        guard let sig = SasCommit.decodeCanonicalBase64(sigText, expectedLength: Pqsig.hybridSigSize),
              let claimedText = mldsaKeyIdB64,
              let claimed = SasCommit.decodeCanonicalBase64(claimedText, expectedLength: Pqsig.keyIdSize)
        else { return Outcome(result: .invalid, keyId: nil) }
        guard let key = await resolveKey(claimed) else { return Outcome(result: .unavailable, keyId: nil) }
        // The resolver must hand back the key the bundle names; anything else is no key at all.
        guard key.keyId() == claimed else { return Outcome(result: .unavailable, keyId: nil) }
        let claimedHex = hex(claimed)
        let fields = Pqsig.HtFields(
            kind: kind, bundleHash: Data(SHA256.hash(data: transcript)), edPub: signerEdPub, mldsaKeyId: claimed,
            dtlsFpSelf: dtlsFpSelf, dtlsFpPeer: kind == Pqsig.kindOffer ? Data() : (dtlsFpPeer ?? Data()),
            capsx: peer.capsx, extx: peer.extx)
        guard let ht = Pqsig.encodeHT(fields) else { return Outcome(result: .invalid, keyId: claimedHex) }
        let ok = Pqsig.verifyHybrid(ht, sig, edPub: signerEdPub, pq: key)
        return Outcome(result: ok ? .valid : .invalid, keyId: claimedHex)
    }
}
