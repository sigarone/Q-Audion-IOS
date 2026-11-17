import XCTest
@testable import QAudionEngine

/// `EarbudAckPopRelay.prepareLink`: the KMS sweep reaches the remembered earbud only when a hw_only key is
/// there to deliver and the earbud is not connected, so the sweep never waits for an earbud it does not need.
///
/// Before, nothing connected the app's GATT proxy, `gatt.isConnected` was always false in the sweep and every
/// hw_only key ended `earbud_not_connected` forever.
final class EarbudAckPopRelayLinkTests: XCTestCase {

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private final class StubGatt: EarbudKeyGattProxy, @unchecked Sendable {
        private let lock = NSLock()
        private var connected: Bool
        private(set) var imports = 0
        let status: UInt8

        init(connected: Bool, status: UInt8 = EarbudGattConstants.KEYIMPORT_ST_OK) {
            self.connected = connected
            self.status = status
        }

        var isConnected: Bool {
            get { lock.lock(); defer { lock.unlock() }; return connected }
            set { lock.lock(); connected = newValue; lock.unlock() }
        }
        func startKeyImport(pkg: Data, popInputs: Data) async throws -> KeyImportOutcome {
            imports += 1
            return .ok(status: status, slot: 0)
        }
        func readAttestPop() async throws -> Data { Data(repeating: 0x7E, count: 32) }
    }

    private func makeKey(keyClass: String? = "hw_only", pkgLength: Int = EarbudGattConstants.KEYIMPORT_PKG_LEN) -> PendingKey {
        PendingKey(
            keyId: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            keyName: "hw-test",
            fingerprint: "fp",
            encryptedPackage: Data(count: pkgLength).base64EncodedString(),
            ephemeralPubkey: "",
            nonce: "",
            earbudId: "ear-1",
            keyClass: keyClass,
            txnId: "11111111-2222-3333-4444-555555555555",
            serverNonce: Data((0x10..<0x20).map { UInt8($0) }).base64EncodedString()
        )
    }

    func testAnUnconnectedEarbudIsReachedThroughPrepareLinkAndTheKeyIsDelivered() async {
        let gatt = StubGatt(connected: false)
        let prepared = Counter()
        let relay = EarbudAckPopRelay(gatt: gatt, prepareLink: {
            prepared.bump()
            gatt.isConnected = true
        })

        let result = await relay.handle(key: makeKey())

        guard case .popVerified(let pop) = result else { return XCTFail("expected popVerified, got \(result)") }
        XCTAssertEqual(Data(base64Encoded: pop), Data(repeating: 0x7E, count: 32))
        XCTAssertEqual(prepared.count, 1)
        XCTAssertEqual(gatt.imports, 1)
    }

    func testAConnectedEarbudIsNotPrepared() async {
        let gatt = StubGatt(connected: true)
        let prepared = Counter()
        let relay = EarbudAckPopRelay(gatt: gatt, prepareLink: { prepared.bump() })

        let result = await relay.handle(key: makeKey())

        guard case .popVerified = result else { return XCTFail("expected popVerified, got \(result)") }
        XCTAssertEqual(prepared.count, 0)
    }

    func testALinkThatCannotBeReachedDefersTheKeyAfterOneAttempt() async {
        let gatt = StubGatt(connected: false)
        let prepared = Counter()
        let relay = EarbudAckPopRelay(gatt: gatt, prepareLink: { prepared.bump() })

        let result = await relay.handle(key: makeKey())

        guard case .defer(let reason) = result else { return XCTFail("expected defer, got \(result)") }
        XCTAssertEqual(reason, "earbud_not_connected")
        XCTAssertEqual(prepared.count, 1)
        XCTAssertEqual(gatt.imports, 0)
    }

    func testWithoutPrepareLinkAnUnconnectedEarbudDefersAsBefore() async {
        let gatt = StubGatt(connected: false)
        let result = await EarbudAckPopRelay(gatt: gatt).handle(key: makeKey())
        guard case .defer(let reason) = result else { return XCTFail("expected defer, got \(result)") }
        XCTAssertEqual(reason, "earbud_not_connected")
    }

    func testAKeyTheRelayCannotDeliverNeverWaitsForTheEarbud() async {
        let gatt = StubGatt(connected: false)
        let prepared = Counter()
        let relay = EarbudAckPopRelay(gatt: gatt, prepareLink: { prepared.bump() })

        // not hw_only, a package of the wrong size: both are refused before any wait for the link
        let notHwOnly = await relay.handle(key: makeKey(keyClass: "shared"))
        guard case .defer(let r1) = notHwOnly else { return XCTFail("got \(notHwOnly)") }
        XCTAssertEqual(r1, "not_hw_only")

        let badSize = await relay.handle(key: makeKey(pkgLength: 100))
        guard case .defer(let r2) = badSize else { return XCTFail("got \(badSize)") }
        XCTAssertEqual(r2, "bad_package_size")

        XCTAssertEqual(prepared.count, 0, "the sweep waits for an earbud only for a key it can deliver")
    }
}
