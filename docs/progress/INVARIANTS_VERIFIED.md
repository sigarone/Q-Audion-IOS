# Cross-Platform Invariants — Verified

> **Generated:** 2026-04-28 (Phase F0 of Track A Foundation Sprint).
> **Source spec:** [docs/superpowers/specs/2026-04-28-cross-platform-alignment-design.md §5](../superpowers/specs/2026-04-28-cross-platform-alignment-design.md).
> **Purpose:** pin canonical values shared across `qaudion-ios` / `qaudion-android-new` / `qaudion-desktop` / `bcrypto-server`. Any divergence breaks interop silently.
>
> Legend: ✅ identical bytes verified · ⚠️ value found but format / encoding differs · ❌ value missing on this platform · 🟡 not applicable on this platform

## §5.1 — Identity / hashing

### Phone hash

| Platform | Source | Algorithm | Notes |
|---|---|---|---|
| iOS | `QAudionEngine/Sources/QAudionEngine/Utils/PhoneHash.swift:74` | `hex(sha256(utf8(normalizeE164(input))))` lowercase | Strips `[\s ().\-/]`, replaces leading `00` with `+`, prepends `defaultCountry` (`+39`) when no `+`. Regex `^\+[1-9]\d{7,14}$`. |
| Android | `feature/feature-auth/src/main/java/com/bcrypto/qaudion/feature/auth/PhoneHashHelper.kt:61` | `hex(sha256(utf8(normalizeE164(input))))` lowercase | Same strip regex, same `00→+` substitution, same E.164 regex, same `defaultCountry = "+39"`. Byte-for-byte mirror of iOS per KDoc. |
| Desktop | `src/main/transport/BCryptoApi.ts:624` | (not computed; sends pre-hashed values from iOS/Android to `/contacts/discover`) | Desktop calls `/contacts/discover` with `phone_hashes` supplied externally; no local normalise+hash. Contact discovery initiated by mobile clients. |
| Server | `internal/api/account.go:180–185` | (not computed; validates 64-hex format only) | `GET /api/v1/contacts/discover` accepts `phone_hashes[]`; server rejects non-64-hex values via `isSHA256Hex` but never re-hashes. |

**Status:** ✅ verified — iOS and Android compute identical bytes for `+39 333 1234567` → `hex(sha256("+393331234567"))` lowercase (64-char hex). Desktop does not hash independently; it relays mobile-computed hashes.

### Username hash (peppered)

| Platform | Source | Algorithm | Notes |
|---|---|---|---|
| iOS | ❌ not implemented | — | No `username`, `pepper`, or `/discover/username` usage found anywhere in `QAudionEngine/Sources`. Phase B.7 gap. |
| Android | ❌ not implemented | — | No `username` hash or `/discover/pepper` call found in `qaudion-android-new`. Phase B.7 gap. |
| Desktop | `src/main/Application.ts:998–1004` | `base64(sha256(lower(handle) ‖ pepper)[:16])` | Fetches 32-byte pepper via `GET /api/v1/discover/pepper`; hashes with Node `createHash('sha256')`, truncates to 16 bytes, sends as base64 to `GET /discover/username?h=`. |
| Server | `cmd/bcrypto-lite/main.go:2247–2253` | `sha256(lower(username) ‖ pepper)[:16]` stored as raw bytes; base64-encoded in response | Pepper served at `GET /api/v1/discover/pepper`. Validates 3–32 chars `[a-zA-Z0-9_]`, normalises to lowercase. Returns `username_hash_b64` + `alg="sha256-peppered-v1"`. |

**Status:** ⚠️ Desktop and Server agree on `sha256(lower ‖ pepper)[:16]` (identical byte order, same truncation). iOS and Android have no implementation yet — see "Open discrepancies" §1.

### Contact-discovery hash v2 (peppered)

