# Q-Audion Wire Specification — Cross-Platform Contract

Authored 2026-05-06 after the consolidation pass that brought Android,
Server, Desktop and iOS back to `main` in lock-step. This document is
the single source of truth for the on-the-wire contracts every client
must honour. Whenever a server-side wire shape changes, this file is
the gating commit — the four client repos pull the updated spec and
adapt before shipping.

Mirror copies live at the root of:
- `apps/bcrypto-server/WIRE_SPEC.md` (this file)
- `apps/qaudion-android-new/WIRE_SPEC.md`
- `apps/qaudion-desktop/WIRE_SPEC.md`
- `apps/qaudion-ios/WIRE_SPEC.md`

---

## 1. HKDF labels (canonical strings)

Every label is a UTF-8 byte string. `salt` and `info` are passed
**verbatim** to `HKDF-SHA256`. Any platform that emits a different
string for the same operation derives a different key and the AEAD
auth tag fails.

| Operation | Salt | Info |
|---|---|---|
| Hybrid PQC handshake (per-call) | `q-audion-hybrid-pqc-v1` | `q-audion-session-key` |
| Audio frame chain key | (per-session) | `q-audion-frame-key` |
| Audio frame chain key (versioned) | (per-session) | `q-audion-frame-key-v1` |
| Video frame chain key | (per-session) | `q-audion-video-frame-key` |
| Video frame chain key (versioned) | (per-session) | `q-audion-video-frame-key-v1` |
| Root ratchet | (per-session) | `q-audion-root-ratchet` / `-v1` |
| PSK mix into session key | `q-audion-psk-mix` | `q-audion-session-key` (hybrid path) |
| Per-contact message PSK derivation | callId UTF-8 | `q-audion-msg-psk-v1` |
| Message AEAD key | random 32 B | `q-audion-msg-key` |
| File key derivation (v2) | `file_id` (16 B) | `qaudion-file-v2-enc` / `qaudion-file-v2-nonce` / `qaudion-file-v2-commit` (§12) |
| Forward-secrecy frame derivation | (per-session) | `q-audion-fs-frame` |
| ZK auth proof key | salt | `q-audion-zk-auth` |
| Password blinding | salt | `q-audion-pw-blind` |
| Next-chain key derivation | (per-session) | `q-audion-next-chain` / `-v1` |
| KMS classical PSK envelope | `bcrypto-kms-salt-v1` | `bcrypto-kms-psk-v1` |
| KMS binding-hybrid PSK envelope | `bcrypto-kms-hybrid-salt-v1` | `bcrypto-kms-hybrid-pqc-v1` |
| KMS legacy KEM-hybrid PSK envelope | `bcrypto-kms-hybrid-salt-v1` | `bcrypto-kms-hybrid-pqc-v1` |

**Note** — the unversioned and `-v1` variants of the same label both
appear in the codebase for historical reasons. Active code paths MUST
use one consistent variant per operation; cross-platform KAT vectors
are in `tools/kat/` (planned).

## 1.1 SRTP master + salt labels (E2EE media seal — clients only)

