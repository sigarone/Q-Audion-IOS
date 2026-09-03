# Key-exchange avatar ring animation (iOS port)

Date: 2026-09-03
Status: approved, ready for implementation plan
Platforms: iOS only (QAudionApp)
Prior art: Android shipped this feature on 2026-09-02 (`qaudion-android-new`,
`docs/superpowers/specs/2026-09-02-key-exchange-avatar-animation-design.md`
and its implementation plan). This document ports the same visual identity
and the same safety discipline to SwiftUI, adapted to real iOS constraints
found by direct investigation — it is not a blind translation.

## Goal

`OutgoingCallScreen` and `IncomingCallScreen` currently draw `AvatarHalo`
behind the contact avatar — a continuously pulsing `TimelineView(.animation)`
circle with no relationship to what the handshake is actually doing.
Replace it with a small ring that fills as the real PQC key exchange for
THIS call progresses, plus a resolving session-key fingerprint readout,
matching the Android feature's visual identity (same colours, same
"assembled from real ingredients" idea) exactly where iOS has the same
ingredient — and deliberately NOT inventing one where it doesn't.

## What already exists (found by direct investigation, not assumed)

- `AvatarHalo` (`QAudionApp/Views/Call/Components/AvatarHalo.swift:17-53`) —
  a `TimelineView(.animation(minimumInterval: 1.0/30.0))` driving a
  1.6s-period pulse, wall-clock-driven, with no stop condition. Three call
  sites: `OutgoingCallScreen.swift:77` (1 instance), `IncomingCallScreen.swift:77-78`
  (2 stacked instances), `InCallScreen.swift:842` (1 instance, post-connect,
  out of scope — see below).
- `CallMeshBackground.swift:19-75` sits behind all of these screens and is
  ALSO a permanently-running `TimelineView(.animation)` (60s gradient
  drift). `IncomingCallScreen` therefore runs three concurrent,
  uncoordinated `TimelineView(.animation)` clocks today (2×`AvatarHalo` +
  1×`CallMeshBackground`) — the same *shape* of risk as the Android
  incident (multiple uncoordinated animators on a ring screen), though no
  iOS incident has ever been measured or reported. Removing `AvatarHalo`
  from these two screens is in-scope cleanup, not scope creep — it is the
  direct consequence of replacing its call sites, exactly like the Android
  plan's own removal of `IncomingCallScreen`'s duplicate `AvatarHalo`.
- No `Localizable.strings`/`NSLocalizedString` mechanism exists anywhere in
  this app (confirmed: no `.lproj` directories, explicit precedent comment
  at `UpgradeSheet.swift:336-346`). New UI text is a plain Swift string
  literal at the call site, Italian, matching every existing call screen.
- `MetaPill` (`QAudionApp/Views/Call/Components/MetaPill.swift:16`) is the
  existing pill component, already used 3× on each ring screen — reused
  as-is for the PSK pill, no new pill component needed.
- Real PQC/PSK/fingerprint data already exists on `AppState`, but only
  reaches `InCallScreen` (post-connect) today, via `LiveInCallScreen
  .liveKeyInfo` (`LiveInCallScreen.swift:699-729`) building an
  `InCallScreen.KeyInfo` (`InCallScreen.swift:97-103`): `pqcAlgorithm`,
  `sessionFingerprint`, `pskMethodLabel`, `pskName`, `pskFingerprint`.
  `sessionFingerprintFromKey(_:)` (`LiveInCallScreen.swift:764-773`,
  `SHA256(key)` formatted as first-8-hex…last-4-hex) is the fingerprint
  formatter, reused as-is.
- `AppState.callPqcSessionKey: Data?` (`AppState.swift:1063`) and
  `AppState.callSasKeySource` (`.none`/`.psk`/`.mlKem`, `AppState.swift:1099`)
  are the underlying live signals; `pskActive`/`pskName`/`pskFingerprint`/
  `pskMethod` (`AppState.swift:1043-1051`) are the PSK metadata fields.

## What is NOT real on iOS — do not invent it

