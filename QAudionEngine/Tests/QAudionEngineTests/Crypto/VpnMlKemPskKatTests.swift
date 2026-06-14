import XCTest
import CryptoKit
@testable import QAudionEngine

/// KAT for the VPN WireGuard PSK derivation (`VpnMlKem.deriveWgPsk`).
///
/// The VPN PQC-hybrid handshake derives the WireGuard PresharedKey from the
/// ML-KEM-768 shared secret as:
///   PSK = HKDF-SHA256(IKM = sharedSecret(32),
///                     salt = <EMPTY>,
///                     info = UTF8("bcrypto-wg-psk-v1"),
///                     L = 32)
///
/// This test pins the HKDF step to a frozen cross-platform vector so it can be
/// verified WITHOUT a live ML-KEM-768 KEM (the vendored liboqs build may be
/// 1024-only, in which case the keygen/decap path is unavailable but the HKDF
/// contract still must match the server + Android byte-for-byte).
///
/// FROZEN VECTOR (independently cross-checked with python `cryptography` HKDF):
///   sharedSecret = 0x00..0x1f
///   → PSK hex = d167a6140371ee7511a5a7c71fae6fce7a9155037ba49f58579196478e7c8763
///   → PSK b64 = 0WemFANx7nURpafHH65vznqRVQN7pJ9YV5GWR458h2M=
final class VpnMlKemPskKatTests: XCTestCase {

    /// sharedSecret = bytes 0x00..0x1f (matches the frozen vector).
    private let sharedSecret = Data((0x00...0x1f).map { UInt8($0) })

    private let expectedHex =
        "d167a6140371ee7511a5a7c71fae6fce7a9155037ba49f58579196478e7c8763"
    private let expectedB64 =
        "0WemFANx7nURpafHH65vznqRVQN7pJ9YV5GWR458h2M="

    func testPskKatMatchesFrozenVector() {
        let psk = VpnMlKem.deriveWgPsk(fromSharedSecret: sharedSecret)
        XCTAssertEqual(psk.count, 32, "PSK must be 32 bytes")
        XCTAssertEqual(psk.map { String(format: "%02x", $0) }.joined(), expectedHex)
        XCTAssertEqual(psk.base64EncodedString(), expectedB64)
    }

    /// Sanity: an empty salt (Data()) must follow RFC 5869 (treated as 32 zero
    /// bytes), i.e. the same as the explicit `info` label with no salt. This
    /// guards against a future refactor accidentally introducing a non-empty
    /// salt, which would silently break interop with the server.
    func testEmptySaltContract() {
        let reference = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedSecret),
            salt: Data(),
            info: Data("bcrypto-wg-psk-v1".utf8),
            outputByteCount: 32
        ).withUnsafeBytes { Data($0) }
        XCTAssertEqual(VpnMlKem.deriveWgPsk(fromSharedSecret: sharedSecret), reference)
    }

    /// `decapsulate` must reject a ciphertext whose length is not the ML-KEM-768
    /// size (1088), independent of liboqs availability.
    func testDecapsulateRejectsWrongCiphertextLength() {
        XCTAssertThrowsError(
            try VpnMlKem.decapsulate(ciphertext: Data(count: 1087), secretKey: Data(count: 2400))
        ) { error in
            XCTAssertEqual(error as? VpnMlKemError, .invalidCiphertext)
        }
    }
}
