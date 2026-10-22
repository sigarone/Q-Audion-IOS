import XCTest
@testable import QAudionEngine

/// The definition of "a call" behind the Bluetooth pause (docs/mesh/MESH_LINK_SPEC.md section 2.1): any connected call
/// on the device, of any app, cellular included; ringing and dialling calls are not calls.
final class MeshCallDefinitionTests: XCTestCase {

    private typealias Call = MeshCallDefinition.SystemCall

    func testACallIsConnectedFromTheMomentItConnectsUntilItEnds() {
        XCTAssertTrue(MeshCallDefinition.isConnected(Call(hasConnected: true, hasEnded: false)))
        XCTAssertFalse(MeshCallDefinition.isConnected(Call(hasConnected: true, hasEnded: true)))
    }

    func testARingingOrDiallingCallIsNotACall() {
        // Not connected yet: an incoming call that nobody answered, an outgoing call the other side has not answered.
        XCTAssertFalse(MeshCallDefinition.isConnected(Call(hasConnected: false, hasEnded: false)))
        XCTAssertFalse(MeshCallDefinition.callActive(ownCallConnected: false, systemCalls: [Call(hasConnected: false, hasEnded: false)]))
    }

    func testACallThatEndedWithoutConnectingIsNotACall() {
        XCTAssertFalse(MeshCallDefinition.isConnected(Call(hasConnected: false, hasEnded: true)))
    }

    func testNoCallAtAll() {
        XCTAssertFalse(MeshCallDefinition.callActive(ownCallConnected: false, systemCalls: []))
    }

    func testTheOwnConnectedCallIsEnoughWhateverThePlatformReports() {
        XCTAssertTrue(MeshCallDefinition.callActive(ownCallConnected: true, systemCalls: []))
        XCTAssertTrue(MeshCallDefinition.callActive(ownCallConnected: true, systemCalls: [Call(hasConnected: false, hasEnded: false)]))
        XCTAssertTrue(MeshCallDefinition.callActive(ownCallConnected: true, systemCalls: [Call(hasConnected: true, hasEnded: true)]))
    }

    func testAnyConnectedCallOfTheDeviceCountsWithoutAnOwnCall() {
        // A cellular call or a call of another app.
        XCTAssertTrue(MeshCallDefinition.callActive(ownCallConnected: false, systemCalls: [Call(hasConnected: true, hasEnded: false)]))
        XCTAssertTrue(MeshCallDefinition.callActive(ownCallConnected: false, systemCalls: [
            Call(hasConnected: true, hasEnded: true),
            Call(hasConnected: false, hasEnded: false),
            Call(hasConnected: true, hasEnded: false),
        ]))
    }

    func testOnlyEndedOrRingingCallsDoNotCount() {
        XCTAssertFalse(MeshCallDefinition.callActive(ownCallConnected: false, systemCalls: [
            Call(hasConnected: true, hasEnded: true),
            Call(hasConnected: false, hasEnded: false),
            Call(hasConnected: false, hasEnded: true),
        ]))
    }
}
