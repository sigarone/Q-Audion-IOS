# iOS 1.0 Readiness — Master Audit (2026-05-02)

**Mandato utente:** "rifai un audit completo su tutto cio che manca per avere la
versione iOS completa e allineata e totalmente interfunzionante con Android,
Desktop, Server."

**Sintesi di 3 audit paralleli** (ricerca su 5523 nodi del graphify del repo
iOS, intersected with Android+Desktop+Server git log):

- `IOS_PARITY_AUDIT_2026_05_02.md` (REST + WS + opaque/sealed-sender + sigsum
  + crypto wire) — 290 linee
- `IOS_CALLING_AUDIT_2026_05_02.md` (CallKit + PushKit + WebRTC + audio/video
  + SAS) — 27 KB
- `IOS_FEATURE_AUDIT_2026_05_02.md` (chat / attachments / voice notes / recovery
  / app-lock / GDPR / a11y / l10n) — 30 KB

Ogni claim qui sotto è citato file:line nei tre audit. Questo documento è il
**single source of truth** per lo stato iOS al 2026-05-02 e per l'execution
order verso 1.0.

---

## 1. Verdetto sintetico

**iOS è il long pole della release 1.0.** Gli altri tre repo (server,
android, desktop) hanno la maggior parte dei P0 plan §2 o terminati o in
chiusura; iOS ha **3 ship-blocker strutturali** e **una decina di gap di
medio peso**.

I tre ship-blocker:

1. **iOS non parla WebRTC.** Zero `import WebRTC`, zero `RTCPeerConnection`,
   zero SDP/SRTP/ICE. Il path audio è custom-AEAD-over-WS via
   `CallService.swift:107-403` → `BCryptoWebSocketClient.sendAudioFrame`.
   `getRelays()` è implementato (`BCryptoCallingApiImpl.swift:103-107`) ma
   **mai chiamato** dall'app. Se Android usa WebRTC (da verificare),
   **i due client non si sentono**. Plan §2.2 esige peer-connection adapter
   su ogni piattaforma — iOS non contribuisce nulla.

2. **iOS SAS non deriva dall'handshake PQC.**
   `SasVerificationViewModel.swift:3-36` accetta parole pre-calcolate via
   `init`, con un `mock` statico di 4 parole hardcoded. Zero hit su
   `qaudion-sas-v1` o `sas-words-v1` in iOS prod, mentre Android `SasConstants.kt:43-87`
   ha bloccato quei label il 2026-04-28 e Desktop si è allineato con
   `e901d36`. **Risultato:** stessa chiamata, Android vede parole reali, iOS
   vede parole mock — la cerimonia SAS produce sempre "MISMATCH". E il
   view-model espone 4 parole mentre `InCallScreen.swift:184` ne stampa 6.

3. **iOS non parla nessuno degli opt-in server-side appena landati.**
   - Nessun `POST /api/v1/opaque/send` REST client
   - Nessun handler WS `opaque_msg_send` / `opaque_msg_ack`
   - Nessun `sealed_sender_cert_b64` encoder (commit `9f33c2c` server)
   - Nessuna lettura/scrittura di `X-Sigsum-Witness-TreeHead` /
     `X-Sigsum-Gossip-TreeHead` (commit `e5129db` server)
   - Nessuna primitiva sealed-sender v2 (CBOR canonical) sul lato iOS
   I commit server `bd2dc12` + `6712ced` + `9f33c2c` + `e5129db` esistono
   ma iOS non li usa.

---

## 2. Coverage matrix per area

Legenda: ✅ allineato · ⚠️ drifta su payload · ❌ assente · ⏸️ deferito a 1.1

### 2.1 REST (35 endpoint Android canonici)