The PQC RTP frame sealer (`PqcRtpFrameSealer`, the inner AEAD layer on
the BcryptoWsRelay / WebRTC audio path) derives a 32-byte SRTP master
key on the ENDPOINTS only. The server is a pure E2EE relay and derives
NO SRTP key material (no SRTP HKDF label exists anywhere in
`bcrypto-server`; the firmware SPE comment confirms "the session key
NEVER leaves the SPE").

| Field | Value | Length |
|---|---|---|
| HKDF salt | `qaudion-srtp-salt-v1` | 20 B |
| HKDF info (base) | `q-audion-srtp-master-v1` | 23 B |
| HKDF output L | 32 | — |

```
srtp_master = HKDF-SHA256(
  IKM  = pqcSessionKey (32 B from §3 PQC handshake),
  salt = "qaudion-srtp-salt-v1",
  info = infoString,   // see binding rules below
  L    = 32
)
```

**`info` binding rules (M-15 + W574x directional):**
- empty callId (back-compat / tests): `q-audion-srtp-master-v1`
- per-call binding (M-15): `q-audion-srtp-master-v1:<callId>`
- directional per-direction keys (W574x, prevents A↔B nonce reuse):
  - A→B: `q-audion-srtp-master-v1:<callId>:a2b`
  - B→A: `q-audion-srtp-master-v1:<callId>:b2a`
  - Role "A" = the peer whose userId is lexicographically smaller
    (pure function, no extra signalling).

Per-frame: AES-256-GCM, nonce = `4 zero bytes || 8-byte BE counter`
(starts at 0, increments per packet); wire layout `nonce(12) ||
ciphertext || tag(16)`.

All three platforms MUST produce byte-identical seals. Cited code:
- Android: `PqcRtpFrameSealer.kt:38` (salt), `HkdfDerive.kt:77` (info
  base), `PqcRtpFrameSealer.kt:86-87` (directional).
- iOS: `PqcRtpFrameSealer.swift:73` (salt), `:34` (info), `:31-36` (L=32).
- Desktop: `src/main/calling/PqcRtpFrameSealer.ts` (mirror).

---

## 2. KMS package wire formats

The server's `/api/v1/kms/pending` endpoint returns a JSON envelope:

```json
{
  "keys": [
    {
      "key_id":            "<uuid>",
      "key_name":          "<human label>",
      "fingerprint":       "<12 hex chars>",
      "status":            "pending",
      "encrypted_package": "<base64 — full serialised wire blob>",
      "ephemeral_pubkey":  "<base64 — 32 bytes X25519>",
      "nonce":             "<base64 — 12 bytes GCM>",
      "created_at":        "<RFC3339>"
    }
  ]
}
```

`encrypted_package` is the FULL wire blob — clients MUST drive the tier
classification off `encrypted_package` length (`ephemeral_pubkey` and
`nonce` are convenience fields for clients that prefer split parsing).

### 2.1 Classical (X25519-only) — 60+ bytes

```
ephPubKey(32) || nonce(12) || ciphertext+tag(N+16)
```

```
key = HKDF-SHA256(
  IKM  = X25519-ECDH(devicePriv, ephPubKey),
  salt = "bcrypto-kms-salt-v1",
  info = "bcrypto-kms-psk-v1",
  L    = 32
)
PSK = AES-256-GCM-Decrypt(key, nonce, ciphertext+tag, no-AAD)
```

### 2.2 Binding-Hybrid — exactly 92 bytes (the production default since 2026-05-02)

Same wire shape as classical; the tier is distinguished only by the
HKDF IKM. Clients that don't have an ML-KEM pubkey on file CANNOT
decrypt this tier (and the server will not emit it for those devices).

```
ephPubKey(32) || nonce(12) || ciphertext+tag(48)
```

```
key = HKDF-SHA256(
  IKM  = X25519-ECDH(devicePriv, ephPubKey) || SHA-256(deviceMlkemPubKey),
  salt = "bcrypto-kms-hybrid-salt-v1",
  info = "bcrypto-kms-hybrid-pqc-v1",
  L    = 32
)
PSK = AES-256-GCM-Decrypt(key, nonce, ciphertext+tag, no-AAD)
```

**Crypto note (binding-only, not true hybrid)** — the `SHA-256(pqPub)`
mix binds the ciphertext to the IDENTITY of the registered ML-KEM key
(defence in depth against an attacker substituting the key under the
same userId), but does NOT provide post-quantum confidentiality. The
classical X25519 ECDH is still the only secrecy primitive in this tier.
True PQ confidentiality lives in §2.3 (decapsulated kemSecret in IKM)
and in the per-call PqcKeyExchange handshake (§3).

### 2.3 Legacy KEM-Hybrid — 1628+ bytes

Real PQ confidentiality. Kept on the wire for backwards compatibility
with packages issued before the binding rollout.

```
ephPubKey(32) || kemCT(1568) || nonce(12) || ciphertext+tag(N+16)
```

```
key = HKDF-SHA256(
  IKM  = X25519-ECDH(devicePriv, ephPubKey)
       || ML-KEM-1024-Decap(deviceMlkemPriv, kemCT),
  salt = "bcrypto-kms-hybrid-salt-v1",
  info = "bcrypto-kms-hybrid-pqc-v1",
  L    = 32
)
```

### 2.4 Client tier selection

```
if pkgLen >= 1628:        decryptLegacyKemHybrid
else if pkgLen >= 60:     try classical
                          on AEAD auth failure AND mlkemPub registered:
                            decryptBindingHybrid
                          else: bubble the auth failure
else:                     reject ("too short")
```

### 2.5 Acknowledge contract

`/api/v1/kms/pending` returns delivered-but-not-acknowledged keys on
every poll until the client explicitly acknowledges via:

```
POST /api/v1/kms/acknowledge/<key_id>
```

Without this, transient client errors (base64 parse, GCM auth) on
first delivery would lose the key forever. Status transitions:
`pending → delivered → acknowledged` (or `revoked`). Only
`acknowledged` and `revoked` are removed from the pending list.

### 2.6 Device-key registration

```
POST /api/v1/devices/<deviceId>/public_key
{
  "public_key":            "<base64 — 32 bytes X25519>",
  "mlkem_encapsulation_key":"<base64 — 1568 bytes ML-KEM-1024 pub, OPTIONAL>",
  "key_type":              "x25519"
}
```

Re-publish is idempotent. If `mlkem_encapsulation_key` is omitted, the
server will only emit classical packages for this device.

Server-side, X25519 and ML-KEM pubkeys live in **separate** bbolt
buckets (`device_pub_keys` and `device_pq_keys`) so registering one
doesn't overwrite the other. The shared `pub_keys_by_user` index
tracks deviceIDs across both.

### 2.7 KMS v2 AAD-bound wire (2026-06-16)

The v2 wrap is wire-compatible in SHAPE with the v1 tiers in §2.1–§2.3
(`ephPub(32) || [ct_pq(1568)] || nonce(12) || ct+tag(48)` — classical
92 B / hybrid 1660 B; see `kms.go:74-76`), but the AES-256-GCM call is
bound to a structured **AAD** instead of v1's `no-AAD` envelope. This
cryptographically binds each wrapped PSK to its key/user/device/epoch/
txn/class so a package cannot be replayed against a different recipient
or key generation.

**v2 AAD byte layout** (server `BuildV2AAD`, `kms.go:84-101`):

```
AAD = "qa-kms-psk-v2"(13)   // ASCII label, no NUL — kms.go:51 (v2AADTag)
    || key_id(16)           // raw 16-byte UUID
    || user_id(16)          // raw 16-byte UUID
    || device_id(16)        // raw 16-byte UUID
    || key_epoch(8, BE)     // uint64 big-endian
    || txn_id(16)           // raw 16-byte UUID
    || key_class_byte(1)    // 0x01 shared / 0x02 hw_only / 0x03 sw_only
                            //   (keyClassByte, kms.go:60-69)
```

Total AAD length = 13+16+16+16+8+16+1 = **86 bytes**.

**v2 HKDF domain separation** (`kms.go:45-47`): info strings bump to
`bcrypto-kms-psk-v2` (classical) / `bcrypto-kms-hybrid-pqc-v2` (hybrid).
Salts unchanged from v1 (`bcrypto-kms-salt-v1` / `bcrypto-kms-hybrid-salt-v1`).

**Difference from v1 (§2.1–§2.3):** v1 calls `AES-256-GCM-Decrypt(key,
nonce, ct+tag, no-AAD)` — the ciphertext is NOT bound to recipient
metadata, so the only binding is the HKDF IKM. v2 keeps the same IKM
derivation but adds the 86-byte AAD above to the GCM tag, so a tampered
or mis-addressed key_id/user_id/device_id/epoch/txn/class fails the auth
tag. Clients MUST reconstruct the identical 86-byte AAD from the envelope
metadata before decrypting a v2 package.

---

## 3. Per-call PQC handshake (`opaque_message` channel)

A 1:1 call runs exactly one handshake dialect: the signed JSON HandshakeBundle
(§3.1), authenticated by the single signed transcript v6 (§3.7), which also
binds both DTLS certificate fingerprints (§3.8) and the caller's SAS commitment
(§3.7.4). There is no dialect negotiation, no fallback and no earlier transcript
version: the transcripts v1-v5, their JSON fields (`signature`, `sigV2`, `sigV3`,
`sigV4`, `sigV5`) and the QUAD binary handshake dialect (§3.2) are removed. Before
launch there is no deployed fleet to stay compatible with, so every client
switches in the same release train (§6, hard switches). A v6 peer ends a v5
OFFER as malformed and a v5 peer rejects `sigV6`: the two do not interoperate.

### 3.1 JSON HandshakeBundle (the single 1:1 handshake dialect)

Wire shape: literal UTF-8 string `"<callId>|<JSON>"` placed verbatim
in the `data` field of an `opaque_message`.

```json
{
  "kind":                   "OFFER" | "ACCEPT",
  "callId":                 "<call uuid>",
  "pqcPublicKey":           "<base64 — ML-KEM-1024 pub, 1568 B>",
  "x25519PublicKey":        "<base64 — X25519 pub, 32 B>",
  "strongBoxPublicKey":     "<base64 — optional StrongBox-bound P-256>",
  "dualCurvePublicKey":     "<base64 — optional X448 pub>",
  "ciphertext": {
    "pqc":       "<base64 — ML-KEM-1024 ciphertext>",
    "x25519":    "<base64 — ephemeral X25519 pub>",
    "strongBox": "<base64 — optional>",
    "dualCurve": "<base64 — optional X448 ephemeral pub>"
  },
  "capabilities": { "ratchetV3": true, ... },
  "pskFingerprints":         ["<sha256 hex>", ...],     // OFFER: offered; ACCEPT: responder's own advert
  "selectedPskFingerprint":  "<sha256 hex>",            // ACCEPT only
  "signerIdentityKey":       "<base64 — Ed25519 pub, 32 B>",
  "rekeyNonce":              "<base64 — 8 B>",
  "rekeyRound":              1,
  "sasCommit":               "<base64 — 32 B; OFFER with rekeyRound 1 ONLY, §3.7.4>",
  "dtlsFingerprint":         "sha-256 AB:CD:...:EF",
  "sigV6":                   "<base64 — Ed25519 signature, 64 B>"
}
```

`ciphertext` is OMITTED in OFFER and PRESENT in ACCEPT.

The following fields are REQUIRED in every OFFER and ACCEPT, including rekey
rounds: `signerIdentityKey`, `capabilities`, `rekeyNonce`, `rekeyRound`,
`dtlsFingerprint` (canonical text form, §3.8.1) and `sigV6` (base64, 64 bytes).
`rekeyRound` MUST be present as a JSON integer in [1, 4294967295] (the initial handshake is 1; the transcript
encodes it as a u32). A bundle that lacks `sigV6`, `dtlsFingerprint` or `rekeyRound`, or whose
`rekeyRound` is 0, negative, fractional, above 4294967295 or not a number, is malformed and ends
the call (§3.8.6). There is no default value: a receiver never reads a missing
`rekeyRound` as 1. `signature`, `sigV2`, `sigV3`, `sigV4` and `sigV5` are removed: a sender MUST NOT
emit them and a receiver MUST NOT consult them (a bundle with `sigV5` and no `sigV6` is malformed). The signature is computed over
the transcript of §3.7, never over the JSON bytes.

`sasCommit` (R-COMMIT-FIELD):

| Message | `sasCommit` |
|---|---|
| OFFER, `rekeyRound` = 1 | REQUIRED: canonical base64 of exactly 32 bytes (§3.7.4) |
| OFFER, `rekeyRound` >= 2 | MUST be absent (any value, even `null`, is malformed) |
| ACCEPT | MUST be absent (any value, even `null`, is malformed) |

- **Canonical base64** (`sasCommit` and the REVEAL payload of §3.7.4): standard alphabet with padding. A string `s` is
  valid iff it decodes to the required length AND `base64encode(decode(s)) == s`. This rejects missing padding, the
  URL-safe alphabet, whitespace and non-zero trailing bits identically on every platform, whatever its base64 decoder
  tolerates.
- A round-1 OFFER without a valid `sasCommit`, a rekey OFFER or an ACCEPT that carries the field, and the FIRST OFFER a
  callee device that has a call context for the `callId` (it rang for it) sees when its `rekeyRound` is not 1
  (R-COMMIT-FIRST-ROUND) are malformed and end the call with
  reason `handshake_malformed` (§3.8.6). An OFFER that arrives before the device has a call context (it overtook the
  `call_incoming`) follows the pending-OFFER rule of §3.7.4.
- Every JSON decode failure of a bundle that was routed as a handshake bundle is malformed as well: the call ends with
  `handshake_malformed` and a hangup on every platform, never with a plain failure that skips the hangup.

### 3.2 QUAD binary frame — handshake dialect RETIRED

The QUAD binary 1:1 handshake dialect is retired (§3.3.1.2): a client MUST NOT
emit a QUAD OFFER or ACCEPT, and MUST drop a received one without acting on it.
The QUAD codec is retained only to carry the non-handshake opcodes, and it must
keep decoding the frame header so that a stray or fabricated handshake frame is
recognised and dropped on purpose.

Wire shape: base64-encoded binary in `data`, starting with
`[4B MAGIC "QUAD"][1B type][1B version=0x01][1B features]`.

Type codes (`uint8`):
- `0x01` OFFER — RETIRED
- `0x02` ACCEPT — RETIRED
- `0x03` DC SDP OFFER
- `0x04` DC SDP ANSWER
- `0x05` DC ICE
- `0x06` AUDIO_DATA
- `0x07` VOICE_ANALYSIS
- `0x08` CALL_HANGUP
- `0x09` KEY_EXCHANGE_OFFER
- `0x0a` KEY_EXCHANGE_ACCEPT

SDP that travels in `0x03` / `0x04` is subject to the same DTLS fingerprint
check as every other SDP (§3.8.3).

### 3.3 PSK fingerprint negotiation

**Fingerprint format (CROSS-PLATFORM CONTRACT — do not deviate):**

```
fingerprint = lowercase_hex( SHA-256(rawPskMaterial) )
            = 64-character UTF-8 string of [0-9a-f] only
```

NOT the user-facing display format some clients expose (e.g. Android's
`displayFingerprint = first 16 hex chars chunked by 4 with dots`). All
4 platforms MUST advertise and compare against the full 64-char SHA-256
hex; the display variant is presentation-layer only.

OFFER advertises `pskFingerprints: [...]` — every locally-eligible PSK
the initiator has (`KeyCreationMethod ∈ {NFC, QR_CODE, MANUAL,
PASSPHRASE, KMS}`, excluding `CALL_DERIVED` rows by name convention).

Responder selects the FIRST fingerprint in the OFFER's advertised
order that it also holds locally:

```
selected = offerSet.first { it in localSet }
```

and echoes this in `selectedPskFingerprint`. The initiator MUST honor
the echoed value verbatim and never recompute. Both sides then mix the
agreed PSK into the session-key HKDF (§1, `q-audion-psk-mix`).

(Superseded the 2026-05-06 lex-ascending rule, which was order-independent
but discarded the caller's PSK priority — see PqcHandshake caller-priority
impl on all 3 platforms. The OFFER advertises `pskFingerprints` already
ORDERED BY PRIORITY (priority 1 = highest), so first-match = highest
mutually-held priority. The choice is platform-independent because every
responder picks from the OFFER's order, not its own local order, and the
initiator honors the echoed fingerprint.)

### 3.3.1 Blinded PSK advertisement (v3)

§3.3's advertisement leaks two things to the relay and to anyone passively
logging signalling:

1. `lowercase_hex(SHA-256(psk))` is a **constant**. Two devices advertise the
   identical string on every call for the life of the key — a permanent
   per-relationship correlator. A signalling log alone partitions the user base
   into "who shares a secret with whom", no key material required.
2. The parallel `pskRoles` array marks which entries came from an NFC tap, i.e.
   **which pairs of users have physically met**.

v3 replaces the advertised value with a per-call HMAC tag. `pskFingerprints`
keeps its type and its 64-lowercase-hex width; only the meaning changes.

```
tag_j = HMAC-SHA256( key = psk_j, msg = tag_preimage_j )[0:32]

tag_preimage_j = "qa-psk-advert-v3"                16 B ASCII, no NUL
              || u8( len(callId_utf8) ) || callId_utf8
              || nonce_sender                      32 B
              || u8( role_j )                       1 B

pskFingerprints[j] = lowercase_hex( tag_j )        64 chars
pskRoles           = OMITTED (null)
```

The label is exactly 16 bytes so the preimage is length-unambiguous with no
separator. `callId` is length-prefixed because the field is free-form; joining a
variable-length value without its length is how `("ab","c")` and `("a","bc")`
collide.

**The nonce is DERIVED, never transmitted:**

```
nonce_sender = SHA-256( "qa-psk-advert-nonce-v3"          22 B ASCII
                      || u8( len(callId_utf8) ) || callId_utf8
                      || sender_ephemeral_x25519_pub )    32 B, fixed width, last
```

`sender_ephemeral_x25519_pub` is the **sender's own** ephemeral X25519 public key
as it appears in the SIGNED bundle: `x25519PublicKey` on the OFFER leg,
`ciphertext.x25519` on the ACCEPT leg. Both are already bound by the §3.7
transcript (`OFFER_v6` binds `LP(x25519Pub)`; `ACCEPT_v6` binds
`LP(ctX25519)`).

This is normative and it is the reason there is no new wire field. A nonce sent
as a plain unsigned field would be a **silent PSK-downgrade oracle**: a relay
flips one byte, the receiver derives different candidate tags, nothing matches,
the PSK drops out of the session key, and both users still see a connected call
with no warning. Deriving it from an already-signed value makes tampering
invalidate the signature instead — at zero new wire bytes and zero transcript
change. Freshness is free: the ephemeral key is per call, so the tag is per call.

**The role is recovered, not read.** The sender folds its own `role_j` into the
preimage and sends `pskRoles` as null. The receiver computes each local secret's
tag under **every** role value `0..255` and looks each up among the received
tags; the value that matches IS the sender's recorded role. The full byte range,
not just the defined roles (`0` ordinary / `1` NFC / `2` QR), for two reasons: a
role disagreement between the two sides must not cost the PSK, and a role added
later must interoperate with an older build without a lockstep release. Cost is
`256 * m` HMAC-SHA256 for `m` local secrets — the tag's secrecy rests on the psk,
not on the role, so a 256-wide search is intended behaviour.

**Selection.** Unchanged in rule, changed in value: the responder picks the
first RECEIVED tag it can reproduce (received order in the outer loop, so the
advertiser keeps its priority) and echoes **that tag verbatim** in
`selectedPskFingerprint`. It MUST NOT echo the static `SHA-256(psk)` — doing so
would put the selected key's permanent correlator back on the wire on every
call and defeat the whole section. The initiator resolves the echoed tag through
the tag→secret map it built when it composed its own advertisement, and MUST
honour it verbatim without recomputing, exactly as in §3.3.

**`advEnc` is unchanged.** `advEnc(list) = u8(m) || (u8(role) || 32B)*m`. A
32-byte tag occupies the slot the 32-byte fingerprint had, and an omitted
`pskRoles` already encodes as all-zero role bytes, so the §3.7 signature covers
the advertisement byte-for-byte with no format change.

**The static fingerprint remains the LOCAL identifier.**
`lowercase_hex(SHA-256(psk))` still keys the vault, `kc_mac`'s
`mixedFingerprints`, the PSK-mix `mix_id`, the UI, and the hw_only §D4 intersect.
Only the wire changes. A receiver MUST translate a matched tag back to its own
static fingerprint before handing it to any of those; skipping the translation
leaves the §D4 hw_only intersect empty and quietly stops enforcing a requirement.

**No capability bit. The dialect is self-describing.**

A receiver MUST attempt BOTH dialects against a received advertisement, v3 first
then §3.3 static, and remember which one produced the match:

```
dialect = v3      if a v3 tag match was found
        = v2      else if a static-fingerprint match was found
        = unknown if neither matched
```

Both attempts are cheap and cannot conflict: a 32-byte HMAC tag equals a
`SHA-256(psk)` only with negligible probability, so trying v2 after v3 widens
what can be matched without ever producing a wrong match.

The responder then **mirrors the dialect it detected** in its own ACCEPT
advertisement — v3 if it matched v3, otherwise static. Consequences:

* The ACCEPT leg has **no mixed window at all**, and needs no negotiation: the
  OFFER's advertisement already says which dialect the initiator speaks.
* **CORRECTED 2026-07-25 (W-UNKNOWNMIRROR).** This section used to claim "there is
  no field for a relay to strip… and a relay cannot produce static fingerprints
  anyway, not holding the keys". That was wrong, and the error was load-bearing:
  DELETING the OFFER's `pskFingerprints` field produces nothing and needs no key
  material. An absent advertisement resolved to `unknown`, and `unknown` used to
  mirror STATIC — so one deleted field made the responder emit the static
  fingerprint of every eligible key it held, plus `pskRoles` marking which of them
  came from a physical NFC tap. Both of the things this section exists to remove,
  from the responder, forced on demand.
* Worse, that path was not attacker-only. `unknown` is the routine outcome whenever
  two peers share no secret — the overwhelmingly common case named below — so the
  static set went out on ordinary untampered traffic and a passive relay could
  harvest it.
* The rule now: the responder mirrors **v3 for every dialect except a real legacy
  peer** (`v2Static`), and falls back to static only when it has no ephemeral of its
  own to blind with, which is a local failure no remote party can induce. A genuine
  legacy peer never reaches the `unknown` branch — it sends static fingerprints, they
  match, and the dialect is `v2Static`.
* Mirroring v3 under `unknown` costs nothing in key agreement: the ACCEPT's
  advertisement is never consumed for PSK selection (the echoed SELECTION is). The
  only thing given up is a pre-phase-A initiator's mutual/NFC-in-common indicator
  going dark.
* Rewriting the initiator's advertisement in place IS covered by the §3.7 signature, and
  both advertisements feed the key-confirmation transcript (§3.7.1). An invalid
  signature aborts the handshake and holds media pending SAS (§3.8.6); a KCMAC that
  does not verify ends the call.
* Every platform now also reports the degraded outcome. Where the notice was
  previously gated on a NON-EMPTY advertisement — making the stripped-field case
  completely silent — it now fires whenever candidates are held and no PSK results,
  and distinguishes ABSENT (possible strip) from EMPTY from unmatched.

`selectedPskFingerprint` is dialect-agnostic because the responder echoes the
RECEIVED element verbatim in both dialects. The initiator knows which dialect it
sent and resolves the echo through the corresponding map (tag→secret for v3,
fingerprint→secret for static).

Rollout was two-phase and per-platform, with only the OFFER emitter needing a
decision. **Both phases are now live on Android, iOS and Desktop (2026-07-25).**

* Phase A — dual-dialect matching and dialect mirroring, while the OFFER still
  emitted §3.3 static fingerprints. No wire change; a peer of any vintage
  unaffected.
* Phase B — the OFFER emits v3 tags. Gated on §3.3.1.1's per-contact latch being
  live everywhere first, which it is.

Consequence of phase B being live, stated so it is not mistaken for a bug: a peer
running a build that predates phase A cannot match a v3 advertisement, so that
call derives WITHOUT a PSK. It still connects, and it MUST say so — an explicit
"PSK not used this call" notice, never a silent derivation. Both legs log it (the
`UNKNOWN with a non-empty peer advert while we hold candidates` branch). The
window closes as each install updates; it does not need a coordinated release,
because the responder mirrors whatever dialect it received.

### 3.3.1.1 Known downgrade: the static fallback is forceable (MITIGATED)

Found by adversarial review during implementation (2026-07-25), confirmed by
walking the code. The mitigation described at the end of this section is
IMPLEMENTED on all three platforms, which is what made phase B safe to enable.

Attacker: the relay, or anyone on path. Prerequisite: it logged this pair's
**old** static fingerprints from any call they made before v3 — those values are
constant for the life of the key, which is the very leak §3.3.1 exists to fix, so
assume any long-lived observer has them.

1. The relay intercepts a v3 OFFER, replaces `pskFingerprints` with the logged
   static fingerprints, and strips the Ed25519 signature. Client policy is
   warn-and-proceed on an absent/bad handshake signature and never to drop the
   call (W-NOBRICK; the SAS is the anti-MITM gate), so the call continues.
2. The responder's v3 match fails, its static match succeeds, and it records the
   peer as speaking the static dialect.
3. It mirrors that dialect, so BOTH sides spend the call on static fingerprints.

The PSK still ends up in the session key on both sides, so this is not a break.
What the relay gets is two things:

* **v3 is switched off for that pair, on demand.** It cannot learn a correlator it
  did not already have, but it can keep confirming the pair on every future call
  rather than losing them to blinding. So v3's unlinkability is NOT robust against
  an active on-path attacker for any pair that ever completed a pre-v3 call.
* **Selection steering.** With the signature stripped and a substituted list, it
  reorders or truncates to choose WHICH shared secret gets selected. This is not
  introduced here — the static dialect has always had it against a warn-only
  peer, and binding the real order in `advEnc` (§3.7) is what closes it — but the
  fallback keeps that door open for pairs whose v3 would otherwise have shut it.

**Mitigation, now implemented: a per-contact "v3 seen" latch.** Once a
contact's advertisement has resolved as v3 even once, refuse the static fallback
for that contact: treat a static advertisement from them as no-match, log it, and
raise the explicit "PSK not used this call" notice. Do NOT drop the call
(W-NOBRICK) — the point is to make the downgrade loud instead of invisible. The
latch is sound because phase A is universal before phase B, so a pair that has
completed one v3 call has no legitimate reason to speak static again. Same shape
as the existing per-contact presence floor, and it belongs in the same store.

### 3.3.1.2 The QUAD 1:1 handshake dialect is RETIRED (advert and all)

**Superseded 2026-07-25 (W-QUADRETIRE).** The section below explains why the blinded advert
was not ported to QUAD, and that reasoning still stands. It has been overtaken by a larger
decision: the QUAD 1:1 handshake dialect is gone entirely. Desktop no longer generates,
sends, or accepts a QUAD OFFER or ACCEPT, and both consume paths are deleted rather than
guarded.

Why the advert fix was not enough. The advert was one field on a dialect that is unsigned,
ML-KEM-only (no X25519 leg), and has no ciphertext binding, no transcript and no key
confirmation. Emptying the advert removed a correlator and left the authentication hole. And
the hole did not need our cooperation: a QUAD OFFER is an unsigned ML-KEM public key and
nothing else, so a relay does not have to intercept one — it can FABRICATE one and send it,
and the responder would have run that unauthenticated handshake against the attacker while
the UI showed an ordinary secure call. Stopping our own emission alone would therefore have
closed nothing; the consume side was the half that mattered.

ML-KEM's implicit rejection is what makes it undetectable from the inside: a substituted
ciphertext yields a valid-looking DIFFERENT shared secret, with no error for any code to act
on.

The dialect had no legitimate user left. Pavel confirmed (2026-07-25) that no Desktop
installs predating the JSON handshake path of 2026-05-26 remain in the fleet; iOS retired its
own QUAD OFFER emitter on 2026-07-12 for a sibling reason; Android's QUAD codec only ever
served the `KEY_EXCHANGE_*` opcodes. Every real caller sends the signed JSON bundle.

Unaffected, and deliberately kept: the `DC_SDP_OFFER` / `DC_SDP_ANSWER` / `DC_ICE` /
`CALL_HANGUP` / `KEY_EXCHANGE_*` opcodes and the QUAD codec itself. Those are the live media,
SDP and first-contact transport. The codec must keep DECODING so a stray or fabricated frame
is recognised and dropped on purpose rather than misparsed.

Sending only one handshake envelope is itself the security property. The old dual-send
reasoning — "we cannot know the peer's platform up front, so send both and let the receiver
pick" — was sound about interop and wrong about trust: the party that picks is the relay,
because it decides which envelope to deliver.

---

### 3.3.1.2 (historical) The QUAD binary transport: advert retired, not ported

§3.3.1 blinds the advertisement in the JSON handshake-bundle dialect (the
`"<callId>|<json>"` `opaque_message` payload) — the one every cross-platform call
uses. The QUAD binary dialect has its own PSK-fingerprint section, its own
selection code, and no dialect of its own: what it carries is static
`SHA-256(psk)`.

**The advertisement there is now empty, and the blinded construction was NOT
ported.** Resolved 2026-07-25 (W-QUADADVERT). Two corrections to the earlier text
in this section, both material:

Reach. Desktop sends BOTH envelopes on EVERY outgoing call — it cannot know the
peer's platform up front — so as long as this list was populated, the constant
correlator shipped on every call to every platform, not on "Desktop↔Desktop only".
Blinding the JSON envelope while this one kept shipping bought nothing on the wire.
(iOS emits no production QUAD OFFER at all, having removed it 2026-07-12; Android
has a QUAD codec but only for the `KEY_EXCHANGE_*` opcodes.)

Why the port was rejected. A derived nonce is only as good as the material it binds
to, and QUAD has no signature, no transcript and no key confirmation — the JSON
path's fail-closed OFFER signature is exactly what makes the same construction safe
there. Binding to the ML-KEM encapsulation key instead was examined and is a
REGRESSION, not a compromise: substituting that key is the one thing a MITM must do
to MITM at all, and after substituting it the recomputed nonce matches nothing, so
both peers complete a working call with no advert-negotiated PSK. The static advert
it would replace makes the same attacker end up with two sessions it cannot read.

"Tampering fails loud" does not hold here either, at the primitive level: ML-KEM
uses implicit rejection, so a substituted key or ciphertext yields a valid-looking
but different shared secret. Any design whose safety rests on a mismatch being
detected is unimplementable on this transport as it stands. Do not re-propose it.

What retirement costs, stated honestly: both QUAD legs also mix an UNADVERTISED
per-contact PSK, loaded separately from the advert, and that is where the UI's
negotiated fingerprint already comes from. So a paired contact keeps its PSK. What
is lost is negotiating a non-contact-bound shared PSK over QUAD specifically, on a
path that loses to the JSON envelope on every modern call.

The consume side is latched, and this closed a live hole. §3.3.1.1's per-contact
latch was wired only into the JSON responder branch, and which branch runs depends
on whether a JSON OFFER arrived — a choice belonging to the RELAY, since it delivers
both envelopes. A relay could therefore force the QUAD branch on demand and have
logged static fingerprints accepted as a plain match: the §3.3.1.1 attack, through
the one door the latch did not cover. Both QUAD consume sites now take the latch. A
refusal is loud and never drops the call (W-NOBRICK), and the responder echoes no
selection when it refuses, so the initiator cannot be left mixing a PSK the
responder did not.

The QUAD codec still DECODES a list — a genuinely old peer has to interoperate. Only
the production emitter is empty.

**Honest limits.** v3 does not hide how many secrets a pair shares (the list
length is still visible; pad to a fixed length if that matters), and it does not
stop a peer who already holds key X from testing whether you also hold X — that
is inherent to any matchable advertisement, and the knowledge gained is nil since
they already have the key. The tag is not password-hardened, so a LOW-ENTROPY psk
stays confirmable offline by computing the tag for a guess and comparing; that is
equally true of the static `SHA-256(psk)` it replaces, and is why psks are 32
random bytes. It says nothing about the server knowing who calls whom; that is a
different layer.

KAT: `bcrypto-server/tools/kat/psk-advert-v3/psk-advert-v3-kat.json`, generated
and self-verified by `tools/kat/gen_psk_advert_v3_kat.py`, which writes every
fleet copy in one run. Consumers: `PskAdvertV3KatTest.kt`,
`PskAdvertV3KatTests.swift`, `pskAdvertV3.kat.spec.ts`.

### 3.4 Mid-handshake hangup

A peer-initiated `call_hangup` arriving while the controller is in
the `Handshaking` state MUST cancel the active handshake job
immediately and surface a clear UI reason. Without this, the
initiator waits the full 35 s `HANDSHAKE_TIMEOUT` before giving up.
Implemented on Android via `armHandshakeHangupListener`; iOS uses
the same `call_hangup` signal as a fail-fast when it detects an
incompatible wire format (Path B in `wireOpaqueMessageHandler`).

### 3.5 Call acceptance gate (`call_accepted`)

`call_answer` signals that the callee's transport/media stack is ready
("the network is ready"). Under R-ANSWER-FIRST (§3.7.4) a 1:1 callee device sets up no media and sends no ACCEPT
before the user has answered, so it sends `call_answer` only after that; the earlier optimization of sending it
ahead of any real user action no longer exists for a 1:1 callee.
`call_accepted` is a distinct, additive message that a client MUST send
if and only if a real user (or an equivalent human-input surface: system
Answer UI, notification action, hardware/watch button) explicitly
accepted the call. It carries no SDP or crypto material — `{call_id}`
only; the server stamps `sender_id`/`recipient_id` before relaying,
exactly like `call_media_ready`. The **caller** MUST NOT show the SAS
or mark the call fully active until BOTH (a) its local handshake has
completed AND (b) it has received `call_accepted` from the callee for
this `call_id` — whichever of the two happens first must be latched and
the finalization performed on the second. The server treats
`call_accepted` as a stateless, party-gated relay (`resolveCallPeer`),
with no per-call singleton/dedup enforcement (unlike `call_answer`'s
`TryMarkAnswered`) — the message is idempotent by construction;
duplicates are harmless.

`call_accepted` gates only what the caller shows (the SAS, the fully-active state). It never gates a handshake message:
the caller sends its REVEAL and its round-1 KCMAC without waiting for it (R-KCMAC-NOGATE, §3.7.1).

---

### 3.6 Base WebRTC SDP exchange (`call_offer` / `call_answer`) — CROSS-PLATFORM CONTRACT

This is a SEPARATE concern from §3's PQC/E2EE handshake above: even
after the crypto handshake completes, the real WebRTC `RTCPeerConnection`
(ICE/DTLS/SRTP — the actual media transport) still needs a real SDP
offer/answer exchange to come up. **This section did not exist before
2026-07-08** — its absence is exactly what let the bug below ship and
stay hidden behind a defensive guard for over a month instead of being
caught by inspection. Two dialects coexist, same shape as §3.2/§3.1:

| type | data | Android dialect | Desktop/iOS (QUAD) dialect |
|---|---|---|---|
| `call_offer` | `{call_id, recipient_id, sdp, capabilities}` | REAL `v=0...` SDP inline in `sdp` | `sdp:''` (vestigial) — real offer rides QUAD `0x03 DC_SDP_OFFER` (§3.2) via `opaque_message` |
| `call_answer` | `{call_id, sdp, capabilities}` | REAL `v=0...` SDP inline in `sdp` — **the ONLY channel Android reads the answer from; it has no QUAD `DC_SDP_ANSWER` parser** | `sdp:''` (control-only) — real answer rides QUAD `0x04 DC_SDP_ANSWER` via `opaque_message` |

**Discriminator (how a responder tells which dialect an incoming offer used):**
a real inline `call_offer.sdp` always starts with `v=0` (mandatory first
line of any SDP body per RFC 8866) — an empty/vestigial `sdp:''` never
does. Check `/^v=0[\r\n]/`, not merely truthiness (an offer WS envelope
always has an `sdp` field present, dialect is what's IN it).

**Server dedup constraint (load-bearing — do not violate):** the server
relays only the FIRST `call_answer` per call (`TryMarkAnswered`, so a
callee's real answer never races a stale duplicate and freezes the
caller's WebRTC state machine). This means an Android-dialect responder
MUST NOT send an empty placeholder `call_answer` and then a second one
with the real SDP later — the real one gets silently dropped, the
answer-side DTLS fingerprint/setup role never reaches the caller, and
its `RTCPeerConnection` sits dead for the entire call (media falls back
to the WS-relay rail, live but never true P2P). **There is exactly ONE
`call_answer` per call; for an Android-dialect peer it MUST already
carry the real SDP.** Since the real answer SDP is only produced later
— asynchronously, by the renderer's actual `RTCPeerConnection`, after
mic/cam + ICE start — the responder MUST defer sending `call_answer`
until that SDP exists, not send a placeholder first "to be safe."

**Historical bug (found 2026-07-08 via live cross-device DTLS transport
stats — `bytesSent` climbing every poll, `bytesRecv=0` for the entire
call, on every single Android↔Desktop test call):** Desktop's responder
path sent `call_answer` with a hardcoded `sdp:''` immediately, on the
mistaken belief that "there is no WebRTC SDP exchange for E2EE calls"
(conflating this section with §3's crypto handshake, which is a real but
SEPARATE concern). Android's `PeerConnectionHolder.applyRemoteAnswer`
correctly discarded the blank SDP (`isBlank()` guard, added 2026-05-26
specifically because of this recurring symptom) rather than crash — but
nobody had wired the real value through, so the guard silently masked a
structural gap for over a month. Fixed in `CallController.ts` by
deferring `call_answer` until the renderer's real SDP answer exists
(mirrors the already-proven `initialOfferSdpSentCallId` pattern used on
the offer side). **Lesson for future message types:** any new WS message
type MUST have its per-dialect field-population contract documented HERE
before shipping — "peer X sends blank, guard against it" is a workaround
for a bug, not a specification.

### 3.7 Signed transcript v6

All integers are big-endian, `LP(x) = u16(len) ‖ x`.

```
OFFER_v6  = "qaudion-handshake-sig-v6" ‖ 0x01 ‖ LP(callId) ‖ LP(signerIK32) ‖ LP(epochId16) ‖ LP(pqcPub)
            ‖ LP(x25519Pub) ‖ LP(strongBox|∅) ‖ LP(dualCurve|∅) ‖ CAPS9 ‖ ratchetV ‖ suiteId
            ‖ LP(advEnc(offer adverts)) ‖ rekeyNonce[8] ‖ u32(round) ‖ DTLSFP_offerer[33]
            ‖ LP(sasCommit | ∅)
ACCEPT_v6 = "qaudion-handshake-sig-v6" ‖ 0x02 ‖ LP(callId) ‖ LP(signerIK32) ‖ LP(epochId16) ‖ LP(ctPqc)
            ‖ LP(ctX25519) ‖ LP(ctStrongBox|∅) ‖ LP(ctDualCurve|∅) ‖ CAPS9 ‖ ratchetV ‖ suiteId
            ‖ LP(selectedPskFp) ‖ LP(SHA-256(OFFER_v6)) ‖ LP(advEnc(responder adverts))
            ‖ rekeyNonce[8] ‖ u32(round) ‖ DTLSFP_acceptor[33]
sigV6     = Ed25519(deviceIdentityKey, OFFER_v6 | ACCEPT_v6)     (pure RFC 8032)
```

- The domain string `qaudion-handshake-sig-v6` is 24 bytes, ASCII, not length-prefixed.
- `LP(sasCommit | ∅)` is `0x0020 ‖ sasCommit[32]` when `round` = 1 and `0x0000` when `round` >= 2. A builder MUST
  throw on any other combination (32 bytes with round >= 2, empty with round 1, any other length). ACCEPT_v6 has no
  commitment field of its own: it binds the commitment through `offerBinding`.
- `offerBinding = SHA-256(OFFER_v6)` in the ACCEPT is mandatory and non-empty.
- `DTLSFP` is the canonical binary fingerprint of §3.8.1 (`u8(alg) ‖ digest`, 33 bytes). OFFER
  carries the offerer's fingerprint and ACCEPT carries the acceptor's, so through
  `offerBinding` the ACCEPT transcript covers both.
- ACCEPT_v6 differs from the v5 layout only in the domain and in `offerBinding` (the hash of OFFER_v6, which now
  ends with the commitment). Every other field keeps its definition below, including `rekeyNonce`, `round`
  semantics and CAPS9. `round` is mandatory and has no default (R-ROUND, §3.1).
- A verifier MUST build `OFFER_v6` with these inputs:
  - as the **offerer**: its own real certificate fingerprint and its own `sasCommit`
  - as the **acceptor**: the fingerprint and the `sasCommit` parsed from the received bundle
- A verifier MUST build `ACCEPT_v6` with these inputs:
  - as the **acceptor**: its own real fingerprint, and the hash of the OFFER_v6 it received
  - as the **offerer**: the fingerprint from the received ACCEPT bundle, and the hash of the OFFER_v6 it sent
- If any of these inputs differ between the two legs, the transcripts differ, and so do the session keys, SAS and
  KCMAC. A commitment rewritten on one leg makes the legs build different `OFFER_v6`, hence different `offerBinding`,
  even with the signatures stripped.

**Field definitions.** Every value is the RAW decoded bytes of the bundle field (base64 decoded first), never the
JSON text. Optional fields that are absent encode as `LP(empty) = 0x0000`.

| Transcript field | Source |
|---|---|
| `callId` | UTF-8 bytes of the bundle `callId`, exactly as it appears in the `"<callId>\|<JSON>"` envelope |
| `signerIK32` | the signer's 32-byte Ed25519 identity public key (`signerIdentityKey`) |
| `epochId16` | 16 bytes, all `0x00`. It is an inert placeholder that every platform feeds identically |
| `pqcPub`, `x25519Pub`, `strongBox`, `dualCurve` | OFFER `pqcPublicKey`, `x25519PublicKey`, `strongBoxPublicKey`, `dualCurvePublicKey` |
| `ctPqc`, `ctX25519`, `ctStrongBox`, `ctDualCurve` | ACCEPT `ciphertext.pqc`, `.x25519`, `.strongBox`, `.dualCurve` |
| `CAPS9` | 9 bytes, each `0x00` or `0x01`, in this fixed order: `ratchetV3`, `sframeV1`, `vkeyV1`, `sessionKdfV3`, `ratchetV4`, `srtpDirKeyV1`, `pskMixV1`, `hsTranscriptBindV1`, `ratchetV5`. Read from the signer's OWN bundle `capabilities`; an absent capability is `0x00` |
| `ratchetV`, `suiteId` | 1 byte each: `0x04` and `0x01` |
| `advEnc(list)` | `u8(m) ‖ (u8(role_j) ‖ fp32_j)` for `j = 1..m`, in the advertised order. `fp32_j` is the RAW 32-byte value of the advertised `pskFingerprints[j]` (a blinded tag, §3.3.1). `role_j` is the j-th entry of the bundle's optional `pskRoles` array (one unsigned byte), and `0` when the array is absent, null or shorter than the list. The blinded advertisement of §3.3.1 omits `pskRoles`, so on such a bundle every `role_j` is `0`, but a builder MUST still honour a non-zero entry: the KAT vector `v6-psk-rekey-round-2` pins that encoding with roles `[0, 1]`. A string that is not exactly 64 hex characters encodes as 32 zero bytes (it never throws). `m ≤ 255` |
| `selectedPskFp` | UTF-8 bytes of the bundle `selectedPskFingerprint` string verbatim, empty when none |
| `rekeyNonce[8]` | the 8 raw bytes of `rekeyNonce`. The offerer mints it once per call in memory and reuses it on every OFFER of that call. The ACCEPT echoes the OFFER's value. It is always present and exactly 8 bytes |
| `round` | `rekeyRound`: `1` for the initial handshake, strictly increasing for each later rekey OFFER under the same `callId`. It MUST be present and in [1, 4294967295]: a missing, 0, out-of-range or non-integer value is malformed and ends the call (§3.1), a verifier never substitutes a default. The ACCEPT echoes the OFFER's value |
| `sasCommit` | the 32 raw bytes of the OFFER's `sasCommit` when `round` = 1; empty when `round` >= 2 (§3.7.4) |

A receiver that has accepted round N for a `callId` MUST reject any later OFFER whose `round` is not greater than N,
and any OFFER whose `rekeyNonce` differs from the one recorded for that call. The first OFFER a callee accepts for a
`callId` MUST have `round` = 1 (R-COMMIT-FIRST-ROUND, §3.1); an OFFER that arrives before the device has a call context for
its `callId` follows the pending-OFFER rule of §3.7.4.

**Rekey ACCEPT wait (R-REKEY-ACCEPT-WAIT).** The offerer of a rekey round (`round` >= 2) waits for that round's ACCEPT
`2 × CONFIRM_TIMEOUT` = 30 s after it handed the OFFER to the transport, never shorter; a platform uses exactly this
value unless it has a reason to wait longer. One leg is the OFFER, the other the ACCEPT, and each may need a socket
re-authentication. The offerer processes at most one ACCEPT per rekey round. The ACCEPT it processes is the first one
from the call's peer user that reaches it for that round (Reach, below); every other ACCEPT it receives is sorted by the
list below. The round-1 wait is not this one: it includes the ring (§3.5).

A rekey round is *waiting* from the moment its OFFER is handed to the transport until the first ACCEPT for it reaches the
offerer or its wait expires, whichever comes first: it stops waiting when that ACCEPT reaches the offerer, not when
its processing ends. T0 is the moment the OFFER of a waiting round was handed to the
transport. This specification fixes no limit on rekeys in flight (R-KCMAC-ROUNDS), so several rounds may be waiting at
once, each with its own T0 and its own wait.

- **Reach.** An ACCEPT reaches the offerer when the offerer's signalling transport receives the envelope that carries
  it (live, or replayed by the server at authentication), before any parsing, queueing or verification. T0 and the
  moment of reaching are both read on the offerer's own clock. An ACCEPT reaches the offerer in time when it reaches it
  before T0 + 30 s.
- **Processed to completion.** An ACCEPT that reached the offerer in time is processed to completion, even when its
  verification, decapsulation or key installation ends after T0 + 30 s: the deadline never aborts an ACCEPT that is
  already being processed, and the round ends bound or refused as that ACCEPT decides. An ACCEPT that reaches the
  offerer at T0 + 30 s or later is dropped silently.
- **One order.** As in R-KCMAC-ATOMIC, the reaching of the ACCEPT and the expiry of the wait are two steps on the call's
  state and never overlap: the step that runs first wins. If the reaching runs first, the wait is over and the expiry
  does nothing; if the expiry runs first, the round is abandoned and an ACCEPT that arrives afterwards is dropped.

**Every ACCEPT the offerer receives once round 1 is bound (the caller) or answered (a callee)** is sorted here, and
nowhere else, in this order (an ACCEPT that is malformed, §3.1, ends the call as before):

1. A byte-identical copy of the round-1 ACCEPT the caller bound (only the caller binds one, a callee never receives
   one). The callee re-sends it (R-ACCEPT-RESEND) while its REVEAL has not verified. The duplicate-ACCEPT rule of
   §3.7.4 applies unchanged, in every state of the call and whether or not a rekey round is waiting: the caller re-sends
   the byte-identical REVEAL, as one re-send event of its budget of 4 (R-KCMAC-RESEND), and does nothing else; once the
   budget is spent the copy is still dropped. Why: a callee that still misses the REVEAL has its 15 s REVEAL timer
   running (§3.7.4), and dropping its copy because a rekey round is waiting would end an honest call at that timer.
2. A well-formed ACCEPT (it parses and passes the malformed checks of §3.1) that echoes a waiting round: it is the
   ACCEPT of that round, the first from the peer user that reached the offerer for it, processed as above. From that
   moment the round is no longer waiting.
3. Every other ACCEPT is dropped silently: a copy, byte-identical or not, of the ACCEPT of an earlier rekey round that
   the offerer already bound, refused or abandoned (the acceptor's re-send, a replay by the server, a late arrival after
   the 30 s wait); a second ACCEPT for a round whose ACCEPT already reached the offerer, whether that first ACCEPT is
   still being processed or finished; an ACCEPT that echoes a round that is not waiting; any ACCEPT of a rekey round
   (`round` >= 2) when no round is waiting; and any round-1 ACCEPT that case 1 does not cover (§3.7.4).
   Dropped silently means: no key, media, KCMAC or REVEAL state changes, no re-send event, no unit of the budget, no
   close reason and no hangup.

Cases 1 and 3 never touch a rekey round of the call, whether it is waiting, being processed or done: a waiting round
keeps its T0 and keeps running, and every round's OFFER, pending key material and KCMAC context, and every round in
PENDING, stay as they were. Nothing is cleared, failed or closed, and no echo, binding, signature or fingerprint check of
any round is run against such an ACCEPT. An echoed round that differs from the waiting one is never a reason to end the
call.

The acceptor arms its KCMAC window for the round when it sends the ACCEPT (§3.7.1). Let `d` be the time the OFFER leg
takes and `e` the time the ACCEPT leg takes. If no ACCEPT for the round has reached the offerer by T0 + 30 s, the round
is abandoned at T0 + 30 s, and each side does the following:

- The offerer, at T0 + 30 s: it installs no key, arms no round (it arms a round on a verified ACCEPT), sends no MAC for
  it and keeps the current key. Its own call does not end by itself, and the next scheduled round retries.
- An acceptor that never armed the round (the OFFER never reached it, or it refused the round): nothing happened on its
  side. The call goes on.
- An acceptor that armed the round (it sent its ACCEPT at T0 + d): the offerer drops that ACCEPT and every re-sent copy
  of it (R-ACCEPT-RESEND) and never sends a MAC for the round, so no MAC for it can arrive. The acceptor's window (30 s
  from arming, §3.7.1) ends the call with `kcmac_mismatch` at T0 + d + 30 s. This happens only when `d + e` exceeds
  30 s, that is, after more than 30 s of signalling trouble on the two legs together (or when every copy of the ACCEPT
  is lost). It is accepted and not repaired: a rekey round has no abort message, and a longer wait only moves the limit.

So "the call goes on" holds only when the acceptor never armed the round.

#### 3.7.1 Transcript-bound session key, SAS and key confirmation (unconditional)

There is no capability gate and no non-bound variant: every 1:1 session key, SAS and key-confirmation MAC is
bound to the v6 transcript.

```
sessionKey = HKDF-SHA256(IKM = pqcSS ‖ x25519SS,
                         salt = the raw bytes of the agreed PSK (§3.3) when one was selected,
                                otherwise the 22 ASCII bytes "q-audion-hybrid-pqc-v1",
                         info = "q-audion-session-key" ‖ SHA-256(ACCEPT_v6),      (20 + 32 = 52 B)
                         L    = 32)
```

- The PSK is the salt itself. The `q-audion-psk-mix` label of §1 belongs to the N ≥ 2 PSK-mixing construction,
  which this derivation does not use. The KAT `kdf` section pins both cases (`kdf-no-psk`, `kdf-with-psk`).
- SAS: §4, over the same `SHA-256(ACCEPT_v6)` and the caller's `sasNonce` (§3.7.4). `sasNonce` enters ONLY the SAS: the session key, KCMAC and frame keys below use no nonce and are not gated by the REVEAL.
- Key confirmation (KCMAC), with `offerBinding = SHA-256(OFFER_v6)` and `acceptBinding = SHA-256(ACCEPT_v6)`:

  ```
  kc_transcript = SHA-256( "qa-kc-transcript-v1"                      19 B ASCII, not length-prefixed
                           ‖ offerBinding[32] ‖ acceptBinding[32]
                           ‖ LP(advEnc(initiator advert)) ‖ LP(advEnc(responder advert))     received wire order
                           ‖ u8(N) ‖ fp_1 ‖ … ‖ fp_N                  the N mixed PSKs, raw 32 B each (N ≤ 1 today)
                           ‖ LP(mix_id)                               LP(empty) = 0x0000 when N ≤ 1
                           ‖ ikInit[32] ‖ ikResp[32] )                Ed25519 identity keys, raw
  K_kc          = HKDF-Expand(PRK = sessionKey, info = "qa-kc-key-v1", L = 32)     expand only, no extract step
  kcMacInit     = HMAC-SHA256(K_kc, 0x01 ‖ kc_transcript)            sent by the offerer
  kcMacResp     = HMAC-SHA256(K_kc, 0x02 ‖ kc_transcript)            sent by the acceptor
  ```

  `ikInit` is the offerer's and `ikResp` the acceptor's `signerIdentityKey`. The KAT `kdf` section pins
  `kc_transcript`, `K_kc` and both MACs. A MAC is compared in constant time.
- **KCMAC runs on EVERY key round (R-KCMAC).** The exchange is not a once-per-call step: the initial handshake
  and each rekey round run it, with that round's own inputs.
  - For a round, `init` (the "offerer" above: `ikInit`, `offerBinding`, `kcMacInit`) is the signer of THAT round's
    OFFER_v6 and `resp` is the signer of THAT round's ACCEPT_v6. `offerBinding`, `acceptBinding`, the adverts, the
    mixed PSKs, `sessionKey` and so `K_kc` are all that round's. A rekey started by the callee therefore has the callee as
    `init` for that round. (This is per round and is unrelated to the fixed call role `o`/`a` of §3.7.2.)
  - Each side sends its own MAC for the round as soon as the round's session key is derived and verifies the peer's
    MAC against that round's `K_kc` and `kc_transcript`. The MAC travels in the existing opaque piggyback
    `<callId>|KCMAC:<base64(role byte ‖ MAC[32])>` (role byte `0x01` for `init`, `0x02` for `resp` of THAT round).
    The message carries NO round field and none is added: a receiver attributes a MAC to a round by content, with the
    rules below, never by arrival order alone.
  - **No gate on the sending (R-KCMAC-NOGATE).** A device sends its MAC at the moment named here and at no later
    one: it is never held back for `call_accepted` (§3.5), for a UI step, for the media connection or for the SAS.
    The CALLER sends its round-1 MAC right after its REVEAL is handed to the transport (§3.7.4), exactly like the
    desktop and iOS do, whether or not a `call_accepted` has arrived. A device sends its MAC for a rekey round when
    it derives that round's key. Holding a MAC until `call_accepted` makes the peer's window run out while the callee
    is still on the answer screen, which would end an honest call.
  - **Round 1 exception (R-COMMIT-KCMAC-HOLD, §3.7.4):** the round-1 `resp` MAC is NOT sent as soon as the key is
    derived. The callee device sends it only after its OWN REVEAL has verified (§3.7.4, R-COMMIT-CHECK step 7), so a
    callee device that never verifies a REVEAL (it lost a double answer, or the REVEAL timer fired) never sends a
    round-1 MAC. The caller's round-1 `init` MAC is unchanged (it follows the caller's REVEAL on the same ordered path).
    Every rekey round is unchanged.
  - **Window (R-CONFIRM-TIMEOUT).** One constant, `CONFIRM_TIMEOUT = 15 s`, is the confirmation window of this
    protocol: the key-confirmation window of every round, the callee's REVEAL timer (§3.7.4) and the DTLS statistics
    check (§3.8.4). A platform defines it once and uses that one constant. The KCMAC window of the fail-closed rule
    below is `CONFIRM_TIMEOUT` and runs per round, from the moment that round's context is armed (the round's key is
    derived), rekey rounds included.
    Three exceptions, two for round 1 (R-COMMIT-KCMAC-HOLD, §3.7.4) and one for rekey rounds: the CALLER's wait
    for the callee's MAC ends no earlier than `2 × CONFIRM_TIMEOUT` = 30 s after the caller handed its REVEAL to the
    transport, because the callee sends that MAC only after the REVEAL round trip and each of the two legs (REVEAL
    to the callee, MAC back) may need a socket re-authentication and a re-send; the CALLEE's wait for the caller's
    MAC ends no earlier than `CONFIRM_TIMEOUT` = 15 s after the callee's own REVEAL verified, because the caller sends
    its MAC right after the REVEAL, and the REVEAL may itself arrive at the very end of the REVEAL timer, after the
    window armed with the callee's own round-1 key would have ended. The ACCEPTOR of a rekey round (the signer of its
    ACCEPT_v6) waits for the offerer's MAC no less than `2 × CONFIRM_TIMEOUT` = 30 s from arming, because the offerer
    derives the round key and sends its MAC only after the ACCEPT reached it: one leg out (the ACCEPT) and one leg back
    (the MAC), each of which may need a socket re-authentication and a re-send (R-ACCEPT-RESEND, R-KCMAC-RESEND). The
    OFFERER of a rekey round keeps `CONFIRM_TIMEOUT` from arming: the acceptor's MAC follows the ACCEPT on the same
    ordered path. All waits are minimums: a platform may wait longer, never shorter, and expiry is the same
    `kcmac_mismatch`. A platform uses exactly these values unless it has a reason to wait longer: the wait is local and
    no peer depends on its length. "Handed to the transport" is as defined for the ACCEPT in §3.7.4 (a message that is
    queued behind a socket re-authentication counts from the moment it is queued). Why a long window is safe: delaying
    a message only lets whoever delays it end the call, which the server can already do; every mismatch still ends the
    call fail-closed, and media under a wrong key never decrypts (AEAD).
  - **Sender device (caller, every round, R-COMMIT-KCMAC-DEVICE, §3.7.4):** a caller runs the format check, the
    duplicate test, the attribution and the hold below only on a MAC whose opaque envelope `sender_device_id` equals the
    `sender_device_id` of the opaque envelope that carried the ACCEPT it bound. A MAC from any other device, or without
    that field, is dropped silently: no judgment, no `kcmac_mismatch`, no hold and no effect on any window. This test
    comes BEFORE the format check and every step below.
  - **Rounds are judged by content (R-KCMAC-ROUNDS).** Per call a receiver keeps:
    - PENDING: every round it armed and has not decided, each with the expected peer MAC
      `HMAC-SHA256(K_kc, peerRole ‖ kc_transcript)` of that round (a receiver MAY compute it at arming and keep only
      it), the role byte the peer must carry for that round, and the round's own window (Window rule above). Arming a
      round NEVER cancels, shortens, extends or decides another pending round: a round superseded by a later one stays
      pending, with its own window, until it is decided. At most `MAX_PENDING_ROUNDS = 16` rounds are pending; a
      device that would arm a 17th ends the call with `kcmac_mismatch`.
    - DECIDED: the 32-byte peer MAC that verified each decided round, for the rest of the call (at least the most
      recent 256).
    - HELD: at most `MAX_HELD_MACS = 8` inbound MACs that matched no pending round, each with its time of receipt. An
      entry received `2 × CONFIRM_TIMEOUT` = 30 s ago or more is stale: it is dropped silently, at step 4 and at
      arming below, and a stale entry counts against no bound.
  - **State is serialised per call (R-KCMAC-ATOMIC).** The state of one call (PENDING, DECIDED and HELD together) is
    changed by one step at a time, in one order (one actor, one queue or one lock; on a platform with more than one
    thread two steps never overlap). A step is exactly one of:
    - the whole processing of ONE inbound MAC: the sender-device rule, the peer-user check and steps 1 to 4 below,
      including the drop of stale held MACs and the insertion into HELD;
    - the whole arming of ONE round: the overflow check, the insertion into PENDING, then the re-offer of the held MACs
      (below), as one step, so that no inbound MAC is processed between the insertion and the end of the re-offer;
    - the expiry of ONE round's window: the test "still pending" and the failure are one step.

    When a decision and an expiry concern the same round, the step that runs first wins: a round decided first never
    fails, a round that failed first is not decided afterwards. Why: without one order, a MAC that step 4 classifies as
    unattributed after the re-offer of an arming has already looked at HELD is held and offered again only at the next
    arming, and the round then fails at its window although its MAC arrived (an honest call ends).
  - An inbound MAC is processed, after the sender-device rule (caller) and the peer-user check, in this order:
    1. Format: the text after `KCMAC:` is not exactly the 44-character canonical base64 (§3.1) of 33 bytes
       (`role ‖ MAC[32]`): dropped silently. It cannot be attributed to a round; it is never judged and never ends the
       call by itself.
    2. Duplicate: the 32-byte MAC part (the role byte is not compared) equals one in DECIDED (a retransmission, or a
       re-send after a socket re-authentication, R-KCMAC-RESEND): dropped silently, never judged. The role is an input
       of the HMAC, so a copy of a decided MAC with another role byte is no new MAC.
    3. Attribution: the MAC is compared in constant time with the expected peer MAC of EVERY pending round, whatever
       order they were armed in. If it equals round R's, R is decided: with R's peer role byte, R is verified (it
       leaves PENDING, its window stops, the MAC joins DECIDED); with any other role byte, the call ends with
       `kcmac_mismatch`.
    4. Unattributed: a MAC that is not a duplicate and matches no pending round (the peer's MAC for a round this side
       has not armed yet, whether or not other rounds are pending, or a MAC that will never verify) is held while HELD
       has room, otherwise dropped silently. Before it is held, every stale held MAC (received 30 s ago or more) is
       dropped silently, so that a stale entry never takes the place of a MAC that arrives later (the limit of 8
       applies to the fresh entries that remain). It is never judged wrong, never ends the call and never shortens or
       extends a window by itself. When a round is armed, it is first inserted into PENDING, then every held MAC
       received less than `2 × CONFIRM_TIMEOUT` = 30 s ago is offered again from step 2 (it already passed the
       sender-device rule, the peer-user check and step 1), keeping its original receipt time; an older held MAC is
       dropped silently.
  - A round fails when its window ends while it is pending: `kcmac_mismatch` with the event of R-CONFIRM-TELEMETRY,
    whether or not later rounds were armed or verified meanwhile. A MAC that never verifies therefore ends the call at
    the window of the round it should have confirmed, not on arrival.
  - A receiver MUST NOT judge a MAC against "the live round" or "the latest round", and MUST NOT use "the latest MAC
    seen" as the peer's MAC of a round.
  - A call in which a KCMAC context is required but missing (a round whose key was derived but that could not be
    armed) ends with `kcmac_mismatch` (R-EARBUD, §3.7.3).
  - Why a MAC that matches nothing fails at the window and not on arrival: the message carries no round, so it cannot
    be told apart from the peer's MAC for a round this side has not armed yet. Judging it against some pending round
    ends honest calls, for example a rekey MAC that overtakes this side's processing of that round's ACCEPT while an
    earlier round waits for a re-sent MAC. Waiting changes no verdict. A round is confirmed only by its exact expected
    MAC, and every unconfirmed round still ends the call. A session key that differs between the legs decrypts no media
    meanwhile (AEAD; every derived key covers the signed transcript). Whoever can put a bogus MAC on the wire (the
    server, the peer user) can already end the call. Bounds: in an honest call a round is decided within one round
    trip, so PENDING holds one or two rounds. `MAX_PENDING_ROUNDS = 16` and `MAX_HELD_MACS = 8` limit the state that a
    bogus sender can make a device keep. They are not pacing rules: this specification fixes no rekey cadence and no
    limit on rekeys in flight. A round leaves PENDING when it is decided or when its window ends (30 s from arming at
    most), so a 17th pending round means 17 rounds armed on one device within one 30 s window, a sustained rate of
    one round per 1.8 s or faster across both sides. No rekey schedule that serves a purpose comes near it. A device
    that reaches it ends the call, the same fail-closed outcome as an unconfirmed round, and never drops a round
    silently.
