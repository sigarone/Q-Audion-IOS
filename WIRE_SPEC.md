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
| Attachment AEAD key | random 32 B | `q-audion-attachment-aead-v1` |
| Attachment AEAD nonce | random 32 B | `q-audion-attachment-nonce-v1` |
| File transfer key | random 32 B | `q-audion-file-key` |
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

Two wire formats coexist on the network for historical reasons. New
implementations MUST be able to consume BOTH and SHOULD be configurable
to emit either.

### 3.1 Android JSON HandshakeBundle (Android-native, Desktop-supported)

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
  "capabilities": { "ratchetV3": true },
  "pskFingerprints":         ["<sha256 hex>", ...],     // OFFER only
  "selectedPskFingerprint":  "<sha256 hex>"             // ACCEPT only
}
```

`ciphertext` is OMITTED in OFFER and PRESENT in ACCEPT.

### 3.2 QUAD binary frame (iOS-native, Desktop-supported)

Wire shape: base64-encoded binary in `data`.

```
[4B MAGIC "QUAD"][1B type][1B version=0x01][1B features]
[2B pubKeyLen BE][pubKey][2B kemLen BE][kemCT]
[2B fpCount BE][for each fp: 2B fpLen BE + UTF-8 bytes]
```

Type codes (`uint8`):
- `0x01` OFFER
- `0x02` ACCEPT
- `0x03` DC SDP OFFER
- `0x04` DC SDP ANSWER
- `0x05` DC ICE
- `0x06` AUDIO_DATA
- `0x07` VOICE_ANALYSIS
- `0x08` CALL_HANGUP
- `0x09` KEY_EXCHANGE_OFFER
- `0x0a` KEY_EXCHANGE_ACCEPT

The QUAD wire carries a SINGLE combined kemPublicKey field instead of
the split (pqc/x25519/dualCurve) JSON fields. This means a JSON OFFER
cannot be losslessly converted to QUAD without an engine-level wire
extension. iOS interoperates with Android by parsing the JSON form
directly (planned, see §6).

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
`ciphertext.x25519` on the ACCEPT leg. Both are already bound by the §3.2 v2
transcript (`offerV2` binds `lp(x25519PublicKey)`; `acceptV2` binds
`lp(ctX25519)`).

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
`pskRoles` already encodes as all-zero role bytes, so the §3.2 signature covers
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
* Rewriting the initiator's advertisement in place IS covered by the §3.2 signature —
  but note that verification is advisory under W-NOBRICK, so that coverage detects
  and reports rather than prevents.
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
  peer, and binding the real order in `advEnc` (§3.2) is what closes it — but the
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
("the network is ready"); it MAY be sent automatically by a client ahead
of any real user action, as an optimization to reduce P2P setup latency.
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

---

## 4. Short Authentication String (SAS)

```
SAS-IKM   = sessionKey (32 B from §3 PQC handshake)
SAS-KDF   = HKDF-SHA256(IKM=SAS-IKM, salt="qaudion-sas-v1", info="sas-words-v1", L=18)
indices   = 6 × uint24 read big-endian from SAS-KDF (3-byte stride, consuming
            all 18 bytes: idx[i] = (out[3i]<<16)|(out[3i+1]<<8)|out[3i+2];
            see CallSas.ts:79-84 and PgpSasWords.kt:35 for the byte layout)
words     = PGP wordlist[indices[i] mod wordlist.length] for i in 0..5
            (wordlist.length == 256 — PgpSasWords.kt:120, PgpSasWordList.ts:74)
```

All three platforms MUST produce byte-equal SAS for the same session
key. Cross-platform KAT vectors planned in `tools/kat/sas/`.

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
| Cross-platform KAT vectors — SAS | tools/kat/sas | ✅ done 2026-05-06: tools/kat/sas/sas-kat.json (4 vectors: all-zeros, all-ones, incremental, pinned-pi-bytes) mirrored byte-equal in all 4 repos. Verifier tests on Android (SasCrossPlatformKatTest.kt, BouncyCastle HKDF), Desktop (CallSas.kat.spec.ts, noble HKDF), iOS (SasCrossPlatformKatTests.swift, CryptoKit HKDF) load the JSON + assert HKDF output byte-equal AND production SAS path produces the pinned 6 words. |
| Cross-platform KAT vectors — Hybrid PQC combine | tools/kat/hybrid-combine | ✅ done 2026-05-06: tools/kat/hybrid-combine/hybrid-combine-kat.json (6 vectors: all-zeros, all-ones, asymmetric-pqc, asymmetric-x25519, incremental, mid-pi-bytes) mirrored byte-equal in all 4 repos. Verifier tests on Android (HybridCombineKatTest.kt, BouncyCastle HKDF), Desktop (HybridCombine.kat.spec.ts, noble HKDF), iOS (HybridCombineKatTests.swift, CryptoKit HKDF) load the JSON + assert HKDF-SHA256(IKM=pqcSs\|\|x25519Ss, salt='q-audion-hybrid-pqc-v1', info='q-audion-session-key', L=32) reproduces every pinned session key byte-for-byte. Pins WIRE_SPEC §1 + §3.2. |
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

- `media` = `"camera"` (explicit consent dialog required) or `"screen"`
  (auto-accept). An UNKNOWN value MUST be treated as `"camera"`
  (fail-safe: consent required). The field is part of the wire contract —
  any server implementation that re-marshals typed structs MUST carry it.
- `sdp` non-empty ⇒ WebRTC renegotiation. `sdp` empty ⇒ WS-relay rail
  (no live PC); `accepted=true` with empty `sdp` is an accept WITHOUT
  renegotiation, not a malformed response.

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

### 8.7 Media readiness & keyframe recovery (v1.1)

- `call_media_ready`: the RECEIVER sends it when its receiver-cryptor is
  BOTH keyed and bound to the negotiated video mid. The SENDER SHOULD
  hold video TX (camera or gate) until ready arrives or a **2 s** timeout
  elapses (timeout ⇒ proceed as today — the handshake is an optimization
  for correctness, never a hard gate: signal-not-kill). On receiving
  ready, the sender MUST force an IDR.
- `video_keyframe_request`: receiver→sender; the sender MUST force a
  local encoder IDR. Senders rate-limit to 1/s. Rationale: the E2EE
  frame-transform suppresses libwebrtc's native PLI on every platform,
  so decoder recovery REQUIRES an explicit wire path. Platforms SHOULD
  additionally run a periodic (~5 s) sender-side IDR forcer.
- Rekey: `key_epoch` is monotonic per call. Receivers keep the PREVIOUS
  video key valid for a grace window (mirror of the audio `previousKey`
  fallback) so in-flight frames sealed under the old epoch still decrypt.

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


---

Last reviewed: 2026-07-24 (§8.9 video-state beacon; §3.5/§3.6 de-collided —
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

Previous: 2026-07-13 (§8.8 documented `audio_relay_degraded`).
Previous: 2026-07-03 (added §8 mid-call upgrade state machine, glare,
DTLS/mid invariants, media-readiness + keyframe wire, rail/key-custody
rules). Previous: 2026-06-27 (realignment: §1.1 SRTP labels, §2.7 KMS v2
AAD-bound wire, §3.3 caller-priority PSK, §4 uint24 SAS, §7 earbud GATT
family).
