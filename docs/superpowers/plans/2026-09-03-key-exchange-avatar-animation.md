# Key-exchange avatar ring animation (iOS port) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the Android `KeyExchangeRing` feature to SwiftUI, replacing `AvatarHalo` on `OutgoingCallScreen`/`IncomingCallScreen` with a single-segment PQC ring that fills as the real handshake progresses, using the same visual identity (colours, "assembled from real ingredients" idea) — adapted to real iOS constraints, not blindly translated.

**Architecture:** One new stateless-from-the-outside SwiftUI `View` (`KeyExchangeRing`) driven by `TimelineView(.animation(paused:))` — the SwiftUI-native equivalent of Android's bounded `withFrameNanos` loop, no custom clock/coroutine needed. `OutgoingCallScreen` derives the ring's phase as a pure computed property from its existing `State` enum (no new local timer). `IncomingCallScreen`'s ring never animates — grounded in the discovered fact that this screen tears down before accept even finishes processing and has no client-side ring timeout.

**Tech Stack:** Swift, SwiftUI (`Canvas`, `GraphicsContext`, `TimelineView`), XCTest for the one pure function this plan extracts.

**No local build available in this environment.** Every step that would normally run `xcodebuild`/`swift test` is replaced with "cross-reference the cited real code in this repo and confirm the API shape matches" — the actual first compile happens via CI or the user's own Xcode, per explicit user direction (2026-09-03). Implementers must still self-review carefully; "I can't verify this compiles" is not license to be careless about matching real, already-used APIs in this codebase.

**Design doc:** `docs/superpowers/specs/2026-09-03-key-exchange-avatar-animation-design.md` — read it first for the full reasoning, especially why iOS has no calibration/self-tuning step (Android's, because a real incident was measured there; no iOS incident exists, and `TimelineView(paused:)` already gives the "stops for good" guarantee for free) and why the fingerprint/PSK pill on `OutgoingCallScreen` show immediately rather than animating in character-by-character (that screen is proven to survive exactly one render frame at `.connected` — `ContentView.swift:426-433`'s `W-OUTGOINGDOT3` comment — so a multi-frame reveal animation would never be visible; Android's equivalent reveal DOES get real wall-clock time there because Android's outgoing→in-call transition is a full Activity swap, not a same-frame SwiftUI view swap).

---

## File Structure

- Create `QAudionApp/Views/Call/Components/KeyExchangeRing.swift` — the ring view + its `Phase` enum + the one extracted pure function (`ringPhase(for:)`).
- Create `QAudionAppTests/KeyExchangeRingTests.swift` (or the equivalent existing unit-test target — see Task 5 for how to find its exact name/location before creating the file) — XCTest for `ringPhase(for:)`.
- Modify `QAudionApp/Views/Call/OutgoingCallScreen.swift` — replace `AvatarHalo` with `KeyExchangeRing`, add `pskMethodLabel`/`sessionFingerprint` params, add the PSK pill + fingerprint text.
- Modify `QAudionApp/Views/Call/IncomingCallScreen.swift` — replace the two stacked `AvatarHalo` instances with one settled `KeyExchangeRing`.
- Modify `QAudionApp/Views/ContentView.swift` — thread real `pskMethodLabel`/`sessionFingerprint` values into `makeOutgoingScreen()`.
- Modify `QAudionApp/Views/Call/LiveInCallScreen.swift` — widen `sessionFingerprintFromKey`'s access so `ContentView` can reuse it (one-word change, no logic change).

No changes to `AppState.swift`, `InCallScreen.swift`, `LiveInCallScreen`'s own `body`, `CallMeshBackground.swift`, or any group-call file — all out of scope per the design doc.

---

### Task 1: `KeyExchangeRing` component

**Files:**
- Create: `QAudionApp/Views/Call/Components/KeyExchangeRing.swift`

- [ ] **Step 1: Write the component**

Create `KeyExchangeRing.swift`:

