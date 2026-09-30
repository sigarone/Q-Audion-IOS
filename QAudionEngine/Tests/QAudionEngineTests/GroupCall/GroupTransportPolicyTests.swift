import XCTest
@testable import QAudionEngine

final class GroupTransportPolicyTests: XCTestCase {

    private func observed(tls: String? = "FEFC", cipher: String? = "TLS_AES_256_GCM_SHA384", srtp: String? = "AEAD_AES_256_GCM") -> GroupTransportPolicy.Observed {
        GroupTransportPolicy.Observed(tlsVersion: tls, dtlsCipher: cipher, srtpCipher: srtp, candidateType: "host")
    }

    func testRequiredLevelPasses() {
        XCTAssertEqual(GroupTransportPolicy.evaluate(observed()), .ok)
    }

    func testBothSrtpSpellingsPass() {
        XCTAssertEqual(GroupTransportPolicy.evaluate(observed(srtp: "SRTP_AEAD_AES_256_GCM")), .ok)
    }

    func testDtls12IsAViolation() {
        XCTAssertEqual(GroupTransportPolicy.evaluate(observed(tls: "FEFD")), .violation(fields: ["tls"]))
    }

    func testTls13WithAes128IsAViolation() {
        XCTAssertEqual(GroupTransportPolicy.evaluate(observed(cipher: "TLS_AES_128_GCM_SHA256")), .violation(fields: ["cipher"]))
    }

    func testAes128SrtpIsAViolation() {
        XCTAssertEqual(GroupTransportPolicy.evaluate(observed(srtp: "AEAD_AES_128_GCM")), .violation(fields: ["srtp"]))
        XCTAssertEqual(GroupTransportPolicy.evaluate(observed(srtp: "AES_CM_128_HMAC_SHA1_80")), .violation(fields: ["srtp"]))
    }

    func testEveryFailureIsReportedInOrder() {
        XCTAssertEqual(GroupTransportPolicy.evaluate(observed(tls: "FEFD", cipher: "X", srtp: "Y")),
                       .violation(fields: ["tls", "cipher", "srtp"]))
    }

    func testAnEmptyRowIsNotReadyYetNotAViolation() {
        XCTAssertEqual(GroupTransportPolicy.evaluate(observed(tls: nil, cipher: nil, srtp: nil)), .notReady)
    }

    func testAPartiallyFilledRowMissingTheSrtpCipherIsAViolation() {
        XCTAssertEqual(GroupTransportPolicy.evaluate(observed(srtp: nil)), .violation(fields: ["srtp"]))
    }

    func testTlsVersionIsCaseAndPrefixTolerant() {
        XCTAssertEqual(GroupTransportPolicy.evaluate(observed(tls: "0xfefc")), .ok)
        XCTAssertEqual(GroupTransportPolicy.evaluate(observed(tls: "fefc")), .ok)
    }
}