| Area | Stato iOS | Note |
|---|---|---|
| Auth (register/login/refresh/logout) | ✅ | Drift critici §3.1+§3.2 chiusi (Task 1.4-a) |
| Auth recovery (setup/verify) | ❌ | Mai implementati |
| Profile | ✅ | Avatar via storage prima, poi PUT URL (Task 1.4-b3) |
| `GET users/{id}` | ❌ | Public lookup mancante |
| Contacts (discover/list/sync/block) | ✅ | Schema `contacts/sync` + `blocked` allineati (Task 1.4-b1) |
| `GET directory/by-extension/{n}` | ❌ | Blocca dial-by-extension |
| Calling relays | ✅ | Decoder OK, ma **nessun chiamante effettivo** |
| Files upload/download | ⚠️ | Single-shot multipart, **niente tus.io** |
| **Backup upload/download/list** | ❌⚠️ | **Trio rotto** — JSON+base64 vs multipart streaming, response shape sbagliata |
| Device publickey | ✅ | curve allineata X25519 (Task 1.4-b2) |
| FCM token | ✅ | platform=ios |
| **APNs VoIP token** | ✅(client) | iOS chiama `/account/apns-voip-token`; **server-side ops blocker** (deploy .p8) |
| KMS pending/ack | ✅ | Wrap `{keys:[...]}` allineato |
| Security zk-register/zk-auth/pqc-relay/wipe-confirm/threat-report | ✅ | W12.A `b86f39c` allineato |
| Version / Health | ❌ | Mancanti |
| Updates check/download/publickey | ❌ | OTA pipeline iOS assente |

**Net delta vs 2026-04-20 snapshot:** 24 → 30 di 35 endpoint. 5 chiusi (auth+contacts+kms+device+security). **6 ancora da fare** (recovery×2, directory, users/{id}, version, health, updates×3).

### 2.2 WebSocket message-types

| Type | Android invia | iOS gestisce | Note |
|---|---|---|---|
| `msg_send` / `msg_received` | ✅ | ✅ | W9.C `b56bce6` |
| `msg_delivered` / `msg_read` | ✅ | ✅ | W9.C |
| `msg_typing` | ✅ | **❌** | Inbound non handlato in `AppState` |
| `opaque_msg_send` / `opaque_msg_ack` / `opaque_msg_receive` / `opaque_mailbox_register` / `opaque_mailbox_registered` | ✅ | **❌** | iOS non parla relay opaco |
| `call_initiate` / `call_answer` / `call_ice` / `call_end` | ✅ | parziale | |
| `call_processing` / `call_ready` / `call_ring` / `call_peer_offline` / `call_cancel` | ✅ | **❌ definiti ma non registrati** | `QAudionCallIntegration.swift:281-331` definisce, `AppState.wireIncomingCallHandlers:616-672` non registra → caller non vede "Connecting → Ringing", responder non vede `call_cancel` |
| `group_membership_changed` | ✅ | ⚠️ | groups in 1.0 = solo testo, no group call |

### 2.3 Crypto wire alignment

| Area | Stato iOS | Note |
|---|---|---|
| HKDF labels canonical | ⚠️ | `HkdfLabels` helper esiste (W10.B `3b04a23`); **da verificare uso effettivo** in tutti i call site KMS |
| KMS pre-bootstrap KAT cross-platform | ❌ | iOS non ha test pinned a `kms-prebootstrap-kat.json` Android |
| `KmsKeyReceiver.swift` (P-256) | ❌ DEAD | F-6 audit: zero callers, P-256 incompatibile X25519 — da cancellare |
| Sealed-sender v2 cert (CBOR) | ❌ | Niente encoder/decoder iOS |
| Sigsum gossip headers | ❌ | Niente lettura/scrittura |
| SAS labels (`qaudion-sas-v1` / `sas-words-v1`) | ❌ | Zero hit, mock-only |
| 6-digit numeric SAS branch | ❌ | Path solo 4-PGP-words; numeric assente |

### 2.4 Calling pipeline

| Componente | Stato iOS | Verdetto |
|---|---|---|
| **WebRTC PeerConnection** | ❌ | Inesistente |
| ICE/TURN consumption | ❌ | `getRelays` non chiamato |
| SDP / SRTP | ❌ | Inesistente |
| Custom AEAD-over-WS audio | ✅ | Funzionante iPhone↔iPhone |
| Opus 16/32kHz adaptive | ⚠️ | 32kHz CBR fisso, niente adaptive nonostante `OpusCodec.reconfigure:110-116` |
| AEC/NS/AGC (voice-processing AU) | ⚠️ | `AVAudioSession.voiceChat` configurato in **2 posti** (CallKitProvider:104-107 + AudioProcessingPipeline:72-97) — race su incoming |
| PLC / jitter buffer adaptive | ❌ | Niente PLC nel decode prod path |
| H.264 baseline default | ❌ | `VideoCodecManager` default HEVC, plan vuole H.264 baseline |
| Adaptive bitrate / risoluzione | ❌ | Scaffolding only |
| `video_frame` wire path | ❌ | Inesistente |
| MOS≥3.8 @ 3% loss | ❌ | Non misurato, non raggiunto |