| Platform | Source | Algorithm | Notes |
|---|---|---|---|
| iOS | ❌ not implemented | — | `BCryptoContactsApiImpl.swift:9` calls legacy `/api/v1/contacts/discover` (v1, unpeppered) only. No `contacts/pepper` fetch or v2 endpoint. Phase B.7 gap. |
| Android | `feature/feature-contacts/src/main/java/com/bcrypto/qaudion/feature/contacts/domain/DiscoverContactsUseCase.kt:284–289` | `hex(sha256(pepper ‖ utf8(e164)))` lowercase | Fetches 32-byte pepper via `GET /api/v1/contacts/pepper`; calls `POST /contacts/discover-v2`. Falls back to v1 when pepper unavailable. Also registers own peppered hashes via `POST /contacts/phones`. |
| Desktop | ❌ not implemented | — | No `/contacts/pepper`, `/contacts/discover-v2`, or `RegisterPepperedPhones` call found anywhere in `src/`. Desktop relies solely on v1 unpeppered discovery. Phase B.7 gap. |
| Server | `internal/store/bbolt.go:88–90`, `cmd/bcrypto-lite/main.go:2007–2031` | (not computed; validates and stores client-supplied hex hashes) | Serves 32-byte random pepper at `GET /api/v1/contacts/pepper` (alg `sha256-peppered-v1`). Stores peppered hashes in `bucketPepperedPhones`; queries them at `POST /contacts/discover-v2`. Never recomputes. |

**Status:** ⚠️ Android implements v2 peppered discovery; iOS and Desktop use v1 (unpeppered) only — see "Open discrepancies" §2.

### Public-key fingerprint (display)

| Platform | Source | Algorithm | Notes |
|---|---|---|---|
| iOS | `QAudionEngine/Sources/QAudionEngine/Crypto/ContactKeyExchange.swift:142–144` | `hex(sha256(psk_bytes))` — full 64-char lowercase hex | No abbreviated display format. The full hex string is stored via `SovereignKeyVault.storePsk(fingerprint:)` and displayed verbatim (see `KeyManagementView.swift:19`). |
| Android | `qaudion-engine/src/main/java/com/bcrypto/qaudion/crypto/SovereignKeyVault.kt:656–658` | `sha256(key_bytes)` → take first 16 hex chars → group into 4×4 with dots: `xxxx.xxxx.xxxx.xxxx` | `fullFingerprint` = full 64-char hex; `fingerprint` = `formatDisplayFingerprint(fullHex)` = `fullHex.take(16).chunked(4).joinToString(".")`. Wire protocol uses `fullFingerprint` for PSK negotiation. |
| Desktop | `src/main/store/SovereignKeyVault.ts:362` | `sha256(material).digest('hex')` — full 64-char lowercase hex | Stored as `fingerprint` field in `PskEntry`; displayed as `fingerprint.slice(0, 28) + "…"` in UI (`CryptoProfileBody.svelte:135`). No dot-grouped abbreviated format. |
| Server | 🟡 not applicable | — | Server stores PSK metadata via KMS delivery; it does not compute PSK fingerprints directly. `internal/kms/handlers.go` surfaces the `fingerprint` field from the client-submitted key record. |

**Status:** ⚠️ All platforms compute `sha256(psk_bytes)` hex, but display formatting diverges: Android shows abbreviated `xxxx.xxxx.xxxx.xxxx` (first 16 hex chars in 4 groups), while iOS and Desktop show a full or truncated 64-char hex string without dot-grouping — see "Open discrepancies" §3.

## §5.2 — Symmetric crypto