- **KCMAC fails closed.** Under v6 a KCMAC failure ENDS the call with reason `kcmac_mismatch`: when a round's window
  ends before a MAC equal to that round's expected peer MAC arrived (every round, superseded rounds included), when
  such a MAC carries the wrong role byte, or when a 17th round would be pending (R-KCMAC-ROUNDS). The windows are
  `CONFIRM_TIMEOUT` = 15 s, with the three exceptions of the Window rule (round-1 caller 30 s after its REVEAL, round-1
  callee 15 s after its own REVEAL verified, rekey acceptor 30 s from arming). There is no observation-only mode and
  no hold-pending-SAS path for it. An expiry emits the telemetry event of R-CONFIRM-TELEMETRY (§3.7.4).
- Consequence for the DTLS binding: if anyone substitutes a fingerprint, even with the signatures stripped, the two
  legs build different `ACCEPT_v6` bytes and so derive different session keys. No media decrypts, the SAS differs and
  the KCMAC fails.

#### 3.7.2 Directional 1:1 frame keys

For each 1:1 key round, meaning the session key produced by the initial ACCEPT v6 and by every rekey round, each
side derives two 32-byte FrameCryptor keys from that round's `sessionKey`:

```
frameKey_o2a = HKDF-SHA256(IKM = sessionKey, salt = "qaudion-frame-salt-v5",
                           info = "q-audion-frame-key-v5:" ‖ callId ‖ ":o2a", L = 32)
frameKey_a2o = HKDF-SHA256(IKM = sessionKey, salt = "qaudion-frame-salt-v5",
                           info = "q-audion-frame-key-v5:" ‖ callId ‖ ":a2o", L = 32)
```

- All strings are ASCII with no NUL. The `-v5` in these labels names the frame-key scheme, which transcript v6 does not change: do not rename it. `callId` is exactly the string of the transcript.
- **R-ROLE.** `o` is the **caller**: the signer of the call's INITIAL OFFER_v6 (the round with `rekeyRound` = 1), and `a`
  is the callee. The role is fixed for the whole call and for every key round: whoever starts a rekey, and whoever
  signs that round's OFFER_v6, `o2a` stays the caller-to-callee direction and `a2o` the callee-to-caller direction.
  This is the call role, not the signer of the round's own OFFER_v6 (that is `init` of R-KCMAC, which may differ per
  round), and not the user-id ordering used by §1.1.
- The offerer encrypts its outgoing frames with `frameKey_o2a` and decrypts incoming frames with `frameKey_a2o`. The
  acceptor does the opposite.
- These two keys are the only keys the 1:1 FrameCryptor receives. No single key is shared by both directions. On the
  native FrameCryptor the key provider runs in per-participant mode (`shared_key = false`): the sender cryptors use
  a local participant id holding the own-direction key, the receiver cryptors use the remote participant id holding
  the peer-direction key.
- **R-SLOT: slot and `keyIndex` (1:1, every platform).** The key round epoch is `E = rekeyRound - 1` (the initial
  round is `E = 0`, the first rekey `E = 1`, and so on). `E` is computed from the round's signed `rekeyRound`, never
  from a local counter: a round that never completes leaves a gap and both sides still agree. Audio and video
  FrameCryptor keys of one round share `E` (it is the `key_epoch` of §8.7, which applies to both media kinds). Both directions of round `E` are installed in ring slot `E mod 16`, and a sender
  stamps every frame it seals under round `E` with `keyIndex = E mod 16` (§11.1). A receiver selects the ring slot
  ONLY from the frame's `keyIndex`, never from "the current key" or from its own sender state; a platform that
  always stamps or opens slot 0 is non-conformant. The ring has 16 slots.
  - A slot that is retired (the grace of §8.7 has expired, or the call ends) is overwritten with 32 RANDOM bytes
    from a CSPRNG, never with zeros: the native FrameCryptor accepts 32 zero bytes as valid key material, so a
    zeroed slot would hold a key derived from a public value and frames sealed under it would authenticate.
    Receivers MUST NOT install all-zero key material in any slot.
- The relay sealer (`srtp_master` a2b/b2a, §1.1) is unchanged.
- The frame wire format and the receiver replay window are defined in §11.

#### 3.7.3 No unauthenticated handshake path (R-EARBUD)

Every 1:1 call on every platform runs the v6 handshake of §3.7: signed OFFER/ACCEPT, DTLS binding (§3.8) and
KCMAC (§3.7.1). There is no other way to set up a 1:1 call.

- The hardware-earbud relay handshake (`earbud-relay-v1` capability, the EARBUDPDU frames, the PSK-less relay
  agreement) is **retired**. A client MUST NOT advertise `earbud-relay-v1`, and MUST ignore it when it is present in
  the unsigned `capabilities` of `call_incoming`, `call_answer` or any other server-relayed message: such a field
  never selects a different handshake, never exempts the DTLS binding checks (a) and (b), and never skips KCMAC. The
  capabilities that matter are the signed ones inside the bundle (CAPS9, §3.7).
- A signalling field that the server, or anyone on the path, can add or change MUST NOT turn off or weaken any step
  of §3.7 or §3.8. In particular there is no "exempt" state of the DTLS binding.
- If a KCMAC context is required for a round whose key was derived (§3.7.1) and is missing, the call ends with reason
  `kcmac_mismatch`. A missing context is a failure, never a reason to skip the check.
- The earbud GATT key-import family of §7 is a local BLE interface of the hardware earbud and is unaffected by this
  rule; it is not a call-handshake path.

#### 3.7.4 SAS commitment and REVEAL (round 1 only)

Why: with a two-message round 1 (OFFER, ACCEPT) the acceptor moves last and can compute the SAS of a candidate
ACCEPT offline before sending it. Whoever controls signalling (a forged server key, a compromised node) can then grind
an ACCEPT on the caller's leg until its SAS equals the one on the callee's leg, and the SAS stops being a
man-in-the-middle check. v6 makes round 1 three moves: the caller commits to a secret nonce in the signed OFFER, the
callee answers, the caller reveals the nonce, and the SAS depends on the nonce. The callee is bound before the nonce
is public and the caller is bound before the callee's contribution exists, so on each leg the last free choice of an
attacker is made without knowing that leg's SAS: `P[SAS_A == SAS_B] = 2^-48` per call attempt.

**Commitment (R-COMMIT-NONCE, R-COMMIT-FIELD).**

```
sasNonce   = 32 bytes from the platform CSPRNG
sasCommit  = SHA-256( "qaudion-sas-commit-v6"     21 bytes ASCII, not length-prefixed
                      ‖ LP(callId)                u16 BE length ‖ UTF-8 callId, exactly the transcript callId
                      ‖ sasNonce[32] )            raw
```

- The caller draws `sasNonce` once per call, before it signs the round-1 OFFER, keeps it only in the call context in
  memory, never logs or persists it, never reuses it for another `callId` (a redial is a new call with a new nonce),
  sends it only in that call's REVEAL, and zeroises it when the call ends in any way.
- An OFFER retransmission re-sends the same bytes with the same commitment. It never re-signs with a new nonce.
- Only round 1 carries a commitment (R-COMMIT-SCOPE). Rekey OFFERs encode `LP(∅)` and have no `sasCommit` field, and
  there is no rekey REVEAL.

**Flow (round 1).**

```
Caller (offerer)                                      Callee device (acceptor)
  draw sasNonce; sasCommit = H(...)
  ---- <callId>|{OFFER, ..., sasCommit, sigV6} ---->  parse; first OFFER must be round 1 with sasCommit;
                                                      while the call rings it is only held (no ACCEPT, no
                                                      media, no timer: R-ANSWER-FIRST); the USER ANSWERS;
                                                      store sasCommit; build ACCEPT_v6
                                                      when the ACCEPT is SENT: freeze sasCommit,
                                                      acceptHash = SHA-256(ACCEPT_v6), start the REVEAL timer
                                                      (CONFIRM_TIMEOUT = 15 s)
  <--- <callId>|{ACCEPT, ..., sigV6} --------------
  bind round 1 to this ACCEPT (first valid one)
  derive keys; compute SAS_v6
  ---- <callId>|SASREVEAL:<B> ----------------------->  check, open the commitment, compute SAS_v6
  ---- <callId>|KCMAC:<...> ------------------------->  (KCMAC rules of §3.7.1; sent right after the REVEAL,
                                                      never gated on call_accepted: R-KCMAC-NOGATE)
                                                      REVEAL verified: only now send the round-1 KCMAC
  <--- <callId>|KCMAC:<...> ------------------------  (R-COMMIT-KCMAC-HOLD)
  caller waits >= 30 s after the REVEAL for this MAC;  callee waits >= 15 s after its REVEAL verified for the
  caller's MAC. After a socket re-authentication each side re-sends what the peer has not yet confirmed
  (R-KCMAC-RESEND, R-ACCEPT-RESEND).
```

**Answer first (R-ANSWER-FIRST).** A callee device does nothing of the handshake before the user has answered the
call: it sends no ACCEPT, arms no handshake timer and sets up no media (PeerConnection, tracks, audio session). While
the call rings, the only thing it may do with an OFFER is hold it under the pending-OFFER rule below. There is a single
callee path and no pre-answer mode: no flag served by the server (for example a ring-signalling-only setting) selects
another one, and a client does not read such a flag. The call context a callee needs for the handshake is the `callId`
(the commitment binds it): a call whose `call_incoming` carries no `callId` cannot run v6, and the callee ends it
with `handshake_malformed` before any ACCEPT is sent, with no fallback to a handshake-less or differently bound path.
The REVEAL timer therefore starts only after the answer, at the first send of the ACCEPT.

**REVEAL message (R-COMMIT-REVEAL).** A literal UTF-8 string, the `data` of an `opaque_message` to the peer user, like
KCMAC:

```
<callId>|SASREVEAL:<B>      B = base64( acceptBinding[32] ‖ sasNonce[32] ), canonical (§3.1), exactly 88 characters
acceptBinding = SHA-256(ACCEPT_v6) of the ACCEPT the caller bound (SHA-256 of the transcript bytes of §3.7, not of the JSON)
```

- The prefix `SASREVEAL:` is case-sensitive ASCII. The dispatcher routes it before the JSON bundle parser (as it does
  `KCMAC:`), so a REVEAL never reaches the bundle parser. There is no round field, no signature and no role byte: a
  call has exactly one REVEAL value. It is not signed: the signed commitment authenticates it, because only the caller
  knows a preimage.
- `acceptBinding` travels because the server fans every `opaque_message` out to all devices of the recipient user and
  has no device addressing. A callee device must tell "this opens the commitment for MY ACCEPT" from "the caller bound
  a sibling device's ACCEPT".
- The REVEAL is neither an SRD precondition nor a media gate (§3.8.2). It gates only the callee's SAS (R-COMMIT-UNCHANGED).

**Caller (R-COMMIT-BIND, R-COMMIT-REVEAL).**

- The caller binds round 1 to the first ACCEPT that parses, passes the malformed checks (§3.1) and the `offerBinding`,
  `rekeyNonce` and `round` echo checks, atomically, before any suspension point. An invalid signature or an
  unresolved identity does not prevent binding: the call binds, reveals and is held pending SAS (§3.8.6).
