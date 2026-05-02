# iOS Parity Audit — 2026-05-02

> **Author:** parity-research agent
> **Branch sampled:** `feature/ios-android-parity` HEAD (= `f367e64` voice-note + perms; same source files as `main` HEAD `70be347`).
> **Comparators:** `qaudion-android-new` (canonical), `bcrypto-server` `cmd/bcrypto-lite/main.go`, `qaudion-desktop`.
> **Predecessor:** `PHASE1_REST_AUDIT.md` (2026-04-20) — this doc tracks delta only and adds WS / opaque-mailbox / sealed-sender / Sigsum / push / crypto / call / P0 dimensions the prior audit ignored.
> **Note on STATUS.md:** STATUS.md is frozen at 2026-04-28. The `feature/ios-android-parity` branch has had ~250 unrelated `W***` commits piled on top (voice-notes, GDPR export, image attachments, App Store polish). None of those commits touch the wire-alignment surface the user is asking about; STATUS.md's "ultime task" sections are accurate for the wire layer — just buried.

---

## 1. REST drift status — delta vs PHASE1_REST_AUDIT.md (2026-04-20)

### 1.1 Endpoints fixed since 2026-04-20 (verified in current source)

| # | Endpoint | Audit § | Closing commit | Verification |
|---|---|---|---|---|
| 1 | `POST register` field shape | §3.1 | `2e78912` (1.4-a) | `BCryptoAccountApiImpl.swift` register method now hashes phone via `PhoneHash.hash` and sends `password` + `display_name` |
| 2 | `POST auth/login` field key | §3.2 | `2e78912` (1.4-a) | login now wires `phone_number` (was `phone_hash`) |
| 3 | `PUT profile` shape | §3.3 | `04f706b` (1.4-b3) | `(displayName?, statusMessage?, avatarUrl?)` JSON-only, multipart branch dropped |
| 4 | `POST contacts/sync` schema | §3.4 | `baf314d` (1.4-b1) | `{contacts:[SyncContactEntry]}` matching Android |
| 5 | `GET contacts/blocked` decode | §3.5 | `baf314d` (1.4-b1) | `{blocked:[BlockedContact]}` matching Android |
| 6 | `POST device/publickey` payload | §3.9 | `c6e605e` (1.4-b2) | `BCryptoKmsClient.swift`: drop `device_id`, default `key_type="x25519"` |
| 7 | `GET kms/pending` envelope + DTO | §3.10 | `c6e605e` (1.4-b2) | `{keys:[KmsKeyDto]}` with full DTO fields |
| 8 | `security/threat-report` field names | §3.14 | `b86f39c` (W12.A) | `BCryptoSecurityApiImpl.swift:53-66` — `{category,details,severity}` matches Android |
| 9 | 5 security endpoints | §3.11 §3.12 §3.13 §3.14 §3.15 | `b86f39c` (W12.A) | `BCryptoSecurityApiImpl.swift` rewritten to Android shapes; TODO blocks gone |
| 10 | Missing endpoints batch | §3.16 | `c0c8026` (1.4-b4) | `AccountApi.recoverySetup/Verify/getPublicUser` + new `BCryptoSystemClient` (`getVersion/getHealth/lookupByExtension`) |

### 1.2 Endpoints STILL drifting

| # | Endpoint | iOS file:line | Drift | Impact |
|---|---|---|---|---|
| D-1 | `POST backup/upload` | `BCryptoStorageApiImpl.swift` (uploadBackup) | Sends JSON `{key,data:base64}`; Android sends multipart `backup` + `key_hint` part | Backup interop broken Android↔iOS — audit §3.6 still open |
| D-2 | `GET backup/download/{id}` | `BCryptoStorageApiImpl.swift` (downloadBackup) | Parses JSON `{data:base64}`; server streams raw bytes | Will truncate/decode-fail on real binaries — audit §3.7 still open |
| D-3 | `GET backup/list` | `BCryptoStorageApiImpl.swift` (listBackups) | Decodes `{keys:[String]}`; Android `{backups:[BackupEntryDto]}` with `size_bytes`/`created_at`/`key_hint` | Loses metadata — audit §3.8 still open |
| D-4 | `POST account/apns-voip-token` | `BCryptoAccountApiImpl.swift:102` + `AppState.swift:551` | iOS-only endpoint (no Android equivalent — Android uses `account/fcm-token`). Wire works against server `account_apns_voip_token.go` but no FCM-style fallback for split builds | Acceptable but worth pinning in `ANDROID_REFERENCE.md` as iOS-only-by-design |

