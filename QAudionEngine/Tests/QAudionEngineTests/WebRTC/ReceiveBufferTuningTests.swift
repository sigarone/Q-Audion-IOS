import XCTest
@testable import QAudionEngine

final class ReceiveBufferTuningTests: XCTestCase {

    func test_forgetFactorIsAValidFraction() {
        XCTAssertGreaterThan(ReceiveBufferTuning.forgetFactor, 0)
        XCTAssertLessThan(ReceiveBufferTuning.forgetFactor, 1)
    }

    func test_agesOutFasterThanStock() {
        let stockHalfLife = 0.5 * (log(0.5) / log(0.983))
        XCTAssertLessThan(ReceiveBufferTuning.halfLifeSeconds, stockHalfLife / 2)
    }

    func test_doesNotAgeOutSoFastThatBurstsAreForgotten() {
        XCTAssertGreaterThanOrEqual(ReceiveBufferTuning.halfLifeSeconds, 5)
    }

    func test_trialValueFormat() {
        XCTAssertEqual(ReceiveBufferTuning.trialValue, "forget_factor:0.960")
    }

    func test_fieldTrialStringIsOrderedAndTerminated() {
        let s = ReceiveBufferTuning.fieldTrialString(ReceiveBufferTuning.fieldTrials)
        XCTAssertEqual(s, "WebRTC-Audio-NetEqDelayManagerConfig/forget_factor:0.960/"
                        + "WebRTC-Network-UseNWPathMonitor/Enabled/")
    }

    func test_fieldTrialStringKeepsEveryEntry() {
        let s = ReceiveBufferTuning.fieldTrialString(["A": "1", "B": "2"])
        XCTAssertEqual(s, "A/1/B/2/")
    }
}
