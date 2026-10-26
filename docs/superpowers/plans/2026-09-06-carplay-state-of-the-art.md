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

- **S1 — SHIPPED to TestFlight 2026-09-06 (`v1.0.1092`).** New
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
  names) — not written from memory.
  - Real build history: `v1.0.1090` failed at archive — `"QAudionIntents"
    requires a provisioning profile` (new bundle id
    `com.qaudion.app.intents` never registered with App Store Connect).
    Fixed in `.github/workflows/ios-testflight.yml` (enable `SiriKit`
    capability on the main bundle id + fetch a plain profile for the new
    extension bundle id, same self-healing pattern already used for
    Associated Domains/App Groups/Network Extensions). `v1.0.1091` archived
    and uploaded clean (13m46s) — proves the Swift code itself compiled
    correctly on the first real attempt.
  - **Gap found AFTER v1.0.1091 shipped, fixed in `v1.0.1092`:** Apple's own
    doc ("Requesting Authorization to Use Siri") states
    `NSSiriUsageDescription` "is a requirement" and
    `INPreferences.requestSiriAuthorization` must be called during the
    app's execution — without both, the app's Siri authorization status
    stays `.notDetermined` forever and the whole S1 feature is silently
    unreachable regardless of how correctly the entitlement/extension are
    configured. `v1.0.1091` shipped with neither. Added
    `NSSiriUsageDescription` to `Info.plist` and a
    `INPreferences.requestSiriAuthorization` call in `AppState.initialize()`
    (right after the `CarPlayBridge` wiring). **Lesson for future slices:
    verify the FULL "Requesting Authorization"/"required keys" doc page for
    each new Intents domain before declaring a slice done — the entitlement
    + extension + Info.plist activity-type trio is necessary but not
    sufficient.**
