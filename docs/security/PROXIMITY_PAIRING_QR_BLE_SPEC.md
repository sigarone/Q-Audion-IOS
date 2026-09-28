# Proximity pairing v1 — QR + Bluetooth LE, hybrid ML-KEM-1024

Status: **iOS implementation in progress** (branch `claude/lucid-mccarthy-7lnmr3`).
Android and Desktop: **not implemented** — this document is the normative spec
for the port. Every byte, label and check below is normative unless marked
"informative". Test vectors: §15.

## 1. Purpose

Give two phones that are physically next to each other a way to establish a
post-quantum pre-shared key (PSK) with the same security posture as the NFC
tap, **without** NFC card emulation (which iOS does not offer to third-party
apps — `AssuranceState.iosOriginatesS2Witness == false`). One phone shows a
QR code, the other scans it; the scan automatically opens a Bluetooth LE
channel between the two phones (no OS pairing dialog, no device list), the
phones run an authenticated hybrid ML-KEM-1024 + X25519 exchange over it, and
both users confirm a 6-digit code before anything is stored.

The resulting PSK is stored with `PskOrigin.proximity` (non-exportable), is
advertised with wire role `3` (§12; WIRE_SPEC §3.3.1 role recovery), and is
mixed into call session keys exactly like every other PSK.

## 2. Threat model and security properties

Attacker capabilities considered:

| # | Attacker | Outcome |
|---|---|---|
| A1 | Passive BLE eavesdropper, even one who ALSO photographed the QR | Learns nothing about the PSK: secrecy comes from ML-KEM-1024 + X25519 ephemeral keys that never leave the devices, not from anything in the QR. |
| A2 | Active BLE attacker in radio range, without the QR | Cannot produce a valid HELLO (needs the per-frame `frameKey`), cannot substitute the displayer's keys (QR commitment), cannot forge ACCEPT/FINISH (Ed25519 + HKDF-keyed MACs over the full transcript). Can only cause a DoS. |
| A3 | Remote attacker holding a photo / screenshot / forwarded image of the QR | The QR rotates every 2 s and a frame is accepted for 8 s only; the displayer screen is screenshot-protected; completing the exchange needs a BLE radio within range of the displayer. A stale image is useless. |
| A4 | Real-time relay: live video of the displayer's screen + an attacker radio near the displayer | **Not preventable by any BLE-only protocol** (BLE has no physical-layer distance bounding; the attacker's radio can terminate the protocol itself, so round-trip timing proves nothing). Detected by the human step: both screens show the peer's name and the same 6-digit SAS, both users must confirm, and the session is single-use — if the attacker wins the race, the legitimate scanner gets "busy" and the displayer shows a name/code the person in front of them does not see. |
| A5 | Someone presenting a known contact's userId with a different identity key | The identity key the contact already has pinned (`PeerIdentityPinStore`) is compared; a mismatch is shown as a red warning on the confirmation screen. |

Properties: mutual authentication of long-term Ed25519 identity keys, key
confirmation, transcript binding (incl. the QR bytes), forward secrecy
(ephemeral KEM + X25519 keys, zeroized after use), post-quantum
confidentiality (ML-KEM-1024, NIST category 5), hybrid defense in depth
(X25519), single-use sessions, contributory randomness from both sides.

Honest limit: the NFC tap bounds distance at a few centimetres by physics;
this protocol bounds it at BLE range (~10 m) plus a human check. An optional
hardware distance-bounding tier (UWB / NearbyInteraction, iPhone 11+) is the
only way to close A4 cryptographically and is out of scope for v1.

Identity signatures are Ed25519 (classical). Authentication only has to hold
at pairing time — there is no "harvest now, forge later" for signatures — and
Ed25519 is the identity key every call handshake already signs with
(`AppState` `integration.localSignerIdentityKey`).

## 3. Primitives

- ML-KEM-1024 (FIPS 203) via liboqs `OQS_KEM_ml_kem_1024_*`: ek 1568 B, dk 3168 B, ct 1568 B, ss 32 B.
- X25519 (RFC 7748): 32 B keys; an all-zero shared secret MUST be rejected.
- Ed25519 (RFC 8032): 32 B public key, 64 B signature.
- SHA-256, HMAC-SHA256, HKDF-SHA256 (RFC 5869).
- CSPRNG: `SecRandomCopyBytes` (iOS), `SecureRandom` (Android). Failure is fatal.