- **There is no hardware-earbud segment on iOS.** `earbudHwVerified`/
  `earbudActive` exist only on `InCallScreen` and are **hardcoded `false`**
  at their one call site (`LiveInCallScreen.swift:320-321`), with an
  explicit comment: iOS has no local earbud media-provider path —
  `EarbudCounterpartyService` only handles the PQC handshake *toward a
  peer's* earbud, and iOS is documented as "ALWAYS the SW counterparty."
  The ring on iOS is therefore **always a single PQC segment** — never
  two segments. Do not build the second segment "for future use"; there is
  no real signal to drive it, and an always-empty second segment would be
  exactly the "fabricated progress" the Android design doc's own principle
  rejects.
- **`IncomingCallScreen`'s ring never animates, by design, not caution.**
  Investigated directly: this screen is a `fullScreenCover` gated on
  `appState.incomingCallRingVisible` (`ContentView.swift:169-198`), which
  is cleared at `AppState.swift:15154` — **before** `callState` even
  leaves `.ringing` (`AppState.swift:15160-15162`) — the instant the user
  taps "Accetta". No handshake data exists yet while merely ringing
  (`callState == .ringing` the whole time, `AppState.swift:5658`), and the
  screen is torn down before any exists. Worse than Android in one respect:
  **there is no client-side timeout for a 1:1 incoming ring** on iOS
  (confirmed: only group calls have one, `AppState.swift:19616-19627`,
  45s) — an unanswered 1:1 call can ring indefinitely from the app's own
  perspective. An animating ring here would therefore have no bound at
  all, on a screen where it can never show real progress anyway. The fix
  is not a phase state machine to reason about carefully (as it was on
  Android) — it is simpler: this screen's ring is always in its static,
  non-animating rendering. See Component design below.
- **`OutgoingCallScreen` is where the real animation lives**, exactly like
  Android. It is not a sheet — it stays mounted through
  `.dialing → .handshaking → .connected` inline in `inCallStack`
  (`ContentView.swift:408-421`), the same multi-second-visible role
  Android's outgoing screen has.

## Component design

### `KeyExchangeRing` (new SwiftUI `View`, `QAudionApp/Views/Call/Components/KeyExchangeRing.swift`)

A single arc (never two), filling from 0 to a near-full circle as the PQC
round-trip is confirmed, using the identical colour identity as Android:
PQC blue `#4C8DFF`, guide-ring blue `#8CB4FF`. No PSK/hardware colour is
needed on the ring itself — PSK is a `MetaPill`, exactly as on Android and
for the same reason (it is only known once the call connects; forcing a
second ring slot for it would either sit empty or force a reflow).

Phases mirror Android's `KeyExchangePhase`: `.handshaking` (arc filling +
a slowly rotating dashed guide ring), `.crystallizing` (one soft pulse,
~320ms), `.settled` (static final frame, zero ongoing draw cost).

### Bounded animation — the SwiftUI-native equivalent of Android's single clock

