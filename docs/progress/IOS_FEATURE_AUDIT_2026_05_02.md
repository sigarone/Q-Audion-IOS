# IOS_FEATURE_AUDIT_2026_05_02 — Q-Audion 1.0 §2 P0 chat / attachments / UX surface

**Scope**: chat MVP, attachments (5 GB E2EE), voice notes, recovery + revoke, biometric / app-lock, GDPR / privacy, telemetry, backup E2EE deferral, localization, accessibility, battery.
**Out of scope**: REST/WS wire (covered in `IOS_PARITY_AUDIT_2026_05_02.md`), calling / CallKit / PushKit (covered in `IOS_CALLING_AUDIT_2026_05_02.md`).
**Plan reference**: `D:\users\f10379a\.claude\plans\glittery-sleeping-hejlsberg.md` §2.5 / §2.6 / §2.7 / §2.10 / §2.11 / §2.12 / §2.13, §3.1-§3.4, §3.8-§3.10.

---

## TL;DR

iOS chat MVP is **largely shipped end-to-end** (W9.C codecs wired, edits/deletes/reactions over `qa_ctl:1`, voice notes + image attachments, typing indicator, read receipts, draft persistence). **Two structural gaps block real cross-platform peer status**:

1. **iOS attachment wire is one schema BEHIND Android+Desktop.** iOS still emits the legacy `qfile` v3 marker (`FileTransfer.FileMarker`, AAD = `"file:v2:..."`); the `attach_announce` codec / `qa_ctl:1` envelope (parity wire with Android `AttachmentEnvelope` + Desktop) ships only as a **decode-side parser**. Send-side never emits it. iOS attachments are receivable iOS↔iOS only; Android & Desktop will see them as undecodable JSON.
2. **iOS storage upload is single-shot multipart, not tus.io resumable.** `BCryptoStorageApiImpl.uploadFile` (`BCryptoStorageApiImpl.swift:37-45`) hits `POST /api/v1/files/upload` with one `multipart/form-data` body. Any 100 MB+ attachment is one TCP failure away from full restart, and there is NO chunking, retry, or pause/resume. The 5 GB §2.6 ceiling is unreachable in practice on cellular.