### 2.5 CallKit + PushKit

| Componente | Stato iOS |
|---|---|
| CallKitManaging protocol + provider | ✅ A.3 done |
| `didDeactivate` mic-pause hook | ❌ comment-only |
| `CXSetHeldCallAction` | ❌ unimplemented |
| `reportCallConnected` | ⚠️ definito ma zero callers |
| PushKitProvider + payload decoder | ✅ A.5.A done |
| Token registration → server | ✅ |
| **APNs HTTP/2 .p8 delivery** | ⚠️ server-side codice esiste (`internal/push/apns.go:36-117` + `push_fanout.go:124-128`); **blocker operativo: deploy .p8 + env vars su VPS** |
| Smoke test fisico iPhone | ❌ |

### 2.6 Chat / messaging UX

| Feature | Stato iOS | Note |
|---|---|---|
| Send/receive plain msg | ✅ | W9.C |
| Delivered/Read receipts | ✅(wire) ⚠️(privacy) | `PrivacySettingsViewModel.readReceiptsEnabled` esiste ma `ChatContainer.emitReadReceipts:564` non lo consulta — toggle è bugia |
| Typing indicator | ⚠️(send) ❌(receive) | `notifyComposerInput:312` ignora `typingIndicatorEnabled`; inbound `msg_typing` non handlato |
| Reactions / edits / deletes (qa_ctl:1) | ✅ | `ChatContainer.deleteMessage/editMessage/toggleReaction` |
| Reply / quote | ❌ | UI banner esiste, ma **nessun `reply_to` field** in `MessageSendEnvelope` (`ChatDetailScreen.swift:850` confessa "reserved for future") |
| Disappearing messages | ❌ | Picker esiste ma è dead toggle: niente wire field, niente sweeper, niente enforcement |
| Search FTS | ❌ | Out of scope iOS 1.0 |

### 2.7 Attachments + voice notes

| Feature | Stato iOS | Cross-platform |
|---|---|---|
| **`attach_announce` (qa_ctl:1) SEND** | ❌ | Codec parser esiste (`AttachAnnounceEnvelope.swift:42`), iOS legge inbound da Android+Desktop ma **non emette mai**. Send usa marker legacy `qfile` v3 (`ChatVoiceNoteSender.swift:106` + `FileTransfer.swift`) → ricevitori cross-platform vedono JSON undecodabile |
| Voice note record/send/receive/play UI | ✅ | `Services/VoiceNoteRecorder.swift` + `Player.swift` + `MessageComposer` push-to-talk + `ChatVoiceNoteSender/Receiver` ma "iPhone↔iPhone today" per disclaimer header |
| Image attachments | ✅ | EXIF-strip + ≤2048px downscale + 10MB cap (`ChatContainer.swift:816-942`) |
| **tus.io resumable upload** | ❌ | `BCryptoStorageApiImpl.swift:37-45` single-shot multipart `POST /api/v1/files/upload`, niente chunking/resume/`Upload-Offset`, **5GB §2.6 ceiling irraggiungibile** |
| XChaCha20-Poly1305 chunked encryptor | ❌ | Niente streaming AES/ChaCha; encrypt-all-in-memory |
| Thumbnails inline | parziale | Solo immagini, niente video thumb |
| Test 100MB+/1GB+/drop+resume/key-rotation mid-transfer | ❌ | Inesistente |

### 2.8 Trust UI / SAS / safety-number / identity rotation

| Feature | Stato iOS |
|---|---|
| SasVerificationView UI | ✅ | A.4 + W14 b0bc521 |
| **Derivazione SAS dall'handshake** | ❌ | View-model accetta parole via `init`, mock statico hardcoded |
| Pinned fingerprint post-verify | ⚠️ | StoredContact.pubkey persisted (`5f7757d`) ma niente baseline tracking |
| **Identity rotation badge "🚨"** | ❌ | `verified` resta `true` anche se peer ruota chiave |
| In-call header fingerprint | ✅ | W14.G `729081d` resolve via ContactsStore |
| In-person QR (show + scan) | ✅ | W14.A/C/D/E/F/H |
| Numeric 6-digit SAS | ❌ | Solo path 4-PGP-words |

### 2.9 Recovery + device management

