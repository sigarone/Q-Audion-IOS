import XCTest
@testable import QAudionApp

/// How the phone knows it is in a car when a call arrives (`CarPlayLink`), and how that decides the way a one-to-one
/// call over the WebSocket is presented (`WsIncomingPresentation`).
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing` list of
/// `.github/workflows/ios-ci.yml`.
final class CarPlayLinkTests: XCTestCase {

    override func tearDown() {
        CarPlayLink.setSceneConnected(false)
        super.tearDown()
    }

    // MARK: - Combining the signals

    func test_combine_nameTheSource() {
        XCTAssertEqual(CarPlayLink.combine(scene: true, route: true), .init(connected: true, source: .both))
        XCTAssertEqual(CarPlayLink.combine(scene: true, route: false), .init(connected: true, source: .scene))
        XCTAssertEqual(CarPlayLink.combine(scene: false, route: true), .init(connected: true, source: .route))
        XCTAssertEqual(CarPlayLink.combine(scene: false, route: false), .init(connected: false, source: .none))
    }

    func test_sourceRawValuesAreTheLoggedWords() {
        XCTAssertEqual(CarPlayLink.Source.scene.rawValue, "scene")
        XCTAssertEqual(CarPlayLink.Source.route.rawValue, "route")
        XCTAssertEqual(CarPlayLink.Source.both.rawValue, "both")
        XCTAssertEqual(CarPlayLink.Source.none.rawValue, "none")
    }

    // MARK: - Scene signal

    func test_sceneFlag_followsSetSceneConnected() {
        CarPlayLink.setSceneConnected(false)
        XCTAssertFalse(CarPlayLink.sceneConnected)
        CarPlayLink.setSceneConnected(true)
        XCTAssertTrue(CarPlayLink.sceneConnected)
        CarPlayLink.setSceneConnected(false)
        XCTAssertFalse(CarPlayLink.sceneConnected)
    }

    @MainActor
    func test_bridge_connectAndDisconnect_setAndClearTheSceneFlag() {
        let bridge = CarPlayBridge.shared
        bridge.carPlayConnected()
        XCTAssertTrue(CarPlayLink.sceneConnected)
        XCTAssertTrue(CarPlayLink.read().connected)
        bridge.carPlayDisconnected()
        XCTAssertFalse(CarPlayLink.sceneConnected)
    }

    func test_read_withTheSceneConnected_isConnectedWhateverTheRouteSays() {
        CarPlayLink.setSceneConnected(true)
        let reading = CarPlayLink.read()
        XCTAssertTrue(reading.connected)
        XCTAssertTrue(reading.source == .scene || reading.source == .both)
    }

    // MARK: - Presentation of a WebSocket call

    func test_foregroundWithoutCarPlay_staysInTheApp() {
        XCTAssertEqual(WsIncomingPresentation.decide(foreground: true, carPlay: false), .inAppOnly)
    }

    func test_foregroundWithCarPlay_goesToCallKit() {
        XCTAssertEqual(WsIncomingPresentation.decide(foreground: true, carPlay: true), .callKit)
    }

    func test_background_goesToCallKitWithOrWithoutCarPlay() {
        XCTAssertEqual(WsIncomingPresentation.decide(foreground: false, carPlay: false), .callKit)
        XCTAssertEqual(WsIncomingPresentation.decide(foreground: false, carPlay: true), .callKit)
    }
}
