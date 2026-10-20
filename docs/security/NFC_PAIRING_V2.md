# NFC pairing v2: identity proof, transcript-bound SAS and mutual confirmation

Status: design, not implemented. Replaces the NFC tap exchange used today between
an iPhone (reader) and an Android phone (card emulation), and between two Android
phones (one reader, one card). Both apps change together; there is no
compatibility mode with v1. Every byte, label and check below is normative unless
marked informative. Test vectors: `nfc-pairing-kat.json`, produced by
`gen_nfc_pairing_kat.py` (section 13).

## 1. Why v1 is replaced

v1 (informative summary; references are to the code as of this writing):

```
reader                                   card (HCE, AID F0BCF1073A5100)
SELECT AID                         ──>   9000
GET_IDENTITY_KEY   80 C4 00 00 20  ──>   idPub_C[32] 9000
PUSH_PEER_IDENTITY 80 C5 00 00 20 idPub_R[32] ──> 9000
KEY_EXCHANGE       80 01 00 00 40 xpk_R[32] entropy_R[32] 40
                                   <──   xpk_C[32] entropy_C[32] 9000
PSK  = HKDF-SHA256(ikm = X25519 ‖ entropy_R ‖ entropy_C,
                   salt = SHA-256(sort(xpk_R, xpk_C)),
                   info = "Q-Audion NFC Collaborative PSK v1", 32)
SAS  = uint32be(HMAC-SHA256("qaudion-sas-v1", sort(idPub_R, idPub_C))[0..4]) mod 10^6
```

Weaknesses:

1. No proof of possession. Each side's Ed25519 identity public key is accepted as
   sent. A person at the tap can present someone else's public key.
2. The SAS covers only the two identity public keys. It is the same six digits at
   every pairing of the same two phones, and it does not depend on the ephemeral
   keys at all. An active relay that forwards both genuine identity keys and runs
   its own X25519 exchange with each phone makes both screens show the same,
   correct-looking code while it holds both PSKs. Calls stay authenticated by the
   identity keys, but the PSK no longer adds the secrecy it is meant to add.
3. A confirmed re-pairing replaces the earlier in-person key of the same peer
   identity. Combined with (1), a person at the tap can get the genuine in-person
   key replaced by one that does not match the real peer.
4. Neither side learns whether the other user confirmed. On the card side the PSK
   is written to the vault and bound to the presented identity while the APDU is
   processed, before any user has compared anything; a rejected or timed-out SAS
   deletes the new key afterwards but does not restore an earlier key that the
   binding already retired.
5. No post-quantum component: the NFC PSK rests on X25519 alone.

## 2. Goals

- Each side proves possession of its Ed25519 identity key by signing the transcript,
  and that proof is verified before anything is stored or bound.
- The SAS is derived from the full transcript (both ephemeral key exchanges, both
  nonces, both identity blocks, the commitment) and from the same key that yields
  the PSK, so equal codes on both screens mean both phones hold the same PSK and
  agree on who is on the other side.
- A man in the middle cannot steer the SAS: the reader commits to its random value
  before the card reveals its own (section 8).
- A key is stored only when the local user confirmed and the other user's
  confirmation was received and verified. An earlier key is replaced only when this
  side also knows the other side has stored the new one.
- Hybrid ML-KEM-1024 + X25519, as in proximity pairing.
- Identities never travel in clear (passive observers learn nothing about who paired).
- Every exchange fits short APDUs (Lc ≤ 255, Le ≤ 256), so no extended-length
  support is needed on either phone.

## 3. Roles, primitives, encodings

R = reader (iPhone, or an Android phone in reader mode). C = card (Android HCE).

- X25519 (RFC 7748). An all-zero shared secret MUST be rejected.
- ML-KEM-1024 (FIPS 203), raw encodings: ek 1568 B, ct 1568 B, ss 32 B. R holds the
  decapsulation key; C encapsulates.
