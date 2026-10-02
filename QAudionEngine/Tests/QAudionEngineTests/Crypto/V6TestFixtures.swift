import Foundation
import CryptoKit
@testable import QAudionEngine

/// Shared builders for the transcript-v6 tests. Every value is synthetic (no real ids, hosts or
/// keys): fingerprints are SHA-256 of fixed ASCII labels, keys come from fixed seeds.
enum V6TestFixtures {

    static let callId = "11111111-2222-3333-4444-555555555555"
    static let rekeyNonce = Data((0..<8).map { UInt8($0 &+ 1) })

    /// A synthetic 32-byte SAS commitment (round-1 OFFER field).
    static let sasCommit = Data(repeating: 0xC1, count: 32)

    static let allCaps = HandshakeTranscript.Caps9(
        ratchetV3: true, sframeV1: true, vkeyV1: true, sessionKdfV3: true, ratchetV4: true,
        srtpDirKeyV1: true, pskMixV1: true, hsTranscriptBindV1: true, ratchetV5: true)

    /// A well-formed binary DTLS fingerprint (`0x01 || SHA-256(label)`).
    static func fingerprint(_ label: String) -> Data {
        DtlsFingerprint.fromDer(Data(label.utf8))
    }

    static func fingerprintText(_ label: String) -> String {
        DtlsFingerprint.canonicalText(fingerprint(label))!
    }

    static func signer(seed: UInt8) -> (priv: Curve25519.Signing.PrivateKey, pubRaw: Data) {
        let priv = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: seed, count: 32))
        return (priv, priv.publicKey.rawRepresentation)
    }

    /// A valid OFFER_v6 for `signerKey` (offerer fingerprint label "offerer"). Round 1 carries the
    /// synthetic commitment, any other round none.
    static func offerTranscript(signerKey: Data, dtls: Data = fingerprint("offerer"), round: UInt32 = 1) -> Data {
        HandshakeTranscript.offer(
            callId: callId, signerIdentityKey: signerKey,
            epochId: HandshakeSigningPolicy.placeholderEpochId,
            pqcPublicKey: Data(repeating: 0xA1, count: 1568),
            x25519PublicKey: Data(repeating: 0xA2, count: 32),
            strongBoxPublicKey: nil, dualCurvePublicKey: nil,
            caps: allCaps, ratchetV: HandshakeSigningPolicy.ratchetV, suiteId: HandshakeSigningPolicy.suiteId,
            pskFingerprints: nil, pskRoles: nil,
            rekeyNonce: rekeyNonce, rekeyRound: round, dtlsFingerprint: dtls,
            sasCommit: round == 1 ? sasCommit : nil)!
    }

    /// A valid ACCEPT_v6 binding `SHA-256(offer)` (acceptor fingerprint label "acceptor").
    static func acceptTranscript(
        signerKey: Data, offer: Data, dtls: Data = fingerprint("acceptor"), round: UInt32 = 1
    ) -> Data {
        HandshakeTranscript.accept(
            callId: callId, signerIdentityKey: signerKey,
            epochId: HandshakeSigningPolicy.placeholderEpochId,
            ctPqc: Data(repeating: 0xB1, count: 1568), ctX25519: Data(repeating: 0xB2, count: 32),
            ctStrongBox: nil, ctDualCurve: nil,
            caps: allCaps, ratchetV: HandshakeSigningPolicy.ratchetV, suiteId: HandshakeSigningPolicy.suiteId,
            selectedPskFingerprint: nil,
            offerBinding: HandshakeTranscript.offerBinding(offer),
            responderPskFingerprints: nil, responderPskRoles: nil,
            rekeyNonce: rekeyNonce, rekeyRound: round, dtlsFingerprint: dtls)!
    }
}
