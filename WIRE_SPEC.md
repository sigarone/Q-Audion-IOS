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

### 3.4 Mid-handshake hangup

A peer-initiated `call_hangup` arriving while the controller is in
the `Handshaking` state MUST cancel the active handshake job
immediately and surface a clear UI reason. Without this, the
initiator waits the full 35 s `HANDSHAKE_TIMEOUT` before giving up.
Implemented on Android via `armHandshakeHangupListener`; iOS uses
the same `call_hangup` signal as a fail-fast when it detects an
incompatible wire format (Path B in `wireOpaqueMessageHandler`).

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

Last reviewed: 2026-06-27 (realignment: §1.1 SRTP labels, §2.7 KMS v2 AAD-bound wire, §3.3 caller-priority PSK, §4 uint24 SAS, §7 earbud GATT family).