- Ed25519 (RFC 8032): 32-byte public key, 64-byte signature. A peer identity key MUST
  be a canonical encoding (y < p, and not x = 0 with the sign bit set) of a point that
  decodes, and that point MUST lie in the prime-order subgroup (`[ℓ]A = O`). This
  rejects the small-order points, the mixed-order points `A + T` (T a torsion point)
  and non-canonical encodings. The 8-entry small-order table kept from v1 is a fast
  path only; on its own it is not enough. Signature verification is RFC 8032 §5.1.7 with
  canonical `R` and `S < ℓ` required, and the same verification equation on both
  platforms. Each platform pins its library against the published Ed25519 edge-case
  vector set (small-order, mixed-order, non-canonical `R`/`A`/`S`; the set from
  "Taming the many EdDSAs"), so that the two verifiers cannot disagree on a signature.
- SHA-256, HMAC-SHA256, HKDF-SHA256 (RFC 5869). AES-256-GCM with the all-zero
  12-byte nonce (every key seals exactly one message), 16-byte tag appended.
- CSPRNG for all random values; failure is fatal.

`u8`, `u32be`: unsigned, big-endian. `lp32(x) = u32be(len(x)) ‖ x`. Labels are ASCII,
no terminator. `‖` is concatenation.

The identity key is the Ed25519 key the call handshake signs with (Android
`Ed25519DeviceSigner`, iOS `SovereignIdentity.signingPrivate`).

## 4. Constants

| Name | Value |
|---|---|
| AID | `F0 BC F1 07 3A 51 00` (unchanged) |
| CLA | `0x80` for every command except SELECT |
| protocol version | `0x02` |
| ML-KEM chunk | 224 B, 7 chunks for ek and for ct |
| nonces, commitment, MACs, tags | 32 B each |
| userId | 0..64 bytes, each in `[A-Za-z0-9._-]` (server ids are UUIDs) |
| handshake timeout (C) | 10 s from EK_PUT[0] to REVEAL |
| user confirmation timeout | 120 s from REVEAL |
| card keeps a committed ceremony | 120 s after its pending store, while the screen is open; afterwards CONFIRM and FINALIZE get `03` and the pending key stays (section 9) |
| handshakes per arming (C) | 1: a handshake that went past HELLO and did not end with a valid REVEAL disarms the card screen (section 6) |
| reader CONFIRM poll | every 250 ms, at most 20 s per field |
| HELLO round-trip limit (R) | 500 ms initial value; logged always, to be calibrated and tightened |

Labels:

```
L_TH1        = "qaudion-nfc-v2/transcript"
L_COMMIT     = "qaudion-nfc-v2/commit"
L_TH_C       = "qaudion-nfc-v2/transcript-card"
L_TH_R       = "qaudion-nfc-v2/transcript-reader"
L_ENC_C      = "qaudion-nfc-v2/enc-card"        L_ENC_R     = "qaudion-nfc-v2/enc-reader"
L_MAC_C      = "qaudion-nfc-v2/mac-card"        L_MAC_R     = "qaudion-nfc-v2/mac-reader"
L_SIG_C      = "qaudion-nfc-v2/sig-card"        L_SIG_R     = "qaudion-nfc-v2/sig-reader"
L_CONFIRM_C  = "qaudion-nfc-v2/confirm-card"    L_CONFIRM_R = "qaudion-nfc-v2/confirm-reader"
L_SAS        = "qaudion-nfc-v2/sas"
L_PSK        = "qaudion-nfc-v2/psk"
L_CONFIRMED  = "qaudion-nfc-v2/user-confirmed"
L_REJECTED   = "qaudion-nfc-v2/user-rejected"
L_FINAL      = "qaudion-nfc-v2/finalize"
L_LOG        = "qaudion-nfc-v2/log"
```

Identity block:

```
idBlock = idPub[32] ‖ u8(n) ‖ userId[n]          (33 + n bytes, n ≤ 64)
```

Parsers MUST check exact lengths, `n ≤ 64`, the userId alphabet, and no trailing
bytes. `n = 0` means the phone has no account id.

## 5. Commands