### 1.3 Endpoints still MISSING on iOS

| Endpoint | Status |
|---|---|
| `GET /api/v1/updates/check` | Used by `AppUpdateChecker.swift:52` — present, but `getOtaUpdate` not exposed via `AccountApi`/`BCryptoSystemClient` protocol |
| `GET /api/v1/updates/download/{id}` | Not implemented — TestFlight is the iOS update channel, so unlikely to be needed; but the Android contract still expects it |
| `GET /api/v1/updates/publickey` | Not implemented — Android uses for OTA Ed25519 trust pinning |
| `POST /api/v1/opaque/send` (REST sealed-sender opt-in) | **Not implemented** — see §3 below |

### 1.4 iOS-only endpoints (still ahead of Android)

Unchanged from §2 of PHASE1_REST_AUDIT.md: `auth/oidc*`, `auth/challenge*`, `register/sovereign*`, `security/cert-info`, `security/compliance`, `models/*` (AASIST), `contacts` POST/DELETE.

### 1.5 Net delta vs 2026-04-20 snapshot

- **24 → 30** of 35 Android endpoints now covered (added recovery-setup/verify, users/{id}, version, health, directory/by-extension).
- **12 payload drifts → 3 surviving** (backup upload + backup download + backup list — all in `BCryptoStorageApiImpl`). Plus 1 server-side endpoint not yet coded on iOS (`opaque/send`).
- All 5 security endpoints aligned (was the biggest drift block).
- D-CRITICAL count down to **0** for auth surface.

---

## 2. WebSocket message-types alignment

### 2.1 Server-dispatched WS types (`bcrypto-lite/main.go`)

Authoritative list found via grep `case "...":` in `cmd/bcrypto-lite/main.go`:

| Type | main.go:line | Notes |
|---|---|---|
| `audio_frame` | 3335 | per-frame relay |
| `video_frame` | 3439 | uplift Track B.5 |
| `opaque_message` | 3542 | legacy single-hop opaque relay |
| `presence_subscribe` | 3607 | subscribe to user-id list |
| `call_offer` | 3684 | with pre-negotiation |
| `call_processing` | 3768 | server→caller pre-neg ack |
| `call_ready` | 3786 | server→caller "ringing" |
| `call_hangup` | 3826 | terminate |
| `opaque_msg_send` | 3896 | **mailbox-based opaque relay** (post-2026-04 addition) |
| `opaque_msg_ack` | 3991 | ack of mailbox delivery |
| `call_answer` / `call_ice` / `msg_send` / `msg_delivered` / `msg_read` / `msg_typing` | 4010-4011 | generic relay branch (sends `msg_receive` to recipient for `msg_send`, see line 4038) |

### 2.2 Android WS-type catalog (`core/core-data/.../data/ws/WsCommand.kt:256-280`)

`authenticate, call_offer, call_answer, call_ice, call_hangup, call_processing, call_ready, call_upgrade_request, call_upgrade_response, call_video_state, opaque_message, audio_frame, video_frame, presence_subscribe, msg_send, msg_delivered, msg_read, msg_typing, group_msg_send, group_call_create, group_call_join, group_call_leave, group_call_forward, group_call_end, ping`

### 2.3 iOS WS senders (across `BCrypto*ApiImpl.swift` + `AppState.swift`)

- `BCryptoCallingApiImpl.swift:29-104` — sends: `call_offer`, `call_answer`, `call_ice`, `call_hangup`, `call_processing`, `call_ready`. (Camel→snake fixed in W77.)
- `BCryptoMessageApiImpl.swift:25-83` — sends: `msg_send`, `msg_delivered`, `msg_read`, `msg_typing`. Wire fields are snake_case (`recipient_id`, `encrypted_payload`, `client_msg_id`, `is_typing`).
- `BCryptoPresenceManager.swift:55,68,78` — sends `presence_subscribe`.
- `BCryptoWebSocketClient.swift:163` `sendOpaqueMessage` → `opaque_message`.
- `BCryptoWebSocketClient.swift:167` `sendAudioFrame` → `audio_frame`.
- `BCryptoWebSocketClient.swift:183` `authenticate`.
- `AppState.swift:712,718` — `registerHandler(type: "msg_delivered" / "msg_read")` for inbound receipts.