| Feature | Stato iOS |
|---|---|
| BIP-39 RecoverySeedView | ✅ | W9.B `a0293b6` |
| Onboarding RecoverySetup | ✅ | W15.A `009cbfe` |
| `auth/recovery-setup` REST call | ❌ | Endpoint Android esiste, iOS non lo chiama |
| `auth/recovery-verify` REST call | ❌ | Idem |
| **DeviceManagementScreen.onRevoke** | ❌ stub | Engine `BCryptoAccountApiImpl.revokeDevice:55` esiste ma screen non lo chiama — UI cosmetica |
| New-device-login push | ⚠️ | Receive end probabile; send ack ❌ |

### 2.10 Hardware keystore + biometric app-lock

| Feature | Stato iOS |
|---|---|
| Secure Enclave P-256 | ✅ | `Crypto/SecureEnclaveManager.swift` |
| Keychain integration | ✅ | base layer |
| **LAContext biometric app-lock** | ❌ | Zero `LAContext` / `LocalAuthentication` callers |
| `SecureEnclaveManager.storeIdentityKey(requireBiometric:)` API | ✅ esiste (`:72`) | Nessun chiamante |
| Inactivity timer (5 min default) | ❌ | |
| Re-lock on background/rotation/foreground | ❌ | `SplashScreen.swift:19` flag "Phase…" ma nessuna fase la implementa |

### 2.11 GDPR / privacy / delete-account

| Feature | Stato iOS |
|---|---|
| Privacy policy first-launch | ❌ | Nessuna AcceptanceScreen |
| Settings → Download my data (export Ed25519) | ❌ | Niente exporter; endpoint server `/account/export` esiste |
| Settings → Delete my account | ✅ | `AccountSettingsScreen.swift:147` chiama `DELETE /api/v1/account` poi logout |
| Data minimization disclosure (PrivacyInfo.xcprivacy) | ✅ | `88ba7a1` v1.0.47-trackA |

### 2.12 Crash telemetry, l10n, a11y, battery

| Area | Stato iOS |
|---|---|
| **Crash telemetry** | ❌ | No MetricKit/Sentry/Crashlytics. STATUS.md non lo menziona neanche come deferred |
| **Localization** | ❌ | Zero `.lproj` / `.xcstrings` / `NSLocalizedString` callers — UI tutta hardcode IT/EN |
| **VoiceOver labels** | ❌ | Audit a11y mai fatto |
| Dynamic Type | ⚠️ parziale | |
| **Battery profiling Instruments** | ❌ | Target <3%/h fg, <1%/h bg non misurato |

---

## 3. Cosa è già OK (non riaprire)

- Track A.4 In-call UI scaffolding (1e5ce28 + b0bc521)
- W14 In-person pairing QR (Show + Scan + persisted pubkey)
- W9.C 4 chat envelope codecs + WS handlers (b56bce6)
- W9.B BIP-39 RecoverySeedView (a0293b6)
- W10 utility surface (FastSetupQrCode v1, HkdfLabels helper, BCryptoOtaModelClient, ContactsListViewModel)
- W12.A security endpoints alignment (b86f39c)
- W14.G in-call fingerprint resolve (729081d)
- 5 W12 + 9 A.6 ViewModels per Settings (foundation sprint)
- Backup E2EE deferred-to-1.1 — Wave 8 BackupCipher AES-GCM half + scrypt stub (`f68c626`) consistente con il defer; **non sovra-investire**
- delete-account settings flow funzionante (`AccountSettingsScreen.swift:147`)
- TestFlight pipeline + Codemagic versioning + ITMS-91061/90725 silenced (v1.0.47-trackA)

---

## 4. Roadmap di execution iOS 1.0 (priorità + sforzo)

Priorità ordinate per **interop blast radius** (rompere il cross-platform è
peggio di rompere una singola feature iOS-only).

### P0-1 — APNs VoIP delivery activation (1h ops, 2h smoke)
Server lato codice è completo (`apns.go:36-117` + `push_fanout.go:124-128`).
Manca **deploy** del file `.p8` su VPS + env vars
`BCRYPTO_APNS_KEY_PATH/KEY_ID/TEAM_ID/BUNDLE_ID`. Senza, iPhone non riceve
chiamate in background (= app inutilizzabile).

### P0-2 — SAS computation real on iOS (4h)
`SasVerificationViewModel` deve derivare 6-PGP-words usando i label canonici
`qaudion-sas-v1` (salt) + `sas-words-v1` (info), HKDF su session-key, 4-byte
SAS truncation, stesse regole di Android `SasConstants.kt:43-87` e Desktop
post-`e901d36`. Inoltre `InCallScreen.swift:184` ha 6 slot → view-model
deve esporre 6 parole, non 4.

