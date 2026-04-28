# Q-Audion Cross-Platform Alignment — Design Spec

> **Status:** DESIGN (awaiting user review). Replaces the planning portion of `docs/superpowers/plans/2026-04-20-ios-android-parity.md` going forward; the 8-day-old plan remains the authoritative log of what was *done* in Phase 0 + 1.
>
> **Date:** 2026-04-28
> **Branch context:** `feature/ios-android-parity` (off `main` @ `4516e01`)
> **Predecessor plan:** `docs/superpowers/plans/2026-04-20-ios-android-parity.md` (Phase 0 ✅ DONE, Phase 1 wire ✅ CODE-COMPLETE, Phase 2-13 not started)
> **Author:** parity agent, after deep audits of `qaudion-ios`, `qaudion-android-new`, `qaudion-desktop`, `bcrypto-server`

---

## 1. Goal

Bring iOS to **functional + UI parity** with Android (the reference implementation), keeping the **server** and **desktop** clients on the same wire contract, **without losing the working Codemagic pipeline** and **without wasting effort on parts the user is still actively reshaping**.

## 2. Non-goals

- No restructuring of `QAudionEngine` package; only additive changes.
- No upgrade of `onnxruntime-swift-package-manager` past `1.17.0`.
- No change to the Codemagic patch step, signing config, or any of the 12 sections of `CLAUDE.md`.
- No External-tester / App Store submission this cycle (PQC export compliance is open per `CLAUDE.md` §7).
- No reverse-porting iOS-only behaviors to Android or desktop.
- No work on areas the user has explicitly flagged as actively-changing (server/Android/desktop wire) until those land.

## 3. Strategic approach — B2-split

The user is **actively** modifying the wire protocol on the server, Android, and desktop. A monolithic 13-phase iOS plan written today would have ~70% of its content invalidated by those changes within weeks. So we split iOS work into three tracks, governed by the dependency on the moving wire surface.

```
            ┌────────────────────────────────────────────────┐
            │  Cross-Platform Invariants (§5) — the contract │
            │   PhoneHash · HKDF labels · AES-GCM ·           │
            │   ML-KEM-1024 · NFC AID · Fingerprint format    │
            └────────────────────────────────────────────────┘
                          ▲                  ▲
              respects    │                  │ respects
                          │                  │
   ┌───────────────────┐  │                  │   ┌──────────────────────┐
   │  Track A          │  │                  │   │  Track B              │
   │  Invariant-first  │──┘                  └───│  Wire-deferred        │
   │  (start NOW)      │                         │  (queue, unblock-gated)│
   └───────────────────┘                         └──────────────────────┘
            │                                                  │
            └────────────────────┬─────────────────────────────┘
                                 ▼
                        ┌─────────────────┐
                        │   Track C       │
                        │   Verification  │
                        │   (Phase 13)    │
                        └─────────────────┘
```

**Track A** = work where iOS does NOT depend on a server/Android wire decision still in flux. Math-locked, platform-locked, or UI-locked. Zero rework risk.

**Track B** = work that consumes a wire schema currently moving. Sits in queue with explicit unblock criteria. Each item gets re-audited at unblock.

**Track C** = end-to-end verification (TestFlight tag, KAT vectors against server / Android / desktop).

## 4. Status snapshot (do NOT redo)

### Phase 0 — Capability & pipeline baseline ✅ DONE

