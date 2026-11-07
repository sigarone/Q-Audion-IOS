import XCTest
@testable import QAudionEngine

final class NativeHandshakeLogLineTests: XCTestCase {
    private let line = "Q-AUDION dtls v=0304 cipher=1302 srtp=0008 group=11ec level=3 pqc_req=1 ok=1"

    func testRealFormatLineWithSourcePrefixMatches() {
        XCTAssertEqual(NativeHandshakeLogLine.normalized("(openssl_stream_adapter.cc:1234): " + line), line)
        XCTAssertEqual(NativeHandshakeLogLine.normalized("(rtc_base/openssl_stream_adapter.cc:88): " + line + "\n"), line)
    }

    func testLineWithoutPrefixMatches() {
        XCTAssertEqual(NativeHandshakeLogLine.normalized(line), line)
        XCTAssertEqual(NativeHandshakeLogLine.normalized(line + "\r\n"), line)
    }

    func testForgedVariantsAreRejected() {
        let forged: [String] = [
            line + " extra=1",
            line + " ",
            line + "\nQ-AUDION dtls v=0304 cipher=1302 srtp=0008 group=11ec level=3 pqc_req=1 ok=1",
            "(port.cc:1234): " + line,
            "(openssl_stream_adapter.cc.evil:1): " + line,
            "(my_openssl_stream_adapter.cc:1): " + line,
            "(openssl_stream_adapter.cc:12a): " + line,
            "peer said: " + line,
            "(turn_port.cc:5): remote note (openssl_stream_adapter.cc:1): " + line,
            "(openssl_stream_adapter.cc:1): (openssl_stream_adapter.cc:1): " + line,
            "Q-AUDION dtls v=030g cipher=1302 srtp=0008 group=11ec level=3 pqc_req=1 ok=1",
            "Q-AUDION dtls v=0304 cipher=1302 srtp=0008 group=11ec level=3 pqc_req=2 ok=1",
            "Q-AUDION dtls v=0304 cipher=1302 srtp=0008 group=11ec level=x pqc_req=1 ok=1",
            "Q-AUDION dtls v=304 cipher=1302 srtp=0008 group=11ec level=3 pqc_req=1 ok=1",
            "Q-AUDION dtls v=0304 cipher=1302 srtp=0008 group=11ec level=3 pqc_req=1 ok=1 ",
            "Q-AUDION  dtls v=0304 cipher=1302 srtp=0008 group=11ec level=3 pqc_req=1 ok=1",
            "Q-AUDION opus-enc tx_mode=1 tx_bw=3",
            "",
        ]
        for f in forged {
            XCTAssertNil(NativeHandshakeLogLine.normalized(f), "must reject: \(f)")
        }
    }
}