| INS | Name | Data (R→C) | Response data (C→R) |
|---|---|---|---|
| A4 (CLA 00) | SELECT | AID, Le 00 | `u8(0x02)` |
| 30 | EK_PUT | P1 = chunk index 0..6, P2 = 7, ek chunk [224] | none |
| 31 | HELLO | `u8(0x02) ‖ xpk_R[32] ‖ commit_R[32]` (65 B), Le 40 | `xpk_C[32] ‖ nonce_C[32]` (64 B) |
| 32 | CT_GET | P1 = chunk index 0..6, P2 = 7, Le E0 | ct chunk [224] |
| 33 | AUTH_C | none, Le 00 | `sealed_C` (145 + n B) |
| 34 | REVEAL | `sealed_R` (177 + n B) | none |
| 35 | CONFIRM | `u8(decision) ‖ tag[32]`, Le 00 | `u8(state) ‖ [tag_C[32]]` |
| 36 | FINALIZE | `final_R[32]`, Le 00 | `u8(state)` |

```
sealed_C = Seal(K_enc_C, aad = TH1,  idBlock_C ‖ sig_C[64] ‖ mac_C[32])
sealed_R = Seal(K_enc_R, aad = TH_C, idBlock_R ‖ nonce_R[32] ‖ sig_R[64] ‖ mac_R[32])
```

CONFIRM decision: `0x01` confirm (tag = `confirm_R`), `0x02` reject (tag = `reject_R`).
CONFIRM/FINALIZE state: `0x00` pending (C's user has not decided, or C has not
finished storing), `0x01` confirmed (CONFIRM: followed by `confirm_C`), `0x02`
rejected (followed by `reject_C`), `0x03` no such ceremony, `0x04` aborted
(acknowledges a reader reject; no tag).

Status words from C: `9000` ok; `6700` wrong length; `6A80` bad data (version,
encoding, decision byte, identity block); `6A86` bad P1/P2; `6982` authentication
failed (box, MAC, signature, commitment); `6985` not allowed now (ceremony screen
not open, command out of order, another ceremony in progress); `6D00` unknown INS
(this is also what a v1 command gets); `6F00` internal error. During tap 1 any status
word other than `9000` ends the ceremony on both sides. A CONFIRM or FINALIZE whose tag
matches no staged ceremony (for example one from a second reader) gets `9000` with
state `03` and does not touch the staged ceremony: the card cannot tell readers apart
other than by the tag. A reader that receives no data byte from SELECT, or a byte
other than `0x02`, stops and tells the user to update the other phone's app.

The states `00`, `03`, `04` and the status words `6F00` and `6985` are not
authenticated. On any of them the reader only reports, waits or discards its own
staged ceremony: it never stores and never deletes a key. It treats `02` as the peer's
rejection only if `reject_C` verifies, and `01` as confirmation only if `confirm_C`
verifies. A wrong tag is handled like `03`.

## 6. Flow

Tap 1 (one reader session, about 18 APDUs):

```
R: generate (xsk_R, xpk_R), ML-KEM keypair (ek_R, dk_R), nonce_R
   commit_R = SHA-256(L_COMMIT ‖ nonce_R ‖ lp32(idBlock_R))
R → C  SELECT                              ← 02
R → C  EK_PUT[0..6]                        C: needs the ceremony screen open and armed (else 6985);
                                              after chunk 6: (ct_C, ss_kem) = Encaps(ek_R)
R → C  HELLO(02, xpk_R, commit_R)          C: generate (xsk_C, xpk_C), nonce_C
                                       ← xpk_C ‖ nonce_C     (R measures this round trip)
R → C  CT_GET[0..6]                        ← ct_C chunks
both:  ss_x = X25519 (reject all-zero); R: ss_kem = Decaps(dk_R, ct_C)
       TH1, PRK1, stage-1 keys (section 7)
R → C  AUTH_C                              ← sealed_C
R:     open sealed_C, parse idBlock_C, identity checks, mac_C, sig_C, pin check
R → C  REVEAL(sealed_R)                    C: open, parse, commitment, identity checks,
                                              mac_R, sig_R  ← 9000
both:  stage-2 keys, SAS, PSK; zeroize ephemeral private keys, dk_R, ss, PRK1
both:  show peer identity + SAS, wait for the local user (120 s)
```

The reader's NFC session ends after REVEAL (on iPhone the system sheet closes,
showing the code in its final message). Users compare the two screens and each
answers on their own phone.