### P0-3 — Pre-negotiation WS handlers (2h)
Registrare in `AppState.wireIncomingCallHandlers:616-672`:
`call_processing`, `call_ready`, `call_ring`, `call_peer_offline`,
`call_cancel`. Sono già definiti come entry-point in `QAudionCallIntegration.swift:281-331`
ma non agganciati. Senza, caller non vede ringback, responder non vede cancel.

### P0-4 — Decisione architettura WebRTC vs custom (1d decision + 2-4w impl)
Fork strategico: **(a)** integrare GoogleWebRTC/libwebrtc-ios e abbandonare
custom-AEAD-over-WS audio path; **(b)** portare WebRTC su Android+Desktop al
custom-AEAD-over-WS path iOS; **(c)** mantenere bridge bidirezionale (peggior
opzione, manutenzione doppia).
Plan §2.2 sembra implicare (a). Decisione blocca tutto il video work
(§2.4) + qualsiasi interop SRTP cross-platform.

### P0-5 — `attach_announce` SEND su iOS (3-4h)
`AttachAnnounceEnvelope.swift:42` parser esiste. Aggiungere encoder + sostituire
in `ChatVoiceNoteSender.swift:106` e `FileTransfer.swift` il marker legacy
`qfile`. Test interop: iPhone manda voice note → Android+Desktop ricevono
qa_ctl:1 attach_announce e leggono il blob (richiede anche §P1-2 sotto).

### P0-6 — Backup REST trio fix (1d)
`BCryptoStorageApiImpl.swift` upload/download/list — passare a multipart
streaming (upload), bytes streaming (download), risposta `{backups:[BackupEntryDto]}`.
Audit §3.6/3.7/3.8.

### P0-7 — Sealed-sender v2 cert encoder iOS (1-2d)
Per usare il `sealed_sender_cert_b64` opt-in lato server (commit `9f33c2c`).
Port da Android `cert.kt` o Desktop equivalente. CBOR canonical encoding.
Bloccato fino a quando iOS non ha un opaque-mailbox WS path.

### P0-8 — Opaque-mailbox WS handlers iOS (2-3d)
`opaque_msg_send` / `opaque_msg_ack` / `opaque_msg_receive` /
`opaque_mailbox_register`. Senza, iOS non partecipa al blind-relay che Android
e Desktop usano per la maggior parte del traffico 1:1 a contatto fresco.

### P0-9 — Biometric app-lock + inactivity timer (1-2d)
`LAContext` evaluate-policy on app foreground, UserDefaults-backed timeout
(default 5 min), scenePhase observer per re-lock su background/foreground.
Wire `SecureEnclaveManager.storeIdentityKey(requireBiometric:true)` per le
operazioni sensibili.

### P0-10 — DeviceManagementScreen revoke wire (2h)
Sostituire la closure-stub di `onRevoke` con call effettiva a
`BCryptoAccountApiImpl.revokeDevice:55`. Plan §2.11.

---

### P1 (hardening prima della GA)

- **P1-1** Privacy toggles enforcement (read-receipts + typing): consultare
  `PrivacySettingsViewModel` in `ChatContainer.emitReadReceipts:564` e
  `notifyComposerInput:312` (1h)
- **P1-2** TUS.io client + streaming AES-GCM/XChaCha20-Poly1305 chunked
  (3-5d, joint task con Android che è nello stesso stato)
- **P1-3** Disappearing messages: o nascondere il picker fino a 1.1, o
  shippare con TTL wire spec + sweeper locale (1d nasconderlo, 3-5d
  shippario)
- **P1-4** Identity rotation badge "🚨": baseline pubkey per contatto +
  detection on receive (1-2d)
- **P1-5** Reply/quote wire: aggiungere `reply_to` field a
  `MessageSendEnvelope` (1d, joint cross-platform wire spec bump)
- **P1-6** Inbound `msg_typing` handler (`AppState`) (1h)
- **P1-7** Sigsum gossip headers (lettura `X-Sigsum-Gossip-TreeHead`,
  scrittura random) (4h)
