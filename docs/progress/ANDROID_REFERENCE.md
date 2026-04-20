# ANDROID_REFERENCE — Cached facts from Q-Audion Android New

> Source of truth cached. Local path (NOT in repo): `D:\users\f10379a\DEV APP\BCRYPTO\Q-Audion Android New`.
> When in doubt, re-read the Android file and update this note with a dated correction.

---

## Wire Protocol (BCrypto server)

### REST base
`/api/v1/` — all calls.

### WebSocket envelope
```json
{"type": "<string>", "data": {...}, "id": "<uuid|nullable>"}
```
- `id` is the correlation/request id for response matching. Present on both directions.
- `type` is snake_case on the wire (e.g. `auth_request`, `call_offer`, `presence_update`).

### Auth/register flow
- Register: `POST /api/v1/auth/register` with `{phone_hash, public_key, device_id, platform}`.
- Login: `POST /api/v1/auth/login` then WS upgrade with bearer token.
- Token refresh: documented in commit `4516e01 feat(backend): align server protocol (envelope id, keepalive, token refresh)`.

## Phone hashing
**SHA-256 (hex, lowercase) of E.164-normalized phone number.**
No salt, no pepper. Identical call across iOS / Android / server.

```
phone_hash = hex(sha256(utf8(e164_normalized_phone)))
```

E.164 normalization: strip spaces, dashes, parens; keep leading `+`; lowercase (digits are digits, but `+` is preserved).

## HKDF parameters

| Purpose | Salt | Info |
|---------|------|------|
| Message key (conversation) | (per-pair, see ContactKeyExchange) | `"q-audion-msg-key"` |
| Device link PSK | `"qaudion-link-salt"` (UTF-8) | `"qaudion-device-link-v1"` |
| NFC collaborative PSK | `SHA256(sorted_concat(pubkeyA, pubkeyB))` | `"Q-Audion NFC Collaborative PSK v1"` |

All HKDF = HKDF-SHA256, output length 32 bytes (256-bit symmetric key).

## Fingerprint format
4-character hex groups joined by dots:
```
a3f7.c291.8b4e.d012
```
Derived from the first 8 bytes of `SHA256(public_key_bytes)`, formatted as 4 groups × 4 hex chars.

## QR Identity (public key sharing)
Printable, copy-paste-friendly text. Used for "show my identity / scan contact" flows.
See `QAudionEngine/Sources/QAudionEngine/UI/QrIdentityView.swift` (iOS) and Android analog.

## Device Linking Binary QR
Binary blob, base64url-encoded, wrapped in custom URL scheme.
```
layout:   [ 32B X25519 public key | 4B length (big-endian) | userId UTF-8 | 16B auth code ]
encoding: base64url (no padding)
wrapper:  qaudion://link/<base64url_blob>
```
NOTE (iOS-specific): iPhones cannot act as NFC HCE tags → no iOS-to-iOS NFC pairing is possible; only iOS-reader ↔ Android-HCE or QR fallback.

## NFC Collaborative PSK (iOS reader ↔ Android HCE)
- **AID:** `F0BCF1073A5100` (7 bytes)
- **APDU SELECT command:** standard ISO-7816 `00 A4 04 00 07 F0 BC F1 07 3A 51 00 00`
- **Payload (64 bytes):** `[ 32B ephemeral X25519 public key | 32B random entropy ]`
- **PSK derivation:** HKDF-SHA256(shared = X25519(myPriv, theirPub), salt = SHA256(sorted(pubA, pubB)), info = `"Q-Audion NFC Collaborative PSK v1"`, len = 32).
  - `sorted(pubA, pubB)` = lexicographic byte-order sort of the two 32-byte public keys, concatenated.

## VoIP Push Notification Payload
Cross-platform FCM (Android) / APNs VoIP (iOS):
```json
{
  "type": "incoming_call",
  "call_id": "<uuid>",
  "caller_id": "<user_id>",
  "caller_name": "<display name>",
  "call_type": "audio|video"
}
```

## Call signaling types (WebSocket `type` field)
- `call_offer` · `call_answer` · `call_reject` · `call_hangup`
- `call_ringing` · `call_connected`
- `ice_candidate` · `sdp_update`
- `presence_update` (online/offline/away)
- `message_send` · `message_delivered` · `message_read`

## Cryptographic primitives parity
- **Post-quantum KEM:** ML-KEM-1024 via liboqs (identical public/private key lengths both platforms).
- **Classic ECDH:** X25519 (Curve25519 KeyAgreement).
- **Combined KEX:** Hybrid = `KDF(ML-KEM-shared || X25519-shared || transcript)`.
- **AEAD:** AES-256-GCM (12-byte nonce, 16-byte tag).
- **Hash:** SHA-256 everywhere (fingerprint, phone_hash, HKDF, transcript binding).

## Settings screen — 9 sections (must match Android)
1. Account (phone, fingerprint)
2. Security (PQC info, threat reports)
3. Notifications (ringtone, quiet hours)
4. Calls (codec, AEC/NS/AGC, VoIP background)
5. Chat (read receipts, typing)
6. Privacy (presence, read status, Tor)
7. Storage (cache, DB)
8. About (version, compliance)
9. Advanced (debug, logs)

## In-call UI — 7 elements
1. Security badge (compact + expanded)
2. Waveform TX (cyan) / RX (green) / Cipher (orange)
3. Call timer
4. Participant name + avatar
5. Mute / Speaker / Hold / End buttons
6. Video PiP (if video)
7. SAS verification prompt (on first call with a new contact)
