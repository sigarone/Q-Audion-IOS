# Proximity pairing v1 — QR + Bluetooth LE, hybrid ML-KEM-1024

Status: **shipped on iOS and Android** (Contacts → Aggiungi contatto →
"Associa di persona (QR + Bluetooth)"). Desktop: **not implemented** — this
document remains the normative spec for that port. Every byte, label and
check below is normative unless marked "informative". Test vectors: §15.

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
| A3 | Remote attacker holding a photo / screenshot / forwarded image of the QR | The QR rotates every 2 s and a frame is accepted for 8 s (real time, sleep included) only; a screenshot replaces the whole session at once; while the screen is recorded, mirrored or shared the code is not shown and no session runs; completing the exchange needs a BLE radio within range of the displayer. A stale image is useless. |
| A4 | Real-time relay: live video of the displayer's screen + an attacker radio near the displayer | **Not preventable by any BLE-only protocol** (BLE has no physical-layer distance bounding; the attacker's radio can terminate the protocol itself, so round-trip timing proves nothing). Detected by the human step: both screens show the peer's name and the same 6-digit SAS, both users must confirm, and the session is single-use. If the attacker wins the race, the displayer shows a name/code the person in front of it does not see, and the legitimate scanner shows no code at all — it gets BUSY, or, if the attacker also advertises the session UUID from closer by (it is broadcast in the clear) and captures the scanner's connection, it shows only a connection error or times out. **The rule both users follow is therefore: confirm only when BOTH screens show the same code at the same time.** A failed check or a refusal never puts a fresh code up by itself (§11). |
| A5 | Someone presenting a known contact's userId with a different identity key | The presented Ed25519 key is compared with every key the contact has pinned (`PeerIdentityPinStore`, legacy and per-device) and the presented keys with the identity key the address book holds; any mismatch is a red warning on the confirmation screen. Independently, the claimed account's server-published identity keys are fetched and the confirmation screen says whether the phone proved one of them (§12). A completion never rewrites a known contact. |
| A6 | Passive observer of the BLE exchange (with or without the QR) | Learns no key material (A1) and no identity: OFFER carries only ephemeral keys, and both identity blocks, signatures and MACs travel inside AES-256-GCM boxes keyed from the hybrid shared secret (SIGMA-I, §10). The scanner's identity is revealed only to whoever holds `dk_D` — the real displayer, since its ephemeral keys are committed in the QR. The displayer's identity is revealed only to a scanner that has completed a valid ACCEPT; an active relay attacker holding the live QR (A4) can be that scanner, which is the inherent SIGMA-I responder limit. No transferable proof of the pairing ever travels in clear. |
| A7 | Any radio in range | Can always deny service (jam, squat on the advertised session UUID, win the connection race). BLE gives range, not exclusivity. It cannot complete a pairing without the live QR, and cannot learn or influence the PSK. |

Properties: mutual authentication of long-term Ed25519 identity keys, key
confirmation, transcript binding (incl. the QR bytes), forward secrecy
(ephemeral KEM + X25519 keys, zeroized after use), post-quantum
confidentiality (ML-KEM-1024, NIST category 5), hybrid defense in depth
(X25519), identity hiding from passive observers (SIGMA-I sealed identity
blocks, A6), final keys bound to both identities (stage-2 extract over the
full transcript), single-use sessions, contributory randomness from both
sides.

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
| identity sealing | AES-256-GCM, 12-byte all-zero nonce (every key seals exactly one message), 16-byte tag appended |
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
L_TH_S        = "qaudion-prox-v1/transcript-scanner"
L_TH_D        = "qaudion-prox-v1/transcript-displayer"
L_ENC_S       = "qaudion-prox-v1/enc-scanner"
L_ENC_D       = "qaudion-prox-v1/enc-displayer"
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
keypair `(ek_D, dk_D)`, an X25519 keypair `(xsk_D, xpk_D)` and `nonce_D`,
and builds its OFFER body (§8) from these ephemeral values only — its
identity is never in the OFFER or the QR. Then:

```
commitment  = SHA-256( L_COMMIT ‖ sessionId ‖ offerBody_D )
frameKey_i  = HMAC-SHA256( key = sessionSecret,
                           msg = L_FRAME ‖ sessionId ‖ u32be(i) )
```

Frame `i` starts at 0 and increments every 2 s; the QR shown for frame `i`
carries `(sessionId, commitment, i, frameKey_i)`. The displayer records the
monotonic time each frame was first shown and accepts frame `i` only while
`now − shownAt(i) ≤ 8 s`.

The QR is displayed only while the session is waiting, and only while the
app is in the foreground with a screen that is not being captured:

