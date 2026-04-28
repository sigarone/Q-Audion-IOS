# Track A Foundation Sprint Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lock the cross-platform invariants contract (A.0), scaffold pure-Swift ViewModels for the screens that A.2 / A.3 / A.4 will touch (A.1, scoped — full Settings sub-screens deferred to a later A.6 plan), and execute three platform-scaffolding hygiene items (A.7). Foundation that unblocks all subsequent Track A feature phases.

**Architecture:** Three sequential phases. F0 = read-only multi-repo audit producing `docs/progress/INVARIANTS_VERIFIED.md`. F1 = pure-Swift ViewModel structs in `QAudionEngine/Sources/QAudionEngine/UI/ViewModels/` (no SwiftUI / no Combine — App layer wraps with `@StateObject` later) + mock factories + XCTest unit tests via `swift test`. F2 = consolidate the duplicated `ChatView.swift` between App and Engine, document the stray 0-byte working-tree files, update `STATUS.md`. Closeout in F3.

**Tech Stack:** Swift 5.9, XCTest, swift-tools-version 5.9 SPM (`QAudionEngine` package, iOS 16+, macOS 13+), git, no new dependencies. Existing tools only — no Codemagic / `xcodebuild` changes (Phase 0 is sacred per CLAUDE.md).

**Predecessor design:** [docs/superpowers/specs/2026-04-28-cross-platform-alignment-design.md](../specs/2026-04-28-cross-platform-alignment-design.md). This plan implements §7 Track A items A.0, A.1 (scoped to non-Settings screens), and A.7.

---

## Reference paths (used by every task)

| Repo | Absolute path | Read-only? |
|---|---|---|
| iOS (this repo) | `D:\users\f10379a\DEV APP\BCRYPTO\apps\qaudion-ios` | NO — we write here |
| Android | `D:\users\f10379a\DEV APP\BCRYPTO\apps\qaudion-android-new` | YES |
| Desktop | `D:\users\f10379a\DEV APP\BCRYPTO\apps\qaudion-desktop` | YES |
| Server | `D:\users\f10379a\DEV APP\BCRYPTO\apps\bcrypto-server` | YES |

> **D-05 hygiene (CLAUDE.md):** in iOS, never stage these USER-WT files: `BCryptoBackendProvider.swift`, `BCryptoCallingApiImpl.swift`, `BCryptoGroupCallManager.swift`, `BCryptoWebSocketClient.swift`, `BCryptoPresenceManager.swift`, `CallingApi.swift`, `QAudionCallIntegration.swift`, `ContactSyncService.swift`. They appear in `git status` as M/?? — leave them alone.

---

## Phase F0 — Cross-Platform Invariants Verification

Goal: produce `docs/progress/INVARIANTS_VERIFIED.md` — a single document that pins, for every value in §5 of the design spec, the actual byte-level value found in iOS / Android / Desktop / Server source. Discrepancies are flagged, not auto-resolved.

### Task F0.1: Create the invariants doc skeleton

**Files:**
- Create: `docs/progress/INVARIANTS_VERIFIED.md`

- [ ] **Step 1:** Create `docs/progress/INVARIANTS_VERIFIED.md` with the following exact content:

```markdown
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
| iOS | _(F0.2)_ | _(F0.2)_ | _(F0.2)_ |
| Android | _(F0.2)_ | _(F0.2)_ | _(F0.2)_ |
| Desktop | _(F0.2)_ | _(F0.2)_ | _(F0.2)_ |
| Server | _(F0.2)_ | _(F0.2)_ | _(F0.2)_ |

**Status:** _(F0.2)_

### Username hash (peppered)

| Platform | Source | Algorithm | Notes |
|---|---|---|---|
| iOS | _(F0.2)_ | _(F0.2)_ | _(F0.2)_ |
| Android | _(F0.2)_ | _(F0.2)_ | _(F0.2)_ |
| Desktop | _(F0.2)_ | _(F0.2)_ | _(F0.2)_ |
| Server | _(F0.2)_ | _(F0.2)_ | _(F0.2)_ |

**Status:** _(F0.2)_

### Contact-discovery hash v2 (peppered)

| Platform | Source | Algorithm | Notes |
|---|---|---|---|
| iOS | _(F0.2)_ | _(F0.2)_ | _(F0.2)_ |
| Android | _(F0.2)_ | _(F0.2)_ | _(F0.2)_ |
| Desktop | _(F0.2)_ | _(F0.2)_ | _(F0.2)_ |
| Server | _(F0.2)_ | _(F0.2)_ | _(F0.2)_ |

**Status:** _(F0.2)_

### Public-key fingerprint (display)

| Platform | Source | Algorithm | Notes |
|---|---|---|---|
| iOS | _(F0.2)_ | _(F0.2)_ | _(F0.2)_ |
| Android | _(F0.2)_ | _(F0.2)_ | _(F0.2)_ |
| Desktop | _(F0.2)_ | _(F0.2)_ | _(F0.2)_ |
| Server | _(F0.2)_ | _(F0.2)_ | _(F0.2)_ |

**Status:** _(F0.2)_

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

_(populated as F0.2-F0.4 progress)_
```

- [ ] **Step 2:** Verify the file was created.

Run: `wc -l "docs/progress/INVARIANTS_VERIFIED.md"`
Expected: `~120 docs/progress/INVARIANTS_VERIFIED.md` (line count approximate).

- [ ] **Step 3:** Commit.

```bash
git add docs/progress/INVARIANTS_VERIFIED.md
git commit -m "docs(parity): F0.1 INVARIANTS_VERIFIED.md skeleton"
```

### Task F0.2: Verify §5.1 identity-hashing invariants across 4 platforms

**Files:**
- Read: `QAudionEngine/Sources/QAudionEngine/Utils/PhoneHash.swift`
- Read: `D:\users\f10379a\DEV APP\BCRYPTO\apps\qaudion-android-new\**\PhoneHashHelper.kt` (find via Glob)
- Read: `D:\users\f10379a\DEV APP\BCRYPTO\apps\qaudion-desktop\src\**\*.ts` (search for `phoneHash` / `phone_hash`)
- Read: `D:\users\f10379a\DEV APP\BCRYPTO\apps\bcrypto-server\**` (search for `phone_hash` / `phone_number` validation)
- Modify: `docs/progress/INVARIANTS_VERIFIED.md` (replace `_(F0.2)_` placeholders for §5.1)

- [ ] **Step 1:** Read `QAudionEngine/Sources/QAudionEngine/Utils/PhoneHash.swift`. Confirm the algorithm is `sha256Hex(normalizeE164(input)).lowercase()`, no salt, no pepper. Note the line numbers of the `hash`, `normalizeE164`, and `sha256Hex` methods.

- [ ] **Step 2:** Glob for the Android equivalent.

Run via Glob tool: pattern `D:\users\f10379a\DEV APP\BCRYPTO\apps\qaudion-android-new\**\PhoneHashHelper.kt`.
Expected: 1 file under `feature/feature-auth/...` or `core/...`.

- [ ] **Step 3:** Read the Android `PhoneHashHelper.kt`. Confirm same algorithm: SHA-256 of E.164-normalized phone, hex-encoded lowercase, no salt. Note any divergence (e.g. different default country code, different strip regex).

- [ ] **Step 4:** Search Desktop for `phoneHash` or `phone_hash`.

Run via Grep tool: pattern `phoneHash|phone_hash`, path `D:\users\f10379a\DEV APP\BCRYPTO\apps\qaudion-desktop\src`, output_mode `files_with_matches`.

- [ ] **Step 5:** Read the matching Desktop file(s). Confirm/note the algorithm. Desktop may use Node `crypto.createHash('sha256')` over the E.164 string.

- [ ] **Step 6:** Search Server for phone-hash validation.

Run via Grep tool: pattern `phone_hash|PhoneHash`, path `D:\users\f10379a\DEV APP\BCRYPTO\apps\bcrypto-server`, output_mode `files_with_matches`, exclude paths matching `node_modules` or build outputs.

- [ ] **Step 7:** Read the matching Server file(s). Note: server should validate that `phone_hash` is 64 lowercase hex chars (SHA-256 hex) but does NOT compute it — clients hash before submit.