One handshake per arming. The card screen is armed by an explicit action of its user
("ready to pair"). A handshake that went past HELLO and did not end with a valid REVEAL
disarms the card screen. This covers the 10 s handshake timeout, any error, a lost
field and a reader that simply stops. The card then shows "the pairing did not
complete" and stays disarmed (every command answered `6985`, token `not_armed`) until
its user starts again. The card logs `nfc.pair.fail` with `timeout`, `order` or the
failing check, so repeated attempts are visible. Section 8 explains why this rule is
needed.

A lost REVEAL response: if the reader's REVEAL transceive fails, the reader cannot
know whether the card accepted it. It shows its code anyway and lets the confirmation
settle it: if the card never accepted, CONFIRM gets `03`, and nothing is stored on
either side without a verified `confirm_C`. AUTH_C and REVEAL are never repeated within
a ceremony; a repeat is `6985` and ends it. If a future revision allows a retry, the
sender MUST resend the cached bytes and never seal again: a randomized Ed25519 signer
would put a second plaintext under the same key and the all-zero nonce.

A repeated SELECT (iOS sends its own SELECT at discovery, then the app sends one) is
answered `02` and never resets a staged ceremony. `selectData` is the data byte of the
SELECT the reader app itself sent.

Confirmation (tap 2 on iPhone; an Android reader may still be in the same field and
then skips the new SELECT):

```
R user confirms → R → C SELECT, then CONFIRM(01, confirm_R), repeated every 250 ms
C on CONFIRM:  verify tag against its own K_confirm_R (constant time)
               C user not decided yet            ← 00 (pending); C shows "the other
                                                    person confirmed"
               C user confirmed, store not done  ← 00 (pending)
               C user confirmed, stored          ← 01 ‖ confirm_C
               C user rejected                   ← 02 ‖ reject_C
R on 01: verify confirm_C → store and finalize (section 9) → FINALIZE(final_R)
C on FINALIZE: verify → finalize (section 9)                    ← 01
R user rejects → R discards everything. An Android reader still in the field sends
                 CONFIRM(02, reject_R); C aborts and answers 04. An iPhone does not
                 ask for a tap to reject; C times out instead.
```

C answers a CONFIRM after a fresh SELECT by matching the tag against the one staged
ceremony; a tag that matches nothing gets `03`. Repeated CONFIRM and FINALIZE are
idempotent. If the 20 s poll ends while C is still pending, R keeps its staged state
until its own 120 s timeout and offers "hold the phones together again".

Ordering: a command not valid in the current state is answered `6985` and aborts the
ceremony, with these exceptions, all idempotent: CT_GET may be repeated for any index;
the last EK_PUT may be repeated with identical bytes (a reader retrying after a
transceive error); CONFIRM and FINALIZE may be repeated. EK_PUT chunks MUST arrive in
order 0..6; a chunk out of order is `6985`, a repeated chunk with different bytes is
`6A80`, both abort. After chunk 6 the card runs the FIPS 203 encapsulation-key check
(modulus check) before encapsulating; a failure is `6A80` with token `kem`. A HELLO or
EK_PUT[0] while a ceremony is waiting for confirmation is refused with `6985`; the
user must cancel first (the card never starts a new code by itself while one is on
screen).

FINALIZE retries: after a valid `confirm_C` the reader sends FINALIZE and repeats it
(every 250 ms, inside the same 20 s budget) until it gets `01` or the field is lost.
The card answers `01` to every valid FINALIZE for as long as it keeps the ceremony
(section 4), and a CONFIRM repeated after FINALIZE still gets `01 ‖ confirm_C`. A
FINALIZE whose tag matches nothing gets `03`.

Store failure on the card: if writing the pending key fails, the card answers the
next CONFIRM with `6F00`, aborts the ceremony (token `store_failed`) and shows the
failure; the reader stores nothing and reports that the other phone could not save
the key.

## 7. Key schedule

