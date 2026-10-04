import XCTest
@testable import QAudionApp

/// CALL-METRICS (2026-10-04) -- the call-monitoring log lines must pass the in-app redactor untouched.
/// `LogRedactor.redactStructured` masks any run of 20 or more `[A-Za-z0-9+/=_-]` characters (residual sweep), and a
/// `key=value` token is one such run: a long key name or a few digits too many turns the token into `***REDACTED***`
/// before the line even reaches the log shipper. The shipper's own vocabulary test does not exercise this redactor.
/// Every token below is at most 19 characters including the `=` and 4 digits.
final class CallMetricsRedactionTests: XCTestCase {

    private let lines: [String] = [
        "audiosrtp hb=2 rtt=7 jitter_ms=77 target_ms=80 plc=0 fec_recv=44 fec_drop=45 nack=0 remote_loss=0 remote_rtt=20"
            + " relay=0 network_type=1 rtt_max=12 jitter_max=3 rtt_remote_max=21 lost_max=0 plc_max=0 sample=5",
        "audiosrtp hb=2 rtt=337 jitter_ms=470 target_ms=455 plc=93600 fec_recv=83 fec_drop=2 nack=1 remote_loss=20"
            + " remote_rtt=1734 relay=1 network_type=3 rtt_max=1730 jitter_max=70 rtt_remote_max=1734 lost_max=12"
            + " plc_max=9360 sample=5",
        "audiosrtp hb=3 eng=1 vpio=1 duck=0 echo_act=1200 echo_idle=3800 echo_far=5000 echo_active_db=-100"
            + " echo_idle_db=-100 echo_suspect=1",
        "audiosrtp hb=3 eng=2 vpio=0 duck=1",
        "audiosrtp hb=4 plc_silent_ms=5000 plc_hear_ms=5000 plc_event=1234",
        "audioroute why=1 old=1 out=3 in=3 profile=1 sr=16000 out_ch=1 in_ch=1 vol=50",
        "audioroute why=99 out=1 in=1 profile=0 sr=48000 out_ch=2 in_ch=1 vol=100",
    ]

    func test_everyCallMetricsLineSurvivesTheStructuredRedactor() {
        for line in lines {
            let out = LogRedactor.redactStructured(line)
            XCTAssertFalse(out.contains("REDACTED"), "masked: " + out)
            for token in line.split(separator: " ") where token.contains("=") {
                XCTAssertLessThanOrEqual(token.count, 19, "token too long for the residual sweep: " + token)
                XCTAssertTrue(out.contains(String(token)), "token lost or altered: " + token + " in " + out)
            }
        }
    }
}