Encodings: `u16be`, `u32be` big-endian unsigned; `lp32(x) = u32be(len(x)) ‖ x`;
labels are ASCII, no NUL terminator; `‖` is concatenation.

## 4. Constants

| Name | Value |
|---|---|
| protocol version | `0x01` |
| sessionId | 16 B random |
| sessionSecret | 32 B random (never leaves the displayer) |
| nonces | 32 B random each side |
| frameKey | 32 B |
| commitment | 32 B |
| MACs | 32 B |
| userId | UTF-8, 1..256 bytes |
| max protocol message | 4096 B |
| frame rotation | 2.0 s |
| frame acceptance window | 8.0 s from first display of that frame |
| displayer session lifetime | 120 s, then regenerated (new keys, new sessionId) |
| handshake timeout | 20 s (HELLO → keys verified) |
| user confirmation timeout | 120 s |
| scanner discovery+connect timeout | 15 s |
| GATT service UUID | the 16 sessionId bytes read as a 128-bit UUID |
| characteristic scanner→displayer | `51A0C2D0-7E2B-4F6B-9E1D-0A8B5C3F2D01` (write) |
| characteristic displayer→scanner | `51A0D2C0-7E2B-4F6B-9E1D-0A8B5C3F2D02` (notify) |

Labels:

```
L_COMMIT      = "qaudion-prox-v1/commit"
L_FRAME       = "qaudion-prox-v1/frame"
L_HELLO       = "qaudion-prox-v1/hello"
L_TRANSCRIPT  = "qaudion-prox-v1/transcript"
L_MAC_S       = "qaudion-prox-v1/mac-scanner"
L_MAC_D       = "qaudion-prox-v1/mac-displayer"
L_CONFIRM_S   = "qaudion-prox-v1/confirm-scanner"
L_CONFIRM_D   = "qaudion-prox-v1/confirm-displayer"
L_SAS         = "qaudion-prox-v1/sas"
L_PSK         = "qaudion-prox-v1/psk"
L_SIG_S       = "qaudion-prox-v1/sig-scanner"
L_SIG_D       = "qaudion-prox-v1/sig-displayer"
L_CONFIRMED   = "qaudion-prox-v1/user-confirmed"
```

## 5. QR payload

```
qrBytes = u8(0x01)            version
        ‖ sessionId[16]
        ‖ commitment[32]
        ‖ u32be(frameIndex)
        ‖ frameKey[32]         = 85 bytes exactly

QR text = "qaudion://pair/" ‖ base64url_nopad(qrBytes)     (114 base64url chars)
```