```
TH1   = SHA-256(L_TH1 ‖ lp32(selectData) ‖ lp32(ek_R) ‖ lp32(helloCmd) ‖ lp32(helloResp) ‖ lp32(ct_C))
PRK1  = HKDF-Extract(salt = TH1, IKM = ss_kem ‖ ss_x)
K_enc_C = HKDF-Expand(PRK1, L_ENC_C, 32)     K_enc_R = HKDF-Expand(PRK1, L_ENC_R, 32)
K_mac_C = HKDF-Expand(PRK1, L_MAC_C, 32)     K_mac_R = HKDF-Expand(PRK1, L_MAC_R, 32)

TH_C  = SHA-256(L_TH_C ‖ TH1 ‖ lp32(idBlock_C))
sig_C = Ed25519(idPriv_C, L_SIG_C ‖ TH_C)          mac_C = HMAC-SHA256(K_mac_C, TH_C)

TH_R  = SHA-256(L_TH_R ‖ TH_C ‖ lp32(idBlock_R) ‖ nonce_R)
sig_R = Ed25519(idPriv_R, L_SIG_R ‖ TH_R)          mac_R = HMAC-SHA256(K_mac_R, TH_R)

PRK2  = HKDF-Extract(salt = TH_R, IKM = PRK1 ‖ nonce_R ‖ nonce_C)
K_confirm_R = HKDF-Expand(PRK2, L_CONFIRM_R, 32)   K_confirm_C = HKDF-Expand(PRK2, L_CONFIRM_C, 32)
sasBytes    = HKDF-Expand(PRK2, L_SAS, 8)
PSK         = HKDF-Expand(PRK2, L_PSK, 32)
SAS         = decimal(u64be(sasBytes) mod 1 000 000), zero-padded to 6 digits

confirm_R = HMAC(K_confirm_R, L_CONFIRMED)   reject_R = HMAC(K_confirm_R, L_REJECTED)
final_R   = HMAC(K_confirm_R, L_FINAL)
confirm_C = HMAC(K_confirm_C, L_CONFIRMED)   reject_C = HMAC(K_confirm_C, L_REJECTED)
logTag    = lowercase hex of the first 4 bytes of SHA-256(L_LOG ‖ TH1)   (8 hex characters)
```

`selectData` is the one version byte; `helloCmd`/`helloResp` are the data fields as
sent, without header or status word. Signatures are never hashed into a transcript:
an Ed25519 signature can be produced in many valid forms, so including it would hand
the signer a free variable. The stored key fingerprint stays `SHA-256(PSK)`, as for
every other PSK.

What binds what: sig_C and mac_C cover TH1, so the card signs both key exchanges and
the reader's commitment. sig_R and mac_R cover TH_R, so the reader signs everything
including the card's identity block. confirm_C and confirm_R are keyed from PRK2, so
each confirmation also proves that its sender derived the same PSK from the same full
transcript.

## 8. Why the commitment

Without it, whoever speaks last could try many values (a different userId spelling, a
different nonce) until the code on one victim's screen equals the code on the
other's: a million SHA-256/HMAC evaluations take well under a second. With it:

- the reader fixes `nonce_R` and `idBlock_R` (inside `commit_R`) before it sees
  anything chosen by the card;
- the card sends everything it contributes (`xpk_C`, `nonce_C`, `ct_C`, `idBlock_C`)
  before the reader opens the commitment, and nothing after;
- signatures are not in the SAS input (section 7).

A man in the middle therefore has to fix all its values towards each victim before
it learns that victim's random value, and the two codes match with probability about
10⁻⁶ per attempt.

What an attempt costs differs between the two sides.
- Towards the real reader, the attacker is the card. It learns the reader's code only
  when the reader already shows it, so each attempt is a code on the reader's screen
  and is seen by the reader's user.
- Towards the real card, the attacker is the reader, and the reader learns its code
  BEFORE it reveals. After AUTH_C it holds PRK1, its own committed `nonce_R` and the
  card's `nonce_C`, so it can compute the card's code, compare it with the code it
  already knows from the other victim, and, on a mismatch, never send REVEAL and start
  over. The card shows nothing before a valid REVEAL. Without a limit, that is about
  one silent attempt per second for as long as the other victim waits (about 100, so
  p ≈ 10⁻⁴).

The one-handshake-per-arming rule (section 6) removes the silent retries. Every
attempt against the card now needs its user to start again by hand after a visible
failure. The bound is back to 10⁻⁶ per action of the card's user. A mismatch on either
side is never retried automatically. Even a successful attempt only pairs each victim
with the attacker's own identity: the identity proof prevents showing the other
victim's.

## 9. Checks, storage and replacement