| Item | Spec value | iOS | Android | Desktop | Server | Status |
|---|---|---|---|---|---|---|
| AEAD | AES-256-GCM, 12B nonce, 16B tag | `AES.GCM` (CryptoKit); `nonceSize=12`, `tagSize=16` — `CryptoConstants.swift:15–16`, enforced in `AeadCipher.swift:36,43` | `"AES/GCM/NoPadding"`; `GCMParameterSpec(128, nonce)`, `NONCE_SIZE=12`, `TAG_SIZE=16` — `CryptoConstants.kt:15,25–29`, `AeadCipher.kt:110–113` | `AES_KEY_SIZE_BYTES=32`, `GCM_NONCE_SIZE_BYTES=12`, `GCM_TAG_SIZE_BYTES=16` — `src/shared/protocol/constants.ts:14–16` | `NonceSize=12`, `cipher.NewGCM` via `crypto/aes`+`crypto/cipher` — `internal/kms/kms.go:18,104` | ✅ identical |
| Hash | SHA-256 everywhere | `SHA256` (CryptoKit) — used in `MessageCrypto.swift:124`, `SessionManager.swift:89`, `HybridPqcKeyExchange.swift:218`, `ContactKeyExchange.swift:134` | `HmacSHA256` for HKDF (`CryptoConstants.kt:41`), `MessageDigest("SHA-256")` for digests — `CertificatePinning.kt:144`, `RecoveryCrypto.kt:87–88` | Web Crypto `SubtleCrypto.digest('SHA-256')` + `hkdf` with `hash:'SHA-256'` — used in `PqcKeyExchange.ts`, `MessageCrypto.ts` | `crypto/sha256` stdlib — `internal/kms/kms.go:8,44,52` | ✅ identical |
| HKDF | HKDF-SHA256, 32B output | `HKDF<SHA256>.deriveKey(…, outputByteCount: 32)` (CryptoKit) — `MessageCrypto.swift:124`, `SessionManager.swift:89`, `HybridPqcKeyExchange.swift:218` | `HKDFBytesGenerator(SHA256Digest())` (Bouncy Castle) → 32B — `DeviceLinkingProtocol.kt:171`, `HybridPqcKeyExchange.kt:11`, `RecoveryCrypto.kt:86–90` | `crypto.subtle.deriveBits({name:'HKDF', hash:'SHA-256', …}, key, 256)` — `PqcKeyExchange.ts`, `PqcHandshake.ts:47–50` | `hkdf.New(sha256.New, …)` via `golang.org/x/crypto/hkdf` → 32B — `internal/kms/kms.go:13,92–94` | ✅ identical |

## §5.3 — HKDF labels

> Note on spec column for rows 6–8: the spec table used constant *names* (`FRAME_CHAIN_AUDIO`, `FRAME_CHAIN_VIDEO`, `FILE_KEY`) as placeholders. The canonical wire bytes are defined in Desktop `src/shared/protocol/constants.ts` and reproduced below.

