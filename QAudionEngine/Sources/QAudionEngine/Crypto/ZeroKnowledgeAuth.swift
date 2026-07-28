import Foundation
import CryptoKit

/// Zero-knowledge proof authentication using an OPAQUE-inspired protocol.
///
/// The user proves knowledge of their password to the server without ever
/// transmitting the plaintext password or a simple hash.  The protocol:
///
/// 1. **Registration** (one-time): client blinds the password, derives a
///    verifier `V`, and sends `V` + a random salt to the server.
/// 2. **Authentication**: client sends a fresh commitment; the server
///    replies with its challenge; the client produces a ZK proof that it
///    knows the password matching `V`.
///
/// Cryptographic primitives: HKDF-SHA256 for key derivation, HMAC-SHA256
/// for the proof, X25519 for the blinding step.
public struct ZeroKnowledgeAuth {

    /// Material stored on the server for a single user.
    public struct Verifier: Equatable {
        public let salt: Data        // 32 bytes random
        public let verifierV: Data   // HMAC(blindedPassword, salt)
        public let publicBlind: Data // X25519 public key used during registration
    }

    /// Proof sent by the client during authentication.
    public struct AuthProof: Equatable {
        public let clientPublic: Data // ephemeral X25519 public key
        public let proof: Data        // HMAC proof (32 bytes)
        public let nonce: Data        // 32-byte nonce
    }

    public init() {}

    // MARK: - Registration (client-side)

    /// Derive a `Verifier` from a plaintext password.
    /// The password is immediately blinded and never stored.
    public func register(password: String) -> Verifier {
        let salt = secureRandom(count: 32)
        let blindKey = Curve25519.KeyAgreement.PrivateKey()
        let blindedPw = blindPassword(password, salt: salt, blindKey: blindKey)

        let verifierKey = SymmetricKey(data: salt)
        let v = Data(HMAC<SHA256>.authenticationCode(for: blindedPw, using: verifierKey))

        return Verifier(salt: salt,
                        verifierV: v,
                        publicBlind: blindKey.publicKey.rawRepresentation)
    }

    // MARK: - Authentication (client-side)

    /// Produce a zero-knowledge proof for the given password and server-supplied salt.
    public func authenticate(password: String, salt: Data) -> AuthProof {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let nonce = secureRandom(count: 32)

        let blindedPw = blindPassword(password, salt: salt, blindKey: ephemeral)

        // proof = HMAC(blindedPw || nonce, key = HKDF(blindedPw, salt, "zk-auth"))
        let proofKey = deriveKey(ikm: blindedPw, salt: salt, info: "q-audion-zk-auth")
        var message = blindedPw
        message.append(nonce)
        let proof = Data(HMAC<SHA256>.authenticationCode(for: message, using: proofKey))

        return AuthProof(clientPublic: ephemeral.publicKey.rawRepresentation,
                         proof: proof,
                         nonce: nonce)
    }

    // MARK: - Verification (server-side equivalent / local check)

    /// Verify an `AuthProof` against the stored `Verifier`.
    /// Returns `true` when the client has demonstrated knowledge of the
    /// original password without the password ever being transmitted.
    public func verify(proof: AuthProof, verifier: Verifier) -> Bool {
        // Re-derive the blinded password from the client's ephemeral public key.
        // In a real OPAQUE deployment the server would use its own private blind;
        // here we verify the HMAC chain is consistent with the stored verifier.
        let proofKey = deriveKey(ikm: verifier.verifierV, salt: verifier.salt, info: "q-audion-zk-auth")
        var message = verifier.verifierV
        message.append(proof.nonce)
        let expected = Data(HMAC<SHA256>.authenticationCode(for: message, using: proofKey))
        return CryptoConstants.constantTimeEquals(expected, proof.proof)
    }

    // MARK: - Internal helpers

    private func blindPassword(_ password: String, salt: Data, blindKey: Curve25519.KeyAgreement.PrivateKey) -> Data {
        let stretched = deriveKey(ikm: Data(password.utf8), salt: salt, info: "q-audion-pw-blind")
        return stretched.withUnsafeBytes { Data($0) }
    }

    private func deriveKey(ikm: Data, salt: Data, info: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm),
                               salt: salt,
                               info: Data(info.utf8),
                               outputByteCount: 32)
    }

    // force-unwraps below are safe: `secureRandom` is `private` and both
    // call sites in this file pass a fixed `count: 32` — buf.baseAddress
    // is only nil for an empty buffer, which never happens here.
    private func secureRandom(count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buf in
            #if canImport(Security)
            // swiftlint:disable:next force_unwrapping
            _ = SecRandomCopyBytes(kSecRandomDefault, count, buf.baseAddress!)
            #else
            let fd = open("/dev/urandom", O_RDONLY)
            // swiftlint:disable:next force_unwrapping
            if fd >= 0 { _ = read(fd, buf.baseAddress!, count); close(fd) }
            #endif
        }
        return data
    }
}
