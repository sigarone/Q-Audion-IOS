import XCTest
@testable import QAudionEngine

/// The one earbud GATT client acts only on link callbacks about the peripheral it follows now. The rule is
/// pure so it is pinned here; `IOSEarbudGattProxy` applies it in every CoreBluetooth callback (the app target
/// cannot be unit-tested without CoreBluetooth, see the CI job earbud-variant-build).
final class EarbudLinkIdentityTests: XCTestCase {

    private let earbudA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-00000000000A")!
    private let earbudB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-00000000000B")!

    func testACallbackAboutTheCurrentPeripheralConcernsTheLink() {
        XCTAssertTrue(EarbudLinkIdentity.concernsCurrentLink(callback: earbudA, current: earbudA))
    }

    /// The bug: `ensureConnected(B)` cancels A and makes B current; A's didDisconnect arrives afterwards and
    /// must not touch B's state.
    func testALateCallbackOfThePreviousPeripheralDoesNotConcernTheNewLink() {
        XCTAssertFalse(EarbudLinkIdentity.concernsCurrentLink(callback: earbudA, current: earbudB))
    }

    func testNoCallbackConcernsAClientThatFollowsNoPeripheral() {
        XCTAssertFalse(EarbudLinkIdentity.concernsCurrentLink(callback: earbudA, current: nil))
    }

    /// A model of the switch, to read the rule as the client uses it: the client's current link and the stream
    /// of callbacks CoreBluetooth delivers after `ensureConnected(B)` replaced A.
    func testTheCallbacksAfterASwitchAreActedOnForTheNewPeripheralOnly() {
        var current: UUID? = earbudA
        var acted: [String] = []
        func deliver(_ name: String, for id: UUID) {
            if EarbudLinkIdentity.concernsCurrentLink(callback: id, current: current) { acted.append(name) }
        }

        deliver("A didConnect", for: earbudA)
        current = earbudB                              // ensureConnected(B): A is cancelled, B is current
        deliver("A didDisconnect", for: earbudA)       // late: ignored
        deliver("A didFailToConnect", for: earbudA)    // late: ignored
        deliver("B didConnect", for: earbudB)
        deliver("B didDisconnect", for: earbudB)

        XCTAssertEqual(acted, ["A didConnect", "B didConnect", "B didDisconnect"])
    }
}
