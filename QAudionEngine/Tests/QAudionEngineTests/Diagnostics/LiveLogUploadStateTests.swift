import XCTest
@testable import QAudionEngine

final class LiveLogUploadStateTests: XCTestCase {

    private let payload = Data(repeating: 0x41, count: 64)

    private func started() -> LiveLogUploadState {
        var state = LiveLogUploadState()
        state.start(filename: "chunk-1.log", data: payload, lastSeq: 40)
        return state
    }

    func test_retryUsesTheSamePayloadNameAndServerUpload() {
        var state = started()
        let first = state.nextAttempt()
        XCTAssertEqual(first?.attempts, 1)
        state.noteFileId("file-a")
        // New lines arrived meanwhile: a second start must not replace the unconfirmed payload.
        state.start(filename: "chunk-2.log", data: Data(repeating: 0x42, count: 8), lastSeq: 99)
        let second = state.nextAttempt()
        XCTAssertEqual(second?.filename, "chunk-1.log")
        XCTAssertEqual(second?.data, payload)
        XCTAssertEqual(second?.lastSeq, 40)
        XCTAssertEqual(second?.fileId, "file-a")
        XCTAssertEqual(second?.attempts, 2)
    }

    func test_networkAndServerErrorsKeepThePayload() {
        for status: Int? in [nil, 429, 502, 503, 409, 401] {
            var state = started()
            XCTAssertEqual(state.noteFailure(status: status), .retrySame)
            XCTAssertTrue(state.hasPending)
        }
    }

    func test_rejectedPayloadIsDiscardedSoTheQueueMovesOn() {
        for status in [400, 413, 415, 422] {
            var state = started()
            XCTAssertEqual(state.noteFailure(status: status), .discard)
            XCTAssertFalse(state.hasPending)
        }
    }

    func test_confirmationClearsOnlyWhenItCoversThePayload() {
        var state = started()
        XCTAssertFalse(state.confirm(throughSeq: 39))
        XCTAssertTrue(state.hasPending)
        XCTAssertTrue(state.confirm(throughSeq: 40))
        XCTAssertFalse(state.hasPending)
        XCTAssertNil(state.nextAttempt())
    }

    func test_forgetFileIdMakesTheNextAttemptCreateANewUpload() {
        var state = started()
        _ = state.nextAttempt()
        state.noteFileId("gone")
        state.forgetFileId()
        XCTAssertNil(state.nextAttempt()?.fileId)
        XCTAssertTrue(state.hasPending, "the payload itself is kept")
    }

    func test_resetDropsEverything() {
        var state = started()
        state.reset()
        XCTAssertFalse(state.hasPending)
    }
}
