import Foundation
import CryptoKit

public enum NfcPskDerivation {
    public enum Error: Swift.Error { case sharedSecretFailed }
    public static let hkdfInfo: Data = "Q-Audion NFC Collaborative PSK v1".data(using: .utf8)!

    public static func derivePsk(
        myPriv: Curve25519.KeyAgreement.PrivateKey,
        peerPub: Curve25519.KeyAgreement.PublicKey
    ) throws -> Data {
        let shared = try myPriv.sharedSecretFromKeyAgreement(with: peerPub)
        let myPub = myPriv.publicKey.rawRepresentation
        let peerPubBytes = peerPub.rawRepresentation
        let salt = sortedConcatHash(myPub, peerPubBytes)
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: salt, sharedInfo: hkdfInfo, outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }

    private static func sortedConcatHash(_ a: Data, _ b: Data) -> Data {
        let sorted = a.lexicographicallyPrecedes(b) ? a + b : b + a
        return Data(SHA256.hash(data: sorted))
    }
}

private extension Data {
    func lexicographicallyPrecedes(_ other: Data) -> Bool {
        for (lhs, rhs) in zip(self, other) {
            if lhs < rhs { return true }
            if lhs > rhs { return false }
        }
        return self.count < other.count
    }
}