Reader, on AUTH_C, in this order: open (else `open_failed`), parse (`length`,
`user_id`), identity checks (`identity_self` if equal to its own key,
`identity_invalid` if not canonical or not in the prime-order subgroup, section 3), `mac`, `signature`, then the
pinned-key check when a contact-targeted re-pairing supplied the identity key stored
for that contact (`peer_identity_changed`). Card, on REVEAL: open, parse, `commitment`, identity
checks, `mac`, `signature`. Opened plaintexts MUST have exactly the expected length (no
trailing bytes, `length`). Any failure: the side that detected it stops, zeroizes,
stores nothing; the card answers `6982` or `6A80` and disarms (section 6). No peer
identity is shown or logged before its MAC and signature have verified. Every
comparison of a commitment, MAC or tag is constant time; the card matches an incoming
CONFIRM or FINALIZE tag against every candidate it holds, never with an early exit.

The identity policy of proximity pairing (comparison with pinned keys of the same
account and with the identity keys the account publishes) applies to the verified
idBlock and drives the same warnings on the confirmation screen. A completion never
rewrites a known contact.

Nothing is written to any vault before both of these hold on that side: its own user
confirmed, and the other side's `confirm` tag was received and verified.

Storage follows the two-step rule of CALL_KEY_PRIORITY.md section 4a: store, then
finalize. Here "the keys of that device" means the NFC keys bound to the verified peer
identity key; keys of the other method and keys of another identity key are never
touched. Every stored key carries a local, monotonically increasing store sequence
number, so "stored before" is exact and does not depend on the clock.

Store. The new key is stored with origin NFC, bound to the verified peer identity key
(and the device witness, as today). It takes the place in the call-key list and the
"placed by hand" mark of the highest-ranked key of that device. That key moves directly
below it, without the mark, and is "retiring", like every other earlier key of that
device. A retiring key is a live key: it is advertised and can be selected. When the
device has no key yet, the new key is placed as in CALL_KEY_PRIORITY.md section 3.
Storing deletes nothing.

Finalize. Finalizing a key deletes every key of that device stored before it, and
never a key stored after it. A side finalizes a key only on evidence that the other
phone holds it:

- F1, the pairing itself. The reader finalizes on a verified `confirm_C` (the card
  sends it only after its store succeeded); the reader therefore stores and finalizes
  in one step. The card finalizes on a verified FINALIZE.
- F2, a call. The evidence is a call round with that device whose handshake signature
  verified under the identity key the new key is bound to, and whose peer key
  confirmation MAC verified (WIRE_SPEC §3.7.1, KCMAC). In that round, either (a) the
  agreed PSK (WIRE_SPEC §3.3, `selectedPskFingerprint` resolved to the local key) is
  the new key, or (b) the peer's signed advertisement matched the new key through a v3
  tag (WIRE_SPEC §3.3.1). A match against the static fingerprint is not evidence,
  because the static fingerprint is not keyed. (a) proves possession because the
  agreed PSK is the salt of the session key that KCMAC is keyed from; (b) because the
  tag is an HMAC keyed by the PSK over this call's signed values.

The card stores when both confirmations hold, and finalizes on F1 or F2. If the card
finalizes any key of that device (by a call) while it still holds a committed ceremony
for that device, it ends that ceremony first: from then on its CONFIRM and FINALIZE get
`03`. The key that ceremony stored stays, since it was stored after the finalized one.

After a key has been stored, nothing deletes it except finalizing a key stored later,
or the user deleting it from Key management. That includes the moment the card has
emitted `confirm_C`: no timeout, cancel, screen close, lost field, failed later
pairing or timer deletes it. Key management shows a key that is not finalized as
waiting for the other phone, and warns before deletion that it may be the only key the
other phone holds.

Losses, both phones starting with K0:

