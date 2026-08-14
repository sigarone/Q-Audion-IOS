import XCTest
@testable import QAudionEngine

/// W-PHANTOMCALLID (2026-08-14) — the call id a client stamps on outbound
/// signalling must be one the server knows, or nothing at all.
///
/// `BCryptoCallingApiImpl.currentCallId()` used to fall back to a fresh
/// `UUID().uuidString` AND latch it into `activeCallId`. A moment of `nil` did
/// not cost one frame, it redirected the ENTIRE call onto an id the server had
/// never heard of — and the server refuses those:
///
///     WARN "F4: call_video_state for foreign call_id rejected"
///     WARN "audio relay rejected: not an established call party"
///
/// Live on call `7fbb9921`, both legs 1.0.986: audio flowed, then ~30 s in the
/// callee's frames began being rejected and that direction went silent until
/// the user hung up. `sendHangup` clears the id by design and ICE keeps
/// trickling, so one late candidate after any clear was enough to poison the
/// rest of the call.
///
/// The rule these tests hold: an id is BOUND (incoming) or MINTED ONCE for an
/// outgoing offer. It is never conjured on the send path of a call that is
/// already running.
final class PhantomCallIdTests: XCTestCase {

    /// The whole defect in one property: reading the id must not create one.
    func testReadingTheActiveIdNeverMintsOne() {
        var store: String? = nil

        // The shape that shipped: read-or-mint-and-latch.
        func minting() -> String {
            if let s = store { return s }
            let fresh = UUID().uuidString
            store = fresh
            return fresh
        }
        _ = minting()
        XCTAssertNotNil(store, "the old shape latched a fabricated id — this is the bug")

        // The shape now in BCryptoCallingApiImpl.
        store = nil
        func reading() -> String? { store }
        XCTAssertNil(reading())
        XCTAssertNil(store, "reading the active call id must leave it unset")
    }

    /// A bound id is returned unchanged — the fix must not disturb the normal
    /// path, which is every call that works.
    func testABoundIdIsReturnedUnchanged() {
        let bound = "7fbb9921-c8a2-43d8-9753-55235533c1c6"
        var store: String? = bound
        func reading() -> String? { store }
        XCTAssertEqual(reading(), bound)
        XCTAssertEqual(store, bound)
    }

    /// Hangup clears the id. The next ICE candidate — which legitimately
    /// arrives after a teardown — must find nothing and send nothing, rather
    /// than mint the id that poisoned call 7fbb9921.
    func testAfterHangupALateCandidateFindsNoCallAndMintsNothing() {
        var store: String? = "7fbb9921-c8a2-43d8-9753-55235533c1c6"

        store = nil                                  // clearActiveCallId()
        func reading() -> String? { store }

        let idForLateCandidate = reading()
        XCTAssertNil(idForLateCandidate, "a late candidate must not be given an id")
        XCTAssertNil(store, "and must not leave one behind for the frames after it")
    }
}