Decoders MUST be strict: scheme `qaudion` and host `pair` (ASCII
case-insensitive), exactly one path segment, no query, no fragment, only the
base64url alphabet `[A-Za-z0-9_-]`, no padding, exactly 114 characters,
decoding to exactly 85 bytes, version `0x01`. Anything else is rejected.
Leading/trailing whitespace and newlines (Unicode `White_Space`, i.e.
Foundation's `.whitespacesAndNewlines`) of the scanned string are trimmed
first; nothing inside the string is.

## 6. Displayer session setup and frame rotation

On start the displayer generates: `sessionId`, `sessionSecret`, an ML-KEM-1024
keypair `(ek_D, dk_D)`, an X25519 keypair `(xsk_D, xpk_D)`, `nonce_D`, and
builds its OFFER body (§8) from these plus its identity. Then:

```
commitment  = SHA-256( L_COMMIT ‖ sessionId ‖ offerBody_D )
frameKey_i  = HMAC-SHA256( key = sessionSecret,
                           msg = L_FRAME ‖ sessionId ‖ u32be(i) )
```

Frame `i` starts at 0 and increments every 2 s; the QR shown for frame `i`
carries `(sessionId, commitment, i, frameKey_i)`. The displayer records the
monotonic time each frame was first shown and accepts frame `i` only while
`now − shownAt(i) ≤ 8 s`.

The QR is displayed only while the session is waiting. The screen MUST be
screenshot/recording protected (iOS: `ScreenshotLockService`).

## 7. BLE profile and framing

Displayer = GATT peripheral, advertises only the service UUID (no local name).
Scanner = central, scans filtered on that UUID, connects to the first match.
No characteristic requires link-layer encryption, so the OS never shows a
pairing dialog; all security is in §8–§10.

- scanner→displayer characteristic: properties `write` (with response), permission `writeable`.
- displayer→scanner characteristic: properties `notify`; reads are refused.
- The displayer requests low connection latency for the connected central.

Each ATT value (a write or a notification) is one fragment:

```
fragment = u8(flags) ‖ u8(seq) ‖ payload      (payload ≥ 1 byte)
flags    : 0x01 FIRST, 0x02 LAST, all other bits MUST be 0
seq      : 0 on the FIRST fragment of a message, +1 for each following
           fragment of that message; a message spans at most 256
           fragments (seq 0…255) — a 257th fragment is an error
```

Fragment size = `ATT_MTU − 3` (iOS: `maximumWriteValueLength(for:
.withoutResponse)` for writes even though writes are sent WITH response, so
the stack never falls back to prepare/execute long writes;
`CBCentral.maximumUpdateValueLength` for notifications). A receiver rejects a
fragment with unknown flag bits, empty payload, a seq mismatch, FIRST in the
middle of a message, a non-FIRST start, or a reassembled size > 4096 B. Any
framing error aborts the pairing.

Writes are sent one at a time, the next after the previous write's response.
Notifications are queued and resumed on "ready to update subscribers".

Closing never cuts off the last message: a scanner that closes with a write
still queued or unanswered (typically ABORT) keeps the connection until that
write is answered or 0.5 s pass, and a displayer that shuts down after
sending keeps its GATT service (not the advertisement) for 0.5 s. Nothing is
delivered to the closed session during that time.

## 8. Messages

A reassembled message is `u8(type) ‖ body`.

| type | name | direction | body |
|---|---|---|---|
| 0x01 | HELLO | S→D | `u32be(frameIndex) ‖ xpk_S[32] ‖ nonce_S[32] ‖ tag[32]` (100 B) |
| 0x02 | OFFER | D→S | `ek_D[1568] ‖ xpk_D[32] ‖ nonce_D[32] ‖ idPub_D[32] ‖ encPub_D[32] ‖ u16be(n) ‖ userId_D[n]` |
| 0x03 | ACCEPT | S→D | `ct[1568] ‖ idPub_S[32] ‖ encPub_S[32] ‖ u16be(n) ‖ userId_S[n] ‖ sig_S[64] ‖ mac_S[32]` |
| 0x04 | FINISH | D→S | `sig_D[64] ‖ mac_D[32]` |
| 0x05 | CONFIRM | both | `mac[32]` |
| 0x06 | ABORT | both | `u8(reason)` |
| 0x07 | BUSY | D→S | empty |

`idPub` = Ed25519 identity public key (the key call handshakes are signed
with); `encPub` = X25519 identity public key (the contact key shown in the
identity QR); `userId` = the server account id. Parsers MUST check exact
lengths, `1 ≤ n ≤ 256`, valid UTF-8, and no trailing bytes.

The **ACCEPT unsigned part** is `ct ‖ idPub_S ‖ encPub_S ‖ u16be(n) ‖ userId_S`.

ABORT reasons: 1 user rejected, 2 authentication failed, 3 protocol
violation, 4 timeout, 5 identity rejected, 6 cancelled, 7 internal error,
8 QR frame expired. ABORT and BUSY are unauthenticated; they can only end a
pairing, never complete one.

HELLO tag:

```
tag = HMAC-SHA256( key = frameKey_i,
                   msg = L_HELLO ‖ sessionId ‖ u32be(i) ‖ xpk_S ‖ nonce_S )
```

## 9. Protocol flow

```
S scans QR ──► parse strictly (§5)
S: generate (xsk_S, xpk_S), nonce_S; scan for service UUID = sessionId,
   connect, subscribe to notify characteristic
S → D  HELLO
D: frame i known and fresh (§6)?  tag valid (constant-time)?
     no  → ABORT(8 or 2) to this central, disconnect it, keep waiting
           (an invalid HELLO does NOT consume the session)
     yes → lock the session to this central, stop advertising, stop
           rotating/hide the QR; any other central gets BUSY
D → S  OFFER
S: SHA-256(L_COMMIT ‖ sessionId ‖ offerBody) == commitment (constant-time)?
   parse; validate lengths; peer idPub != own idPub, peer userId != own userId
   identity policy (§12) on (idPub_D, userId_D) — already bound by the QR
   commitment, so it runs here, before any key material is spent
                                   any failure → ABORT, fail
   (ct, ss_kem) = ML-KEM-1024.Encaps(ek_D)
   ss_x = X25519(xsk_S, xpk_D)           reject all-zero
   TH, keys (§10); sig_S, mac_S
S → D  ACCEPT
D: ss_kem = Decaps(dk_D, ct); ss_x = X25519(xsk_D, xpk_S); TH, keys
   mac_S valid (constant-time)?  sig_S valid under idPub_S?
   identity policy (§12)?          any failure → ABORT, fail
D → S  FINISH
S: mac_D valid?  sig_D valid under idPub_D (committed in the QR)?
                                   any failure → ABORT, fail
Both: show peer name + SAS; wait for the local user.
   local confirm → send CONFIRM(HMAC(K_confirm_self, L_CONFIRMED))
   local reject  → send ABORT(1), fail
   receive CONFIRM → verify against K_confirm_peer (constant-time)
Both confirmed and the peer's CONFIRM verified → COMPLETE → persist.
Close the link 1 s after completing (lets the last CONFIRM drain).
```

Completion is per side and can be asymmetric: the side whose user confirms
LAST completes as soon as its own CONFIRM is sent, while the other side
completes only when that CONFIRM arrives. If the link drops in between, one
side stores the PSK and the other times out and stores nothing. That is safe
— a PSK is only ever mixed into a call when BOTH sides advertise the same
fingerprint (mutual selection), so an orphan entry is never used and a fresh
pairing simply adds a new one — but the failed side's UI must never claim
the pairing succeeded.

Ordering rules: a message not valid in the current state is a protocol
violation (abort). Messages are processed strictly one at a time.

## 10. Key schedule

```
TH  = SHA-256( L_TRANSCRIPT ‖ lp32(qrBytes_i) ‖ lp32(helloBody)
               ‖ lp32(offerBody) ‖ lp32(acceptUnsigned) )
```
`qrBytes_i` is the exact 85-byte QR of the frame named in HELLO (the
displayer rebuilds it from `(sessionId, commitment, i, frameKey_i)`);
bodies are exactly as sent, without the type byte.

```
IKM = ss_kem[32] ‖ ss_x[32] ‖ nonce_S[32] ‖ nonce_D[32]
PRK = HKDF-Extract( salt = TH, IKM )
K_mac_S     = HKDF-Expand(PRK, L_MAC_S, 32)
K_mac_D     = HKDF-Expand(PRK, L_MAC_D, 32)
K_confirm_S = HKDF-Expand(PRK, L_CONFIRM_S, 32)
K_confirm_D = HKDF-Expand(PRK, L_CONFIRM_D, 32)
sasBytes    = HKDF-Expand(PRK, L_SAS, 8)
PSK         = HKDF-Expand(PRK, L_PSK, 32)

mac_S = HMAC-SHA256(K_mac_S, TH)          sig_S = Ed25519(idPriv_S, L_SIG_S ‖ TH)
mac_D = HMAC-SHA256(K_mac_D, TH)          sig_D = Ed25519(idPriv_D, L_SIG_D ‖ TH)
confirm_S = HMAC-SHA256(K_confirm_S, L_CONFIRMED)
confirm_D = HMAC-SHA256(K_confirm_D, L_CONFIRMED)
SAS = decimal( u64be(sasBytes) mod 1 000 000 ), zero-padded to 6 digits
```

## 11. State machines and resource hygiene (informative)

Displayer: `idle → showing(frame) → exchanging → awaitingConfirmation →
completed | failed`. Scanner: `idle → connecting → exchanging →
awaitingConfirmation → completed | failed`. Every LOCAL failure (a check
that failed here, a local timeout, the user rejecting or cancelling) sends
ABORT on the locked link before closing it; a failure the peer caused (an
ABORT or BUSY received, the link dropping) sends nothing back. Every failure
closes the link and zeroizes `sessionSecret`, `dk_D`, shared secrets and
derived keys (the PSK is handed only to the completion result). Nothing is
persisted on any path other than `completed`.

A failure that says nothing about who is on the other end (QR frame expired,
timeout, radio dropped, BUSY) may put a fresh code on screen by itself. Any
other failure — a MAC/signature/commitment check, a "codes don't match"
from either user, an identity rejection — stays on the error until the user
explicitly asks for a new code, so a relaying attacker is never handed a new
attempt without a person deciding to try again.

## 12. Identity policy and persistence

Before showing the SAS each side evaluates the peer identity:
- same Ed25519 key or same userId as the local identity → **reject**;
- `PeerIdentityPinStore` holds one or more pins for `userId` (the legacy
  per-contact pin and/or the per-device ones) and the presented Ed25519 key
  equals none of them → **accept with warning** (red banner on the
  confirmation screen; the user decides in person);
- otherwise → accept.

Nothing writes pins (the call handshake owns pinning). On completion:

- vault entry name `prox-` ‖ first 16 lowercase hex chars of the peer's Ed25519 key;
- fingerprint label `lowercase_hex(SHA-256(PSK))`;
- origin `PskOrigin.proximity` (raw `"proximity"`, `isExportable == false`);
- the peer's full Ed25519 key in the presence-identity field of the vault blob
  (`nfcpid`, shared with NFC), so `AssuranceState.resolveNfcMixInputs` can
  prove at call time that the mixed secret is bound to the verified caller;
- wire role `3` (proximity) in PSK advertisements. `WIRE_SPEC.md` §3.3.1 still
  lists roles 0–2: that file is hash-locked byte-identical across the four
  repos (`.github/workflows/wire-spec-lock.yml`), so the one-line addition
  "`3` proximity" must land in all four together with the Android port. No
  wire change depends on it — receivers already recover the role by walking
  all 256 values;
- the app adds the peer as a contact (userId + encPub) if missing.

## 13. Android port notes (informative)

Same bytes, same labels, same checks. Android can play both roles
(BluetoothLeAdvertiser + BluetoothGattServer for the displayer,
BluetoothLeScanner + BluetoothGatt for the scanner); request MTU 517 on
connect. ML-KEM via BouncyCastle — use raw 1568-byte encodings on the wire,
never SPKI. The KAT in §15 is platform-neutral.

## 14. NFC v2 — ML-KEM-1024 for the NFC tap (proposal, not implemented)

The NFC exchange (`NfcApduExchange` / Android `NfcApduService`) is still
X25519-only. Its code comments are accurate: Android's HCE service answers
only SELECT / 0xC4 / 0xC5 / 0x01, so an iOS-only change would break the
only NFC peer that exists. The upgrade has to ship on both sides together:

1. SELECT response data gains a version byte (`0x02` = supports v2).
2. New INS `0xC6 GET_KEM_PUBKEY` (P1 = chunk index, Le = 240) returns the
   card's ephemeral ek in 240-byte chunks (7 APDUs), avoiding reliance on
   extended-length APDU support.
3. New INS `0xC7 PUT_KEM_CIPHERTEXT` (P1 = chunk index, P2 = 0x80 on the last
   chunk) carries the reader's ciphertext in ≤ 240-byte chunks.
4. `psk_v2 = HKDF(salt = SHA-256(sorted(ephPubs)),
   ikm = ss_kem ‖ ecdh ‖ entropy_a ‖ entropy_b,
   info = "Q-Audion NFC Collaborative PSK v2 ML-KEM-1024")`, and the SAS
   input gains the negotiated version byte, so a stripped capability changes
   both the key and the code instead of silently downgrading.
5. A contact once paired with v2 records it; a later v1-only tap with that
   contact is refused.

## 15. Test vectors

`QAudionEngine/Tests/QAudionEngineTests/Proximity/Resources/proximity-pairing-kat.json`,
generated by `scripts/kat/gen_proximity_pairing_kat.py` (an independent
hashlib/hmac reference implementation of §5, §6, §8 and §10). ML-KEM and
X25519 shared secrets are fixed inputs in the vector; everything derived
from them is checked byte-for-byte. Regenerate with
`python3 scripts/kat/gen_proximity_pairing_kat.py`.