| # | Event | Reader | Card | Common |
|---|---|---|---|---|
| 1 | abort before REVEAL, reject, or timeout | K0 | K0 | K0 |
| 2 | store failure on the card | K0 | K0 | K0 |
| 3 | nothing lost | K1 | K1 (FINALIZE deleted K0) | K1 |
| 4 | FINALIZE lost | K1 | K1, K0 retiring | K1; the card finalizes at the first call that proves K1 (F2) |
| 5 | `01 ‖ confirm_C` lost, re-tap while the card keeps the ceremony | K1 | K1 | K1 |
| 6 | `01 ‖ confirm_C` lost, no re-tap | K0 | K1 waiting, K0 retiring | K0 |
| 7 | the card stores after the reader's 120 s or 20 s poll ended | K0 | K1 waiting, K0 retiring | K0 |
| 8 | row 4, then ceremony 2 stores K2 on the card with `confirm_C` lost, then a call, then a re-tap | K1 (the re-tap gets `03`) | K2 waiting, K1 (the call finalized K1 and deleted K0, then ended ceremony 2) | K1 |

The common key is decided by mutual selection: a call uses the first key of the
caller's advert that the other side also holds, so a key only one side holds is never
selected. A key waiting on one side (rows 6 and 7) is never selected and never
finalizes; it stays until the user deletes it or a later pairing of that device
finalizes. While a KMS key or another common key ranks above the in-person keys, F2(a)
does not happen. Until advertisements carry v3 tags, the earlier key then simply stays
as retiring, which is harmless.

A key whose identity is unknown is never replaced. A pairing with another device of the
same person (another identity key) is a new key.

## 10. User interface (informative, but the rules are not)

Both phones show the peer's name (the known contact for the verified identity, else
"unknown phone") and the SAS as `123 456`. The rule for users: confirm only when both
screens show the same code at the same time. Each side shows the other user's
decision as soon as it knows it: the card when CONFIRM arrives, the reader in the
CONFIRM response. A failed check or a "codes differ" never puts a new code on screen
by itself. On iPhone the confirmation needs a second hold of the phones, which the
screen says explicitly ("Hold the iPhone to the other phone again to finish"). The
card screen has an explicit "ready to pair" state that its user starts. After an
incomplete handshake it shows that the pairing did not complete and needs a new start.
A key that is not yet finalized appears in Key management as waiting for the other
phone.

## 11. Logging and telemetry