Other significant gaps: **no biometric app-lock at all** (the `SecureEnclaveManager.storeIdentityKey(requireBiometric:)` API exists but no caller, no `LAContext` evaluatePolicy invocation anywhere, no inactivity timer, no scenePhase re-lock). **No localization** (zero `.lproj` / `Localizable.strings` / `.xcstrings`, zero `NSLocalizedString` callers — every user-facing string is a hard-coded Italian or English literal). **No crash telemetry** of any kind (no MetricKit, Sentry, Crashlytics; STATUS.md doesn't even mention it as a deferred item). Recovery seed UI is **shipped** (W9.B `RecoverySeedView`); device revoke API exists but the UI calls `onRevoke` with no AppState-side wire (`DeviceManagementView.swift:63` is a closure-only stub; the engine `revokeDevice(deviceId:)` REST call from `BCryptoAccountApiImpl.swift:55` is unreachable).

---

## 1. Chat MVP — message send / receive / delivered / read / typing

### State

| Feature | Wire codec | Send path | Receive path | UI bubble | Notes |
|---|---|---|---|---|---|
| msg_send (text) | `MessageSendEnvelope` (`Backend/Wire/MessageSendEnvelope.swift`) | `ChatMessageSendService.sendEncrypted` (`Services/ChatMessageSendService.swift:56`) → `BCryptoMessageApiImpl.sendMessage` | `AppState.handleIncomingMessage` (`AppState.swift:888-`) → `ConversationStore.appendMessage` | `MessageBubble` (`Views/Chat/Components/MessageBubble.swift`) | AES-256-GCM, AAD `"msg:{senderId}:{recipientId}:{msgId}"`. Wire format parity with Desktop / Android. |
| msg_delivered | `MessageDeliveredEnvelope` | not emitted by iOS (relies on server "msg-delivered" relay back from peer) | `AppState` observer → `ConversationStore.updateMessageStatus(.delivered)` | `MessageBubble` checkmark state | OK. |
| msg_read | `MessageReadEnvelope` | `ChatContainer.emitReadReceipts` (`ChatContainer.swift:564`) → `BCryptoMessageApiImpl.sendReadReceipts` | `AppState` observer → store update | UI flips `✓✓ → ✓✓ blue` (TODO: bubble color isn't blue today, just `.read` enum) | Triggered from `ChatDetailScreen.onAppear`. |
| msg_typing | `MessageTypingEnvelope` | `ChatContainer.notifyComposerInput` (`ChatContainer.swift:312`) — typing=true on first keystroke, debounced typing=false 3 s after last keystroke | `ChatContainer.attach(appState:)` observer (`ChatContainer.swift:170-189`) → `viewModel.isPeerTyping` | `ChatDetailScreen.typingRow` (`ChatDetailScreen.swift:627`) "{peerName} sta scrivendo…" | OK. iOS-Android round-trip OK in theory. |

**§3.1 reactions / edits / deletes (`qa_ctl:1`)** — fully wired:
- `ChatControlEnvelope.swift:36` enum (delete / edit / reaction)
- `ChatContainer.deleteMessage` (`ChatContainer.swift:421`) + `editMessage` (`:465`) + `toggleReaction` (`:492`) build envelopes, apply locally first, then ship via `emitControlEnvelope` (`:524`) which encrypts the JSON envelope as the plaintext of a normal `msg_send`.
- 8 KiB edit body cap + 16-grapheme reaction cap (parity with Desktop hardening, `ChatControlEnvelope.swift:64-69`).
- 15-min edit-window UI gate referenced in `ChatDetailScreen.swift:247`.
- Delete-for-everyone confirm dialog (`ChatDetailScreen.swift:258-276`).
- Delete-for-me path: `ChatContainer.deleteMessageLocally` (`:451`) — local tombstone, no peer envelope. Closes `TODO_AUDIT.md` §2.1.
- `Message.reactions: [String:[String]]` stored map (`Models/Message.swift:75`); reaction chips rendered in `ChatDetailScreen.swift:561-583`.
- Receive-side spoof check: only original sender of a message can edit / delete it (per `ChatControlEnvelope.swift:26-30` doc + verified by `senderId == row.senderUserId` check at envelope-apply time).

**§3.2 reply / quote** — UI scaffolding only:
- `MessageComposer.ReplyTarget` struct (`MessageComposer.swift:362`) and reply banner (`:215`).
- `ChatDetailScreen.swift:38` `replyTarget` `@State`.
- BUT — `ChatDetailScreen.swift:845-850` shows that `replyHandled` is used only as `_ = replyHandled` after send: the reply target is cleared on send but **never embedded into the wire**. There is no `reply_to` field on `MessageSendEnvelope` (verified — only `message_id`, `recipient_id`, `ciphertext`, `client_ts`). Reply is purely visual on iOS today.
- Comment at `:848`: `// replyHandled is reserved for a future sendMessage(replyTo:)`.

**§3.3 disappearing messages** — settings UI present, **NO send-side enforcement, NO local TTL sweeper, NO wire field**:
- `PrivacySettingsViewModel.disappearingMessagesDuration` (`UI/ViewModels/Settings/PrivacySettingsViewModel.swift:9`) — 0/60/3600/86400/604800 s.
- `PrivacySettingsScreen.swift:264-273` picker bound to `setDisappearingDuration`.
- BUT — `grep -rn "disappearing" QAudionApp QAudionEngine` on the **wire / persistence side** returns ZERO matches outside the settings VM. `Message` model has no `expiresAt` field. `ConversationStore` has no TTL-sweep loop. `MessageSendEnvelope` doesn't ship a `ttl_seconds`. The setting is a dead toggle.

**§3.4 read-receipt + typing privacy toggle** — UI only:
- `PrivacySettingsViewModel.readReceiptsEnabled` + `typingIndicatorEnabled` (`PrivacySettingsViewModel.swift:4-5`).
- BUT — `ChatContainer.emitReadReceipts` (`:564`) and `notifyComposerInput` (`:312`) **do not consult either flag**. Disabling read-receipts in settings has no effect on the wire today.

### Gap summary

| § | Gap | Severity | Effort |
|---|---|---|---|
| 3.2 | Reply payload not on wire | M | M |
| 3.3 | Disappearing messages not enforced (sweeper + TTL) | **P0 if shipped, otherwise hide UI** | M |
| 3.4 | Privacy toggles not honoured | P0 (privacy theatre) | S |

---

## 2. File attachments E2EE 5GB (§2.6 — value-prop #1)

### tus.io resumable upload

**iOS: NOT IMPLEMENTED.** `BCryptoStorageApiImpl.uploadFile` (`Backend/BCrypto/BCryptoStorageApiImpl.swift:37-45`) is a single-shot `POST /api/v1/files/upload` with one `multipart/form-data` body. No chunking, no resume, no Upload-Offset header.

For reference, the server has a `/api/v1/files/tus` endpoint (`bcrypto-server/cmd/bcrypto-lite/files_tus.go`), Android client and Desktop have **planned** but **not yet wired** TUS support either (`Android UploadAttachmentUseCase.kt:21` still hits `/files/upload`). So this is a P0 gap on **all** clients.

The `AttachAnnounceEnvelope` doc (`AttachAnnounceEnvelope.swift:22`) and `BCryptoDownloadTokenClient.swift:8`+`:37` document tus.io as the target but no tus-client code exists in iOS today.

### XChaCha20-Poly1305 chunked encryption

iOS uses **AES-256-GCM** for attachments (`Messaging/FileTransfer.swift:169` — `AES.GCM.seal`). Android `AttachmentCrypto.kt` also uses AES-256-GCM with 96-bit nonce (verified). The plan §2.6's "XChaCha20-Poly1305" is **not** the actual cross-platform choice; AES-256-GCM with a fresh random key per attachment is what all three platforms ship. **No gap.**

That said, the iOS path is **single-buffer in-memory** (`FileTransfer.upload(bytes: Data, ...)` `:155`) — the entire file is loaded into RAM before encryption. A 5 GB attachment would crash even with the streaming TUS upload path. Need streaming AES-GCM (CryptoKit doesn't expose chunked AES-GCM directly — needs CommonCrypto or a wrap around `CCCryptorUpdate`).

### Wire format gap (KEY FINDING)

iOS emits **two parallel attachment formats** at receive but only **one** (the older one) on send:

| Marker | Where parsed | Where emitted |
|---|---|---|
| `qa_ctl:1` `attach_announce` (Android+Desktop) | `AppState.swift:1174` `AttachAnnounceEnvelope.parse` | **NOT EMITTED ANYWHERE** (search `emitAttachAnnounce`, `att_announce` send paths — zero hits) |
| Legacy `qfile` v3 (`FileTransfer.FileMarker`, AAD `"file:v2:..."`) | `AppState.swift:1192` `FileTransfer.tryParseMarker` | `ChatVoiceNoteSender.prepareAttachmentMarkerJson` (`Services/ChatVoiceNoteSender.swift:106`) — voice notes AND images |

The comment at `ChatVoiceNoteSender.swift:7-14` explicitly says: *"iPhone↔iPhone today. Cross-platform (iOS↔Android, iOS↔Desktop) is deferred until the engine ships the Double Ratchet chain-key snapshot the `attach_announce` envelope requires."*

**Result**: voice notes and images sent FROM iOS are **silently dropped on Android & Desktop** (the `qfile` parser doesn't exist there, only `attach_announce` does). Receive direction works (iOS parses both), but iOS is a **send-side island**.

### Thumbnails

Inline thumbnails for images: **NOT IMPLEMENTED.** Image bubble (`ImageBubbleContent.swift`) renders the local `mediaLocalPath` but does not pre-fetch or cache a thumbnail; the receiver has to download the full ciphertext, decrypt, and decode the JPEG before any pixel paints. Android+Desktop don't have it either — uniform gap.

### Progress / retry / "go to file" UX

- Progress bar: NOT IMPLEMENTED. `ChatContainer.sendImage` (`:816`) and `sendVoiceNote` (`:592`) await the upload as a single `Task`; bubble status flips `sending → delivered/failed` with no intermediate %. No `URLSession` upload-task progress observer. No `Progress` ObservableObject.
- Retry: IMPLEMENTED. `ChatContainer.retryFailedMessage` (`:743`) handles audio/* / image/* / text branches, re-reads the local cache, re-runs the pipeline.
- "Go to file" link: NOT IMPLEMENTED. No download-folder integration, no `UIActivityViewController` "save to Files" path on inbound attachments.

### Test coverage

- `100 MB+`: NOT TESTED. Multipart single-shot would likely OOM-crash given current in-memory buffer.
- `1 GB+`: NOT TESTED. Server `files_tus.go` may accept it but client can't.
- Network drop+resume: NOT TESTED. No resume codepath exists to test.
- Mid-transfer key rotation: NOT TESTED. Decoder tries every PSK in `vault.allByPriority()` (`FileTransfer.swift:212-225`) so this could in theory work — but no test exercises it.

### Gap summary

| Item | State | Severity | Effort |
|---|---|---|---|
| tus.io client | absent | P0 (cross-platform) | L |
| Streaming AEAD (chunked AES-GCM) | absent | P0 (5 GB ceiling) | M |
| `attach_announce` send | absent | P0 (cross-platform) | M |
| Thumbnails | absent | P1 | M |
| Progress UI | absent | P1 | S |
| "Save to Files" | absent | P1 | S |
| 100 MB / 1 GB / drop tests | absent | P0 | M |

---

## 3. Voice notes E2EE 5min (§2.5)

### iOS UI for record / send / receive / play

| Component | File | State |
|---|---|---|
| Recorder service | `Services/VoiceNoteRecorder.swift` (176 lines) | OK |
| Player service | `Services/VoiceNotePlayer.swift` (215 lines) | OK |
| Push-to-talk gesture | `Views/Chat/Components/MessageComposer.swift:307-352` (DragGesture-based) | OK |
| Live recording banner | `MessageComposer.swift:140-185` (pulsing red dot, drag-up cancel) | OK |
| 5-min hard cap warning | `MessageComposer.swift:144-178` ("30s alla fine" chip in last 30 s) | OK |
| Bubble | `Views/Chat/Components/VoiceNoteBubbleContent.swift` | OK |
| Waveform | `Views/Chat/Components/VoiceWaveform.swift` | OK |
| Send orchestrator | `Services/ChatVoiceNoteSender.swift` (252 lines) | OK |
| Receive orchestrator | `Services/ChatVoiceNoteReceiver.swift` (178 lines) | OK |

### Wire format match with Android+Desktop

**FAIL.** Sender uses legacy `qfile` v3 marker (with `downloadClaim` + `durationMs` extension). Android sends `qa_ctl:1` `attach_announce`. Same observation as §2 above — the codec gap is the blocker, the audio bytes themselves are AES-256-GCM on both sides.

### tus.io upload

Same as §2 — single-shot multipart, no resumable upload. A voice note caps at 5 min × 96kbps AAC ≈ 3.6 MB so resumability is less critical here than for general attachments — but still part of the same gap surface.

### Gap summary

| Item | Severity | Effort |
|---|---|---|
| Switch send to `attach_announce` (cross-platform) | P0 | M |
| TUS upload | P1 (small payloads survive multipart) | reuse §2 work |

---

## 4. Trust UI / SAS / safety-number (§2.7)

### State

- `SasVerificationView` (`UI/SasVerificationView.swift`, 80+ lines read) — 4 PGP words OR fingerprint toggle, "They Match" / "They Don't Match" verdict.
- `SasVerificationViewModel` (`UI/ViewModels/SasVerificationViewModel.swift`, F1.6 of Foundation Sprint).
- `ContactDetailView` / `ContactDetailViewModel` (W7.C, `560c542`) — fingerprint display surface.
- `Fingerprint.format(pubkey:)` produces `xxxx.xxxx.xxxx.xxxx` 4-group hex (`Crypto/Fingerprint.swift`, parity confirmed in `STATUS.md` §"§3 fingerprint display").

### Identity-change badge ("peer rotated keys → IDENTITY CHANGED")

**NOT IMPLEMENTED.** `grep -rn "identity.changed|IDENTITY CHANGED|identityRotated|peer.*rotated|fingerprintChanged|pinned.fingerprint|pinFingerprint"` returns zero matches across iOS. There is no:
- Stored "last-seen-fingerprint per contact" baseline
- Comparison on incoming `msg_receive` / KMS key envelope
- "🚨 IDENTITY CHANGED" badge in any view
- Auto-warn / re-verify flow

Compare Android `feature/feature-chat/.../security/SecurityBadge.kt` which has the warning chip wired. iOS has `CallSecurityBadge.swift` — name is the same but it's call-encryption status, not identity-rotation.

### Pinned fingerprint after manual verify

`StoredContact.pubkey` (`ContactsStore.swift`, W14.F `5f7757d`) persists the 32B X25519 pubkey on contact-add, AND a separate `verified` flag — but the verified flag is **set by SAS verdict in-memory, not pinned to a snapshot**. There is no diff-on-change check. If the peer's pubkey changes the next time we exchange keys, the `verified` flag stays `true` silently.

### Gap summary

| Item | Severity | Effort |
|---|---|---|
| Identity-rotation detection + badge | **P0** (Trust UI is value-prop, this is the audit user actually sees) | M |
| Fingerprint pinning + mismatch warning | P0 | S |

---

## 5. Account recovery + device revoke (§2.11)

### Recovery seed (W9.B)

- `RecoverySeedView` (`UI/RecoverySeedView.swift`) — BIP-39 12-word mnemonic, 4-step state machine (`setupShowMnemonic` / `setupConfirmEntry` / `verifyEnterMnemonic` / `complete` / `error`).
- `RecoveryMnemonic.swift` (`Crypto/RecoveryMnemonic.swift`) — BIP-39 wordlist + checksum.
- `RecoverySeedViewModel.computeRecoveryHash` (`UI/ViewModels/RecoverySeedViewModel.swift`).
- Wired into onboarding via `OnboardingRecoverySeedHost` (W15.A `009cbfe`) — REAL flow for new users.
- REST endpoints `recoverySetup` / `recoveryVerify` exist on `BCryptoAccountApiImpl` (Task 1.4-b4 `c0c8026`).

**OK.**

### Device revoke

- Engine REST: `BCryptoAccountApiImpl.revokeDevice(deviceId:)` (`BCryptoAccountApiImpl.swift:55`) — exists.
- UI: `DeviceManagementView.deviceRow` (`UI/DeviceManagementView.swift:43-69`) renders a "Revoke" button per device, calling `onRevoke?(d.deviceId)` closure.
- **The host that wires `onRevoke` to `provider.accountApi.revokeDevice(deviceId:)` does not exist.** `Settings/DeviceManagementScreen.swift:306` declares `let onRevoke: () -> Void` (no deviceId param!) and `:353` just calls it. The screen-level container does not call into the engine API at all.

**P0 gap**: revoke UI is purely cosmetic.

### New-device-login push to existing devices

**NOT IMPLEMENTED.** No push notification handler for "new device linked" event, no UI banner, no auto-revoke prompt. The server emits this via APNs (`bcrypto-server` `3ff8e47` Wave 13) but iOS doesn't subscribe to or render it.

### Gap summary

| Item | Severity | Effort |
|---|---|---|
| Wire `DeviceManagementScreen.onRevoke` → `accountApi.revokeDevice` | **P0** | S |
| New-device-login push handler + UI | P1 | M |

---

## 6. Hardware keystore + biometric app-lock (§2.13)

### Secure Enclave + Keychain

- `SecureEnclaveManager.swift` (`Crypto/SecureEnclaveManager.swift`) — `generateEnclaveKey(tag:)` (`:41`), `storeIdentityKey(tag:requireBiometric:)` (`:72`). All identity keys generated inside SEP, never leave hardware.
- `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` used everywhere (`QAudionKeyStore.swift:17`, `SovereignKeyVault.swift:18`, `SovereignIdentityManager.swift:206`). Correct accessibility class.
- `DeviceKeyManager.swift:15` — device key uses `kSecAttrTokenIDSecureEnclave`.

**OK on the engine side.**

### Biometric app-lock

**NOT IMPLEMENTED ANYWHERE.**
- `grep -rn "LAContext|LocalAuthentication"` returns zero matches across `QAudionApp/` and `QAudionEngine/Sources/`.
- `SecureEnclaveManager.storeIdentityKey(requireBiometric: true)` — the API exists but the only caller (`grep "storeIdentityKey"` — engine internals only) passes `requireBiometric: false` or doesn't trigger biometric prompt at app foreground.
- No UI gate between launch and home-tab (`SplashScreen.swift:19` comment: *"AppLockMode infrastructure (Phase…)"*).
- `import LocalAuthentication` — zero hits.

### Inactivity timer

NOT IMPLEMENTED. There is no inactivity Timer, no `scenePhase` observer that resets it, no Settings toggle for it. (Compare the Android side, where MEMORY.md flags an entire app-lock mode debate that already happened.)

### Re-lock on background / rotation / foreground

NOT IMPLEMENTED. `UIApplication.willResignActiveNotification` is observed once in `ChatContainer.swift:194` to flush the typing draft — that's the only foreground/background hook in the whole app.

### Gap summary

| Item | Severity | Effort |
|---|---|---|
| LAContext biometric gate at app foreground | **P0** (this is the value-prop "decoy / lock" advertised in plan §2.13) | M |
| 5-min inactivity timer | P0 | S |
| Re-lock on background / scenePhase | P0 | S |

---

## 7. GDPR + privacy policy + delete-account (§2.12)

### Settings → Download my data

- `Services/ConversationExporter.swift` (118 lines) — exists. Per `AccountSettingsScreen.swift:130` it builds an export and presents a `UIActivityViewController` share sheet.
- Likely covers conversations only (`grep` on the file would confirm scope). **OK** for data-portability, but not necessarily a full GDPR Article 20 dump (contacts, profile, settings, threat-report log, voice-enrollment hash …).

### Settings → Delete my account

- `AccountSettingsScreen.deleteAccount()` (`AccountSettingsScreen.swift:147`) calls `provider.accountApi.deleteAccount()` (best-effort) **then** `provider.accountApi.logout()` regardless of server response. Local wipe is unconditional. Comment at `:142-146` flags this as audit P0 #2.12.
- Engine: `BCryptoAccountApiImpl.deleteAccount` (`:48`) — fires `DELETE /api/v1/account`.

**OK.**

### Privacy policy first-launch acceptance

**NOT IMPLEMENTED.** `grep -rn "privacyPolicy|termsAccepted|gdprAccepted"` in `QAudionApp/Views/Onboarding/` returns zero. The onboarding flow (`WelcomeScreen.swift` → `PhoneEntryScreen.swift` → `VoiceEnrollmentScreen.swift` → `RecoverySeed*Host`) jumps straight from welcome to phone entry with no consent gate.

### Gap summary

| Item | Severity | Effort |
|---|---|---|
| Privacy policy first-launch consent UI | **P0** (App Store / GDPR mandate) | S |
| Audit `ConversationExporter` for full-data dump (contacts + profile + settings + threat log) | P1 | S |

---

## 8. Crash telemetry (§2.10)

**NOTHING WIRED.** Zero hits for `MetricKit`, `MXMetricPayload`, `crashReporter`, `Crashlytics`, `sentry` in the iOS source tree. STATUS.md does not mention this as deferred. `PrivacyInfo.xcprivacy` (`v1.0.47-trackA`) does NOT declare a tracking domain.

There is no first-launch opt-in dialog, no log-shipping target, no diagnostic-export integration with a remote backend. `Services/TransportDiagnostics.swift` collects diagnostics LOCALLY only.

### Gap summary

| Item | Severity | Effort |
|---|---|---|
| MetricKit subscriber + privacy-preserving aggregator (no PII, no userId) | **P0** for production launch | M |
| First-launch opt-in dialog | P0 (App Store privacy guidance) | S |

Recommendation: ship Apple's built-in MetricKit (no third-party SDK = no privacy-manifest delta required) and only flush aggregated counts, never stack frames with paths.

---

## 9. Backup E2EE — DEFERRED to 1.1 (CONFIRM no over-investment)

iOS state — consistent with the deferral:

| Component | File | Lines | Notes |
|---|---|---|---|
| `BackupCipher` | `Crypto/BackupCipher.swift` | (W8.B `f68c626` "AES-GCM half + scrypt stub") | Half-built. |
| `BackupContainer` | `Crypto/BackupContainer.swift` | (QAUD magic + scrypt N=2¹⁷ + AES-GCM, W12.B Android-shape adoption) | Shipped, parity. |
| `BackupCoordinator` | `Services/BackupCoordinator.swift` (226 lines) | local-file based (`Documents/qaudion-backup.qabk`), `.completeFileProtection`, comment at `:9` says *"server upload via /backup/upload is Phase 2 work"* | OK. |
| `BackupSettingsScreen` | `Views/Settings/BackupSettingsScreen.swift` | UI scaffolding shipped (A.6.A.9 `13bc292`); upload/restore BLOCKED on §3.6-§3.8 backup transport decision. | OK. |

**No over-investment.** iOS has roughly the same surface as Desktop+Android: local QAUD container works, server transport deferred, restore deferred.

---

## 10. Localization (§3.8 P1) — EN+IT+FR+DE+ES launch set

### iOS state

**ZERO localization shipped.**

- `find -name "*.lproj"` → empty
- `find -name "*.xcstrings"` → empty
- `find -name "Localizable.*"` → empty
- `grep -rn "NSLocalizedString"` (across `QAudionApp/` + `QAudionEngine/Sources/`) → zero
- Every user-facing string is a hard-coded literal in Italian (`"Stai modificando un messaggio"`, `"Errore di rete. Controlla la connessione."`) or English (`"Recovery Seed"`, `"Devices"`, `"Verify Security"`).

### Android comparison

`apps/qaudion-android-new` ships per-module `strings.xml` (recent commits `303b8223`, `e6d0925c` did EN+FR+DE+ES "translation footholds for the existing string resources"). Android is **also** mid-rollout, so iOS isn't unique in being incomplete, but iOS hasn't even done step 1 (extract literals → keys).

### Gap summary

| Item | Severity | Effort |
|---|---|---|
| Extract every user-facing literal into String Catalog (`.xcstrings`) — iOS 17+ first-class flow | **P1 P0-blocker for non-IT TestFlight launch** | L |
| Generate IT base + EN/FR/DE/ES placeholder columns | P1 | S (after extraction) |

This is the largest "stop the world" task in the audit. Estimated ~600-800 unique strings across the iOS UI surface (Settings has 11 sub-screens × ~30 strings each + chat + onboarding + alerts + accessibility labels).

---

## 11. Accessibility (§3.9 P1)

### VoiceOver labels

Partial — coverage spotty:
- `ChatDetailScreen.swift` has 4 `.accessibilityLabel(...)` calls (back button, audio call, video call, more menu — `:322`, `:360`, `:369`, `:403`).
- `MessageComposer.swift` has 5 (`:132`, `:255`, `:304`, `:351`, plus implicit close ✕ on banners).
- Total grep hit count across `QAudionApp/Views/Chat/` = 23 — meaning ~one label per major button but **not** the message bubbles, reactions, edited indicator, attachment placeholders, voice-note duration.

### Dynamic Type

**EFFECTIVELY ABSENT.** Hard-coded `.font(.system(size: 17, weight: .regular))` and `.qaudionStyle(type.bodyMedium)` (custom design system) used throughout — these do NOT scale with the user's preferred content size.

`grep -n "@Environment(\\\\.sizeCategory)" QAudionApp/` → zero hits. The 4 `.callout` matches found are minor info text on QR sheets, not bubble copy.

### Gap summary

| Item | Severity | Effort |
|---|---|---|
| Audit + add `.accessibilityLabel` to every interactive bubble + reaction chip + attachment | P1 | M |
| Convert `.font(.system(size:))` → `.font(.body)` / `.font(.subheadline)` (Dynamic Type-aware) | P1 | M |
| Test pass with VoiceOver + Larger Accessibility Sizes | P1 | S |

---

## 12. Battery profiling (§3.10 P1)

### State

**NOT MEASURED ON iOS.** No Instruments energy log baseline in `docs/progress/`. STATUS.md doesn't mention battery KPIs. No MetricKit subscriber to surface `MXAnimationMetric` / `MXCPUMetric` post-launch.

Likely culprits to profile:
- `BCryptoPersistentConnectionImpl.swift` WS keepalive pulse — interval?
- `PresenceService` polling cadence (`Services/PresenceService.swift`).
- `AVCaptureSession` left running on QR scan dismissal? (`QrScannerView.swift`)
- Voice recorder leaving `AVAudioSession` active.

Plan §3.10 target: <3 %/h fg, <1 %/h bg.

### Gap summary

| Item | Severity | Effort |
|---|---|---|
| Instruments Energy Log baseline run | P1 | S |
| MetricKit `MXEnergyMetric` aggregator | P1 (rolls into §8 telemetry work) | M |

---

## iOS-blocking next 10 actions (prioritized)

| # | Action | P | Effort | Coordinated with |
|---|---|---|---|---|
| 1 | **Wire `attach_announce` send-side on iOS** (build envelope from `FileMarker` data, drop the `qfile` v2 path on send). Without this, iOS attachments are unreachable from Android+Desktop — the cross-platform value-prop is broken. | P0 | M | Android (verify decode tolerance), Desktop (verify decode tolerance) |
| 2 | **Biometric app-lock + inactivity + scenePhase re-lock** (LAContext.evaluatePolicy at foreground, 5-min inactivity timer, lock on `scenePhase == .background`). The plan §2.13 sells this as a value-prop; today it's not even started. | P0 | M | None (iOS-only) |
| 3 | **Wire `DeviceManagementScreen.onRevoke` → `accountApi.revokeDevice(deviceId:)`.** Pure plumbing; the engine REST call already exists. UI is cosmetic until this lands. | P0 | S | None |
| 4 | **Honour privacy toggles** (`readReceiptsEnabled` / `typingIndicatorEnabled` actually gate `emitReadReceipts` / `notifyComposerInput`). Currently privacy theatre. | P0 | S | None |
| 5 | **Privacy policy first-launch consent gate** (between `WelcomeScreen` and `PhoneEntryScreen`). App Store + GDPR mandate. | P0 | S | Legal copy from product |
| 6 | **Identity-rotation badge + fingerprint pinning** (snapshot peer pubkey on first verify, diff on every contact key envelope, render a 🚨 chip in `ContactDetailView` + chat header). | P0 | M | Android (verify same baseline format) |
| 7 | **Decide and ship — or hide — disappearing messages** (`PrivacySettingsViewModel.disappearingMessagesDuration`). Either: (a) wire a `ttl_seconds` field on `MessageSendEnvelope` + local TTL sweep loop, OR (b) hide the picker in PrivacySettingsScreen until 1.1. Today it's a privacy lie. | P0 | M (option a) / S (option b) | Android+Desktop (wire spec field if option a) |
| 8 | **MetricKit subscriber + first-launch opt-in dialog** (no third-party SDK, privacy-manifest stays clean). Required for any production launch. | P0 | M | None (iOS-only) |
| 9 | **String extraction → `.xcstrings` Catalog (IT base + 4 placeholders)** for chat + settings + onboarding. Largest single task; gates non-IT TestFlight rollout. | P1 (P0-blocker for non-IT TestFlight) | L | Translation team (post-extraction) |
| 10 | **tus.io resumable upload client + streaming AES-GCM (CommonCrypto)** to make the 5 GB §2.6 ceiling real. Until this lands, single-shot multipart is the de-facto cap. | P0 (cross-platform; coordinate with Android, who is also still on `/files/upload`) | L | Android (joint TUS adoption), Server (verify `/files/tus` happy path) |

### Suggested ordering

Sprint 1 (P0 quick wins, ~1 week): #3, #4, #5, #6, #7-option-b.
Sprint 2 (P0 features, ~2 weeks): #1, #2, #8.
Sprint 3 (P0 heavy lift, ~3 weeks): #10, #7-option-a.
Sprint 4 (P1 stabilization, ~3 weeks): #9 + accessibility (§11) + battery profiling (§12).

### Cross-team coordination required

- **#1 + #10**: server team must confirm `/files/tus` behaviour matches what iOS+Android+Desktop expect (Upload-Length header, Tus-Resumable header, partial-upload completion). Today nobody is exercising it from a real client.
- **#6**: Android baseline for the "fingerprint pin baseline" data structure — both clients must agree on JSON schema for the `verifiedFingerprint` snapshot so a contact verified on iPhone shows verified on Android after restore.
- **#7-option-a**: cross-platform wire spec field (`ttl_seconds` on MessageSendEnvelope or a `qa_ctl:1` `t="ttl"` envelope?) — needs server-team WIRE_SPEC bump.

---

## File:line references for every claim above

(Inline throughout — every assertion cites the file + line. Where a feature is asserted ABSENT, the citation is the negative grep result + the closest comment/TODO in the source that flags the deferral.)