```swift
import SwiftUI

/// Ring around the call avatar that fills as the real PQC key exchange for
/// THIS call is confirmed — replaces the static-in-name-but-actually-
/// perpetually-pulsing `AvatarHalo` on the ring screens. See
/// `docs/superpowers/specs/2026-09-03-key-exchange-avatar-animation-design.md`
/// for the full design.
///
/// Always a SINGLE segment — iOS has no local earbud-hardware media path
/// (`earbudHwVerified`/`earbudActive` are hardcoded `false` at their one
/// call site, `LiveInCallScreen.swift:320-321`), so there is nothing real
/// for a second segment to represent. Do not add one.
///
/// Driven by `TimelineView(.animation(paused: phase == .settled))` — when
/// paused, SwiftUI does not invoke the closure at all, which is the direct
/// SwiftUI analogue of Android's bounded `withFrameNanos` loop that exits
/// for good once settled. No custom clock, no calibration/self-tuning: no
/// iOS incident analogous to Android's A36 frame-skip has ever been
/// measured, so there is nothing to calibrate against — see the design
/// doc's "Bounded animation" section for why this is a deliberate scope
/// reduction, not an oversight.
struct KeyExchangeRing: View {
    enum Phase: Equatable {
        case handshaking
        case crystallizing
        case settled
    }

    let phase: Phase
    /// True once a real PQC round-trip is known to be in flight for this
    /// call. On `OutgoingCallScreen` this is true from the moment the ring
    /// screen appears (`.dialing` and `.handshaking` both mean the
    /// handshake is already running — see the design doc). On
    /// `IncomingCallScreen` this is always false, because that screen's
    /// ring is always constructed with `phase: .settled` and no real
    /// handshake data exists while merely ringing.
    let confirmed: Bool
    var ringSize: CGFloat = 220

    @State private var confirmedAt: Date?
    @State private var crystallizeStartedAt: Date?

    private let ringPQCColor = Color(red: 0x4C / 255.0, green: 0x8D / 255.0, blue: 0xFF / 255.0)
    private let ringGuideColor = Color(red: 0x8C / 255.0, green: 0xB4 / 255.0, blue: 0xFF / 255.0)
    private let strokeWidth: CGFloat = 7
    private let fillDurationSeconds: Double = 0.28
    private let crystallizeDurationSeconds: Double = 0.32

    var body: some View {
        TimelineView(.animation(paused: phase == .settled)) { context in
            Canvas { ctx, size in
                draw(ctx: &ctx, size: size, now: context.date)
            }
            .frame(width: ringSize, height: ringSize)
        }
        .onAppear {
            if confirmed && confirmedAt == nil { confirmedAt = Date() }
            if phase == .crystallizing && crystallizeStartedAt == nil { crystallizeStartedAt = Date() }
        }
        .onChange(of: confirmed) { newValue in
            if newValue && confirmedAt == nil { confirmedAt = Date() }
        }
        .onChange(of: phase) { newPhase in
            if newPhase == .crystallizing && crystallizeStartedAt == nil {
                crystallizeStartedAt = Date()
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(ctx: inout GraphicsContext, size: CGSize, now: Date) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) * 0.455

        // Dim track — always drawn, same shape as the fill arc.
        var track = Path()
        track.addArc(center: center, radius: radius,
                     startAngle: .degrees(-90), endAngle: .degrees(262),
                     clockwise: false)
        ctx.stroke(track, with: .color(ringPQCColor.opacity(0.16)),
                   style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))

        // Fill — animates 0 -> full once `confirmed` flips true.
        if let confirmedAt {
            let progress = min(1.0, now.timeIntervalSince(confirmedAt) / fillDurationSeconds)
            let endAngle = -90.0 + 352.0 * progress
            var fill = Path()
            fill.addArc(center: center, radius: radius,
                        startAngle: .degrees(-90), endAngle: .degrees(endAngle),
                        clockwise: false)
            ctx.stroke(fill, with: .color(ringPQCColor),
                       style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
        }

        // Slowly rotating dashed guide ring — only while actively handshaking.
        if phase == .handshaking {
            let guideRadius = radius + 14
            let rotationDegrees = now.timeIntervalSinceReferenceDate * 12
                .truncatingRemainder(dividingBy: 360)
            ctx.translateBy(x: center.x, y: center.y)
            ctx.rotate(by: .degrees(rotationDegrees))
            ctx.translateBy(x: -center.x, y: -center.y)
            var guide = Path()
            guide.addArc(center: center, radius: guideRadius,
                        startAngle: .degrees(0), endAngle: .degrees(360),
                        clockwise: false)
            ctx.stroke(guide, with: .color(ringGuideColor.opacity(0.28)),
                       style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [4, 14]))
        }

        // Crystallize pulse — one soft fading white ring, fires once.
        if phase == .crystallizing, let crystallizeStartedAt {
            let progress = min(1.0, now.timeIntervalSince(crystallizeStartedAt) / crystallizeDurationSeconds)
            var pulse = Path()
            pulse.addArc(center: center, radius: radius - strokeWidth,
                        startAngle: .degrees(0), endAngle: .degrees(360),
                        clockwise: false)
            ctx.stroke(pulse, with: .color(.white.opacity((1 - progress) * 0.7)),
                       style: StrokeStyle(lineWidth: 2))
        }
    }
}

/// Pure mapping from `OutgoingCallScreen.State` to the ring's phase —
/// extracted as a free function (not a method on either type) so it is
/// unit-testable with plain XCTest, no SwiftUI/view-hosting needed.
/// Mirrors Android's `KeyExchangeRingModel.kt` split between pure logic
/// and the Compose view.
///
/// `.dialing` and `.handshaking` both map to `.handshaking` — the PQC
/// round-trip is already in flight during `.dialing` too, per the shared
/// cross-platform wire protocol (see the design doc). `.rekeying` is
/// documented dead in production wiring today
/// (`ContentView.swift:424-451`) but is mapped to `.settled` rather than
/// crashing or being left unhandled, in case that ever changes.
func ringPhase(for state: OutgoingCallScreen.State) -> KeyExchangeRing.Phase {
    switch state {
    case .dialing, .handshaking:
        return .handshaking
    case .connected:
        return .crystallizing
    case .rekeying, .ended:
        return .settled
    }
}

#Preview("Handshaking") {
    ZStack {
        Color.black.ignoresSafeArea()
        KeyExchangeRing(phase: .handshaking, confirmed: true)
    }
}

#Preview("Crystallizing") {
    ZStack {
        Color.black.ignoresSafeArea()
        KeyExchangeRing(phase: .crystallizing, confirmed: true)
    }
}

#Preview("Settled, unconfirmed (IncomingCallScreen's case)") {
    ZStack {
        Color.black.ignoresSafeArea()
        KeyExchangeRing(phase: .settled, confirmed: false)
    }
}
```