| Purpose | Spec salt | Spec info | iOS source | Android source | Desktop source | Status |
|---|---|---|---|---|---|---|
| Message conversation key | per-pair (random 32B) | `"q-audion-msg-key"` | `CryptoConstants.HKDF_INFO_MSG_KEY = "q-audion-msg-key"` — `CryptoConstants.swift:39`; used in `MessageCrypto.swift:46,94` | `HKDF_INFO = "q-audion-msg-key"` — `MessageCrypto.kt:95`; used at line 229 | `HKDF_LABELS.MSG_KEY = 'q-audion-msg-key'` — `constants.ts:22`; used in `MessageCrypto.ts:20` | ✅ identical |
| Device-link PSK | `"qaudion-link-salt"` | `"qaudion-device-link-v1"` | ❌ not implemented — no `DeviceLinkingProtocol` or these label strings found anywhere in `QAudionEngine/Sources`. Phase B.6 gap. | `HKDF_INFO = "qaudion-device-link-v1"` (companion object) + `"qaudion-link-salt".toByteArray()` at call site — `DeviceLinkingProtocol.kt:42,174` | ❌ not implemented — no device-link HKDF or `qaudion-link-salt` found in `src/`. Desktop has no multi-device linking flow. | ⚠️ Android only — see "Open discrepancies" §4 |
| NFC collaborative PSK | `sha256(sorted(pubA, pubB))` | `"Q-Audion NFC Collaborative PSK v1"` | `CryptoConstants.hkdfNfcCollaborativePskInfo = "Q-Audion NFC Collaborative PSK v1"` — `CryptoConstants.swift:52` | `HKDF_INFO_COLLAB = "Q-Audion NFC Collaborative PSK v1"` — `NfcProtocol.kt:135` | ❌ not implemented — NFC pairing not present in Desktop (`src/`). | ⚠️ iOS+Android match; Desktop N/A — see "Open discrepancies" §5 |
| Hybrid PQC session key | `HYBRID_PQC_SALT_V1` = `"q-audion-hybrid-pqc-v1"` | `HYBRID_PQC_INFO` = `"q-audion-session-key"` | `hybridKdfSalt = "q-audion-hybrid-pqc-v1"`, `hybridKdfInfo = "q-audion-session-key"` — `CryptoConstants.swift:85,87`; consumed in `HybridPqcKeyExchange.swift:215–216` | `HYBRID_KDF_SALT = "q-audion-hybrid-pqc-v1"`, `HYBRID_KDF_INFO = "q-audion-session-key"` — `CryptoConstants.kt:124,127`; used in `HybridPqcKeyExchange.kt:42` | `HYBRID_PQC_SALT_V1: 'q-audion-hybrid-pqc-v1'`, `HYBRID_PQC_INFO: 'q-audion-session-key'` — `constants.ts:38,40`; consumed in `PqcHandshake.ts:48,50` and `PqcKeyExchange.ts:227–228` | ✅ identical |
| Recovery seed → secret | `"recovery-auth-v1"` (spec) | BIP-39 mnemonic (spec) | ❌ not implemented — iOS sends `recoverySecret` as an opaque string via `BCryptoAccountApiImpl.swift:71` but no local HKDF derivation with `"recovery-auth-v1"` exists in `QAudionEngine/Sources`. Phase B.8 gap. | `info = "recovery-auth-v1"`, `salt = "bcrypto-recov-v1"`, `ikm = entropy` — `RecoveryCrypto.kt:70–71`. Note: actual salt is `"bcrypto-recov-v1"`, not `"recovery-auth-v1"` as the spec salt column states — see "Open discrepancies" §6. | ❌ not implemented — no recovery HKDF in `src/`. Desktop has no seed-phrase recovery flow. | ⚠️ Android only; spec salt/info description inaccurate — see "Open discrepancies" §6 |
| Frame chain (audio) | chainKey | `"q-audion-frame-key"` (spec column used constant name `FRAME_CHAIN_AUDIO`; canonical bytes from Desktop) | `hkdfInfoChain = "q-audion-frame-key"` — `CryptoConstants.swift:28`; used in `SessionManager.swift:41,72` | `HKDF_INFO_CHAIN = "q-audion-frame-key"` — `CryptoConstants.kt:54` | `FRAME_CHAIN_AUDIO: 'q-audion-frame-key'` — `constants.ts:24` | ✅ identical |
| Frame chain (video) | chainKey | `"q-audion-video-frame-key"` (spec column used constant name `FRAME_CHAIN_VIDEO`) | `hkdfInfoVideoChain = "q-audion-video-frame-key"` — `CryptoConstants.swift:34` | `HKDF_INFO_VIDEO_CHAIN = "q-audion-video-frame-key"` — `CryptoConstants.kt:67` | `FRAME_CHAIN_VIDEO: 'q-audion-video-frame-key'` — `constants.ts:26` | ✅ identical |
| Attachment | contactPSK | `"q-audion-file-key"` (spec column used constant name `FILE_KEY`) | `HKDF_INFO_FILE_KEY = "q-audion-file-key"` — `CryptoConstants.swift:40`; consumed in `FileTransfer.swift:26` | `HKDF_INFO = "q-audion-file-key"` — `FileCrypto.kt:38` | `FILE_KEY: 'q-audion-file-key'` — `constants.ts:34`; referenced in `FileTransfer.ts:34–35` | ✅ identical |

## §5.4 — Asymmetric crypto

_(F0.4)_

## §5.5 — NFC collaborative pairing

_(F0.4)_

## §5.6 — Device-linking binary QR

_(F0.4)_

## §5.7 — VoIP push payload

_(F0.4)_

## §5.8 — WebSocket envelope

_(F0.4)_

## §5.9 — TURN credentials

_(F0.4)_

## §5.10 — Backup file format `.qabk`

_(F0.4)_

## §5.11 — Frozen wire types

_(F0.4)_

