# CarPlay — state-of-the-art programme (master plan)

> **For agentic workers:** this is the INDEX, mirroring
> `qaudion-android-new/docs/superpowers/plans/2026-09-05-android-auto-state-of-the-art.md`
> (same ask, other platform — read that file for the cross-platform parity
> mapping). Each slice below gets its own plan file
> (`2026-09-06-carplay-s<N>-<name>.md`) written to the superpowers
> `writing-plans` standard once approved to start. Execute IN ORDER with
> superpowers:subagent-driven-development; every slice ends green on the
> `ios-testflight.yml` build pipeline (or, where noted, cannot be verified on
> TestFlight at all until Apple grants an entitlement) plus a review.

**Goal:** bring Q-Audion's iOS car-interface story to parity with the Android
Auto program (`2026-09-05-android-auto-state-of-the-art.md`) wherever the
CarPlay SDK actually allows it, using the Communication-category templates
and SiriKit the way Apple's own docs specify them — not the current
hand-rolled `CPListItem`-everywhere approximation.

**Research base:** `reference_carplay_siri_communication_pattern_2026_09_06`
memory (Apple docs: CarPlay framework reference, SiriKit Intents reference,
WWDC26-212 "Rev up your CarPlay app"; full technique breakdown + this repo's
current-state evidence, file:line sourced). No competitor code or names
involved anywhere in this research — CarPlay/SiriKit are Apple's own SDKs.

**Architecture decisions (locked):**

1. **One call owner stays CallKit.** CarPlay never gets a custom
   incoming/active-call template. This already matches Android Auto's own
   locked decision (host renders the call UI, the app never draws its own).
   Tier A (see [[project_carplay]]) needs zero changes in this programme.
2. **Video-on-CarPlay is explicitly out of scope**, for the same reason
   Android Auto's plan rules it out: the in-call surface has no video
   rendering capability on either platform's car UI, regardless of app code.
   WWDC26's new "CarPlay video app" category (browsing pre-recorded video
   while parked) is a different feature aimed at media/streaming apps and
   does not apply to a VoIP calling app.
3. **Siri work (Intents Extension) is NOT gated by the CarPlay entitlement**
   and should be built first — `com.apple.developer.siri` is a self-service
   capability, unlike `com.apple.developer.carplay-communication` (Apple
   discretionary review, "free, weeks", per [[project_carplay]]). Building the
   Intents Extension pays off standalone (Siri Suggestions, Lock Screen,
   "Hey Siri, chiama X su Q-Audion" on the phone itself) even before/without
   CarPlay entitlement approval, and everything CarPlay-side that depends on
   Siri (assistant cell, `CPMessageListItem`, `CPContactMessageButton`) is
   free the moment the entitlement lands, if this slice ships first.