Android's non-negotiable constraint was exactly one bounded animation
clock that stops for good once settled, because multiple uncoordinated
`rememberInfiniteTransition`s caused the real A36 incident. iOS has no
recorded incident, but the investigation found the identical risk shape
already present (three concurrent `TimelineView(.animation)`s on
`IncomingCallScreen` today) and no existing precedent in this codebase for
a "runs once, stops for good" driver — the closest patterns
(`InCallScreen.swift:2295-2310`'s crypto-engine meter, `CallSecurityBadge
.swift:43-44`'s red-pulse) are "runs indefinitely but gated on a live
condition," which is the exact SwiftUI mechanism to reuse here:

```swift
TimelineView(.animation(paused: phase == .settled)) { context in
    // draw using context.date, exactly like the existing cipher-tube meter
}
```

When `paused` is `true`, SwiftUI does not invoke the closure at all — this
is the direct, idiomatic SwiftUI analogue of Android's bounded
`withFrameNanos` loop that exits once `Settled`, verified against this
codebase's own established pattern rather than invented fresh.
`IncomingCallScreen`'s ring is simply always constructed with
`phase: .settled` — it never needs the `paused` branch to ever flip, so
there is no restart-safety concern to solve here the way Android's fix
needed one (Android's bug was specifically that a composable instance
could move FROM settled TO animating on the same instance; on iOS,
`IncomingCallScreen`'s ring instance never does that, because it is
recreated fresh every time the `fullScreenCover` re-presents, and it is
never given a non-`.settled` phase in the first place).

### `OutgoingCallScreen` wiring

Map `OutgoingCallScreen.State` (`dialing`/`handshaking`/`connected`/
`rekeying`/`ended`) to the ring's phase: `.dialing` and `.handshaking` both
→ ring `.handshaking` (the PQC round-trip is already in flight during
`.dialing` too — that iOS-only sub-phase distinguishes "transport not yet
confirmed" from "confirmed," not "handshake not started," per the shared
cross-platform wire protocol both apps implement); `.connected` → ring
`.crystallizing` then `.settled` after the pulse, exactly mirroring
Android's own `Crystallizing`-then-`Settled` timing (320ms + 200ms
buffer); `.rekeying`/`.ended` → `.settled` (`.rekeying` is documented dead
in production wiring today, `ContentView.swift:424-451`; `.ended` means
the screen is being torn down regardless).

Fingerprint reveal and PSK pill: only meaningful once `LiveInCallScreen
.liveKeyInfo`-equivalent data exists, i.e. once `AppState.callPqcSessionKey`
is non-empty — which today only happens post-connect, same timing
constraint Android has for its own fingerprint/PSK reveal. `OutgoingCallScreen`
does not currently receive `KeyInfo`; this plan threads a minimal, ring-relevant
subset of it in (see the implementation plan for the exact new parameters).

### `IncomingCallScreen` wiring

Replace the two stacked `AvatarHalo` instances with one `KeyExchangeRing`
constructed with `phase: .settled` and no confirmed segment — a static,
mostly-unfilled arc, matching Android's own "safe default for an unwired
caller" fallback exactly, except here it is not a fallback, it is the only
state this screen's ring ever has, because that is the honest state of the
world during unanswered ringing.

## Scope

In scope: `OutgoingCallScreen.swift`, `IncomingCallScreen.swift`, the new
`KeyExchangeRing.swift`.

Explicitly out of scope: `InCallScreen`/`LiveInCallScreen` (the persistent
live-call screen, Android's equivalent exclusion of `InCallScreen`'s
`ReKeyProgress`); `CallMeshBackground` (its own animator is a separate,
pre-existing concern, not touched); group calls (`IncomingGroupCallScreen`
equivalent, if any — the design doc for Android left group calls on the
composable's safe default rather than fully wiring them; same choice
here, confirmed by this investigation that 1:1 and group incoming flows
share `IncomingCallScreen` via `.fullScreenCover`, so the `.settled`-only
design already covers the group case for free, without a separate
placeholder decision needed); Android and Desktop (separate ports).

## Testing

SwiftUI view code is not unit-testable the way Compose's pure-logic layer
was on Android, and this codebase has no SwiftUI snapshot-testing harness
in place (not investigated further — out of scope to introduce one for
this feature). The genuinely pure logic here — phase mapping from
`OutgoingCallScreen.State`, fingerprint-reveal character counting — will
be extracted into small, plain-Swift, unit-testable functions where
practical (mirroring Android's `KeyExchangeRingModel.kt` split), with
XCTest coverage for those. The `TimelineView`/`Canvas` drawing itself is
verified by manual on-device inspection only, same acknowledged gap
Android has for its own `KeyExchangeRing.kt` Canvas code.

## Real-device verification

No Mac is available in this environment; iOS builds/tests run only via
GitHub Actions macOS CI or on the user's own physical device via the
existing go-ios/WebDriverAgent tooling (see the global CLAUDE.md's
"go-ios + WebDriverAgent" section) — screenshots and `/source` accessibility
dumps are reachable that way, but this plan does not assume a live call
can be orchestrated end-to-end without the user's participation, same as
was needed for the Android on-device pass.