- screen recorded, mirrored (AirPlay/cable) or shared (iOS
  `UIScreen.isCaptured`): the displayer stops its session and hides the code
  until the capture ends, then starts a fresh session. (iOS
  `ScreenshotLockService` only blanks its own secure layer in a capture, not a
  sibling view, so it is not relied on for this.)
- screenshot taken (`userDidTakeScreenshotNotification`): the whole session
  (sessionId, secrets, frame keys) is replaced at once.
- app to the background (screen locked, app switched): any live pairing on
  either side is cancelled; the displayer starts a fresh session on return.
  The screen does not auto-lock while the pairing screen is open.
- freshness uses a monotonic clock that keeps counting while the device
  sleeps (Darwin `CLOCK_MONOTONIC`, Android `SystemClock.elapsedRealtime`).
- the one-time OS Bluetooth permission prompt is answered BEFORE a code is
  shown (displayer) and, where possible, when the QR scanner opens
  (scanner), so its time never counts against a frame's 8 s window.

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

Fragment size = `min(ATT_MTU − 3, 512)` (iOS: `maximumWriteValueLength(for:
.withoutResponse)` for writes even though writes are sent WITH response, so
the stack never falls back to prepare/execute long writes;
`CBCentral.maximumUpdateValueLength` for notifications). The 512-byte cap is
`GATT_MAX_ATTR_LEN` (Bluetooth Core spec Vol 3 Part F §3.2.9) — a plain
`ATT_MTU − 3` is uncapped and reaches 514 B at MTU 517, which Android's
Bluetooth stack drops (a notification bigger than 512 B) or truncates (a
write bigger than 512 B) below the app; a sender that skips this cap breaks
every pairing against an Android peer once MTU negotiation goes past 515.
A receiver rejects a fragment with unknown flag bits, empty payload, a seq
mismatch, FIRST in the middle of a message, a non-FIRST start, or a
reassembled size > 4096 B. Any framing error aborts the pairing.

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
| 0x02 | OFFER | D→S | `ek_D[1568] ‖ xpk_D[32] ‖ nonce_D[32]` (1632 B) |
| 0x03 | ACCEPT | S→D | `ct[1568] ‖ sealed_S` where `sealed_S = Seal(K_enc_S, aad = TH1, idBlock_S ‖ sig_S[64] ‖ mac_S[32])` (1746 + n B) |
| 0x04 | FINISH | D→S | `sealed_D = Seal(K_enc_D, aad = TH_S, idBlock_D ‖ sig_D[64] ‖ mac_D[32])` (178 + n B) |
| 0x05 | CONFIRM | both | `mac[32]` |
| 0x06 | ABORT | both | `u8(reason)` |
| 0x07 | BUSY | D→S | empty |