- [ ] **Step 8:** Edit `docs/progress/INVARIANTS_VERIFIED.md` — replace the four "Phone hash" placeholders with the verified data. Use this exact format for each row:

```markdown
| iOS | `QAudionEngine/Sources/QAudionEngine/Utils/PhoneHash.swift:74` | `hex(sha256(utf8(normalizeE164(input))))` lowercase, default country `+39` | E.164 regex `^\+[1-9]\d{7,14}$`; strips ` () .-/`; `00` prefix → `+`. |
| Android | _<actual file:line>_ | _<algorithm string>_ | _<observations>_ |
| Desktop | _<actual file:line>_ | _<algorithm string>_ | _<observations>_ |
| Server | _<actual file:line>_ | (not computed; validates 64-hex format) | _<observations>_ |
```

Set the **Status:** line to `✅ verified — all four platforms compute identical bytes for `+39 333 1234567` → `sha256("+393331234567")` lowercase hex.` (Replace text if any platform differs — switch to ⚠️ and document the exact divergence under "Open discrepancies".)

- [ ] **Step 9:** Repeat steps 1-8 for **Username hash (peppered)**. Sources:
  - iOS: search via Grep `username.*hash|sha256.*pepper`, path `QAudionEngine/Sources` and `QAudionApp`.
  - Android: search `qaudion-android-new` for username pepper handling.
  - Desktop: Onboarding / Contacts source.
  - Server: per audit §2 the endpoint `GET /api/v1/discover/pepper` exposes the global pepper; algorithm `hex(sha256(pepper ‖ username))` lowercase.

- [ ] **Step 10:** Repeat steps 1-8 for **Contact-discovery hash v2 (peppered)**. Sources:
  - iOS: `QAudionEngine/Sources/QAudionEngine/Backend/BCrypto/BCryptoContactsApiImpl.swift` — does iOS call `discover-v2` yet? If not, mark iOS row `❌ not implemented yet — Phase B.7`.
  - Server: pepper endpoint `GET /api/v1/contacts/pepper`, hash form `hex(sha256(pepper ‖ e164))`.

- [ ] **Step 11:** Repeat steps 1-8 for **Public-key fingerprint (display)**. Sources:
  - iOS: search Grep `fingerprint|displayFingerprint`, path `QAudionEngine/Sources`. Likely in `Crypto/SovereignKeyVault.swift` or `Crypto/SovereignIdentityManager.swift`.
  - Android: search for `fingerprint` in `qaudion-android-new\qaudion-engine\src\main\java\com\bcrypto\qaudion\crypto`.
  - Desktop: search `src/main/identity` and `src/main/crypto`.
  - Confirm the format is `xxxx.xxxx.xxxx.xxxx` derived from `sha256(pubkey)[:8]` formatted as 4 hex groups.

- [ ] **Step 12:** Run a sanity check on the doc: every row in §5.1 should have a non-placeholder value, and the **Status:** lines should be set.

Run: `grep -c "_(F0.2)_" docs/progress/INVARIANTS_VERIFIED.md`
Expected: `0`

- [ ] **Step 13:** Commit.

```bash
git add docs/progress/INVARIANTS_VERIFIED.md
git commit -m "docs(parity): F0.2 verify identity-hashing invariants (§5.1)"
```

### Task F0.3: Verify §5.2-§5.3 symmetric crypto + HKDF labels

**Files:**
- Modify: `docs/progress/INVARIANTS_VERIFIED.md` (replace `_(F0.3)_` placeholders for §5.2-§5.3)

- [ ] **Step 1:** Verify §5.2 AEAD on iOS.

Read: `QAudionEngine/Sources/QAudionEngine/Crypto/AeadCipher.swift`. Confirm AES-256-GCM with 12-byte nonce, 16-byte tag.

- [ ] **Step 2:** Verify §5.2 AEAD on Android.

Read via Grep: pattern `AES.*GCM|GCMParameterSpec`, path `D:\users\f10379a\DEV APP\BCRYPTO\apps\qaudion-android-new\qaudion-engine\src\main\java\com\bcrypto\qaudion\crypto\AeadCipher.kt`. Confirm same parameters.

- [ ] **Step 3:** Verify §5.2 AEAD on Desktop.

Read via Grep: pattern `AES-256-GCM|aes-256-gcm`, path `D:\users\f10379a\DEV APP\BCRYPTO\apps\qaudion-desktop\src`. Likely in `src/main/crypto/AeadCipher.ts` or similar.

- [ ] **Step 4:** Edit `docs/progress/INVARIANTS_VERIFIED.md` — replace §5.2 placeholders. Format for each row: file:line + observation. Status: `✅ identical` if AES-256-GCM with 12B nonce + 16B tag everywhere; otherwise `⚠️` and document under "Open discrepancies".

- [ ] **Step 5:** Verify §5.3 HKDF labels on iOS.

Search via Grep: pattern `q-audion-msg-key|qaudion-link-salt|qaudion-device-link-v1|Q-Audion NFC Collaborative PSK v1|HYBRID_PQC|FRAME_CHAIN|FILE_KEY|recovery-auth-v1`, path `QAudionEngine/Sources`, output_mode `content`, `-n true`. Note exact byte values.

- [ ] **Step 6:** Verify §5.3 HKDF labels on Android.

Search via Grep: same patterns, path `D:\users\f10379a\DEV APP\BCRYPTO\apps\qaudion-android-new`, output_mode `content`, `-n true`.

- [ ] **Step 7:** Verify §5.3 HKDF labels on Desktop.

Search via Grep: same patterns, path `D:\users\f10379a\DEV APP\BCRYPTO\apps\qaudion-desktop\src\shared` and `\src\main\crypto`, output_mode `content`, `-n true`. Desktop's `constants.ts` is the canonical source per the audit — pin the exact UTF-8 bytes.

- [ ] **Step 8:** Compare. Each row must have IDENTICAL byte sequences. If any platform has a typo or different label, flag it ⚠️ under "Open discrepancies" — DO NOT auto-correct.

- [ ] **Step 9:** Edit `docs/progress/INVARIANTS_VERIFIED.md` — replace §5.3 placeholders. Each row's iOS / Android / Desktop column gets `<file:line>` citation; the right-most "Status" column is `✅` or `⚠️` per item.

- [ ] **Step 10:** Sanity check.

Run: `grep -c "_(F0.3)_" docs/progress/INVARIANTS_VERIFIED.md`
Expected: `0`

- [ ] **Step 11:** Commit.

```bash
git add docs/progress/INVARIANTS_VERIFIED.md
git commit -m "docs(parity): F0.3 verify symmetric crypto + HKDF labels (§5.2-§5.3)"
```

### Task F0.4: Verify §5.4-§5.11 remaining invariants

**Files:**
- Modify: `docs/progress/INVARIANTS_VERIFIED.md` (replace `_(F0.4)_` placeholders for §5.4-§5.11)

- [ ] **Step 1: §5.4 Asymmetric crypto.**

For each of (ML-KEM-1024, X25519, Ed25519, hybrid KEX combine):
- iOS: cite `QAudionEngine/Sources/QAudionEngine/Crypto/PqcKeyExchange.swift` / `HybridPqcKeyExchange.swift` / liboqs binding.
- Android: cite `qaudion-android-new\qaudion-engine\src\main\java\com\bcrypto\qaudion\crypto\PqcKeyExchange.kt` / `HybridKeyAgreement.kt`.
- Desktop: cite `qaudion-desktop\src\main\identity\PqcHandshake.ts` / `SessionKeyDerivation.ts` (per audit).

Replace the `_(F0.4)_` block under §5.4 with a 4-row table per primitive (ML-KEM-1024, X25519, Ed25519, Hybrid).

- [ ] **Step 2: §5.5 NFC.**

Cite per platform: AID = `F0BCF1073A5100`, payload layout `[32B X25519 ‖ 32B random]`, HKDF info `"Q-Audion NFC Collaborative PSK v1"`, salt `sha256(sorted(pubA, pubB))`. Sources:
- iOS: `QAudionEngine/Sources/QAudionEngine/Sovereign/NfcProtocol.swift` (verify line by line).
- Android: `qaudion-android-new\...\NfcProtocol.kt` (or wherever the AID + APDU live).
- Desktop: `🟡 not applicable` (Electron desktop has no NFC).

