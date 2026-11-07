import XCTest
#if canImport(WebRTC)
import WebRTC
#endif
@testable import QAudionEngine

#if canImport(WebRTC)
/// The post-quantum DTLS requirement is set at every 1:1 call start, with the flag value in both directions,
/// and a group start never touches it. Real WebRTC build (iOS Simulator slice), nothing is ever connected.
final class DtlsPqcRequirementTests: XCTestCase {

    private let callId = "dtls-pqc-requirement"
    private var savedOverride: Bool?
    private var seen: [Bool] = []

    override func setUp() {
        super.setUp()
        savedOverride = CallCapabilities.audioSrtpDebugOverride
        CallCapabilities.audioSrtpDebugOverride = true
        CallCapabilities.endNativeSrtpCallSnapshotAtCallEnd(callId: nil)
        CallCapabilities.beginNativeSrtpCallSnapshot(callId: callId)
        seen = []
        QaudionRuntimeTuning.requireDtlsPqcObserver = { [unowned self] in self.seen.append($0) }
    }

    override func tearDown() {
        QaudionRuntimeTuning.requireDtlsPqcObserver = nil
        // The native setting is process-wide: leave it cleared for whatever runs next.
        QaudionRuntimeTuning.setRequireDtlsPqc(false)
        CallCapabilities.endNativeSrtpCallSnapshot(callId: callId)
        CallCapabilities.audioSrtpDebugOverride = savedOverride
        super.tearDown()
    }

    private func makeOneToOne(provider: (() -> Bool)?) async throws -> QAudionPeerConnection {
        let factory = await QAudionPeerConnectionFactory.shared.factory()
        guard let context = CallDtlsContextStore().context(forCallId: callId) else {
            throw XCTSkip("no per-call certificate could be generated on this host")
        }
        return QAudionPeerConnection(factory: factory, iceServers: [], delegate: nil, dtlsContext: context,
                                     dtlsPqcRequiredProvider: provider)
    }

    func testEveryOneToOneStartSetsTheFlagValueTrueThenFalse() async throws {
        var flag = true
        let first = try await makeOneToOne(provider: { flag })
        first.close()
        flag = false
        let second = try await makeOneToOne(provider: { flag })
        second.close()
        XCTAssertEqual(seen, [true, false])
    }

    func testAMissingProviderSetsFalse() async throws {
        let peer = try await makeOneToOne(provider: nil)
        peer.close()
        XCTAssertEqual(seen, [false])
    }

    func testAGroupStartNeverTouchesIt() async throws {
        let factory = await QAudionPeerConnectionFactory.shared.factory()
        let base = GroupPeerBase(factory: factory, iceServers: [])
        _ = try base.makePeerConnection()
        base.closePeerConnection()
        XCTAssertEqual(seen, [])
    }
}
#endif