- [ ] **Step 2: Cross-reference the Canvas/GraphicsContext API against real, already-compiling code in this repo**

Read `QAudionApp/Views/Call/InCallScreen.swift` around lines 2295-2370 (`cryptoEngineMeterRow`/`drawCipherTube`) and `QAudionApp/Views/Call/Components/CallMeshBackground.swift` in full. Confirm every API used above — `TimelineView(.animation(paused:))`, `Canvas { ctx, size in }`, `GraphicsContext.stroke(_:with:style:)`, `GraphicsContext.fill(_:with:)`, `Path.addArc(center:radius:startAngle:endAngle:clockwise:)`, `StrokeStyle(lineWidth:lineCap:dash:)`, `GraphicsContext.translateBy`/`.rotate(by:)` — appears with the same signature shape somewhere in one of those two files or is a standard, long-stable SwiftUI/CoreGraphics API (all of the above are; `Path.addArc` and `StrokeStyle` predate `Canvas` itself). If anything looks inconsistent with this codebase's own usage, fix it to match the established pattern before moving on — do not guess a different API shape.

- [ ] **Step 3: Self-review — no compiler available, so this is a careful manual read**

- Confirm `Phase` has exactly three cases and `ringPhase(for:)` is exhaustive over `OutgoingCallScreen.State`'s five cases (the compiler would normally catch a missing case — here, count them by hand: `.dialing, .handshaking, .connected, .rekeying, .ended` — all five appear on the left of the `switch`).
- Confirm there is only ONE `TimelineView` in this file (matches the "one bounded clock" requirement) and its `paused:` argument is exactly `phase == .settled`.
- Confirm nothing in `draw(ctx:size:now:)` allocates per-call in a way that would be expensive if it somehow ran every frame indefinitely (it shouldn't, since `paused` stops it, but the draw body itself should still be cheap: it is — a handful of `Path` constructions and `stroke`/`fill` calls, no loops, matching the design doc's performance intent even without Android's explicit calibration).

- [ ] **Step 4: Commit**

```bash
cd "D:/users/f10379a/DEV APP/BCRYPTO/apps/qaudion-ios"
git add QAudionApp/Views/Call/Components/KeyExchangeRing.swift
git -c commit.gpgsign=false commit -m "feat(key-exchange-ring): KeyExchangeRing SwiftUI component"
```

IMPORTANT: use `git add` with the exact file path above, never `git add -A`/`git add .` — verify with `git status --short` first that nothing else is unexpectedly staged (this repo's working tree should be clean at the start of this task, but check).

---

### Task 2: Wire into `OutgoingCallScreen`

**Files:**
- Modify: `QAudionApp/Views/Call/OutgoingCallScreen.swift`

- [ ] **Step 1: Add the new parameters**

Find (in the `init`'s parameter list and the matching stored properties):
```swift
    let peerDisplayName: String
    let avatarUrl: URL?
    let state: State
    let elapsedSeconds: Int
    let errorMessage: String?
    /// Numero interno PBX del destinatario (es. "103").
    /// Priorità assoluta nel cerchietto dell'avatar.
    let peerShortNumber: String?
    let onHangup: () -> Void

    init(peerDisplayName: String,
         avatarUrl: URL? = nil,
         state: State = .dialing,
         elapsedSeconds: Int = 0,
         errorMessage: String? = nil,
         peerShortNumber: String? = nil,
         onHangup: @escaping () -> Void) {
        self.peerDisplayName = peerDisplayName
        self.avatarUrl = avatarUrl
        self.state = state
        self.elapsedSeconds = elapsedSeconds
        self.errorMessage = errorMessage
        self.peerShortNumber = peerShortNumber
        self.onHangup = onHangup
    }
```

Replace with:
```swift
    let peerDisplayName: String
    let avatarUrl: URL?
    let state: State
    let elapsedSeconds: Int
    let errorMessage: String?
    /// Numero interno PBX del destinatario (es. "103").
    /// Priorità assoluta nel cerchietto dell'avatar.
    let peerShortNumber: String?
    /// PSK binding method label ("NFC"/"QR"/"KMS"/…), non-nil only once a
    /// real PSK was mixed into THIS call's session key — mirrors
    /// `InCallScreen.KeyInfo.pskMethodLabel`. Shown as an immediate
    /// `MetaPill`, not an animated reveal — see this file's kdoc-equivalent
    /// note on `ringPhase` below for why.
    let pskMethodLabel: String?
    /// Session-key fingerprint, formatted like `LiveInCallScreen
    /// .sessionFingerprintFromKey` — non-nil only once the real PQC session
    /// key exists. Shown as an immediate `Text`, not an animated reveal.
    let sessionFingerprint: String?
    let onHangup: () -> Void

    init(peerDisplayName: String,
         avatarUrl: URL? = nil,
         state: State = .dialing,
         elapsedSeconds: Int = 0,
         errorMessage: String? = nil,
         peerShortNumber: String? = nil,
         pskMethodLabel: String? = nil,
         sessionFingerprint: String? = nil,
         onHangup: @escaping () -> Void) {
        self.peerDisplayName = peerDisplayName
        self.avatarUrl = avatarUrl
        self.state = state
        self.elapsedSeconds = elapsedSeconds
        self.errorMessage = errorMessage
        self.peerShortNumber = peerShortNumber
        self.pskMethodLabel = pskMethodLabel
        self.sessionFingerprint = sessionFingerprint
        self.onHangup = onHangup
    }
```

- [ ] **Step 2: Add the computed ring phase**

Add this computed property inside the `struct OutgoingCallScreen` body, near the top (right after the `init`, before `var body`):

```swift
    /// Pure function of `state` — no local timer, see the implementation
    /// plan's Task 2 note on why (this screen is proven to survive exactly
    /// one render frame at `.connected`, `ContentView.swift:426-433`).
    private var ringPhase: KeyExchangeRing.Phase {
        ringPhase(for: state)
    }

    /// True whenever a handshake round-trip is genuinely in flight —
    /// everything except the terminal `.ended` state (and `.rekeying`,
    /// which is dead in production wiring today but treated the same way
    /// for safety).
    private var ringConfirmed: Bool {
        state == .dialing || state == .handshaking || state == .connected
    }
```

`ringPhase(for:)` is a plain top-level Swift function (no enclosing type/namespace — Task 1 created it exactly that way), so it is called unqualified. This shadows the computed-property name (`ringPhase` the property vs `ringPhase(for:)` the function) — Swift resolves this correctly by argument label, but if that reads confusingly during review, that's a legitimate naming nitpick to flag, not a correctness bug.

- [ ] **Step 3: Replace the `AvatarHalo` call site**

Find:
```swift
                    ZStack {
                        AvatarHalo(color: extras.pqcAccent, diameter: 240)
                        QAudionAvatar(displayName: peerDisplayName,
                                      imageURL: avatarUrl,
                                      size: 160,
                                      shortNumber: peerShortNumber)
                    }
                    .frame(width: 240, height: 240)
                    .padding(.bottom, 24)
```

Replace with:
```swift
                    ZStack {
                        KeyExchangeRing(phase: ringPhase, confirmed: ringConfirmed, ringSize: 240)
                        QAudionAvatar(displayName: peerDisplayName,
                                      imageURL: avatarUrl,
                                      size: 160,
                                      shortNumber: peerShortNumber)
                    }
                    .frame(width: 240, height: 240)
                    .padding(.bottom, 24)

                    if let fp = sessionFingerprint {
                        Text(fp)
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .tracking(2)
                            .foregroundStyle(ringPQCColorForText)
                            .padding(.bottom, 6)
                    }
```

Add a small private colour helper right below the new computed properties from Step 2 (so the fingerprint text matches the ring's own blue without duplicating the raw hex a third time in this file):
```swift
    private var ringPQCColorForText: Color {
        Color(red: 0x8F / 255.0, green: 0xD3 / 255.0, blue: 0xFF / 255.0)
    }
```

- [ ] **Step 4: Add the PSK pill**

Find:
```swift
                    HStack(spacing: 8) {
                        MetaPill("PQC NEGOTIATING", accent: extras.pqcAccent)
                        MetaPill("VOICE TRUST · ENROLLED", accent: extras.success, filled: true)
                        MetaPill("LOW LATENCY · 48ms", accent: extras.warning)
                    }
                    .padding(.bottom, 22)
```

Replace with:
```swift
                    HStack(spacing: 8) {
                        MetaPill("PQC NEGOTIATING", accent: extras.pqcAccent)
                        MetaPill("VOICE TRUST · ENROLLED", accent: extras.success, filled: true)
                        MetaPill("LOW LATENCY · 48ms", accent: extras.warning)
                        if let method = pskMethodLabel {
                            MetaPill("PSK · \(method)", accent: pskPillColor, filled: true)
                        }
                    }
                    .padding(.bottom, 22)
```

Add the second colour helper alongside `ringPQCColorForText`:
```swift
    private var pskPillColor: Color {
        Color(red: 0x7C / 255.0, green: 0x6F / 255.0, blue: 0xFF / 255.0)
    }
```

- [ ] **Step 5: Cross-check against Task 1's component**

Read the current `KeyExchangeRing.swift` (from Task 1, already committed) once more and confirm `Phase`/`ringPhase(for:)`'s exact spelling matches exactly what this task just wrote — a typo here (e.g. `KeyExchangeRing.Phase` vs some other name) would only be caught by a compiler, which isn't available, so read both files side by side and confirm the names line up character-for-character.

- [ ] **Step 6: Commit**

```bash
cd "D:/users/f10379a/DEV APP/BCRYPTO/apps/qaudion-ios"
git add QAudionApp/Views/Call/OutgoingCallScreen.swift
git -c commit.gpgsign=false commit -m "feat(call): OutgoingCallScreen uses KeyExchangeRing instead of AvatarHalo"
```

---

### Task 3: Wire into `IncomingCallScreen`

**Files:**
- Modify: `QAudionApp/Views/Call/IncomingCallScreen.swift`

- [ ] **Step 1: Replace the double `AvatarHalo`**

Find:
```swift
                ZStack {
                    AvatarHalo(color: extras.success,    diameter: 240)
                    AvatarHalo(color: extras.pqcAccent,  diameter: 200)
                    QAudionAvatar(displayName: peerDisplayName,
                                  imageURL: avatarUrl,
                                  size: 160,
                                  shortNumber: peerShortNumber)
                }
                .frame(width: 240, height: 240)
                .padding(.bottom, 28)
```

Replace with:
```swift
                ZStack {
                    // Always .settled/unconfirmed — this screen is torn
                    // down before Accept even finishes processing
                    // (appState.incomingCallRingVisible clears BEFORE
                    // callState leaves .ringing) and there is no
                    // client-side timeout on a 1:1 incoming ring, so an
                    // animating ring here would have no real progress to
                    // show and no bound on how long it could run. See the
                    // design doc's "What is NOT real on iOS" section.
                    KeyExchangeRing(phase: .settled, confirmed: false, ringSize: 240)
                    QAudionAvatar(displayName: peerDisplayName,
                                  imageURL: avatarUrl,
                                  size: 160,
                                  shortNumber: peerShortNumber)
                }
                .frame(width: 240, height: 240)
                .padding(.bottom, 28)
```

Do not touch anything else in this file — the pill row, footer text, and action buttons are unrelated to this change.

- [ ] **Step 2: Self-review**

Confirm the diff touches only this one `ZStack` — grep the rest of the file yourself for `AvatarHalo` to confirm zero remaining references (there should be none left in this file after this edit; `AvatarHalo.swift` itself and its other two call sites in `OutgoingCallConfirmScreen`-equivalent-if-any and `InCallScreen.swift` are untouched and out of scope — do not modify `AvatarHalo.swift`).

- [ ] **Step 3: Commit**

```bash
cd "D:/users/f10379a/DEV APP/BCRYPTO/apps/qaudion-ios"
git add QAudionApp/Views/Call/IncomingCallScreen.swift
git -c commit.gpgsign=false commit -m "feat(call): IncomingCallScreen uses a settled KeyExchangeRing, removes duplicate AvatarHalo"
```

---

### Task 4: Thread real data through `ContentView` and widen `sessionFingerprintFromKey`'s access

**Files:**
- Modify: `QAudionApp/Views/Call/LiveInCallScreen.swift`
- Modify: `QAudionApp/Views/ContentView.swift`

- [ ] **Step 1: Widen `sessionFingerprintFromKey`'s access**

In `LiveInCallScreen.swift`, find:
```swift
    private static func sessionFingerprintFromKey(_ key: Data) -> String {
```
Replace with:
```swift
    static func sessionFingerprintFromKey(_ key: Data) -> String {
```
(Just drops `private` — same body, same behavior. Everywhere this is currently called from inside `LiveInCallScreen` via `Self.sessionFingerprintFromKey(...)` keeps working unchanged; this only ADDS the ability for `ContentView` to call `LiveInCallScreen.sessionFingerprintFromKey(...)` from outside.)

- [ ] **Step 2: Thread the real values into `makeOutgoingScreen()`**

Find:
```swift
    private func makeOutgoingScreen() -> OutgoingCallScreen {
        let cs = appState.callState
        // W-OUTGOINGDOT3 — cs can now legitimately be .active/.encrypted
        // here: showLiveCallScreen hasn't flipped yet for this render pass
        // (its .onChange fires after), so this frame is exactly the one
        // that must show the third checkmark. Previously this branch could
        // never see those two values in practice (inCallStack swapped
        // away synchronously the same instant), so the ternary only ever
        // needed to distinguish .connecting from everything else — that
        // silently made OutgoingCallScreen.State.connected dead code.
        let outState: OutgoingCallScreen.State
        switch cs {
        case .connecting: outState = .dialing
        case .active, .encrypted: outState = .connected
        default: outState = .handshaking
        }
        let name: String = outgoingDisplayName.isEmpty
            ? (appState.callContactId ?? "…")
            : outgoingDisplayName
        return OutgoingCallScreen(
            peerDisplayName: name,
            avatarUrl: outgoingAvatarUrl,
            state: outState,
            elapsedSeconds: Int(appState.callService.callDurationSeconds),
            peerShortNumber: outgoingShortNumber,
            onHangup: { appState.endCall() }
        )
    }
```

Replace with:
```swift
    private func makeOutgoingScreen() -> OutgoingCallScreen {
        let cs = appState.callState
        // W-OUTGOINGDOT3 — cs can now legitimately be .active/.encrypted
        // here: showLiveCallScreen hasn't flipped yet for this render pass
        // (its .onChange fires after), so this frame is exactly the one
        // that must show the third checkmark. Previously this branch could
        // never see those two values in practice (inCallStack swapped
        // away synchronously the same instant), so the ternary only ever
        // needed to distinguish .connecting from everything else — that
        // silently made OutgoingCallScreen.State.connected dead code.
        let outState: OutgoingCallScreen.State
        switch cs {
        case .connecting: outState = .dialing
        case .active, .encrypted: outState = .connected
        default: outState = .handshaking
        }
        let name: String = outgoingDisplayName.isEmpty
            ? (appState.callContactId ?? "…")
            : outgoingDisplayName
        // Key-exchange ring — only non-nil once the real PQC session key
        // exists (same condition LiveInCallScreen.liveKeyInfo uses), which
        // in practice is only true for the single .connected render frame
        // this screen survives — see this plan's design-doc reference for
        // why these are shown immediately rather than animated in.
        let pskMethodLabel: String? = appState.pskMethod.isEmpty ? nil : appState.pskMethod
        let sessionFingerprint: String? = {
            guard let key = appState.callPqcSessionKey, !key.isEmpty else { return nil }
            return LiveInCallScreen.sessionFingerprintFromKey(key)
        }()
        return OutgoingCallScreen(
            peerDisplayName: name,
            avatarUrl: outgoingAvatarUrl,
            state: outState,
            elapsedSeconds: Int(appState.callService.callDurationSeconds),
            peerShortNumber: outgoingShortNumber,
            pskMethodLabel: pskMethodLabel,
            sessionFingerprint: sessionFingerprint,
            onHangup: { appState.endCall() }
        )
    }
```

- [ ] **Step 3: Self-review**

Confirm `appState.pskMethod`/`appState.callPqcSessionKey` are genuinely accessible from `ContentView` (they're on `AppState`, an `@EnvironmentObject`/`@ObservedObject` this file already has as `appState` — confirm by grepping this same file for another existing use of `appState.pskMethod` or a sibling property like `appState.pskActive`, which `LiveInCallScreen.swift:709-721` already reads the same way, to confirm the access level is not more restrictive than `internal`).

- [ ] **Step 4: Commit**

```bash
cd "D:/users/f10379a/DEV APP/BCRYPTO/apps/qaudion-ios"
git add QAudionApp/Views/Call/LiveInCallScreen.swift QAudionApp/Views/ContentView.swift
git -c commit.gpgsign=false commit -m "feat(call): thread real PSK/fingerprint data into OutgoingCallScreen"
```

---

### Task 5: XCTest for `ringPhase(for:)`

**Files:**
- Create: a new test file for the pure `ringPhase(for:)` function.

- [ ] **Step 1: Find the real unit-test target first**

Before creating anything, find this repo's actual XCTest target name and an existing small, simple test file to copy the exact header/import style from:
```bash
cd "D:/users/f10379a/DEV APP/BCRYPTO/apps/qaudion-ios"
find . -iname "*Tests*" -path "*Tests*" -name "*.swift" | head -5
```
Open one of the results and note: the `import` lines at the top (likely `import XCTest` plus `@testable import QAudionApp` or similar — use the REAL module name found, do not guess), and which directory new test files live in.

- [ ] **Step 2: Write the test file**

Create it in the same directory as the existing tests found in Step 1, using the same import style, e.g.:
```swift
import XCTest
@testable import QAudionApp

final class KeyExchangeRingTests: XCTestCase {
    func testDialingAndHandshakingBothMapToHandshaking() {
        XCTAssertEqual(ringPhase(for: .dialing), .handshaking)
        XCTAssertEqual(ringPhase(for: .handshaking), .handshaking)
    }

    func testConnectedMapsToCrystallizing() {
        XCTAssertEqual(ringPhase(for: .connected), .crystallizing)
    }

    func testRekeyingAndEndedBothMapToSettled() {
        XCTAssertEqual(ringPhase(for: .rekeying), .settled)
        XCTAssertEqual(ringPhase(for: .ended), .settled)
    }
}
```
(If Step 1's actual `@testable import` module name differs from `QAudionApp`, use the real one found — do not assume.)

- [ ] **Step 3: Self-review**

This cannot be executed in this environment. Read it once more and confirm: all 5 `OutgoingCallScreen.State` cases are covered across the three test methods (dialing, handshaking, connected, rekeying, ended — yes, all 5), and `KeyExchangeRing.Phase` conforms to `Equatable` (confirm this by re-reading Task 1's `enum Phase: Equatable` declaration — `XCTAssertEqual` requires it).

- [ ] **Step 4: Commit**

```bash
cd "D:/users/f10379a/DEV APP/BCRYPTO/apps/qaudion-ios"
git add <the exact new test file path found/created in Steps 1-2>
git -c commit.gpgsign=false commit -m "test(key-exchange-ring): unit tests for the OutgoingCallScreen.State to ring-phase mapping"
```

---

## Self-review notes (for whoever executes this plan)

- No calibration/self-tuning task exists here on purpose — see the design doc. Do not add one "for parity with Android" — there is nothing to calibrate against without a measured incident, and `TimelineView(paused:)` already provides the stop-for-good guarantee natively.
- No animated fingerprint reveal exists here on purpose, for the same reason documented in Task 2 — `OutgoingCallScreen` only survives one render frame at `.connected` on iOS (a real, cited architectural fact — `ContentView.swift:426-433` — not a guess), unlike Android where the outgoing→in-call transition is a full Activity swap with real elapsed wall-clock time.
- Every step that would normally be "run the build/tests" is replaced with "read and cross-reference a cited real file in this repo." Whoever executes this MUST still do that reading — skipping it because "there's no compiler to catch mistakes anyway" is backwards; it's the ONLY check available here.
- Real verification happens later via CI or the user's own Xcode, per explicit user direction (2026-09-03) — flag any compile error found that way back into this plan's history (a follow-up commit, same as the Android plan's Task 8 found and fixed issues after the fact) rather than treating it as this plan having failed.