- Right after binding, before its round-1 KCMAC and without waiting for `call_accepted` or any UI step, it sends the
  REVEAL. It never sends a REVEAL before binding, for an ACCEPT that failed parsing or the malformed checks, or after
  the call ended.
- A byte-identical duplicate of the bound ACCEPT is dropped and answered by re-sending the byte-identical REVEAL (and
  nothing else), in every state of the call, a rekey round that is waiting for its ACCEPT included
  (R-REKEY-ACCEPT-WAIT). A WS re-authentication also re-sends it, for as long as the caller has not verified the callee's round-1 KCMAC (a
  verified MAC proves the REVEAL arrived; a later copy is harmless and the callee drops it), together with the KCMAC
  re-send of R-KCMAC-RESEND. Re-sends of the REVEAL and of a KCMAC share one budget of 4 per call
  (R-KCMAC-RESEND).
- Any other round-1 ACCEPT after binding (a sibling device, a forgery) is dropped and never used for keys, SAS or
  REVEAL. A SASREVEAL received by a caller is dropped silently.
- The caller computes the SAS once it has sent the REVEAL.

**Callee device (R-COMMIT-CHECK).** Processing a received REVEAL, in this order:

1. Route: the text before the FIRST `|` is the `callId` and the remainder starts with `SASREVEAL:`.
2. No call context for `callId`, or this device is the caller, or this device has not SENT a round-1 ACCEPT for it
   (none computed, or still held while ringing): drop silently, create no state, hold nothing. An ACCEPT counts as SENT
   from the moment it is handed to the transport, before the write completes, so a REVEAL that is processed right after
   cannot be mistaken for an early one.
3. `sender_id` (stamped by the server) is not the call's peer user: drop silently.
4. Parse strictly: `B` canonical base64, decodes to exactly 64 bytes, the whole `data` at most 200 characters.
   Otherwise `sas_commit_mismatch`.
5. `acceptBinding` differs from the `acceptHash` (= SHA-256 of the ACCEPT_v6 transcript bytes of the ACCEPT this
   device sent): sibling rule below.
6. A REVEAL was already verified for this call: byte-identical, drop silently; different, `sas_commit_mismatch`.
7. `SHA-256("qaudion-sas-commit-v6" ‖ LP(callId) ‖ sasNonce)` equals the stored `sasCommit` (constant-time compare):
   record it, cancel the REVEAL timer, compute the SAS and only now send the round-1 KCMAC (R-COMMIT-KCMAC-HOLD below).
   Otherwise `sas_commit_mismatch`.

- The REVEAL timer is `CONFIRM_TIMEOUT` = 15 s (§3.7.1). It starts at the FIRST send of this device's ACCEPT (a later
  byte-identical retransmission of the ACCEPT does not restart it). No verified REVEAL when it fires:
  `sas_reveal_timeout`, with the telemetry event of R-CONFIRM-TELEMETRY. There is no early-REVEAL hold.
- A callee device that retransmits its ACCEPT (byte-identical copies, for example while no media has arrived) stops
  once its REVEAL has verified: the REVEAL names its ACCEPT, so the caller bound it, and every further copy would only
  spend one unit of the caller's re-send budget (R-KCMAC-RESEND) that a later socket re-authentication may need.
- A callee takes the commitment from the OFFER it actually answered: if several round-1 OFFERs for one `callId` arrive
  before the ACCEPT is sent, the newest replaces the stash; after the ACCEPT is sent, a different round-1 OFFER is
  dropped and the frozen commitment stays. A byte-identical OFFER re-sends the cached ACCEPT or is dropped, never a
  fresh ACCEPT.
- **Pending OFFER (no call context yet).** The opaque OFFER can overtake the `call_incoming` that creates the call
  context. A client that already keeps such an OFFER in a pre-ring slot keeps doing so: at most one per peer user (a
  newer one replaces the held one), no handshake processing, no ACCEPT, no timer, no hangup. The first-OFFER checks
  (round 1, valid `sasCommit`, §3.1) apply when the OFFER arrives: a pending OFFER that fails them is dropped without
  creating any state and without a hangup (there is no call to end yet), and a valid one is processed as the first
  OFFER once the call context exists, but only for the call whose `callId` it carries; a held OFFER with another
  `callId` is discarded, never applied to that call. An OFFER for a `callId` that already ended or was answered
  elsewhere is dropped without creating state.
- Until the REVEAL is verified the callee has no SAS words: its UI shows a waiting state and the SAS confirmation
  action is disabled. Polling UIs MUST cover the whole 15 s window (`CONFIRM_TIMEOUT`) or be event-driven.

**Sibling devices (R-COMMIT-SIBLING).** A callee device that has sent its ACCEPT and receives a REVEAL that passes
steps 1-4 but names a different `acceptBinding` has lost the race to a sibling device of the same user. It drops the
REVEAL and leaves the call locally: no `call_hangup`, no `HANGUP:` piggyback, no security close reason, local history
reason `answered_on_other_device`; it also stops its KCMAC and REVEAL timers and never sends a KCMAC for that round.
The caller sends the REVEAL before its KCMAC on the same ordered path, so the loser leaves before it can judge the
caller's MAC, and under R-COMMIT-KCMAC-HOLD it has no KCMAC of its own to send in the first place. Siblings that never
sent an ACCEPT drop the REVEAL at step 2 and end through the existing `call_cancel` (`answered_on_other_device`). Whoever can inject a REVEAL as the peer user is the server, which can
already drop or end any call: the sibling exit adds no capability to it.

**KCMAC hold (R-COMMIT-KCMAC-HOLD).** Normative on every client, for round 1 (a rekey round is unchanged, there is no
REVEAL for it).

- Callee device: it sends its round-1 KCMAC (role byte `0x02`, §3.7.1) ONLY after its own REVEAL has verified
  (R-COMMIT-CHECK step 7). Not when the ACCEPT is sent, not when the key is derived, not on any user action. A device
  that never verifies a REVEAL (sibling exit, `sas_reveal_timeout`, `sas_commit_mismatch`) never sends a round-1 KCMAC.
  A device that loses a double answer therefore never puts a MAC on the wire that the caller could judge.
- Caller: it accepts the callee's round-1 KCMAC for at least `2 × CONFIRM_TIMEOUT` = 30 s after it sent its REVEAL.
  "Sent" is as for the ACCEPT: the moment the REVEAL is handed to the transport. 30 s is one `CONFIRM_TIMEOUT` for
  the REVEAL to reach the callee (a socket re-authentication and a re-send may be needed) plus one for the MAC to come
  back, because the callee now answers the REVEAL. The wait may be longer, never shorter. At expiry without a verified
  MAC: `kcmac_mismatch`, as in §3.7.1.
- Callee device, its own wait: it accepts the caller's round-1 KCMAC for at least `CONFIRM_TIMEOUT` = 15 s after its
  own REVEAL verified (step 7), even when the window armed with its round-1 key would end earlier (the REVEAL may
  have arrived at the very end of the REVEAL timer). The caller sends its KCMAC right after the REVEAL on the same
  ordered path, so these 15 s are margin, not a round trip. The wait may be longer, never shorter. At expiry without a
  verified MAC: `kcmac_mismatch`, as in §3.7.1.

**KCMAC re-send and the re-send budget (R-KCMAC-RESEND).** A message handed to a signalling socket that is
replaced before the message reaches the peer can be lost. After its signalling socket
re-authenticates, a device re-sends, byte-identical, its OWN KCMAC of every round for which the peer may still be
waiting: every round whose PEER MAC it has not yet verified, AND every round whose own MAC it first sent less than
`2 × CONFIRM_TIMEOUT` = 30 s before the re-authentication. Having verified the peer's MAC of a round does not show that
the own MAC of that round arrived: the two MACs of a round cross on the wire, so the own MAC can be lost in the
replaced socket after the peer's MAC was verified, and the peer would then wait out its window and end the call with
`kcmac_mismatch`. 30 s is the longest window a peer waits for a MAC (§3.7.1): past it the peer has either verified the
MAC or already ended the call. A device re-sends only a MAC it has already sent once: a device that has no MAC of its
own for a round (key not yet derived, or a callee whose REVEAL has not verified, R-COMMIT-KCMAC-HOLD) re-sends nothing
for it and does not start sending it now. A callee whose REVEAL verified, and which sent its round-1 MAC, re-sends that
MAC under the same rule. The receiver attributes every MAC by content (R-KCMAC-ROUNDS, §3.7.1): a re-sent MAC of an
earlier round verifies that round while it is pending, is dropped as a duplicate once that round verified, and is never
judged against a later round. The sender-device rule is unaffected because the copy comes from the same device.

**ACCEPT re-send (R-ACCEPT-RESEND).** In the same re-send event, the acceptor of a round re-sends its ACCEPT of every
round for which it has no proof yet that the ACCEPT arrived. Round 1 (callee): as long as its REVEAL has not verified.
Rekey round: as long as the round is armed and undecided, that is, still in PENDING (R-KCMAC-ROUNDS): the peer's MAC of
that round has not verified and the round's window has not ended. A REVEAL naming its ACCEPT, or a peer MAC that
verifies for the round, is that proof. The copy is the exact bytes first handed to the transport, never re-signed or
re-serialised, and it leaves BEFORE that round's MAC. A device re-sends only an ACCEPT it has already sent once; a
callee whose ACCEPT is still held while ringing re-sends nothing. An acceptor re-sends a rekey ACCEPT only for a round
it armed and has not decided: the test is membership in PENDING (R-KCMAC-ROUNDS), whatever else the acceptor recorded
about the round. A rekey round that the acceptor refused, never armed, abandoned or whose window ended is forgotten (it
is not in PENDING): its ACCEPT is never re-sent, even if the bytes are still stored, it adds no message to a re-send event, and
it is never by itself a reason to spend a unit of the budget. On the offerer, a copy of the bound round-1 ACCEPT is
answered by the REVEAL re-send of R-REKEY-ACCEPT-WAIT (case 1: one event of the offerer's budget, whether or not a
rekey round is waiting), and a copy of a rekey ACCEPT is dropped silently (case 3).

The budget is ONE counter per call and per device, shared by every re-send of the call: the REVEAL re-sent on a
duplicate ACCEPT, the REVEAL and the KCMACs re-sent after a re-authentication. Only re-sends count: the first send of
an ACCEPT, a REVEAL or a MAC is not an event and consumes nothing, so a call has 4 re-send events. An EVENT is a
duplicate ACCEPT (a byte-identical copy of the bound round-1 ACCEPT) received by the caller after round 1 is bound,
a rekey round waiting or not, or a socket re-authentication of the device. A
duplicate that arrives while the caller is still verifying the first copy (before binding) has no REVEAL to re-send:
it is no event and consumes nothing. An event consumes one unit of the budget and re-sends in that event everything
that is due; it does not consume one unit per message. The two kinds
of event are independent: a duplicate ACCEPT re-sends the REVEAL and nothing else (as above), a re-authentication
re-sends everything due (the acceptor's ACCEPTs of R-ACCEPT-RESEND, the caller's REVEAL while the callee's round-1 MAC
is unverified, and the MACs above; for each round its ACCEPT first, then its MAC). A
fifth event re-sends nothing.

**Telemetry for every confirmation expiry (R-CONFIRM-TELEMETRY).** When any confirmation timer ends a call, the
device emits exactly one event, in addition to the verdict events of this section and §3.8.4:

```
{event:"confirm_timeout", timer:"reveal"|"kcmac_r1_caller"|"kcmac_r1_callee"|"kcmac_round"|"dtlsfp_stats",
 elapsedMs, round, reauths, callId8}
```