| Item | Commit | Contents |
|---|---|---|
| Push entitlement portal | (manual) | `aps-environment` capability enabled on `com.qaudion.app` 2026-04-20 |
| `Info.plist` UIBackgroundModes [voip, audio] + `aps-environment=production` entitlement | `51b0404` | iOS app declares VoIP + audio background modes |
| SDK frameworks linked (CallKit, PushKit, AVFoundation, CoreNFC, Contacts, ContactsUI) | `4e230ab` | XcodeGen `project.yml` updated |
| TestFlight smoke (tag `v1.0.24-ph0`, build #40) | (Codemagic) | IPA `43328e71-44c2-...` LIVE on `Q-Audion testers` |
| Beta-group config fix | `b470ed8` | Removed explicit `beta_groups` from publishing |

**Treat as sacred.** Anything in `codemagic.yaml`, `Info.plist`, `QAudion.entitlements`, `project.yml`, `Assets.xcassets/AppIcon.*`, the ONNX patch step, or signing config is **not editable** in this spec's scope unless explicitly approved by the user.

### Phase 1 — Wire alignment ✅ CODE-COMPLETE (with TODOs and one BLOCKED task)

| Item | Commit | Contents |
|---|---|---|
| Canonical `PhoneHash` helper | `65c5ea4` | `QAudionEngine/Utils/PhoneHash.swift` matches Android `PhoneHashHelper.kt` |
| REST endpoint audit (35 endpoints, 12 drifts, 11 missing) | `82cb970` | `docs/progress/PHASE1_REST_AUDIT.md` |
| D-CRITICAL auth fixes (`register`+`login`) | `2e78912` | iOS sends `phone_number=hash, password, ...` matching Android `RegisterRequest`/`LoginRequest` |
| Contacts sync + blocked schema | `baf314d` | `{contacts:[…]}` + `{blocked:[…]}` envelopes match Android |
| KMS device/publickey + pending envelope | `c6e605e` | iOS drops extra `device_id`, default `key_type="x25519"`, decodes `{keys:[KmsKeyDto]}` |
| Profile `updateProfile` aligned | `04f706b` | JSON-only `{display_name?, status_message?, avatar_url?}` |
| Missing endpoints added | `c0c8026` | `recovery-setup/verify`, `users/{id}`, `version/health/directory-by-extension` |
| Security endpoints flagged (`zk-register`/`zk-auth`/`pqc-relay`/`threat-report`/`wipe-confirm`) | `a0a70ed` | TODO(parity, §3.11..§3.15) on every method — wire-behavior NOT changed pending server-team decision |

**Blocked / open:**
- **Task 1.1 WS code fixes** — camelCase leakage on `call_offer/answer/ice/hangup` + missing `call_id`. **BLOCKED** on USER's uncommitted `BCryptoCallingApiImpl.swift` / `CallingApi.swift` / `QAudionCallIntegration.swift`. Documented in `PHASE1_AUDIT.md`. Will run a second audit + fix when USER WT lands.
- **§3.6–§3.8 backup transport** (multipart upload + streaming download + `BackupEntryDto`). User decision pending: land before `v1.0.24-ph1` tag, or defer to Phase 2.
- **§3.11–§3.15 security endpoints** — server-team clarification needed; agents must not auto-rewrite.

### Phase 2-13 — NOT STARTED

The 20-Apr plan defines 13 phases. The **content** of those phases is mostly still good, but ordering, dependencies, and the desktop/server axes are now richer thanks to the 28-Apr audits. Sections 7-8 below re-route this work into Track A / Track B.

## 5. Cross-platform invariants (THE CONTRACT)

The single most important deliverable of this design. These values MUST be byte-identical across `qaudion-ios`, `qaudion-android-new`, `qaudion-desktop`, and `bcrypto-server`. Any divergence breaks interop silently.

### 5.1 Identity / hashing

| Item | Value | Notes |
|---|---|---|
| **Phone hash** | `hex(sha256(utf8(e164_normalized)))` lowercase, 64 chars | E.164 normalize: strip spaces/dashes/parens; keep leading `+`. NO salt, NO pepper for phone hash. Sources: iOS `QAudionEngine/Utils/PhoneHash.swift`, Android `PhoneHashHelper.kt`, server migration. |
| **Username hash** | `hex(sha256(utf8(global_pepper ‖ username)))` | Pepper from `GET /api/v1/discover/pepper`. Server cannot reverse. |
| **Contact discovery hash (v2)** | `hex(sha256(utf8(contacts_pepper ‖ e164)))` | Pepper from `GET /api/v1/contacts/pepper`. v1 (`POST /contacts/discover`) is obsolete. |
| **Public-key fingerprint (display)** | first 8 bytes of `sha256(pubkey_bytes)` formatted as 4 dot-separated 4-hex-char groups: `a3f7.c291.8b4e.d012` | Shown in UI; used for SAS verification anchor. |

### 5.2 Symmetric crypto

| Item | Value |
|---|---|
| **AEAD** | AES-256-GCM, 12-byte nonce (random per message), 16-byte tag (appended to ciphertext) |
| **Hash** | SHA-256 (everywhere) |
| **HKDF** | HKDF-SHA256, output 32 bytes (256-bit symmetric key) unless noted |

### 5.3 HKDF salts / infos (canonical)

| Purpose | Salt | Info | Output |
|---|---|---|---|
| Message conversation key | per-pair (see ContactKeyExchange) | `"q-audion-msg-key"` | 32B |
| Device-link PSK | UTF-8 `"qaudion-link-salt"` | UTF-8 `"qaudion-device-link-v1"` | 32B |
| NFC collaborative PSK | `sha256(sorted_concat(pubkeyA, pubkeyB))` | UTF-8 `"Q-Audion NFC Collaborative PSK v1"` | 32B |
| Hybrid PQC session key | `HYBRID_PQC_SALT_V1` (desktop constant — must verify exact bytes match Android) | `HYBRID_PQC_INFO` | 32B |
| Recovery seed → secret | UTF-8 `"recovery-auth-v1"` | (BIP-39 mnemonic) | first 32B |
| Frame chain (audio/video) | `chainKey` | `"FRAME_CHAIN_AUDIO"` / `"FRAME_CHAIN_VIDEO"` (desktop constants) | 32B + next chain |
| Attachment | `contactPSK` | `"FILE_KEY"` | 32B file key |

> **Open invariant — must verify:** the desktop `constants.ts` defines `HYBRID_PQC_SALT_V1`, `HYBRID_PQC_INFO`, `FRAME_CHAIN_*`, `FILE_KEY` as exact bytes. Android Kotlin and iOS Swift must agree. **Action item before Phase 4 starts:** dump these constants from all three repos into `docs/progress/INVARIANTS_VERIFIED.md` and pin them.

### 5.4 Asymmetric crypto

| Item | Value |
|---|---|
| **Post-quantum KEM** | ML-KEM-1024 (FIPS 203). iOS via liboqs, Android via BouncyCastle (KAT-gated against `@noble/post-quantum` on desktop), desktop via `@noble/post-quantum` v0.2.1 |
| **Classic ECDH** | X25519 (Curve25519). iOS CryptoKit, Android Tink/BC, desktop `@noble/curves` |
| **Identity signing** | Ed25519 (32-byte pubkey). For device-publickey, prekey signing, sovereign-register signature |
| **Hybrid KEX combine** | `HKDF(ML-KEM-shared ‖ X25519-shared ‖ transcript, salt=HYBRID_PQC_SALT_V1, info=HYBRID_PQC_INFO)` |

### 5.5 NFC collaborative pairing

| Item | Value |
|---|---|
| AID | `F0BCF1073A5100` (7 bytes, ISO-7816) |
| SELECT APDU | `00 A4 04 00 07 F0 BC F1 07 3A 51 00 00` |
| Payload (64 bytes) | `[32B X25519 ephemeral pubkey ‖ 32B random entropy]` |
| PSK derivation | HKDF-SHA256(shared=X25519(myPriv, theirPub), salt=`sha256(sorted(pubA, pubB))`, info=`"Q-Audion NFC Collaborative PSK v1"`, out=32B) |
| iOS limitation | iPhone cannot do HCE — iOS-to-iOS NFC pairing IMPOSSIBLE. iOS reader ↔ Android HCE only. |

### 5.6 Device-linking binary QR

| Item | Value |
|---|---|
| Layout | `[32B X25519 pubkey ‖ 4B big-endian length ‖ userId UTF-8 ‖ 16B auth code]` |
| Encoding | base64url (no padding) |
| URL wrapper | `qaudion://link/<base64url_blob>` |

### 5.7 VoIP push payload (cross-platform)

```json
{
  "type": "incoming_call",
  "call_id": "<uuid>",
  "caller_id": "<user_id>",
  "caller_name": "<display>",
  "call_type": "audio|video"
}
```

> **Server gap (P0 for iOS):** the lite server variant **does not currently emit APNs VoIP pushes** — only FCM. iOS Phase 6 (PushKit VoIP) is therefore **server-dependent**, not just client-dependent. See §10.1.

### 5.8 WebSocket envelope

```json
{ "type": "<snake_case>", "data": { … } }
```

> **Audit correction:** the server's lite variant does NOT carry an `id` field. ANDROID_REFERENCE.md §"WebSocket envelope" claims `{type, data, id}` — this is **stale**. iOS code that emits `id` is sending an ignored field. Correlation is by `call_id` / `recipient_id` / context. Update `ANDROID_REFERENCE.md` accordingly when this spec is approved.

### 5.9 TURN credentials (server-issued)

`username = "{userID}:{unix_timestamp}"`, `password = HMAC-SHA1(username, turn_secret)`, expires in 1h. Fetched via `GET /api/v1/calling/relays`.

### 5.10 Backup file format `.qabk` (iOS ↔ Desktop portable)

| Step | Algorithm |
|---|---|
| Master key derivation | scrypt(password, salt, N=2^15, r=8, p=1) → 32B |
| File body encryption | AES-256-GCM (12B nonce, 16B tag) |
| Container | (TBD — desktop has the spec; iOS must consume identically) |

> **Action item:** Phase 4 must include reading `qaudion-desktop/src/main/backup/*.ts` to extract the exact container layout (header / version / metadata block / encrypted payload).

### 5.11 Frozen wire types (committed)

These WS `type` strings and REST endpoints will not change per server team:

- WS: `authenticate`, `ping`, `audio_frame`, `call_offer`, `call_answer`, `call_ice`, `call_hangup`, `call_ready`, `call_processing`, `call_status`, `presence_subscribe`, `opaque_message`, `group_call_create/join/leave/end`, `device_register/list/sync/remove`.
- REST: `POST /api/v1/auth/login`, `POST /api/v1/auth/refresh`, `POST /api/v1/auth/logout`, `POST /api/v1/auth/recovery-setup`, `POST /api/v1/auth/recovery-verify`, `GET /api/v1/profile`, `PUT /api/v1/profile`, `POST /api/v1/contacts/discover-v2`, `GET /api/v1/contacts/pepper`, `POST /api/v1/contacts/sync`, `POST /api/v1/contacts/block`, `DELETE /api/v1/contacts/block/{user_id}`, `GET /api/v1/contacts/blocked`, `GET /api/v1/calling/relays`, `POST /api/v1/files/upload`, `GET /api/v1/files/{file_id}`, `POST /api/v1/account/fcm-token`, `GET /api/v1/version`, `GET /api/v1/health`, `GET /api/v1/config/client`, `GET /api/v1/flags`, `POST /api/v1/users/me/identity-key`, `GET /api/v1/users/{id}/identity-key`, `GET /api/v1/users/{id}/profile`.

## 6. Platform map — iOS surface vs Android / Desktop / Server

### 6.1 iOS today

**`QAudionApp/`** (the SwiftUI shell):
- Views: `ContentView`, `HomeView`, `ConversationListView`, `LoginView`, `RegisterView`, `ChatView`, `MessageBubbleView`, `CallView`, `VideoCallView`, `GroupCallView`, `CallSecurityBadge`, `WaveformView`, `SettingsView`.
- Services: `AuthService`, `CallService`, `ContactSyncService` (the latter untracked / USER WT).
- App entry: `QAudionApp.swift`, state: `AppState.swift`.

**`QAudionEngine/Sources/QAudionEngine/UI/`** (engine-level views, embedded into the app shell):
- Identity / keys: `KeyManagementView`, `QrIdentityView`, `QrScanView`, `DeviceManagementView`, `NfcExchangeView`.
- Voice / security: `VoiceEnrollmentView`, `VoiceAuthView`, `GuardianModeOverlay`, `SasVerificationView`, `TrustShieldView`, `SecurityDashboardView`, `SecuritySettingsView`.
- Communication: engine-level `ChatView`, `VideoCallView`, `ContactDetailView`.
- Root: `QAudionRootView`.

> **A.7 cleanup target:** there are TWO `ChatView.swift` files — `QAudionApp/Views/ChatView.swift` and `QAudionEngine/Sources/QAudionEngine/UI/ChatView.swift`. Same for `VideoCallView`. Engine UI was probably intended to be a reusable library; app shell inadvertently shadows it. Phase A.7 must decide which is canonical and consolidate.

**Engine layers:** `Crypto/`, `Audio/`, `Transport/`, `Backend/{Protocols,BCrypto,Upstream}`, `Integration/`, `Registry/`, `Sovereign/`, `Deepfake/`, `Analysis/`, `Core/`.

### 6.2 Android reference (qaudion-android-new) — 30 user-visible screens

Bottom-nav 4 tabs: `Chat List` / `Contacts` / `Calls` / `Settings`. Settings has 11 sub-screens (Security Dashboard, Device Manager, Link New Device, Profile, Privacy, Backup, OTA Update, About, Key Management, Transport Settings, Network Simulator).

Auth flow: `Splash` → `Welcome` → (`PhoneEntry` ⇒ `InviteCode` ⇒ `PasswordCreation` ⇒ `ProfileSetup` ⇒ `VoiceEnrollment` ⇒ `DeviceLink` ⇒ `OnboardingComplete`) | (`PasswordLogin`) | (`FastSetup` QR).

Calls: `IncomingCall` (full-screen Telecom CallStyle), `OutgoingCall`, `InCall`, `GroupCall`, `CallHistory`. Plus `NetworkSimulator` (dev-only).

NFC: `KeyExchangeNfcScreen` with explicit `Idle → Waiting → Exchanging → Success/Error` states + Android HCE service.

### 6.3 Desktop reference (qaudion-desktop) — 12 user-visible screens

Stack: Electron 33 + Svelte 5 + TypeScript. Pure-JS crypto (`@noble/post-quantum`, `@noble/curves`, Node `crypto`).

Screens: `Onboarding` / `ChatList` / `Chat` / `GroupChat` / `Contacts` / `ContactDetail` / `Calls` / `Call` / `Group` (group call) / `CreateGroup` / `GroupInfo` / `Settings`.

**Notable feature deltas to Android:**
- Has `GroupChat` as a separate screen from group calls. Android consolidates group messaging into `ChatDetail`.
- Has `CreateGroup` + `GroupInfo` as full screens (Android has them implicitly inside ContactsScreen + ChatDetailScreen).
- Has `Call` (1:1 active) + `Group` (group call) as separate routes.
- `Settings` is one screen, NOT 11 — desktop chose UI consolidation.

Backup: `.qabk` format using scrypt + AES-256-GCM. Portable iOS↔Desktop is a stated goal.

### 6.4 Server reference (bcrypto-server lite variant)

Stack: Go 1.25 + bbolt + `nhooyr.io/websocket` + Pion TURN + FCM v1 + Let's Encrypt + HTTP/2/3 + MASQUE.

REST endpoint surface: ~70 endpoints across `/auth`, `/contacts`, `/messages`, `/opaque`, `/calling`, `/identity`, `/profile`, `/users`, `/kms`, `/security`, `/files`, `/backup`, `/account`, `/discover`, `/register/sovereign`, `/groups`, `/updates`, `/models`, `/admin`, `/version`, `/health`, `/flags`, `/telemetry`, `/config`, `/quic`, `/masque`. Full inventory in agent's audit (Section 9 below references the file).

**Gaps for iOS:**
1. No APNs / no VoIP push in lite. iOS PushKit cannot work as-is — must add APNs server-side OR design degraded path (see §10.1).
2. No `id` correlation on WS envelope (iOS code that sends `id` is wasting bytes — harmless but cleanup-worthy).
3. Group call max 8 participants (may change; Track B).
4. Video upgrade flow + H.265 in flux (Track B).
5. MASQUE/QUIC discovery at `/quic` and `/.well-known/masque/udp/` is emerging — not required for v1.

## 7. Track A — Invariant-First (start NOW)

### A.0 Cross-Platform Invariants Document — verification & sign-off — **START HERE**

**File to write:** `docs/progress/INVARIANTS_VERIFIED.md` — pin the canonical bytes for every value in §5 of this spec by *reading* iOS / Android / Desktop / server constants and asserting equality.

**Why first:** every later phase silently assumes these values. The OpenRouter reviewer flagged this as the single most leveraged deliverable. Get the user (and the Android / desktop / server developers, even informally) to sign off — even a chat ack or a PR review is enough — before writing any feature code.

**Acceptance criteria:**
- All 11 sub-sections of §5 have a "verified ✅" checkbox with file:line citation per platform.
- Discrepancies are *flagged* (not auto-resolved). Each becomes a TODO for the user to decide.
- The doc is committed and `docs/progress/STATUS.md` is updated to point at it.

**Effort:** ~2-3h read-only audit. Zero code touched.

### A.1 UI Data Contract (View Model spec) — **START SECOND**

**Why before any UI work:** the OpenRouter review correctly identified that "in-call UI is mockup-driven" was *naive* — the SAS values, participant states, video upgrade state, deepfake confidence, all flow from the wire. We can't build the UI without knowing the *shape* of data the wire delivers.

**File to write:** `QAudionApp/Views/ViewModels/*.swift` — pure Swift structs with no wire imports, mirroring the data each screen consumes. Pair with `Mocks/*.swift` factories.

**Coverage:** every screen in §6.1 (iOS today + the missing Android screens we'll build) gets a ViewModel. Each ViewModel has a mock factory so SwiftUI previews + tests work without server.

**Why this is in Track A:** the *names* and *shapes* are decided in this spec from the merged audits. Even if a wire field gets renamed later, the ViewModel can stay stable behind a thin mapper. UI built against the ViewModel doesn't churn.

### A.2 Phase 4 — Key management depth + NFC collaborative exchange

**Stable inputs:** AID, HKDF info, payload layout from §5.5 are math/standards-locked. Won't change.

**Scope:**
- Implement `NfcCollaborativeExchange` Swift service using `CoreNFC` `NFCTagReaderSession` (iOS reader role only). State machine: Idle → Waiting → Exchanging → Success/Error matching Android Compose state.
- `KeyManagementView` enrichment: identity QR (already works) + key rotation + key backup (`.qabk` format from §5.10 — needs desktop spec extraction first).
- `DeviceManagementView` enrichment: list linked devices via `device_list` WS (frozen type per §5.11) + revoke.

**Wire dependencies:** only frozen WS types. Safe.

**Codemagic impact:** none.

### A.3 Phase 5 — CallKit integration

**Why Track A:** purely iOS-platform API; no server / Android / desktop dependency.

**Scope:**
- `CallKitService` wrapping `CXProvider`, `CXCallController`, `CXCallObserver`. Maps to iOS analogues of Android `QAudionConnectionService` (Telecom).
- Bridge to existing `CallService` so incoming/outgoing calls show the OS-native call UI.
- Audio routing (speaker / earpiece / Bluetooth) via `AVAudioSession` modes.

**Iteration constraint (per OpenRouter critique #4):** user is on Windows; testing CallKit fully requires a Mac or a TestFlight cycle. Mitigation:
- Define `CallKitManaging` protocol in `QAudionEngine`. Implement in iOS and a `MockCallKitProvider` for unit tests.
- Unit-test `CallService` against the mock; defer device validation to a single TestFlight tag (`v1.0.25-callkit`).

**Codemagic impact:** none (frameworks already linked in Phase 0.3).

### A.4 Phase 7 — In-call UI parity (SAS + waveform + transport + video PiP)

**Why Track A:** the *visual layout* of the 7 in-call elements (security badge, waveform TX/RX/Cipher, timer, avatar+name, mute/speaker/hold/end, video PiP, SAS prompt) is mockup-driven. The *data binding* uses the ViewModels from A.1 — wire schema can change behind the ViewModel without affecting the UI.

**Caveat:** video upgrade flow (`call_upgrade_request/response`, `call_video_state`) is currently MOVING (server commit `067a2d0`). Do the audio-only in-call UI in A.4; defer the video upgrade button to Track B until server flow stabilizes.

**Scope (audio-only in-call):**
- `InCallView` SwiftUI screen (replaces partial `CallView`) with the 7 elements.
- `SasVerificationView` becomes a child sheet that presents on first call with a new contact.
- Reuses `WaveformView` (already exists) for TX/RX/Cipher channels.
- Pull stats from `EngineStats` (already in engine).

**Iteration constraint:** layout changes should be testable in Xcode previews on Mac OR via Mac-CI screenshot diffs. User is on Windows; previews must be exercised by Codemagic itself OR deferred to TestFlight.

### A.5 Phase 6-prep — PushKit VoIP **scaffolding only** (not delivery)

**Why split:** iOS-side PushKit code (token registration, payload parsing, CallKit hand-off) is platform-only and Track A — it consumes the *frozen* VoIP payload spec from §5.7, which won't change. The actual *delivery* (server emits APNs VoIP push) is server-blocked — see §10.1.

**Scope:**
- `PushKitService` wrapping `PKPushRegistry` for `.voIP` type, registering on app launch.
- `application(_:continue:)` and `pushRegistry(_:didReceiveIncomingPushWith:)` plumbing.
- POST `/api/v1/account/fcm-token` (frozen endpoint) carrying APNs token in iOS variant — **document explicitly** that on iOS the "fcm-token" field carries an APNs token, server must route appropriately.
- Wire payload parser for `{type:"incoming_call", call_id, caller_id, caller_name, call_type}` (frozen per §5.7).
- Bridge to `CallKitService.reportIncomingCall(...)`.

**Cannot complete until:** server emits APNs VoIP pushes (Track B item — see §10.1 for design options).

### A.6 Phase 11-restructure — Settings split into 11 sub-screens (Android parity)

**Why Track A:** screen *structure* is UI; it doesn't depend on wire. Even sub-screens that show wire data (e.g. Security Dashboard showing key state) bind via ViewModels (A.1).

**Scope:** replace the single `SettingsView.swift` with a hub view + 11 sub-screens matching Android:
1. Account (Profile sub-screen) — display name, avatar, phone, extension
2. Security Dashboard — key state, device verification, wipe status
3. Device Manager — list + revoke + link new
4. Privacy — read receipts / typing / blocked list / disappearing-messages
5. Calls — codec / AEC-NS-AGC / VoIP background
6. Chat — read receipts / typing
7. Notifications — ringtone / quiet hours
8. Storage / Backup — `.qabk` upload + restore
9. About — version, compliance, legal links
10. Key Management (existing engine view, surfaced from Settings hub)
11. Transport — AUTO / P2P / TURN / Relay (matches Android `TransportSettingsScreen`)

(Android has a 12th: "Network Simulator (dev-only)" — out of scope for iOS unless user wants it.)

### A.7 Platform Scaffolding (per OpenRouter critique #3)

A bucket for purely-local iOS work with zero wire dependency that unblocks later phases:
- `BackendRegistry` audit + cleanup of the dual `BCrypto` / `Upstream` provider split — keep the abstraction but reduce dead code.
- DI container review for `QAudionApp/Services/*`.
- Migration of `Services/AuthService` to consume `AccountApi` directly (eliminate any duplicated state).
- Untracked working-tree hygiene: identify which of the stray 0-byte files (`'`, `.allocate(capacity`, `[DiscoveredContact]`, `Bool`, `String`, `Void)`, …) are accidental shell redirects safe to remove vs. user's in-progress work to leave alone.

### A — Track A summary order

1. **A.0 Invariants verification** (READ-ONLY, gate to all else)
2. **A.1 UI Data Contract / ViewModels** (foundation for all UI work)
3. **A.7 Platform Scaffolding** (parallel-safe cleanup)
4. **A.2 Phase 4 NFC + Key mgmt** (NFC AID frozen, low risk)
5. **A.3 Phase 5 CallKit** (independent platform API)
6. **A.6 Phase 11 Settings restructure** (UI-only)
7. **A.4 Phase 7 In-call UI** (consumes A.1, A.3)
8. **A.5 Phase 6-prep PushKit scaffolding** (waits for A.3 and §10.1 server resolution)

Estimated bandwidth: ~6 weeks of focused iOS work for one engineer with Codemagic-only loop.

## 8. Track B — Wire-deferred (in queue)

| # | Phase | Original 20-Apr name | Unblock criteria |
|---|---|---|---|
| B.1 | Phase 1 redo (sub-tasks) | WS code fix (Task 1.1), backup transport (§3.6-§3.8), security schemas (§3.11-§3.15) | (a) USER lands `BCryptoCallingApiImpl.swift`/`CallingApi.swift` WT (b) server team confirms zk-register/zk-auth/pqc-relay/threat-report/wipe-confirm shapes (c) backup-multipart shape pinned with desktop |
| B.2 | Phase 2 | FastSetup QR login + voice enrollment | server `/api/v1/admin/invite/fast-setup` admin-only — needs a *user-facing* invite-redeem endpoint pinned by server team. Voice enrollment endpoint not in server inventory — needs server team confirmation. |
| B.3 | Phase 3 | Device linking (binary QR + sync key + snapshot) | snapshot/sync endpoint pinned. Binary QR layout (§5.6) is frozen, but the server side that issues `userId + auth_code` is not yet documented. |
| B.4 | Phase 6 (delivery half) | PushKit VoIP **delivery** (server APNs emission) | server team picks an option from §10.1 |
| B.5 | Phase 7 (video half) | Video upgrade flow | server commits to H.264 vs H.265 + finalizes `call_upgrade_request/response/_video_state` |
| B.6 | Phase 8 | Chat parity (typing / attach / status) | `msg_send`/`msg_delivered`/`msg_read`/`msg_typing` WS types pinned (currently in Track B per audit) |
| B.7 | Phase 9 | Contacts blocked-list UI + phonebook + editor | `contacts/sync` + `contacts/discover-v2` are now frozen, BUT phonebook-import flow is still UI-pending. Could partially move to Track A once UI Data Contract done. |
| B.8 | Phase 10 | Group calls (ViewModel + SFU bridge) | SFU max-participants finalized (currently 8); `group_call_forward` schema reconciled (PHASE1_AUDIT.md row "group_call_forward"). |
| B.9 | Phase 12 | Tor / proxy real integration | server-side onion + MASQUE discovery; iOS uses `TorObfsTransport` already-stubbed |
| B.10 | "Group Chat" (NEW from desktop) | Separate group-chat screen (desktop has it; Android folds it into ChatDetail) | UX decision: does iOS follow Android (folded) or desktop (separate)? |
| B.11 | OTA model channel | `/models/desktop/aasist/{manifest,download}` Ed25519-signed | server team pins manifest signing format |

**Re-audit ritual** (per item): when user signals an unblock, parity agent re-reads the relevant server commit / Android working tree, refreshes `PHASE1_REST_AUDIT.md` (or a successor), then writes a focused mini-spec for that single item.

## 9. Track C — Phase 13 verification + TestFlight release

After Track A is fully merged AND ≥1 round of Track B convergence has happened:

1. **KAT vectors** — generate Swift KAT dumps for ML-KEM-1024 / X25519 / hybrid / NFC PSK / device-link blob; verify against Android + desktop dumps.
2. **Cross-client interop tests** — iOS↔Android voice call (audio + SAS), iOS↔Desktop voice call, iOS↔Android NFC pairing.
3. **Server interop** — full happy-path against staging bcrypto-server (register → login → contact discovery → 1:1 call → message).
4. **TestFlight tag `v1.0.30-final`** (or whatever the version is) — internal `Q-Audion testers` group.
5. **Apple inbox watch** — wait 24h for any ITMS-* validation rejections.

## 10. Open design issues (need user / server-team input)

### 10.1 APNs VoIP push gap (server-side)

Per server audit §5: *"Lite variant **does NOT support APNs**. iOS clients must use WebSocket + FCM fallback."*

Options:
- **Option α — server adds APNs.** Server team adds APNs HTTP/2 emission for `incoming_call` payload. Requires APNs auth token (.p8 from Apple Dev portal). Adds ~1-2 days server work. **Cleanest UX.**
- **Option β — iOS persistent WebSocket.** iOS keeps a persistent WS via VoIP background mode. Battery cost; iOS may suspend WS aggressively → calls drop in low-battery / Low Power Mode.
- **Option γ — silent push + WS reconnect.** Server uses APNs *background* push (not VoIP) to wake iOS, which then reconnects WS to fetch the offer. Adds a few seconds of latency (incoming-call ring delay). Also requires APNs in server.
- **Option δ — degraded "missed call" only.** No real-time incoming notification; user sees "X missed calls" on app open. **Worst UX, but unblocks ship.**

**Recommendation:** **α**. Worth the 1-2 days server work to keep iOS UX on par with Android Telecom. Until then, document expectation in iOS Settings → About: "VoIP push pending server upgrade."

**Action item:** ask server team to commit to one of α/β/γ/δ before A.5 (PushKit scaffolding) finalizes.

### 10.2 §3.11–§3.15 security endpoints

Already TODO'd in code per Task 1.4-b5. Server team must commit to either Android shape or iOS shape (or a third) for: `zk-register`, `zk-auth`, `pqc-relay`, `threat-report`, `wipe-confirm`. These power Sovereign-Identity, deepfake threat reporting, and remote-wipe. Until resolved, iOS UI surfaces (Security Dashboard, Threat Reports, Wipe-confirm flow) are partially stubbed.

### 10.3 Group Chat (desktop has, Android doesn't)

Desktop has a separate `GroupChat.svelte` screen. Android folds group messaging into `ChatDetailScreen`. **User must decide:** does iOS follow Android (one ChatView for both 1:1 and group) or desktop (separate screens)? This affects A.4 ChatList navigation, the canonical-`ChatView` consolidation in A.7, and B.10.

### 10.4 Phonebook import scope

Android has `ContactEditorScreen` + system `Contacts` integration. iOS has `ContactSyncService.swift` (USER WT, untracked). Decision needed: does iOS sync iOS Contacts → server, or only one-way phone-hash discovery? Affects Phase 9 (Track B).

## 11. Convergence checkpoint protocol (handling the moving target)

Each iOS commit that touches a server endpoint records a server snapshot. Mechanism:

1. New file: `docs/progress/SERVER_SNAPSHOTS.md` — append-only log: `YYYY-MM-DD | endpoint | iOS commit | observed wire shape (one-line) | server git sha if known`.
2. Each iOS commit message that lands a wire-aware change includes a `Wire-Snapshot:` trailer with the server sha (or `unknown`) and the endpoint touched.
3. When user signals "I changed `<endpoint>`", parity agent grep-searches the snapshot log to find affected iOS commits → re-audit and patch.
4. KAT vectors live at `QAudionEngine/Tests/cross_platform_vectors.json`; updated whenever an invariant is touched (must NEVER touch — that's the contract).

This keeps rework targeted and prevents whole-plan invalidation when the server shifts.

## 12. Codemagic preservation rules

These are operative rules for the spec's executors:

1. **Never edit** `codemagic.yaml`, `Info.plist` `UIBackgroundModes`/`aps-environment`, `QAudion.entitlements`, `QAudionApp/project.yml` `dependencies:` block, `Assets.xcassets/AppIcon.*`, the ONNX Patch step, or the signing config.
2. **Never bump** `onnxruntime-swift-package-manager` past `1.17.0`.
3. **Never push to `main`** during this spec's execution. All work goes on `feature/ios-android-parity` (or sub-branches) and lands via Phase-end TestFlight tags.
4. **Tags follow the existing scheme:** `v1.0.24-ph1`, `v1.0.25-callkit`, `v1.0.26-ui-parity`, `v1.0.30-final`, etc. Do not reuse old tags.
5. **Treat Apple emails post-upload as canonical truth.** Codemagic publishing-success ≠ Apple-accepts.
6. **D-05 hygiene:** USER's uncommitted WT files (`BCryptoCallingApiImpl.swift`, `BCryptoGroupCallManager.swift`, `BCryptoWebSocketClient.swift`, `BCryptoBackendProvider.swift`, `BCryptoPresenceManager.swift`, `CallingApi.swift`, `QAudionCallIntegration.swift`, `ContactSyncService.swift`) **must NOT be staged or committed by parity agents**. They're tracked in `docs/progress/STATUS.md` §"Working-tree hygiene".

## 13. Risks & mitigations

| Risk | Mitigation |
|---|---|
| User's parallel server/Android work invalidates Track A constants | A.0 invariants verification + sign-off; commits carry `Wire-Snapshot:` trailers |
| CallKit can't be tested without a Mac → bug discovered post-TestFlight | `CallKitManaging` protocol + mock + unit tests; tight TestFlight cycle on `v1.0.25-callkit` |
| ONNX patch step breaks on a future macOS runner | Pin Codemagic image; keep onnxruntime at `1.17.0`; CLAUDE.md §4 covers fallback |
| Apple changes Xcode 16.2 → 26 SDK requirement (deadline 2026-04-28 = TODAY) | CLAUDE.md §12 already flagged; bump `xcode: 26.0` in `codemagic.yaml` *only when* Codemagic image is available; until then the existing tag remains accepted |
| Server APNs decision (§10.1) takes longer than expected | A.5 PushKit scaffolding finishes regardless; iOS gracefully degrades to WS-only delivery in the meantime |
| Spec drift — this doc gets stale | `docs/progress/STATUS.md` gets updated each Track A item closure; this spec is the "design as of 2026-04-28", not a living doc |
| Audit hooks break CI silently | Phase 0 is sacred — never delete/disable hooks. If a hook fails, fix the underlying cause per CLAUDE.md §3 |

## 14. Definition of done (for this spec)

- [ ] User reviews this spec and accepts/changes/rejects.
- [ ] On accept: `writing-plans` skill is invoked to produce a per-phase implementation plan for Track A.
- [ ] The 11 invariants (§5) are pinned in a `docs/progress/INVARIANTS_VERIFIED.md` and circulated to server / Android / desktop developers.
- [ ] `STATUS.md` is updated to point at this spec as the active design.
- [ ] Track B items are recorded in `STATUS.md` "Task dependencies blocked" table with their unblock criteria.

## 15. References

- `docs/superpowers/plans/2026-04-20-ios-android-parity.md` — predecessor 13-phase plan.
- `docs/progress/PHASE1_AUDIT.md` — WS command audit (2026-04-20).
- `docs/progress/PHASE1_REST_AUDIT.md` — REST endpoint audit (2026-04-20).
- `docs/progress/ANDROID_REFERENCE.md` — wire facts cache. **Note:** §"WebSocket envelope" claim that envelope has `id` field is stale per server audit §3 — must be corrected.
- `docs/progress/STATUS.md` — current state.
- `docs/progress/TASK_LOG.md` — append-only task log.
- `docs/progress/DECISIONS.md` — decision log.
- `docs/progress/CODEMAGIC_GUARD.md` — Codemagic invariants.
- `CLAUDE.md` — project-wide agent instructions (12 hard-won rules).
- Sibling repos: `qaudion-android-new`, `qaudion-desktop`, `bcrypto-server` (out of this repo, read-only references).
- OpenRouter review (Gemini 2.5 Pro, 2026-04-28): graded plan 80%, called out Invariants doc as highest-leverage deliverable, surfaced UI Data Contract, Platform Scaffolding category, and Codemagic-only iteration loop constraint — incorporated as A.0, A.1, A.7, and the iteration-constraint notes in A.3/A.4.
