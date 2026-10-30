import Foundation
import CryptoKit
import Security

/// The proof of a node id (docs/mesh/MESH_LINK_SPEC.md section 8.5). Each side puts a random 16-byte challenge in its ANNOUNCE
/// on a link (`ch`). The other side answers with an ANNOUNCE_PROOF packet carrying its identity public key and an Ed25519
/// signature over a fixed 73-byte message that binds the domain, the link role, both node ids and both challenges. The proof is
/// checked in the background: a link is usable from its first ANNOUNCE and only ranks higher once verified.
public enum MeshAnnounceProof {

    /// The domain separation string, 24 ASCII bytes.
    public static let domain = Data("qaudion-mesh-announce-v1".utf8)
    public static let payloadVersion: UInt8 = 1
    public static let nonceBytes = 16
    public static let publicKeyBytes = 32
    public static let signatureBytes = 64
    /// version(1) + public key(32) + signature(64).
    public static let payloadLength = 1 + publicKeyBytes + signatureBytes
    /// domain(24) + role(1) + prover(8) + verifier(8) + prover nonce(16) + verifier nonce(16).
    public static let messageLength = 24 + 1 + 8 + 8 + nonceBytes + nonceBytes

    private static let roleCentral: UInt8 = 1
    private static let rolePeripheral: UInt8 = 2

    public static func newNonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: nonceBytes)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        }
        return Data(bytes)
    }

    /// The bytes that are signed. `proverIsCentral` is the role of the PROVER on this link.
    public static func message(prover: MeshNodeId, verifier: MeshNodeId, proverNonce: Data, verifierNonce: Data,
                               proverIsCentral: Bool) -> Data? {
        guard proverNonce.count == nonceBytes, verifierNonce.count == nonceBytes else { return nil }
        var out = Data(capacity: messageLength)
        out.append(domain)
        out.append(proverIsCentral ? roleCentral : rolePeripheral)
        out.append(prover.toBytes())
        out.append(verifier.toBytes())
        out.append(proverNonce)
        out.append(verifierNonce)
        return out
    }

    public static func payload(publicKey: Data, signature: Data) -> Data? {
        guard publicKey.count == publicKeyBytes, signature.count == signatureBytes else { return nil }
        var out = Data([payloadVersion])
        out.append(publicKey)
        out.append(signature)
        return out
    }

    public enum Result: String, Sendable {
        case ok
        case badLength = "bad_len"
        case badVersion = "bad_ver"
        case nodeMismatch = "bad_node"
        case badSignature = "bad_sig"
        /// A valid proof, but the node id is pinned to another key (set by the transport, never by ``verify``).
        case keyChanged = "key_change"
    }

    /// Checks a proof received on a link. `prover` is the node id the link is bound to, `verifier` is this device,
    /// `proverNonce` the challenge the prover sent in its ANNOUNCE on this link and `verifierNonce` ours.
    public static func verify(payload: Data, prover: MeshNodeId, verifier: MeshNodeId, proverNonce: Data, verifierNonce: Data,
                              proverIsCentral: Bool) -> Result {
        let bytes = [UInt8](payload)
        guard bytes.count == payloadLength else { return .badLength }
        guard bytes[0] == payloadVersion else { return .badVersion }
        let key = Data(bytes[1..<(1 + publicKeyBytes)])
        let signature = Data(bytes[(1 + publicKeyBytes)...])
        // The node id is the fingerprint of the key: the same function that derives every node id.
        guard MeshNodeId.from(identityKeyRaw: key) == prover else { return .nodeMismatch }
        guard let message = message(prover: prover, verifier: verifier, proverNonce: proverNonce, verifierNonce: verifierNonce,
                                    proverIsCentral: proverIsCentral),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key),
              publicKey.isValidSignature(signature, for: message) else { return .badSignature }
        return .ok
    }

    /// The public key a payload carries, for the cache; nil if the payload is not the right size.
    public static func publicKey(of payload: Data) -> Data? {
        guard payload.count == payloadLength else { return nil }
        let bytes = [UInt8](payload)
        return Data(bytes[1..<(1 + publicKeyBytes)])
    }
}