4. **File the CarPlay entitlement request now, in parallel with S1** — it is
   the long pole (weeks, per Apple's own framing) and every Tier-B template
   upgrade in this plan is unverifiable on a real head unit / TestFlight
   until it's granted. Nothing downstream blocks on filing it; filing it
   blocks on nothing.
5. **`CPSearchTemplate` (Navigation-only) means CarPlay has no native contacts
   search**, unlike Android Auto's `SearchTemplate`-based S2 slice. This is a
   platform ceiling — do not spend a slice trying to fake search via a
   custom filtered list; scrolling a capped, sorted list (verified-first,
   alphabetical, 50-row cap — already how `CarPlayScene.reloadContacts`
   works today) is the correct fallback, matching the ceiling rather than
   fighting it.
6. **No competitor names anywhere in the repo** (comments included) — this
   entire programme is pure first-party Apple SDK, so the constraint is
   trivially satisfied, but stated for consistency with the Android plan.

**Tech stack:** CarPlay.framework (iOS 16+, already the repo's deployment
target), Intents.framework + IntentsUI.framework (new app-extension target),
existing `CallKitProvider`/`PersistentCallRecordStore`/`ConversationStore`/
`ContactsStore` (QAudionEngine + QAudionApp) as the data source every new
template reads from — no new data layer, only new presentation surfaces.

---

## Status

- **S1 — IMPLEMENTED 2026-09-06, NOT YET BUILD-VERIFIED.** New
  `QAudionIntents` app-extension target (`IntentHandler.swift`,
  `INStartCallIntentHandling` — resolve/confirm/handle, pure pass-through,
  zero `QAudionEngine` dependency by design); `com.apple.developer.siri`
  entitlement added; `NSUserActivityTypes: [INStartCallIntent]` in
  `Info.plist`; `QAudionApp.swift` gained
  `.onContinueUserActivity(NSStringFromClass(INStartCallIntent.self))`;
  `AppState.handleSiriStartCall`/`donateStartCallInteraction` added (the
  latter wired into every `startCall` call, covering CarPlay/manual-dial/
  Siri-originated calls alike); new pure `SiriCallResolution`
  (QAudionEngine, matches by E.164 phone or display name against
  `AppState.cachedContacts`, unit-tested in `SiriCallResolutionTests.swift`
  — no pepper/hash matching, see that file's own doc for the known gap).
  Every SiriKit API call was cross-checked against Apple's current
  documentation (initializer signatures, property optionality, enum case
  names) — not written from memory. **Cannot be compiled locally** (no
  macOS toolchain in this environment) — first real compiler feedback comes
  from either `engine-tests.yml` (covers `SiriCallResolution` + its tests
  only, runs on every push) or a manual `ios-ui-smoke.yml` dispatch (covers
  the full `QAudionApp` + new `QAudionIntents` target, Simulator, no
  signing — the right cheap gate for this slice, see the Gates section).
  Not yet committed.
- S2-S6: not started.

## Current state (confirmed 2026-09-06, all via `Read`/`Grep`, not assumed)

- Tier A (CallKit-driven incoming/active call on CarPlay): **works today**,
  zero code, zero entitlement. Unaffected by this programme.
- Tier B (`CarPlayScene.swift`): compiled out behind `QAUDION_CARPLAY`
  (absent from `SWIFT_ACTIVE_COMPILATION_CONDITIONS` in `project.yml`).
  Three `CPListTemplate` tabs (Recenti/Contatti/Messaggi), every row a plain
  `CPListItem` with a manual `handler` that places a call. No
  `CPContactTemplate`, no `CPMessageListItem`, no `CPAssistantCellConfiguration`.
- `QAudion.entitlements`: no `com.apple.developer.siri`, no
  `com.apple.developer.carplay-communication`.
- `project.yml`: zero Intents-Extension target (compare
  `QAudionPacketTunnel`/`QAudionBroadcastExtension`, the two existing
  app-extension targets this new one should structurally match).
- `Info.plist`: `UIApplicationSupportsMultipleScenes = false` (must flip for
  the CarPlay scene itself — already documented in `CarPlayScene.swift`'s own
  header checklist, unchanged by this plan).
- Zero `INStartCallIntent`/`INSendMessageIntent`/`INSearchForMessagesIntent`/
  `Intents` imports anywhere in the codebase. Full absence, not partial.
- `CXProviderConfiguration.includesCallsInRecents = false`
  (`CallKitProvider.swift`) — a product decision that predates this plan and
  interacts with Siri donation (see S1 below); flagged, not silently changed.

## Slices (execute in this order)

| # | Slice | What it adds | Depends on | Blocked on Apple? |
|---|---|---|---|---|
| S1 | Siri calling foundation | New Intents-Extension target; `INStartCallIntentHandling` (resolve/confirm/handle, unified audio+video intent — NOT the deprecated iOS-13-and-earlier `INStartAudioCallIntent`/`INStartVideoCallIntent` pair); `com.apple.developer.siri` entitlement on the main app; `scene(_:continue:)`/`application(_:continue:restorationHandler:)` handoff into the existing `CallKitProvider.startOutgoingCall` path; donate `INInteraction` after every real in-app outgoing call (hook into the same place `PersistentCallRecordStore` already records one) | Existing `CallKitProvider`, `AppState` call-placement path | No — Siri capability is self-service |
| S2 | Siri messaging foundation | Same Intents-Extension target gains `INSendMessageIntentHandling` + `INSearchForMessagesIntentHandling` + `INSetMessageAttributeIntentHandling` (mark-read after Siri reads a message aloud); `UNAuthorizationOptions.announcement`/`allowAnnouncement` wiring for AirPods announce; donate `INSendMessageIntent` interactions after a real in-app message send | S1's extension target and entitlement | No |
| S3 | CarPlay entitlement request | File the `com.apple.developer.carplay-communication` request (developer.apple.com/contact/request/carplay-entitlement, category "Communication app"); no code | Nothing — can run in parallel with S1/S2, should be filed immediately given multi-week turnaround | **Yes — this IS the Apple gate**, everything below waits on its outcome |
| S4 | Tier B template upgrade — contacts & assistant cell | Replace Contatti tab's flat `CPListItem` rows with `CPContactTemplate` push (`CPContact` + `CPContactCallButton` + `CPContactMessageButton`); add `CPAssistantCellConfiguration` (`.startCall` action) to the Recenti tab, now unlockable because S1 shipped the required Intents Extension | S1 (assistant cell literally cannot be added without it — Apple validates the intent is handled), S3's entitlement grant | Yes (needs the grant to test on a real head unit — code can be written and reviewed earlier, gated `#if QAUDION_CARPLAY` same as today) |
| S5 | Tier B template upgrade — messaging | Replace Messaggi tab's `CPListItem`-as-fake-contact-list with real `CPMessageListItem` rows (conversation identifier, unread leading/trailing configuration) so Siri drives compose/read/reply hands-free instead of the current "tap = call the peer" workaround; keep the no-plaintext-on-screen policy (Siri reads the *content*, the screen still never renders it) | S2 (message intents), S3's entitlement grant | Yes (same reason as S4) |
| S6 | Deferred, explicitly | `includesCallsInRecents` flip to `true` (product/privacy decision — surfaces peer identity in the system-wide Phone Recents list and Siri's own ranking; needs a explicit yes/no from Pavel, not a default); CarPlay Ultra dashboard-cluster APIs (no navigation feature to expose); CarPlay video-app category (N/A — not a video-content app); `CPSearchTemplate` (N/A — Navigation-only per Apple's category matrix) | — | — |

## Gates (every slice)

1. `xcodegen generate` (regenerate `.xcodeproj` from `project.yml`) succeeds.
2. Local `xcodebuild build` (or the CI "Diagnose Swift compile" step) green —
   Swift 6 type-checker traps from this repo's own `CLAUDE.md` §13 apply to
   any new closure-heavy Intents-handler code exactly as they do elsewhere.
3. `engine-tests.yml` stays green (no QAudionEngine changes expected in this
   plan, but the Intents Extension links against `QAudionEngine` products
   the same way `QAudionApp` does — verify no new circular/heavy dependency).
4. `graphify update .` after every slice.
5. Review by a fresh reviewer agent against the slice plan.
6. S1/S2: testable TODAY on a real iPhone via Xcode's "run Siri or Maps as
   the host app" debug flow — no CarPlay hardware or entitlement needed to
   verify the Intents Extension in isolation.
7. S4/S5: **cannot be verified end-to-end until S3's entitlement is granted**
   — Apple will not sign a build carrying `com.apple.developer.carplay-
   communication` without it. Write and review the code regardless (gated
   behind `QAUDION_CARPLAY`, same as today), but do not expect a TestFlight
   build with Tier B active before the grant lands.

## Live verification checklist (needs S3 granted + CarPlay hardware or the Xcode CarPlay Simulator)

- "Hey Siri, chiama [contatto] su Q-Audion" from the phone (no CarPlay
  connected) places a real outgoing PQC call through the existing
  `CallKitProvider` path — proves S1 end-to-end before any CarPlay hardware
  is involved.
- Same phrase spoken while CarPlay is connected: the assistant cell on the
  Recenti tab responds, or the call places directly if Siri resolves the
  contact unambiguously.
- "Chiedi a Q-Audion di leggermi i messaggi di [contatto]" reads the latest
  message aloud via `INSearchForMessagesIntent`, without the screen ever
  showing plaintext — the core policy this repo already enforces on the
  Messaggi tab must survive the upgrade unchanged.
- Tapping a `CPMessageListItem` row launches Siri's reply flow, not a
  silent call to the peer (the current, pre-S5 behavior).
- `CPContactMessageButton` on the new contact-detail screen activates Siri's
  compose flow; `CPContactCallButton` still places a call with zero Siri
  round-trip (same as today's direct-handler behavior).
