import XCTest
@testable import QAudionEngine

final class CallKitManagingTests: XCTestCase {

    private var mock: MockCallKitManager!

    override func setUp() {
        super.setUp()
        mock = MockCallKitManager()
    }

    override func tearDown() {
        mock.reset()
        mock = nil
        super.tearDown()
    }

    // MARK: - reportIncomingCall

    func test_reportIncomingCall_recordsCorrectAction() async {
        let uuid = UUID()
        await mock.reportIncomingCall(uuid: uuid, callerName: "Alice", hasVideo: false)

        XCTAssertEqual(mock.records.count, 1)
        XCTAssertEqual(
            mock.records.first?.action,
            .reportIncomingCall(uuid: uuid, callerName: "Alice", hasVideo: false)
        )
    }

    // MARK: - reportCallEnded

    func test_reportCallEnded_recordsCorrectAction() async {
        let uuid = UUID()
        await mock.reportCallEnded(uuid: uuid, reason: .remoteEnded)

        XCTAssertEqual(mock.records.count, 1)
        XCTAssertEqual(
            mock.records.first?.action,
            .reportCallEnded(uuid: uuid, reason: .remoteEnded)
        )
    }

    func test_reportCallEnded_withFailedReason_recordsMessage() async {
        let uuid = UUID()
        await mock.reportCallEnded(uuid: uuid, reason: .failed("network timeout"))

        XCTAssertEqual(
            mock.records.first?.action,
            .reportCallEnded(uuid: uuid, reason: .failed("network timeout"))
        )
    }

    // MARK: - startOutgoingCall

    func test_startOutgoingCall_returnsConfiguredUUID() async throws {
        let expected = UUID()
        mock.startOutgoingCallResult = .success(expected)

        let returned = try await mock.startOutgoingCall(handle: "+15551234567", hasVideo: true)

        XCTAssertEqual(returned, expected)
        XCTAssertEqual(
            mock.records.first?.action,
            .startOutgoingCall(handle: "+15551234567", hasVideo: true)
        )
    }

    func test_startOutgoingCall_throwsConfiguredError() async {
        struct FakeError: Error, Equatable {}
        mock.startOutgoingCallResult = .failure(FakeError())

        do {
            _ = try await mock.startOutgoingCall(handle: "bob", hasVideo: false)
            XCTFail("Expected an error to be thrown")
        } catch is FakeError {
            // expected
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - reportCallConnected

    func test_reportCallConnected_recordsCorrectAction() async {
        let uuid = UUID()
        await mock.reportCallConnected(uuid: uuid)

        XCTAssertEqual(mock.records.count, 1)
        XCTAssertEqual(
            mock.records.first?.action,
            .reportCallConnected(uuid: uuid)
        )
    }

    // MARK: - setMuted

    func test_setMuted_recordsCorrectAction() async throws {
        let uuid = UUID()
        try await mock.setMuted(uuid: uuid, isMuted: true)

        XCTAssertEqual(mock.records.count, 1)
        XCTAssertEqual(
            mock.records.first?.action,
            .setMuted(uuid: uuid, isMuted: true)
        )
    }

    func test_setMuted_throwsConfiguredError() async {
        struct MuteError: Error {}
        mock.setMutedError = MuteError()

        do {
            try await mock.setMuted(uuid: UUID(), isMuted: false)
            XCTFail("Expected error to be thrown")
        } catch is MuteError {
            // expected
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - setOnHold

    func test_setOnHold_recordsCorrectAction() async throws {
        let uuid = UUID()
        try await mock.setOnHold(uuid: uuid, isOnHold: true)

        XCTAssertEqual(mock.records.count, 1)
        XCTAssertEqual(
            mock.records.first?.action,
            .setOnHold(uuid: uuid, isOnHold: true)
        )
    }

    func test_setOnHold_throwsConfiguredError() async {
        struct HoldError: Error {}
        mock.setOnHoldError = HoldError()

        do {
            try await mock.setOnHold(uuid: UUID(), isOnHold: false)
            XCTFail("Expected error to be thrown")
        } catch is HoldError {
            // expected
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}
