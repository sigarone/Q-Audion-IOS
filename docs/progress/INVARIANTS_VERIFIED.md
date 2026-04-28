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