## Open discrepancies (require user / server-team decision)

### §1 — Username hash: iOS and Android not implemented (F0.2)

iOS and Android have no `@handle` registration or `username_hash` computation. Desktop and Server agree on `sha256(lower(handle) ‖ pepper)[:16]` (base64-encoded). The two mobile platforms must implement the same algorithm before handle-based discovery can function cross-platform. Tracking: Phase B.7.

### §2 — Contact-discovery v2 (peppered): iOS and Desktop use v1 only (F0.2)

Android implements `sha256(pepper ‖ e164)` via `DiscoverContactsUseCase.peppered()` and calls `POST /contacts/discover-v2`. iOS (`BCryptoContactsApiImpl`) and Desktop have no `/contacts/pepper` fetch and no v2 endpoint call — both fall back to legacy v1 `POST /contacts/discover` (unpeppered). This means iOS and Desktop contacts cannot be discovered by Android peers using the v2 flow until they register peppered hashes. Tracking: Phase B.7.

> Note: Android hashes `pepper ‖ e164` (pepper first); the server's `bbolt.go` comment also documents `SHA-256(pepper || e164)`. These are consistent. If iOS/Desktop implement v2, they MUST use this order.

### §3 — PSK fingerprint display format divergence (F0.2)

All platforms derive `sha256(psk_bytes)` for the fingerprint, but the display string differs:
- **Android**: `sha256(key)` → first 16 hex chars → `xxxx.xxxx.xxxx.xxxx` (dot-grouped, 19 chars displayed)
- **iOS**: full 64-char hex (no grouping)
- **Desktop**: first 28 chars of full 64-char hex + `"…"` (UI truncation, no grouping)

The spec calls for `xxxx.xxxx.xxxx.xxxx` from `sha256(pubkey)[:8]` (4 hex groups × 4 chars = 16 hex chars = 8 bytes). Android matches the spec format exactly. iOS and Desktop need to adopt the same `formatDisplayFingerprint` logic for cross-platform out-of-band verification to work. Wire-level PSK negotiation already uses full hex on all platforms; this is a display-only discrepancy.

### §4 — Device-link PSK: iOS and Desktop not implemented (F0.3)

Android's `DeviceLinkingProtocol.kt` derives the sync key via `HKDF-SHA256(X25519_shared, salt="qaudion-link-salt", info="qaudion-device-link-v1", 32B)`. iOS has no `DeviceLinkingProtocol` or these label constants anywhere in `QAudionEngine/Sources`. Desktop has no multi-device linking flow. Until iOS implements the same protocol with byte-identical labels, cross-platform device linking (Android ↔ iOS) cannot function. Tracking: Phase B.6.

### §5 — NFC collaborative PSK: Desktop not implemented (F0.3)

iOS (`CryptoConstants.hkdfNfcCollaborativePskInfo = "Q-Audion NFC Collaborative PSK v1"`) and Android (`NfcProtocol.kt:135`, same literal) agree exactly on the NFC PSK info string and salt construction (`sha256(sorted(pubA, pubB))`). Desktop has no NFC pairing code at all — this is expected given hardware constraints, but means NFC-paired PSKs established on mobile cannot be bootstrapped from a Desktop session.

### §6 — Recovery HKDF: spec description inaccurate; iOS and Desktop not implemented (F0.3)

The spec table lists salt=`"recovery-auth-v1"` / info=BIP-39 mnemonic. The actual Android implementation (`RecoveryCrypto.kt:70–71`) uses: `ikm=entropy`, `salt="bcrypto-recov-v1"`, `info="recovery-auth-v1"`, `length=32`. The spec's salt and info are transposed relative to the code — the server comment in `cmd/bcrypto-lite/main.go:1769` matches the Android code (not the spec table). The spec table needs to be corrected: actual values are `salt="bcrypto-recov-v1"`, `info="recovery-auth-v1"`. Separately, iOS and Desktop have no local HKDF derivation for recovery at all (iOS merely passes an opaque `recoverySecret` string up to the API — caller must derive it externally). Tracking: Phase B.8.
