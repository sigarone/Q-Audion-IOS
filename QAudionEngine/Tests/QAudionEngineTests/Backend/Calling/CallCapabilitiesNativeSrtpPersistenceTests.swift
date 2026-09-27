import XCTest
@testable import QAudionEngine

/// W-NATIVESRTPPERSIST (this task) — the persisted native-SRTP override
/// (``CallCapabilities/loadPersistedAudioSrtpOverride()`` /
/// ``CallCapabilities/savePersistedAudioSrtpOverride(_:)``) and the
/// consecutive-native-crash auto-reset guard
/// (``CallCapabilities/registerNativeSrtpCrashAndMaybeAutoReset()``).
/// Mirrors Android's `NativeSrtpPreferenceTest` (three-state read/write +
/// removal-on-reset) plus the owner-recommended crash-streak behavior from
/// spec section B.
final class CallCapabilitiesNativeSrtpPersistenceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        resetAllPersistedState()
    }

    override func tearDown() {
        resetAllPersistedState()
        super.tearDown()
    }

    private func resetAllPersistedState() {
        CallCapabilities.savePersistedAudioSrtpOverride(nil)
        CallCapabilities.resetNativeSrtpCrashStreak()
        CallCapabilities.audioSrtpDebugOverride = nil
        CallCapabilities.endNativeSrtpCallSnapshot()
    }

    // MARK: - Three-state persistence

    func test_neverWritten_loadsNil() {
        XCTAssertNil(CallCapabilities.loadPersistedAudioSrtpOverride())
    }

    func test_saveTrue_loadsTrue() {
        CallCapabilities.savePersistedAudioSrtpOverride(true)
        XCTAssertEqual(CallCapabilities.loadPersistedAudioSrtpOverride(), true)
    }

    func test_saveFalse_loadsFalse() {
        // Distinct from "never written" (nil) — a user who explicitly
        // turned it OFF must not be indistinguishable from a fresh install.
        CallCapabilities.savePersistedAudioSrtpOverride(false)
        XCTAssertEqual(CallCapabilities.loadPersistedAudioSrtpOverride(), false)
    }

    func test_saveNil_removesTheKey_backToNeverWrittenState() {
        CallCapabilities.savePersistedAudioSrtpOverride(true)
        XCTAssertEqual(CallCapabilities.loadPersistedAudioSrtpOverride(), true)
        CallCapabilities.savePersistedAudioSrtpOverride(nil)
        XCTAssertNil(CallCapabilities.loadPersistedAudioSrtpOverride())
    }

    func test_saveFalseThenNil_isDistinguishableFromSaveFalse() {
        CallCapabilities.savePersistedAudioSrtpOverride(false)
        CallCapabilities.savePersistedAudioSrtpOverride(nil)
        XCTAssertNil(CallCapabilities.loadPersistedAudioSrtpOverride(),
                     "reset must clear the key, not merely flip it to false")
    }

    // MARK: - Crash-streak auto-reset (spec section B, owner-recommended ON)

    func test_singleNativeCrash_doesNotAutoReset() {
        CallCapabilities.savePersistedAudioSrtpOverride(true)
        CallCapabilities.audioSrtpDebugOverride = true
        let fired = CallCapabilities.registerNativeSrtpCrashAndMaybeAutoReset()
        XCTAssertFalse(fired)
        XCTAssertEqual(CallCapabilities.nativeSrtpCrashStreak(), 1)
        // The preference itself must be untouched after only one crash.
        XCTAssertEqual(CallCapabilities.loadPersistedAudioSrtpOverride(), true)
        XCTAssertEqual(CallCapabilities.audioSrtpDebugOverride, true)
    }

    func test_twoConsecutiveNativeCrashes_autoResetsToOffPersisted() {
        CallCapabilities.savePersistedAudioSrtpOverride(true)
        CallCapabilities.audioSrtpDebugOverride = true
        _ = CallCapabilities.registerNativeSrtpCrashAndMaybeAutoReset()
        let firedOnSecond = CallCapabilities.registerNativeSrtpCrashAndMaybeAutoReset()
        XCTAssertTrue(firedOnSecond)
        XCTAssertEqual(CallCapabilities.loadPersistedAudioSrtpOverride(), false,
                       "two crashes in a row must force the PERSISTED override off")
        XCTAssertEqual(CallCapabilities.audioSrtpDebugOverride, false,
                       "and the live value, so the very next call already reflects it")
        XCTAssertEqual(CallCapabilities.nativeSrtpCrashStreak(), 0,
                       "the streak counter itself must not ratchet forever")
    }

    func test_cleanNativeCallEnd_resetsTheStreak_soAnUnrelatedLaterCrashStartsFresh() {
        CallCapabilities.savePersistedAudioSrtpOverride(true)
        _ = CallCapabilities.registerNativeSrtpCrashAndMaybeAutoReset() // streak = 1
        XCTAssertEqual(CallCapabilities.nativeSrtpCrashStreak(), 1)
        // A native call that ends WITHOUT crashing (CallService.endCall()'s
        // own call) breaks the "consecutive" chain.
        CallCapabilities.resetNativeSrtpCrashStreak()
        XCTAssertEqual(CallCapabilities.nativeSrtpCrashStreak(), 0)
        let firedOnNextCrash = CallCapabilities.registerNativeSrtpCrashAndMaybeAutoReset()
        XCTAssertFalse(firedOnNextCrash, "a single crash after a working call must not auto-reset")
        XCTAssertEqual(CallCapabilities.nativeSrtpCrashStreak(), 1)
    }

    // MARK: - Remote kill switch (forceNativeSrtpCallSnapshotOff)

    func test_forceOff_onlyAffectsTheMatchingCallId() {
        _ = CallCapabilities.audioSrtpDebugOverride = true
        _ = CallCapabilities.beginNativeSrtpCallSnapshot(callId: "call-aaa")
        XCTAssertEqual(CallCapabilities.nativeSrtpCallSnapshot, true)

        XCTAssertFalse(CallCapabilities.forceNativeSrtpCallSnapshotOff(callId: "call-bbb"),
                       "a different call id must not be able to force this one off")
        XCTAssertEqual(CallCapabilities.nativeSrtpCallSnapshot, true)

        XCTAssertTrue(CallCapabilities.forceNativeSrtpCallSnapshotOff(callId: "CALL-AAA"),
                     "case-insensitive match on the owning call id")
        XCTAssertEqual(CallCapabilities.nativeSrtpCallSnapshot, false)

        // Idempotent: already false, so a second force reports "nothing to do".
        XCTAssertFalse(CallCapabilities.forceNativeSrtpCallSnapshotOff(callId: "call-aaa"))
    }

    func test_forceOff_withNoSnapshot_isANoOp() {
        XCTAssertNil(CallCapabilities.nativeSrtpCallSnapshot)
        XCTAssertFalse(CallCapabilities.forceNativeSrtpCallSnapshotOff(callId: "call-aaa"))
        XCTAssertNil(CallCapabilities.nativeSrtpCallSnapshot)
    }
}