Allowed fields: role (`reader`/`card`), step (`select`, `ek`, `hello`, `ct`, `auth`,
`reveal`, `confirm`, `finalize`), result token, status word, HELLO round-trip in ms,
durations, chunk index, `logTag` (to line up both phones' logs of one ceremony),
booleans `peerKnown`, `pinned`, `stored`, `pending`, `replaced`. Never logged: keys,
nonces, transcript hashes, the SAS, MACs, tags, signatures, identity public keys,
userIds, fingerprints.

Events: `nfc.pair.start`, `nfc.pair.step`, `nfc.pair.fail` (with one token of:
`version`, `not_armed`, `order`, `length`, `user_id`, `x25519_zero`, `kem`,
`open_failed`, `mac`, `signature`, `commitment`, `identity_self`, `identity_invalid`,
`peer_identity_changed`, `rtt`, `timeout`, `user_rejected`, `peer_rejected`,
`no_ceremony`, `store_failed`, `field_lost`), `nfc.pair.sas_shown`,
`nfc.pair.user` (`confirm`/`reject`/`timeout`), `nfc.pair.peer`
(`confirm`/`reject`/`pending`), `nfc.pair.commit` (`stored`, `pending`, `replaced`),
`nfc.pair.finalize` (`via` = `confirm`/`finalize`/`call`, `deleted` = count).

`logTag` is computed from public APDUs, so a passive observer who recorded the tap can
link it to these logs. That is accepted, given that the logs carry nothing else about
the ceremony. The PSK fingerprint is never logged, even though it is the vault label.

## 12. Residual risks

- A user who confirms without comparing the codes defeats the human check. The
  identity proof still prevents presenting someone else's identity key, so the worst
  case is an extra key with whoever was at the tap, shown under that person's identity.
- A relay that forwards every byte unchanged between two phones that are not together
  learns nothing: both ends derive the same keys from their own ephemeral secrets and
  both see the same code. What it can achieve is an unintended but genuine pairing
  between two real identities, each of which is shown on the other screen. The user
  must therefore check the name shown, not only the code. The relaying device itself
  cannot show the right code (it does not know the keys), so beating the code
  comparison as well needs a live view of the far screen. A relay that changes
  anything (its own ephemeral keys) gives independent codes, which match with
  probability 10⁻⁶ per attempt (section 8). The HELLO round-trip limit is a secondary
  check: the round trip is dominated by processing on the two phones, not by
  distance, so it cannot be tight.
- 6 digits are about 20 bits. That is acceptable only because attempts cannot be
  ground offline, and each attempt costs a visible action of a user: a code on the
  reader's screen, or a manual restart on the card (section 8).
- An active party at the tap learns the other side's identity. The card reveals its
  identity block, sealed, to any reader that completes the handshake while its
  ceremony screen is open, because the card answers AUTH_C first. The reader reveals
  its own to any card that returned a valid AUTH_C for some identity, including the
  attacker's own. Passive observers learn nothing.
- Ed25519 identity proofs are classical; they only need to hold at pairing time.
- Lost final messages leave a not-yet-finalized key on the card until the next call
  that proves it. A key that only one side holds stays until the user deletes it
  (section 9). Such keys are advertised, which makes the advert longer and the number
  of keys visible to the peer; they are never cleaned up by a timer.
- A legitimate tap whose field is lost mid-handshake disarms the card screen, and its
  user must start again. This is the price of rule 6 ("one handshake per arming").

## 13. Test vectors

`nfc-pairing-kat.json` holds one full exchange (all inputs, every intermediate value,
every APDU of both taps as bytes), the transcript hash and SAS of a second session with
the same identities, and negative cases: substituted identity key, replayed signature,
tampered box, MAC under the wrong key, commitment mismatch (identity and nonce), self
identity at AUTH_C and at REVEAL, small-order, mixed-order and non-canonical identity
keys, REVEAL with trailing bytes, the reject flow, userId too long and with a bad
character, pinned
identity changed, all-zero X25519, confirmation tags that must not cross-verify, a
two-session man in the middle (different codes, each victim sees the attacker's
identity), the per-session SAS against the static v1 SAS, and framing errors with their
status words (including EK_PUT ordering and repetition, an encapsulation key that
fails the FIPS 203 modulus check, and FINALIZE with no ceremony). The APDU list also
shows a repeated FINALIZE and a CONFIRM repeated after FINALIZE. The reader's ML-KEM key
pair is real, from a fixed FIPS 203 seed; the ciphertext is fixed bytes and the
shared secret is what decapsulation returns for it (implicit rejection), so a reader
can check its decapsulation but a card takes ct and ss as given. Signatures are
deterministic RFC 8032; a randomized signer must check that the vector signatures
verify and that its own verify, not that they are equal. Both apps copy the file byte
for byte and pin its SHA-256 in their tests.

The storage rule of section 9 is pinned by the loss sequences in
`call-key-priority-cases.tsv` (CALL_KEY_PRIORITY.md section 6, operations `~X>Y` and
`!Y`), which both apps run.

## 14. Implementation requirements

- CoreNFC: the AID is listed in `com.apple.developer.nfc.readersession.iso7816.select-identifiers`.
  Tap 1 runs inside one reader session, with a time budget per APDU; tap 2 is a new
  session started by a user action in the foreground. `expectedResponseLength` is 224
  for CT_GET and 256 elsewhere. "Session invalidated" and "tag connection lost" are
  `field_lost`, never a rejection.
- Android HCE: the staged ceremony survives `onDeactivated` and a re-created service
  (an app-scoped holder; pending keys live in the vault). Every command is answered
  `6985` when the ceremony screen is not open and armed. The AID category is `other`;
  check routing conflicts with other HCE apps.
- ML-KEM: raw encodings only, never SPKI. The card performs the FIPS 203 modulus check
  itself if the library in use does not (decode the 12-bit coefficients, each < 3329,
  re-encode, compare). The reader checks that ct is exactly 1568 B and does not add a
  separate "bad ct" path: implicit rejection shows up as `open_failed` at AUTH_C.
  `dk_R` is zeroized.
- X25519: compare the shared secret with 32 zero bytes explicitly; do not rely on the
  library to refuse a small-order point.
- Randomness: fresh `nonce_R`, `nonce_C`, X25519 and ML-KEM keys for every handshake,
  never reused across a retried one.
- Timers use clocks that keep counting during sleep (`CLOCK_MONOTONIC`,
  `SystemClock.elapsedRealtime`).
