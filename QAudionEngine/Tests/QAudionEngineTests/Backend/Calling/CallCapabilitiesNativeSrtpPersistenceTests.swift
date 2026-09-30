import XCTest
@testable import QAudionEngine

/// W-NATIVESRTPPERSIST — the persisted native-SRTP override
/// (``CallCapabilities/loadPersistedAudioSrtpOverride()`` /
/// ``CallCapabilities/savePersistedAudioSrtpOverride(_:)``) and the
/// consecutive-native-crash auto-reset guard
/// (``CallCapabilities/registerNativeSrtpCrashAndMaybeAutoReset()``).
/// Mirrors Android's `NativeSrtpPreferenceTest` (three-state read/write +
/// removal-on-reset) plus the owner-recommended crash-streak behavior from
/// spec section B. W-SRTPALWAYSON (2026-09-29/30) added the migration
/// section at the bottom — the Settings toggle that used to be the OTHER
/// caller of `savePersistedAudioSrtpOverride` is gone, and an install
/// updating from before that change must not keep whatever it last chose.
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
        CallCapabilities.resetManualOverrideMigrationFlagForTesting()
        UserDefaults.standard.removeObject(forKey: "qaudion.calls.nativeSrtpGuardTrippedBuild.v1")
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

    // MARK: - W-SRTPALWAYSON (2026-09-29/30) — migration away from the toggle

    /// An install updating from before the toggle's removal may still have
    /// its last manual choice sitting in the persisted slot. The migration
    /// must discard it unconditionally, whatever it was — a pre-update
    /// manual "OFF" must never keep native SRTP off after this update.
    func test_migration_discardsAPreExistingManualValue_regardlessOfWhatItWas() {
        CallCapabilities.savePersistedAudioSrtpOverride(false) // pre-update manual choice
        CallCapabilities.migrateAwayFromManualAudioSrtpOverrideIfNeeded()
        XCTAssertNil(CallCapabilities.loadPersistedAudioSrtpOverride(),
                     "a pre-existing manual toggle value must not survive the migration")
    }

    func test_migration_runsOnlyOnce_andNeverClobbersALaterCrashStreakValue() {
        CallCapabilities.savePersistedAudioSrtpOverride(true) // pre-update manual choice
        CallCapabilities.migrateAwayFromManualAudioSrtpOverrideIfNeeded()
        XCTAssertNil(CallCapabilities.loadPersistedAudioSrtpOverride())

        // Simulate the crash-streak safety net legitimately persisting a
        // fresh `false` on a LATER launch, after the migration already ran
        // once. A second migration call must be a no-op.
        CallCapabilities.savePersistedAudioSrtpOverride(false)
        CallCapabilities.migrateAwayFromManualAudioSrtpOverrideIfNeeded()
        XCTAssertEqual(CallCapabilities.loadPersistedAudioSrtpOverride(), false,
                       "the migration must run only once -- it must never wipe a value the crash-streak safety net persists afterward")
    }

    func test_migration_withNothingPersisted_isANoOp() {
        CallCapabilities.migrateAwayFromManualAudioSrtpOverrideIfNeeded()
        XCTAssertNil(CallCapabilities.loadPersistedAudioSrtpOverride())
    }

    // MARK: - Cross-platform parity round 2 (2026-09-30): build-tied persistence
    //
    // Mirrors Android's `NativeSrtpCrashGuardTest` build-tie cases
    // (`decideGuardOnLoad` / `effectiveStreakForBuild`): trip after two
    // consecutive crashes, persist across a restart of the SAME build,
    // auto-clear the moment a DIFFERENT build is seen, "not cleared" on the
    // same version, and independence from the remote kill switch mechanics.

    func test_twoConsecutiveCrashes_recordsTheTrippingBuild() {
        _ = CallCapabilities.registerNativeSrtpCrashAndMaybeAutoReset(currentBuild: "100")
        let fired = CallCapabilities.registerNativeSrtpCrashAndMaybeAutoReset(currentBuild: "100")
        XCTAssertTrue(fired)
        XCTAssertEqual(CallCapabilities.nativeSrtpGuardTrippedBuild(), "100")
    }

    func test_guardPersistsAcrossARestartOfTheSameBuild() {
        _ = CallCapabilities.registerNativeSrtpCrashAndMaybeAutoReset(currentBuild: "100")
        _ = CallCapabilities.registerNativeSrtpCrashAndMaybeAutoReset(currentBuild: "100")
        XCTAssertEqual(CallCapabilities.loadPersistedAudioSrtpOverride(), false)

        // Simulate the next launch of the SAME build: reconcile must be a
        // no-op, leaving the tripped override in force.
        let cleared = CallCapabilities.reconcileNativeSrtpGuardForCurrentBuild(currentBuild: "100")
        XCTAssertFalse(cleared, "a restart of the SAME build must not un-trip the guard")
        XCTAssertEqual(CallCapabilities.loadPersistedAudioSrtpOverride(), false,
                       "the override must still be forced off on the same build")
        XCTAssertEqual(CallCapabilities.nativeSrtpGuardTrippedBuild(), "100")
    }

    func test_guardIsClearedOnceADifferentBuildIsSeen_andRetriesNativeSrtp() {
        _ = CallCapabilities.registerNativeSrtpCrashAndMaybeAutoReset(currentBuild: "100")
        _ = CallCapabilities.registerNativeSrtpCrashAndMaybeAutoReset(currentBuild: "100")
        XCTAssertEqual(CallCapabilities.loadPersistedAudioSrtpOverride(), false)

        let cleared = CallCapabilities.reconcileNativeSrtpGuardForCurrentBuild(currentBuild: "101")
        XCTAssertTrue(cleared, "a new build must clear a guard tripped by an OLDER build")
        XCTAssertNil(CallCapabilities.loadPersistedAudioSrtpOverride(),
                    "clearing must remove the override entirely -- back to the compiled default (native SRTP retried)")
        XCTAssertNil(CallCapabilities.nativeSrtpGuardTrippedBuild())
        XCTAssertEqual(CallCapabilities.nativeSrtpCrashStreak(), 0,
                       "the streak itself must also reset -- the new build gets a FRESH 2-crash budget")
    }

    func test_neverTripped_reconcileIsANoOp() {
        XCTAssertFalse(CallCapabilities.reconcileNativeSrtpGuardForCurrentBuild(currentBuild: "100"))
        XCTAssertNil(CallCapabilities.loadPersistedAudioSrtpOverride())
    }

    func test_freshStreakOnTheNewBuild_tripsTheGuardAgain() {
        // Build 100 trips, then build 101 is installed and the guard clears.
        _ = CallCapabilities.registerNativeSrtpCrashAndMaybeAutoReset(currentBuild: "100")
        _ = CallCapabilities.registerNativeSrtpCrashAndMaybeAutoReset(currentBuild: "100")
        _ = CallCapabilities.reconcileNativeSrtpGuardForCurrentBuild(currentBuild: "101")

        // A single crash on the new build must not immediately re-trip it.
        let firstCrashOnNewBuild = CallCapabilities.registerNativeSrtpCrashAndMaybeAutoReset(currentBuild: "101")
        XCTAssertFalse(firstCrashOnNewBuild)
        XCTAssertEqual(CallCapabilities.nativeSrtpCrashStreak(), 1)

        // A second, consecutive crash on the SAME new build trips it again.
        let secondCrashOnNewBuild = CallCapabilities.registerNativeSrtpCrashAndMaybeAutoReset(currentBuild: "101")
        XCTAssertTrue(secondCrashOnNewBuild)
        XCTAssertEqual(CallCapabilities.nativeSrtpGuardTrippedBuild(), "101")
    }

    func test_guardTripAndReconcile_neverTouchTheRemoteKillSwitchMechanics() {
        // The crash-streak guard and the per-call snapshot / remote
        // kill-switch forcing mechanism are independent signals: tripping
        // (or clearing) one must never touch the other's state.
        _ = CallCapabilities.beginNativeSrtpCallSnapshot(callId: "call-aaa")
        XCTAssertEqual(CallCapabilities.nativeSrtpCallSnapshot, true)

        _ = CallCapabilities.registerNativeSrtpCrashAndMaybeAutoReset(currentBuild: "100")
        _ = CallCapabilities.registerNativeSrtpCrashAndMaybeAutoReset(currentBuild: "100")
        _ = CallCapabilities.reconcileNativeSrtpGuardForCurrentBuild(currentBuild: "101")

        XCTAssertEqual(CallCapabilities.nativeSrtpCallSnapshot, true,
                       "the in-progress call's snapshot must be untouched by the guard tripping or clearing")
    }
}
