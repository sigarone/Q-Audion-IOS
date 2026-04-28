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
| AEAD | AES-256-GCM, 12B nonce, 16B tag | _(F0.3)_ | _(F0.3)_ | _(F0.3)_ | _(F0.3)_ | _(F0.3)_ |
| Hash | SHA-256 everywhere | _(F0.3)_ | _(F0.3)_ | _(F0.3)_ | _(F0.3)_ | _(F0.3)_ |
| HKDF | HKDF-SHA256, 32B output | _(F0.3)_ | _(F0.3)_ | _(F0.3)_ | _(F0.3)_ | _(F0.3)_ |

## §5.3 — HKDF labels

| Purpose | Spec salt | Spec info | iOS source | Android source | Desktop source | Status |
|---|---|---|---|---|---|---|
| Message conversation key | per-pair | `"q-audion-msg-key"` | _(F0.3)_ | _(F0.3)_ | _(F0.3)_ | _(F0.3)_ |
| Device-link PSK | `"qaudion-link-salt"` | `"qaudion-device-link-v1"` | _(F0.3)_ | _(F0.3)_ | _(F0.3)_ | _(F0.3)_ |
| NFC collaborative PSK | `sha256(sorted(pubA, pubB))` | `"Q-Audion NFC Collaborative PSK v1"` | _(F0.3)_ | _(F0.3)_ | _(F0.3)_ | _(F0.3)_ |
| Hybrid PQC session key | `HYBRID_PQC_SALT_V1` | `HYBRID_PQC_INFO` | _(F0.3)_ | _(F0.3)_ | _(F0.3)_ | _(F0.3)_ |
| Recovery seed → secret | `"recovery-auth-v1"` | (BIP-39 mnemonic) | _(F0.3)_ | _(F0.3)_ | _(F0.3)_ | _(F0.3)_ |
| Frame chain (audio) | chainKey | `"FRAME_CHAIN_AUDIO"` | _(F0.3)_ | _(F0.3)_ | _(F0.3)_ | _(F0.3)_ |
| Frame chain (video) | chainKey | `"FRAME_CHAIN_VIDEO"` | _(F0.3)_ | _(F0.3)_ | _(F0.3)_ | _(F0.3)_ |
| Attachment | contactPSK | `"FILE_KEY"` | _(F0.3)_ | _(F0.3)_ | _(F0.3)_ | _(F0.3)_ |

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