- **S2 (Siri messaging) — IMPLEMENTED 2026-09-06, NOT YET RELEASED/
  BUILD-VERIFIED.** `INSendMessageIntentHandling`/
  `INSearchForMessagesIntentHandling`'s `handle()` cannot be a
  `continueInApp` pass-through like calls (Apple's docs: both must
  send/search from inside the Intents Extension process itself), which
  would normally mean sharing E2EE ratchet/session material across a
  process boundary. Resolved via a `cryptography-security-expert`
  consultation (2026-09-06) into a narrower, reviewed design with NO
  ratchet sharing at all:
  - New `group.com.bcrypto.qaudion.siri` App Group (separate from vpn/
    broadcast, this project's per-feature convention), new
    `QAudionIntents.entitlements`.
  - New `SiriMessageBridgeStore.swift` (`QAudionApp/Siri/`, compiled into
    BOTH targets directly — Foundation + CryptoKit only, no
    `QAudionEngine`) — two strictly single-writer, App-Group-encrypted
    channels: `recentMessages` (main app writes plaintext it already
    decrypted; extension reads, opt-in via `SiriMessagingConsent`, default
    OFF — new "SIRI" section in `PrivacySettingsScreen`) and `outbox`
    (extension appends raw `{handle, spokenName, text}`, never encrypts
    anything; main app drains).
  - `AppState.drainSiriOutbox()`: resolves each queued entry via
    `SiriCallResolution` (same resolver as S1), then inserts a normal
    outgoing `.sending` `Message` row via `ConversationStore
    .appendMessage` + `resolveOrCreateConversationId` and kicks the
    ALREADY-EXISTING `ChatOutboxDrain` — the real encrypt+send happens
    through the app's one, single-writer send pipeline
    (`ChatMessageSendService`), completely unchanged, exactly as if the
    user had typed the message in `ChatDetailScreen`. Never calls the send
    service directly. `handle()`'s response code is `.inProgress`
    ("queued", Apple's own semantics for "not sent within a few seconds"),
    never `.success` — no false confirmation to the user.
  - `AppState.refreshSiriMessageCache()`: capped snapshot of recent 1:1
    message history (`ConversationStore.loadMessages`), skips
    `deletedAt`/`isViewOnce` rows. Both drain and refresh run on cold
    launch (`initialize()`) and on every foreground
    (`QAudionApp.swift`'s `handleScenePhase(.active)`).
  - `QAudionIntents/Info.plist`: `IntentsSupported` gained both intents;
    `IntentsRestrictedWhileLocked` gained `INSearchForMessagesIntent` only
    (reading plaintext, even from the cache, requires an unlocked device —
    matches this app's existing no-plaintext-while-locked posture; sending
    is NOT restricted, same as calls).
  - `.github/workflows/ios-testflight.yml`: `QAudionIntents` now has an
    entitlements file (it didn't for S1), so its signing block gained the
    same enable-capabilities/delete-stale-profile dance as the VPN/
    broadcast extensions (App Groups only — no other capability needed).
  - Every new SiriKit API call (both protocols' full resolve/confirm/
    handle surface, `INMessage`, `INSendMessageIntentResponseCode
    .inProgress`'s exact semantics) was cross-checked against Apple's
    current docs, not written from memory — same discipline as S1.
  - **Not yet committed/tagged.** Materially larger blast radius than S1
    (touches the real `ConversationStore`/`ChatOutboxDrain` message
    pipeline, even though only through brand-new, additive call sites) —
    flagged to Pavel before cutting a release for this batch.
- **S3 (file the CarPlay entitlement request)** — still not filed; this is
  a manual action at developer.apple.com/contact/request/carplay-entitlement
  that only the Apple Developer account holder can do. Nothing in S4/S5 can
  be verified end-to-end without it.
- **S4 — COMPLETE 2026-09-06** (assistant cell part shipped with S1's fix
  in `v1.0.1092`; `CPContactTemplate`/`CPContactMessageButton` part added
  right after S2 landed, same day, not yet tagged). Recenti tab keeps its
  `CPAssistantCellConfiguration(.startCall)`. Contatti tab: a row tap now
  pushes a `CPContactTemplate` (contact detail) instead of dialing
  directly — `CPContactCallButton` (no Siri) always present,
  `CPContactMessageButton` (Siri compose, needs S2) added only when the
  contact has a known phone/email (`ContactsStore.StoredContact
  .phoneNumber` — many Q-Audion contacts, discover-v2/QR-scan imports,
  never learn one, so the button is genuinely conditional, not always
  shown). This is a deliberate one-extra-tap UX change from the old
  direct-dial row — accepted now that the detail screen has a real second
  action to offer; it would have been a pure regression before S2 existed,
  which is exactly why it was deferred that long.
- **S5 — COMPLETE 2026-09-06**, same pass as S4. Messaggi tab: real
  `CPMessageListItem` rows (conversation identifier + peer name + unread
  count only — never message content) replace the old `CPListItem`-that-
  calls-the-peer workaround. No `handler` — CarPlay itself decides
  compose/read/reply based on the unread indicator, routing to
  `IntentHandler`'s `INSendMessageIntentHandling`/
  `INSearchForMessagesIntentHandling` (S2). The no-plaintext-on-screen
  policy is unchanged — only what Siri may say aloud changed, not what the
  screen draws.
- **S7 — Tier B is part of every build (2026-10-26).** Apple assigned the CarPlay
  Communication entitlement and the capability is enabled on the App ID, so the
  variant is folded into the default spec:
  - `CarPlayScene.swift` is always compiled (no compilation flag), `project.yml`
    links `CarPlay.framework`, the source `Info.plist` declares the scene
    (`CPTemplateApplicationSceneSessionRoleApplication`, `CarPlaySceneDelegate`,
    multiple scenes on) and `QAudion.entitlements` / `QAudionVPN.entitlements`
    carry `com.apple.developer.carplay-communication`. `project-carplay.yml`,
    `carplay-add-scene.sh` and the `carplay-variant-build` job are gone.
  - `ios-app-tests.yml` reads the built app and requires the scene
    configuration, the scene class, the framework load command and the
    entitlement. `scripts/ci/check_carplay_gating.py` (with its tests, run by
    `ios-ci-gates.yml`) requires the same of the sources, keeps CarPlay types
    inside the scene file and keeps car-screen text free of phone references.
  - `ios-testflight.yml` deletes every App Store profile of the App ID and
    recreates it, then compares the profile with the entitlements file the
    build is signed with (`verify_profile_entitlements`).
  - Lists are built by `CarPlayListModel.swift` (compiled in every build, no
    CarPlay type): rows are capped by `CPListTemplate.maximumItemCount` and
    by 12 on a vehicle that limits lists (`CPLimitableUserInterface.lists`),
    verified contacts first, orphaned accounts left out. Nothing is listed
    while the session is not known yet, while nobody is signed in, or while
    the app lock is up (`CarPlayAccess`). Pinned one-to-one conversations go
    into the iOS 26 header grid (`CPMessageGridItemConfiguration`), behind
    `#available(iOS 26.0, *)`.
  - Cold launch with only the car: `AppDelegate` wires
    `CarPlayBridge.bootApp` at process launch; the scene's connect calls
    `CarPlayBridge.carPlayConnected()`, which runs the app's start-up
    (`AppState.initializeForCarPlayLaunch()`) before anything is listed or
    dialled, so `placeCall` is wired without the phone window's `onAppear`.
    `AppInitializeGate` makes `initialize()` run once whichever door comes
    first. A Siri call request that reaches the scene (`scene(_:continue:)`,
    or the connection options of a cold launch) goes through
    `CarPlayBridge.deliverSiriActivity` into `handleSiriStartCall`.
  - The session is restored after `initialize()`, so a launch made by the car
    starts with the session not known (a stored token, `isAuthenticated` still
    false), which is not "signed out". `AppState.isAuthenticated` fires
    `CarPlayBridge.onSignInChanged` and the scene reloads its lists. The app
    lock is `AppLockService.shared`: a launch with only the car sets an enabled
    lock without a prompt, `AppState.isAppLocked` reads it, and the lists stay
    empty and calls are refused until the phone window unlocks
    (`CarPlayBridge.onLockChanged`). In a process that is already running,
    `CarPlayBridge.refreshAppLock` (`AppLockService.lockIfGraceExpiredWithoutPrompt`)
    sets the lock when the grace period ran out while the phone window was in
    the background; it runs when the car connects and before every read of the
    lock, and asks nobody. A revoked session found at restore also fires
    `onSignInChanged`.
  - Empty and error states are complete on the car screen: starting,
    signed-out and locked states, and four alert notices (contact not found,
    call not started, app not ready, app locked) drawn with `CPAlertTemplate`.
    A call that could not be set up after a tap on a row (no engine, or the
    setup failed) raises "call not started"; a second tap while a start is in
    flight or a call is up does not (`CallStartOutcome`). All strings are in
    the catalog in the six languages.
  - Intents extension: `INSetMessageAttributeIntent` is handled (Siri marks a
    conversation as read after reading it aloud; the mark is queued in the
    bridge and applied by the main app) and listed in `IntentsSupported`.
    A read mark covers the messages Siri was given, up to the newest of them
    (the message identifier carries the second it was sent), and the unread
    count keeps what arrived after. The extension posts a Darwin notification
    after it queues a message or a read mark; a running app drains the queue
    on it and when a CarPlay session connects.
    `intent.conversationIdentifier` (the peer id of a conversation row) is
    honoured on send and search before any name is looked at. For a message,
    a person Siri tied to a contact card or this app donated is resolved
    (`SiriIntentPolicy`): several such candidates are a disambiguation,
    several recipients are put to the user as a choice. A bare spoken name is
    passed on unchanged. A call request passes every person on as Siri gave
    it, as before: the app matches it by phone number or display name and
    reports "contact not found" on the car screen. The call resolvers use the result types the protocols declare
    (`INStartCallContactResolutionResult`,
    `INStartCallCallCapabilityResolutionResult`), and a test checks that
    SiriKit's Objective-C selectors reach every resolve, confirm and handle
    method.
  - Unit tests: `CarPlayListModelTests`, `CarPlayBridgeTests`,
    `AppLockServiceTests`, `CallStartSupportTests`, `SiriIntentPolicyTests`, `IntentHandlerTests` (the extension source is
    compiled into the test bundle with a fake bridge), and the new cases of
    `SiriCallResolutionTests` in the engine.
  - Not yet run on a head unit: the scene itself (templates) is compiled by
    CI, not driven by a test. That needs the CarPlay entitlement or the
    CarPlay simulator.
- S6: deferred, explicitly, no change.

## Current state (confirmed 2026-10-23, from the files at `main`)

- Tier A (CallKit-driven incoming/active call on CarPlay): **works today**,
  zero code, zero entitlement. Unaffected by this programme.
- Tier B (`CarPlayScene.swift`): part of every build (see S7). Three
  `CPListTemplate` tabs (Recenti/Contatti/Messaggi) plus the assistant cell on
  Recenti, `CPContactTemplate` with call and message buttons,
  `CPMessageListItem` rows, an iOS 26 pinned grid. The rows and their caps
  come from `CarPlayListModel.swift` (always compiled, unit tested).
- `QAudion.entitlements` / `QAudionVPN.entitlements`: `com.apple.developer.siri`,
  the Siri App Group and `com.apple.developer.carplay-communication` (a gate
  fails the pull request that drops it).
- `project.yml`: `QAudionIntents` app-extension target (compiles
  `SiriMessageBridgeStore.swift` and `SiriIntentPolicy.swift` from
  `QAudionApp/Siri/`), `Intents.framework`, `CarPlay.framework`.
- `Info.plist`: `UIApplicationSupportsMultipleScenes = true` and the CarPlay
  scene configuration.
- Intents: `INStartCallIntent`, `INSendMessageIntent`,
  `INSearchForMessagesIntent`, `INSetMessageAttributeIntent`. Donations: the
  call donation after every outgoing call.
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
5. Check the slice against the slice plan with a fresh pass.
6. S1/S2: testable TODAY on a real iPhone via Xcode's "run Siri or Maps as
   the host app" debug flow — no CarPlay hardware or entitlement needed to
   verify the Intents Extension in isolation.
7. Every pull request: `ios-app-tests.yml` builds the app, checks the CarPlay
   scene in the built app and runs the app-target tests, `ios-ci-gates.yml`
   runs `check_carplay_gating.py` and its tests.
8. S4/S5: the entitlement is granted; verify end-to-end in a car or the Xcode
   CarPlay Simulator with a TestFlight build.

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