### 2.4 Comparison table

| Type | Server | Android | iOS sends | iOS receives | Status |
|---|---|---|---|---|---|
| `authenticate` | ✓ | ✓ | ✓ | n/a | OK |
| `call_offer` | ✓ | ✓ | ✓ | ✓ | OK |
| `call_answer` | ✓ | ✓ | ✓ | ✓ | OK |
| `call_ice` | ✓ | ✓ | ✓ | ✓ | OK |
| `call_hangup` | ✓ | ✓ | ✓ | ✓ | OK |
| `call_processing` | ✓ | ✓ | ✓ | ✓ (`onCallProcessing` :66) | OK |
| `call_ready` | ✓ | ✓ | ✓ | ✓ (`onCallReady` :75) | OK |
| `call_ring` | ✓ | ✓ | — | ✓ (`onCallRing` :85) | iOS receives but never sends; Android server emits server-side. OK. |
| `call_peer_offline` | ✓ | ✓ | — | ✓ (`onCallPeerOffline` :92) | OK |
| `call_cancel` | ✓ | ✓ | — | ✓ (`onCallCancel` :99) | OK |
| `call_upgrade_request/response` | ? (not in main.go grep) | ✓ | **— missing** | **— missing** | Drift: Android can request audio→video upgrade; iOS can't initiate or respond |
| `call_video_state` | ? | ✓ | — | — | Drift: video state propagation |
| `opaque_message` (legacy) | ✓ | ✓ | ✓ | ✓ | OK |
| `opaque_msg_send` (new) | ✓ | **— missing** (only `opaque_message` in WsCommand.kt) | **— missing** | **— missing** | Both clients still on legacy path; the post-2026-04 server addition is unused by both |
| `opaque_msg_ack` | ✓ | **— missing** | **— missing** | **— missing** | Same as above |
| `audio_frame` | ✓ | ✓ | ✓ | n/a | OK |
| `video_frame` | ✓ | ✓ | — | — | Drift: video uplift not wired on iOS or Android — Track B.5 |
| `presence_subscribe` | ✓ | ✓ | ✓ | ✓ (handler in `BCryptoPresenceManager`) | OK |
| `msg_send` | ✓ | ✓ | ✓ | n/a (server fans out as `msg_receive`) | OK |
| `msg_receive` | server emits | ✓ | n/a | ✓ (`AppState.handleIncomingMessage`) | OK |
| `msg_delivered` | ✓ | ✓ | ✓ | ✓ | OK — but iOS sends `{message_ids:[id]}` array (line 43) and the audit chain confirms server expects `[]string` |
| `msg_read` | ✓ | ✓ | ✓ (`{sender_id, message_ids:[]}`, lines 56-59 + 67-76) | ✓ | OK |
| `msg_typing` | ✓ | ✓ | ✓ | ? — no inbound handler grep hit on iOS for `msg_typing` | **Probable drift**: iOS sends but does not surface typing receipts |
| `group_msg_send` | ? | ✓ | — | — | Drift: group chat fan-out unimplemented on iOS |
| `group_call_*` (5 types) | ? | ✓ | — | — | Drift: group calling unimplemented on iOS |
| `delete_for_me` (audit P0 #2.x — landed 2026-05-01 W326 per `314b78b`) | ? | ? | — | — | Recent — not yet a WS-type; verify |
| `key_rotation` | not in server grep | not in Android WsCommand.kt | — | — | Pure crypto-layer event today; not WS |
| `ping` | ✓ (server replies `pong`/`heartbeat_ack`) | ✓ | ✓ (keepalive timer `BCryptoWebSocketClient.swift:271`) | ✓ | OK |

### 2.5 Net WS deltas

- iOS missing **5 send types**: `call_upgrade_request`, `call_upgrade_response`, `call_video_state`, `group_msg_send`, `group_call_*` (5).
- iOS missing **inbound `msg_typing` handler** (not registered anywhere).
- iOS and Android **both** miss the new `opaque_msg_send`/`opaque_msg_ack` mailbox path — server fix landed 2026-05-01 (`9f33c2c`) but no client speaks it. Plan §6.iOS / §6.Android both list this as P0 still-open.
- No iOS-only WS types found.

---

## 3. Opaque mailbox + sealed-sender + Sigsum gossip on iOS

### 3.1 Server side just landed

| Server commit | What it added |
|---|---|
| `9f33c2c` | `sealed_sender_cert_b64` opt-in field on `POST /api/v1/opaque/send`; if present, `internal/sealed_sender.Guard` validates the cert via `internal/sealed_sender/middleware.go` |
| `e5129db` | Sigsum gossip middleware globally — reads `X-Sigsum-Witness-TreeHead` from authenticated clients, attaches `X-Sigsum-Gossip-TreeHead` from a different client to outbound responses (`internal/sigsum/gossip_http.go:38-40`) |
| `bd2dc12` | server-side `sealed_sender.Guard` (the underlying validator) |
| `6712ced` | `sigsum.GossipStore` — split-view detection substrate |

### 3.2 iOS side — current state

| Surface | Status | Evidence |
|---|---|---|
| REST `POST /api/v1/opaque/send` client | **NOT IMPLEMENTED** | `grep -rn "/api/v1/opaque/send\|opaque/send" --include="*.swift"` returns zero hits |
| WS `opaque_message` client | OK | `BCryptoWebSocketClient.swift:163` |
| WS `opaque_msg_send`/`opaque_msg_ack` (mailbox) | **NOT IMPLEMENTED** | No grep hit anywhere in iOS |
| `OpaqueMailbox` (mailbox-id derivation + envelope encryption) | Implemented (`Crypto/OpaqueMailbox.swift`) | Uses `qaudion-mailbox-v1`, `qaudion-call-v1`, `qaudion-envelope-key-v1` HKDF/HMAC labels — match Android per file's "match Android" comments |
| Sealed-sender v2 cert encoder/signer | **NOT IMPLEMENTED** | Zero Swift hits for `sealed_sender`, `SealedSender`, or any cert-encoder; `SealedSenderCert*` lives only in `bcrypto-server/internal/sealed_sender/` (Go) |
| Sigsum `X-Sigsum-Witness-TreeHead` outbound header | **NOT IMPLEMENTED** | Zero Swift hits for `X-Sigsum`, `tree.head`, `gossip` (only false-positive: `gossip` as a BIP-39 word in `RecoveryMnemonic.swift:128`) |
| Sigsum `X-Sigsum-Gossip-TreeHead` inbound parsing | **NOT IMPLEMENTED** | same |

### 3.3 Net opaque/sealed/Sigsum status

iOS speaks neither the new mailbox-relay (`opaque/send` REST + `opaque_msg_send` WS) nor the privacy/integrity middlewares the server now optionally enforces. The legacy `opaque_message` WS path still works (server line 3542 still routes it), so calling + key-exchange interop is fine — but the server's anti-amplification + split-view-detection upgrades are invisible to iOS.

---

## 4. Push delivery (PushKit + APNs)

### 4.1 iOS state

- `PushKitProvider` lives in engine, wired in `AppState.swift:171,313`.
- VoIP token cached at `AppState.swift:90` (`W75`).
- Token registered to server via `POST /api/v1/account/apns-voip-token` (`AppState.swift:551`, `BCryptoAccountApiImpl.swift:102`). Body `{voip_token: <hex>}`.
- Incoming push → CallKit handoff wired in `AppState.swift:311-365`.

### 4.2 Server state

- `cmd/bcrypto-lite/account_apns_voip_token.go:38,47-48,87,94` — accepts `{voip_token}` JSON, stores in `accounts.APNsVoipToken`. Hex length validated at 64 (`apnsVoipTokenLenHex`).
- APNs HTTP/2 dispatcher with token-based JWT auth landed in W13.D commit `3ff8e47` (per TASK_LOG line 25 + STATUS.md §10.1 ✅).
- DB migration 014 added `devices.push_platform` column; dispatcher routes on `platform="ios-apns"`.
- Activation env vars: `BCRYPTO_APNS_KEY_PATH/KEY_ID/TEAM_ID/BUNDLE_ID`.

### 4.3 What's left to close the loop

- **Operational, not code:** server admins must drop the `.p8` APNs key on the VPS and set the four env vars. STATUS.md `bcrypto-server@3ff8e47` is "NOT pushed to origin" — verify it's deployed to `217.160.65.35`.
- **iOS smoke test on physical device** never executed (STATUS.md §"Still open" lists "iOS smoke tests on physical devices (NFC pairing, CallKit, APNs incoming-call)").
- **iOS lacks PKPushPayload→`opaque_msg_send` mapping** because the mailbox WS type isn't wired. Today the push-payload triggers CallKit reportNewIncomingCall and the call_offer arrives over the open WS — this works only if WS reconnects fast enough; if the device is fully suspended, the call_offer is enqueued server-side. Worth verifying server has a missed-call retry path.

---

## 5. Crypto wire alignment vs Android + Desktop

### 5.1 HKDF labels — iOS canonical helper

`QAudionEngine/Sources/QAudionEngine/Crypto/HkdfLabels.swift:20-43`:

| Label | iOS value | Android source of truth | Status |
|---|---|---|---|
| `messageKey` | `q-audion-msg-key` | `MessageCrypto.kt:54` `q-audion-msg-key` | MATCH |
| `hybridPqcSessionKey` | `q-audion-session-key` | per `docs/security/hkdf-label-audit.md` row #4 | MATCH (not re-grepped today) |
| `nfcCollaborativePsk` | `Q-Audion NFC Collaborative PSK v1` | KAT-vector pinned per F0.4 | MATCH |
| `deviceLinkPsk` | `qaudion-device-link-v1` | NOT YET IMPLEMENTED on iOS per `HkdfLabels.swift:29` comment | iOS missing call site |
| `frameChainAudio` | `q-audion-frame-key` | `cross_platform_vectors.json:29` | MATCH |
| `frameChainVideo` | `q-audion-video-frame-key` | — | n/a (Track B.5) |
| `fileKey` | `q-audion-file-key` | `hkdf-label-audit.md` row #14 | MATCH |
| `recoveryAuth` | `recovery-auth-v1` | Android uses `bcrypto-recov-v1` salt with `recovery-auth-v1` info per `HkdfLabels.swift:11-15` comment | **DISCREPANCY (iOS not yet calling — not active)** |

`CryptoConstants.swift:30-31` adds: `q-audion-root-ratchet`, `q-audion-psk-mix`, `q-audion-next-chain` — all match Android per `cross_platform_vectors.json`.

`CryptoConstants.swift:46-48` adds: `qaudion-envelope-salt`, `qaudion-envelope-key-v1` — match Android per `OpaqueMailbox.swift:18-20` "match Android" claim.

**Recently unified labels (Android + Desktop) — iOS check:** the user's request mentions Android + Desktop unifying canonical HKDF labels in commits `e901d36` + `ccf57ec`. The iOS `HkdfLabels.swift` file pre-dates those commits; `INVARIANTS_VERIFIED.md` Open Discrepancy §6 is the standing record that recovery-seed is still unreconciled. Other label families look congruent.

### 5.2 KAT regression vectors

- `QAudionEngine/Tests/Resources/cross_platform_vectors.json` (9.2 KB) covers padding + HKDF (root, frame, psk-mix, next-chain) — pinned against Android `kat-vectors-android.json`.
- **No iOS test references `kms-prebootstrap-kat.json`** — that file lives in `qaudion-engine/src/test/resources/` (Android) and the user noted it has uncommitted edits in `git status`. iOS does not consume it; cross-platform KMS handshake KAT is therefore untested on the iOS side.

### 5.3 X25519 vs P-256 — KMS path

`QAudionEngine/Sources/QAudionEngine/Integration/KmsKeyReceiver.swift:17-23` uses `P256.KeyAgreement` and HKDF info `q-audion-kms`.

| Aspect | Android (canonical) | iOS `KmsKeyReceiver.swift` |
|---|---|---|
| Curve | x25519 | P-256 (line 17) |
| HKDF info | `qaudion-kms-pkg-v1` (per Android `BCryptoKmsClient`) | `q-audion-kms` (line 23) |

**Liveness check:** `grep -rn "KmsKeyReceiver\|decryptPskPackage" --include="*.swift"` returns ONLY the file's own definition. **No call site exists.** F-6 audit's "DEAD code" verdict (`docs/security/f6-ios-orphan-trace.md`) is confirmed: `KmsKeyReceiver.swift` is a 32-line orphan never instantiated. The live KMS path is `BCryptoKmsClient.registerPublicKey` (sends `key_type="x25519"` per W12.A) — KMS pending packages are decoded but never decrypted in-app. **Suggested action:** delete the file or replace its body with X25519 + Android info string so a future caller doesn't accidentally re-introduce the P-256 path.

---

## 6. Calling-side wire — SDP, ICE, WebRTC

### 6.1 SDP / ICE / call-init

`BCryptoCallingApiImpl.swift:24-101` — sends camelCase-fixed snake_case envelopes:
- `call_offer` → `{recipient_id, call_id, sdp, call_type:"audio"}` — note `call_type` hard-coded to `"audio"` (line 34) — the SDP-less PQC path.
- `call_answer` → `{call_id, sdp}` — drops `recipient_id` (server has it from session).
- `call_ice` → `{call_id, candidate, sdp_mid:"", sdp_mline_index:0}` — empty mid + zero index because PQC path doesn't use SDP-bundled ICE.
- `call_hangup` → `{call_id, reason:"normal"}`.
- `call_processing` / `call_ready` → `{call_id, caller_id}` — pre-negotiation steps 1+2 (Android/Desktop interop).

**Drift vs Android:** none on the wire fields. The PQC SDP-less path matches. WebRTC video upgrade (`call_upgrade_request/response`, `call_video_state`) NOT wired on iOS (see §2.4) — Track B.5.

### 6.2 SAS + safety-number

- `SasVerificationViewModel.swift:11-15`: 4 PGP words derived from first 32 bits of the call-session PQC handshake transcript.
- `SasVerificationView.swift:5,108`: 4-word grid + §5.1 fingerprint toggle.
- `SasVerificationViewModelTests.swift:11`: explicit comment "4 PGP words = 32 bits of fingerprint entropy" — pins the cross-platform invariant.
- **`SasConstants` byte-for-byte lock (Android `SasConstants.SALT="qaudion-sas-v1"`, `DIGIT_COUNT=6`):** iOS does NOT have a `SasConstants.swift` — there is no equivalent constant pinned. Searching `--include=*.swift` for `SasConstants` returns zero hits. The 4-PGP-word path is implemented but the numeric-SAS branch (6 digits, salt `qaudion-sas-v1`) is missing on iOS. If the call-time SAS is supposed to fall back to digits when words are unavailable, that branch is silently broken. **Action:** port `SasConstants` and `SasComputation` from Android `app/src/main/java/com/bcrypto/qaudion/nfc/SasComputation.kt` to iOS; add a KAT vector to `cross_platform_vectors.json`.

### 6.3 WebRTC codec negotiation (H.264 baseline)

Plan §2.4 says H.264 baseline default. iOS `BCryptoCallingApiImpl` does not negotiate codecs — call_type is hard-coded `"audio"`, no SDP munging. Video uplift (Track B.5) is not in scope for 1.0.

---

## 7. Plan §2 P0 items — iOS as long-pole status

| Plan item | Spec § | iOS state | Evidence |
|---|---|---|---|
| Voice notes E2EE (§2.5) | crypto = AEAD per attachment | **PARTIAL** — iPhone↔iPhone only | `ChatVoiceNoteSender.swift` header: "iPhone↔iPhone today. Cross-platform deferred until engine ships Double Ratchet chain-key snapshot the `attach_announce` envelope requires (XChaCha20-Poly1305 + canonical CBOR AAD)". 5-min cap (W107), pulse anim (W126/W132/W133), playback-rate persistence (W144), `.txt` export (W139) — UX is rich, **wire/crypto for cross-platform is the long pole.** |
| File attachments E2EE 5GB (§2.6) | tus.io + XChaCha20-Poly1305 | **NOT IMPLEMENTED** | No `tus`/`tus.io`/`resumable` Swift hits; iOS still goes through `/api/v1/files/upload` (`BCryptoStorageApiImpl.swift:41`). XChaCha20-Poly1305 not present in iOS Crypto/. The `qfile` v3 path uses AES-256-GCM (`ChatVoiceNoteSender.swift` header: "HKDF-SHA256 + AES-256-GCM, AAD `file:v2:{sender}:{recipient}:{ts}`"). Plan target unmet. |
| Trust UI SAS + safety-number (§2.7) | SAS digits + 4 PGP words | **PARTIAL** | 4 PGP words ✓ via `SasVerificationViewModel`. Numeric SAS / `SasConstants` port missing — see §6.2. |
| GDPR data-export + delete-account (§2.12) | REST endpoints + UI | **DONE on iOS** | `b2adbc5` "feat(settings): GDPR Export + Delete account (audit P0 #2.12)" + `1c55b6b` "iOS AccountApi gains accountExport/deleteAccount/revokeDevice"; verified at `BCryptoAccountApiImpl.swift:42-48` + `AccountSettingsScreen.swift:105-156`. |
| Hardware keystore / SEP / biometric app-lock (§2.13) | SEP-backed identity, FaceID/TouchID gate | **PARTIAL** | `SecureEnclaveManager.swift` exists + comment `:67` "Store a master identity key in the Secure Enclave, optionally protected by biometric". `LAContext`/`evaluatePolicy` grep returns zero hits — the biometric prompt is NOT yet wired into the foreground re-lock flow. Android landed user-configurable foreground re-lock timeout in `d0f97f56` (audit P0 #2.13); iOS has no equivalent. |
| OTA Sigstore verification (§2.14b) | cosign signature + cert validation | **NOT IMPLEMENTED on iOS** | Android landed `a659c78d` "feat(ota): wire OtaSigstoreVerifier into install path"; iOS `grep -rn "OtaSigstoreVerifier\|sigstore" --include="*.swift"` returns zero hits. iOS update channel is TestFlight, so this gap is by design — but worth pinning that decision in `ANDROID_REFERENCE.md`. |
| i18n EN/FR/DE/ES (§3.8) | string resources | **iOS-side state unverified** | Android `e6d0925c` + `303b8223` landed translation footholds; no equivalent recent commit on iOS surfaced in W*-ranges sampled. |
| App-lock disable-by-default (Android `feedback_phase24_disabled`) | AppLockMode default Real | n/a iOS | This is an Android feedback memo; iOS uses LAContext gate (above) once wired |

---

## 8. Cross-cutting findings

1. **Branch hygiene:** `feature/ios-android-parity` has accumulated ~250 unrelated `W***` commits (voice notes, App-Store polish). This makes parity-status grep noisy and is why STATUS.md feels stale. Recommend rebasing parity changes onto `main` and retiring the branch — or, more pragmatic, fast-forwarding `main` to include the parity work since `70be347`.
2. **Stale `KmsKeyReceiver.swift`:** P-256 + wrong HKDF label, never called. Delete or rewrite.
3. **`SasConstants` port missing** — see §6.2.
4. **No iOS opaque mailbox client** — cannot benefit from server's anti-amplification + split-view detection.
5. **Sigsum gossip headers entirely absent on iOS REST stack** — `BCryptoRestClient.swift` does not read or set `X-Sigsum-*`.
6. **Backup endpoint trio (upload/download/list)** still drifts since 2026-04-20; flagged in §1.2 D-1..D-3.
7. **`msg_typing` inbound** has no handler → typing indicators silently drop.

---

## 9. Prioritized next 10 actions

> P0 = cross-platform interop blocker for 1.0; P1 = closes a security-promised feature; P2 = hygiene/follow-up.
> Effort: S = ≤ 0.5 day, M = 1-2 days, L = 3-5 days.

| # | Pri | Effort | Action |
|---|---|---|---|
| 1 | P0 | M | **Wire iOS opaque mailbox client** (`opaque_msg_send`/`opaque_msg_ack` WS types + `POST /api/v1/opaque/send` REST). Reuse `OpaqueMailbox.swift` for envelope; add a new `BCryptoOpaqueMailboxClient.swift` paralleling `BCryptoMessageApiImpl`. Unblocks the server's new mailbox path for both fan-out paths. |
| 2 | P0 | L | **Fix backup transport trio** (`backup/upload` multipart + streaming `backup/download` + `BackupEntryDto` decode for `backup/list`). All three live in `BCryptoStorageApiImpl.swift` — single-file change. Closes audit §3.6–§3.8 (open since 2026-04-20). |
| 3 | P0 | L | **Implement tus.io resumable upload + XChaCha20-Poly1305 attachment encryption** to satisfy plan §2.6 (5 GB attachments). New `BCryptoTusClient.swift` + new `AttachmentCipher.swift` (CryptoKit has no XChaCha20 — pull `swift-sodium` or hand-roll via Apple's `cc_chacha20*` SPI). Without this, voice notes + image attachments stay iPhone↔iPhone-only. |
| 4 | P0 | M | **Port `SasConstants` + numeric-SAS branch** from Android `app/.../nfc/SasComputation.kt`. Add KAT vector to `cross_platform_vectors.json`. Required to keep iOS↔Android trust-verify byte-equivalent post-2026-04-28 SAS lock. |
| 5 | P0 | S | **Delete `KmsKeyReceiver.swift`** (or rewrite to X25519 + canonical HKDF info to match Android). Currently dead, but a future agent could mistakenly wire it. |
| 6 | P1 | M | **Sigsum gossip headers** in `BCryptoRestClient`: emit `X-Sigsum-Witness-TreeHead` from a stored last-observed tree-head, parse `X-Sigsum-Gossip-TreeHead` from inbound responses. Persist via `SettingsStore` for split-view detection. Mirrors server `internal/sigsum/gossip_http.go`. |
| 7 | P1 | M | **Sealed-sender v2 cert encoder** + opt-in plumbing through `OpaqueMailboxClient` (action #1). Without this, iOS-originated opaque sends get the lower anti-amplification trust tier from `internal/sealed_sender.Guard`. |
| 8 | P1 | M | **Biometric app-lock wire** — port Android's foreground re-lock timeout (`d0f97f56`). Add `LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)` gate in `AppState.scenePhaseDidChange` triggered after configurable idle; UserDefault stores the timeout. Unblocks plan §2.13 P0 on iOS. |
| 9 | P2 | S | **Inbound `msg_typing` handler** — register in `AppState.swift` near lines 712/718. Bind to `ChatViewModel` typing state. Restores typing indicator visibility. |
| 10 | P2 | S | **Add `call_upgrade_request/response` + `call_video_state` WS senders** to `BCryptoCallingApiImpl` even as no-ops, so audio-call-only clients politely refuse the upgrade rather than ignoring it. Matches Android `WsCommand.kt:263-265`. |

**Branch rebase / merge** (separately): bring `feature/ios-android-parity` parity work onto `main` (or vice versa) so the source files I audited match what TestFlight ships. STATUS.md should be regenerated post-merge. Effort S, no priority — but it's a precondition for the next parity audit being trustworthy.

---

## 10. Source provenance

All file:line citations were verified by `Read`/`Grep` against the working tree at audit time. The most load-bearing files for any follow-up reader:

- `D:\users\f10379a\DEV APP\BCRYPTO\apps\qaudion-ios\QAudionEngine\Sources\QAudionEngine\Backend\BCrypto\BCryptoCallingApiImpl.swift`
- `D:\users\f10379a\DEV APP\BCRYPTO\apps\qaudion-ios\QAudionEngine\Sources\QAudionEngine\Backend\BCrypto\BCryptoMessageApiImpl.swift`
- `D:\users\f10379a\DEV APP\BCRYPTO\apps\qaudion-ios\QAudionEngine\Sources\QAudionEngine\Backend\BCrypto\BCryptoStorageApiImpl.swift`
- `D:\users\f10379a\DEV APP\BCRYPTO\apps\qaudion-ios\QAudionEngine\Sources\QAudionEngine\Backend\BCrypto\BCryptoSecurityApiImpl.swift`
- `D:\users\f10379a\DEV APP\BCRYPTO\apps\qaudion-ios\QAudionEngine\Sources\QAudionEngine\Backend\BCrypto\BCryptoWebSocketClient.swift`
- `D:\users\f10379a\DEV APP\BCRYPTO\apps\qaudion-ios\QAudionEngine\Sources\QAudionEngine\Crypto\HkdfLabels.swift`
- `D:\users\f10379a\DEV APP\BCRYPTO\apps\qaudion-ios\QAudionEngine\Sources\QAudionEngine\Crypto\CryptoConstants.swift`
- `D:\users\f10379a\DEV APP\BCRYPTO\apps\qaudion-ios\QAudionEngine\Sources\QAudionEngine\Crypto\OpaqueMailbox.swift`
- `D:\users\f10379a\DEV APP\BCRYPTO\apps\qaudion-ios\QAudionEngine\Sources\QAudionEngine\Integration\KmsKeyReceiver.swift`
- `D:\users\f10379a\DEV APP\BCRYPTO\apps\qaudion-ios\QAudionApp\AppState.swift`
- `D:\users\f10379a\DEV APP\BCRYPTO\apps\qaudion-android-new\core\core-data\src\main\java\com\bcrypto\qaudion\data\ws\WsCommand.kt`
- `D:\users\f10379a\DEV APP\BCRYPTO\apps\bcrypto-server\cmd\bcrypto-lite\main.go`
- `D:\users\f10379a\DEV APP\BCRYPTO\apps\bcrypto-server\internal\sigsum\gossip_http.go`
- `D:\users\f10379a\DEV APP\BCRYPTO\apps\bcrypto-server\internal\sealed_sender\middleware.go`
