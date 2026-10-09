import SwiftUI
import UIKit
import BackgroundTasks
import Intents  // CarPlay/Siri state-of-the-art plan S1 — INStartCallIntent handoff
import QAudionEngine

/// W-NOCALLKIT — minimal UIApplicationDelegate, attached via
/// `@UIApplicationDelegateAdaptor`, to capture the STANDARD APNs device token.
/// Needed only in `CallsGate.callKitFreeMode` (the server sends an INCOMING_CALL
/// *alert* push to this token when the app is killed). The token is forwarded
/// via NotificationCenter so AppState can register it server-side without a
/// static AppState reference (same pattern as the BGTask bridge). When the flag
/// is OFF, AppState.handleApnsDeviceToken ignores the token → no behavior change.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02hhx", $0) }.joined()
        NotificationCenter.default.post(name: AppState.apnsTokenReceived, object: hex)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("[AppDelegate] APNs registration failed: \(error.localizedDescription)")
    }

    /// W-CONNWANT (piece 3) — the OS resumed/relaunched the app to deliver
    /// events for a background `URLSession` (`ReachabilityWakeService`'s
    /// reachability-wake session). Per Apple's contract this completion
    /// handler must be called once that session's delegate has finished
    /// processing everything it has for us — stash it; the service's own
    /// `urlSessionDidFinishEvents(forBackgroundURLSession:)` calls it.
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == ReachabilityWakeService.backgroundSessionIdentifier else {
            completionHandler()
            return
        }
        // Force the session (and its delegate hookup) to exist NOW — a
        // background relaunch is not guaranteed to have reached AppState's
        // normal `.onAppear` → `initialize()` → `start()` sequence yet.
        ReachabilityWakeService.shared.ensureSessionExists()
        ReachabilityWakeService.shared.pendingSystemCompletionHandler = completionHandler
    }
}

