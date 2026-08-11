# BitChat-Inspired Features — Design Spec (Emergency Wipe + BLE Offline Text Fallback)

Authored 2026-08-11 on branch `claude/bitchat-quadion-evaluation-m6sff7`,
following an evaluation of [permissionlesstech/bitchat](https://github.com/permissionlesstech/bitchat)
(Bluetooth-mesh offline chat, ~35k stars, Unlicense) requested to assess
which of its ideas are worth bringing into Q-Audion. This is a **design
doc, not an implementation** — no code changes are included. See §4 for
recommended next steps.

Mirror copy lives at:
- `Q-Audion-IOS/BITCHAT_FEATURES_DESIGN.md` (this file)
- `New-Q-Audion-Android/BITCHAT_FEATURES_DESIGN.md`

Both platforms are covered in the same document because the two features
below are cross-platform by nature (wipe UX parity, and any BLE mesh wire
format must be byte-identical between iOS and Android, same discipline as
`WIRE_SPEC.md`).

---

## 0. Scope & non-goals

Of everything BitChat does, two ideas were flagged as worth designing for
Q-Audion:

1. **Emergency / panic wipe** (BitChat: triple-tap clears all local data).
2. **BLE mesh as an offline *text* fallback transport** for chat, not
   calls.

**Non-goals, explicitly ruled out during evaluation:**

- **Voice/calls over BLE mesh.** BitChat's own whitepaper documents
  multi-hop flood relay with 10–220ms jitter per hop and TTL up to 7 hops.
  That is unusable for real-time Opus/SILK streaming — this is a physical
  bandwidth/latency limit of BLE mesh flooding, not an engineering gap to
  close.
- **Adopting BitChat's Nostr internet-fallback path.** It would duplicate
  what `bcrypto-server` already does, while adding a dependency on public
  third-party relays outside Q-Audion's audit perimeter.
- **Adopting BitChat's crypto as-is.** BitChat's live-session encryption is
  Noise `XX` over Curve25519 only (no post-quantum margin), and its
  store-and-forward path uses one-way Noise `X` with **no forward
  secrecy** by the authors' own admission. Neither is acceptable as the
  actual encryption for Q-Audion messages — see §2.4.

---

## 1. Feature A — Emergency / Panic Wipe

### 1.1 Existing primitives (already in the codebase, confirmed by reading the source)

- **iOS** — `QAudionApp/Services/LocalCryptoWipe.swift`, `LocalCryptoWipe.wipeAll()`.
  A free function (deliberately not taking `AppState`, per §16 of this
  file's own CLAUDE.md) that already wipes `SovereignIdentityManager`,
  `SovereignKeyVault`, the ratchet/group-session Keychain vaults, contacts,
  conversations, threat-report log, and the published-fingerprint
  UserDefaults entry. Already wired into the `remote_wipe` WS handler and
  account deletion.
- **Android** — `core/core-data/.../security/RemoteWipeHandler.kt`,
  `RemoteWipeHandler.execute(reason)`. A DI-injected, `suspend` class that
  wipes every Room table plus the crypto vaults (`SovereignKeyVault`,
  `RatchetVault`, `GroupSessionVault`, `LongTermX25519Vault`,
  `Ed25519DeviceSigner`) and tokens/profile, best-effort per step.
  Currently invoked only from the FCM `remote_wipe` payload path.

### 1.2 The gap

Both wipe paths assume **connectivity** (a WS message or an FCM push) or
an **authenticated in-app menu action**. Neither is reachable from a
local, offline, no-network, no-menu-navigation gesture. BitChat's
triple-tap is valuable precisely because it works with zero connectivity
and zero UI navigation — the scenario is a user under duress who needs
data gone *now*, not after finding Settings → Security → Wipe.

### 1.3 Design

Both platforms: reuse the existing wipe function unchanged, add a new
local trigger and confirmation UX layer only.

- **iOS**: a triple-tap gesture recognizer (`.onTapGesture(count: 3)`) on
  a fixed, always-reachable surface, calling `LocalCryptoWipe.wipeAll()`
  followed by the same forced-logout / onboarding-navigation path the
  `remote_wipe` handler already triggers in `AppState.swift`.
- **Android**: the analogous gesture on a fixed surface (candidate:
  `SecurityDashboardScreen.kt`), calling
  `RemoteWipeHandler.execute(reason = "local_panic_wipe")` from a
  ViewModel coroutine scope — same call shape as the existing
  FCM-triggered call site.

No new crypto, no new entitlement, no new source file risk (per this
repo's CLAUDE.md §16, since no `AppState`-typed parameter is introduced)
— this is UI-layer wiring onto code that already exists and is already
exercised by the remote-wipe path.

### 1.4 Open questions — need a product decision before implementation

1. **Confirmation UX.** Bare triple-tap (BitChat's own model — zero
   friction, but an accidental wipe is unrecoverable) vs. triple-tap plus
   a second confirming step (hold, or a second tap window) that stays
   fast under duress but reduces accidental triggers.
2. **Trigger surface.** Global (reachable from anywhere in the app, most
   "panic-ready") vs. confined to the Security Dashboard (safer against
   false triggers during normal fast tapping, e.g. in chat). BitChat
   scopes it to its main list view, not truly global.
3. **Call teardown ordering.** Confirm a panic wipe during an active call
   tears the call down in the same order the existing remote-wipe path
   does, so no audio frame processing races the vault clear.

### 1.5 Effort estimate

**Small** — no new module, no new entitlement, no wire-format change.
Primarily the gesture recognizer, the confirmation-UX decision from §1.4,
and wiring to already-existing, already-tested wipe functions. Estimated
0.5–1 day per platform, including a Maestro (iOS) / instrumented (Android)
UI test for the trigger path.

---

## 2. Feature B — BLE Offline Text Fallback (design only — not scoped for immediate implementation)

### 2.1 Goal

Give **chat** (not calls) a fallback delivery path for short text messages
between nearby devices when no connectivity path exists at all — today
`TransportPreferences.Mode` (Android) covers AUTO / FORCE_P2P / FORCE_TURN
/ FORCE_WS, all of which assume *some* form of internet reachability.
Adapted from BitChat's proven design, a BLE mesh path would let two
physically-nearby devices exchange text with zero connectivity (airplane
mode, no SIM, a censored or down network).

### 2.2 Architecture sketch, adapted from BitChat

- **Transport**: CoreBluetooth (iOS) / Android BLE central+peripheral dual
  role (as BitChat does), advertising a Q-Audion-specific service UUID.
- **Relay**: TTL-bounded flood (start 5–7 hops, decrement per relay,
  density-adaptive cap as BitChat does), LRU dedup keyed on
  sender+timestamp+payload-digest, jittered relay delay to avoid BLE
  collision storms — same shape BitChat documents in its whitepaper.
- **Store-and-forward**: reuse the *existing* outbox pattern already in
  the codebase rather than reinventing BitChat's courier system from
  scratch. Android's `PendingSendOrchestrator` / `PendingSendDao`
  (`core/core-data/.../ws/PendingSendOrchestrator.kt`) already implements
  exactly this shape — attempts, exponential backoff, a
  PENDING→IN_FLIGHT→DONE/FAILED state machine — for the WS path today. A
  BLE variant would add a new `PendingSendEntity.KIND_BLE_MESH` and a
  drain loop keyed to BLE peer presence instead of WS connectivity state.
  The iOS-side equivalent send-queue needs the same audit (not yet
  located in this pass — follow-up task before implementation).
- **Peer discovery**: signed periodic BLE advertisements, duty-cycled for
  battery (BitChat backs off 4s → 15–30s once connected — a reasonable
  starting point to tune from).

### 2.3 Explicitly out of scope for this feature too

- Voice — see §0.
- BitChat's Nostr fallback — see §0.
- BitChat's own crypto scheme as the actual encryption — see §2.4.

### 2.4 Crypto — must diverge from BitChat, reuse Q-Audion's existing PQC stack

BitChat's live-session Noise XX/Curve25519 has zero post-quantum margin,
which directly contradicts Q-Audion's positioning, and its
store-and-forward path has **no forward secrecy** by the authors' own
admission. The design constraint here: BLE is a new **transport** carrying
ciphertext already produced by Q-Audion's existing hybrid ML-KEM-1024 +
X25519 handshake and per-message ratchet (`MessageRatchet` /
`ForwardSecrecy` / `RatchetVault` — same types used for the WS path today,
mirrored on iOS), not a new crypto scheme layered under it. Doing it this
way avoids inheriting BitChat's own admitted weakness for messages that
sit waiting in the mesh.

A BLE-specific HKDF label will be needed for any session binding at the
transport layer, following the existing `WIRE_SPEC.md` labelling
convention (e.g. `q-audion-ble-mesh-v1`) — exact shape to be defined in a
`WIRE_SPEC.md` addendum, with cross-platform KAT vectors, once this design
is approved. Not defined yet in this pass.

### 2.5 Platform-specific constraints

**iOS**
- New entitlement/Info.plist keys: `NSBluetoothAlwaysUsageDescription`,
  plus `bluetooth-central`/`bluetooth-peripheral` background modes for
  background mesh participation — both carry App Review and battery
  scrutiny.
- Per this repo's CLAUDE.md §16: any new Swift file interacting with app
  state must take primitives + `@MainActor` closures, never `AppState`
  directly.
- Per CLAUDE.md §14: this is a large enough subsystem that it should be
  planned as multiple new files under `Services/` (or a new
  `QAudionEngine` module) from the start, not appended to existing
  large files like `ChatDetailScreen.swift`.

**Android**
- New permissions: `BLUETOOTH_SCAN`, `BLUETOOTH_ADVERTISE`,
  `BLUETOOTH_CONNECT` (API 31+), `ACCESS_FINE_LOCATION` for BLE scan on
  older APIs.
- A foreground service would be required for background mesh
  participation — same category of Play Store/battery scrutiny as the
  existing `CallForegroundServiceCoordinator`.

### 2.6 Effort estimate

**Large** — a new subsystem on both platforms: BLE stack, mesh relay
logic, outbox extension, a new `WIRE_SPEC.md` addendum with cross-platform
KAT vectors, new permissions/entitlements with store-review implications,
and dedicated battery testing. This should get its own multi-week plan
doc (Android already has a `docs/superpowers/plans/` convention for this)
before any code is written — **not** scoped as a quick add.

### 2.7 Open questions — need a decision before implementation starts

1. **Export-control impact** of a second radio-based crypto transport —
   flag to legal / dual-use-export-control review, per this repo's
   existing note that ML-KEM is not standard "mass market" cryptography.
2. **Actual demand** — is offline BLE text a validated user scenario, or
   speculative? Worth confirming before a multi-week build.
3. **Metadata exposure in the mesh.** Even with Q-Audion's own AEAD
   payload encryption, BitChat's whitepaper notes that only Noise packets
   get PKCS#7-bucketed padding — other traffic (and per-hop timing) leaks
   size/timing metadata to every relaying device. Needs an explicit
   threat-model writeup before shipping, since messages here physically
   transit through other users' devices.

---

## 3. Summary

| Feature | Effort | New crypto scheme needed? | Ready to implement now? |
|---|---|---|---|
| Emergency wipe (§1) | Small (0.5–1 day/platform) | No — reuses existing wipe primitives | Yes, pending the 2 UX decisions in §1.4 |
| BLE offline text fallback (§2) | Large (multi-week) | No new scheme, but needs a `WIRE_SPEC.md` addendum | No — needs its own plan doc + legal/export review first |

## 4. Recommended next steps

1. Get product sign-off on the two open questions in §1.4, then implement
   the emergency-wipe gesture on both platforms — small, self-contained,
   no dependencies on §2.
2. If BLE offline fallback is confirmed as wanted, open a dedicated plan
   doc (`docs/superpowers/plans/...-ble-mesh-fallback.md` on Android,
   equivalent on iOS) scoping §2 into concrete milestones, starting with
   the `WIRE_SPEC.md` addendum and cross-platform KAT vectors before any
   BLE stack code, and loop in export-control review per §2.7.1.

---

**Sources:** [permissionlesstech/bitchat](https://github.com/permissionlesstech/bitchat) (README.md, WHITEPAPER.md).