`idBlock = idPub[32] ‖ encPub[32] ‖ u16be(n) ‖ userId[n]`, where `idPub` =
Ed25519 identity public key (the key call handshakes are signed with),
`encPub` = X25519 identity public key (the contact key shown in the identity
QR) and `userId` = the server account id. `Seal(K, aad, p)` = AES-256-GCM
with key `K`, the all-zero 12-byte nonce, additional data `aad`, output
`ciphertext ‖ tag[16]`; a tag that does not verify is an authentication
failure. Identities therefore never travel in clear: OFFER carries only
ephemeral keys, and each identity block goes inside a sealed box whose key
only the two ends of this exchange can derive. Parsers MUST check exact
lengths (a sealed box is 178 + n bytes — the 162 + n byte plaintext plus the
16-byte tag — and the opened plaintext exactly 66 + n + 96), `1 ≤ n ≤ 256`, no
trailing bytes, and MUST reject any userId
byte outside `[A-Za-z0-9._-]` (server ids are UUIDs). The grammar leaves no
way to write "the same id" as different bytes — no padding, NBSP,
zero-width or bidi characters, no `|` (the pin store's account separator) —
so the name shown for a userId and every exact-match lookup (pins, contacts,
self check) always agree. The KAT (§15) lists valid and invalid ids.

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
D → S  OFFER (ephemeral keys only)
S: SHA-256(L_COMMIT ‖ sessionId ‖ offerBody) == commitment (constant-time)?
                                   no → ABORT(2), fail
   (ct, ss_kem) = ML-KEM-1024.Encaps(ek_D)
   ss_x = X25519(xsk_S, xpk_D)           reject all-zero
   TH1, stage-1 keys (§10); TH_S, sig_S, mac_S; sealed_S
S → D  ACCEPT = ct ‖ sealed_S
D: ss_kem = Decaps(dk_D, ct); ss_x = X25519(xsk_D, xpk_S); TH1, keys
   open sealed_S (tag valid?); parse idBlock_S strictly
   mac_S valid (constant-time)?  sig_S valid under idPub_S?
   idPub_S != own idPub, userId_S != own userId; identity policy (§12)?
                                   any failure → ABORT, fail
   TH_D, sig_D, mac_D; sealed_D; stage-2 keys, SAS
D → S  FINISH = sealed_D
S: open sealed_D (aad = TH_S); parse idBlock_D strictly
   mac_D valid?  sig_D valid under idPub_D?
   idPub_D != own idPub, userId_D != own userId; identity policy (§12)?
                                   any failure → ABORT, fail
   stage-2 keys, SAS
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

Stage 1 — the handshake, before either identity is known:

```
TH1 = SHA-256( L_TRANSCRIPT ‖ lp32(qrBytes_i) ‖ lp32(helloBody)
               ‖ lp32(offerBody) ‖ lp32(ct) )
IKM = ss_kem[32] ‖ ss_x[32] ‖ nonce_S[32] ‖ nonce_D[32]
PRK1    = HKDF-Extract( salt = TH1, IKM )
K_enc_S = HKDF-Expand(PRK1, L_ENC_S, 32)      K_enc_D = HKDF-Expand(PRK1, L_ENC_D, 32)
K_mac_S = HKDF-Expand(PRK1, L_MAC_S, 32)      K_mac_D = HKDF-Expand(PRK1, L_MAC_D, 32)
```
`qrBytes_i` is the exact 85-byte QR of the frame named in HELLO (the
displayer rebuilds it from `(sessionId, commitment, i, frameKey_i)`);
bodies are exactly as sent, without the type byte.

Identities — each side signs and MACs a transcript that chains everything
before it plus its own identity block (SIGMA-I):

```
TH_S  = SHA-256( L_TH_S ‖ TH1 ‖ lp32(idBlock_S) )
sig_S = Ed25519(idPriv_S, L_SIG_S ‖ TH_S)      mac_S = HMAC-SHA256(K_mac_S, TH_S)
TH_D  = SHA-256( L_TH_D ‖ TH_S ‖ lp32(idBlock_D) )
sig_D = Ed25519(idPriv_D, L_SIG_D ‖ TH_D)      mac_D = HMAC-SHA256(K_mac_D, TH_D)
```

Stage 2 — the final keys, bound to the whole transcript including both
identities:

```
PRK2        = HKDF-Extract( salt = TH_D, IKM = PRK1 )
K_confirm_S = HKDF-Expand(PRK2, L_CONFIRM_S, 32)
K_confirm_D = HKDF-Expand(PRK2, L_CONFIRM_D, 32)
sasBytes    = HKDF-Expand(PRK2, L_SAS, 8)
PSK         = HKDF-Expand(PRK2, L_PSK, 32)
confirm_S = HMAC-SHA256(K_confirm_S, L_CONFIRMED)
confirm_D = HMAC-SHA256(K_confirm_D, L_CONFIRMED)
SAS = decimal( u64be(sasBytes) mod 1 000 000 ), zero-padded to 6 digits
```

PRK1, the stage-1 keys, TH values and PRK2 are zeroized once the PSK is
handed over (or on any failure).

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
- otherwise, the address book holds an identity key for `userId` and it
  equals neither presented key (`ContactsStore.pubkey` may hold either the
  X25519 key from an identity-QR scan or the Ed25519 key a call filled in)
  → **accept with warning**. Best effort only: `encPub` is signed into the
  transcript but its private key is never proven, so a match is not proof of
  identity — only the Ed25519 checks (pins, server set) are;
- otherwise → accept.

Server check (informative, host-supplied): while the SAS is on screen the
app fetches the Ed25519 identity keys the claimed account published
(`GET /api/v1/users/{id}/identity-key?all=1`). The presented `idPub` in that
set → "account verified"; a non-empty set without it → red warning; empty /
offline / no answer within 5 s → "could not verify". "Confirm" waits for the
answer (at most 5 s).

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
- the app adds the peer as a contact (userId + encPub) **only if missing**,
  marked verified only when the server check confirmed the account; a known
  contact's stored key, name and verified state are never changed by a
  pairing.

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
from them is checked byte-for-byte. Both identities are real Ed25519 keys
from fixed seeds (`displayerSigningSeed`, `scannerSigningSeed`), so the
vector's signatures verify, and RFC 8032 signers (BouncyCastle) reproduce
them exactly; CryptoKit signs with randomness, so the Swift test verifies
them instead. The vector pins both sealed boxes byte-for-byte (AES-GCM with
the fixed zero nonce is deterministic), the full ACCEPT and FINISH messages,
ABORT and BUSY, and lists valid and invalid userIds for the §8 grammar. Regenerate with
`python3 scripts/kat/gen_proximity_pairing_kat.py`.