`timer` names the timer that expired: `reveal` (the callee's REVEAL timer), `kcmac_r1_caller` and `kcmac_r1_callee`
(the two round-1 exceptions of §3.7.1), `kcmac_round` (the ordinary window of a round, and any round >= 2),
`dtlsfp_stats` (§3.8.4). `elapsedMs` is the time from the start of that wait to its expiry, `round` the key round
(`1` for the REVEAL and the DTLS check), `reauths` the number of signalling-socket re-authentications of this device
during the wait, `callId8` the first 8 characters of the `callId`. The event carries no key, MAC, nonce, SAS word,
fingerprint, address or full identifier. Each platform sends it through its own diagnostics path (Android the
`qaudion.audit` telemetry, iOS the hsfatal-style line and telemetry, desktop the log and telemetry). The server
treats it as an ordinary telemetry event and defines no behaviour for it.

**Sender device of a KCMAC (R-COMMIT-KCMAC-DEVICE).** Defence in depth against any device other than the one whose
ACCEPT the caller bound.

- Server fact. For every `opaque_message` it delivers to a connected recipient, on this node or through another
  cluster node, the server builds the outgoing envelope itself as `{sender_id, sender_device_id, data}`.
  `sender_device_id` is the device id the sending WebSocket authenticated with (from the access token), never a value
  from the client's envelope, and it is an opaque string: compare it byte for byte. A message that was stored for an
  offline recipient and is replayed later (`msg_pending_sync`, entries of `msg_type` `opaque`) carries the same
  `sender_device_id` field in the entry, so a replayed ACCEPT or KCMAC is matched exactly like a live one.
- The caller records, at binding (R-COMMIT-BIND), the `sender_device_id` of the envelope that carried the ACCEPT it
  bound. If that field is absent (a message the server stored before it recorded the field) there is no device to match,
  so no KCMAC will pass and the call ends at the KCMAC window: fail closed, never an unfiltered judgment.
- From then on the caller judges only a KCMAC whose envelope `sender_device_id` equals the recorded value. A KCMAC from
  any other device, or one without the field, is dropped silently. It is never judged, never produces
  `kcmac_mismatch`, is not held and does not shorten or extend any window (§3.7.1, sender-device rule).
- The REVEAL's `acceptBinding` (the callee-side sibling test) is unchanged; this rule is its caller-side counterpart.

**SAS scope (R-COMMIT-SAS).** The SAS of a call is the round-1 SAS of §4, held or not, before and after any rekey: no
platform computes or shows words for a round >= 2, and there is no SAS without `sasNonce`. A SAS confirmation pins
round 1's `signerIdentityKey` and is refused if any round of the call was signed by another key. R-HELD-REKEY is
unchanged: a caller defers rekeys while held.

**Close reasons (R-COMMIT-REASONS).** These are security-class reasons and notify the peer like `kcmac_mismatch`.
The table also maps every confirmation timer of §3.7.1, §3.7.4 and §3.8.4 to its reason:

| Reason | Cause |
|---|---|
| `sas_commit_mismatch` | ill-formed REVEAL naming this device's ACCEPT, a nonce that does not open the commitment, or a second different REVEAL |
| `sas_reveal_timeout` | no verified REVEAL `CONFIRM_TIMEOUT` (15 s) after this device first sent its ACCEPT |
| `kcmac_mismatch` | (existing) a MAC equal to a round's expected peer MAC with the wrong role byte; no verified peer KCMAC within a round's window, superseded rounds included: 15 s from arming, round 1 caller 30 s after its REVEAL was handed to the transport, round 1 callee 15 s after its own REVEAL verified, rekey acceptor 30 s from arming (§3.7.1); a 17th pending round (R-KCMAC-ROUNDS) |
| `dtls_fp_mismatch` | (existing) a fingerprint mismatch, or no verdict of check (b) within `CONFIRM_TIMEOUT` (15 s) after `connected` (§3.8.4) |
| `handshake_malformed` | (existing) now also: missing, misplaced, non-canonical or wrong-length `sasCommit`, a first OFFER whose round is not 1, and a callee call without a `callId` (R-ANSWER-FIRST) |

The sibling exit is not a security reason. Telemetry carries verdicts only: callee `{event:"sas_commit",
result:"ok"|"mismatch"|"timeout"|"sibling"}`, caller `{event:"sas_commit", result:"revealed"|"resent"}`. A timer
expiry additionally emits the `confirm_timeout` event of R-CONFIRM-TELEMETRY.

**Duplicates, reordering, replays.** The server stores opaque messages for a recipient without a fresh socket and
replays them at authentication, possibly duplicated and up to 24 h old, so receivers MUST NOT rely on arrival order
across reconnects.

| Message | At | Action |
|---|---|---|
| identical OFFER | callee | re-send the cached ACCEPT if already sent, otherwise drop |
| OFFER, first for the callId, round != 1 | callee that has a call context for the callId and no OFFER yet | `handshake_malformed` |
| OFFER for a callId without a call context yet (it overtook `call_incoming`) | callee | not a valid first OFFER (round != 1, no valid `sasCommit`): drop, create no state, no hangup. Valid: pending-OFFER rule above |
| OFFER for a callId that ended or was answered elsewhere | callee | drop, create no state |
| rekey OFFER carrying `sasCommit` | callee | `handshake_malformed` |
| byte-identical copy of the round-1 ACCEPT | caller | before binding, drop only (no event); once round 1 is bound, re-send the identical REVEAL (one re-send event of the budget of 4) and do nothing else, whether or not a rekey round is waiting (R-REKEY-ACCEPT-WAIT case 1) |
| different round-1 ACCEPT after binding | caller | drop |
| identical REVEAL after verification | callee | drop |
| different REVEAL naming own ACCEPT after verification | callee | `sas_commit_mismatch` |
| REVEAL naming another ACCEPT | callee | sibling rule |
| KCMAC whose envelope `sender_device_id` is not the bound ACCEPT's (or is absent) | caller | drop silently, no `kcmac_mismatch` (R-COMMIT-KCMAC-DEVICE) |
| callee round-1 KCMAC before the callee's own REVEAL verified | callee | never sent (R-COMMIT-KCMAC-HOLD) |
| KCMAC whose 32-byte MAC part equals one already verified for a round (role byte not compared) | either | drop silently, no judgment (R-KCMAC-ROUNDS step 2) |
| KCMAC of an earlier round that is still pending, arriving after a later round was armed | either | verifies THAT round (step 3), never judged against the later round |
| KCMAC that matches no pending round, or malformed | either | held (at most 8, stale after 30 s, stale entries dropped before a new MAC is held) and offered again when a round is armed, or dropped if malformed; never ends the call by itself (steps 1, 4) |
| ACCEPT of an earlier rekey round (bound, refused or abandoned), byte-identical or not, while another rekey round is waiting or none is | offerer | drop silently: no state, no event, no budget, no close reason, and a waiting round is not touched, cleared, failed or closed (R-REKEY-ACCEPT-WAIT case 3) |
| second ACCEPT for a waiting rekey round, or an ACCEPT that reaches the offerer at T0 + 30 s or later | offerer | drop silently, as above (R-REKEY-ACCEPT-WAIT, Reach, case 3) |
| ACCEPT of a waiting rekey round that reached the offerer before T0 + 30 s and is still being processed at T0 + 30 s | offerer | processed to completion, the deadline does not abort it (R-REKEY-ACCEPT-WAIT, Processed to completion) |
| rekey ACCEPT of a round the acceptor refused, never armed, abandoned, decided, or whose window ended | acceptor | never re-sent, no message added to a re-send event, no budget use (R-ACCEPT-RESEND) |
| any message other than an OFFER (see the pending-OFFER rule above) for an ended or unknown callId | both | drop, create no state |

**Logging (R-COMMIT-LOG).** Never log `sasNonce`, `sasCommit`, `acceptBinding`, transcript hashes or SAS words; at most
a verdict and 8-character call ids.

**What does not change (R-COMMIT-UNCHANGED).** The session key, KCMAC, frame keys (the labels containing `-v5` in
§3.7.2 name the frame-key scheme and stay), the relay sealer, the DTLS binding (§3.8) and every media gate keep their
formulas over the v6 transcripts. Only the TIMING of the callee's round-1 KCMAC and the confirmation windows change
(R-COMMIT-KCMAC-HOLD, R-CONFIRM-TIMEOUT). `sasNonce` enters no key and no MAC; `kc_transcript` covers the commitment only
through `offerBinding`.

### 3.8 DTLS certificate binding

Each 1:1 client binds its DTLS certificate to the signed handshake (§3.7) and verifies, at the SDP level and at the
transport level, that the certificate negotiated by DTLS is the one that was signed. Without this, anyone who can
modify signalling JSON can rewrite `a=fingerprint` in the plaintext SDPs (`call_offer`, `call_incoming`,
`call_answer`, `call_upgrade_*`, ICE-restart re-offers, `DC_SDP_*`) and terminate DTLS on both legs. The server
relays SDP byte-for-byte, never parses `opaque_message` or `a=fingerprint`, and MUST keep doing so.

Each client generates a fresh ECDSA P-256 certificate per call, before it signs anything, and passes it to the
PeerConnection (`RTCConfiguration.certificates`). The certificate is never reused across calls, so calls stay
unlinkable. There is no DTLS trust-on-first-use.

**R-CERT: the certificate and its context are pinned per call.** A call's DTLS certificate, its `fpSelf` and the
context that holds them (including the PeerConnection reference and `fpPeer` once pinned) live exactly as long as the
call. A client:
- MUST NOT evict the context of a live call from any cache or table (an LRU or a size cap may only evict contexts of
  calls that have ended; offers for other callIds, from the same peer or from anyone else, never displace it);
- MUST NOT generate a new certificate for a `callId` that has already signed a bundle, and in particular not on a
  rekey round: every bundle of the call carries the same `fpSelf`. If the context of such a call is missing when it is
  needed, the call ends with `dtls_fp_mismatch`; it does not silently mint a new certificate;
- MUST create every PeerConnection of the call (the first one and any re-created one after a reconnect or media
  move) with that same pinned certificate;
- MUST bound the table for contexts of calls that are not yet live (pending offers) separately, so that flooding it
  cannot evict a live call.

#### 3.8.1 Canonical fingerprint

- **Binary form (transcript):** `DTLSFP = u8(alg) ‖ digest`.
  - `alg = 0x01` means SHA-256, and `digest` is 32 bytes. That makes the field 33 bytes. No other algorithm is
    valid.
  - The digest is SHA-256 over the DER encoding of the X.509 certificate. That is what libwebrtc puts in
    `a=fingerprint` (`SSLFingerprint::Create`).
- **Text form (JSON bundle field `dtlsFingerprint`):** `"sha-256 " ‖ HEX`.
  - HEX is 32 upper-case hex byte pairs joined by `:`.
  - Regex: `^sha-256 [0-9A-F]{2}(:[0-9A-F]{2}){31}$`.
  - Receivers MUST reject any other spelling: lower-case, no colons, other algorithm, extra whitespace. This keeps the
    form non-malleable.
- **Computing your own fingerprint:**
  - Android: `RtcCertificatePem.certificate` PEM → base64-decode the body → DER → SHA-256.
  - iOS: `RTCCertificate.certificate` PEM, same procedure.
  - Desktop: `RTCCertificate.getFingerprints()`. Take the entry whose algorithm is `sha-256` and upper-case its value.
  - Desktop MUST also check that it is the only `sha-256` entry.

#### 3.8.2 Call-setup ordering (MUST)

1. At call start, generate the certificate and compute `fpSelf`. Then create the PeerConnection with that
   certificate.
2. Sign and send your bundle only after `fpSelf` is known.
3. Never call `setRemoteDescription` before the peer's bundle has been received and passed these steps:
   - It parses.
   - `sigV6` has gone through the policy (§3.8.6).
   - `fpPeer` is pinned for the call.
   Remote SDP that arrives earlier is buffered. A callee device creates its PC and certificate only after the user
   answered (R-ANSWER-FIRST, §3.7.4), and defers SRD until the OFFER bundle has been processed.
   The SAS REVEAL (§3.7.4) is not a precondition of SRD or of any media gate: only the callee's SAS waits for it.
4. The acceptor sends ACCEPT **before** `call_answer`, so the offerer normally has `fpPeer` before the answer
   arrives. The offerer still buffers the answer if it does not.
5. `fpPeer` is pinned once per call. Later bundles (rekey rounds) MUST carry the same `fpPeer`, and the re-signed
   own `fpSelf` must be unchanged (R-CERT above).

#### 3.8.3 Check (a): SDP

`checkSdp(sdp, expectedFp)` passes iff all of the following hold:

- There is at least one `a=fingerprint:` line (session or media level, whether a line ends in CRLF or LF).
- Every line is exactly `a=fingerprint:<alg> <hex>` (a single space, no other characters before the line end, so
  trailing whitespace fails), where `<alg>` equals `sha-256` (ASCII case-insensitive, RFC 8122).
- For every line, `<hex>` upper-cased equals the canonical HEX of `expectedFp`.
- There are no other hash algorithms and no differing values.

When it is applied:

- **Remote SDP:** before SRD, with `expectedFp = fpPeer`. This covers every remote description: offer, answer,
  pranswer, renegotiation, ICE restart, `call_upgrade_*` and `DC_SDP_*`.
- **Local SDP:** before sending and after any munging (forcing the passive DTLS role, codec rewrites), with
  `expectedFp = fpSelf`.

On failure: do not apply or send the SDP, end the call with reason `dtls_fp_mismatch`, and emit telemetry
`{event:"dtls_fp", result:"mismatch", stage:"sdp_remote|sdp_local"}`. The telemetry carries no values.

ICE restart and the video or screen upgrade (§8) are ordinary renegotiations. The certificate is constant per PC, so
on honest paths the check always passes. ICE ufrag/pwd and candidates are deliberately **not** bound: once DTLS is
authenticated, ICE manipulation can only cause loss, and loss is already in the threat model.

#### 3.8.4 Check (b): negotiated certificate

Trigger it on every transition of a DTLS transport, or of the PC `connectionState`, to `connected`. Then:

1. Call `getStats()`.
2. For each `transport` stats entry with `dtlsState == "connected"`, compare:
   - `certificate[remoteCertificateId]`: `fingerprintAlgorithm` must equal `sha-256` (case-insensitive), and the
     upper-cased `fingerprint` must equal the canonical HEX of `fpPeer`.
   - `certificate[localCertificateId]`: the same comparison against `fpSelf`.
3. Stats are missing or incomplete: retry every 250 ms for up to `CONFIRM_TIMEOUT` (15 s, §3.7.1) after the transition to
   `connected`, then fail. Each such transition starts its own check and its own 15 s. The media gate below stays
   closed for the whole retry.

The media gate is the AND of this check and all existing gates (SAS hold, attach gates):

- Local audio and video tracks are `enabled = false`.
- Remote audio playout is muted and remote video is not rendered.
- The FrameCryptor is **never** disabled as a gate, because a disabled cryptor passes clear text.

A pass opens the gate. A fail ends the call with `dtls_fp_mismatch` and telemetry `stage:"stats"`. No verdict within
`CONFIRM_TIMEOUT` (15 s) of `connected` is a fail; that expiry (as opposed to a verified mismatch) additionally emits
the `confirm_timeout` event with `timer:"dtlsfp_stats"` (R-CONFIRM-TELEMETRY, §3.7.4).

#### 3.8.5 Relay fallback (no DTLS)

On the WS relay there is no DTLS, so (b) does not apply. (a) still applies to any SDP the call exchanges. What
protects relay media:

- The inner `PqcRtpFrameSealer`: directional AES-256-GCM keys derived from the v6 transcript-bound session key, with
  an anti-replay window (Android 256, iOS 1024, desktop `ReplayWindow`).
- The SPKI-pinned client↔server TLS connection.

The server can still drop, delay and observe metadata, which is inherent to a relay.

If a call upgrades from relay to P2P or TURN, (a) and (b) apply at the moment of the upgrade. TURN-relayed ICE is
still DTLS end to end, so it is fully covered.

#### 3.8.6 Failure policy

- A fingerprint mismatch (a, b, a changed fingerprint in a rekey round, or a differing `fpPeer`) never has a benign
  cause. It ends the call with reason `dtls_fp_mismatch`. It is NOT the hold-pending-SAS path and no SAS comparison
  can override it.
- A bundle without `sigV6`, without `dtlsFingerprint` or without a valid `rekeyRound` ([1, 4294967295]) is malformed (every
  client emits all three) and ends the call with reason `handshake_malformed`. So does a bundle with a missing,
  misplaced, non-canonical or wrong-length `sasCommit`, a first OFFER whose `rekeyRound` is not 1, and any JSON
  decode failure of a bundle routed as a handshake bundle (§3.1, §3.7.4).
- An *invalid* signature or an unknown identity key aborts the handshake and holds media pending SAS, as before. The
  SAS covers both fingerprints (§3.7.1), so confirming a matching SAS also authenticates them.
- A KCMAC failure ends the call with reason `kcmac_mismatch` (§3.7.1).
- A REVEAL that does not open the commitment ends the call with `sas_commit_mismatch`, and a callee that gets no
  verified REVEAL within `CONFIRM_TIMEOUT` (15 s) of sending its ACCEPT ends it with `sas_reveal_timeout` (§3.7.4).

The identity pins (Ed25519 trust on first use) are the anchor for `sigV6` and are unchanged. The DTLS certificate is
not pinned across calls. Group calls are unaffected: §10.2 pins the SFU certificate.

---

## 4. Short Authentication String (SAS)

```
SAS-IKM   = sessionKey of round 1 (32 B, the transcript-bound key of §3.7.1)
SAS-INFO  = "q-audion-sas-v6" ‖ SHA-256(ACCEPT_v6 of round 1) ‖ sasNonce      (15 + 32 + 32 = 79 B)
SAS-KDF   = HKDF-SHA256(IKM=SAS-IKM, salt="qaudion-sas-v1", info=SAS-INFO, L=18)
indices   = 6 × uint24 read big-endian from SAS-KDF (3-byte stride, consuming
            all 18 bytes: idx[i] = (out[3i]<<16)|(out[3i+1]<<8)|out[3i+2])
words     = PGP even-word list[indices[i] mod 256] for i in 0..5
            (the wordlist has exactly 256 entries)
```

- The SAS is the one of ROUND 1, on every platform, whether the call is held or not and before or after any rekey
  (R-COMMIT-SAS, §3.7.4). The caller computes it once it has sent the REVEAL, the callee once the REVEAL verified.
  There is no SAS without `sasNonce`: no fallback derivation exists.
- All label strings above are raw ASCII octets, passed to HKDF verbatim (`salt` = the 14 bytes of `qaudion-sas-v1`).
- The number of words is a single constant per platform (6 words, 48 bits). It MAY later be reduced for display only
  without any change to this derivation.
- The info label `q-audion-sas-v6` is the version separator; the salt `qaudion-sas-v1` is unchanged. The earlier
  labels `q-audion-sas-transcript` and `sas-words-v1` are retired.

The SAS is transcript-bound over `ACCEPT_v6` (§3.7): `ACCEPT_v6` commits, through `offerBinding`, to both identity
keys, both sides' key-exchange material, both capability sets, both PSK adverts, both DTLS fingerprints (§3.8) and the
caller's SAS commitment, and `sasNonce` opens that commitment. A successful SAS comparison therefore also
authenticates both fingerprints. With the commitment, a man in the middle that controls both legs gets the words of
the two legs to match with probability 2^-48 per call attempt (2^-8w when the users compare only w words), whatever
its compute budget.

All platforms MUST produce byte-equal SAS for the same session key, the same `ACCEPT_v6` hash and the same `sasNonce`.
Cross-platform KAT vectors: `tools/kat/handshake-sig-v6/` (`commit`, `sas`, `reveal` and `kdf` sections). The vector
`design-check` of the `sas` section pins the derivation on synthetic inputs (an independent third implementation):

```
callId     5a1c0de5-0000-4000-8000-000000000006
sasNonce   000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
sasCommit  c8a3b16610b678b555f74ec265566ffde23291041c80cd1dc0c3d98951ca3368
sessionKey 32 bytes of 0x11 (synthetic input)
acceptHash 78c373629a88841eb5d67829551c86d127f3e62fa7b317ad8144029f399af43d   (= SHA-256("design-check ACCEPT_v6 bytes"))
SAS-KDF    a67d24be7c14857704ea33918284878fef43
words      bluebird baboon adrift pheasant Neptune crucial
```

---

## 5. Open gaps / planned (P1)

| Item | Owner | Issue |
|---|---|---|
| iOS responder JSON-HandshakeBundle | iOS engine | ✅ done 2026-05-06: AndroidHandshakeBundle.swift + QAudionCallIntegration.onAndroidBundleReceived |
| iOS originator JSON-HandshakeBundle (engine layer) | iOS engine | ✅ done 2026-05-06: QAudionCallIntegration.onAndroidCallSetupStarted emits dual JSON+QUAD OFFER, ACCEPT branch decapsulates ML-KEM + X25519 against the stashed local privs (callId-keyed, double-ACCEPT-guarded, key-zeroized after initSession) |
| iOS originator JSON-HandshakeBundle (UI/WS plumbing) | iOS app | ✅ done 2026-05-06: CallService.beginAndroidOutgoing + AppState.startCall wiring + 2 new CallingApi methods (sendCallOfferWithId, sendCallHangupForId) for explicit callId management. Cross-validated glm-5.1 — applied 7 review fixes. |
| iOS KMS 3-tier decrypt + ML-KEM registration | iOS engine | ✅ done 2026-05-06: KmsTransport.swift (classical / binding-hybrid / legacy-KEM tier discrimination by package length, narrow auth-fail catch for the binding-hybrid retry, structured error enum, round-trip self-tests in KmsTransportTests.swift). BCryptoKmsClient.registerPublicKey extended with optional mlkemEncapKey field. |
| iOS KMS sovereign-vault import | iOS app | ✅ done 2026-05-06: KmsPollerService.swift wraps poll → 3-tier decrypt → SovereignKeyVault.storePsk (Keychain-backed, kSecAttrAccessibleWhenUnlockedThisDeviceOnly) → acknowledge. Fingerprint = full SHA-256 hex per WIRE_SPEC §3.3 so the persisted PSK is immediately usable by the PqcHandshake fingerprint-negotiation lex-sort intersection. |
| iOS KMS device-key persistence | iOS app | ✅ done 2026-05-06: DeviceKeyManager.swift generates X25519 + ML-KEM-1024 keypairs ONCE, persists privs+pubs to Keychain via SovereignKeyVault namespacing (`__device.x25519.{priv,pub}`, `__device.mlkem.{priv,pub}`), and registers pubs idempotently via `BCryptoKmsClient.registerPublicKey(publicKey:, mlkemEncapKey:)`. ensureProvisioned() is the canonical app-launch hook; currentKeys() the read-only fast-path for the WS `kms_key_available` handler. |
| iOS KMS app-level wiring | iOS app | ✅ done 2026-05-06: AppState.runKmsSweep() helper + initial sweep right after WS auth + per-event sweep on every `kms_key_available` push. BCryptoBackendProvider.kmsClient lazy var mirrors accountApi/contactsApi pattern. The full iOS KMS pipeline is now end-to-end functional. |
| Desktop PSK fingerprint negotiation | Desktop | ✅ done 2026-05-06: vault.list().map(p => p.fingerprint) feeds generateOffer + lex-sort intersection on responder |
| Cross-platform KAT vectors — SAS | tools/kat/sas | RETIRED 2026-10-01: the transcript-less SAS (`info = "sas-words-v1"`) no longer exists (§4). The SAS vectors are the `commit`, `reveal` and `sas` sections of `tools/kat/handshake-sig-v6/handshake-sig-v6-kat.json`; `tools/kat/sas/sas-kat.json` is deleted and every client drops its test of it. |
| Cross-platform KAT vectors — Hybrid PQC combine | tools/kat/hybrid-combine | RETIRED 2026-10-01: those vectors pinned the session key WITHOUT the transcript hash in `info`, a variant that no longer exists (§3.7.1). The session key vectors are the `kdf` section of `tools/kat/handshake-sig-v6/handshake-sig-v6-kat.json`; `tools/kat/hybrid-combine/` and `tools/kat/hybrid-combine-kat.json` are deleted and every client drops its test of them. |
| Cross-platform KAT vectors — handshake v6 | tools/kat/handshake-sig-v6 | 2026-10-02: `handshake-sig-v6-kat.json`, byte-identical in the four repos, sha256 pinned in each (server: `tools/kat/katpin_test.go`). Sections: `certVectors`, `canonical`, `sdp`, `commit`, `transcripts`, `kdf`, `sas`, `frameKeys`, `reveal`, `bundle`, `sequences`, `negative`. The server recomputes every positive vector independently in Go (`tools/kat/handshake-sig-v6/kat_v6_verify_test.go`). The v5 file is deleted. |
| Cross-platform KAT vectors — PSK negotiation | tools/kat/psk-negotiation | ✅ done 2026-05-06: tools/kat/psk-negotiation/psk-negotiation-kat.json (6 vectors: no-intersection, single-match, lex-sort-required, reversed-offer, partial-overlap, empty-offer) mirrored byte-equal in all 4 repos. Verifiers on Android (PskNegotiationKatTest.kt), Desktop (PskNegotiation.kat.spec.ts), iOS (PskNegotiationKatTests.swift) load the JSON + assert `selected = sort(offerSet ∩ localSet, lex-asc)[0]` produces the pinned answer regardless of input ordering. Pins WIRE_SPEC §3.3. |
| Cross-platform KAT vectors — KMS round-trip | tools/kat/kms | ✅ done 2026-05-06: tools/kat/kms/kms-roundtrip-kat.json (4 vectors: 2 classical + 2 binding-hybrid, each 92 bytes) mirrored byte-equal in all 4 repos. Reference Python encryptor uses `cryptography` package (X25519 + AES-GCM) with WIRE_SPEC §2 canonical labels. Verifier tests on Android (KmsRoundTripKatTest.kt, BouncyCastle X25519 + javax AES-GCM), Desktop (KmsRoundTrip.kat.spec.ts, noble x25519 + node crypto), iOS (KmsRoundTripKatTests.swift, exercises production KmsTransport.decryptPackage) decrypt every package back to the pinned PSK. Legacy KEM-hybrid (1628+ B) requires a real ML-KEM keypair to be deterministic — separate KAT planned. |
| Capabilities negotiation in JSON OFFER | Android+Desktop | Add `wireFormats: [...]` so peer can pick the lowest common denominator |

---

## 6. Versioning

Wire-format changes follow these rules:
1. Add a new field with a default value that older peers ignore.
2. Bump a `v` integer in `capabilities` when adding a binary-incompatible
   change so peers can detect mismatches up front.
3. Never repurpose existing fields. If you need a different shape,
   add a new field name.

Before launch, a binary-incompatible format change is a HARD SWITCH. All clients change in the same release
train, the old format is deleted instead of negotiated, and no capability bit, flag or fallback keeps it alive.
Rules 1-3 above apply from the first public release on. The signed transcript v6 (with the DTLS certificate binding
and the SAS commitment, §3.7, §3.7.4, §3.8), the frame IV counter change (§11) and the file format v2 (§12) are hard
switches of this kind.

A new version of a file message (the `qa_file` member of §12.7.1) is a binary-incompatible change. Until a signed
per-device announcement of the highest file message version it reads is defined in this specification, a sender MUST
emit version 2 only; a group sender uses the lowest version announced by every current member device; a device that has announced nothing
is taken to read version 2 only. A receiver that meets a version it does not know follows §12.7.1
(`unsupported_version`).

---

## 7. Earbud key-import GATT family (0xc0–0xca)

Canonical 128-bit characteristic UUIDs for the earbud (nRF firmware).
FROZEN cross-platform contract — iOS / Android / Desktop MUST use these
EXACT UUIDs when relaying sovereign-key import + Proof-of-Possession to
the earbud. Source of truth: `firmware/nspe/src/transport/qaudion_gatt.c`.

**Base UUID pattern:** `f2c0aaaa-bcc0-4001-8000-0000000000XX`, where
`XX` is the opcode's last byte (`qaudion_gatt.c:374`).

| Opcode | Name | Dir | Purpose | Cite |
|---|---|---|---|---|
| 0xc0 | ATTEST_INFO | read | pk_se(32) || earbud_id | `qaudion_gatt.c:376` |
| 0xc1 | ATTEST_POP | read | 32-byte SE PoP (relay to /kms/ack-pop) | `qaudion_gatt.c:377,396` |
| 0xc2 | ATTEST_PQ | read | pk_pq (ML-KEM pub, 4×392 B chunked) | `qaudion_gatt.c:378` |
| 0xc3 | KEY_IMPORT | write | sealed package + PoP inputs; read-back `[status:u8][slot:u8]` | `qaudion_gatt.c:379,385-397` |
| 0xc4 | MEDIA_KEY_INSTALL | write | 60-B sealed PQ-ratchet media key (Phase 18) | `qaudion_gatt.c:334-337,380` |
| 0xc5 | PAIR_BEGIN | write | FE-5 earbud-excl msg1 = pk_se(32)\|\|pk_pq(1568)\|\|eid(32) | `qaudion_gatt.c:345,381` |
| 0xc6 | PAIR_RESP | read | FE-5 msg2 = pk_se(32)\|\|ct_ee(1568)\|\|eid(32) | `qaudion_gatt.c:346,382` |
| 0xc7 | PAIR_FIN | write | FE-5 msg3 = SAS-confirm MAC (seals ss_ee in NVS) | `qaudion_gatt.c:347,383` |
| 0xc8 | FP_ADV_REQUEST | write+read | write 32-B ct_bind; read 40-B fp_adv[32]\|\|epoch_le[8] | `qaudion_gatt.c:355-358` |
| 0xc9 | KC_CONFIRM | read | diagnostic kc_mac (zeroed transcript) after FP_ADV write | `qaudion_gatt.c:360-363` |
| 0xca | PSK_LIST | read | active hw_only PSK list: `[n:1] + n×[epoch_le8(8)+fp(32)]` | `qaudion_gatt.c:365-368` |

**0xc4 MEDIA_KEY_INSTALL wire format** (`qaudion_gatt.c:334-336`):

```
nonce(12) || AES-256-GCM(ble_session_key, nonce, media_key(32),
                         aad="qa/v4/mkd/v1")(32 + 16 tag)   = 60 bytes
```

The SPE handler `nsc_import_media_key` (`firmware/spe/src/secure_services.c:2384-2448`)
unseals with the SPE-resident `ble_session_key` and stages via
`audio_pipeline_set_session_key`. AAD = `qa/v4/mkd/v1` (12 B, no NUL —
`secure_services.c:2386`).

**0xc4 replay-counter status (no dedicated monotonic counter today):**
unlike the HANDSHAKE_INIT path (explicit per-connection 8-bit `hs_counter`
anti-replay, `qaudion_gatt.c:655-781`), the 0xc4 write carries NO dedicated
monotonic replay counter. Replay resistance currently relies on (1) the GCM
AEAD tag and (2) the freshness of `ble_session_key` (re-derived per BLE
handshake — a 0xc4 frame from a previous session cannot be replayed because
the session key differs). A within-session replay window is NOT closed; a
dedicated 0xc4 counter is a planned hardening (audit D10-3).

---

## 8. Mid-call media upgrade (video / screen) — state machine & readiness

Added 2026-07-03. Until this section existed, the upgrade protocol had NO
written contract: each client re-derived it from the others' commits, every
protection (DTLS pin, glare rule, phantom guard, rollback) shipped on one
platform/role only, and the recurring black/purple-video class was the
result. This section is NORMATIVE for all three clients and the server.

### 8.1 Message inventory (WS envelope `{type, data}`)

| type | data | dir | server behavior |
|---|---|---|---|
| `call_upgrade_request` | `{call_id, recipient_id, sdp, media}` | initiator→peer | stamp `sender_id`, transparent relay; federated cross-node |
| `call_upgrade_response` | `{call_id, recipient_id, sdp, accepted}` | peer→initiator | same |
| `call_video_state` | `{call_id, recipient_id, ...}` | either | same |
| `screen_share_state` | `{call_id, recipient_id, on}` | either | same |
| `call_media_ready` (v1.1) | `{call_id, recipient_id, mid, key_epoch, dir}` | receiver→sender | same |
| `video_keyframe_request` (v1.1) | `{call_id, recipient_id}` | receiver→sender | same |
| `call_video_pause_request` (v1.3) | `{call_id}` | either→peer | stamp `sender_id`, resolve peer via `resolveCallPeer`, transparent relay |

- `media` = `"camera"` (explicit consent dialog required) or `"screen"`
  (auto-accept). An UNKNOWN value MUST be treated as `"camera"`
  (fail-safe: consent required). The field is part of the wire contract —
  any server implementation that re-marshals typed structs MUST carry it.
- `sdp` non-empty ⇒ WebRTC renegotiation. `sdp` empty ⇒ WS-relay rail
  (no live PC); `accepted=true` with empty `sdp` is an accept WITHOUT
  renegotiation, not a malformed response.
- `call_video_pause_request` (v1.3) is deliberately OUTSIDE the consent model
  above: it asks the receiver to turn off ITS OWN camera, never to turn one
  on, so it carries no `media` field and needs no consent dialog — a receiver
  auto-complies (drives the same local path as the user's own camera-off
  toggle) and only surfaces a brief notice. No `recipient_id`/`sender_id` on
  the wire (server resolves the peer via `resolveCallPeer`), same convention
  as `call_accepted`.

### 8.2 Upgrade state machine (per side)

```
AudioOnly
  --local request sent----------------→ UpgradeRequested(local)
  --peer request received-------------→ ConsentPending(remote)
UpgradeRequested(local)
  --response accepted+sdp-------------→ Renegotiating
  --response accepted, empty sdp------→ VideoActive (WS-relay rail)
  --response declined OR 30s timeout--→ AudioOnly   [ROLLBACK, §8.4]
ConsentPending(remote)
  --user accepts----------------------→ Renegotiating (answer shipped)
  --user declines OR 30s auto-decline-→ AudioOnly   (send accepted=false)
Renegotiating
  --answer applied / answer shipped---→ VideoActive
  --failure---------------------------→ AudioOnly   [ROLLBACK, §8.4]
VideoActive
  --video toggled off (both dirs)-----→ AudioOnly   (state msg, no SDP teardown)
```

Timeouts are ALIGNED at **30 s** on both roles (requester watchdog AND
responder auto-decline). A decline/timeout MUST leave both sides able to
upgrade again later in the same call.

### 8.3 Glare (simultaneous upgrade requests)

Politeness is keyed to the ORIGINAL call role, not the upgrade role:
**polite = original CALLEE, impolite = original CALLER.**

- Polite peer, on receiving `call_upgrade_request` while its own request
  is in flight: JSEP-rollback its pending local offer, answer the peer's
  offer, and treat its own request as satisfied by the resulting video
  state.
- Impolite peer: ignore the peer's colliding request (no decline) and
  wait for the response to its own.
- TRANSITIONAL (until all clients implement the rule): degrading to a
  clean mutual decline is permitted, but MUST NOT poison state — both
  sides MUST be able to retry (§8.4).
- A responder MUST NOT silently drop a colliding request (that leaves
  the requester burning its full timeout).

### 8.4 Rollback obligations (decline / timeout / failure)

The initiator MUST undo everything its request did, atomically w.r.t.
later upgrades:

1. stop the camera capture it started;
2. remove the local video track added for the upgrade;
3. JSEP-rollback the pending local offer (PC returns to `stable`);
4. clear the upgrade-in-progress latch and re-arm the duplicate-answer
   guard for the ORIGINAL call answer.

A PC parked in `have-local-offer` after a decline is a protocol violation
(it makes the peer's next offer fail wrong-state → auto-decline → upgrades
dead in both directions).

### 8.5 DTLS role invariant

The `a=setup` role negotiated by the ORIGINAL call answer NEVER changes
across any renegotiation (upgrade, ICE restart, screen-share stop, …).
BOTH sides MUST pin the role on EVERY applied answer — the upgrade
envelope path AND any generic remote-SDP path. (History: the pin shipped
offerer-side only, per-platform, months apart; iOS never had it.)

### 8.6 m-line / mid stability & the phantom transceiver

- A 1:1 call has exactly ONE video m-line per direction pair. Reuse the
  existing video transceiver on re-upgrade; never add a second one.
- PHANTOM: on a callee-initiated upgrade, libwebrtc (observed M144) can
  mint an extra RECV_ONLY video transceiver with no sender track. It MUST
  be ignored: renderer sink and receiver-cryptor stay bound to the
  ESTABLISHED mid. "Last receiver wins" sink policies are forbidden.
- If a legitimate re-negotiation lands the video on a NEW mid, the
  receiver MUST re-latch sink + cryptor to the new mid (and MAY treat the
  old one as closed).

### 8.7 Media readiness & keyframe recovery (v1.2)

- `call_media_ready`: the RECEIVER sends it when its receiver-cryptor is
  BOTH keyed and bound to the negotiated video mid. The SENDER SHOULD
  hold video TX (camera or gate) until ready arrives or a **2 s** timeout
  elapses (timeout ⇒ proceed as today — the handshake is an optimization
  for correctness, never a hard gate: signal-not-kill). On receiving
  ready for the FIRST key of that media kind in the call, the sender MUST
  force an IDR. In a 1:1 call `key_epoch` is the key round epoch `E` of §3.7.2
  (`E = rekeyRound - 1`), so the first video key of a call that starts audio-only
  and upgrades to video in round R carries `key_epoch = R - 1`, not 0; the
  force-IDR rule is keyed on "first ready for this media kind", never on the
  number 0.
- `video_keyframe_request`: receiver→sender; the sender MUST force a
  local encoder IDR. Senders rate-limit to 1/s. Rationale: the E2EE
  frame-transform suppresses libwebrtc's native PLI on every platform,
  so decoder recovery REQUIRES an explicit wire path. Platforms SHOULD
  additionally run a periodic (~5 s) sender-side IDR forcer.
- Rekey: `key_epoch` is monotonic per call. In a 1:1 call it is the key
  round epoch `E` of §3.7.2, shared by audio and video; the two media kinds
  are tracked INDEPENDENTLY only in WHEN each kind switches its sender to a
  new epoch and releases the old one (audio and video can be at different
  epochs at the same instant), not in how the epoch is numbered. Receivers keep the PREVIOUS key valid for a grace window
  (mirror of the audio `previousKey` fallback) so in-flight frames sealed
  under the old epoch still decrypt.
- **Re-key media-deafness fix (v1.2, 2026-09-04)** — `call_media_ready`
  gained a `media` field (`"audio" | "video"`, additive; a receiver that
  predates it treats an absent value as `"video"`, the only kind that
  existed before) and is now sent on EVERY re-key (`key_epoch > 0`), not
  just once per call. On deriving a new epoch's key, a device MUST
  install it into its own decode ring IMMEDIATELY (decode is driven
  purely by the on-wire `key_epoch`, never by the device's own sender
  state, so this needs no coordination) and SHOULD defer switching its
  OWN sender to the new epoch until it receives the peer's
  `call_media_ready` for that exact `(media, key_epoch)` pair or the same
  **2 s** timeout elapses (identical signal-not-kill bound as the
  original epoch-0 case — an old peer that never sends a per-epoch ready
  always falls through this same timeout, so the fix degrades cleanly
  against an unpatched peer). This is why decode-readiness and switch
  timing are two separate concerns on this field going forward: a
  `call_media_ready` with `key_epoch > 0` means "I installed your new
  epoch, safe for you to switch to it" and MUST NOT be conflated with the
  original epoch-0 semantics ("I'm bound, force an IDR") — a receiving
  platform needs its own equivalent of only reacting to a `key_epoch > 0`
  ready when it is actually the epoch that platform's own re-key
  machinery is waiting on, not merely because the number is nonzero (a
  legacy per-call reannounce for stall recovery also carries whatever the
  LIVE epoch happens to be at the time, not a hardcoded 0).

### 8.8 Transport rails & key custody

- The WebRTC RTP rail is primary whenever a live PC exists. The WS-relay
  video rail (`video_frame` fragments) is armed ONLY while the frame-relay
  transport reports `BcryptoWsRelay` AND video is active.
- Relay-rail PQC sealers are OWNED by the call controller for the whole
  call; transient transport legs BORROW them by reference and MUST NOT
  dispose them on their own close(). ("Who creates, disposes; transports
  borrow.")
- The server relays media frames only between the two REGISTERED call
  parties; a party-gate miss drops the FRAME (advisory
  `call_relay_reject {call_id, media, reason}`) and MUST NOT tear the
  call down.
- When an `audio_frame` relay fails because the recipient has zero
  registered devices locally (peer's WS connection is down/flapping),
  the server sends the SENDER an advisory
  `audio_relay_degraded {call_id, peer_id, recipient_online}` (added
  2026-07-13), at the same sampled cadence as the server-side warn log
  (frame 1-3, then every ~500 frames — never more than ~1 per 10s per
  call). No client currently consumes this type (per the general
  unknown-WS-type-is-ignored rule, sending it ahead of a consumer is
  safe); a future client MAY use it to show a "peer connection
  unstable" indicator instead of silent one-way audio loss.

### 8.9 Video-state BEACON (`call_video_state`) — v1.2, 2026-07-24

`call_video_state` was edge-triggered: each side announced its camera the
moment it toggled, once, and never again. That makes the peer's video lane a
value both sides must derive from a stream of edges, and every way of losing
one edge is unrecoverable for the rest of the call:

- the announcement is sent while the peer's WS is stale — the edge is gone;
- the peer reconnects mid-call — it starts knowing nothing about our camera
  and nothing ever tells it;
- two toggles arrive reordered — the older one wins and pins the lane wrong.

All three end with the two sides disagreeing permanently, which is the
observed "voice → video → voice → video, and then it will not go back to
voice on both sides".

**The message is now state-triggered.** Each side MUST re-announce its
CURRENT state:

1. on change (camera on/off, screen-share start/stop),
2. every **3000 ms** while the call is active — including an audio-only call,
   where it announces `sending: false`,
3. on WS (re)connect.

A missed announcement therefore self-heals within one heartbeat instead of
lasting the call.

**Additive fields** (the server relays this message verbatim — no server
change; all three are OPTIONAL and MUST be omitted entirely when unset):

| field | type | meaning |
|---|---|---|
| `seq` | int | monotonic per `(call_id, sender)`, first value 1. Orders repeats. |
| `sending` | bool | positive restatement of `!paused`. `paused` alone is ambiguous between "camera off" and "no video in this call at all". |
| `screen` | bool | the video being sent is a screen share, not a camera. |

**Receive rule — last-writer-wins.** Repeats need ordering or a delayed
repeat could overwrite a newer toggle, i.e. the heartbeat would become a new
way to strand a lane:

- `seq` absent → **accept** (the peer predates this section and only sends
  edges; dropping one would strand the lane, the failure this prevents);
- `seq` ≤ highest accepted for this call → **drop**;
- otherwise → accept and store. The stored value MUST NOT move backwards, so
  a seq-less announcement interleaved with numbered ones cannot reset the
  window and re-admit an already-superseded repeat.

**Lane vocabulary.** All three clients derive and report exactly four lane
names — `Off`, `LocalOnly` (we send), `RemoteOnly` (peer sends), `Both` — in
the `call.video.transition` telemetry event, so one server-side query answers
"which side got stuck" regardless of platform. Two legs of the same call MUST
end in mirrored lanes (`Both`/`Both`, `Off`/`Off`, `LocalOnly`/`RemoteOnly`);
anything else is a stuck lane and `tools/tune-report.py` prints it as
`!! MISMATCHED LANES`.

**A peer's announcement MUST only ever change the PEER's lane.** Applying a
remote event to the local lane is precisely what made audio-only unreachable
(a closed `RemoteOnly ↔ Both` 2-cycle whose only exit was hangup). Reference
implementations of both the lane table and the receive rule are pure and
tested in each client: `VideoLaneTransitions` + `VideoStateBeacon` (Kotlin /
TypeScript / Swift, same rules).

**Interop.** A client that ships this section talking to one that does not is
never worse off: the new client's extra fields are ignored by the old one,
and the old one's seq-less announcements are always accepted. The ordering
protection switches itself on once both sides ship.

### 8.10 Session consent vs. local camera authority (v1.3, 2026-09-08)

`videoConsentGranted` (§8.9's consent latch) and a re-sent `call_upgrade_request`
answer two DIFFERENT questions that earlier client code conflated:

- **Session consent** — "may video exist on this call at all" — is what lets a
  responder auto-accept a re-offer (`media="camera"`, consent already granted
  this call) WITHOUT re-showing the dialog. This is §8.9's latch.
- **Local camera authority** — whether MY OWN camera hardware opens right now —
  belongs SOLELY to the local user. Session consent is never a substitute for
  it.

A `call_upgrade_request` a responder auto-accepts under session consent MUST
NOT, by itself, open a camera the local user has since turned off (via the
in-call toggle / `downgradeToAudio` / `call_video_pause_request`). The peer's
request is about THEIR video (or resuming a bidirectional lane THEY still
think is live) — it carries no authority over a camera the local side
deliberately paused. Concretely: on a consented re-offer, a responder MUST
gate the camera-open on whether it is CURRENTLY sending locally (its own
current video-lane state), and answer the peer's offer receive-only when it
is not — the peer's video must still work either way.

This is NORMATIVE for all three clients (`W-CAMREVIVE` on iOS —
`acceptPendingIncomingUpgrade`'s `localVideoPaused` guard, predates this
subsection by iOS shipping it first; `shouldOpenLocalCameraOnConsentedReupgrade`
on Android/Desktop). Before this subsection existed the rule was implicit and
two of three clients (Android, Desktop) did not enforce it: a peer re-toggling
their OWN camera off/on mid-call could silently reopen a LOCAL camera the user
had just turned off, with no consent dialog and no notice — reported live as
"peer's camera off/on causes my camera to activate without consent."

Distinct from — and layered under — §8.9's beacon and §8.1's `media` gate:
as of this subsection's writing there was no separate "resume" vs. "first
upgrade" message type on the wire, and the split was entirely receiver-local
state, so every client's OWN re-offer handler is where this had to be
enforced, not the protocol. §8.11 below changes that premise for Android's
SENDER side specifically — read it before assuming every resume is
wire-visible.

### 8.11 Sender-side resume shortcut (W-VIDRESUMEFAST, Android, v1.3, 2026-09-08)

§8.10 is about a RESPONDER deciding whether to open its own camera on an
incoming re-offer. This subsection is the mirror case: a REQUESTER (the side
whose own camera is coming back on) deciding whether it needs to send a
`call_upgrade_request` at all.

`downgradeToAudio` never renegotiates — it only nulls the local sender's
track (`RTCRtpSender.setTrack(null)`/equivalent); the video transceiver stays
negotiated `sendrecv` on the same mid for the rest of the call. A later
resume can therefore bind a fresh track onto that SAME sender with a bare
setTrack and let RTP simply start flowing again — no new SDP needed, since
nothing about the m-line changed. Android's `upgradeToVideo` takes exactly
this shortcut once its own video has completed one full offer/answer this
video session (tracked locally, e.g. Android's
`localVideoTransceiverNegotiated`): **it sends NO `call_upgrade_request` at
all for that resume.** The peer's `call_video_state` beacon receipt (§8.9,
already required either way) is what tells it our camera is on again.

This corrects §8.10's closing paragraph above: for Android specifically,
"resume" now IS wire-distinguishable from "first upgrade" — a resume is the
ABSENCE of a `call_upgrade_request` where a beacon alone flips
`sending: true`. **NORMATIVE consequence for every peer:** do not build logic
that assumes a `call_upgrade_request`/response pair is the only way a video
lane starts flowing again mid-call — the §8.9 beacon must be treated as
sufficient on its own to learn that a peer's camera resumed. This is
Android-only today (an efficiency optimization, not a privacy or consent
mechanism — §8.10's camera-authority rule is unaffected and still applies in
full on whichever side answers the FIRST upgrade of a video session); Desktop
does not need it (its camera mute keeps the sender attached throughout, so it
never re-renegotiates a resume in the first place) and iOS has not been
evaluated. A platform MAY adopt the same shortcut under the same precondition
(this exact side's own video already completed one full offer/answer THIS
video session, tracked independently of §8.9/§8.10's session-consent latch —
see the false-positive risk called out in the Android reference
implementation's kdoc, where session consent alone is NOT sufficient because
a responder can gain consent without ever completing its own send-side
negotiation) — it is not required to.

---

Last reviewed: 2026-09-08 (§8.1 `call_video_pause_request` added to the
message inventory — v1.3, shipped as Android wire message before this doc
caught up; §8.10 added — session consent vs. local camera authority,
NORMATIVE, closes the Android/Desktop W-CAMREVIVE-parity gap; §8.11 added —
sender-side resume shortcut, Android-only today, corrects §8.10's original
"no resume-vs-first-upgrade wire distinction" claim which W-VIDRESUMEFAST
made false for Android specifically, and gives every peer the NORMATIVE
consequence: a lone §8.9 beacon, with no `call_upgrade_request`, is a valid
way to learn a peer's video resumed). Prior review
2026-07-24 (§8.9 video-state beacon; §3.5/§3.6 de-collided —
the four repo copies had drifted so that `### 3.5` meant "call acceptance
gate" in the server copy and "base WebRTC SDP exchange" in the Desktop copy,
while EVERY code reference to §3.5 in all four repos means the acceptance
gate. The SDP-exchange section keeps its content under §3.6, which nothing
cited. All four copies are now byte-identical and CI-enforced.)
## 9. BLE mesh chat transport — wire v2 (2026-08-12)

The mesh carries chat messages between two phones directly over Bluetooth Low
Energy, with no server in the path and, in full-mesh mode, with other phones
relaying traffic they cannot read. That last property is what shapes this
format: a hop is a participant, not a trusted intermediary.

### 9.1 What travels, and what is visible

A `.data` packet's payload is a `MeshSealedShell`:

```json
{ "c": "<clientMsgId>", "e": "<base64 sealed envelope>" }
```

`e` is the AEAD output over a serialised `MeshChatMessage`:

```json
{ "v": 2, "s": "<senderUserId>", "r": "<recipientUserId>",
  "c": "<clientMsgId>", "conv": "<conversationId>", "b": "<body>",
  "ts": <sentAtMs>, "sn": "<senderNodeHex>", "rn": "<recipientNodeHex>" }
```

Everything that identifies the parties — both user ids, the conversation, the
timestamp and the body — is inside the ciphertext. Only two things are visible
to a listener: the `MeshPacket` header a relay must read to forward at all
(version, type, the 8-byte sender and recipient node ids, ttl, source route,
length) and the shell's `c`.

Wire v1 did the opposite: it encrypted the body and shipped the user ids, the
conversation id and the timestamp in cleartext around it, on the reasoning that
these are the same fields the WebSocket transport already sends in the clear.
That holds inside a TLS tunnel to a server that already knows them. It does not
hold on a broadcast medium, where those real user UUIDs were readable by anyone
in range without breaking a cipher. v1 is rejected on version, not accepted for
compatibility: it never worked end to end, so there is no deployed traffic to
preserve, and accepting it would only keep a downgrade path to the leak open.

### 9.2 Why `clientMsgId` stays outside

For a v3.1 or v4 peer the message ratchet rebuilds its own associated data over
`{m, r, s}` — message id, recipient, sender — and the receiver must therefore
know the message id before it can decrypt anything. Sealing it makes it
unreachable at exactly the moment it is needed and every message from a modern
peer fails to open.

It is a random UUID minted per message: it identifies a message, not a person,
and says nothing about who is talking to whom or about what. The recipient and
sender user ids the ratchet also needs have another source — the receiver knows
its own, and derives the sender from the header's node id through the contact
directory — so only the message id has to be public.

### 9.3 Header authentication

`sn` and `rn` are a sealed copy of the header's two addressing fields. The
receiver compares them with the header the packet actually arrived in and drops
a mismatch. A relay that re-addresses a packet it forwards cannot repair the
copy without the message key.

Associated data is deliberately NOT the mechanism, although it is the obvious
one. `meshPacketAad(version, type, senderNode, recipientNode)` exists and is
honoured by the v2 ratchet path, but for v3.1 and v4 peers the ratchet discards
the caller's AAD and rebuilds the canonical one, so an AAD-based header binding
would look correct and protect nothing for every modern peer. TTL and source
route are excluded from any binding regardless: a relay is supposed to change
them, and a hop that wants a packet to stop propagating can simply not forward
it.

`meshPacketAad` is byte-pinned by a test on both platforms. The packet type is
rendered UNSIGNED, because Kotlin's `Byte` is signed and Swift's `UInt8` is not:
a type of 0x80 or above would otherwise render as `-128` on one platform and
`128` on the other, and nothing would decrypt between them.

### 9.4 Receive obligations

In order: parse the shell; reject a `c` already seen (a flood-relay legitimately
delivers the same packet more than once, and this happens before any decryption
is attempted); resolve the sender from the header's node id through the contact
directory and drop an unknown device without attempting to decrypt; decrypt with
that contact's key and the shell's `c`; parse the envelope and reject anything
that is not `v: 2`; then reject unless `r` is this user, `s` is the resolved
sender, `sn`/`rn` match the arriving header, and `c` matches the shell.

### 9.5 Delivery and read receipts

A message that goes over the mesh is acknowledged over the mesh. Nothing else
can acknowledge it: delivery normally comes from the server's ack and the read
receipt is a WebSocket `MsgRead` frame keyed by `serverMessageId`, and a mesh
message has no server and no server id. Without this, a message sent with no
network in reach stopped at one tick permanently.

Packet type `0x05` (`RECEIPT`), payload a `MeshSealedShell` exactly like a
message, `e` sealing:

```json
{ "v": 2, "s": "<acknowledgerUserId>", "r": "<messageAuthorUserId>",
  "c": "<receiptId>", "m": "<acknowledged clientMsgId>", "k": "d" | "r",
  "ts": <atMs>, "sn": "<senderNodeHex>", "rn": "<recipientNodeHex>" }
```

`k` is `d` for delivered (the message reached the peer's device and was stored)
or `r` for read. The receipt's own random `c` — not the acknowledged message's
id — is what rides outside the seal, for the reason in §9.2; publishing the
acknowledged id there would announce in the clear that this exact message had
just been read. Everything else, `m` included, is inside the ciphertext: a
receipt is metadata about a conversation, which is what §9.1 exists to hide.

The type is part of the associated data, so a receipt cannot be replayed as a
message or the reverse, and a queued receipt must be retransmitted as `0x05`.

Receive obligations are the message's, plus: the acknowledged message must be
one this user sent to that contact, and status only ever moves forward
(`PENDING` < `SENT` < `DELIVERED` < `READ`; `FAILED` is below all of them,
since a signed receipt is proof of arrival). A flood mesh re-delivers packets
out of order, so a late `d` must not take the blue ticks off a message already
`r`.

Read receipts follow the user's existing read-receipt privacy setting; delivery
receipts do not, matching the WebSocket transport.

### 9.6 What this does not hide

Node ids are `SHA-256(Ed25519 identity key)` truncated to 8 bytes: stable
pseudonyms, not names. A listener can still tell that two devices are exchanging
traffic and can follow a device between places. That is inherent to routing
without a server and is not addressed here.

## 10. Group calls v2 (qjanus) — server <-> client wire (2026-09-30)

Group calls (>= 3 participants and every 1:1 promoted to a group) run on **qjanus**, a Janus
VideoRoom SFU with the Q-Audion DTLS patch. The full normative spec (client Janus protocol,
E2EE v2, layer policy, amendments) is `docs/GROUP_CALLS_V2.md` in the server repo; this section
is the server-facing contract every client must honour. There is NO backward compatibility with
the LiveKit/WS-relay group path: the messages it used are rejected (§10.8).

### 10.1 Roster (unchanged shapes, changed semantics)
`group_call_create` / `group_call_join` / `group_call_leave` / `group_call_end` /
`group_call_invite` / `group_call_ended` / reactions, raise hand, mute request keep their v1
shapes. `supports_group_sender_keys` and `supports_raw_key_aes256` are gone (always true).

`group_call_update` (S->C, members only):
```
{ "call_id", "participants":[user_id...], "sender_key_epoch":<uint32>,
  "media": { "node_id", "pseudonyms": { "<user_id>":"<32 hex>", ... } } }   // media once a node hosts the call
```
`sender_key_epoch` is server-authoritative: 1 at create, +1 on EVERY real roster change (join,
leave, drop after the 20 s grace, kick), and +1 after 30 minutes without any change (periodic
rekey: the same `group_call_update`, nobody is kicked or admitted; every epoch change restarts
the 30 minute countdown). An idempotent re-join, a non-member's leave and the
publication of `media` change nothing. A removed member is evicted at qjanus BEFORE the new epoch
is broadcast. Pseudonyms are 128-bit random hex, fresh per call and per roster join.

### 10.2 Media join
`group_call_media_join {call_id}` (C->S, sender must be a participant). Answer, to the requester
only, either
```
group_call_media_ready { call_id, node_id, ws_url, room, pseudonym, session_token, join_token,
                         dtls_fingerprint, ice_servers:[{urls:[...], username, credential}], ttl_s }
group_call_media_unavailable { call_id, reason: no_node | room_create_failed | not_member | full }
```
`room` is a random 128-bit hex id (never the call id). `session_token` is a Janus core signed
token valid for `ttl_s` = 600 seconds; `join_token` is the room's per-member `allowed` token, `<pseudonym>:<32 lowercase hex>`
(qjanus accepts it only for a publisher join whose id is that pseudonym).
`dtls_fingerprint` (`sha-256 AB:CD:...`) is the node's fixed certificate, which the client pins
against the SDP. `ice_servers` carry per-call TURN credentials (username `<expiry>:<pseudonym>`,
TTL 2 h). There is no relay fallback: `unavailable` is an error. `group_call_media_join` is
idempotent for a current participant: sending it again (clients do so hourly to renew the TURN
credentials) returns the same room, pseudonym and join token with a fresh `session_token` and
`ice_servers`; nothing is kicked or re-added and the epoch does not move. Repeated requests
within 250 ms from one member are dropped without an answer, and a user is limited to 20
media_join / media_rejoin requests per minute across all their calls (the excess is dropped too).

### 10.3 Session token refresh
Janus re-validates the signed token on every request, keepalives included, so a client that
holds a Janus session sends `group_call_media_refresh {call_id}` (C->S) every 300 s and before
any WebSocket reconnect. The server answers the requester with
`group_call_media_token {call_id, session_token, ttl_s:600}` (S->C) only if the requester is a
current member and the room exists; every other case is
`group_call_media_unavailable {call_id, reason:"not_member"}`. At most one refresh per 5 s per
member, and 12 per minute per user, is answered; the excess is dropped without a reply. The client uses the newest token for
all later Janus requests.

### 10.4 Node failure
`group_call_media_moved {call_id, node_id}` (S->C, every member but a rejoin's requester) when the
room moved to another node: tear down both PCs and send `group_call_media_join` again; keys,
pseudonyms and the epoch are unchanged. `group_call_media_rejoin {call_id, reason}` (C->S) is the
"my session died" message: same answer as media_join but with a FRESH join token, the previous
token retired and the previous Janus session of that pseudonym kicked; the server also re-probes
the node and moves the room only if it really is down.

### 10.5 Decline / ring timeout
`group_call_decline {call_id}` (C->S): the invitee leaves `Invited`; their devices get
`group_call_ended {call_id, reason:"declined"}`. After 45 s an invitee that neither joined nor
declined gets `group_call_ended {reason:"ring_timeout"}` (still invited). When the creator ends the
call, invitees still ringing get `group_call_ended {reason:"ended"}` too.

### 10.6 Limits
Participant cap = `lim.group_call_max_participants` of the creator's entitlement (Pro 16),
default 8, resolved at create; create truncates recipients to cap-1; join at the cap is refused;
media_join over the cap answers `reason:"full"`. `feat.calls.group` gates create;
`feat.calls.group_video` gates the establishment of the room (the first member pays, later
members ride the established room).

### 10.7 Transport and content level (clients)
DTLS 1.3 only, `TLS_AES_256_GCM_SHA384`, `X25519MLKEM768`, SRTP `AEAD_AES_256_GCM`, checked by
every client after connect; frames are end-to-end encrypted with the per-sender per-epoch key
(same frame format as 1:1); keys travel in `qa_grp:2` envelopes over the pairwise sealed control
channel. See `docs/GROUP_CALLS_V2.md` §4-§5 and §11.

### 10.8 Removed (server answers one `error {code:"unsupported_message"}` per socket, then drops)
`group_call_sfu_token`, `group_call_sfu_token_recv`, `group_call_sfu_unavailable`,
`group_call_forward`, `group_call_frame`, `group_call_subscribe`, `group_call_unsubscribe`,
`group_call_state`, `group_call_receive`; envelopes `qa_grp:1` (`sender_key_init` /
`sender_key_rotate`).

---

## 11. Frame E2EE wire format and receiver replay window

This section defines the wire format of an end-to-end encrypted media frame (the FrameCryptor frame) and the
receiver-side replay rule. It applies to group calls v2 (§10, per-participant keys) and to 1:1 calls
(directional keys, §3.7.2). The server never touches frames; the section is a client contract. The relay and
DataChannel sealer (`PqcRtpFrameSealer`, §1.1) has its own directional keys and replay window and is out of scope.

### 11.1 Frame wire format

```
frame   = header(U) || AES-256-GCM(key_slot, iv, aad=header, payload) [ct||tag16] || iv(12) || trailer(2)
trailer = 0x0C || keyIndex
iv      = BE32(ssrc) || BE32(rtpTs) || BE32((rtpTs - counter) mod 2^32)
```

- `counter` is a **full 32-bit** per-ssrc frame counter (§11.2). The byte layout, the AAD, the trailer and the key
  derivation are otherwise unchanged. A frame with counter 0 is byte-identical to the previous layout.
- U = 1 for Opus, 10 for a VP8 key frame, 3 for a VP8 delta frame, 0 for AV1. For H.264/H.265 it is the slice NALU
  offset + 2.
- For H.264/H.265 the tail `ct||tag||iv||trailer` is RBSP-escaped by the sender.
  - The receiver MUST unescape the whole body first, then parse trailer and IV from the unescaped tail.
- `ssrc` and `rtpTs` are the sender's own frame metadata (`frame->GetSsrc()`, `frame->GetTimestamp()`).
- `keyIndex` selects the key slot of the receiver's key ring (ring size 16, slot = `epoch % 16`). The sender stamps
  `keyIndex = epoch mod 16` of the key it sealed with, and the receiver selects the slot by that value alone. For 1:1
  calls `epoch = rekeyRound - 1` (R-SLOT, §3.7.2); for group calls it is the group epoch (§11.9).

### 11.2 Sender (MUST)

- **S1.** `counter` is taken from the sender's key handler, `NextSendCounter(ssrc)`, under the handler mutex.
  - The first frame of a given ssrc in a handler gets 0. Each later frame gets the previous value + 1.
  - The counter lives in the key handler (per ssrc), not in the encryptor. It survives the re-creation of the
    encryptor for the whole life of the key provider. It is never reset (not on key switch, enable toggle or slot
    change) and never wraps.
  - If the previous value is `0xFFFFFFFF`, the call returns "exhausted". The frame is dropped and the sender reports
    an encryption failure once (edge-triggered).
- **S2.** The handler records `ssrc` as a *local send ssrc*, the input to the reflection guard (§11.4).
- **S3.** Counters are never copied by `Clone()` and never derived from randomness.
- **S4.** Nonce uniqueness. For a fixed key and ssrc, `(w2,w3)` determines `counter = w2 - w3`, so two frames with
  different counters have different IVs.
- **S5.** A key provider MUST live at least as long as every sender that uses it. An app MUST NOT create a new provider
  for an RtpSender whose ssrc is unchanged under a key that is still installed. The same holds for the receiving
  key handlers: a receiving handler, with its replay windows, MUST live as long as any key it holds stays
  installed, and in particular across the teardown and re-creation of the PeerConnection (§11.9).
- **S6.** A sender that cannot read `synchronizationSource` or `rtpTimestamp` from the frame metadata, or finds either
  one not a uint32, MUST drop the frame. It MUST NOT default them to 0.

### 11.3 Receiver (MUST)

The receiver runs these steps in `decryptFrame`, after the length checks:

```
body      = unescape_if_annexb(data[U:])            // parse AFTER unescaping
require len(body) >= 16 + 12 + 2
trailer   = body[-2:]; require trailer[0] == 12
keyIndex  = trailer[1]; iv = body[-14:-2]
ivSsrc    = BE32(iv[0:4]); w2 = BE32(iv[4:8]); w3 = BE32(iv[8:12])
ctr       = (w2 - w3) mod 2^32
handler   = key provider handler of the participant       // see §11.7 for 1:1
key_set   = handler.GetKeySet(keyIndex)  (missing -> missing-key, existing path)

pre = handler.ReplayPreCheck(ivSsrc, ctr)       // no state change
if pre != OK: drop(pre); return                 // §11.6: no observer call

plaintext = AES-GCM-open(key_set, iv, aad=header, ct||tag)
if fail: existing failure path ; return         // unchanged

res = handler.ReplayCommit(ivSsrc, ctr, keyIndex)   // under the handler mutex
if res != OK: drop(res); return                 // §11.6
deliver(plaintext)
```

**Replay identity** = (receiving key handler, `ivSsrc`, `frameCounter`). `ivSsrc` is IV word 1. `frameCounter` is
`(IV word 2 - IV word 3) mod 2^32`. The whole IV is authenticated, because it is the GCM nonce: any change fails the
tag. RTP metadata (ssrc, timestamp, sequence number) is NEVER used, because an SFU rewrites it.

**Commit only after AEAD success.** The pre-check is a cheap rejection of frames that are clearly too old or already
seen, and changes no state. The authoritative check-and-set runs under the handler mutex after the tag verifies.
A window is created only after authentication, so a forger cannot consume memory.

### 11.4 Window algorithm

One window per `ivSsrc` per receiving handler, shared across key slots, with **W = 256** frames and at most **64**
windows per handler. `ReplayPreCheck` is `ReplayCheck(commit = false)` and `ReplayCommit` is
`ReplayCheck(commit = true)`, both under the handler mutex:

```
if ivSsrc in local_send_ssrcs:                  return REFLECTED
win = windows.find(ivSsrc)
if win == none:
    if Commit: if windows.size() >= 64: return CAP
               windows[ivSsrc] = {top=ctr, bitmap=1, slotMask=bit(keyIndex mod ring)}
    return OK
if ctr > win.top:
    if Commit: d = ctr - win.top
               win.bitmap = (d >= 256) ? 1 : (win.bitmap << d) | 1     // 256-bit shift
               win.top = ctr; win.slotMask |= bit(keyIndex mod ring)
    return OK
d = win.top - ctr
if d >= 256:                                    return TOO_OLD
if win.bitmap bit d set:                        return DUPLICATE
if Commit: set bit d; win.slotMask |= bit(keyIndex mod ring)
return OK
```

Counters are uint32 and never wrap (S1), so the comparisons are plain unsigned comparisons and need no rollover
estimate. For the same state, the pre-check and the commit return the same verdict, except that `CAP` is decided
only at commit (the pre-check of an unseen `ivSsrc` returns `OK`).

The window is a sliding bitmap in the style of RFC 4303. 256 frames are 15 s of 60 ms audio and 8.5 s of 30 fps
video, far more than any real reordering. When the limit of 64 windows is reached, a new stream is **rejected**
(verdict CAP, fail-closed, counted). An existing window is never evicted, because eviction would re-open replay.

### 11.5 Behaviour in the listed situations

| Situation | Behaviour |
|---|---|
| Reorder ≤ 255 frames behind the top | Accepted once. |
| Exact duplicate on the same mid or another mid, or into a re-created or re-bound receiver cryptor | DUPLICATE. The window belongs to the key handler, so all cryptors bound to the same participant share it. |
| Key switch (sender moves to a new slot) | Same window. The counter keeps increasing across keys, and late old-slot frames inside the window are still accepted once. |
| Slot retirement or overwrite (random-byte retirement, ring wrap) | Window GC, §11.8. Frames under the old key can no longer authenticate. |
| Simulcast layer switch by the SFU | Each layer has its own sender ssrc, so its own `ivSsrc` and its own window. Switching back to a layer jumps forward, the bitmap resets to 1 and the frame is accepted. |
| SSRC rewriting or timestamp rebasing by the SFU | Irrelevant. Only IV fields are used. |
| RTP timestamp wrap | Irrelevant. `ctr = w2 - w3` is computed mod 2^32, and the wrap of `rtpTs` cancels out. |
| Receiver joins mid-stream | The first authenticated frame of each `ivSsrc` opens the window at any counter. |
| Sender rejoins (new PC) | New random ssrcs, so new windows. Old windows are collected when their keys retire. |
| Reflection of a local stream back to the sender | 1:1: the frame is sealed under the direction key the receiver does not hold, so it fails the tag; it is dropped without any key action (§11.7). Group: REFLECTED (§11.4). |
| More than 64 live streams for one participant | CAP: fail-closed and counted. |

An SFU that drops or delays frames is inherent and out of scope: a delayed frame that is still inside the window and
never seen is accepted once.

### 11.6 Verdicts and drop semantics

The verdicts are `OK`, `DUPLICATE`, `TOO_OLD`, `REFLECTED` and `CAP`.

- A frame with a verdict other than `OK` is **dropped silently**. It MUST NOT produce a decryption-failed or
  missing-key state, and no observer callback: those states drive `media_key_nack` (§10 and
  `docs/GROUP_CALLS_V2.md` §5.4) and key-frame requests, and a replay must not trigger them.
- The receiver increments internal counters per verdict and logs at most one line every 10 s per receiver, only when a
  counter moved. The line carries counts and the media kind only: never an ssrc, participant id, key index, key or IV.
- No replay counter is exported through any application API.

### 11.7 1:1 calls: directional keys and the reflection guard

- 1:1 calls use the directional keys of §3.7.2. The sender cryptors use the key handler of the local participant
  id, the receiver cryptors use the key handler of the remote participant id. A frame reflected back to its sender
  is sealed under the sender's own direction key, which the receiver cryptor does not hold for that direction, so it
  fails the tag. Nothing is decrypted and nothing is delivered.
- The `REFLECTED` guard of §11.4 compares against the local send ssrcs of the SAME handler. With directional keys the
  sender and receiver cryptors of a 1:1 call use different handlers, so the guard does not fire in the normal 1:1
  flow: for 1:1 the tag failure above is the defence, and §11.5 lists it as such. In group calls the receiving
  handlers belong to other participants, so the guard never fires there either.
- **What a 1:1 receiver does with such a tag failure.** A reflected frame is an attacker-or-relay artefact, not a key
  problem, and a receiver MUST NOT react to it as one:
  - it drops the frame silently;
  - it MUST NOT send `media_key_nack` or any other key re-request, MUST NOT start or request a rekey, MUST NOT raise a
    "missing key" or "wrong key" state, and MUST NOT end the call because of it;
  - its only visible effect is an internal decrypt-failure counter (rate-limited log, §11.6 rules: counts and media
    kind only);
  - a keyframe request for loss recovery (`video_keyframe_request`, §8.7) keeps its existing rate limit (1 per
    second) and is not a key request; it MUST NOT be sent more often because of tag failures.
  A receiver that can see the local send ssrcs of the call (the union over the call's sender handlers) SHOULD
  classify a frame whose `ivSsrc` is one of them as `REFLECTED` before the AEAD step and drop it with no observer
  callback at all (§11.6). A tag failure on a frame whose `ivSsrc` is not local is an ordinary decryption failure
  and takes the existing failure path. In 1:1 calls the key only changes through a signed rekey round (§3.7), so a
  decryption failure never asks the peer for a key.

### 11.8 Window garbage collection tied to keys

Installing key material into a slot compares the new material with the slot's current material in constant time.

- **Different** (a new key, or a random-byte retirement; a retirement with zeros is not allowed, §3.7.2 R-SLOT): clear `bit(slot)` from the `slotMask` of every
  window, then erase every window whose `slotMask` is now 0. This is safe: every frame such a window ever accepted was
  sealed under a key that is no longer installed, so a replay of it fails the tag.
- **Identical** (an idempotent re-install): no change. Resetting here would re-open replay.
- `Clone()` copies neither windows, counters nor `local_send_ssrcs`.

### 11.9 Epoch rule for group calls

Group calls v2 bump the epoch, and with it every sender's key, on every join and every leave
(`docs/GROUP_CALLS_V2.md` §5.1). A receiver that has just joined therefore never holds a key that was used before it
joined, and a frame sealed before the join cannot be replayed to it.

A media-only rejoin is different: after `group_call_media_moved` or a media rejoin the clients tear down and
re-create their PeerConnections but keep the same keys, with no epoch bump (`docs/GROUP_CALLS_V2.md` §2.5). The
receiving key handler and its windows MUST therefore survive that teardown (§11.2 S5). A client that re-created the
handler would open a fresh window for an old ssrc and accept a replayed frame of the current epoch once. The periodic
rekey (`docs/GROUP_CALLS_V2.md` §12.6) bounds the lifetime of any key that is replayable at all.

## 12. File transfer v2 (AES-256-GCM) — cross-platform contract

Added 2026-10-02. Source of truth: the file-transfer program's format document (`FILE_V2_FORMAT`), which this
section reproduces; the known-answer vectors are `test/kat/file_v2/file-v2-kat.json` in the server repository
(generated by `tools/katgen/filev2`, standard library only), copied byte for byte into each client repository,
where each test pins the SHA-256 of the file.

This is a HARD SWITCH (§6): one format for every file, image, video, voice note, avatar, thumbnail and group
attachment, over every transport, with no negotiation and no legacy path. It replaces all earlier file and
attachment encryption schemes (the `qa_fa_announce` / QAFA chunked announce, `qa_ctl` `attach_announce`, `qa_att`,
`qfile`, the Android voice-note format, and the group attachment v1 envelope), whose labels are removed from §1.
`MUST`, `MUST NOT` and `SHOULD` have their RFC 2119 meaning. All integers are big-endian; `||` is concatenation;
`u32be(x)` and `u64be(x)` are unsigned integers on 4 and 8 bytes.

### 12.1 Constants

| Name | Value |
|---|---|
| `CHUNK` | 1 048 576 bytes (2^20) of plaintext per chunk |
| `TAG` | 16 bytes (GCM tag, 128 bit) |
| `STRIDE` | `CHUNK + TAG` = 1 048 592 bytes |
| `HEADER_LEN` | 64 bytes |
| `MAX_SIZE` | 5 368 709 120 bytes (5 GiB) of plaintext file |
| `MAX_STREAM` | 5 368 709 120 (`padme(MAX_SIZE)`, which is exactly 5 GiB) |
| `MAX_CHUNKS` | 5 120 |
| `MAX_BLOB` | `HEADER_LEN + MAX_STREAM + MAX_CHUNKS × TAG` = 5 368 791 104 bytes |
| `MAGIC` | `51 41 46 02` ("QAF" followed by the version byte 0x02) |

`CHUNK` is fixed and does not appear in the header: one value, one set of vectors.

### 12.2 Keys and derivations

For every file the sender draws from the operating system's cryptographic generator: `K`, 32 random bytes (the file
key), and `file_id`, 16 random bytes. Everything else derives from `K` with HKDF-SHA256 (RFC 5869):

```
PRK          = HKDF-Extract(salt = file_id, IKM = K)
K_enc        = HKDF-Expand(PRK, "qaudion-file-v2-enc",    32)
nonce_prefix = HKDF-Expand(PRK, "qaudion-file-v2-nonce",   8)
commitment   = HKDF-Expand(PRK, "qaudion-file-v2-commit", 32)
```

The `info` strings are ASCII without a terminator. `K` MUST NOT be used directly as an AES key. `K` and `file_id`
MUST NOT be reused for a second content: forwarding a file, re-encrypting it after an edit and re-sending it after
a cancel each generate a new (`K`, `file_id`). `K` MUST NOT be restored from a backup; the resume state that holds
it is local to the device (§12.8).

### 12.3 Padding (Padmé)

The server sees the blob length, so the plaintext stream is extended with zero bytes up to `stream_len = padme(size)`:

```
padme(L):            // L >= 1
  E = bitlen(L) - 1  // floor(log2 L)
  S = bitlen(E)      // floor(log2 E) + 1, with bitlen(0) = 0
  z = E - S
  if z <= 0: return L
  mask = (1 << z) - 1
  return (L + mask) & ~mask
```

The overhead is at most 12.5% up to 255 bytes, under 6.25% up to 64 KiB, under 3.2% up to 4 GiB and under 1.6%
beyond. The function is monotonic and `padme(5 GiB) = 5 GiB`. The plaintext stream is
`P = file || 0x00 × (stream_len - size)`; the padding is encrypted and authenticated like the rest, and the
receiver MUST check that it is all zero.

### 12.4 Header (64 bytes)

```
offset  len  field
0       4    magic_version = 51 41 46 02
4       16   file_id
20      8    stream_len     u64be, 1..MAX_STREAM
28      4    total_chunks   u32be = ceil(stream_len / CHUNK), 1..MAX_CHUNKS
32      32   commitment
```

### 12.5 Chunk encryption

`P` is split into `n = total_chunks` chunks: chunk `i < n-1` is `CHUNK` bytes, the last is
`stream_len - (n-1) × CHUNK` bytes (1 to `CHUNK`).

```
nonce_i = nonce_prefix || u32be(i)                                       // 12 bytes
final_i = 0x01 if i == n-1, otherwise 0x00
AAD_i   = "qaudion-file-v2-chunk" || header(64) || u32be(i) || final_i   // 90 bytes
C_i     = AES-256-GCM(K_enc, nonce_i, AAD_i, P_i) = ciphertext || tag(16)

blob        = header(64) || C_0 || C_1 || ... || C_{n-1}
offset(C_i) = 64 + i × STRIDE
len(blob)   = 64 + stream_len + 16 × n
```

The AAD binds the whole header (version, `file_id`, `stream_len`, `total_chunks`, `commitment`), the index (a moved
chunk does not open: reordering, duplication), `final_i` together with `total_chunks` (a truncated or extended blob
does not open) and `file_id` with the commitment (a chunk of another file does not open).

Nonce uniqueness: inside one file the nonce is unique because the index is unique and `MAX_CHUNKS` is far below
2^32; across files the keys `K_enc` are independent. The only way to reuse a nonce is to encrypt two different
plaintexts under the same (`K`, `file_id`, `i`), which §12.8 forbids on every path. AES-GCM limits are not
approached: 1 MiB per invocation, at most 5 120 invocations and 5 GiB per key.

### 12.6 Key commitment

AES-GCM does not bind a ciphertext to one key. The `commitment` in the header, derived from `K`, and the header's
presence in every chunk's AAD close that gap: a blob opens under one key only, so a sender cannot hand different keys
to different recipients for the same blob and make each see different content. The receiver:

1. derives `commitment` from `K` and compares it with the header (constant time) BEFORE decrypting any chunk;
2. compares the header it receives from the source (server or direct channel) with the header of the descriptor,
   byte for byte.

### 12.7 End-to-end descriptor

The key and all metadata travel in a JSON descriptor carried exactly where chat text travels: in a 1:1 chat, as the
body of an ordinary chat message sealed by the existing message channel (same encryption, sender authentication and
per-device distribution; where the channel uses the hybrid post-quantum exchange, files inherit it); in a group,
inside the group payload 0xE4 with `msg_type = 1`. There is no separate announce, no per-device X25519 envelope and
no dedicated signature. If the channel cannot send a text message to a contact it MUST NOT send the file either.

```json
{
  "qa_file": 2,
  "id":   "<b64 16 B file_id>",
  "k":    "<b64 32 B K>",
  "h":    "<b64 64 B header>",
  "sz":   1234567,
  "kind": "file | image | video | voice | avatar | thumb",
  "nm":   "report.pdf",
  "mt":   "application/pdf",
  "src":  { "via": "srv", "obj": "<lowercase UUID>", "tok": { "v": "<64 lowercase hex>", "exp": 0, "max": 0 } },
  "m":    { "w": 1920, "h": 1080, "dur": 5234, "wave": [] },
  "pv":   "<b64 preview, at most 2048 B>",
  "th":   { "qa_file": 2, "kind": "thumb", "...": "complete descriptor of the thumbnail" },
  "ex":   0,
  "xp":   1
}
```

The example above is expanded for readability: builders emit compact JSON in the canonical form of §12.7.1.

- `id` MUST equal the header's `file_id`; `padme(sz)` MUST equal `stream_len`; `sz` is 1..`MAX_SIZE`.
- `nm` is at most 255 UTF-8 bytes and `mt` at most 128; the receiver still sanitises them (canonical path, no
  overwriting).
- `src.via = "direct"` means the direct path with no copy on the server; `src.via = "srv"` carries the server object
  and the download token.
- `m` carries only display hints (dimensions, duration, waveform) of its own `kind`. `pv` is a tiny preview (decoded
  length at most 2048 bytes). The real thumbnail is a separate v2 file (`kind: "thumb"`, own key) described in `th`.
- `ex` and `xp` keep their current meaning: `ex` is the ephemeral-message lifetime (`-1` view once, `0` no timer, `N`
  seconds), `xp` the export permission (`0` blocked, `1` allowed).
- The serialised descriptor MUST stay under 8 KiB, 8192 bytes (the server limits WebSocket frames to 32 KiB and the
  descriptor travels encrypted and base64-encoded).

The sub-sections below fix, for every point where a lenient JSON library and a strict one would disagree, exactly one
behaviour. The three platforms implement them as written and test them with the vectors of §12.13; the vectors state
the expected result for each rule, so a library that is stricter or more lenient than this section fails a test.
The numbers of this section (limits, prefixes, patterns) are also published as `descriptor_constants` in the vector
file.

#### 12.7.1 Recognition, builders and the canonical form (MUST)

The body of a file message is a sequence of bytes, the UTF-8 text decrypted from the channel. Recognition and
validation run on those bytes exactly as decrypted: no decoder that strips a byte order mark, normalises the text or
substitutes U+FFFD runs before them (JavaScript: `new TextDecoder('utf-8', { fatal: true, ignoreBOM: true })`), and a
platform string that holds an unpaired UTF-16 surrogate is not valid UTF-8, so a body made of it is rejected for
version 2 (§12.7.2). Every comparison of this section is on bytes: in Swift `body.utf8.starts(with:)`, never `hasPrefix`, which
compares grapheme clusters and would take a colon followed by a combining mark for a different character.

A chat message body (1:1), or the content of a group payload 0xE4 with `msg_type = 1`, is a file message if and only
if its bytes begin with one of these three strings, the compact form up to and including the colon, whatever the
version that follows:

| Prefix | Message |
|---|---|
| `{"qa_file":` | file descriptor |
| `{"qa_file_src":` | source message (§12.7.6) |
| `{"qa_file_cancel":` | cancel message (§12.7.6) |

No leading whitespace is skipped and none is allowed inside the prefix: `{ "qa_file":2,`, `{"qa_file" :2,` and a body
that begins with a byte order mark are not recognised. Recognition is a prefix test on the bytes and needs no JSON
parsing; it is the same in a 1:1 chat and in a group.

- A body that does not begin with one of the prefixes is ordinary chat text, whatever else it contains, including a
  valid descriptor whose first member is another member. It is displayed as text and creates no transfer.
- The version is the text after the prefix up to the first `,`, `}` or JSON whitespace, or up to the end of the body.
  It is read before anything else. The plain integer 2 (§12.7.3): the body is validated (§12.7.2 to §12.7.6). Another
  plain integer (`1`, `3`, `0`, `-1`): the body is rejected with `unsupported_version` and the rest of it is not
  examined, because a later version may have another shape. Anything else (empty, `2.0`, `"2"`, `02`, `1e0`, a
  magnitude above 2^53 - 1): `bad_descriptor`.
- Digits are the ASCII characters 0 to 9; a routine that accepts other Unicode digits MUST NOT be used on the version
  text (the Arabic-Indic and fullwidth digits two are not a 2).
- The checks of §12.7.2 apply to version 2 only: a body with a recognised prefix and another plain integer version is
  `unsupported_version` whatever follows, invalid UTF-8 or a length of 8192 bytes or more included.
- A recognised body that is rejected, with any code, MUST NOT be displayed as text, ever. A rejected descriptor
  becomes ONE placeholder in the conversation; for `unsupported_version` with a version greater than 2 the placeholder
  text is 'update the app' (the sender may also resend). Its content is never displayed, quoted (reply, forward), put
  in a notification, indexed for search, or written in the clear to backups or logs. A client that receives an
  `unsupported_version` message SHOULD keep the raw body sealed, with the same at-rest protection as any other message
  of the conversation, so that an app update can process it; if it cannot, the placeholder tells the user that the
  sender must resend it. A rejected CONTROL message (§12.7.6) produces no placeholder at all: it is dropped silently and
  keeps nothing.
- Text supplied by the user through any entry point (typing, paste, share sheet, intents, dictation) that begins with a
  prefix MUST be refused as an ordinary message; only the builders of this section produce such a body.
- Forward compatibility. A later incompatible change of a file message MUST bump the version (§6). Until a signed
  per-device announcement of the highest file message version it reads is defined in this specification, a sender MUST
  emit version 2 only; a group sender uses the lowest version announced by every current member device. Within
  version 2, an unknown `kind` or `via` stays `bad_descriptor`, and unknown members are ignored (§12.7.2).

Builders (MUST). A builder takes structured input and writes the canonical form, so that every platform can be tested
byte for byte against the `builder_cases` of §12.13:

- compact JSON (no whitespace outside strings), the members in this fixed order: `qa_file`, `id`, `k`, `h`, `sz`,
  `kind`, `nm`, `mt`, `src` (`via`, `obj`, `tok` (`v`, `exp`, `max`)), `m` (`w`, `h`, `dur`, `wave`), `pv`, `th`, `ex`,
  `xp`; the thumbnail in `th` is built by the same rules;
- an absent optional member is omitted, and `null` is NEVER written; an empty `nm`, `mt` or `pv` counts as absent, `m`
  is omitted when none of its members is set, and `ex` and `xp` are written only when the sender set them;
- integers in plain decimal form (§12.7.3); `id`, `k`, `h` and `pv` in canonical base64;
- `nm` and `mt`: every unpaired surrogate of a UTF-16 platform string is replaced by U+FFFD, then the text is cut to at
  most 255 (`nm`) or 128 (`mt`) UTF-8 bytes at a character boundary, a Unicode scalar value never being split;
- escaping: only the quote, the backslash and the C0 controls (U+0000 to U+001F) are escaped, with the short forms
  `\b`, `\f`, `\n`, `\r`, `\t` and the form `\u00xx` with lowercase hex for the others; `/` is not escaped, and every
  other character (DEL, U+2028 and all non-ASCII included) is written raw as UTF-8. A general-purpose JSON encoder is
  not enough: many of them also escape U+2028, `<`, `>` and `&`, or write non-ASCII as escapes;
- control messages are built the same way: compact JSON, the members `qa_file_src` (or `qa_file_cancel`), `id`, and for
  `qa_file_src` then `src`, built as in a descriptor; the text begins `{"qa_file_src":2,"id":` or
  `{"qa_file_cancel":2,"id":`;
- `src.obj` and `src.tok.v` are written exactly as the server returned them, never re-formatted through a UUID or a
  number type (Swift's `uuidString`, for one, is upper case);
- size: if the canonical text would reach 8192 bytes, the builder drops `m.wave`, then `pv`, then `th`, of the file
  descriptor, in that order, stopping as soon as the text fits; the thumbnail is dropped whole, never trimmed, and a
  dropped `m.wave` leaves `m` omitted if it has no other member. It refuses to send the message if the text still does
  not fit. The cut of `nm` and `mt` counts the raw UTF-8 bytes, not the escaped ones;
- a builder refuses to send a value outside §12.7.4 (for example a `pv` over 2048 decoded bytes or an out-of-range `sz`)
  instead of writing it.

The output of a builder MUST be accepted by the receiver rules of §12.7.2 to §12.7.6, and a descriptor begins with
`{"qa_file":2,"id":`.

#### 12.7.2 JSON profile (MUST)

The text of a file message is parsed with this profile. A text that fails any rule is `bad_descriptor` and none of its
fields is used.

1. The text is the body as decrypted (§12.7.1), valid UTF-8, and shorter than 8192 bytes. Bytes are counted, not
   characters or UTF-16 units, over the whole serialised text: unknown members and the thumbnail count too.
2. It is exactly one JSON object (RFC 8259), optionally surrounded by JSON whitespace (space, tab, LF, CR). No byte
   order mark, no comments, no trailing comma, no data after the object.
3. Member names are unique within every object. Names are compared as sequences of Unicode code points after
   unescaping, WITHOUT any normalisation or case folding: the precomposed and the decomposed form of a letter are two
   names, the Kelvin sign U+212A is not `K`, and a name written with an escape equals the same name written raw.
   Implementations compare code points or UTF-8 bytes (Swift: `unicodeScalars` or UTF-8 bytes, never `String`
   equality or a `[String: _]` key, which compare canonically equivalent texts as equal; JavaScript: a `Map`, so that
   `__proto__` and `constructor` are ordinary names). A repeated name is rejected at every depth and in known and
   unknown members alike: there is no "last one wins" and no "first one wins".
4. At most 4 nested containers (objects and arrays), the top-level object being depth 1. The deepest legitimate
   descriptor is `th` holding `src` holding `tok` (depth 4), or `th`, `m`, `wave` (depth 4); the token object holds
   scalar members only (§12.7.4).
5. A string escape that denotes a lone surrogate (a high surrogate not followed by a low surrogate, or a low surrogate
   on its own) is rejected, so that every string has one and the same UTF-8 length on every platform. A valid
   surrogate pair is one character.
6. Unknown members are ignored, at every level and whatever their JSON type (forward compatibility), including the
   `scope` member the server adds to a download token. They count for the 8 KiB limit and obey rules 1 to 5 like
   everything else. Numbers inside unknown members are checked against the JSON grammar of RFC 8259 only and are never
   converted: `1e400`, an integer of 400 digits and `-0` are accepted there, so a library must not turn them into a
   double or an integer.

#### 12.7.3 Integers and base64 (MUST)

Integers. Every number that the format reads (`qa_file`, `sz`, `ex`, `xp`, `src.tok.exp`, `src.tok.max` and the numbers
inside `m`) is an integer written in plain decimal form: `0`, or an optional minus sign followed by a digit 1 to 9
followed by zero or more digits 0 to 9 (so `2` and `-1` are integers). A fraction (`2.0`), an exponent (`1e0`), a plus
sign, a leading zero and `-0` are not integers of the format, and neither is a magnitude above 2^53 - 1 =
9 007 199 254 740 991 (not exact in a JavaScript number). A string, a boolean, `null`, an array or an object is not an
integer. A required integer that is not one makes the descriptor `bad_descriptor`; in `m` it makes `m` malformed
(§12.7.4).

Base64. `id`, `k`, `h` and `pv` are base64 in the standard alphabet of RFC 4648 section 4, with the mandatory `=`
padding, in canonical form: no CR, LF or other whitespace anywhere in the text, no character of the URL-safe alphabet,
no missing or surplus padding, and zero in the unused trailing bits of the last character. One byte string has exactly
one accepted text; a receiver can check this by decoding the text, encoding the bytes again and comparing with the
original. Anything else is `bad_descriptor`.

#### 12.7.4 Fields (MUST)

Every violation in this table is `bad_descriptor`. The fields are checked before the header (§12.9, step 1 before
step 2): a descriptor with a bad field and a wrong header is `bad_descriptor`.

| Member | Rule |
|---|---|
| `qa_file` | required, the integer 2 |
| `id`, `k`, `h` | required; canonical base64 (§12.7.3) of exactly 16, 32 and 64 bytes |
| `sz` | required; integer 1..`MAX_SIZE` |
| `kind` | required; string, one of `file`, `image`, `video`, `voice`, `avatar`, `thumb` |
| `nm` | optional; string of at most 255 UTF-8 bytes (bytes, not characters) |
| `mt` | optional; string of at most 128 UTF-8 bytes |
| `pv` | optional; canonical base64 of at most 2048 decoded bytes (the empty string is valid) |
| `src` | required object |
| `src.via` | required; `"srv"` or `"direct"` |
| `src.obj` | string of exactly 36 characters in the format of the server's object ids, `^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$` (lowercase hex, hyphens at 8, 13, 18 and 23, no version check). Required when `via` is `"srv"`; on a `"direct"` source it is checked the same way and not used |
| `src.tok` | optional object whose members are scalars only (a member that is an object or an array is invalid, so that `th.src.tok` stays at depth 4; unknown scalar members are ignored); when present: `v` required, exactly 64 lowercase hex characters (an HMAC-SHA-256); `exp` required, integer 0..2^53 - 1, epoch milliseconds; `max` required, integer 0..2^31 - 1 |
| `ex` | optional integer: `-1` (view once), `0` (no timer) or a lifetime of 1..2^31 - 1 seconds; absent means no timer |
| `xp` | optional integer: `0` (export blocked) or `1` (export allowed); absent means allowed |

`null` is accepted as "absent" for `nm`, `mt` and `pv` only. For every other member, `null` is a value of the wrong
type, which is `bad_descriptor` (`src.obj: null`, `src.tok: null`, `ex: null`, `xp: null` included), except for `m`
(below) and `th` (§12.7.5). `ex` and `xp` carry the ephemeral timer and the export permission, so a wrong type or an
out-of-range value fails closed instead of falling back to a default (a reader that tests `xp != 0` would otherwise
allow the export of a file marked `xp: 2`).

A `"srv"` source without `tok` is valid, but the receiver cannot download from the server with it: it never requests
the object without a token, it keeps the transfer pending ("waiting for the sender") until a `qa_file_src` message of
the same transfer brings a source it can use (§12.7.6), and the user can discard it. The format sets no timeout.

`m` is cosmetic and never makes a descriptor invalid. It is well typed when it is an object in which `w`, `h` and
`dur`, if present, are integers (§12.7.3) and `wave`, if present, is an array of integers; unknown members of `m` are
ignored. A well-typed `m` is used as it is and the format does not check its ranges (a value may be negative or larger
than 32 bits; the user interface MUST clamp whatever it draws or allocates from `m`). A malformed or wrongly typed `m`
(not an object, a member of the wrong type, `null` included, a non-integer number such as `1920.0`, an element of
`wave` that is not an integer) is IGNORED: the receiver treats `m` as absent and keeps the file. A violation of the
JSON profile inside `m` (§12.7.2, for example a repeated name) is still `bad_descriptor` for the whole descriptor.

#### 12.7.5 Thumbnail (`th`)

`th`, when present, MUST be a complete descriptor: it satisfies §12.7.3 and §12.7.4 exactly as a file descriptor does,
with its own `id`, `k`, `h`, `sz`, its own `src`, and the header checks of §12.9 step 2 against its own key, and its
`kind` is `"thumb"`. Its `id` MUST differ from the `id` of the file (a thumbnail is another file). A thumbnail
descriptor carries no `th` of its own: a descriptor of kind `thumb` that has a `th` member is invalid, and at the top
level it is rejected with `bad_descriptor`. `th` set to `null`, or to anything other than such a descriptor, is
invalid.

An invalid `th` does not invalidate the file. The file descriptor stays valid and is processed as if `th` were absent,
with one difference: the receiver MUST NOT use the thumbnail (it neither downloads nor displays it) and reports
`bad_descriptor` for the thumbnail only. Every failure of the thumbnail, including its header checks, is reported with
this one code. The thumbnail is a file of its own, with its own key, transfer and errors; its result never changes the
result of the file. The JSON profile (§12.7.2) applies to the whole text: a repeated member name, a nesting depth over
4 or a text of 8192 bytes or more inside `th` rejects the entire descriptor, not only the thumbnail.

#### 12.7.6 Control messages

`{"qa_file_src":2,"id":...,"src":{...}}` adds a source (for example the server after a failed direct path);
`{"qa_file_cancel":2,"id":...}` means the sender cancelled and the receiver discards the chunks received. Both are
recognised by their prefix and version (§12.7.1) and follow the JSON profile and the number and base64 rules (§12.7.2,
§12.7.3). In both, the version member is the integer 2 and `id` is canonical base64 of 16 bytes; in `qa_file_src`,
`src` is required and follows the rules of §12.7.4. Other members are ignored. A control message that begins with its
prefix and fails these checks (`bad_descriptor`, or `unsupported_version`) is rejected: it is dropped silently, with no
placeholder, and never shown as text.

A control message applies only to a transfer whose descriptor came from the SAME sender ACCOUNT, from any of its
devices, in the SAME conversation (the same 1:1 chat, or the same group). If the sender account or the conversation
differs, or if no transfer with that `id` exists, the message is dropped silently: it neither adds a source, nor cancels, nor creates a transfer. No vector can state
this, because it depends on the state of the receiver; it is a requirement of the platform behaviour tests.

Delivery receipts keep their current form, keyed by `id`.

### 12.8 Resume, retries, parallelism: the nonce-reuse rule

Encryption is deterministic: the same (`K`, `file_id`) always gives the same bytes for the same plaintext chunk, so a
chunk can be re-encrypted on every retry or resume instead of being kept on disk, provided the content has not
changed. The sender MUST keep a local transfer state, never included in a backup (Android: excluded from the backup
rules and `K` wrapped by the Keystore; iOS: Keychain `ThisDeviceOnly`; desktop: `safeStorage`), holding `file_id`,
the wrapped `K`, `stream_len`, the source identity (path or URI, size, modification time), `T[i]` (the tag of every
chunk already encrypted at least once, at most 80 KiB) and the transport state.

1. Before resuming, if the source's size or modification time changed, the transfer is cancelled: new `K` and
   `file_id`, restart from zero.
2. Whenever a chunk `i` already present in `T` is encrypted again, the new tag MUST equal `T[i]` before the chunk
   leaves the process. If it differs the content changed: the chunk MUST NOT be transmitted, the transfer is
   cancelled and the sender sends `qa_file_cancel`.
3. In parallel, each index is assigned to one worker. A part that fails is resent with the same bytes (from memory,
   or re-encrypted under rule 2).
4. The direct path and the server path transmit the same bytes: same (`K`, `file_id`), rule 2 on both.
5. A forwarded or re-sent file is a new file.

The reason for a cancellation does not go to the server: it sees only that an object is deleted and another created;
the receiver gets `qa_file_cancel` on the encrypted channel.

### 12.9 Reception

Checks, in this mandatory order:

1. the body is recognised as a file message of version 2 (§12.7.1; another plain integer version is
   `unsupported_version`) and the descriptor is valid: the JSON profile, the integer and base64 rules and the fields of
   §12.7.2 to §12.7.4 (lengths, `kind`, `src`, `ex`, `xp`), `sz` between 1 and `MAX_SIZE`. `th` is judged on its own
   (§12.7.5) and never changes the result of the file;
2. the header of the descriptor: magic, `file_id == id`, `stream_len` in range, `total_chunks == ceil(stream_len /
   CHUNK)` and in range, `stream_len == padme(sz)`, `commitment` equal to the one derived from `K`;
3. the header of the source (the first 64 bytes of the blob, or the `HELLO` frame of the direct channel) equals the
   descriptor's header byte for byte;
4. for each chunk: index `i < total_chunks` (otherwise discarded without allocating anything), exact length
   (`STRIDE`, or the last chunk's length), AES-GCM open with `nonce_i`, `AAD_i` and the whole 16-byte tag (truncated
   tags are rejected). On failure the chunk is discarded and requested again, from the same or another source, at
   most 3 times, then error. A chunk already verified that arrives again is ignored: completion is counted on the map
   of verified chunks, never on the number of messages received;
5. at the end: all `total_chunks` chunks verified, padding all zero, truncation to `sz`. The padding check stays last:
   it runs only on a complete stream.

Incomplete transfer. When the source ends the stream before the last chunk (the server's object ends, or the direct
channel sends `DONE`, with chunks of the map still missing), the transfer is incomplete and the result is
`size_mismatch`, whether the stream ends at a chunk boundary or inside a chunk. There is no separate error code for it,
and `bad_padding` is never reported for it (the padding is checked at step 5 only). A connection that fails or times
out is not an end of stream: the receiver resumes from the map of verified chunks (below).

The receiver writes verified chunks at their position (`i × CHUNK`), keeps the map of verified chunks, may resume from
any point and from any source, and checks it has room for `stream_len` before starting. No plaintext byte is shown to
the user before its chunk is verified; progressive playback may use verified chunks in order.

Error codes common to the three platforms (telemetry and negative vectors): `bad_descriptor`, `bad_header`,
`commit_mismatch`, `header_mismatch`, `chunk_auth`, `bad_padding`, `size_mismatch`, `cancelled`, `unsupported_version`.
The mapping of the checks above, as the reference receiver of the vector generator applies it:

| Check | Code |
|---|---|
| recognised file message whose version is a plain integer other than 2 (§12.7.1), before step 1 | `unsupported_version` |
| version that is not a plain integer, JSON profile, integers, base64, descriptor fields, lengths, `kind`, `src`, `ex`, `xp`, `sz` range (§12.7.1 to §12.7.4) | `bad_descriptor` |
| `th` invalid (§12.7.5) | `bad_descriptor` for the thumbnail only; the file is processed |
| magic, `file_id != id`, `stream_len` or `total_chunks` out of range or inconsistent | `bad_header` |
| `stream_len != padme(sz)` | `size_mismatch` |
| commitment differs from the derived one | `commit_mismatch` |
| source header differs from the descriptor header | `header_mismatch` |
| blob length differs from `64 + stream_len + 16 × total_chunks` (including a missing last chunk) | `size_mismatch` |
| the source ends the stream before the last chunk (incomplete transfer) | `size_mismatch` |
| chunk of the wrong length, or GCM open fails | `chunk_auth` |
| chunk index `>= total_chunks` | discarded, no error |
| non-zero padding | `bad_padding` |
| sender cancelled | `cancelled` |

### 12.10 Transports

The format does not depend on the transport: the bytes of `C_i` are the same on every path.

- Server: the blob is an opaque object. The header is delivered when the object is created; the chunks travel in
  parts of 8 chunks (8 × `STRIDE` bytes), aligned to chunk boundaries, uploaded and downloaded in parallel with range
  requests. Part `p` occupies the bytes from `64 + p × 8 × STRIDE`. The server does not know the format: it knows
  "a 64-byte header followed by parts of a fixed size", checks transport integrity per part with
  `Content-Digest: sha-256` (RFC 9530) while writing, and caps an object and a user's quota at `MAX_BLOB`. The client
  no longer sends `mime` or `sha256_b64` in the upload metadata. (The server's parts protocol arrives with the
  client pipelines; this section fixes the bytes it will carry.)
- Direct channel (WebRTC DataChannel over DTLS 1.3 AES-256 of the M150 build, DTLS fingerprints signed as in §3.7):
  frames `HELLO(header)`, then the chunks split into 64 KiB messages and reassembled before verification,
  `HAVE(map)` to resume, `DONE`, `CANCEL`. DTLS authenticates the channel; the chunk GCM remains the only guarantee
  about the content.
- Several sources: the receiver may take different chunks from different sources, because each chunk verifies on its
  own with the same `K`.

### 12.11 Download token

The token remains the server's HMAC token (opaque to clients): bound to the object and the recipient, with a
byte cap (8 times the blob length) and a use counted only by a request that starts at offset 0. In v2:

- the token travels only in the descriptor, hence encrypted end to end;
- a use is the start of a download, that is the read of the first 64 bytes; the parallel requests that follow consume
  only the byte cap;
- groups: one token with group scope (the server checks group membership at download time) instead of a per-member
  token map, which does not fit the descriptor limit for large groups;
- streaming delivery: the server issues the token at object creation (today it answers 409 before completion).

### 12.12 Removal of the earlier formats and the CI marker check

The v2 release deletes the earlier code, it does not switch it off. A check in CI in every repository fails if a
source file (tests included) contains any of these markers: `qaudion-fa-v1`, `qa_fa_announce`, `qa_att`,
`attach_announce`, `"qfile"`, `q-audion-attachment-`, `q-audion-file-key`, `qaudion-vn-`, `XChaCha`, `HChaCha`.
Out of scope and unchanged: the backup format (scrypt + AES-256-GCM), the local on-device file encryption (Jetpack
`EncryptedFile`, AES-256) and the end-of-call diagnostics packages.

### 12.13 Platform primitives and vectors

| Platform | AES-256-GCM | HKDF-SHA256 |
|---|---|---|
| Android | `javax.crypto` `AES/GCM/NoPadding` from Conscrypt, a new `Cipher` per chunk; no BouncyCastle on the file path | `Mac HmacSHA256` |
| iOS | CryptoKit `AES.GCM` with a 12-byte nonce | CryptoKit `HKDF<SHA256>` |
| Desktop | `node:crypto` `aes-256-gcm` in the main process | `crypto.hkdfSync` |
| Server | none | none (generates the vectors only) |

Vectors (`test/kat/file_v2/file-v2-kat.json`): derivations; Padmé inputs; complete files with deterministic content
(byte `j` = `j mod 251`) of 1, 1023, 2^20 - 1, 2^20, 2^20 + 1 and 3 × 2^20 + 5 bytes with header, per-chunk nonce,
AAD, tag and ciphertext SHA-256 and the blob SHA-256 (the blob itself for the small ones); the derivations for the
maximum chunk index of a 5 GiB file; negative vectors (header and descriptor tampering, wrong commitment, swapped,
duplicated, removed and foreign chunks, wrong `final` flag, non-zero padding, `stream_len` not Padmé, inconsistent
`total_chunks`, source header differing from the descriptor, truncated and extended blobs), each with its expected
error code; and descriptor examples, three valid (file with thumbnail, voice note, group image) and invalid ones.
Multi-chunk negative vectors are given as a recipe on a named positive vector plus the SHA-256 of the resulting blob.
A blob that ends before the last chunk is covered by `last_chunk_removed` (at a chunk boundary) and `blob_tag_truncated`
(inside a chunk): both `size_mismatch`, §12.9.
The strict descriptor profile of §12.7.1 to §12.7.6 has four more sections, and `error_codes` lists `unsupported_version`
after the eight earlier codes.

- `descriptor_constants`: the limits, the version, the object id pattern and the three recognition prefixes.
- `recognition`: a chat BODY is judged by recognition (§12.7.1) and, if it is a file message, by the validator. A vector
  gives `class` (`text`, `descriptor`, `src` or `cancel`) and `expect`: `text` (not a file message, shown as text), `ok`
  (a valid file message) or an error code (recognised and rejected, never shown as text; `unsupported_version` among
  them), and `rule`, the reason of a rejection. Only these texts go through recognition.
- `descriptor_rules`: a descriptor TEXT goes straight to the validator (§12.7.2 to §12.7.5), WITHOUT the recognition
  step of §12.7.1; the earlier `descriptors` section works the same way. The validator checks `qa_file` itself, so
  `{"qa_file":1,...}` is `bad_descriptor` there and `unsupported_version` only through recognition. A vector gives
  `expect` (`ok` or an error code), `rule`, and for `ok` the `normalized` result described below.
- `builder_cases`: structured input for a builder and the exact text it MUST write (§12.7.1). `message` says what is
  built: `descriptor`, `src` or `cancel`. For a descriptor the input has `id_hex`, `k_hex`, `h_hex`, `sz`, `kind`, `nm` and
  `mt` (text, or UTF-16 code units in `nm_utf16` and `mt_utf16` for the platforms whose strings can hold an unpaired
  surrogate; the others skip those cases), `src`, `m`, `pv_hex`, `th`, `ex` and `xp`; a member absent from the input is
  absent for the builder. For `src` and `cancel` the input has `id_hex` and, for `src`, `src`. `expected` is also
  accepted by the receiver. The cases pin the escaping, the cut of `nm` and `mt` on raw bytes, the size rule (`m.wave`,
  then `pv`, then `th` are dropped) and that `src.obj` and `tok.v` are copied as given.

`receive_order` keeps its eight lines: recognition and the `unsupported_version` row are covered by the `recognition`
section, not by `receive_order`.

A body is carried as `serialized` (text) or, when it is not valid UTF-8 or a text tool could alter it (a byte order
mark), as `serialized_b64`, the base64 of its bytes; exactly one of the two is present, and a library compares and
parses BYTES. Together the sections pin recognition and versions, the JSON profile (size at exactly 8191, 8192 and 8193
bytes, duplicate names compared as code points, depth, surrogates, invalid UTF-8), integers, canonical base64, every
typed field (`src.obj`, `src.tok`, `ex`, `xp`, `nm`, `mt`, `pv`), the ignored `m`, the thumbnail rules, the order of the
checks and the canonical serialisation; every rule has at least one accepted and one rejected case. The earlier
`descriptors` section keeps its names and results (the object ids in it are now lowercase UUIDs, as §12.7.4 requires).

The `normalized` result of an accepted descriptor has: `sz` and `kind`; `nm` and `mt`, the strings or `null` when absent;
`pv_len`, the decoded length of the preview or `null`; `src`, with `via`, `obj` (kept when present, on a `direct` source
too, else `null`) and `tok` (`v`, `exp`, `max`, or `null`); `media`, `null` when `m` is absent or ignored, else an object
with `w`, `h`, `dur` and `wave`, each `null` when that member is absent (an empty `wave` stays an empty array);
`thumbnail`, `absent` (no `th`), `valid`, or `bad_descriptor` (an invalid `th`: the file stays valid); `ex` and `xp`,
the integers or `null` when absent (the defaults then apply). Integers compare as integers.
All keys in the file are test keys derived from public labels.

Latest: 2026-10-06 (file transfer v2, descriptor hardening: §12.7 gains §12.7.1 to §12.7.6, one behaviour for every point where
the three client libraries diverged. Recognition is a byte-prefix test on the compact `{"qa_file":` (and the two control
prefixes), any version, on the body exactly as decrypted; a plain integer version other than 2 is the new error code
`unsupported_version` whatever follows (invalid UTF-8 and a length of 8192 bytes or more included), any other malformed
version and every other rejection is `bad_descriptor`; a rejected descriptor is one placeholder, never shown, quoted,
notified or indexed, a rejected control message is dropped silently; a sender emits version 2 only until a signed
per-device announcement exists (§6). Builders emit the canonical form for descriptors and control messages (fixed
member order, no `null`, escaping, cut of `nm` and `mt` on raw bytes at a character boundary, `src.obj` and `tok.v` as
the server returned them, `m.wave` then `pv` then `th` dropped when the text would reach 8192 bytes). JSON profile: UTF-8,
under 8192 bytes, one object, no duplicate member names (compared as code points without normalisation), depth at most 4,
no lone surrogates, unknown members ignored but counted and their numbers never converted. Integers in plain decimal form
only, at most 2^53 - 1; base64 canonical. Typed fields: `src.obj` the server's lowercase UUID, `src.tok` scalars only with
`v` 64 lowercase hex and integer `exp` and `max`, `ex` -1, 0 or seconds up to 2^31 - 1, `xp` 0 or 1, all failing closed with
`bad_descriptor`; `nm`, `mt` and `pv` accept `null` as absent; a malformed `m` is ignored; an invalid `th` (or one with the
id of the file) makes the thumbnail unusable and the file stays valid, a thumbnail carries no `th`; a control message
applies only to a transfer of the same sender account and conversation. §12.9: a stream that ends before the last chunk is
`size_mismatch`, the padding check staying last. KAT: new sections `descriptor_constants`, `recognition`,
`descriptor_rules` and `builder_cases`, bodies that are not UTF-8 carried as `serialized_b64`, `error_codes` gains
`unsupported_version`; the other earlier sections keep their results, the object ids of the `descriptors` vectors are now
UUIDs.)
Previous: 2026-10-04 (closing: R-REKEY-ACCEPT-WAIT defines when an ACCEPT reaches the offerer (received by its transport
before T0 + 30 s) and says that an ACCEPT that reached it in time is processed to completion even if its verification
ends after the deadline, while one that reaches it at T0 + 30 s or later is dropped; it sorts every ACCEPT the offerer
receives once round 1 is bound in one place: a byte-identical copy of the bound round-1 ACCEPT is answered by the
REVEAL re-send in every state of the call, a rekey round that is waiting included (one event of the budget of 4), and
every other copy or late ACCEPT is dropped silently without touching a waiting round; R-ACCEPT-RESEND: a rekey ACCEPT
is re-sent only for a round the acceptor armed and has not decided, any other round is forgotten. KAT unchanged.)
Previous: 2026-10-04 (K-round review: R-KCMAC-ATOMIC, the per-call KCMAC state (PENDING, DECIDED, HELD) is changed by one
serialised step at a time, and arming is insert then re-offer as one step; stale held MACs (30 s or more) are dropped
before a new MAC is held, not only at arming; the bounds of 16 pending rounds and 8 held MACs are stated as state
limits, not pacing rules; R-REKEY-ACCEPT-WAIT says exactly what the offerer and the acceptor do when the ACCEPT is late
(the call goes on only if the acceptor never armed the round); step 2 compares the 32-byte MAC part; wording and
wrapping. KAT unchanged.)
Previous: 2026-10-03 (K-round: R-KCMAC-ROUNDS, every receiver keeps each undecided round, superseded ones included, with
its own window and attributes an inbound MAC by content; a MAC that matches no pending round is held (8, 30 s) and
never ends the call by itself; every pending round is judged, which closes the superseded-round fail-open; at most 16
pending rounds. The rekey acceptor waits 30 s for the offerer's MAC. R-REKEY-ACCEPT-WAIT, the rekey offerer waits 30 s
for the ACCEPT and processes at most one per round. R-ACCEPT-RESEND, the acceptor re-sends its unconfirmed ACCEPT in
the re-authentication re-send event. KAT unchanged.)
Previous: 2026-10-02 (night, four-way review of the T-round: R-KCMAC-RESEND also re-sends the own KCMAC of every round
first sent less than 30 s before the re-authentication, because a verified peer MAC does not show that the own MAC
arrived; a duplicate ACCEPT before round 1 is bound is no re-send event; a callee stops retransmitting its ACCEPT once
its REVEAL verified).
Previous: 2026-10-02 (evening, "no legitimate call may end after 5 s": one `CONFIRM_TIMEOUT` = 15 s in §3.7.1 for every
confirmation window; callee REVEAL timer 15 s; caller's round-1 KCMAC wait 30 s after its REVEAL, callee's 15 s after its
own REVEAL verified, early-MAC hold 30 s; R-KCMAC-NOGATE (the caller's round-1 KCMAC is never gated on `call_accepted`);
R-KCMAC-RESEND (KCMAC re-sent after a socket re-authentication, one shared re-send budget of 4); R-ANSWER-FIRST (a 1:1
callee never sends an ACCEPT or sets up media before the user answers, a call without `callId` ends with
`handshake_malformed`; §3.5 and §3.8.2 follow); DTLS statistics check retried for 15 s after `connected` (§3.8.4);
R-CONFIRM-TELEMETRY `confirm_timeout` event; close-reason table maps every timer; supersedes the 5 s / 10 s / 15 s values
of the previous entry).
Previous: 2026-10-02 (afternoon: R-COMMIT-KCMAC-HOLD and R-COMMIT-KCMAC-DEVICE in §3.7.4, §3.7.1 timing; server
stamps `sender_device_id` on live `opaque_message`; the callee's round-1 KCMAC wait ends no earlier than 5 s after its
REVEAL verified; §12 file transfer v2 merged from main).
Previous: 2026-10-02 (SAS commitment: signed transcript v6 §3.7, new §3.7.4 commitment and REVEAL, §4 SAS v6 over a
caller nonce, close reasons `sas_commit_mismatch` / `sas_reveal_timeout`, round-1-only SAS, KAT
`tools/kat/handshake-sig-v6/`; v5 transcript, `sigV5` and the v5 KAT removed).
Previous: 2026-10-02 (new §12 file transfer v2, AES-256-GCM chunked format, hard switch; §1 label rows for the earlier
attachment and file key schemes replaced by the v2 derivation row; known-answer vectors in test/kat/file_v2).
Previous: 2026-10-01 (v5 review round: R-ROLE and R-SLOT in §3.7.2, R-KCMAC on every round in §3.7.1,
R-ROUND in §3.1, R-EARBUD §3.7.3, R-CERT in §3.8, reflection handling §11.5/§11.7, random-byte slot retirement).
Previous: 2026-10-01 (§3 rewritten: single JSON dialect, signed transcript v5 §3.7 with
OFFER/ACCEPT DTLS fingerprints, DTLS certificate binding §3.8, directional 1:1 frame keys,
fail-closed KCMAC; §4 SAS bound to ACCEPT v5; §6 hard-switch note; new §11 frame E2EE wire
format and receiver replay window).
Previous: 2026-09-30 (added §10 group calls v2 / qjanus; the LiveKit path is gone).
Previous: 2026-07-13 (§8.8 documented `audio_relay_degraded`).
Previous: 2026-07-03 (added §8 mid-call upgrade state machine, glare,
DTLS/mid invariants, media-readiness + keyframe wire, rail/key-custody
rules). Previous: 2026-06-27 (realignment: §1.1 SRTP labels, §2.7 KMS v2
AAD-bound wire, §3.3 caller-priority PSK, §4 uint24 SAS, §7 earbud GATT
family).