- **P1-8** auth/recovery-setup + auth/recovery-verify REST calls (4h)
- **P1-9** Crash telemetry MetricKit + privacy-preserving collector (2-3d)
- **P1-10** Localization extraction `.xcstrings` EN+IT+FR+DE+ES (1-2w)
- **P1-11** A11y VoiceOver smoke (3-5d)

---

### P2 (post-GA / nice-to-have)

- 5 endpoint REST mancanti minor: `users/{id}`, `directory/by-extension`,
  `version`, `health`, `updates/*`
- Cancellare `KmsKeyReceiver.swift` + `KmsError` (DEAD code, P-256
  incompatibile)
- 6-digit numeric SAS branch (4-PGP-words copre il caso, numeric è opt-in)
- Battery profiling Instruments

---

## 5. Effort totale stimato (single dev, focus iOS)

- **P0 senza WebRTC fork:** ~2-3 settimane (P0-1, P0-2, P0-3, P0-5..10)
- **P0 con WebRTC fork (opzione a):** +3-5 settimane (P0-4 alone)
- **P1 hardening:** +2-3 settimane in parallelo
- **P2:** post-GA

**Stima realistica iOS GA-ready:** 6-9 settimane se WebRTC fork va in scope
1.0; 3-5 settimane se la decisione P0-4 lo defer a 1.1 e si accetta che
iOS-Android calls usino il custom-AEAD-over-WS path comune.

---

## 6. Cross-team coordination map

| iOS task | Richiede |
|---|---|
| P0-2 SAS computation | Allineamento label con Android (locked 2026-04-28) — già pronto |
| P0-4 WebRTC fork | Decision + Android `QAudionPeerConnection.kt` impl (plan §2.2 — Android è anche nello skeleton-only) |
| P0-5 attach_announce send | Solo iOS (Android+Desktop già emettono e ricevono) |
| P0-6 backup REST trio | Solo iOS |
| P0-7 sealed-sender cert | Port da Android `cert.kt` |
| P0-8 opaque-mailbox WS | Solo iOS |
| P1-2 TUS + streaming AEAD | **Joint con Android** (stesso buco lì) + server tus.io integration completion |
| P1-5 reply_to wire | **Joint cross-platform wire-spec bump** (Android + Desktop + iOS allineati nello stesso commit + KAT regen) |

---

## 7. Cosa il vecchio "completato" copriva (per onestà intellettuale)

L'audit di sicurezza chiuso al turno precedente ha riguardato:
- 12 di 13 finding (5.1, 5.2, 5.3, 5.6, 5.8, 5.9, 5.10, F-6, F-7, F-11, F-12, F-13)
- + wire-up server-side (gossip globale `e5129db`, Guard su opaque/send `9f33c2c`, supply-chain CI `34b68e3`)

**Quel "100%" si riferiva alla colonna findings-di-sicurezza, non al plan
1.0 generale.** Il plan 1.0 ha **15 P0** + 10 P1 + 10 finding §5; ne sono
chiusi davvero solo i 12 finding §5 + qualche wire-up server. Tutto il
P0 §2 (calling, audio, video, chat features, recovery, app-lock, GDPR,
release pipeline) è ancora largamente open su iOS — questo audit
quantifica esattamente quanto.

---

## 8. Documenti collegati

- [`IOS_PARITY_AUDIT_2026_05_02.md`](./IOS_PARITY_AUDIT_2026_05_02.md) — REST/WS/crypto wire alignment dettaglio
- [`IOS_CALLING_AUDIT_2026_05_02.md`](./IOS_CALLING_AUDIT_2026_05_02.md) — CallKit/PushKit/WebRTC/audio/video
- [`IOS_FEATURE_AUDIT_2026_05_02.md`](./IOS_FEATURE_AUDIT_2026_05_02.md) — chat/attachments/UX/OS-integration
- [`PHASE1_REST_AUDIT.md`](./PHASE1_REST_AUDIT.md) — predecessore 2026-04-20
- [`STATUS.md`](./STATUS.md) — snapshot last edited 2026-04-28
- Plan `D:\users\f10379a\.claude\plans\glittery-sleeping-hejlsberg.md`
- Security findings tracker `apps/qaudion-android-new/docs/security/findings.md`

---

*Generated 2026-05-02 dalla sintesi di 3 audit paralleli (researcher agents
con accesso al graphify del repo iOS, 5523 nodi). Il documento è il single
source of truth per l'execution iOS 1.0; aggiornare in-place quando i task
P0/P1 si chiudono, citando il commit hash.*