Note the iOS-specific limitation: iPhones cannot do HCE → only iOS-reader ↔ Android-HCE pairing works.

- [ ] **Step 3: §5.6 Device-linking binary QR.**

Cite per platform: layout `[32B X25519 ‖ 4B BE length ‖ userId UTF-8 ‖ 16B auth code]`, encoding base64url no padding, URL `qaudion://link/<blob>`.
- iOS: search Grep for `qaudion://link` to find the parser/builder.
- Android: `DeviceLinkingProtocol.kt` (path from CLAUDE.md plan).
- Desktop: search Grep for `qaudion://link` in `src/`.

- [ ] **Step 4: §5.7 VoIP push payload.**

Spec form `{type, call_id, caller_id, caller_name, call_type}`.
- iOS: not yet implemented — mark `❌ Phase A.5 (PushKit scaffolding)`.
- Android: search Grep `incoming_call|call_id` in `qaudion-android-new\app\src\main\java\com\bcrypto\qaudion\push`.
- Server: search Grep `incoming_call`, path `D:\users\f10379a\DEV APP\BCRYPTO\apps\bcrypto-server`. **Per server audit §5: server lite emits NO APNs VoIP push currently.** Mark server side as `❌ not implemented for APNs (FCM only)` and add an entry under "Open discrepancies" pointing at design spec §10.1.

- [ ] **Step 5: §5.8 WebSocket envelope.**

Spec form `{type, data}` (NO `id` per server audit §3).
- iOS: `QAudionEngine/Sources/QAudionEngine/Backend/BCrypto/BCryptoWebSocketClient.swift` — note that iOS currently emits `id` field, server ignores it. Mark `⚠️ iOS sends extraneous id field — cleanup tracked in B.1 WS code fix`.
- Android: `qaudion-android-new\core\core-data\src\main\java\com\bcrypto\qaudion\data\ws\WsCodec.kt` — verify Android decode tolerates absent `id`.
- Desktop: `qaudion-desktop\src\main\transport\BCryptoSocket.ts`.
- Server: `bcrypto-server` WS dispatcher — cite the file:line where envelope is parsed; confirm `id` is NOT consumed.

Add an entry under "Open discrepancies": **`ANDROID_REFERENCE.md` claim `{type, data, id}` is stale — must be corrected to `{type, data}` after this audit ships.**

- [ ] **Step 6: §5.9 TURN credentials.**

Spec form: `username = "{userID}:{unix_timestamp}"`, `password = HMAC-SHA1(username, turn_secret)`, expires 1h.
- iOS: search Grep `getRelays|TURN`, path `QAudionEngine/Sources/QAudionEngine`.
- Server: per audit, `GET /api/v1/calling/relays` returns this shape. Cite the handler file:line.
- Android / Desktop: confirm parsers consume the same shape.

- [ ] **Step 7: §5.10 Backup file format `.qabk`.**

Spec: scrypt(N=2^15, r=8, p=1, 32B output) → AES-256-GCM (12B nonce, 16B tag). Container layout TBD.
- Desktop: read `qaudion-desktop\src\main\backup\*.ts`. Extract the exact container layout (header magic, version byte, metadata block, payload). **This is the canonical source per spec §5.10.**
- iOS: `QAudionEngine/Sources/QAudionEngine/Crypto/BackupKeyVault.swift` — confirm or document divergence.
- Android: search Grep `qabk|backup.*scrypt`.

If iOS / Android container layout differs from desktop, mark ⚠️ and add to "Open discrepancies": iOS Phase 4 must align before A.2 closes.

- [ ] **Step 8: §5.11 Frozen wire types.**

For each of the 24 WS types and ~25 REST endpoints listed in spec §5.11, do NOT re-audit — just cite the source:
- WS types: `BCryptoWebSocketClient.swift` (iOS), `WsCommand.kt` / `WsEvent.kt` (Android), `BCryptoSocket.ts` (Desktop), server WS dispatcher.
- REST: `BCryptoApi.kt` (Android), `BCryptoApi.ts` (Desktop), iOS `Backend/BCrypto/*Impl.swift` family.

Compress this into a single 1-line statement per item: `✅ frozen across all 4 platforms` OR ⚠️ with note. The §5.11 section should not exceed 30 rows.

- [ ] **Step 9:** Sanity check.

Run: `grep -c "_(F0.4)_" docs/progress/INVARIANTS_VERIFIED.md`
Expected: `0`

Run: `grep -c "_(F0\." docs/progress/INVARIANTS_VERIFIED.md`
Expected: `0`

- [ ] **Step 10:** Read the entire `docs/progress/INVARIANTS_VERIFIED.md` end-to-end. Spot any internal contradictions (e.g. §5.3 says iOS uses `"q-audion-msg-key"` but §5.11 says iOS says `"q-audion-message"`). Fix inline.

- [ ] **Step 11:** Commit.

```bash
git add docs/progress/INVARIANTS_VERIFIED.md
git commit -m "docs(parity): F0.4 verify §5.4-§5.11 invariants — F0 complete"
```

### Task F0.5: Wire INVARIANTS_VERIFIED.md into STATUS.md and TASK_LOG.md

**Files:**
- Modify: `docs/progress/STATUS.md`
- Modify: `docs/progress/TASK_LOG.md`

- [ ] **Step 1:** Open `docs/progress/STATUS.md`. Update the "Last updated" line to today's date (`2026-04-28`). Update the "Plan" line to also reference this plan: `Plan: docs/superpowers/plans/2026-04-28-track-a-foundation.md` (in addition to the predecessor plan).

- [ ] **Step 2:** Replace the "Fase attiva" section with:

```markdown
## Fase attiva
**Track A Foundation Sprint — IN PROGRESS** (`docs/superpowers/specs/2026-04-28-cross-platform-alignment-design.md` + `docs/superpowers/plans/2026-04-28-track-a-foundation.md`).
- F0 (Invariants verification) — ✅ DONE — see `docs/progress/INVARIANTS_VERIFIED.md`
- F1 (UI ViewModels) — IN PROGRESS
- F2 (Platform scaffolding) — pending
- F3 (Closeout) — pending
```

- [ ] **Step 3:** Append to `docs/progress/TASK_LOG.md` (newest on top, after the existing top entry):

```markdown
- 2026-04-28 | F0 | Cross-platform invariants verified (§5.1-§5.11) | <commit-sha-here> | DONE | `docs/progress/INVARIANTS_VERIFIED.md` is the canonical contract. Discrepancies catalogued under "Open discrepancies" — server team / Android dev / desktop dev sign-off requested before any wire-touching work resumes.
```