@main
struct QAudionApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    /// W441: App lock service. isLocked drives the gate overlay in body.
    @StateObject private var lockService = AppLockService()
    @Environment(\.scenePhase) private var scenePhase

    /// W441: reactive screenshot-protection flag, so the ZStack modifier
    /// re-evaluates when the user toggles the setting in PrivacySettings.
    ///
    /// W-APPSTORAGEDEADLOCK (2026-08-16) — this used to be `@AppStorage`
    /// bound to a plain UserDefaults key, which was two bugs at once: (1)
    /// the REAL value is Keychain-backed (`PrivacyGate.screenshotProtection-
    /// Enabled`, SECURITY M-28), so the plain-UserDefaults `@AppStorage`
    /// mirror never actually reflected the user's toggle; (2) @AppStorage
    /// installs SwiftUI's own UserDefaults-change-notification observer for
    /// the entire app lifetime (this is the App root, always live —
    /// unlike every other @AppStorage use here, which is scoped to a
    /// screen only instantiated while visible). Root-caused live via a
    /// real TestFlight crash: a background PushKit-driven launch deadlocked
    /// (EXC_CRASH/SIGKILL 0x8BADF00D, scene-update watchdog) with the main
    /// thread inside a SwiftUI ForEach/Observation graph update while a
    /// background thread's UserDefaults-change notification drove that same
    /// @AppStorage observer into the same AttributeGraph lock. Plain
    /// `@State`, seeded from the real Keychain value and kept in sync via
    /// `PrivacyGate.screenshotProtectionDidChange` (posted only from the
    /// one place that actually writes the value), sidesteps SwiftUI's
    /// reactive-UserDefaults machinery entirely.
    @State private var screenshotProtectionEnabled: Bool

    /// In-app language override — bumped by `AppLanguageManager.onLanguageChanged`,
    /// drives `.environment(\.locale, ...)` below so every SwiftUI `Text`/
    /// `LocalizedStringKey` re-resolves on a language switch. Deliberately
    /// NOT a `.id(...)`-based tree rebuild (an earlier version of this code
    /// did that and was caught in review: it reset `ContentView`'s own
    /// `@State` — `splashResolved`, every `NavigationStack` position,
    /// in-call screen state — on every language switch, kicking the user
    /// back to the splash screen and out of whatever they were doing the
    /// instant they picked a language). `AppLanguageManager`'s Bundle
    /// swizzle (installed below) separately covers every `String(localized:)`
    /// call site that ISN'T a SwiftUI view — plain Swift/Foundation code
    /// has no `\.locale` environment to read.
    @State private var currentLanguageCode = AppLanguageManager.effectiveLanguageCode

    init() {
        _screenshotProtectionEnabled = State(initialValue: PrivacyGate.screenshotProtectionEnabled)
        // W472 — install the native-crash catcher as the very first
        // thing, before any code that could crash. It persists a
        // backtrace on a signal / NSException; the report is flushed to
        // the W417 telemetry on the NEXT launch (see `flushPendingReport`
        // in `.onAppear`, which must run AFTER the stdout tee attaches).
        CrashReporter.installHandlers()

        // File transfer v2: the text a rejected file message becomes (WIRE_SPEC 12.7.1) is localised here, the engine has no
        // strings of its own. Before anything can record a message.
        FileV2PlaceholderText.install()

        // W-SRTPALWAYSON (2026-09-29/30, owner decision after live M150
        // verification — DTLS 1.3/TLS_AES_256_GCM_SHA384, SRTP
        // AEAD_AES_256_GCM, X25519MLKEM768, 0 handshake failures, 0
        // crashes) — native SRTP audio is now the unconditional compiled
        // default (`CallCapabilities.audioSrtpSendEnabled == true`) on
        // every build; the "Audio SRTP standard (WebRTC)" toggle that used
        // to live in Settings > Chiamate is gone, and with it the only
        // LOCAL, MANUAL way to turn this off. An install updating from
        // before this change may still have that toggle's old choice sitting
        // in `persistedOverrideKey` — this one-time migration discards it
        // (whatever it was) so it can never keep native SRTP off after the
        // update, then never touches that key again. See
        // `CallCapabilities.migrateAwayFromManualAudioSrtpOverrideIfNeeded()`'s
        // own doc for why this must run exactly once, before the seed below.
        CallCapabilities.migrateAwayFromManualAudioSrtpOverrideIfNeeded()

        // W-NATIVESRTPGUARDBUILD (cross-platform parity round 2, 2026-09-30,
        // owner decision) — reconcile a PRIOR crash-streak trip against the
        // build running right now, BEFORE the seed below loads it into
        // `audioSrtpDebugOverride`. A trip from an OLDER build (the build
        // has since been updated) is cleared here — native SRTP gets a
        // fresh 2-crash budget on the new build — while a trip from THIS
        // SAME build is left untouched. Mirrors Android's
        // `NativeSrtpCrashGuard.loadPersistedGuardOnInit`.
        if CallCapabilities.reconcileNativeSrtpGuardForCurrentBuild() {
            RTLog.warn("call", "native_srtp_guard cleared build_changed=1")
        }

        // W-NATIVESRTPPERSIST — load whatever is left in the persisted slot
        // BEFORE anything else that could start a call (same ordering
        // rationale as `CrashReporter.installHandlers()` above, and the
        // Android counterpart's `QAudionApplication.onCreate` ordering —
        // spec section B). Now that the migration above has run (and the
        // reconcile above has cleared any stale, older-build trip), the
        // only thing that can ever be sitting here is a `false` the
        // crash-streak safety net below persisted on a PRIOR launch of
        // THIS SAME build — `nil` (the normal case: fresh install, no
        // crash streak has ever fired, or the build just changed) leaves
        // `audioSrtpDebugOverride` at its own default (`nil` -> compiled
        // default, i.e. ON).
        CallCapabilities.audioSrtpDebugOverride = CallCapabilities.loadPersistedAudioSrtpOverride()

        // W-NATIVESRTPCRASHGUARD — a crash (or an OS kill) while a
        // native-SRTP call was in progress leaves its breadcrumb
        // call-context in place (`CallService.endCall()` never ran to clear
        // it). Two such crashes IN A ROW force native SRTP off for this
        // device/build — persisted AND live — so a broken native path
        // cannot keep crashing every call the user makes. This is the one
        // local safety net that survives the toggle's removal
        // (W-SRTPALWAYSON): it is automatic, not a manual control, and
        // there is deliberately no UI to turn it back on again — a device
        // that trips it stays on the legacy sealed-audio path until a
        // future build changes that (see the reconcile call above for the
        // one AUTOMATIC way it comes back). Must run before any call path
        // AND before the context is cleared below, and does not need the
        // stdout tee (`RTLog` records into the ring directly).
        // W-MEDIAATACCEPT (option b) — I9/§10: `CrashGuardDecisions
        // .countsTowardStreak` replaces the two raw `.contains` checks —
        // with the media plane no longer built at ring, a crash while
        // merely RINGING (phase "ring", no PeerConnection yet) must not
        // advance this streak; only "pc"/"media" (or the one-release
        // "snapshot" grandfather value) do. See that function's doc.
        if CrashReporter.hasPendingCrashReport(),
           let ctx = CrashBreadcrumbs.lastCallContext(),
           CrashGuardDecisions.countsTowardStreak(context: ctx) {
            if CallCapabilities.registerNativeSrtpCrashAndMaybeAutoReset() {
                RTLog.warn("call", "native_srtp_guard tripped build=\(CallCapabilities.currentAppBuild()) reason=crash_streak n=2")
            }
        }
        // Consumed (whether or not it triggered the guard above) — a stale
        // "in_call=1" must not survive to be misread by a LATER, unrelated
        // crash (e.g. one on the home screen).
        CrashBreadcrumbs.clearCallContext()

        // In-app language override — must install its Bundle swizzle before
        // WindowGroup's first `body` evaluation (right after this init()
        // returns), so every LocalizedStringKey lookup in the very first
        // frame already resolves against the overridden language.
        AppLanguageManager.installOverrideIfNeeded()
        // No DispatchQueue/Task hop needed: `onLanguageChanged` is only
        // ever invoked from `AppLanguageManager.setOverride`, itself
        // @MainActor-isolated (the class is `@MainActor`), so every call
        // already runs on the main thread by construction — wrapping it
        // would also force this closure's captured `Binding` through a
        // `@Sendable` boundary (DispatchQueue/Task closures are
        // `@Sendable` under Swift 6 strict concurrency) for no benefit.
        let languageBinding = $currentLanguageCode
        AppLanguageManager.onLanguageChanged = {
            languageBinding.wrappedValue = AppLanguageManager.effectiveLanguageCode
        }

        // W-DBOPENRECOVER (2026-09-01) — a local-database open/migration
        // failure no longer traps the process (audit memory
        // reference_ios_stability_audit_2026_09_01, P0; ladder in
        // DatabaseOpenRecoveryPolicy). Installed HERE, before `AppState()`
        // is built (StateObject is lazy) and therefore before the first
        // `QAudionDatabase.shared` access anywhere, so a quarantine/degrade
        // decided during that first open reaches the ring buffer via RTLog
        // even when it happens before the stdout tee attaches in `.onAppear`,
        // and the sealed telemetry when consent is on. Same closure shape as
        // `controller.videoTelemetry` in AppState. Tag "chat": the file IS
        // the chat store, and only tags on scripts/ship-ios-logs.py's
        // TAG_SCOPE_PREFIXES survive the shipper's gate (a new "db" tag
        // would be dropped whole); the line's numeric tail is the part the
        // redactor lets through. Must not touch the database itself.
        QAudionDatabase.onOpenOutcome = { outcome in
            let line = DatabaseOpenRecoveryPolicy.logLine(for: outcome)
            if outcome.isDegraded {
                RTLog.error("chat", line)
            } else {
                RTLog.warn("chat", line)
            }
            TelemetryService.shared.emit(
                kind: "db.open_recovery",
                attrs: DatabaseOpenRecoveryPolicy.telemetryAttributes(for: outcome))
        }

        // W-BGK: BGAppRefreshTask must be registered before the app finishes
        // launching (Apple requirement). We forward it via NotificationCenter
        // so AppState.handleWsKeepaliveTask() can access the live auth state
        // without a static reference to AppState.
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "com.bcrypto.qaudion.ws-keepalive",
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            NotificationCenter.default.post(
                name: AppState.bgWsKeepalive,
                object: refreshTask
            )
        }
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    // In-app language override — SwiftUI re-evaluates every
                    // Text/LocalizedStringKey that reads this environment
                    // value on change, WITHOUT discarding ContentView's own
                    // @State (splash/navigation/in-call screen position).
                    // Scoped to ContentView only, not the outer ZStack, so
                    // it never touches AppLockGateView's own state below.
                    .environment(\.locale, Locale(identifier: currentLanguageCode))
                    .environmentObject(appState)
                    // Entitlements Task 5 (whole-phase-review finding I4,
                    // 2026-08-17) — `capabilityGate` is a plain `lazy var` on
                    // `AppState`, a SEPARATE `ObservableObject`. SwiftUI does
                    // NOT forward a nested ObservableObject's
                    // `objectWillChange` through its parent automatically, so
                    // a view reading `appState.capabilityGate.isUnlocked(...)`
                    // would never re-render when `claims` changes (e.g. right
                    // after a successful invite-code redemption, or a
                    // background `refresh()` completing). Injecting
                    // `capabilityGate` as its OWN environment object,
                    // alongside `appState`, lets any child view declare
                    // `@EnvironmentObject var capabilityGate: CapabilityGate`
                    // directly and get correct, live updates — see
                    // `CapabilityGate.claims`'s own doc for the full
                    // analysis. This must travel together with `appState`'s
                    // own injection since both come from the exact same
                    // `AppState` instance.
                    .environmentObject(appState.capabilityGate)
                    // W441: hide app content from app-switcher snapshots when
                    // screenshot protection is on (iOS 15+ system API).
                    .privacySensitive(screenshotProtectionEnabled)
                    .allowsHitTesting(!lockService.isLocked)

                if lockService.isLocked {
                    AppLockGateView(lockService: lockService)
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: lockService.isLocked)
            .onChange(of: scenePhase) { newPhase in
                handleScenePhase(newPhase)
            }
            // Pending phone-number transfer: the state is dropped when the app locks, nothing is read
            // while it is locked, and the list is read again from the server when it unlocks.
            .onChange(of: lockService.isLocked) { locked in
                appState.phoneTransferNotice.setLocked(locked)
                if !locked { appState.refreshPhoneTransferNotice() }
            }
            // W-EMAILVERIFYLINK — Universal Link entry point (parity with
            // Android's App Link intent-filter). associated-domains in
            // QAudion.entitlements is what makes the OS route the tapped
            // link here instead of Safari; AppState does the actual
            // host/path/token parsing so this stays a one-liner.
            .onOpenURL { url in
                appState.handleIncomingUniversalLink(url)
            }
            // CarPlay/Siri state-of-the-art plan S1 — "Hey Siri, chiama X su
            // Q-Audion" (docs/superpowers/plans/2026-09-06-carplay-state-of
            // -the-art.md). QAudionIntents/IntentHandler.swift resolves the
            // INStartCallIntent and hands off here; the activity type MUST
            // be the literal Intents class name, matching Info.plist's
            // NSUserActivityTypes entry.
            .onContinueUserActivity(NSStringFromClass(INStartCallIntent.self)) { userActivity in
                appState.handleSiriStartCall(userActivity)
            }
            .sheet(isPresented: Binding(
                get: { appState.pendingEmailVerifyToken != nil },
                set: { if !$0 { appState.pendingEmailVerifyToken = nil } }
            )) {
                // `.sheet`'s content inherits the environment of the view
                // this modifier is attached to (the ZStack) — appState is
                // only injected further down, onto ContentView() — so it
                // must be added explicitly here too, or the view's
                // `@EnvironmentObject var appState: AppState` fatals at
                // presentation time with "No ObservableObject found".
                if let token = appState.pendingEmailVerifyToken {
                    EmailVerifyConfirmView(token: token) {
                        appState.pendingEmailVerifyToken = nil
                    }
                    .environmentObject(appState)
                }
            }
            .onAppear {
                // W416: ring-buffer stdout tee from launch for live telemetry.
                RuntimeLogSink.shared.attachStdoutTee()
                // W472 — flush any crash report from the previous launch.
                // MUST be after attachStdoutTee() so the prints are
                // captured by the W417 telemetry and shipped to the server.
                CrashReporter.flushPendingReport()
                // W-FLAGS — start the remote feature-flag poll. Primitive-only
                // signature (CLAUDE.md §16): a compile-time flags URL String,
                // NO AppState. Plain URLSession (public, un-authed, NOT the
                // pinned voip host) — see FeatureFlags.swift header. Placed
                // after attachStdoutTee() so the "[FeatureFlags] fetched: ..."
                // line is captured by the W417 telemetry. Fire-and-forget:
                // never blocks launch, fails safe to the compiled defaults.
                FeatureFlags.shared.start(flagsUrl: "https://dash.bcrypto.com/flags.json")
                appState.initialize()
                // W-MK — register the MetricKit subscriber. MUST be after
                // attachStdoutTee() so the per-payload prints are captured
                // by the W417 telemetry, same rationale as the crash flush
                // above. W-MKCRASHTELEMETRY (this task) moved this AFTER
                // appState.initialize() (was between the crash flush and
                // FeatureFlags.start above): initialize() is what calls
                // TelemetryService.shared.start(...), and MetricKitDiagnostics
                // now also calls TelemetryService.shared.emit(kind: "app.crash",
                // ...) for a crash/hang diagnostic. `emit()` silently drops an
                // event until TelemetryService.started flips true, so
                // registering the MetricKit subscriber (whose didReceive could
                // in principle fire immediately) before that flip would risk
                // losing exactly the event this task adds. Registering a few
                // synchronous statements later, still in the same runloop
                // turn, costs nothing — MetricKit queues payloads until a
                // subscriber exists.
                MetricKitDiagnostics.start()
                // W441: sweep expired messages immediately + every 60s.
                EphemeralMessageJanitor.shared.start()
                // W441: listen for OS screenshot events and warn in the log.
                registerScreenshotObserver()
                // W-SCREENRECDETECT (2026-09-02): listen for an active
                // screen-recording/mirroring session and warn in the log,
                // same gate + scheme as the screenshot observer above.
                registerScreenRecordingObserver()
                // W-APPSTORAGEDEADLOCK — keep the root-level @State in sync
                // with the real (Keychain-backed) value without SwiftUI's
                // own @AppStorage/UserDefaults-observer machinery. See
                // screenshotProtectionEnabled's doc for why this replaced
                // @AppStorage. PrivacyGate.setScreenshotProtectionEnabled is
                // the only writer, so this notification is the only source.
                NotificationCenter.default.addObserver(
                    forName: .screenshotProtectionDidChange,
                    object: nil,
                    queue: .main
                ) { _ in
                    screenshotProtectionEnabled = PrivacyGate.screenshotProtectionEnabled
                }
            }
        }
    }

    // MARK: - Scene phase

    private func handleScenePhase(_ phase: ScenePhase) {
        RTLog.info("call", "W-CALLFG-DIAG handleScenePhase(\(phase)) — isInCall=\(appState.isInCall) callState=\(appState.callState) callWasAnswered=\(appState.callWasAnswered) groupCallControllerState=\(appState.groupCallControllerState) isLocked=\(lockService.isLocked)")
        // Group calls v2 (spec 4.6): a backgrounded app unsubscribes every remote
        // video and pauses its own video publish; audio is never touched.
        switch phase {
        case .background: appState.groupCallController?.setAppBackgrounded(true)
        case .active: appState.groupCallController?.setAppBackgrounded(false)
        default: break
        }
        switch phase {
        case .background:
            lockService.handleBackground()
        case .active:
            // Active call bypasses the lock so in-call controls stay reachable.
            // SECURITY M-25/L-7: pass the real callState so the bypass only
            // applies to an answered/established call (.active/.encrypted),
            // NOT a mere .ringing (pre-answer) state — otherwise anyone
            // holding the device could dismiss the lock by triggering an
            // incoming call without answering it.
            //
            // W-CALLFG (2026-07-27) — `isInCall` is 1:1-only (group calls use
            // the SEPARATE `groupCallControllerState` signal, never `isInCall`
            // — see AppState's own busy-check that treats them as parallel
            // conditions). Before this fix, a live GROUP call never reached
            // `bypassForCall` at all, so `handleForeground()`'s grace-window
            // path could re-lock the app (biometric prompt) mid-group-call —
            // the same friction already solved for 1:1, just never extended.
            let groupActive: Bool = {
                switch appState.groupCallControllerState {
                case .connecting, .active: return true
                case .idle, .failed: return false
                }
            }()
            if appState.isInCall || groupActive {
                lockService.bypassForCall(
                    callState: appState.callState,
                    answered: appState.callWasAnswered,
                    groupCallActive: groupActive
                )
            } else {
                lockService.handleForeground()
            }
            // CarPlay/Siri state-of-the-art plan S2 — catch a message the
            // Intents Extension queued while merely backgrounded (not just
            // on cold launch, see AppState.initialize()'s own call).
            appState.drainSiriOutbox()
            appState.refreshSiriMessageCache()
            // Pending phone-number transfers: read again on a return to the foreground (a locked
            // app reads after the unlock, see the `isLocked` observer).
            if !lockService.isLocked { appState.refreshPhoneTransferNotice(throttled: true) }
        default:
            break
        }
    }

    // MARK: - Screenshot detection

    private func registerScreenshotObserver() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.userDidTakeScreenshotNotification,
            object: nil,
            queue: .main
        ) { _ in
            guard PrivacyGate.screenshotProtectionEnabled else { return }
            RTLog.warn("privacy", "screenshot taken while protection is active")
        }
    }

    /// W-SCREENRECDETECT (2026-09-02) — sibling to the screenshot observer
    /// above. The screenshot notification is one-shot (a still capture);
    /// `UIScreen.capturedDidChangeNotification` is Apple's own API for a
    /// LIVE capture session (Control Center screen recording, AirPlay/
    /// QuickTime device mirroring — `isCaptured` does not distinguish the
    /// two, per Apple's own doc) and had no listener at all before this fix
    /// (audit memory reference_ios_stability_audit_2026_09_01, P2 "privacy
    /// overlay default OFF" item). `UIScreen.main` matches this codebase's
    /// existing convention (`AboutSettingsScreen.swift`); the actual
    /// log-or-not decision is `ScreenCaptureAlertPolicy.shouldLog`, pure and
    /// unit-tested, so this closure is just wiring.
    private func registerScreenRecordingObserver() {
        NotificationCenter.default.addObserver(
            forName: UIScreen.capturedDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            guard ScreenCaptureAlertPolicy.shouldLog(
                protectionEnabled: PrivacyGate.screenshotProtectionEnabled,
                isCaptured: UIScreen.main.isCaptured
            ) else { return }
            RTLog.warn("privacy", "screen recording active while protection is active")
        }
    }
}
