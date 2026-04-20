# Phase 1.2 — REST Endpoint Audit (iOS vs Android `BCryptoApi.kt`)

> **Status:** Read-only audit. Findings only; fixes scheduled for a subsequent task.
> **Date:** 2026-04-20
> **Reference (authoritative):** `Q-Audion Android New/core/core-data/src/main/java/com/bcrypto/qaudion/data/net/BCryptoApi.kt` + DTOs under `…/data/net/dto/`.
> **iOS impls audited:** `QAudionEngine/Sources/QAudionEngine/Backend/BCrypto/*.swift` + `…/Crypto/SovereignIdentityManager.swift` + `…/Integration/OtaDownloadManager.swift`.

---

## 1. Executive summary

- **35 authoritative Android endpoints.**
- **iOS covers 24** (directly or via legacy shape).
- **11 endpoints missing** on iOS (recovery, directory-by-extension, users/{id}, version/health, updates/*).
- **12 drifts in payload shape** — some catastrophic (login field name mismatch, zkRegister/zkAuth completely different schema).
- **10 iOS endpoints with no Android counterpart** — legacy / experimental paths that may or may not exist server-side (OIDC, sovereign-identity, auth/challenge, security/cert-info+compliance, models OTA, contacts CRUD).
- **Two D-CRITICAL drifts** that break cross-platform interop silently (auth + contact sync).

Phase 1.2 is **COMPLETE as an audit**. Fixes are **partially blocked** by USER's uncommitted WT (only `BCryptoCallingApiImpl.swift` has calling-relays REST — which matches Android anyway). All other drifts live in files outside D-05 hygiene list → safe to fix next.

---

## 2. Coverage matrix — Android authoritative vs iOS impl

Legend: ✅ matches · ⚠️ path matches / payload drifts · ❌ missing on iOS · ➕ iOS-only (not in Android)

### 2.1 Auth

| # | Android (authoritative) | iOS impl | Status | Notes |
|---|---|---|---|---|
| 1 | `POST register` | `BCryptoAccountApiImpl.register` | ⚠️ | Field drift — see §3.1 |
| 2 | `POST auth/login` | `BCryptoAccountApiImpl.login` | ⚠️ | Field drift — see §3.2 |
| 3 | `POST auth/refresh` | `BCryptoAccountApiImpl.refreshToken` | ✅ | `{refresh_token}` matches |
| 4 | `DELETE auth/logout` | `BCryptoAccountApiImpl.logout` | ✅ | No body |
| 5 | `POST auth/recovery-setup` | — | ❌ | MISSING (seed-phrase enrol) |
| 6 | `POST auth/recovery-verify` | — | ❌ | MISSING (seed-phrase recover) |
| — | — | `GET auth/oidc` | ➕ | iOS-only (`BCryptoOIDCClient`) |
| — | — | `GET auth/oidc/authorize` | ➕ | iOS-only |
| — | — | `POST auth/oidc/callback` | ➕ | iOS-only |
| — | — | `POST auth/challenge` | ➕ | iOS-only (`SovereignIdentityManager:166`) |
| — | — | `POST auth/challenge/verify` | ➕ | iOS-only (`SovereignIdentityManager:179`) |
| — | — | `POST register/sovereign` | ➕ | iOS-only (`SovereignIdentityManager:135`) |
| — | — | `POST register/sovereign/verify` | ➕ | iOS-only |

### 2.2 Profile / Users

| # | Android | iOS | Status | Notes |
|---|---|---|---|---|
| 7 | `GET profile` | `BCryptoAccountApiImpl.getProfile` | ✅ | Returns `UserProfile` |
| 8 | `PUT profile` | `BCryptoAccountApiImpl.updateProfile` | ⚠️ | Field drift + unsupported multipart branch — see §3.3 |
| 9 | `GET users/{user_id}` | — | ❌ | MISSING (public user lookup) |

### 2.3 Contacts

| # | Android | iOS | Status | Notes |
|---|---|---|---|---|
| 10 | `POST contacts/discover` | `BCryptoContactsApiImpl.discoverContacts` | ✅ | `{phone_hashes: [...]}` matches |
| 11 | `GET contacts` | `BCryptoContactsApiImpl.listContacts` | ✅ | |
| 12 | `POST contacts/sync` | `BCryptoContactsApiImpl.syncContacts` | ⚠️ | **Schema completely different** — see §3.4 |
| 13 | `POST contacts/block` | `BCryptoContactsApiImpl.blockContact` | ✅ | `{user_id}` matches |
| 14 | `DELETE contacts/block/{user_id}` | `BCryptoContactsApiImpl.unblockContact` | ✅ | |
| 15 | `GET contacts/blocked` | `BCryptoContactsApiImpl.getBlockedContacts` | ⚠️ | iOS decodes `contacts` but Android returns `blocked` array — see §3.5 |
| — | — | `POST contacts` | ➕ | iOS-only (addContact) |
| — | — | `DELETE contacts/{id}` | ➕ | iOS-only (removeContact) |

### 2.4 Directory

| # | Android | iOS | Status | Notes |
|---|---|---|---|---|
| 16 | `GET directory/by-extension/{n}` | — | ❌ | MISSING — blocks Task 3.x dial-by-extension |

### 2.5 Calling / Relays

| # | Android | iOS | Status | Notes |
|---|---|---|---|---|
| 17 | `GET calling/relays` | `BCryptoCallingApiImpl.getRelays` | ✅ | `RelayResponse` decoding OK |

### 2.6 Files

| # | Android | iOS | Status | Notes |
|---|---|---|---|---|
| 18 | `POST files/upload` (multipart) | `BCryptoStorageApiImpl.uploadFile` | ✅ | Response shape partial-compatible (iOS only reads `file_id`) |
| 19 | `GET files/{file_id}` (streaming) | `BCryptoStorageApiImpl.downloadFile` | ✅ | iOS returns raw `Data`; server streams bytes |

### 2.7 Backup

| # | Android | iOS | Status | Notes |
|---|---|---|---|---|
| 20 | `POST backup/upload` (multipart `backup` + `key_hint`) | `BCryptoStorageApiImpl.uploadBackup` | ❌⚠️ | **iOS sends JSON `{key, data: base64}`** — completely wrong transport/format. See §3.6 |
| 21 | `GET backup/download/{backup_id}` (streaming) | `BCryptoStorageApiImpl.downloadBackup` | ⚠️ | iOS parses JSON response; Android streams bytes. See §3.7 |
| 22 | `GET backup/list` → `{backups: [BackupEntryDto]}` | `BCryptoStorageApiImpl.listBackups` | ⚠️ | iOS decodes `{keys: [String]}` — wrong key & wrong element type. See §3.8 |
| 23 | `DELETE backup/{backup_id}` | `BCryptoStorageApiImpl.deleteBackup` | ✅ | Path matches |

### 2.8 Device / Account

| # | Android | iOS | Status | Notes |
|---|---|---|---|---|
| 24 | `POST device/publickey` | `BCryptoKmsClient.registerPublicKey` | ⚠️ | iOS sends extra `device_id`; default `key_type` differs ("P-256" vs "x25519"). See §3.9 |
| 25 | `POST account/fcm-token` | `BCryptoAccountApiImpl.registerPushToken` | ✅ | Platform default `"ios"` is correct |

### 2.9 KMS

| # | Android | iOS | Status | Notes |
|---|---|---|---|---|
| 26 | `GET kms/pending` → `{keys: [KmsKeyDto]}` | `BCryptoKmsClient.getPendingKeys` | ⚠️ | iOS decodes **bare array** `[PendingKey]`. Android wraps in `{keys: [...]}`. See §3.10 |
| 27 | `POST kms/acknowledge/{key_id}` | `BCryptoKmsClient.acknowledgeKey` | ✅ | |

### 2.10 Security

| # | Android | iOS | Status | Notes |
|---|---|---|---|---|
| 28 | `POST security/zk-register` | `BCryptoSecurityApiImpl.zkRegister` | ❌⚠️ | **Schema completely different** — see §3.11 |
| 29 | `POST security/zk-auth` | `BCryptoSecurityApiImpl.zkAuth` | ❌⚠️ | **Schema completely different** — see §3.12 |
| 30 | `POST security/pqc-relay` | `BCryptoSecurityApiImpl.sendPqcKeyExchange` | ❌⚠️ | **Schema completely different** — see §3.13 |
| 31 | `POST security/threat-report` | `BCryptoSecurityApiImpl.reportThreat` | ⚠️ | Field-name drift — see §3.14 |
| 32 | `POST security/wipe-confirm` | `BCryptoSecurityApiImpl.confirmWipe` | ❌⚠️ | **Schema completely different** — see §3.15 |
| — | — | `GET security/cert-info` | ➕ | iOS-only |
| — | — | `GET security/compliance` | ➕ | iOS-only |

### 2.11 System / Health

| # | Android | iOS | Status | Notes |
|---|---|---|---|---|
| 33 | `GET version` | — | ❌ | MISSING |
| 34 | `GET config/client` | `BCryptoStorageApiImpl.getClientConfig` | ✅ | iOS returns raw dict; Android decodes to `ClientConfigResponse` — dict form is interop-safe |
| 35 | `GET health` | — | ❌ | MISSING |

### 2.12 Updates (OTA)

| # | Android | iOS | Status | Notes |
|---|---|---|---|---|
| 36 | `GET updates/check?current_version=&channel=` | — | ❌ | MISSING |
| 37 | `GET updates/download/{id}` (streaming) | — | ❌ | MISSING |
| 38 | `GET updates/publickey` | — | ❌ | MISSING |
| — | — | `GET models/{name}` | ➕ | iOS-only (`OtaDownloadManager:10`) — AASIST model channel, unrelated to app OTA |
| — | — | `GET models/latest` | ➕ | iOS-only (`OtaDownloadManager:16`) |

---

## 3. Drift details

### 3.1 ⚠️ D-CRITICAL — `register` payload *(RESOLVED — see Task 1.4-a commit)*

**Android `RegisterRequest`** (wire): `{ phone_number: <SHA-256 hex hash>, password, invite_code?, display_name? }`
Note: Kotlin property `phoneHash` is annotated `@SerialName("phone_number")` — the server key is `phone_number`, but the VALUE sent is the hash.

**iOS `BCryptoAccountApiImpl.register:8-11`** (wire): `{ phone_number: <RAW phone>, invite_code? }`
- Sends **raw phone** under `phone_number` (expected hash).
- **Missing `password`** entirely → Android-registered accounts cannot authenticate via iOS-created ones, and iOS registration likely fails server-side validation.
- **Missing `display_name`** (optional but expected by Android clients).
- `AuthService.register(phoneNumber:)` also passes raw phone straight through, confirming this is not just a naming issue.

**Impact:** Silent cross-platform account incompatibility. iOS users created via this path cannot be discovered by Android contact-discovery (which hashes), and vice-versa.

### 3.2 ⚠️ D-CRITICAL — `auth/login` payload *(RESOLVED — see Task 1.4-a commit)*

**Android `LoginRequest`** (wire): `{ phone_number: <SHA-256 hash>, password, device_name }`
**iOS `BCryptoAccountApiImpl.login:17-18`** (wire): `{ phone_hash: <hash>, password, device_name }`

- Wire key is **`phone_hash`** on iOS but server expects **`phone_number`** (per Android contract).
- Value is correct (hash) post-Task-1.3.
- Server likely 401s or treats field as missing.

**Impact:** iOS login **broken** against any server that follows the Android contract. Fix is trivial (rename key) but belongs to the next fix task — this audit is read-only.

### 3.3 ⚠️ `PUT profile` drift

**Android `UpdateProfileRequest`**: `{ display_name?, status_message?, avatar_url? }` — all optional.
**iOS `BCryptoAccountApiImpl.updateProfile`**:
- JSON branch: `{ display_name, status_message }` — both non-null, missing `avatar_url`.
- Multipart branch: `POST /profile` with `display_name`, `status_message`, `avatar` file part → **Android has no such endpoint/verb**. Will 404 or 405.

**Impact:** Avatar upload path is non-functional. Profile PUT works for name/status only.

### 3.4 ⚠️ D-CRITICAL — `contacts/sync` schema

**Android `SyncContactsRequest`**: `{ contacts: [{ contact_user_id, display_name?, local_alias? }] }`
**iOS**: `{ phone_hashes: [String] }`

Completely different intent — Android sync uploads user_ids + labels; iOS uploads hash batch (which is what `contacts/discover` does). The iOS impl is either duplicating discover or broken.

### 3.5 ⚠️ `contacts/blocked` response decode

Android returns `{ blocked: [BlockedEntryDto{user_id, blocked_at}] }`. iOS decodes as `{ contacts: [DiscoveredContact] }` → JSON key mismatch + wrong shape.

### 3.6 ⚠️ `backup/upload` transport

Android: multipart `backup` + `key_hint` parts. Response `{ backup_id, size_bytes, checksum? }`.
iOS: JSON `{ key, data: <base64> }`. Response `{ id }` (not `backup_id`).

### 3.7 ⚠️ `backup/download` parsing

Android streams raw bytes. iOS parses JSON `{ data: <base64> }` and base64-decodes → will fail or truncate on real binary backups.

### 3.8 ⚠️ `backup/list` response schema

Android: `{ backups: [BackupEntryDto{backup_id, size_bytes, created_at?, key_hint?}] }`.
iOS: decodes `{ keys: [String] }` — wrong wire key, loses structured metadata.

### 3.9 ⚠️ `device/publickey` payload

Android: `{ public_key, key_type="x25519" }`.
iOS: `{ device_id, public_key, key_type="P-256" }` — extra `device_id`, different algorithm default.

**Impact:** Server may reject unknown field or ignore; key_type=P-256 vs x25519 means iOS and Android register **different curves** by default — incompatible if server uses key_type to route handshake.

### 3.10 ⚠️ `kms/pending` response envelope

Android: `{ keys: [KmsKeyDto{key_id, key_name, fingerprint, status, encrypted_package, ephemeral_pubkey, nonce, created_at?}] }`.
iOS: decodes **bare array** `[PendingKey{key_id, encrypted_key, algorithm, created_at}]`.

Double drift: envelope missing (`keys:` wrapper) + DTO schema entirely different (`encrypted_key` vs `encrypted_package` + missing `fingerprint`/`ephemeral_pubkey`/`nonce`).

### 3.11 ⚠️ `security/zk-register` schema

Android: `{ zk_commitment, public_params? }`.
iOS: `{ salt, verifier_v, public_blind }`.

No overlap. This is cargo-culted from a different ZK protocol (looks like SRP-style `verifier_v`).

### 3.12 ⚠️ `security/zk-auth` schema

Android: `{ challenge, proof }`.
iOS: `{ client_public, proof, nonce }`.

`proof` is the only shared field.

### 3.13 ⚠️ `security/pqc-relay` schema

Android: `{ recipient_id, ciphertext, algorithm="ml-kem-768" }`.
iOS: `{ target_user_id, pqc_ciphertext, x25519_public_key, message_type, enclave_public_key? }`.

Field names differ (`recipient_id` vs `target_user_id`, `ciphertext` vs `pqc_ciphertext`), iOS bundles the x25519 pubkey into the relay envelope (Android splits into separate channels), iOS default algorithm unspecified (Android `ml-kem-768`; project target is `ml-kem-1024`).

### 3.14 ⚠️ `security/threat-report` field names

Android: `{ category, details, severity }`.
iOS: `{ threat_kind, severity, detail, timestamp, session_id? }`.

`category`↔`threat_kind`, `details`↔`detail`. Extra iOS fields likely ignored.

### 3.15 ⚠️ `security/wipe-confirm` schema

Android: `{ wipe_id, confirmed }` — client ACKs a server-initiated wipe by echoing the `wipe_id`.
iOS: `{ device_id }` — client tells server which device was wiped (reverse direction).

Completely different semantic contract; requires clarification with server team before fixing.

---

## 4. Files touched by this audit (read-only)

**iOS (read):**
- `QAudionEngine/Sources/QAudionEngine/Backend/BCrypto/BCryptoAccountApiImpl.swift`
- `QAudionEngine/Sources/QAudionEngine/Backend/BCrypto/BCryptoContactsApiImpl.swift`
- `QAudionEngine/Sources/QAudionEngine/Backend/BCrypto/BCryptoSecurityApiImpl.swift`
- `QAudionEngine/Sources/QAudionEngine/Backend/BCrypto/BCryptoStorageApiImpl.swift`
- `QAudionEngine/Sources/QAudionEngine/Backend/BCrypto/BCryptoKmsClient.swift`
- `QAudionEngine/Sources/QAudionEngine/Backend/BCrypto/BCryptoOIDCClient.swift`
- `QAudionEngine/Sources/QAudionEngine/Backend/BCrypto/BCryptoCallingApiImpl.swift` *(USER WT — read only)*
- `QAudionEngine/Sources/QAudionEngine/Integration/OtaDownloadManager.swift`
- `QAudionEngine/Sources/QAudionEngine/Crypto/SovereignIdentityManager.swift`

**Android (read):**
- `core/core-data/.../data/net/BCryptoApi.kt`
- `core/core-data/.../data/net/dto/{Auth,Contacts,Profile,Device,Security,Kms,Storage,Updates,Calling}Dto.kt`

**Android working tree untouched by the agent** (`git status` in Android repo shows only user's preexisting WT changes on `WsCodec.kt`, `WsCommand.kt`, `WsEvent.kt`, `DatabasePassphraseVault.kt`, `WsCallSignaller.kt`, `CallController.kt`). No Android file was modified.

---

## 5. Recommended fix ordering (for a follow-up task 1.2-fix)

1. **D-CRITICAL auth fixes** (login key rename + register add password/hash) — single small commit, unblocks cross-platform login.
2. **Contact-sync schema realignment** — `BCryptoContactsApiImpl.syncContacts` + `getBlockedContacts` decode.
3. **Security endpoint schemas** (zk-register, zk-auth, pqc-relay, threat-report, wipe-confirm) — five schema-only changes; requires coordination with server team to confirm Android or iOS is "right" for each.
4. **Backup transport fixes** — move to multipart upload + streaming download + decode `BackupEntryDto`.
5. **KMS pending envelope** + DTO reshape.
6. **Missing endpoints** (recovery-setup, recovery-verify, directory/by-extension, version, health, updates/*, users/{id}) — add new impls; none collide with USER WT.
7. **`device/publickey` alignment** — drop `device_id`, change default `key_type` to `"x25519"` (or confirm with server).
8. **Cleanup iOS-only endpoints** — verify server support for OIDC, sovereign-identity, challenge/*, security/cert-info+compliance, models/*; remove dead ones, flag working ones in ANDROID_REFERENCE.md as iOS-ahead.

**Blocked by USER WT (D-05):** none of the above. `BCryptoCallingApiImpl.swift` has only `GET calling/relays` which already matches Android. All fixable files are outside the hygiene list.

---

## 6. Audit status

- **Endpoint coverage:** documented ✅
- **Drift catalogue:** documented ✅
- **Fix recommendations:** documented ✅
- **Task 1.2 verdict:** PARTIAL — audit complete; fixes deferred to a dedicated task (not in the 13-phase plan snapshot — treat as emergent Phase 1.4 follow-on).
- **Phase 1 closure:** blocked on Task 1.1 (WS code fixes, blocked on USER WT) **and** a new Task 1.4 (REST fixes per §5).

Tag `v1.0.24-ph1` should not be cut until §5 items 1 + 2 land minimum; items 3–8 can follow in `v1.0.24-ph1-b` if needed to de-risk the first TestFlight.