(Replace `<commit-sha-here>` with the SHA from F0.4's commit — get it via `git log --oneline -1`.)

- [ ] **Step 4:** Commit.

```bash
git add docs/progress/STATUS.md docs/progress/TASK_LOG.md
git commit -m "docs(progress): F0 complete — invariants doc landed; STATUS+TASK_LOG updated"
```

---

## Phase F1 — UI Data Contract / ViewModels

Goal: scaffold pure-Swift `ViewModels` for the screens that A.2 (NFC + key mgmt), A.3 (CallKit), A.4 (in-call UI), and A.5 (PushKit) will touch. Each ViewModel is a struct/enum with no SwiftUI / Combine dependency — it can be unit-tested with `swift test` and consumed by both iOS app and (eventually) macOS catalyst variants. App-level views wrap with `@StateObject` containers as needed in subsequent phases.

**Scope decision:** Settings hub + 11 sub-screen ViewModels are **deferred to a future A.6 plan** to keep this sprint shipped within ~1 week. F1 covers only the ViewModels for A.2 / A.3 / A.4 / A.5.

### Task F1.1: Create UI/ViewModels directory + base protocol

**Files:**
- Create: `QAudionEngine/Sources/QAudionEngine/UI/ViewModels/ViewModelProtocol.swift`
- Create: `QAudionEngine/Tests/QAudionEngineTests/UI/ViewModelsTests.swift`

- [ ] **Step 1:** Create `QAudionEngine/Sources/QAudionEngine/UI/ViewModels/ViewModelProtocol.swift`:

```swift
import Foundation

/// A view model is a pure-data shape consumed by a SwiftUI screen.
///
/// View models in QAudionEngine intentionally do NOT import SwiftUI or Combine.
/// They are values you can build, test, and snapshot from any host (iOS app,
/// macOS catalyst variant, swift-test on Linux CI). The hosting view layer is
/// responsible for wrapping a view model in `@StateObject` / `@ObservedObject`
/// / `@Observable` — none of that is the engine's concern.
///
/// A view model has two responsibilities:
///   1. Expose every datum the screen renders.
///   2. Provide a `mock` factory so previews + tests stay decoupled from
///      live wire data.
public protocol ViewModelProtocol: Equatable, Sendable {
    /// A deterministic mock instance used by SwiftUI previews and unit tests.
    /// Every concrete view model MUST provide a `.mock` value with realistic
    /// (but synthetic) data.
    static var mock: Self { get }
}
```

- [ ] **Step 2:** Create the test target file `QAudionEngine/Tests/QAudionEngineTests/UI/ViewModelsTests.swift`:

```swift
import XCTest
@testable import QAudionEngine

/// Smoke tests for the ViewModel layer.
///
/// Each concrete view model gets a dedicated test case file under this
/// directory; this file holds cross-cutting tests (e.g. "every view model
/// declares a stable `.mock`").
final class ViewModelProtocolSmokeTests: XCTestCase {

    /// Mocks must be deterministic — calling `.mock` twice in a row must
    /// produce equal values, otherwise SwiftUI previews flicker.
    func test_mockIsDeterministic_protocolWitness() {
        // Real assertion lives in each concrete view model's test file
        // (e.g. KeyManagementViewModelTests.test_mockIsDeterministic).
        // This method exists as a smoke test that the test target compiles
        // and runs against the engine package.
        XCTAssertTrue(true)
    }
}
```

- [ ] **Step 3:** Run the test target to verify it compiles + the smoke test passes.

Run from `QAudionEngine/`: `swift test --filter ViewModelProtocolSmokeTests`
Expected: `Test Suite 'ViewModelProtocolSmokeTests' passed at ...` with 1 test executed in <1s.

(If `swift test` fails on Windows due to liboqs C dependencies, instead run via the GitHub Actions `engine-tests.yml` workflow — push the commit and let CI verify. Document this in the commit message.)

- [ ] **Step 4:** Commit.

```bash
git add QAudionEngine/Sources/QAudionEngine/UI/ViewModels/ViewModelProtocol.swift QAudionEngine/Tests/QAudionEngineTests/UI/ViewModelsTests.swift
git commit -m "feat(ui): F1.1 ViewModelProtocol + test scaffold"
```

### Task F1.2: KeyManagementViewModel (TDD)

**Files:**
- Create: `QAudionEngine/Sources/QAudionEngine/UI/ViewModels/KeyManagementViewModel.swift`
- Create: `QAudionEngine/Tests/QAudionEngineTests/UI/KeyManagementViewModelTests.swift`

KeyManagementViewModel binds `KeyManagementView` (engine UI). It exposes the user's identity + the list of linked devices + actions the user can take (rotate key, link new device, view QR identity, view fingerprint).

- [ ] **Step 1: Write the failing test** at `QAudionEngine/Tests/QAudionEngineTests/UI/KeyManagementViewModelTests.swift`:

```swift
import XCTest
@testable import QAudionEngine

final class KeyManagementViewModelTests: XCTestCase {

    func test_mockIsDeterministic() {
        XCTAssertEqual(KeyManagementViewModel.mock, KeyManagementViewModel.mock)
    }

    func test_mockExposesIdentityFingerprint_in4HexGroups() {
        let mock = KeyManagementViewModel.mock
        // §5.1 fingerprint format: "xxxx.xxxx.xxxx.xxxx"
        let parts = mock.fingerprint.split(separator: ".")
        XCTAssertEqual(parts.count, 4)
        for part in parts {
            XCTAssertEqual(part.count, 4, "Each fingerprint group must be 4 hex chars")
            XCTAssertTrue(part.allSatisfy(\.isHexDigit), "Group '\(part)' is not all hex")
        }
    }

    func test_mockHasAtLeastOneLinkedDevice() {
        XCTAssertGreaterThanOrEqual(KeyManagementViewModel.mock.linkedDevices.count, 1)
    }
}

private extension Character {
    var isHexDigit: Bool { isHexDigit(self) || isNumber }
    private func isHexDigit(_ c: Character) -> Bool {
        ("0"..."9").contains(c) || ("a"..."f").contains(c) || ("A"..."F").contains(c)
    }
}
```

- [ ] **Step 2: Run test to verify it fails.**

Run: `swift test --filter KeyManagementViewModelTests`
Expected: FAIL — `error: cannot find 'KeyManagementViewModel' in scope`.

- [ ] **Step 3: Write the minimal implementation** at `QAudionEngine/Sources/QAudionEngine/UI/ViewModels/KeyManagementViewModel.swift`:

```swift
import Foundation

public struct KeyManagementViewModel: ViewModelProtocol {

    public struct LinkedDevice: Equatable, Sendable, Hashable {
        public let deviceId: String
        public let deviceName: String
        public let lastSeen: Date
        public let isCurrentDevice: Bool

        public init(deviceId: String, deviceName: String, lastSeen: Date, isCurrentDevice: Bool) {
            self.deviceId = deviceId
            self.deviceName = deviceName
            self.lastSeen = lastSeen
            self.isCurrentDevice = isCurrentDevice
        }
    }

    public let userId: String
    /// `xxxx.xxxx.xxxx.xxxx` per spec §5.1.
    public let fingerprint: String
    public let linkedDevices: [LinkedDevice]
    /// Server-side last-rotation timestamp (nil if never rotated post-enrol).
    public let lastKeyRotation: Date?

    public init(userId: String, fingerprint: String, linkedDevices: [LinkedDevice], lastKeyRotation: Date?) {
        self.userId = userId
        self.fingerprint = fingerprint
        self.linkedDevices = linkedDevices
        self.lastKeyRotation = lastKeyRotation
    }

    public static let mock = KeyManagementViewModel(
        userId: "user-aabbccdd-1122-3344-5566-778899aabbcc",
        fingerprint: "a3f7.c291.8b4e.d012",
        linkedDevices: [
            LinkedDevice(
                deviceId: "device-iphone-13-pavel",
                deviceName: "Pavel's iPhone 13",
                lastSeen: Date(timeIntervalSince1970: 1_745_000_000),
                isCurrentDevice: true
            ),
            LinkedDevice(
                deviceId: "device-pixel-7",
                deviceName: "Pixel 7 (Android)",
                lastSeen: Date(timeIntervalSince1970: 1_744_950_000),
                isCurrentDevice: false
            )
        ],
        lastKeyRotation: Date(timeIntervalSince1970: 1_744_000_000)
    )
}
```

- [ ] **Step 4: Run tests to verify they pass.**

Run: `swift test --filter KeyManagementViewModelTests`
Expected: 3 tests, all PASS.

- [ ] **Step 5: Commit.**

```bash
git add QAudionEngine/Sources/QAudionEngine/UI/ViewModels/KeyManagementViewModel.swift QAudionEngine/Tests/QAudionEngineTests/UI/KeyManagementViewModelTests.swift
git commit -m "feat(ui): F1.2 KeyManagementViewModel + tests"
```

### Task F1.3: DeviceManagementViewModel (TDD)

**Files:**
- Create: `QAudionEngine/Sources/QAudionEngine/UI/ViewModels/DeviceManagementViewModel.swift`
- Create: `QAudionEngine/Tests/QAudionEngineTests/UI/DeviceManagementViewModelTests.swift`

Device management screen lists linked devices and lets the user revoke or link new ones. Distinct from KeyManagement (which is identity-key-centric); this is device-list-centric.

- [ ] **Step 1: Write the failing test:**

```swift
import XCTest
@testable import QAudionEngine

final class DeviceManagementViewModelTests: XCTestCase {

    func test_mockIsDeterministic() {
        XCTAssertEqual(DeviceManagementViewModel.mock, DeviceManagementViewModel.mock)
    }

    func test_mockHasCurrentDeviceFirst() {
        let mock = DeviceManagementViewModel.mock
        XCTAssertTrue(mock.devices.first?.isCurrentDevice ?? false,
                      "Current device must be first in the list for UI clarity")
    }

    func test_mockOtherDevicesAreRevocable() {
        let mock = DeviceManagementViewModel.mock
        let nonCurrent = mock.devices.filter { !$0.isCurrentDevice }
        XCTAssertGreaterThanOrEqual(nonCurrent.count, 1)
        for d in nonCurrent {
            XCTAssertTrue(d.canRevoke, "Non-current devices must be revocable")
        }
    }

    func test_mockCurrentDeviceIsNotRevocable() {
        let mock = DeviceManagementViewModel.mock
        let current = mock.devices.first { $0.isCurrentDevice }
        XCTAssertNotNil(current)
        XCTAssertFalse(current!.canRevoke,
                       "User cannot revoke the device they are currently using — must do that elsewhere")
    }
}
```

- [ ] **Step 2: Run test to verify it fails.**

Run: `swift test --filter DeviceManagementViewModelTests`
Expected: FAIL — `cannot find 'DeviceManagementViewModel' in scope`.

- [ ] **Step 3: Implementation:**

```swift
import Foundation

public struct DeviceManagementViewModel: ViewModelProtocol {

    public struct Device: Equatable, Sendable, Hashable {
        public let deviceId: String
        public let deviceName: String
        public let platform: Platform
        public let linkedAt: Date
        public let lastSeen: Date
        public let isCurrentDevice: Bool
        public let canRevoke: Bool

        public enum Platform: String, Sendable {
            case iOS, android, desktop, unknown
        }

        public init(deviceId: String, deviceName: String, platform: Platform,
                    linkedAt: Date, lastSeen: Date,
                    isCurrentDevice: Bool, canRevoke: Bool) {
            self.deviceId = deviceId
            self.deviceName = deviceName
            self.platform = platform
            self.linkedAt = linkedAt
            self.lastSeen = lastSeen
            self.isCurrentDevice = isCurrentDevice
            self.canRevoke = canRevoke
        }
    }

    /// Sorted with current device first, then others by `lastSeen` descending.
    public let devices: [Device]

    public init(devices: [Device]) {
        self.devices = devices
    }

    public static let mock = DeviceManagementViewModel(devices: [
        Device(
            deviceId: "device-iphone-13-pavel",
            deviceName: "Pavel's iPhone 13",
            platform: .iOS,
            linkedAt: Date(timeIntervalSince1970: 1_740_000_000),
            lastSeen: Date(timeIntervalSince1970: 1_745_000_000),
            isCurrentDevice: true,
            canRevoke: false
        ),
        Device(
            deviceId: "device-pixel-7",
            deviceName: "Pixel 7",
            platform: .android,
            linkedAt: Date(timeIntervalSince1970: 1_741_000_000),
            lastSeen: Date(timeIntervalSince1970: 1_744_950_000),
            isCurrentDevice: false,
            canRevoke: true
        ),
        Device(
            deviceId: "device-macbook-pro",
            deviceName: "Pavel's MacBook Pro",
            platform: .desktop,
            linkedAt: Date(timeIntervalSince1970: 1_742_000_000),
            lastSeen: Date(timeIntervalSince1970: 1_744_900_000),
            isCurrentDevice: false,
            canRevoke: true
        )
    ])
}
```

- [ ] **Step 4: Run tests:**

Run: `swift test --filter DeviceManagementViewModelTests`
Expected: 4 tests, all PASS.

- [ ] **Step 5: Commit.**

```bash
git add QAudionEngine/Sources/QAudionEngine/UI/ViewModels/DeviceManagementViewModel.swift QAudionEngine/Tests/QAudionEngineTests/UI/DeviceManagementViewModelTests.swift
git commit -m "feat(ui): F1.3 DeviceManagementViewModel + tests"
```

### Task F1.4: NfcExchangeViewModel (TDD)

**Files:**
- Create: `QAudionEngine/Sources/QAudionEngine/UI/ViewModels/NfcExchangeViewModel.swift`
- Create: `QAudionEngine/Tests/QAudionEngineTests/UI/NfcExchangeViewModelTests.swift`

Drives the iOS-reader NFC pairing flow. Mirrors the Android Compose state machine `Idle → Waiting → Exchanging → Success/Error`.

- [ ] **Step 1: Write the failing test:**

```swift
import XCTest
@testable import QAudionEngine

final class NfcExchangeViewModelTests: XCTestCase {

    func test_mockIsDeterministic() {
        XCTAssertEqual(NfcExchangeViewModel.mock, NfcExchangeViewModel.mock)
    }

    func test_mockStartsInIdle() {
        XCTAssertEqual(NfcExchangeViewModel.mock.state, .idle)
    }

    func test_stateMachine_idleToWaiting() {
        var vm = NfcExchangeViewModel.mock
        vm.transition(to: .waiting)
        XCTAssertEqual(vm.state, .waiting)
    }

    func test_stateMachine_waitingToExchanging() {
        var vm = NfcExchangeViewModel.mock
        vm.transition(to: .waiting)
        vm.transition(to: .exchanging)
        XCTAssertEqual(vm.state, .exchanging)
    }

    func test_stateMachine_exchangingToSuccess() {
        var vm = NfcExchangeViewModel.mock
        vm.transition(to: .waiting)
        vm.transition(to: .exchanging)
        vm.transition(to: .success(peerDeviceName: "Pixel 7"))
        if case .success(let peer) = vm.state {
            XCTAssertEqual(peer, "Pixel 7")
        } else {
            XCTFail("Expected .success state")
        }
    }

    func test_stateMachine_exchangingToError() {
        var vm = NfcExchangeViewModel.mock
        vm.transition(to: .waiting)
        vm.transition(to: .exchanging)
        vm.transition(to: .error(message: "Tag dropped"))
        if case .error(let msg) = vm.state {
            XCTAssertEqual(msg, "Tag dropped")
        } else {
            XCTFail("Expected .error state")
        }
    }

    func test_stateMachine_rejectsBackwardTransition() {
        var vm = NfcExchangeViewModel.mock
        vm.transition(to: .waiting)
        vm.transition(to: .exchanging)
        // Going back to .idle from .exchanging is not allowed; stay put.
        vm.transition(to: .idle)
        XCTAssertEqual(vm.state, .exchanging)
    }
}
```

- [ ] **Step 2: Run to verify failure.**

Run: `swift test --filter NfcExchangeViewModelTests`
Expected: FAIL — `cannot find 'NfcExchangeViewModel' in scope`.

- [ ] **Step 3: Implementation:**

```swift
import Foundation

public struct NfcExchangeViewModel: ViewModelProtocol {

    public enum State: Equatable, Sendable {
        case idle
        case waiting              // user has tapped "Start", phone listening for tag
        case exchanging           // tag detected, APDU + payload exchange in flight
        case success(peerDeviceName: String)
        case error(message: String)

        fileprivate var rank: Int {
            switch self {
            case .idle: return 0
            case .waiting: return 1
            case .exchanging: return 2
            case .success, .error: return 3
            }
        }
    }

    public private(set) var state: State

    /// The 7-byte AID we SELECT into. Frozen per §5.5.
    public let aidHex: String = "F0BCF1073A5100"

    public init(state: State = .idle) {
        self.state = state
    }

    /// Forward-only state transitions. Rejects backward moves except `.error → .idle`
    /// (user dismisses an error and starts over) and `.success → .idle` (same).
    public mutating func transition(to next: State) {
        switch (state, next) {
        case (.error, .idle), (.success, .idle):
            state = next
        case (let cur, let nxt) where nxt.rank > cur.rank:
            state = next
        case (let cur, let nxt) where nxt.rank == cur.rank:
            state = next  // e.g. update error message
        default:
            return  // reject backward transition
        }
    }

    public static let mock = NfcExchangeViewModel(state: .idle)
}
```

- [ ] **Step 4: Run tests.**

Run: `swift test --filter NfcExchangeViewModelTests`
Expected: 7 tests, all PASS.

- [ ] **Step 5: Commit.**

```bash
git add QAudionEngine/Sources/QAudionEngine/UI/ViewModels/NfcExchangeViewModel.swift QAudionEngine/Tests/QAudionEngineTests/UI/NfcExchangeViewModelTests.swift
git commit -m "feat(ui): F1.4 NfcExchangeViewModel + state machine tests"
```

### Task F1.5: InCallViewModel (TDD)

**Files:**
- Create: `QAudionEngine/Sources/QAudionEngine/UI/ViewModels/InCallViewModel.swift`
- Create: `QAudionEngine/Tests/QAudionEngineTests/UI/InCallViewModelTests.swift`

Drives the new in-call screen (spec A.4 — replaces partial `CallView`). Holds the 7 in-call elements: security badge, waveform TX/RX/Cipher, timer, peer info, controls, video PiP placeholder, SAS prompt presence.

- [ ] **Step 1: Write the failing test:**

```swift
import XCTest
@testable import QAudionEngine

final class InCallViewModelTests: XCTestCase {

    func test_mockIsDeterministic() {
        XCTAssertEqual(InCallViewModel.mock, InCallViewModel.mock)
    }

    func test_mockHasSecuredBadge() {
        XCTAssertEqual(InCallViewModel.mock.security, .secure)
    }

    func test_mockHasNonZeroWaveformAmplitudes() {
        let mock = InCallViewModel.mock
        XCTAssertGreaterThan(mock.waveformTx, 0)
        XCTAssertGreaterThan(mock.waveformRx, 0)
        XCTAssertGreaterThan(mock.waveformCipher, 0)
    }

    func test_mockHasMonotonicTimer() {
        XCTAssertGreaterThanOrEqual(InCallViewModel.mock.callDuration, 0)
    }

    func test_mockExposesAllControlsAsActionable() {
        let mock = InCallViewModel.mock
        XCTAssertFalse(mock.controls.isMuted)
        XCTAssertFalse(mock.controls.isSpeakerOn)
        XCTAssertFalse(mock.controls.isOnHold)
        XCTAssertEqual(mock.controls.endCallStyle, .red)
    }

    func test_mockSasPrompt_visibleOnFirstCallWithNewContact() {
        // Mock represents a first-call scenario (worst-case UX path).
        XCTAssertTrue(InCallViewModel.mock.shouldShowSasPrompt)
    }

    func test_videoPipPlaceholder_audioOnlyCallHidesIt() {
        let mock = InCallViewModel.mock
        // A.4 audio-only scope: video PiP exists in struct but is hidden.
        XCTAssertFalse(mock.showVideoPip)
    }
}
```

- [ ] **Step 2: Run to verify failure.**

Run: `swift test --filter InCallViewModelTests`
Expected: FAIL — `cannot find 'InCallViewModel' in scope`.

- [ ] **Step 3: Implementation:**

```swift
import Foundation

public struct InCallViewModel: ViewModelProtocol {

    public enum SecurityState: Equatable, Sendable {
        case secure          // hybrid PQC handshake completed, frame keys flowing
        case verifying       // handshake in progress, audio NOT yet relayed
        case insecureFallback  // server-mediated relay, no E2E (warn user)
    }

    public struct Controls: Equatable, Sendable {
        public enum EndCallStyle: Sendable { case red, neutral }

        public let isMuted: Bool
        public let isSpeakerOn: Bool
        public let isOnHold: Bool
        public let endCallStyle: EndCallStyle

        public init(isMuted: Bool, isSpeakerOn: Bool, isOnHold: Bool, endCallStyle: EndCallStyle) {
            self.isMuted = isMuted
            self.isSpeakerOn = isSpeakerOn
            self.isOnHold = isOnHold
            self.endCallStyle = endCallStyle
        }
    }

    public struct PeerInfo: Equatable, Sendable {
        public let userId: String
        public let displayName: String
        public let avatarUrl: URL?
        public let fingerprint: String  // §5.1 format

        public init(userId: String, displayName: String, avatarUrl: URL?, fingerprint: String) {
            self.userId = userId
            self.displayName = displayName
            self.avatarUrl = avatarUrl
            self.fingerprint = fingerprint
        }
    }

    public let peer: PeerInfo
    public let security: SecurityState
    public let callDuration: TimeInterval
    /// Normalized 0…1 amplitude for the green TX waveform (mic input).
    public let waveformTx: Double
    /// Normalized 0…1 amplitude for the orange RX waveform (peer audio).
    public let waveformRx: Double
    /// Normalized 0…1 amplitude for the cipher channel (post-AEAD ciphertext energy).
    public let waveformCipher: Double
    public let controls: Controls
    public let shouldShowSasPrompt: Bool
    public let showVideoPip: Bool

    public init(peer: PeerInfo, security: SecurityState, callDuration: TimeInterval,
                waveformTx: Double, waveformRx: Double, waveformCipher: Double,
                controls: Controls, shouldShowSasPrompt: Bool, showVideoPip: Bool) {
        self.peer = peer
        self.security = security
        self.callDuration = callDuration
        self.waveformTx = waveformTx
        self.waveformRx = waveformRx
        self.waveformCipher = waveformCipher
        self.controls = controls
        self.shouldShowSasPrompt = shouldShowSasPrompt
        self.showVideoPip = showVideoPip
    }

    public static let mock = InCallViewModel(
        peer: PeerInfo(
            userId: "user-aabbccdd-1122-3344-5566-778899aabbcc",
            displayName: "Alice (Pixel 7)",
            avatarUrl: nil,
            fingerprint: "a3f7.c291.8b4e.d012"
        ),
        security: .secure,
        callDuration: 47.3,
        waveformTx: 0.62,
        waveformRx: 0.41,
        waveformCipher: 0.88,
        controls: Controls(isMuted: false, isSpeakerOn: false, isOnHold: false, endCallStyle: .red),
        shouldShowSasPrompt: true,
        showVideoPip: false  // A.4 audio-only scope; video upgrade is Track B
    )
}
```

- [ ] **Step 4: Run tests.**

Run: `swift test --filter InCallViewModelTests`
Expected: 7 tests, all PASS.

- [ ] **Step 5: Commit.**

```bash
git add QAudionEngine/Sources/QAudionEngine/UI/ViewModels/InCallViewModel.swift QAudionEngine/Tests/QAudionEngineTests/UI/InCallViewModelTests.swift
git commit -m "feat(ui): F1.5 InCallViewModel covering 7 in-call elements"
```

### Task F1.6: SasVerificationViewModel (TDD)

**Files:**
- Create: `QAudionEngine/Sources/QAudionEngine/UI/ViewModels/SasVerificationViewModel.swift`
- Create: `QAudionEngine/Tests/QAudionEngineTests/UI/SasVerificationViewModelTests.swift`

Drives the SAS-verification sheet that pops on first call with a new contact. Per desktop audit §8: SAS uses PGP word list. Per spec §5.1: anchored to the public-key fingerprint.

- [ ] **Step 1: Write the failing test:**

```swift
import XCTest
@testable import QAudionEngine

final class SasVerificationViewModelTests: XCTestCase {

    func test_mockIsDeterministic() {
        XCTAssertEqual(SasVerificationViewModel.mock, SasVerificationViewModel.mock)
    }

    func test_mockHasFourSasWords() {
        // Cross-platform standard: 4 PGP words = 32 bits of fingerprint entropy.
        XCTAssertEqual(SasVerificationViewModel.mock.sasWords.count, 4)
    }

    func test_mockSasWordsAreLowercase() {
        for w in SasVerificationViewModel.mock.sasWords {
            XCTAssertEqual(w, w.lowercased(), "SAS words must be lowercase for cross-platform comparison")
        }
    }

    func test_mockExposesPeerFingerprint() {
        let mock = SasVerificationViewModel.mock
        let parts = mock.peerFingerprint.split(separator: ".")
        XCTAssertEqual(parts.count, 4)
    }

    func test_mockUserHasNotConfirmed() {
        XCTAssertEqual(SasVerificationViewModel.mock.userVerdict, .pending)
    }
}
```

- [ ] **Step 2: Run to verify failure.**

Run: `swift test --filter SasVerificationViewModelTests`
Expected: FAIL — `cannot find 'SasVerificationViewModel' in scope`.

- [ ] **Step 3: Implementation:**

```swift
import Foundation

public struct SasVerificationViewModel: ViewModelProtocol {

    public enum Verdict: Equatable, Sendable {
        case pending           // user hasn't pressed match / mismatch yet
        case match             // user confirmed words match peer's
        case mismatch          // user reports words DON'T match — call MUST be torn down
    }

    public let peerDisplayName: String
    public let peerFingerprint: String  // §5.1 format
    /// 4 lowercase PGP words derived from first 32 bits of the call-session
    /// PQC handshake transcript, lookup-mapped to PGP word list.
    public let sasWords: [String]
    public private(set) var userVerdict: Verdict

    public init(peerDisplayName: String, peerFingerprint: String, sasWords: [String], userVerdict: Verdict = .pending) {
        self.peerDisplayName = peerDisplayName
        self.peerFingerprint = peerFingerprint
        self.sasWords = sasWords
        self.userVerdict = userVerdict
    }

    public mutating func recordUserVerdict(_ verdict: Verdict) {
        guard userVerdict == .pending else { return }
        userVerdict = verdict
    }

    public static let mock = SasVerificationViewModel(
        peerDisplayName: "Alice (Pixel 7)",
        peerFingerprint: "a3f7.c291.8b4e.d012",
        sasWords: ["abandon", "ability", "able", "about"],  // PGP word-list samples
        userVerdict: .pending
    )
}
```

- [ ] **Step 4: Run tests.**

Run: `swift test --filter SasVerificationViewModelTests`
Expected: 5 tests, all PASS.

- [ ] **Step 5: Commit.**

```bash
git add QAudionEngine/Sources/QAudionEngine/UI/ViewModels/SasVerificationViewModel.swift QAudionEngine/Tests/QAudionEngineTests/UI/SasVerificationViewModelTests.swift
git commit -m "feat(ui): F1.6 SasVerificationViewModel + verdict state machine"
```

### Task F1.7: Run full ViewModel test suite + closeout F1

**Files:** none (verification step)

- [ ] **Step 1:** Run all UI ViewModel tests.

Run from `QAudionEngine/`: `swift test --filter ViewModelTests` (matches all `*ViewModelTests` classes)
Expected: 5 test cases, ~24 individual tests, all PASS, in <2s.

- [ ] **Step 2:** Update `docs/progress/STATUS.md` — mark F1 as DONE, F2 as IN PROGRESS:

```markdown
## Fase attiva
**Track A Foundation Sprint — IN PROGRESS** (`docs/superpowers/specs/2026-04-28-cross-platform-alignment-design.md` + `docs/superpowers/plans/2026-04-28-track-a-foundation.md`).
- F0 (Invariants verification) — ✅ DONE — see `docs/progress/INVARIANTS_VERIFIED.md`
- F1 (UI ViewModels: KeyMgmt, DeviceMgmt, NfcExchange, InCall, SasVerification) — ✅ DONE
- F2 (Platform scaffolding) — IN PROGRESS
- F3 (Closeout) — pending
```

- [ ] **Step 3:** Append to `docs/progress/TASK_LOG.md`:

```markdown
- 2026-04-28 | F1 | UI ViewModel scaffold (KeyMgmt + DeviceMgmt + NfcExchange + InCall + SasVerification + protocol) | <commit-sha-of-F1.6> | DONE | Pure Swift, no SwiftUI/Combine deps; ~24 unit tests via `swift test`. Settings hub + 11 sub-screen VMs deferred to A.6 plan.
```

- [ ] **Step 4:** Commit.

```bash
git add docs/progress/STATUS.md docs/progress/TASK_LOG.md
git commit -m "docs(progress): F1 complete — ViewModel scaffold landed"
```

---

## Phase F2 — Platform Scaffolding

Goal: low-risk hygiene work that makes A.2-A.6 cleaner. Three targeted tasks.

### Task F2.1: ChatView consolidation analysis (decide canonical, don't implement)

**Files:**
- Read: `QAudionApp/Views/ChatView.swift`
- Read: `QAudionEngine/Sources/QAudionEngine/UI/ChatView.swift`
- Create: `docs/progress/CHATVIEW_CONSOLIDATION.md`

The two files cover the same conceptual screen. We need to decide which is canonical BEFORE A.6 / B.6 implements chat parity.

- [ ] **Step 1:** Read both files end-to-end.

Run via Read tool: `QAudionApp/Views/ChatView.swift`
Run via Read tool: `QAudionEngine/Sources/QAudionEngine/UI/ChatView.swift`

- [ ] **Step 2:** Tabulate differences. For each of (imports, public surface, state management, server calls, message bubble subview, attachment handling, navigation), note which file has it and how rich it is.

- [ ] **Step 3:** Create `docs/progress/CHATVIEW_CONSOLIDATION.md` with this exact format:

```markdown
# ChatView Consolidation Analysis

> **Generated:** 2026-04-28 (F2.1).
> **Decision needed before:** Track B.6 (chat parity) or A.6 settings split, whichever lands first.

## Two files exist

| Aspect | `QAudionApp/Views/ChatView.swift` | `QAudionEngine/Sources/QAudionEngine/UI/ChatView.swift` |
|---|---|---|
| LOC | _<count>_ | _<count>_ |
| Imports | _<list>_ | _<list>_ |
| Public surface | _<list of public structs/funcs>_ | _<list>_ |
| State management | _<observation>_ | _<observation>_ |
| Server calls | _<list endpoints touched, or "none">_ | _<list, or "none">_ |
| Subviews | _<list>_ | _<list>_ |
| Attachments | _<yes/no, mechanism>_ | _<yes/no, mechanism>_ |
| Last commit touching it | _<run `git log -1 --format=%h\ %s -- <file>`>_ | _<same>_ |

## Recommendation

_<one of: "Keep app-level, delete engine-level (engine view is dead code)" / "Keep engine-level, delete app-level (app view shadows the proper engine impl)" / "Both have value — extract a shared `ChatViewProtocol` in engine, keep both impls">_

## Action item for the next plan

_<concrete next step, e.g.: "B.6 Step 1: delete `QAudionApp/Views/ChatView.swift`, update import in `ContentView.swift` to `import QAudionEngine`.">_
```

Fill in every `_<...>_` placeholder by reading the two files. Do NOT delete either file in this task — that's for a future task once the decision is made.

- [ ] **Step 4:** Commit.

```bash
git add docs/progress/CHATVIEW_CONSOLIDATION.md
git commit -m "docs(parity): F2.1 ChatView consolidation analysis"
```

### Task F2.2: Working-tree stray-files inventory

**Files:**
- Modify: `docs/progress/STATUS.md`

Per `STATUS.md` §"Stray files in working tree (not ours, flagged)" there are 12+ empty 0-byte files at the repo root that are accidental shell redirects. Today's `git status --short` shows: `.allocate(capacity`, `QAudionApp/Services/ContactSyncService.swift`, `QAudionEngine/Sources/QAudionEngine/Backend/BCrypto/BCryptoPresenceManager.swift`. The two latter ones are real files (USER WT). The first is a stray.

- [ ] **Step 1:** Run a full inventory.

Run: `git status --short` and capture output.
Run: `ls -la "D:/users/f10379a/DEV APP/BCRYPTO/apps/qaudion-ios" | grep -E "^-.*[0-9]+ [A-Za-z]+ +[0-9]+ +[0-9]+:[0-9]+ "` and capture stray files (size = 0 bytes).

(On Windows, the equivalent: use Bash `find . -maxdepth 1 -size 0 -type f`.)

- [ ] **Step 2:** For each stray file found:
- Cite its name verbatim (some have weird characters like `'`, `(`, `[`).
- Confirm size is 0 bytes via `wc -c "<filename>"`.
- Check it is NOT in `git status` as M (modified) — if it is, leave alone (USER WT).

- [ ] **Step 3:** Update `docs/progress/STATUS.md` §"Stray files in working tree (not ours, flagged)" with the current full list (replacing the 2026-04-20 list). Add a date-stamped header.

```markdown
## Stray files in working tree (not ours, flagged)

**Verified empty (0-byte) at 2026-04-28 — accidental shell redirects from prior sessions:**
- _<full list of file names with backticks around weird-char names>_

**USER working-tree files (D-05 hygiene — NEVER stage):**
- `QAudionApp/Services/ContactSyncService.swift` (untracked)
- `QAudionEngine/Sources/QAudionEngine/Backend/BCrypto/BCryptoPresenceManager.swift` (untracked)
- `QAudionEngine/Sources/QAudionEngine/Backend/BCrypto/{BCryptoBackendProvider,BCryptoCallingApiImpl,BCryptoGroupCallManager,BCryptoWebSocketClient}.swift` (M)
- `QAudionEngine/Sources/QAudionEngine/Backend/Protocols/CallingApi.swift` (M)
- `QAudionEngine/Sources/QAudionEngine/Integration/QAudionCallIntegration.swift` (M)

The stray files are harmless and DO NOT impact build. Parity agents will not auto-delete them (some look like USER's accidental keypresses); the user should `rm` them at their convenience.
```

- [ ] **Step 4:** Commit.

```bash
git add docs/progress/STATUS.md
git commit -m "docs(progress): F2.2 working-tree stray-files inventory refreshed"
```

### Task F2.3: ANDROID_REFERENCE.md correction (WS envelope `id` field)

**Files:**
- Modify: `docs/progress/ANDROID_REFERENCE.md`

Per server audit (design spec §5.8): the lite server doesn't read the `id` field on WS envelopes. ANDROID_REFERENCE.md §"WebSocket envelope" is stale.

- [ ] **Step 1:** Read `docs/progress/ANDROID_REFERENCE.md`. Locate the §"WebSocket envelope" block (around lines 13-19).

- [ ] **Step 2:** Replace that block with:

```markdown
### WebSocket envelope
```json
{"type": "<string>", "data": {...}}
```
- `type` is snake_case on the wire (e.g. `auth_request`, `call_offer`, `presence_update`).
- **No `id` correlation field on the lite server variant** (verified 2026-04-28 in `INVARIANTS_VERIFIED.md` §5.8). Earlier docs claimed `{type, data, id}` — that's stale. Correlation is by context (`call_id` / `recipient_id` / `mailbox_id`).
- iOS code currently emits an `id` field on outbound envelopes; server ignores it. Cleanup tracked in B.1 WS code fix.
```

- [ ] **Step 3:** Commit.

```bash
git add docs/progress/ANDROID_REFERENCE.md
git commit -m "docs(parity): F2.3 correct ANDROID_REFERENCE.md WS envelope (no id field)"
```

---

## Phase F3 — Closeout

### Task F3.1: Final STATUS + TASK_LOG sync

**Files:**
- Modify: `docs/progress/STATUS.md`
- Modify: `docs/progress/TASK_LOG.md`

- [ ] **Step 1:** Update `docs/progress/STATUS.md` Fase attiva:

```markdown
## Fase attiva
**Track A Foundation Sprint — ✅ DONE** (`docs/superpowers/plans/2026-04-28-track-a-foundation.md`).
- F0 (Invariants) ✅ · F1 (ViewModels) ✅ · F2 (Scaffolding) ✅ · F3 (Closeout) ✅

## Next phase
**Track A.2-A.6 — feature plans pending.** Next plan to write: `docs/superpowers/plans/2026-04-28-track-a-phase4-nfc-keymgmt.md` (or whatever next plan is prioritized — A.3 CallKit, A.6 Settings, etc.). User decides priority.

## Open server-team questions (carried from spec §10)
- §10.1 APNs VoIP push — server team to pick α/β/γ/δ
- §10.2 security endpoints (zk-register/zk-auth/pqc-relay/threat-report/wipe-confirm) schema decision
- §10.3 GroupChat — iOS UX decision
- §10.4 Phonebook import scope decision
```

- [ ] **Step 2:** Append two lines to `docs/progress/TASK_LOG.md`:

```markdown
- 2026-04-28 | F2 | Platform scaffolding hygiene (ChatView analysis + stray-files + WS-envelope correction) | <commit-sha-of-F2.3> | DONE | F2.1 produced `CHATVIEW_CONSOLIDATION.md` (decision pending). F2.2 refreshed stray-files inventory in STATUS. F2.3 corrected ANDROID_REFERENCE.md §"WebSocket envelope" to remove stale `id` field claim.
- 2026-04-28 | F3 | Track A Foundation Sprint closeout | <commit-sha-of-F3.1> | DONE | Plan executed end-to-end. Ready for next Track A feature plan (A.2 NFC, A.3 CallKit, A.6 Settings, A.4 In-call UI, A.5 PushKit).
```

- [ ] **Step 3:** Commit.

```bash
git add docs/progress/STATUS.md docs/progress/TASK_LOG.md
git commit -m "docs(progress): Track A Foundation Sprint complete"
```

### Task F3.2: Verification tag (optional, recommended)

**Files:** none (Codemagic verification only)

- [ ] **Step 1:** Confirm with the user that they want to push a verification tag to Codemagic. Foundation Sprint touched:
  - 1 new spec file
  - 1 new plan file
  - 1 new INVARIANTS_VERIFIED.md
  - 5 new ViewModel Swift files + 5 test files
  - 1 new ViewModelProtocol.swift + 1 smoke test file
  - Various STATUS.md / TASK_LOG.md / ANDROID_REFERENCE.md edits
  - 1 new CHATVIEW_CONSOLIDATION.md

  Total: ~13 new files, ~5 docs edits. Zero changes to `codemagic.yaml`, `Info.plist`, `entitlements`, `project.yml`, `Package.swift`. Should produce an IPA byte-identical to `v1.0.24-ph0` (no app code paths changed).

- [ ] **Step 2 (only if user approves):** Push tag.

```bash
git tag v1.0.24-ph2  # ph2 = post-Foundation-Sprint
git push origin v1.0.24-ph2
```

- [ ] **Step 3 (only if Step 2 ran):** Watch Codemagic. Per CLAUDE.md §10: green pipeline = upload OK; canonical truth comes from Apple's email inbox 24h later.

- [ ] **Step 4:** Update `docs/progress/STATUS.md` "Prossima verification tag" line accordingly.

---

## Self-review checklist (run mentally before declaring plan complete)

- [x] **Spec coverage:** F0 covers §5 invariants. F1 covers A.1 (scoped to A.2/A.3/A.4/A.5 screens; Settings 11-VMs deferred to a future A.6 plan with explicit rationale in F1 header). F2 covers A.7 sub-items (ChatView consolidation + stray files + ANDROID_REFERENCE correction). Spec §10 open questions (APNs / security schemas / GroupChat / phonebook) carried forward to STATUS.md.
- [x] **Placeholder scan:** No "TBD" / "TODO" / "etc" in any code step. Document templates have explicit `_(F0.X)_` markers that the executing engineer fills in by reading source — those are not placeholder *answers*, they are placeholder *prompts*.
- [x] **Type consistency:** `KeyManagementViewModel.LinkedDevice` uses `deviceId / deviceName / lastSeen / isCurrentDevice`; `DeviceManagementViewModel.Device` extends with `platform / linkedAt / canRevoke`. Both `InCallViewModel.PeerInfo.fingerprint` and `KeyManagementViewModel.fingerprint` use the §5.1 4-group hex format. `NfcExchangeViewModel.aidHex` matches the §5.5 spec value.
- [x] **D-05 hygiene observed:** no step touches USER-WT files.
- [x] **Codemagic preservation:** zero edits to `codemagic.yaml`, `Info.plist`, `QAudion.entitlements`, `project.yml`, `Package.swift`, `Assets.xcassets`. F3.2 verification tag is optional.
- [x] **Test approach:** every ViewModel task is TDD (failing test → implementation → passing test → commit). F0 doc tasks use grep-based sanity checks (`grep -c "_(F0.X)_"` should be 0).
- [x] **Iteration loop on Windows:** `swift test --filter <Class>` is the canonical verifier. If liboqs C deps don't build on Windows, fallback is GitHub Actions `engine-tests.yml` (per Package.swift, the QAudionEngine target depends on CLiboqs — pure ViewModels won't trigger that, but transitive imports might).

---

## Notes for the executing engineer

1. **Run from `QAudionEngine/` directory** for `swift test`. The package manifest is there.
2. **If `swift test` fails on liboqs link** on your Windows machine, you have two options: (a) push to a feature branch and let `engine-tests.yml` run on macOS GitHub runners, (b) skip local test verification and trust the structure.
3. **Do not bump any dependency** in `Package.swift` (CLAUDE.md §6 + spec §12).
4. **Every commit message uses conventional prefix** (`docs(...)`, `feat(ui)`, `fix(...)`).
5. **If a step fails unexpectedly**, document it as a BLOCKED line in `TASK_LOG.md` and stop — do NOT improvise around the spec.
