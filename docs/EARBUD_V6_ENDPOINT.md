# Hardware earbud as a v6 call endpoint — design specification

Status: Accepted by the owner 2026-11-17 (revision 2 + decisions). The accepted text is revision 2, which answers an
adversarial review of revision 1 (§16 lists every issue raised and what was done with it), with the owner's decisions
on the open points recorded and made normative (§14). This file is revision 4 of that text: revision 3 recorded the
first round of decisions, revision 4 records the second round of the same evening and answers the open questions of
the reviewers and of the KAT generator (§14, §17.2), with the fixes of the review of its first text (§17.2 rows 40 to
52). §17 lists every change of both revisions and carries no rule.
Docs only: nothing in this file changes behaviour until the WIRE_SPEC text of
Appendix A and Appendix B has landed byte-identical in every locked copy together with this file (§13.3) and the KAT
file of §13 is generated and pinned. Implementation work on the earbud call path starts from phase 0 of §12.1, after
that landing.

Scope: 1:1 calls in which the hardware earbud (nRF54LM20B) is the cryptographic endpoint, hosted by an Android or an
iOS phone (owner decisions of 2026-11-17, §1.1). Remote peers of every platform (Android, iOS, Desktop, web app).

Baselines this document was written against (every `file:line` below refers to them):

| Repo | Ref | Note |
|---|---|---|
| bcrypto-server | `origin/main` `c1790e7` (2026-11-13) | `WIRE_SPEC.md` sha256 `7a12b308ba282fb79d10ce7bd0b0c8d06d409e4dcb5828c30278eb2da7a4c277`, the `EXPECTED` value of `.github/workflows/wire-spec-lock.yml`; `docs/PQC_HARDENING_V1.md` revision 9 (§10.7) |
| bcrypto-server open PRs | checked 2026-11-17 | only #328 (earbud-excl-v2 KAT sync, verifier docstring); it touches neither `WIRE_SPEC.md` nor `docs/PQC_HARDENING_V1.md` |
| qaudion-android-new | `origin/main` `970e77fd` (2026-11-16) | the files first cited in revision 2 were read at `614bc164` (2026-11-17) |
| qaudion-ios | `origin/main` `6859edb7` (2026-11-17) | the alignment snapshot of 2026-11-16 was `d269ef18`; the files cited were re-read at `6859edb7` |
| qaudion-firmware | PR #5, `fix/fw-build-align-2026-11` head `74a43d2` | LM20B builds on NCS v3.3.5; `main` was `38fad83` when read (PR #5 has merged since: `main` is `235b994` on 2026-11-18); `button_handler.c`, `ble_gap.c`, `secure_services.c` and both `prj.conf` files were re-read at `74a43d2` for revision 2 |
| qaudion-firmware | PR #6, `fix/mcuboot-ed25519-2026-11` head `03a83f3` | stacked on PR #5; read for revision 3 only, for the MCUboot anti-rollback decision (§8.3): `firmware/sysbuild.conf`, `firmware/sysbuild/mcuboot.conf` |
| Firmware spike | 2026-11-17, helsinki `~/vol/fwbuild/spike-logs` | Ed25519, ML-DSA-87, veneers, transport and RAM measurements quoted in §12; silicon timings were not measured |
| qaudion-firmware | branch `feat/ep-phase0` read at `934e22a` (stacked on `74a43d2`; its head on 2026-11-18 is `86293ad`, after a merge of `main` and a runbook commit) | read for revision 4: `docs/PHASE0_DK_RUNBOOK.md` and the commits `1b759cc` (bench log levels) and `934e22a` (phase-0 headroom); the flash and RAM figures of §12.2 and §12.3 marked "measured, revision 4" come from NCS v3.3.5 builds of `74a43d2` and of this branch (the LC3 and LE Audio figure from two phase-0 builds at `201188a`, Appendix C); `qaudion_gatt.c` re-read at `74a43d2` for the DIAG record (§4.5); the runbook, `config/phase0_mldsa.conf` and `~/vol/ep0-artifacts/BUILD_INFO.txt` re-read at `86293ad` for the review of revision 4 (§3.1, Appendix C) |
| bcrypto-server | branch `kat/earbud-ep-v1` head `e7cde5d` | `tools/kat/earbud-ep-v1/README.md`: the open points TODO-1 to TODO-19 that revision 4 answers (§17.2) |

This document is a companion of `WIRE_SPEC.md` and `docs/PQC_HARDENING_V1.md`. It defines no new call transcript,
call KDF, KCMAC, SAS or media construction: the earbud speaks exactly the v6 handshake of WIRE_SPEC §3.7 and the
hardening items of PQC_HARDENING_V1 that it implements. What is new is who computes what (the earbud, not the phone),
the link between the phone and the earbud (with its own authenticated key exchange, §4.3, which never leaves the
phone-earbud link), the earbud's identity, and the rules that make peers accept that identity.

---

## 0. Conventions and terms

- MUST, MUST NOT, SHOULD, MAY as in RFC 2119.
- Integers are big-endian unless a field is marked LE. `LP(x) = u16(len(x)) ‖ x`. `‖` is concatenation. Strings are
  ASCII bytes with no NUL and no length prefix unless wrapped in `LP`. `∅` is the empty string.
- `HKDF(IKM, salt, info, L)` is HKDF-SHA256 (RFC 5869), extract then expand; `HKDF-Expand(PRK, info, L)` is expand only.
- Ed25519 is pure RFC 8032. Every Ed25519 verification of this document applies the uniform Ed25519 rule of
  PQC_HARDENING_V1 §5.2 (canonical key, not of small order, cofactorless equation, `S < L`, canonical `R`).
- `callId`, `callIdL`, `E` (key round epoch, `E = rekeyRound − 1`), the call roles `o` (caller) and `a` (callee) and
  `dirTag(o2a) = 0x01`, `dirTag(a2o) = 0x02` are those of PQC_HARDENING_V1 §0.
- "WIRE_SPEC" is the calling contract `WIRE_SPEC.md`: at the lock sha of the baseline table when this text was
  written, and from the landing of Appendix A and Appendix B (§17) at the hash that its lock records; "PQC" is
  `docs/PQC_HARDENING_V1.md`. "PQC B2" means item B2 of that document.
- Constants fixed by the owner decisions of §14: `EP_MAX_HOSTS = 4` (hosts per earbud, OD-2, §3.2),
  `EP_MAX_ENDPOINTS_PER_USER = 4` and `EP_MAX_TOMBSTONES_PER_USER = 32` (§3.6); the capture press adds
  `ANSWER_PRESS_WINDOW = 10 s` (OD-6 (b), §7.10, value confirmed by the owner on 2026-11-17). Every other constant is
  defined where it first appears.

| Term | Meaning |
|---|---|
| earbud, EP | the hardware earbud acting as the call endpoint |
| host | the phone (Android or iOS) bonded to the earbud and running the Q-Audion app |
| remote peer | the other endpoint of the 1:1 call: a phone, Desktop, the web app, or another host with an earbud |
| HK | the host device's Ed25519 identity key, the key that signs `sigV6` in a phone call today |
| EK | the earbud's Ed25519 endpoint key, generated in the earbud and never exported (§3.1) |
| `earbudId` | `SHA-256(pk_se)`, the existing attestation identifier of the earbud (WIRE_SPEC §7, `0xc0`) |
| EPC | the endpoint certificate that binds EK to the account and to HK (§3.3) |
| EPL | the endpoint link: the L2CAP channel between host and earbud and its record protocol (§4) |
| EPL session | one channel open, from `HOST_HELLO` to the close, with its own X25519 exchange and record keys (§4.3) |
| owner host | the host whose authenticated EPL session created a call context; only it may drive that context (§9.13) |
| confirm gesture | a press-and-hold of at least 3 s of the earbud button that starts after the earbud opened a confirm window; the only gesture that confirms an enrolment or the removal of another host (§9.14) |
| EP call | a 1:1 call whose local endpoint is the earbud |
| no-endpoint earbud | an earbud whose image reports PROTOCOL_VERSION `0x02` and exposes no `EP_INFO` (the authoritative and production images, §10.1): its host uses only the characteristics that WIRE_SPEC §7 keeps besides `EP_INFO` (DIAG, attestation, KEY_IMPORT, FE-5 pairing, PSK_LIST), opens no EPL and places no EP call (§8.1) |
| secure code | the firmware modules that hold call secrets. With owner decision (2) the dev board runs a single image, so this is a module boundary, not hardware isolation (§1.4, §10.2) |

---

## 1. Scope, goals and threat model

### 1.1 Owner decisions this design implements (2026-11-17)

1. Option A: the earbud is a full v6 call endpoint. It holds its own signing identity, signs OFFER_v6 and ACCEPT_v6
   (Ed25519 first, ML-DSA-87 `sigHybridV1` when flash allows), derives `sessionKey`, `K_kc` and the SAS in the secure
   code, and exports only one-way outer-relay keys to the phone. The phone is a blind relay for audio.
2. The dev board runs the single image plus the bench overlay now. A real TF-M partition is a separate, later project.
3. iOS MUST be able to host the earbud, not only Android.
4. Earbud OTA from the phone comes after the call works. Only the MCUboot image signing (Ed25519, offline key) and
   the software anti-rollback check are fixed now (§8.3).
5. The open decisions of revision 2 were decided together with its acceptance (§14): OD-1 (a), the limit against an
   active host at call setup is stated and accepted and no earbud-played SAS is built now; OD-2, up to 4 host devices
   of the same account per earbud; OD-3, if the earbud is unavailable before the first bundle the call runs on the
   phone with a visible notice; OD-4, endpoint calls exist on the CI and bench profiles only until the PCB profile
   exists, with no RAM cuts on the authoritative profile now; OD-5, LE Audio and the cellular passthrough stay, with
   the exclusivity rules of §9.6; OD-6 (b), the capture indicator plus a fresh earbud press in each call before the
   microphone opens. MCUboot anti-rollback is the software version check now; the hardware OTP counter is decided
   later, with the factory flow.
6. Second round, the same evening (§14): the retired relay plane is removed from every firmware profile in phase 1,
   so the authoritative and production images report PROTOCOL_VERSION `0x02` without `EP_INFO` and their hosts apply
   the decision of §8.1; the values revision 3 chose are confirmed; a refusing `EP_AUTH` carries no key and no
   signature (§4.3); the envelope's `sender_device_id` is always required (§3.7); and the server rules of §3.6: only
   the host device publishes, per-host removal, a cap of 32 tombstones per account, erasure at account deletion, the
   DR and failover export, strict decoding of the publish body.

Owner rules of earlier decisions that still bind this design: no call is refused because a peer lacks a capability
(PQC §0.1 rule 1; the checks this document adds that can end a call are tampering or identity checks, stated as such
where they appear); before launch a binary-incompatible change is a hard switch (WIRE_SPEC §6); phones keep Opus
60 ms / 32 kbps (PQC §0.1 rule 8); pin anomalies are warning only (PQC §2.5, owner decision Q9).

### 1.2 Goals

- G1. In an EP call the earbud alone holds the round secrets: the ML-KEM-1024 and X25519 private keys, `pqcSS`,
  `x25519SS`, `sessionKey_E`, `K_kc`, `ck_E`, the inner keys `kIn` (or the legacy inner key), the caller's `sasNonce`
  until the REVEAL is due, and EK's private key. The host receives only the values listed in §6.6, each of them public
  or a one-way function of `sessionKey_E` bound to its purpose.
- G2. The earbud's signature is the v6 signature of the call: `signerIdentityKey` is EK. A remote peer authenticates
  EK through a certificate made by the host's identity key, and pins it without disturbing the existing device pins
  or the chat safety number (§3.7). The post-quantum half of the call's authentication is anchored in the host
  device's ML-DSA key and in the contact's existing PQ pin of that device, so an endpoint call is never a silent
  downgrade toward a contact who pinned the host (§3.9).
- G3. Android and iOS can both host, with one protocol (§4) and one set of host rules (§9).
- G4. Remote peers interoperate with no change to the v6 transcript, KDF, KCMAC, SAS, KCMAC timing or media envelopes.
- G5. The firmware work is phased to the measured flash and RAM budget (§12).

### 1.3 Non-goals

- No new transcript version and no change to any formula of WIRE_SPEC §3.7, §4 or PQC.
- No DTLS, ICE, WebRTC or signalling in the earbud: the host keeps all of them.
- No video, screen share, mid-call upgrade or group call with the earbud as endpoint (§9.8).
- No hardware isolation claim before the TF-M project, and no hardware attestation of EK (gap S-3) in this revision.
- No earbud OTA (owner decision 4).
- No protection against an actively compromised host at call setup and no earbud-rendered SAS (OD-1 (a), §1.4, §5.9).
- No handover of a running call between the earbud and the phone (§9.8).

### 1.4 Threat model

| Adversary | What it can do | Outcome in an EP call |
|---|---|---|
| Server, relay, network | read, drop, delay, modify signalling and media | as in a phone call today: content protected by the v6 session; tampering ends the call by the existing rules (`kcmac_mismatch`, `dtls_fp_mismatch`, `handshake_malformed`) |
| Passive host compromise, during or after the call (malware reading memory, a forensic dump, logs) | everything the host holds | cannot recover audio or any round secret (G1). It sees metadata, timing, the SAS words, the inner envelope headers and the outer keys, which only remove the outer layer |
| Active host compromise at call setup | controls the host app, the peer bundle it hands to the earbud and the SAS it displays | OUT OF SCOPE of this revision, stated plainly. The host can hand the earbud a peer bundle signed by a key it holds, terminate the earbud's leg itself, place its own leg to the real peer, and show the user the SAS of that leg, which matches the peer's. The earbud has no anchor of its own for the peer's identity: everything it could check (peer user id, peer key, the SAS shown) comes from the host. Option A protects against passive host compromise (G1), not against an active one at call setup; an earbud-rendered SAS is the only known countermeasure, and the owner decided on 2026-11-17 not to build it now (OD-1 (a): the limit is stated and accepted) |
| Active host compromise toward the remote peer | holds HK and the host's ML-DSA key | can always place a phone-endpoint call signed by HK, as today, and can also mint a software key with a valid EPC and pop (§3.3), because both signatures are made by keys it holds. The "earbud" label a remote peer shows is therefore asserted by the contact's host and never proved (no attestation, gap S-3); the UI says so (§3.10, §9.10) |
| Other apps on the host phone (the BLE bond is OS-wide) | open GATT or L2CAP to the bonded earbud | cannot use the call plane: every EPL session starts with an Ed25519 challenge that only an enrolled host's identity key can answer (§4.3). Enrolling a new host needs a fresh bond or a pairing-mode window opened by a physical long press, plus a fresh confirm gesture after an audible host code that the genuine app plays as well (§3.4) |
| Enrolled host that is malicious or compromised, used as a remote microphone | creates a call context with a peer it controls | the earbud never captures without the capture indicator (start cue, LED, periodic cue), which the host cannot turn off; it also needs a fresh earbud press per call (OD-6 (b)) before it captures anything but encoded silence (§7.10) |
| Radio attacker present at the first pairing | the earbud has no display, so LESC numeric comparison is nominal and an active attacker may hold the BLE link keys (§9.2) | the EPL runs its own authenticated X25519 exchange with sealed records (§4.3): after the first enrolment every session is mutually authenticated by HK and EK, so the attacker can neither read nor change EPL records. The first enrolment is protected by the committed, audible enrolment code (§3.4), with a 1 in 256 chance per attempt for an attacker who must also get the user to hold the button |
| Thief of the earbud alone | physical possession | cannot place calls as the owner (needs the owner's account and host). Enrolling the earbud to another account needs a factory reset, which destroys EK (§3.8) |
| Physical attacker with a debugger on a bench unit | SWD access | the bench overlay disables APPROTECT: every key is readable. Dev boards are not sovereign devices, and their EPC says so (`buildProfile`, §3.3) |
| Code execution on the earbud | any memory | with the single image every secret is exposed; isolation comes with the TF-M project |
| Quantum adversary | breaks X25519, Ed25519 | session keys stay hybrid ML-KEM-1024 + X25519 as today. Authentication: `sigHybridV1` whose ML-DSA half is made by the host device in phase 1 (host-anchored, §3.9) and by the earbud in phase 2; toward a contact who pinned the host's ML-DSA key, an endpoint bundle without a valid hybrid signature is the visible PQ anomaly of PQC §5.5, never a silent classical call |

### 1.5 What changes for whom

| Repo | Change |
|---|---|
| firmware | the endpoint itself: EPL with its session protocol, identity, enrolment gate, v6 handshake, key schedule, inner seal, media profile, media gate and capture indicator, gestures, exclusivity, telemetry; removal of the retired relay dialect from every firmware profile (§8.4) |
| Android | host role (§9), including the host-anchored `sigPq` (§3.9); remote-peer verification of earbud endpoints (§3.7, R-EP-PQ); 20 ms receive from an earbud peer (§2.3) |
| iOS | host role, new feature (§9.11); remote-peer verification; audio profile rule |
| Desktop, web app | remote-peer verification of earbud endpoints (R-EP-VERIFY, R-EP-PQ) and the audio profile rule only |
| server | endpoint records API (§3.6): publication by the host device only, strict body decoding, per-host removal, permanent tombstones with a cap per account, erasure at account deletion keeping only the hashes of revoked keys, the DR and failover export, the Sigsum leaf; `certPq` verification (phase 2, §3.9); KAT generator and recomputation (§13); the WIRE_SPEC lock gains the firmware repo and a second hash for this document |

---

## 2. Architecture

### 2.1 Split of functions

| Function | Earbud | Host |
|---|---|---|
| WebSocket signalling, `opaque_message`, `call_offer`/`call_answer`/`call_accepted`, ICE, the PeerConnection, DTLS (per-call certificate, checks (a) and (b) of WIRE_SPEC §3.8), DataChannel `qaudion-audio`, WS `audio_frame` | | yes |
| JSON HandshakeBundle assembly and strict parsing (WIRE_SPEC §3.1, D27, D28 routing), malformed checks, 24 KiB rule | | yes |
| Identity resolution of the remote peer (pins, server fetch, published set, R-IDENTITY), PQ pin policy (PQC §2.5, §5.5), warnings | | yes |
| Verification of the remote peer's `sigV6` | no (§5.8) | yes |
| Verification of the remote peer's `sigHybrid` | | yes |
| Own `sigV6`; `sigEd` of the own `sigHybrid` (over `HT`, PQC §5.4) | yes | |
| `sigPq` of the own `sigHybrid` | phase 2 (earbud ML-DSA key) | phase 1 (the host device's ML-DSA key, host-anchored, §3.9) |
| EPL session key exchange and record sealing (§4.3) | yes | yes |
| ML-KEM-1024 and X25519 of each key round (keygen, encapsulation, decapsulation) | yes | |
| `relayKem` exchange (`relaySS`) | | yes |
| `kOut` derivation (needs `sessionKey_E`) | yes, then exported | installs and uses |
| PSK vault, advert tags (WIRE_SPEC §3.3.1), selection | hw_only PSKs, phase 1b | host PSKs |
| `sessionKey_E`, `K_kc`, `kc_transcript` / `kc_transcript_x`, both MACs, SAS-KDF, `sasNonce` and `sasCommit`, `ck_E` | yes | |
| KCMAC state machine (PENDING, DECIDED, HELD, windows, re-sends, budget, timers) | | yes, using the MAC values the earbud returns (§5.2) |
| Inner seal (PQC B2 or legacy with B1), inner receive slots, inner replay window | yes | |
| Outer seal (`kOut` or M-15), outer counters, outer replay window, outer send pointer (PQC B5), NACK cache (PQC B12), control lane `0x03` (WIRE_SPEC §16) | | yes |
| Opus encode and decode, jitter buffer, concealment, microphone and speaker processing, voice (deepfake) scoring | yes | |
| Call UI, CallKit or ConnectionService, SAS display, telemetry into Loki | | yes |

### 2.2 Data path

```
TX: mic -> DSP -> Opus 20 ms -> 120 B block -> inner seal (earbud) -> EPL AUDIO_OUT -> host
    -> outer seal (kOut or M-15) -> DataChannel 'qaudion-audio' or WS audio_frame -> remote peer
RX: remote peer -> DataChannel or WS -> host: outer open, peek first byte
    0x03 control  -> host (hangup, NACK, hold, outer-off)
    0x01 / 0x04   -> EPL AUDIO_IN -> earbud: inner open, replay check, Opus decode (20/40/60 ms) -> speaker
    anything else -> dropped by the host
```

The host never holds decrypted audio, so it never plays or captures call audio in an EP call.

### 2.3 Capability tag `earbudEpV1` and the audio profile (R-EP-PROFILE)

`earbudEpV1` is a new boolean member of the bundle `capabilities` object (PQC §2.2 pattern: advertised `true` or
omitted). Requires `capsBindV1` in the same bundle. It enters CAPSX, so with `capsBindV1` on both sides a relay that
strips or adds it fails the round's KCMAC (PQC §2.4).

It is a declaration of the signer, not a negotiated feature: a receiver applies it whenever the PEER's round-1 bundle
carries it (with `capsBindV1`), whatever its own bundle says. Its meaning is fixed:

1. The signer sends audio as 20 ms Opus frames in 120 B blocks, one block every 20 ms, and receives frames of 20, 40
   or 60 ms in blocks of at most 256 B.
2. The call is audio only: no video, screen share, mid-call upgrade (WIRE_SPEC §8) or promotion to a group call.
3. Every bundle of the signer carries the `endpoint` member (§3.5).

R-EP-PROFILE. A sender keeps its own send profile whatever the peer's tag says: a phone sends 60 ms / 256 B (the
profile Android names `W-ALL60` in code; the name is an implementation label, not a WIRE_SPEC rule), an earbud sends
20 ms / 120 B. Each direction is constant-size and constant-rate on its own; the two directions differ. A receiver
whose peer's round-1 bundle carries `earbudEpV1` MUST accept 20 ms / 120 B frames at 50 frames per second. The
decision is made from the round-1 bundles, which both sides hold when round 1 binds, so the arrival-order problem
that made Android drop profile negotiation (`CallCapabilities.kt:893-930`) does not arise. Every receiver, the
firmware included, passes the `profileRx` vectors of §13.1.

Consequences per platform:

- Android: `resolveAudioProfile` keeps returning `DEFAULT` for its own send profile; the clause `earbudPaired ->
  STANDARD` (`CallCapabilities.kt:926-927`) is removed, because a host does not encode audio in an EP call at all.
- iOS: `resolveAudioProfile(negotiated:, earbudInCall:)` reads the unsigned `earbud-relay-v1` tag
  (`CallCapabilities.swift:1421`, `CallService.swift:1715`), which WIRE_SPEC §3.7.3 says MUST be ignored; that input is
  removed. iOS keeps `long60x256` for its own TX. Its receiver decodes blocks of any size up to the opened plaintext
  (`QAudionEngine.swift:557-590`); the `profileRx` receive test at 50 frames per second of 120 B blocks is required
  (§13.1).
- Desktop and the web app: the same receive rule; their send profile is unchanged.

### 2.4 Tags and capabilities in an EP call

| Tag (bundle `capabilities`) | In the earbud's bundles | Implemented by |
|---|---|---|
| `capsBindV1` | REQUIRED | earbud (CAPSX and EXTX in `kc_transcript_x`) |
| `earbudEpV1` | REQUIRED | earbud declares, peers honour (§2.3) |
| `innerSealV2` | REQUIRED | earbud. A peer without it gets the legacy inner seal with the B1 nonce (§7.3) |
| `rekeyChainV1` | REQUIRED | earbud (PQC B13) |
| `relayKemV1` | host decides, SHOULD | host runs the relay KEM, the earbud derives `kOut` (§6.6) |
| `relayRotV1` | host decides | as `relayKemV1`, per round |
| `frameKeyV6` | MUST NOT | none: an EP call has no FrameCryptor (PQC B6, D13) |
| `sigHybridV1` | exactly when the host device has a published ML-DSA key (phase 1) or the firmware has its own (phase 2) | earbud signs `sigEd`; the host (phase 1) or the earbud (phase 2) signs `sigPq` (§3.9); the host verifies the peer |
| `innerAudioAadV1` | MUST NOT | retired (PQC §2.2) |
| `capsWithdrawn` member | MUST NOT | the earbud never withdraws a tag in v1; a host MUST NOT add the member to an earbud bundle |

CAPS9 (the nine signed booleans of WIRE_SPEC §3.7): the earbud signs `sframeV1 = 0x00` and `vkeyV1 = 0x00` whatever the
host supplies (no video), and returns the nine bytes it signed, which the host MUST copy into the JSON. The seven
other bytes (`ratchetV3`, `sessionKdfV3`, `ratchetV4`, `srtpDirKeyV1`, `pskMixV1`, `hsTranscriptBindV1`, `ratchetV5`)
MUST be exactly the bytes that the same host build would sign in a phone-endpoint bundle of the same call toward the
same peer. Reason: Android and iOS keep sticky per-contact pins on some of these bits, keyed by the contact and not by
the signer key (PQC F4, F5; Android `HandshakeSigner.kt:337-353`, iOS `HandshakeSigningPolicy.swift:183-188`), so an
endpoint bundle that signs `ratchetV5 = 0x00` toward a contact pinned capable is held as `ratchet_v5_downgrade`, and
one that drops `srtpDirKeyV1` loses the directional relay keys. The values are build-dependent (Android derives
`ratchetV4` and `srtpDirKeyV1` from runtime switches, `PqcHandshake.kt:1782-1786`, `:3438-3459`), so they cannot be
constants of this document; the earbud cannot check them and the `flows` vectors of §13 pin the bytes of each case.

Unsigned call-signalling capability strings (the `capabilities` list of `call_offer`, `call_answer`,
`call_incoming`): these strings are platform constants (Android `CallCapabilities.kt`, iOS `CallCapabilities.swift`);
most of them are not defined in WIRE_SPEC, and the list below is a host implementation rule of this document, not a
wire rule. In an EP call the host MUST NOT advertise `audio-srtp-v1` (WIRE_SPEC: no FrameCryptor can carry frames
the host cannot open), any video or SFrame string (`vkey-v1`, `sframe-v1`, `sframe-aes256-v1`), the mid-call upgrade
string `upgrade-intent-recv-v1`, or `aprof-60x256-v1` (the endpoint does not send 60 ms). It advertises the other
strings it advertises in a phone call (`aprof-60x256-recv-v1`, `dc-mux-v1`, `dc-hangup-v1`, `audio-nack-v1`,
`outer-off-v1`, `call-hold-v1`, `ice-batch-v1`, `restart-ice-req-v1` in today's builds). It MUST NOT advertise
`earbud-relay-v1` (retired, Appendix A).

---

## 3. Identity

### 3.1 The endpoint key EK

- EK is an Ed25519 key pair generated inside the earbud with `psa_generate_key`, in the CRACEN KMU, RAW scheme
  (scheme 3), algorithm `PSA_ALG_PURE_EDDSA`, type `PSA_KEY_TYPE_ECC_KEY_PAIR(PSA_ECC_FAMILY_TWISTED_EDWARDS)` of 255
  bits, usage `PSA_KEY_USAGE_SIGN_MESSAGE` only (no EXPORT, no COPY), handle `0x7fff0000 | (3 << 12) | slot`. The
  public key is read with `psa_export_public_key`. Kconfig: `CONFIG_PSA_WANT_ALG_PURE_EDDSA=y`,
  `CONFIG_PSA_WANT_ECC_TWISTED_EDWARDS_255=y` (spike: `cracen_psa_kmu.c:97`, `:771-780`, `cracen_psa_kmu.h:40-63`;
  measured +1,636 B flash).
- Property, stated as the spike found it: the private key cannot be exported through the API and is never written to
  flash or NVS, but it passes through secure RAM when it is created and at every signature (`kmu_push_area`). In the
  single image any code that runs on the earbud can sign with it.
- The KMU slot is fixed in the firmware slot map. It MUST NOT overlap the IKG seed slots 183 to 185, the provisioning
  slot 186, slots 248 and 249, or the contact PSK slots. Phase 0 verifies on the DK that a RAW KMU key survives a
  reboot: the existing ids `0x100`-`0x103` and `0x200+` are probably not KMU keys at all, because
  `CONFIG_MBEDTLS_PSA_CRYPTO_STORAGE_C` is off in this build (spike; runtime not verified).
- EK is generated at the first enrolment (§3.4) and kept until a factory reset (§3.8). It is never rotated otherwise.
- KAT and QEMU builds run the same signing code over a software key imported from the vector seed. That import path
  exists only under a test Kconfig option that the CI configuration check rejects in the CI, bench, authoritative and
  production profiles. The production path (`psa_sign_message` with a KMU handle on CRACEN) gets its own known-answer
  check on the DK: a test image imports the vector seed into a spare KMU slot, signs the messages of the
  `kmuKnownAnswer` section (§13.1) through the KMU handle, compares the signatures byte for byte with the vectors
  (Ed25519 is deterministic), and destroys the key (§13.1, acceptance item 11).
- One test image is exempt from that destruction: the phase-0 DK self-test image (`CONFIG_QA_PHASE0_TESTS`, built
  only on the bench overlay and refused by every other profile, §12.1) keeps its test keys and destroys nothing, so
  that its reboot persistence test can run: the phase-0 EK that it generates in KMU slots 120 and 121 (handle
  `0x7fff3078`), the known-answer keys imported from public vector seeds into slots 124 to 127 (two keys, at 124 and
  126, two slots each), and the persistent PSA keys it creates (ids `0x100` to `0x103`, `0x200` and `0x7000`;
  `docs/PHASE0_DK_RUNBOOK.md` at `86293ad`). Because the imported keys are public and the phase-0 EK belongs to no
  enrolment, `nrfutil device recover` (an ERASEALL, which also erases
  the KMU) MUST be run on that board before any other image is flashed on it; no other image may keep a test key.

EK signs exactly five kinds of message, each with its own domain prefix, and nothing else: the v6 transcripts (domain
`qaudion-handshake-sig-v6`, WIRE_SPEC §3.7), the EPL authentication (§4.3), the EPC proof of possession (§3.3), the
hybrid message `HT` (prefix `qaudion-hs-hybrid-ed25519-v1`, PQC §5.4; from phase 1, §3.9) and, in phase 2, the
cross-certificate XC (§3.9). The earbud builds every signed message itself from the structured inputs of §4.5. It
never signs a byte string the host supplies.

### 3.2 Binding to the account and to the host

- The existing earbud attestation (`POST /api/v1/device/earbud-attest`, TOFU binding of `earbudId` to one account,
  HTTP 409 when the id is bound to another account; server `cmd/bcrypto-lite/main.go:12836-12915`) stays the account
  binding of the hardware.
- The EPC (§3.3) binds EK to the account UUID, to one host device id and to that host's HK. It is signed by HK (the
  certificate) and by EK (the proof of possession).
- `EP_MAX_HOSTS = 4` (owner decision OD-2, 2026-11-17): one earbud may be enrolled by up to 4 host devices of the
  same account, matching `CONFIG_BT_MAX_PAIRED=4` and the 4-entry host table of §10.4. Each host has its own EPC for
  the same EK. An earbud never holds hosts of two accounts. A fifth distinct host key gets `host_table_full` (step 5 of
  §3.4) until the user removes one with `UNENROLL`; a host that is already in the table may re-enrol. `EP_INFO`
  reports `maxHosts = 4` (§8.2).

### 3.3 Endpoint certificate (EPC)

```
EPC  = "qaudion-endpoint-cert-v1"        24 B
       ‖ uuid_raw[16]                    the account UUID, RFC 4122 network byte order (the uuid16 of the Sigsum leaf)
       ‖ LP(hostDeviceId)                exact UTF-8 bytes of the host's server device id, 1..255 B, no normalization
       ‖ hostEdPub[32]                   HK
       ‖ u8(kind)                        0x01 = earbud; every other value is reserved
       ‖ epEdPub[32]                     EK
       ‖ earbudId[32]                    SHA-256(pk_se)
       ‖ BE64(created_ms)                enrolment time chosen by the host, > 0
       ‖ u8(buildProfile)                the earbud's own EP_INFO.buildProfile (§8.2): 0x01 CI, 0x02 bench,
                                         0x03 authoritative, 0x04 production
       ‖ u8(board)                       the earbud's own EP_INFO.board (§8.2)
cert = Ed25519(HK, EPC)                                                 64 B
pop  = Ed25519(EK, "qaudion-endpoint-pop-v1" ‖ SHA-256(EPC))            64 B, prefix 23 B
```

- `hostDeviceId` follows the rules of the XC `deviceId` (PQC §5.2): exact bytes as the server stores them, non-empty,
  at most 255 bytes, valid UTF-8, no surrounding whitespace.
- The earbud computes `SHA-256(EPC)` itself from the enrolment inputs, its own EK, its own `earbudId` and its own
  build profile and board, so `pop` only ever covers an EPC that names this earbud's own keys and the profile it
  runs. `buildProfile` and `board` are asserted by the earbud firmware: they let an honest development unit be shown
  as one (§9.10); they prove nothing about a unit whose firmware lies (no attestation, gap S-3).
- A verifier checks `cert` under `hostEdPub` and `pop` under `epEdPub`, both with the uniform Ed25519 rule. Both keys
  must pass rules 1 and 2 of that rule (canonical, not of small order).

### 3.4 Enrolment

Enrolment runs over the EPL (§4) on a bonded link. The messages are defined in §4.5. Enrolment is the step that
decides which host keys may use the call plane, so it is gated by two physical facts that another app on the same
phone cannot produce: a fresh bond or a pairing-mode window, and a fresh confirm gesture after a host code the user
can hear.

1. The user chooses "Add earbud" in the host app. The host bonds (§9.2), reads `EP_INFO` (§8.2) and opens an EPL
   session (§4.3).
2. An unknown host gets `EP_AUTH` with result `enrol_only`; an enrolled host gets `authenticated` and may re-enrol
   (which replaces its EPC).
3. The host sends `ENROLL_BEGIN` (account UUID, its device id, `created_ms`). Its HK is the key it proved in
   `HOST_AUTH` of this session. The earbud refuses with `not_fresh` unless one of these holds: (a) the BLE bond of
   this connection was created during this connection less than 180 s ago (the SMP pairing that created it already
   needed a press, FW-C2); (b) the user opened pairing mode with a long press less than 180 s ago (§9.14, the path
   for a reinstalled app on a phone whose bond already exists); (c) the session is `AUTHED` (re-enrolment of an
   enrolled host). It refuses with `busy` while a call context exists, while the CCP client reports a cellular call
   ringing or active, or while another confirm window is open. Reason for (a) and (b): an app on a phone that is
   already bonded, which is how "another app on the host phone" reaches the earbud, has neither a fresh bond nor the
   user's long press.
4. The earbud opens a confirm window of 30 s: it answers `ENROLL_PROMPT` with the window length and the enrolment code
   (§4.3, four symbols derived from this session's committed key exchange and `hostEdPub`), plays the code as four
   tones and shows the confirm LED pattern. The host plays the same four tones on the phone and shows them, with the
   text "The earbud plays four notes. If they are the same as these, hold the earbud button for 3 seconds. If not,
   do nothing." Opening the window clears every earlier press timestamp: only a confirm gesture (§9.14) that starts
   after the prompt confirms. While the window is open the button does nothing else (no call answer, no pairing mode,
   no `EVENT BUTTON`, no FW-C2 timestamp). A short press cancels the window (`ENROLL_RESULT` `cancelled`); the end of
   the window without a gesture gives `no_press`.
5. If the earbud has no EK it generates one (§3.1). If it already holds hosts of another account UUID it answers
   `other_account` and changes nothing. If its host table (`EP_MAX_HOSTS = 4` entries, §3.2) is full and this host is
   not in it, `host_table_full`.
6. The earbud builds the EPC, signs `pop` and answers `ENROLL_RESULT` (EK, `earbudId`, `pop`).
7. The host verifies `pop`, signs `cert` with HK and sends `ENROLL_COMMIT`. The earbud verifies `cert` under HK and
   stores the host entry `{hostEdPub, platform, uuid_raw, hostDeviceId, created_ms, cert}` in NVS, then answers
   `ENROLL_DONE`.
8. The host closes the session and opens a new one. That session is mutually authenticated (EK now exists and is
   known to the host), so, given that the enrolment code matched and EK is therefore the earbud's own, every later
   record is sealed under keys no radio attacker of the first pairing can know (§4.3). The host checks there that
   `epEdPub` equals the EK of `ENROLL_RESULT`, reads `HOST_LIST` and shows the enrolled hosts; a host the user does
   not recognise is removed with `UNENROLL` (confirm gesture).
9. The host stores EK, `earbudId` and the endpoint id, and publishes the endpoint record (§3.6). Check 6 of §3.6
   refuses an earbud that was never attested, so before its first publication for an earbud the host runs the
   existing earbud attestation (§3.2: `ATTEST_INFO` and `ATTEST_POP` of WIRE_SPEC §7, then
   `POST /api/v1/device/earbud-attest`) unless it has already attested that `earbudId` for this account. If the
   publication fails on the network or with a 5xx answer it retries in the background. A 4xx answer of §3.6 is shown
   with its code and is never retried automatically: the host publishes the same record again only after the cause
   was removed, that is after a successful attestation for 412 `earbud_not_attested`, and after the user removed an
   endpoint or a host record for 409 `endpoint_limit`; every other 4xx answer is final for that record. Peers accept
   an unlisted endpoint only within the 7-day window of §3.7 step 4 (c), so the host shows "Earbud not yet
   registered" until the publication succeeds.

What the code gives, stated: the four symbols carry 8 bits. They are a function of the session transcript, which
contains the host's commitment made before the earbud revealed its ephemeral key (§4.3), so an attacker between the
phone and the earbud cannot choose its keys to make the two codes equal; it matches by chance with probability 1/256
per attempt, and every attempt needs the user to hold the button after hearing a code. A malicious app that runs an
enrolment while the genuine app is prompting produces a code of its own key, which the genuine app does not play.

### 3.5 The `endpoint` member of handshake bundles

Every OFFER and ACCEPT signed by EK, rekey rounds included, carries one top-level member:

```json
"endpoint": {
  "v": 1,
  "kind": "earbud",
  "hostDeviceId": "<exact host device id>",
  "hostKey": "<canonical base64 of HK, 32 B>",
  "earbudId": "<canonical base64, 32 B>",
  "created": 1794873600000,
  "profile": 4,
  "board": 1,
  "cert": "<canonical base64, 64 B>",
  "pop": "<canonical base64, 64 B>"
}
```

- Valid iff it is a JSON object with exactly these ten members, each once; `v` is the integer 1; `kind` is the
  string `earbud`; the base64 values pass the canonical rule of PQC §2.3 and decode to the stated lengths; `created`
  is a JSON integer in `[1, 2^53 − 1]` and `profile` and `board` JSON integers in `[0, 255]`, all written without
  sign, fraction or exponent; `hostDeviceId` meets §3.3. Anything else, a duplicated `endpoint` member or a duplicate
  member inside it included, makes the member absent. An absent member is never a malformed bundle by itself.
- The member is outside the signed transcript and outside EXTX. It needs no binding: it is self-authenticating
  (`cert`, `pop`), and `epEdPub` is the transcript's `signerIK32`. Stripping it only sends the verifier to the
  R-IDENTITY path (media held pending the SAS), where a bundle that declares `earbudEpV1` never gets its key pinned
  (§3.7, "No valid `endpoint` member").
- Size about 420 bytes of JSON; it is counted in the 24 KiB rule of PQC §5.6. The phase-2 host certificate
  `certPq` (§3.9) is not carried in bundles: it is fetched with the earbud's ML-DSA key, which a bundle never
  carries either (PQC §5.4).

### 3.6 Publication on the server

The endpoint record is a separate store keyed by `(user, hostDeviceId, endpointId)`. It is never written through the
identity bundle publish: `PutBundle` overwrites the bare-UUID "latest" bundle of the user
(`internal/store/identity_bundles.go:174-188`, called at `cmd/bcrypto-lite/users_identity_key.go:279`), so publishing
EK there would change the key every peer uses for the chat safety number and for the single-key fetch.

`endpointId` = lowercase hex of the first 16 bytes of `SHA-256(epEdPub)` (32 characters), derived by the server and
by every client in the same way.

`POST /api/v1/users/me/endpoints` (authenticated; only the host device publishes, check 2 below):

```json
{
  "version": 1,
  "kind": "earbud",
  "host_device_id": "<exact>",
  "host_ed25519_pub_b64": "<32 B>",
  "endpoint_ed25519_pub_b64": "<32 B>",
  "earbud_id_b64": "<32 B>",
  "created_ms": 1794873600000,
  "build_profile": 4,
  "board": 1,
  "ep_cert_sig_b64": "<64 B>",
  "ep_pop_sig_b64": "<64 B>"
}
```

The server runs these checks in order. The first that fails answers with its status and the error body
`{"error":"<code>"}` (the server's existing error shape, `jsonErr`, `cmd/bcrypto-lite/main.go:4771-4775`) and changes
nothing:

1. Strict decoding, 400 `endpoint_body_invalid`. The body is one JSON object, decoded under the strict RFC 8259 rule
   of WIRE_SPEC §3.1 (D27), with exactly the eleven members above, each once. Member names are compared byte for byte
   with those names, so an unknown member, a duplicate member name and a name that differs from one of them only in
   case are all refused (a case-insensitive decoder, such as Go's `encoding/json` used alone, does not meet this
   rule). `version` is the integer 1 and `kind` the string `earbud`; `host_device_id` meets §3.3; the base64 values
   pass the canonical rule of PQC §2.3 and decode to the stated lengths; `created_ms` is an integer in
   `[1, 2^53 − 1]` and `build_profile` and `board` integers in `[0, 255]`, written without sign, fraction or exponent.
2. Caller, 403. The authenticated device (the device of the bearer token) MUST NOT be revoked, `device_revoked` (the
   authentication layer may refuse such a request earlier, as it refuses every request of a revoked device), and MUST
   be `host_device_id`, `endpoint_host_mismatch`.
3. Host key, 409 `endpoint_host_key_mismatch`: the stored per-device identity bundle of `host_device_id` has
   `ed25519_pub` equal to `host_ed25519_pub_b64`.
4. Keys, 400 `endpoint_key_invalid`: both keys pass rules 1 and 2 of the uniform Ed25519 rule.
5. Signatures, 400 `endpoint_sig_invalid`: the server rebuilds the EPC from the body and the account UUID and verifies
   `cert` under the host key and `pop` under EK (uniform Ed25519 rule).
6. Earbud: 412 `earbud_not_attested` when `earbud_id_b64` was never attested; 409 `earbud_other_account` when
   `earbud-attest` bound it to another account.
7. Revoked key, 410 `endpoint_revoked`: EK has a tombstone in any account, this one or another, or its SHA-256 is in
   the set of revoked keys that account deletion keeps (below).
8. Key of another account, 409 `endpoint_key_taken`: EK has a live record (below) in another account. A tombstone of
   another account is refused by check 7 already.
9. Limits (owner decision OD-2), 409 `endpoint_limit`: the registration would leave more than
   `EP_MAX_ENDPOINTS_PER_USER = 4` endpoints with a live record, or more than `EP_MAX_HOSTS = 4` live records for this
   endpoint (one per host device, §3.2), so one earbud enrolled by four phones uses one endpoint of the budget.
10. Tombstone cap, 409 `endpoint_tombstone_limit`: the account holds `EP_MAX_TOMBSTONES_PER_USER = 32` tombstones or
    more and the registration would add a live record (a `(hostDeviceId, endpointId)` that has none); a registration
    that replaces an existing live record is not refused by this check.

A live record is a record that is neither revoked nor removed (both below) and whose host device is neither revoked
nor deleted. The limits count live records only: an endpoint counts toward `EP_MAX_ENDPOINTS_PER_USER` while it has a
live record, tombstones count against neither limit, and a record for an existing `(hostDeviceId, endpointId)`
replaces it and is never counted twice. The per-user budget of live records is therefore at most 4 × 4 = 16, and one
host device holds at most one live record per endpoint, so at most 4: the `endpoints` member of one device (below) has
at most 4 live entries and the `?all=1` shape at most 16 live entries in all. A new record for the same
`(hostDeviceId, earbudId)` with a different EK revokes the previous one (re-enrolment after a reset). On success the
server stores the validated fields, never the request text, and answers 200 with `{"endpoint_id": "<id>"}`; every list
entry it serves later is its own serialization of the stored fields. Each accepted record queues a Sigsum leaf
`SHA-256("qaudion-kt-endpoint-v1\x20" ‖ uuid16 ‖ hostEdPub[32] ‖ epEdPub[32] ‖ be64(created_ms))`, through the same
worker as the identity leaves; a submission failure never affects the publish.

Revocation. `DELETE /api/v1/users/me/endpoints/{endpointId}` from any non-revoked device of the account
(403 `device_revoked` otherwise) revokes every record of that endpoint and answers 204; 404 `endpoint_not_found` when
the account has no record of it; an endpoint that is already revoked answers 204 and nothing changes. Revocation is
never refused because of a limit or of the tombstone cap. It is permanent: each record becomes a tombstone
`{endpoint_id, endpoint_ed25519_pub_b64, host_ed25519_pub_b64, created_ms, revoked_ms}` that is listed for ever (about
150 bytes each; it is never deleted, so a revoked key can never become valid again by the certificate alone), and the
same EK can never be registered again, by this account or by any other (check 7). Check 10 stops new live records
once the account holds 32 tombstones; revocation stays open, so the tombstones of the records still live at that
point can be added beyond 32.

Per-host removal, for a lost or replaced host phone.
`DELETE /api/v1/users/me/endpoints/{endpointId}/hosts/{hostDeviceId}` (`hostDeviceId` as one RFC 3986 path segment,
percent-encoded from its exact UTF-8 bytes) from any non-revoked device of the account (403 `device_revoked`
otherwise) removes the live record of that host device for that endpoint WITHOUT a
tombstone and answers 204: EK stays valid for the other hosts and may be registered again by a host device, the
removed one included. 410 `endpoint_revoked` when the account holds a tombstone of that endpoint, checked first, so a
revoked endpoint answers 410 whatever the host device named (a tombstone is never removed); otherwise 404
`endpoint_not_found` when no live record of that pair exists. The records of a host device that is revoked or deleted
are treated the same way: they are not counted toward `EP_MAX_HOSTS` and are never listed to peers as live
entries; a revoked device that is restored later does not bring them back, its host publishes again. A tombstone is
never hidden: the tombstones of such a host device stay listed like every other tombstone (below) wherever that
device's payload is served. Afterwards the `endpoints` list of that host
device no longer contains K, so step 4 (c) of R-EP-VERIFY (§3.7) applies to the bundles that host signs with K: they
fail as unlisted (`identity_unresolved`, `ep=unlisted_stale`, media held pending the SAS) at every peer that had
pinned the endpoint, and at every other peer once `created` is more than 7 days old; inside those 7 days a peer that
never pinned the endpoint accepts it as `ep=unlisted`, the publication-lag window that any holder of HK can use in any
case (§1.4). Removing a record does not stop the host device itself from publishing it again: against a lost phone the
user also revokes that device, after which check 2 refuses its publications. The earbud still holds the host's entry:
the earbud's owner removes it with `UNENROLL` from another enrolled host (confirm gesture, §3.8, §4.5); until then that
host, if it still holds HK and reaches the earbud, can open an EPL session.

Account deletion, erasure rule. When an account is deleted the server first revokes every endpoint of the account that
has a live record, then erases every endpoint record, certificate, proof of possession and tombstone of the account.
Of the whole endpoint store of the account it keeps only the SHA-256 of each revoked EK: 32 bytes each, stored with no
account identifier, host key, device id, time or any other field, in a set that is never deleted. Check 7 refuses an
EK whose SHA-256 is in that set, so a revoked EK can never be registered again by any account. Leaves already
submitted to the Sigsum log are outside the server's store and are not affected.

Fetch: the payload of a device bundle (`bundlePayload`, `users_identity_key.go:390-420`) gains the member `endpoints`
only when that device has live endpoint records or tombstones, in all three fetch shapes (default, `?device_id=`,
`?all=1`). Old clients ignore it and every other payload stays byte-identical:

```json
"endpoints": [ {
  "endpoint_id": "<32 hex>", "kind": "earbud",
  "endpoint_ed25519_pub_b64": "...", "host_ed25519_pub_b64": "...", "earbud_id_b64": "...",
  "created_ms": 1794873600000, "build_profile": 4, "board": 1,
  "ep_cert_sig_b64": "...", "ep_pop_sig_b64": "...", "revoked_ms": 0
} ]
```

A tombstone appears in the same list with `revoked_ms > 0` and without the certificate members. The list is sent
complete (no paging); with the limits and the tombstone cap above it stays small. Phase 2 adds the ML-DSA members of
§3.9 to an entry. EK is never part of the device key set returned by `?all=1`: a peer that only knows the device set
must not take EK for a device key (iOS would re-pin to it, `HandshakeSigningPolicy.swift:42`, `:199`).

The phase-2 publication `POST /api/v1/users/me/endpoints/{endpointId}/mldsa` (§3.9) follows the same rules: strict
decoding of its body (check 1, with the seven members of §3.9), a caller that is not revoked and is the host device of a
live record of that endpoint (403 `device_revoked`, `endpoint_host_mismatch`), and the error body above.

Operational requirements of the server:

- The DR export and the failover export carry the per-device identity bundles (bucket
  `user_identity_bundles_by_device_v2`, `internal/store/bbolt.go:184`), the endpoint records, the tombstones, the set
  of revoked-key hashes and the device revocation records that the per-host rule above reads (`revoked_keys`, `:78`).
  At `c1790e7` `drExportBuckets` (`internal/store/bbolt.go:4629-4641`), which `failoverExportBuckets` extends
  (`:4650-4670`), carries `user_identity_bundles_v2` but neither of those two buckets. Without the per-device bundles a
  failover node finds no record for `?device_id=`, falls through to the user's latest bundle
  (`users_identity_key.go:452-454`, `:476-485`) and so serves the latest device's endpoints for every device id.
- The primary MUST NOT be rolled back below the first server binary that stores endpoint records, and the deployment
  procedure MUST refuse such a rollback: an older binary does not know the endpoint stores, its exporter drops them,
  and a failover node fed by that export lists no endpoint, so peers read a revoked endpoint as unlisted (accepted
  while young, §3.7 step 4 (c)) instead of revoked.

### 3.7 Verification by the remote peer (R-EP-VERIFY)

For a received bundle whose `signerIdentityKey` is `K`, every client (Android, iOS, Desktop, web app) runs, in place of
the final R-IDENTITY step of its identity resolution:

1. Existing resolution first (pin, per-device fetch with the envelope's `sender_device_id`, published set: Android
   `HandshakeSigner.kt:257-330`, iOS `HandshakeSigningPolicy.swift:111-200`). If `K` resolves there, nothing below
   applies.
2. Otherwise, if the bundle carries a valid `endpoint` member (§3.5): rebuild the EPC with `uuid_raw` of the call's
   peer user (from the call context, never from the bundle), `hostDeviceId`, `hostKey`, `kind = 0x01`,
   `epEdPub = K`, `earbudId`, `created`, `profile` and `board`. Verify `pop` under `K` and `cert` under `hostKey`
   (uniform Ed25519 rule). The envelope that carried the bundle MUST carry `sender_device_id`, and it MUST equal
   `hostDeviceId` byte for byte (WIRE_SPEC §3.7.3; the server stamps the field on every live and replayed
   `opaque_message`, WIRE_SPEC §3.7.4 R-COMMIT-KCMAC-DEVICE): an envelope without the field or with another value fails
   this step. Any failure: verdict `identity_key_mismatch` (media held pending the SAS, WIRE_SPEC §3.8.6), log
   `ep=cert_invalid`.
3. Resolve `hostKey` as the peer's device key for `hostDeviceId` with the existing resolver (observed key `hostKey`).
   If that resolution is `Unauthenticated` or `Unresolved`, the verdict is the one the resolver gives for `hostKey`
   (`identity_key_mismatch` or `identity_unresolved`), log `ep=host_mismatch` or `ep=host_unresolved`. A deleted host
   device no longer resolves, which also ends its endpoints.
4. Server listing, from the fetch of the host device's record that the client makes for the call (a callee during
   ringing, a caller when it starts the call, as for identity keys):
   - (a) the list has a tombstone for `K` (`revoked_ms > 0`): verdict `identity_key_mismatch`, log `ep=revoked`,
     warning "This earbud was removed by its owner."; an endpoint pin of `K` is deleted.
   - (b) the list has `K` and it is not revoked: accepted, log `ep=listed`.
   - (c) the fetch succeeded and `K` is not in the list: accepted only while the endpoint is young, i.e. `created` is
     at most `EP_UNLISTED_GRACE = 7` days before the verifier's clock and at most 1 day after it (publication lag, a
     retrying host), log `ep=unlisted`. Outside that window: verdict `identity_unresolved` (media held pending the
     SAS), log `ep=unlisted_stale`. An endpoint that this client had pinned and that the successful fetch no longer
     lists was listed before (step 6 pins only listed endpoints) and was then removed by its owner (§3.6): verdict
     `identity_unresolved`, log `ep=unlisted_stale`, whatever its age, and its endpoint pin is deleted.
   - (d) the fetch failed (offline, server error): an endpoint pinned earlier for `(peer user id, hostDeviceId,
     hostKey, K)` is accepted, log `ep=pinned_offline`; an endpoint not pinned gets `identity_unresolved` (media held
     pending the SAS), log `ep=unverified_offline`. The client re-checks the pin at its next successful fetch.
   Tombstones are permanent (§3.6) and the young-endpoint window is short, so a revoked endpoint never becomes valid
   again by its certificate alone.
5. Post-quantum rule (R-EP-PQ, §3.9). The PQ pin record that governs an endpoint call is the record of
   `(peer user id, hostKey)` of PQC §2.5, the same record that the contact's phone calls use. It is never a fresh
   record keyed by `K`. The PQC §5.5 table is applied to that record with the endpoint resolution of §3.9: a bundle
   whose `sigHybrid` does not verify under the host's ML-DSA key (phase 1) or under an earbud ML-DSA key certified by
   the host's ML-DSA key (phase 2) is, toward a pinned host, the PQC §5.5 anomaly (visible warning, `auth=C`, never
   an end of call), and the endpoint is not pinned by such a call. The log tokens are `ep_pq=` and `pq_sig=` of §11.2.
6. The verdict is `authenticated endpoint`: `sigV6` is verified under `K` over the rebuilt transcript, after steps 2 to
   5, and the rest of the call policy runs unchanged with `K` as the signer key, except that every capability and PQ
   pin lookup uses the host's record of step 5. A `sigV6` that does not verify gives `sig_invalid` (media held pending
   the SAS, WIRE_SPEC §3.8.6) and pins nothing. The client records an endpoint pin `(peer user id, hostDeviceId,
   hostKey, K)` only when step 4 gave `ep=listed`, step 5 gave no anomaly and `sigV6` verified: an endpoint accepted
   as `ep=unlisted` or `ep=pinned_offline` is not pinned anew. The device pin of `hostDeviceId` stays the pin of
   `hostKey`: EK never replaces it and is never pinned as a device key, so the chat safety number and the phone calls
   of the same contact are not affected.
7. A SAS confirmed in a call whose verdict is `authenticated endpoint` with `ep=listed`, no step-5 anomaly and a valid
   `sigV6` pins `K` as endpoint of `hostKey` and confirms `hostKey` for `hostDeviceId`. In every other case a confirmed
   SAS releases the media hold of that call, if there is one (WIRE_SPEC §3.8.6), and pins nothing (table below). The
   pop makes the pin sound against a third party: an adversary who certified a genuine EK with a key of its own would
   need EK's signature over an EPC that names its key, and the earbud signs a pop only at an enrolment confirmed with
   the confirm gesture (§3.4). It gives nothing against the contact's own host, which can mint a software EK (§1.4).
8. A later bundle with an endpoint key different from the pinned one for the same `hostKey` is not an identity change
   of the contact: a new EK with a valid certificate by an authenticated host, accepted by step 4 and without an
   anomaly in step 5, is a new or replaced earbud, shown as a neutral notice ("<contact> now uses a new Q-Audion
   earbud"), never as the identity-change warning; it is pinned only by the rules of steps 6 and 7. With an anomaly in
   step 5 the anomaly's warning is shown instead and the new key is not pinned (the "rogue EK under a pinned host"
   vectors of §13.1).

No valid `endpoint` member. When step 1 does not resolve `K` and the bundle carries no valid `endpoint` member
(absent, invalid, or counted as absent by §3.5), steps 2 to 8 do not run: the bundle gets the verdict of the client's
existing R-IDENTITY step for `K`, `identity_key_mismatch` when the existing resolution says `Unauthenticated` for `K`
and `identity_unresolved` when it says `Unresolved`, media held pending the SAS in both cases. When the bundle's
`capabilities` carry `earbudEpV1` (every earbud bundle carries the member, §2.3) the log is `ep=absent` and a SAS
confirmed in that call releases its hold and pins nothing: `K` is never pinned as a device key. A bundle without
`earbudEpV1` is an ordinary unknown key, judged by the existing rules.

Pin actions. The first step that fails gives the verdict; the device pin of `hostDeviceId` is changed by no row except
the confirmation of `hostKey` in the `ep=listed` row, and `K` is never pinned as a device key in any row.

| Outcome | Verdict | `ep=` | Endpoint pin of `K` | A SAS confirmed in the call |
|---|---|---|---|---|
| step 1 resolves `K` | existing resolution | none | not touched | the existing rule |
| no valid `endpoint` member | R-IDENTITY verdict for `K` | `absent` with `earbudEpV1`, else none | not touched | with `earbudEpV1`: releases the hold, pins nothing; without: the existing rule |
| step 2 fails (certificate, pop, `sender_device_id`) | `identity_key_mismatch` | `cert_invalid` | not touched | releases the hold, pins nothing |
| step 3 fails | `identity_key_mismatch` or `identity_unresolved` | `host_mismatch` or `host_unresolved` | not touched | releases the hold, pins nothing |
| 4 (a) tombstone | `identity_key_mismatch` | `revoked` | deleted | releases the hold, pins nothing |
| 4 (b) listed, no step-5 anomaly, `sigV6` valid | `authenticated endpoint` | `listed` | recorded | pins `K` as endpoint of `hostKey` and confirms `hostKey` for `hostDeviceId` (step 7) |
| 4 (b) listed, step-5 anomaly, `sigV6` valid | `authenticated endpoint` with the PQC §5.5 warning, `auth=C` | `listed` | not recorded; an existing one is kept | pins nothing for the endpoint; the record `(peer user id, hostKey)` changes only as PQC §5.5 says for a SAS confirmed from the warning |
| 4 (c) young, never pinned, `sigV6` valid | `authenticated endpoint` | `unlisted` | not recorded | pins nothing |
| 4 (c) stale, or pinned and no longer listed | `identity_unresolved` | `unlisted_stale` | deleted | releases the hold, pins nothing |
| 4 (d) pinned, fetch failed, `sigV6` valid | `authenticated endpoint` | `pinned_offline` | kept, re-checked at the next successful fetch | pins nothing new |
| 4 (d) not pinned, fetch failed | `identity_unresolved` | `unverified_offline` | not recorded | releases the hold, pins nothing |
| steps 2 to 5 pass, `sigV6` invalid | `sig_invalid` | the token of step 4 | not recorded; an existing one is kept | releases the hold, pins nothing |

An endpoint that a call did not pin is verified again from step 1 at the next call: nothing of that call is
remembered for the endpoint except the deletions in the table, and the PQ record follows PQC §5.5.

A client that predates this section sees an unknown signer key and holds media pending the SAS (R-IDENTITY) on every
EP call. That is safe and degrades every call, so the release gate of §8.6 applies.

UI on the remote peer: the call screen shows "Audio endpoint: <contact>'s Q-Audion earbud (reported by their device)"
next to the usual safety-code control, with "development unit" when `profile` is not `0x04` production; the contact
screen lists the endpoint (kind, date, profile, the first 16 hex characters of `SHA-256(EK)` in groups of four). No
string of the peer UI says the earbud "protects" anything until endpoint attestation exists (§3.10). The SAS words are
those of WIRE_SPEC §4, computed by the earbud on the other side.

### 3.8 Revocation, replacement, reset and lost devices

- Lost or replaced earbud: the user removes it in the host app (DELETE, §3.6) or from any other device of the account.
  The revocation is a permanent tombstone, so the lost unit's EK stays refused by every peer that fetches (§3.7 step
  4). The host also sends `UNENROLL` if the earbud is reachable.
- Lost or replaced host phone: from another device of the account the user removes that host's records with the
  per-host route of §3.6 (no tombstone: EK stays valid for the other hosts) and, for a lost phone, revokes the device,
  which also hides its records and stops it from publishing them again (§3.6). Peers then see that host's calls with
  the endpoint as unlisted (§3.6, §3.7 step 4 (c)). The earbud still holds the host's entry; another enrolled host
  removes it with `UNENROLL` naming that host key, which needs the confirm gesture (§4.5, §9.14), and until then a
  lost phone that holds HK and reaches the earbud can still open an EPL session. The earbud settings of every enrolled
  host list the enrolled hosts (`HOST_LIST`).
- Replacement earbud: a new enrolment, a new EK, a new record. Peers see a new endpoint of an authenticated host
  (§3.7 step 8).
- Factory reset: a physical gesture defined by the firmware (proposed: hold the button for 10 s while powering on,
  §9.14) destroys EK (`psa_destroy_key`), the host table, the hw_only PSKs, the bonds and every call state in NVS. An ERASEALL of a bench unit (APPROTECT recovery) has the same effect. The next enrolment
  generates a new EK, and the server revokes the old record when the new one arrives (§3.6).
- Host reinstall (new HK): the earbud answers `enrol_only`; the bond of the phone still exists, so the host app asks
  the user to open pairing mode with a long press (§3.4 step 3 (b)) and then confirm with the confirm gesture. The
  new record supersedes the old one, and the old HK entry is removed from the earbud with `UNENROLL`.
- A thief who resets a stolen earbud gets a new EK; the owner's EK is gone with the reset.

### 3.9 Post-quantum authentication: host-anchored in phase 1, earbud ML-DSA-87 in phase 2 (R-EP-PQ)

The problem this section solves: PQC §2.5 and §5.5 key every PQ pin record by `(peer user id, signerIdentityKey)`. In
an endpoint call the signer key is EK, which is certified by HK with Ed25519 only (§3.3). If the PQ record of an
endpoint call were keyed by EK, an adversary able to forge HK's Ed25519 signature (the quantum adversary PQC §5
exists for) could mint a new EK' with a valid EPC, get a fresh empty record, and pass as a classical call with no
warning toward a contact who has pinned the host's ML-DSA key. Two rules prevent that: the governing record is the
host's (§3.7 step 5), and the ML-DSA half of the signature is always anchored in the host device's ML-DSA key.

Phase 1, host-anchored hybrid signature:

- The earbud's bundles carry `sigHybridV1` in CAPSX exactly when the host device has a published ML-DSA key
  (PQC §5.3); the host decides and puts the tag into `CAPSX_own`. `mldsaKeyId` of the bundle is `SHA-256` of the
  HOST device's ML-DSA public key, supplied by the host as `hybKeyId` (§4.5).
- `HT` is the message of PQC §5.4 with `edPub` = EK and `mldsaKeyId` = the host's key id; `T`, the fingerprints,
  `CAPSX` and `EXTX` are those of the earbud's bundle, and EXTX is computed with the same `mldsaKeyId`.
- `sigEd = Ed25519(EK, "qaudion-hs-hybrid-ed25519-v1" ‖ HT)` is made by the earbud, which builds `HT` itself and
  returns `SHA-256(HT)` with `sigEd`. `sigPq = ML-DSA-87.Sign(sk_host, HT, ctx = "qaudion-handshake-sig-v7")`, hedged,
  is made by the host over the `HT` it builds from the same inputs (`SHA-256(T)` is the `offerBinding` or
  `acceptBinding` the earbud returned); the host MUST compare its `SHA-256(HT)` with the earbud's before it signs and
  treats a difference as a failure of the request (§5.11). `sigHybrid = sigEd ‖ sigPq` as PQC §5.4.
- Verification, amending step 2 of PQC §5.5 for a bundle whose `endpoint` member passed §3.7 steps 2 to 4: the
  ML-DSA public key is the key of the HOST device, i.e. the pinned key of the record `(peer user id, hostKey)`, else
  the fetched identity bundle of `hostDeviceId` whose cross-certificate verifies against `hostKey` and whose
  `SHA-256(mldsaPub) = mldsaKeyId`. Step 3 verifies `sigEd` with `signerIdentityKey` (EK) and `sigPq` with that key.
  The table of PQC §5.5 then runs, unchanged, on the record `(peer user id, hostKey)`.
- What it means: the round's post-quantum authentication is the host device's. That is the trust Option A already
  places in the host at call setup (§1.4), so it adds no new trust. It closes the downgrade: an EK' minted with a
  forged Ed25519 HK signature has no valid `sigPq` under the host's ML-DSA key, so toward a contact who pinned the host
  the call gets the visible PQC §5.5 warning and `auth=C`, and EK' is not pinned (§3.7 step 6).
- A host without a published ML-DSA key: no `sigHybridV1`, `auth=C`, exactly as its own phone calls; no record holds a
  key id for that host, so there is no anomaly.
- Cost on the earbud: one more Ed25519 signature per bundle (`HT` is 200 to 300 B plus CAPSX, about 0.31 M
  instructions, spike). No ML-DSA code in the firmware.

Phase 2, the earbud's own ML-DSA-87 key (owner decision 1):

- Seed. The earbud generates `ξ` (32 B) from the CRACEN TRNG at the first phase-2 boot after enrolment, and stores it
  only wrapped with AES-256-GCM under a KMU AES key (PROTECTED scheme, non-exportable). It expands `ξ` with
  `ocrypto_ml_dsa87_key_pair` at each signature (3.5 M instructions, spike).
- Deviation from PQC §5.1, stated: §5.1 derives `ξ` from the Ed25519 seed. EK is a KMU SIGN-only key whose seed never
  leaves the KMU, so that derivation is impossible. Verifiers never re-derive `ξ`: they check the cross-certificate
  (PQC §5.2), which binds the two keys in both directions. The `mldsaSeed` vectors therefore do not apply to the
  earbud. The rotation rule is kept: the earbud's ML-DSA key changes only when EK changes, `gen` is 0.
- XC as PQC §5.2 with `deviceId` = `endpointId` (§3.6), `edPub` = EK, `xcEd` by EK and `xcPq` by the earbud's ML-DSA
  key (context `qaudion-identity-xcert-v1`, hedged).
- Host certificate over the earbud's ML-DSA key, made by the host device's ML-DSA key:
  `certPq = ML-DSA-87.Sign(sk_host, SHA-256(EPC) ‖ epMldsaKeyId[32], ctx = "qaudion-endpoint-cert-pq-v1")`, hedged,
  with `epMldsaKeyId = SHA-256(epMldsaPub)`. It binds the earbud's PQ key to the host's PQ identity directly, so the
  Ed25519-only `cert` is never the only link between EK and the host for a PQ verdict.
- Publication: `POST /api/v1/users/me/endpoints/{endpointId}/mldsa` from the host with `mldsa_pub_b64`,
  `mldsa_xc_created_ms`, `mldsa_xc_ed_sig_b64`, `mldsa_xc_pq_sig_b64`, `mldsa_gen` (0), `host_mldsa_key_id_b64` and
  `ep_cert_pq_sig_b64`, under the field rules of PQC §5.3. The server verifies XC and `certPq` under the host
  device's published ML-DSA key (412 if the host device has none). The entry of §3.6 then carries the same members
  plus `mldsa_key_id_b64`.
- Bundles: `mldsaKeyId` = `epMldsaKeyId`; the earbud signs both halves of `sigHybrid`.
- Verification: the earbud's ML-DSA key is resolved from the `endpoints` entry whose `endpoint_ed25519_pub_b64` equals
  `signerIdentityKey` and whose key id equals `mldsaKeyId`; the verifier checks XC against EK, `certPq` under the
  host's ML-DSA key (the key pinned in `(peer user id, hostKey)`, else the fetched one whose XC verifies against
  `hostKey`), then `sigHybrid`. All valid: `auth=H`, and the record `(peer user id, hostKey)` is judged as if the
  bundle carried the host's pinned key id (a certified earbud key id is not an "other key" of the host); the earbud
  key id is stored with the endpoint pin, and a later bundle of that endpoint under another earbud key id is the
  other-key anomaly. `certPq` missing, invalid or not under the pinned host key: the bundle is judged as `unavailable`
  against the host's record (toward a pinned host: the warning, `auth=C`).
- A phase-2 earbud brought back to phase-1 firmware signs host-anchored again; the round stays `auth=H` under the host
  record and the verifier logs `ep_pq=host`. MCUboot's downgrade prevention and the host rule of §8.3 keep that from
  happening in the field.
- The earbud signs `HT` over the EXTX it computes itself from the raw `relayKem` bytes the host supplies (§4.5), with
  an empty `capsWithdrawn`, so a host cannot make the earbud sign a withdrawal marker.
- Marginal value, stated: once the host co-signs in phase 1, phase 2 adds only that the PQ half no longer rests on the
  host's ML-DSA key. A leaked host ML-DSA key (passive compromise of the phone) together with a quantum forgery of EK
  could impersonate the earbud endpoint in phase 1 and cannot in phase 2; the same attacker can still impersonate the
  host's phone endpoint in both. Phase 2 stays because owner decision 1 asks for it; its cost is in §12.

### 3.10 What the endpoint label proves

The endpoint member, the certificate and the server record prove that the contact's host device certified EK and
that EK signed the pop and the call. They do not prove that EK lives in an earbud: a host can generate a software key
and certify it, and `earbudId` is a public value (it is readable from `EP_INFO`). Until endpoint attestation exists
(gap S-3, phase 3) every UI that mentions the endpoint says it is reported by the contact's device, never that the
call or the audio is "protected" by the earbud (§3.7, §9.9, §9.10). `buildProfile` lets an honest development unit
be labelled as one.

---

## 4. Endpoint link (EPL)

### 4.1 Transport

- The EPL is one L2CAP LE credit-based connection-oriented channel on PSM `0x00B5`, the earbud being the server,
  registered exactly by the images that expose `EP_INFO` (§8.1, §10.1). The AudioLink channel on PSM `0x00B3` (148 B
  sealed frames, `audio_link_channel.c`) is retired with PROTOCOL_VERSION `0x02` in every firmware profile (§8.4);
  `0x00B4` (dev clear audio) and `0x00B2` (DoV) are not part of an EP build.
- The earbud keeps one EPL channel per connection. A second channel on a connection whose channel is `AUTHED` or
  `ENROL_ONLY` is refused; a second channel on a connection whose only channel is still `UNAUTH` replaces it (the old
  one is closed), so an app that opens the channel and never authenticates cannot block the host (§4.3 timeouts).
- At accept the earbud requires the connection's security level to be `BT_SECURITY_L4` (LESC), as the AudioLink
  server does today. That is defence in depth only: the earbud has no display and confirms numeric comparison with a
  button press (`ble_gap.c:667-700`), so the user never compares the number and the bond gives confidentiality
  against passive observers, not authentication against an active attacker at the first pairing. Every security
  property of the EPL comes from its own session protocol (§4.3).
- The channel is a reliable byte stream. Records (§4.2) may span L2CAP SDUs and an SDU may carry several records; SDU
  boundaries carry no meaning. This is required because iOS exposes a `CBL2CAPChannel` as a pair of streams, and the
  firmware's current rule that one SDU is one frame must go.
- Earbud receive MTU at least 498 bytes and at least 8 receive credits (the existing `AL_RX_CREDITS = 8`).
- The host opens the channel after bonding and after the version checks of §8, and SHOULD keep it open while the
  earbud is connected, so that a call does not wait for a channel open. Closing the channel during a call starts the
  link grace of §5.10.
- Link parameters for every EP firmware profile: LE Data Length 251 (`CONFIG_BT_CTLR_DATA_LENGTH_MAX=251`,
  `CONFIG_BT_BUF_ACL_TX_SIZE=251`; the CI and bench profiles have 27 today, spike), 2M PHY preferred. Connection
  interval: the earbud requests 15 to 30 ms for an iOS host and 7.5 to 15 ms for an Android host (it learns the
  platform from `HOST_HELLO`); the 7.5 ms interval that `audio_link_channel.c` forces today is not accepted by iOS.
  The iOS range follows Apple's accessory guideline as commonly cited (minimum at least 15 ms, maximum at least the
  minimum plus 15 ms); that rule is external to this repository and phase 0 checks it by measuring the interval iOS
  actually grants. Every buffer and the latency figures of §5.6 and §7.5 are sized for a 30 ms interval.

### 4.2 Record framing

```
record = BE16(len) ‖ u8(type) ‖ u8(flags) ‖ body        len = 2 + len(body), 2 ≤ len ≤ 4094
```

- A record is therefore at most 4096 bytes. After `EP_AUTH` every record is sealed (§4.3): `body` is then the
  ciphertext and its 16-byte tag, so a sealed record carries at most 4,076 bytes of plaintext. `flags` bit 0 is MORE;
  bits 1 to 7 are zero (a record with a reserved bit set is dropped and answered with ERROR `malformed`).
- A message is the concatenation of the bodies of consecutive records of one `type`, up to and including the first
  record of that type whose MORE bit is clear. Records of different types may interleave (audio records travel
  between the records of a large handshake message). A receiver keeps at most one partial message per type. A message
  longer than the maximum of its type (§4.5) is discarded and answered with ERROR `malformed`.
- A record of an unknown type is skipped by its length and answered once per type with ERROR `unknown_type`.
- `len` below 2 or above 4094 means the stream is out of sync: the receiver closes the channel.
- Audio records (`AUDIO_IN`, `AUDIO_OUT`) are single-record messages; their MORE bit is always clear.
- Sender scheduling (both sides). While a call context carries audio, a sender splits every other message into
  records of at most 512 bytes of plaintext and, at each record boundary, the boundary before the first record of a
  message included, sends every audio record queued at that moment before the next record of another type. A
  512-byte record holds the link for about 4 ms at 2M PHY with DLE 251, well under the
  20 ms frame period and the earbud's 40 ms minimum jitter target (§7.5). Outside a call records may use the full
  size.
- A receiver MAY parse a message as its records arrive and store each field in its destination buffer instead of
  reassembling the whole message; the firmware does so for the messages above 4 KB (§12.3).

### 4.3 Session start and host authentication

Every channel open starts a session: a committed, authenticated X25519 exchange, after which every record in both
directions is sealed. The BLE bond is not relied on for the integrity or the confidentiality of any record (§4.1).

```
H→E HOST_HELLO = BE16(hostProto) ‖ u8(platform) ‖ commitH[32]
E→H EP_HELLO   = LP(EP_INFO) ‖ nonceE[32] ‖ xE[32]
H→E HOST_AUTH  = hostEdPub[32] ‖ nonceH[32] ‖ xH[32] ‖ sigH[64]
E→H EP_AUTH    = u8(result) ‖ epEdPub[32] ‖ sigE[64]

commitH = SHA-256("qaudion-epl-commit-v1" ‖ hostEdPub[32] ‖ nonceH[32] ‖ xH[32])
AUTH_H  = "qaudion-epl-auth-host-v2"             24 B
          ‖ earbudId[32] ‖ nonceE[32] ‖ nonceH[32] ‖ xE[32] ‖ xH[32] ‖ hostEdPub[32] ‖ u8(platform)
sigH    = Ed25519(HK, AUTH_H)
AUTH_E  = "qaudion-epl-auth-ep-v2"               22 B
          ‖ earbudId[32] ‖ nonceE[32] ‖ nonceH[32] ‖ xE[32] ‖ xH[32] ‖ hostEdPub[32] ‖ epEdPub[32]
sigE    = Ed25519(EK, AUTH_E)

ss      = X25519(eE, xH) = X25519(eH, xE)                 an all-zero ss closes the channel
th      = SHA-256(AUTH_E)
PRK     = HKDF-Extract(salt = "qaudion-epl-salt-v1", IKM = ss)
kH2E    = HKDF-Expand(PRK, "qaudion-epl-h2e-v1" ‖ th, 32)
kE2H    = HKDF-Expand(PRK, "qaudion-epl-e2h-v1" ‖ th, 32)
enrolCode = SHA-256("qaudion-epl-enrol-code-v1" ‖ th)[0]   four 2-bit symbols, most significant first
```

- `hostProto` is `0x0002`. `platform` is `0x01` Android or `0x02` iOS. The earbud checks both when `HOST_HELLO`
  arrives: any other `hostProto` (`0x0001` included) and any other `platform` value is refused with `EP_AUTH` result
  `0x03`, sent in place of `EP_HELLO` and carrying 96 zero bytes for `epEdPub ‖ sigE`, after which the earbud closes
  the channel. `nonceE`, `nonceH` and the X25519 scalars `eE`, `eH` (public keys `xE`, `xH`) are fresh CSPRNG values
  per session and are erased when the session closes (forward secrecy of the link).
- The host sends `HOST_HELLO` first, committing to `hostEdPub`, `nonceH` and `xH` before it sees `xE`. The earbud
  checks `commitH` when `HOST_AUTH` reveals them, then `sigH`; a mismatch is `result` `0x02`. The commitment is what
  makes the enrolment code of §3.4 resist an attacker in the middle: neither side's ephemeral can be chosen after
  seeing the other's.
- `result`: `0x00` authenticated (`hostEdPub` is an enrolled host and `sigH` verifies), `0x01` enrol only (the
  signature verifies but the host is not enrolled), `0x02` bad signature or bad commitment, `0x03` protocol version or
  platform not supported. `epEdPub ‖ sigE` are EK and its signature over `AUTH_E` exactly when `result` is `0x00`, or
  `0x01` and the earbud holds EK. In every other case they are 96 zero bytes, in particular in every refusing
  `EP_AUTH` (`0x02`, `0x03`) whatever the earbud holds: a refusing `EP_AUTH` carries neither EK nor a signature, and
  the earbud signs nothing for a host whose commitment and `sigH` it has not verified. That rule is about `EP_AUTH`
  only. EK is a public key: the `EP_INFO` record carries it (`epEdPub`, §8.2) unchanged in `EP_HELLO` and in the
  characteristic `0xd0`, both of which the earbud serves before it has authenticated the host, so a host refused with
  `0x02` has already received EK in `EP_HELLO`. In an `0x01` session without EK, `AUTH_E` and `th` are computed with
  32 zero bytes for `epEdPub`; a refusing `EP_AUTH` has no `th`, and a host ignores its 96 bytes.
- After `0x02` or `0x03` the earbud closes the channel. A second `HOST_HELLO` or `HOST_AUTH` on the same channel
  closes it as well.
- The host verifies `sigE` under the EK it stored at enrolment. A different EK means a reset or another unit: the host
  closes the channel and shows "This earbud's identity changed. Add it again." It never re-pins EK silently. A host
  that holds an EK for this earbud refuses a session without `sigE`.
- Timeouts (`UNAUTH` state): `HOST_HELLO` must arrive within 5 s of the channel open and `HOST_AUTH` within 5 s of
  `EP_HELLO`, otherwise the earbud closes the channel. A new channel on the same connection replaces an `UNAUTH`
  one (§4.1).
- Record sealing. Every record after `EP_AUTH`, in both directions, has `body = AES-256-GCM(k, nonce, aad = BE16(len)
  ‖ u8(type) ‖ u8(flags), plaintext) ‖ tag[16]`, with `k = kH2E` for host-to-earbud records and `kE2H` for
  earbud-to-host records, and `nonce = 0x00000000 ‖ BE64(seq)`, where `seq` counts the sealed records of that
  direction in this session from 1 and is not sent (the stream is reliable and ordered). A tag that does not verify,
  or `seq` reaching 2^63, closes the channel. `HOST_HELLO`, `EP_HELLO`, `HOST_AUTH` and `EP_AUTH` are the only
  unsealed records.
- Properties, stated: in a session where both signatures are present (every session after the first enrolment) a
  radio attacker, even one holding the BLE link keys, can neither read nor change nor replay a record, and a recorded
  session cannot be decrypted later. In an `ENROL_ONLY` session without EK only the host is authenticated; the
  enrolment code (§3.4) protects that one session, and the host reopens a mutually authenticated session right after
  `ENROLL_DONE`.
- Channel states on the earbud: `UNAUTH` (only `HOST_HELLO`, then `HOST_AUTH`), `ENROL_ONLY` (only `ENROLL_BEGIN`
  and `ENROLL_COMMIT`), `AUTHED` (everything). Every other message in a state that does not allow it
  gets ERROR `not_authenticated` and has no effect.
- Cost: one X25519 key generation and one X25519 per session, one Ed25519 signature and one verification, and one
  AES-GCM operation per record on CRACEN; AES-GCM and X25519 are already linked for the inner seal and the KEM
  combiner.

### 4.4 Requests, responses, timeouts and errors

- At most one outstanding request per request type. Each call-plane response carries the `callHandle` and the round of
  its request.
- Idempotent retries. For every call-plane request the earbud keeps the last response per `(callHandle, request type,
  round)` until the context moves past that step (the next request of a later step of the same round, the next round,
  or `CALL_END`). A request byte-identical to the one that produced the cached response gets the cached response again,
  without recomputation and without a new random value; a different body for the same `(callHandle, request type,
  round)` gets `bad_state`, except a `PEER_ACCEPT` for a round whose first `PEER_ACCEPT` was answered ok (the round is
  bound), which gets `already_bound`. This is what makes a request lost to a link drop (§5.10) safe to resend: for
  example a lost `ACCEPT_BOUND` is reproduced exactly, `B` included. Once a cached response was released (the
  context moved past its step), the earbud never recomputes it: a later request of that step gets `bad_state`,
  byte-identical or not, except a `PEER_ACCEPT` for a bound round, which gets `already_bound` (for example a
  `PEER_ACCEPT` of round 1 that arrives after `KCMAC_VERIFIED` of round 1 erased the cached `ACCEPT_BOUND` and
  `sasNonce`, §6.7).
- `EPL_RESPONSE_TIMEOUT` is 5 s for every request, and 10 s for a request whose response carries an ML-DSA signature
  (phase 2), measured by the host from the moment the request was written to the channel. The host treats an expired
  request as failed (§5.11) unless the link dropped meanwhile, in which case it resends after the resume (§5.10).
  Expected response times are far below it (§5.6).
- Setup timeout. A call context whose round 1 has no derived keys 120 s after `CALL_BEGIN` (`EP_SETUP_TIMEOUT`, above
  the server's 60 s ring timeout plus its 30 s sweep margin, `cmd/bcrypto-lite/main.go:1897`,
  `call_release.go:68`) is erased (§6.7) and later requests for it get `bad_state`.
- The earbud processes records in arrival order but runs the cryptographic requests on a worker thread (§10.3), so
  audio records are never delayed behind a signature or a KEM operation.
- `ERROR` (E→H) = `u8(reqType) ‖ u8(code) ‖ LP(detail)`, `detail` printable ASCII of at most 64 bytes with no key,
  MAC, nonce, SAS word or identifier beyond 8 characters.
- Layout of a refusal. A request refused with a code of the table below is answered with its typed response when that
  response has a `status` byte (`CALL_BEGIN_OK`, `OFFER_EPH`, `OFFER_SIGNED`, `ACCEPT_BOUND`, `PEER_OFFER_OK`,
  `ACCEPT_SIGNED`, `RESUME_RESULT`, `KCMAC_ACK`, `ENROLL_RESULT`, `ENROLL_DONE`, `UNENROLL_DONE`). The response keeps
  the fields that precede `status` (`h` and `round` as in the request), then `status`, and ends there, with two
  exceptions: `ENROLL_RESULT` keeps its fixed fields as zeros (§4.5), and `CALL_BEGIN_OK` and `RESUME_RESULT` are
  always 2 bytes (`h = 0x00` in a refused `CALL_BEGIN_OK`, the request's `h` in a refused `RESUME_RESULT`). Every
  other refusal is an `ERROR` record with the request's type and the code: a request whose response has no `status`
  byte (`REVEAL` refused by its state, `HOST_LIST`, `ROUND_DROP`, `CALL_END`, `MEDIA_CTRL`), a message the channel
  state does not allow (`not_authenticated`), a request too short to carry `h` and `round` (`malformed`), an unknown
  type and a malformed record (§4.2). A `CALL_END` for an `h` with no context gets `ERROR` `bad_state`, which the host
  takes as the end of that context.

Status and error codes, one table for every response `status` byte and every `ERROR` code:

| Code | Name | Meaning |
|---|---|---|
| `0x00` | ok | |
| `0x01` | bad_state | message not allowed in the current call or round state |
| `0x02` | malformed | a field has the wrong length, an `LP` overruns, CAPSX or advEnc does not parse, the earbud's own advEnc has more than 64 entries or a non-zero role byte |
| `0x03` | required_tag_missing | CAPSX of the earbud's own bundle lacks `capsBindV1`, `earbudEpV1`, `innerSealV2` or `rekeyChainV1`, or lacks `sigHybridV1` while a `hybKeyId` is supplied (phase 1) or on phase-2 firmware |
| `0x04` | forbidden_tag | CAPSX of the earbud's own bundle contains `frameKeyV6` or `innerAudioAadV1`, or contains `sigHybridV1` without a `hybKeyId` on phase-1 firmware |
| `0x05` | round_rule | first round not 1, round not greater than the last accepted one, `sasCommit` present or absent against WIRE_SPEC §3.1, round above 2^31 − 1, a `PEER_ACCEPT` whose `roundEcho` differs from its `round` |
| `0x06` | rekey_nonce_mismatch | `rekeyNonce` differs from the call's |
| `0x07` | dtls_fp_changed | the own fingerprint supplied differs from the call's, or the peer's fingerprint differs from the one pinned in round 1 |
| `0x08` | chain_base | PQC B13 refusal of a `PEER_OFFER`: `chainBase` missing, `≥ E`, or naming a round whose `ck` this earbud does not hold (never derived, or erased by the retention rule of PQC B13); the answer is the round's `PEER_OFFER_OK` with this status, and the earbud keeps nothing of the round |
| `0x09` | too_many_rounds | more than `EP_MAX_STAGED = 8` rounds armed and undecided |
| `0x0A` | spacing | `OFFER_PREP` of a rekey round received less than 5 s after the earbud answered the previous `OFFER_SIGNED` ok, or while the earbud's previous own round is undecided (neither confirmed by `KCMAC_VERIFIED` nor dropped by `ROUND_DROP`) (PQC §2.6 R-OFFERSPACING). Only `OFFER_PREP` gets this code: an `OFFER_FINAL` that follows an `OFFER_EPH` ok is never refused with it. In a call that negotiated `rekeyChainV1` the base rule of §5.4 (caller, step 1) is checked first: an `OFFER_PREP` of a rekey round that arrives before `KCMAC_VERIFIED` of round 1 gets `bad_state`, never `spacing`, although round 1 is then undecided, as the D12 gate of PQC B13 runs before any rate limit |
| `0x0B` | crypto_failure | key generation, encapsulation or decapsulation failed, or an X25519 output is all zero |
| `0x0C` | (reserved) | was `peer_key_changed` of the revision-1 peer pin table, removed (§5.9) |
| `0x0D` | busy | another call context is active, a confirm window is open, a cellular call is ringing or active (enrolment), or another host owns the ring (§9.13) |
| `0x0E` | unsupported | a feature this firmware does not implement (for example a hw_only PSK reference before phase 1b) |
| `0x0F` | offer_binding_mismatch | the ACCEPT's `offerBinding` is not the hash of the OFFER this earbud signed |
| `0x10` | already_bound | a second `PEER_ACCEPT` for a round that is bound, with a body that differs from the first (a byte-identical one gets the cached `ACCEPT_BOUND` while that cache exists, a different one after a refused first `PEER_ACCEPT` gets `bad_state`), and every `PEER_ACCEPT` for a bound round after its cached `ACCEPT_BOUND` was released, byte-identical or not |
| `0x11` | not_authenticated | channel state does not allow the message |
| `0x12` | unknown_type | |
| `0x13` | resource | out of memory or time for this request |
| `0x14` | no_press | the confirm window of 30 s ended without a confirm gesture |
| `0x15` | other_account | enrolment under another account UUID than the earbud's |
| `0x16` | host_table_full | |
| `0x17` | bad_cert | `ENROLL_COMMIT` certificate does not verify under the host key |
| `0x18` | not_owner | a message for a call context that another host's session created (§9.13) |
| `0x19` | not_fresh | `ENROLL_BEGIN` from an unknown host without a fresh bond or a pairing-mode window (§3.4 step 3) |
| `0x1A` | caps_changed | a rekey round's `CAPSX_own` differs from the round-1 `CAPSX_own` of the call (PQC §2.6) |
| `0x1B` | cancelled | the confirm window was cancelled with a short press |
| `0x1C` | ht_mismatch | host side only: the host's `SHA-256(HT)` differs from the earbud's (§3.9); never sent by the earbud |

### 4.5 Message catalogue

`h` is the `callHandle` (`u8`, assigned by `CALL_BEGIN_OK` in 1..255; `h = 0x00` addresses no call and is valid only in
`MEDIA_CTRL` TONE_START and TONE_STOP, for example the ring of a call that has not been answered). `round` is `BE32(rekeyRound)` of the round the message is
about. `CAPS9`, `CAPSX`, `advEnc` and `DTLSFP` are the encodings of WIRE_SPEC §3.7, PQC §2.3 and WIRE_SPEC §3.8.1. All
fixed-length key fields have the lengths of WIRE_SPEC §3.1 (ML-KEM-1024 key and ciphertext 1568 B, X25519 32 B).

| Type | Dir | Name | Maximum message |
|---|---|---|---|
| `0x07` | H→E | HOST_HELLO | 35 |
| `0x80` | E→H | EP_HELLO | 288 |
| `0x01` | H→E | HOST_AUTH | 160 |
| `0x81` | E→H | EP_AUTH | 97 |
| `0x02` | H→E | ENROLL_BEGIN | 281 |
| `0x82` | E→H | ENROLL_PROMPT | 2 |
| `0x83` | E→H | ENROLL_RESULT | 129 |
| `0x03` | H→E | ENROLL_COMMIT | 64 |
| `0x84` | E→H | ENROLL_DONE | 1 |
| `0x04` | H→E | UNENROLL | 32 |
| `0x85` | E→H | UNENROLL_DONE | 1 |
| `0x05`, `0x86` | | reserved (revision-1 PIN_ACCEPT and PIN_RESULT, removed) | |
| `0x06` | H→E | HOST_LIST | 0 |
| `0x87` | E→H | HOST_LIST_RESULT | 169 |
| `0x10` | H→E | CALL_BEGIN | 293 |
| `0x90` | E→H | CALL_BEGIN_OK | 2 |
| `0x11` | H→E | OFFER_PREP | 5 |
| `0x91` | E→H | OFFER_EPH | 42 (phase 1b: 2,157) |
| `0x12` | H→E | OFFER_FINAL | 8192 |
| `0x92` | E→H | OFFER_SIGNED | 8192 |
| `0x13` | H→E | PEER_ACCEPT | 16384 |
| `0x93` | E→H | ACCEPT_BOUND | 512 |
| `0x14` | H→E | PEER_OFFER | 16384 |
| `0x94` | E→H | PEER_OFFER_OK | 38 (phase 1b: 2,284) |
| `0x15` | H→E | ACCEPT_FINAL | 12288 |
| `0x95` | E→H | ACCEPT_SIGNED | 8192 |
| `0x16` | H→E | REVEAL | 65 |
| `0x96` | E→H | REVEAL_RESULT | 22 |
| `0x17` | H→E | KCMAC_VERIFIED | 37 |
| `0x97` | E→H | KCMAC_ACK | 6 |
| `0x18` | H→E | ROUND_DROP | 6 |
| `0x98` | E→H | ROUND_DROPPED | 5 |
| `0x1E` | H→E | CALL_RESUME | 1 |
| `0x9E` | E→H | RESUME_RESULT | 2 |
| `0x1F` | H→E | CALL_END | 67 |
| `0x9F` | E→H | CALL_ENDED | 1 |
| `0x20` | H→E | AUDIO_IN | 300 |
| `0xA0` | E→H | AUDIO_OUT | 300 |
| `0x21` | H→E | MEDIA_CTRL | 3 |
| `0xA1` | E→H | EVENT | 256 |
| `0xFF` | E→H | ERROR | 68 |

Enrolment and hosts:

```
ENROLL_BEGIN  = uuid_raw[16] ‖ LP(hostDeviceId) ‖ BE64(created_ms)        host key = hostEdPub of this session's HOST_AUTH
ENROLL_PROMPT = u8(windowSeconds) ‖ u8(enrolCode)                          30; the code of §4.3, which the host recomputes
ENROLL_RESULT = u8(status) ‖ epEdPub[32] ‖ earbudId[32] ‖ pop[64]          zeros unless status = ok
ENROLL_COMMIT = cert[64]
ENROLL_DONE   = u8(status)
UNENROLL      = hostEdPub[32]          removes that host entry; another host's entry needs the confirm gesture
                                       (the earbud answers ENROLL_PROMPT first, with the code of this session)
UNENROLL_DONE = u8(status)
HOST_LIST     = ∅                      AUTHED sessions only
HOST_LIST_RESULT = u8(n) ‖ n × (hostEdPub[32] ‖ u8(platform) ‖ BE64(created_ms) ‖ u8(connected))
```

The host compares `enrolCode` of `ENROLL_PROMPT` with its own computation from `th` and aborts on a difference
(a programming error, or a session that is not the one it authenticated); the user-facing comparison is the tones.

Call context:

```
CALL_BEGIN    = u8(role) ‖ LP(callId) ‖ dtlsFpSelf[33] ‖ u8(flags) ‖ u8(graceSeconds)
                role 0x01 = caller (o), 0x02 = callee (a); callId 1..255 B, exactly the transcript callId;
                flags: every bit reserved, 0; graceSeconds 5..15, the link grace of §5.10 for this host platform
CALL_BEGIN_OK = u8(status) ‖ u8(h)                the context records the hostEdPub of this session as its owner
CALL_END      = u8(h) ‖ LP(reason)       reason printable ASCII ≤ 64 B (the call's close reason)
CALL_ENDED    = u8(h)
CALL_RESUME   = u8(h)
RESUME_RESULT = u8(status) ‖ u8(h)
```

Caller rounds (the earbud's host is `o`, R-OFFERER: only it offers):

```
OFFER_PREP    = u8(h) ‖ round
OFFER_EPH     = u8(h) ‖ round ‖ u8(status) ‖ x25519Pub[32] ‖ BE32(chainBase)
                chainBase = 0xFFFFFFFF in round 1 and in a call without rekeyChainV1
OFFER_FINAL   = u8(h) ‖ round ‖ CAPS9[9] ‖ LP(CAPSX_own) ‖ EXTXIN ‖ LP(advEnc_own)
OFFER_SIGNED  = u8(h) ‖ round ‖ u8(status) ‖ pqcPub[1568] ‖ rekeyNonce[8] ‖ LP(sasCommit | ∅) ‖ CAPS9_signed[9]
                ‖ offerBinding[32] ‖ sigV6[64] ‖ LP(HYB | ∅)
PEER_ACCEPT   = u8(h) ‖ round ‖ signerIK[32] ‖ ctPqc[1568] ‖ ctX25519[32] ‖ LP(ctStrongBox) ‖ LP(ctDualCurve)
                ‖ CAPS9_peer[9] ‖ LP(selectedPskFp) ‖ LP(offerBindingEcho) ‖ LP(advEnc_peer) ‖ rekeyNonce[8]
                ‖ BE32(roundEcho) ‖ dtlsFpPeer[33] ‖ sigV6[64] ‖ PSKREF ‖ LP(CAPSX_peer) ‖ EXTX_peer[32] ‖ RELAY
ACCEPT_BOUND  = u8(h) ‖ round ‖ u8(status) ‖ acceptBinding[32] ‖ kcMacOwn[32] ‖ kcMacPeer[32]
                ‖ LP(SASOUT | ∅) ‖ EXPORT
```

Callee rounds:

```
PEER_OFFER    = u8(h) ‖ round ‖ signerIK[32] ‖ pqcPub[1568] ‖ x25519Pub[32] ‖ LP(strongBox) ‖ LP(dualCurve)
                ‖ CAPS9_peer[9] ‖ LP(advEnc_peer) ‖ rekeyNonce[8] ‖ dtlsFpPeer[33] ‖ LP(sasCommit | ∅) ‖ sigV6[64]
                ‖ BE32(chainBase) ‖ LP(CAPSX_peer) ‖ EXTX_peer[32]
                chainBase = 0xFFFFFFFF when the OFFER carries none
PEER_OFFER_OK = u8(h) ‖ round ‖ u8(status) ‖ x25519Pub[32]
ACCEPT_FINAL  = u8(h) ‖ round ‖ CAPS9[9] ‖ LP(selectedPskFp) ‖ PSKREF ‖ LP(advEnc_own) ‖ LP(CAPSX_own) ‖ EXTXIN ‖ RELAY
ACCEPT_SIGNED = u8(h) ‖ round ‖ u8(status) ‖ ctPqc[1568] ‖ CAPS9_signed[9] ‖ acceptBinding[32] ‖ sigV6[64]
                ‖ kcMacOwn[32] ‖ kcMacPeer[32] ‖ EXPORT ‖ LP(HYB | ∅)
REVEAL        = u8(h) ‖ B[64]                     B = acceptBinding[32] ‖ sasNonce[32], decoded from SASREVEAL
REVEAL_RESULT = u8(h) ‖ u8(verdict) ‖ LP(sasKdf[18] | ∅)
                verdict 0x00 ok, 0x01 sibling, 0x02 commit_mismatch, 0x03 duplicate, 0x04 conflicting
```

Both roles:

```
KCMAC_VERIFIED = u8(h) ‖ round ‖ mac[32]           the peer MAC the host attributed to this round
KCMAC_ACK      = u8(h) ‖ round ‖ u8(status)        0x00 confirmed, 0x01 bad_state (no such armed round),
                                                   0x02 malformed (not the expected MAC of the round)
ROUND_DROP     = u8(h) ‖ round ‖ u8(reason)        0x01 abandoned, 0x02 refused, 0x03 window expired, 0x04 kcmac failed
ROUND_DROPPED  = u8(h) ‖ round
```

Shared sub-structures:

```
EXTXIN = LP(relayKem.mlkem | ∅) ‖ LP(relayKem.x25519 | ∅) ‖ LP(hybKeyId | ∅)
         raw decoded bytes. hybKeyId: phase-1 firmware, the host device's ML-DSA key id (32 B) when the host
         co-signs (§3.9), else ∅; phase-2 firmware, MUST be ∅ (the earbud uses its own key id). The earbud computes
         EXTX itself with mldsaKeyId = hybKeyId (phase 1) or its own key id (phase 2), and LP(∅) for capsWithdrawn.
PSKREF = u8(kind) ‖ ...
         kind 0x00: no PSK selected
         kind 0x01: LP(psk)          raw bytes of the agreed host-vault PSK (1..64 B)
         kind 0x02: u8(slot)         an earbud-held hw_only PSK (phase 1b, §5.12)
RELAY  = u8(mode) ‖ ...              what the earbud derives for the outer layer of THIS round
         mode 0x00: nothing          (outer off, or a round that keeps the previous outer keys)
         mode 0x01: nothing more     legacy M-15 keys, round 1 only (srtpDirKeyV1 negotiated, relayKemV1 not in effect)
         mode 0x02: relaySS[64] ‖ RELAYX[32]      relayKemV1 in effect (round 1, or a rekey round under relayRotV1)
EXPORT = u8(outerMode) ‖ OUTER ‖ vconfKey[32]
         outerMode 0x00: OUTER = ∅
         outerMode 0x01: OUTER = m15_a2b[32] ‖ m15_b2a[32]
         outerMode 0x02: OUTER = kOut_audio_o2a[32] ‖ kOut_audio_a2o[32]
SASOUT = sasKdf[18] ‖ B[64]          round 1 only, caller: the SAS-KDF output and the REVEAL payload
HYB    = u8(form) ‖ ...              present exactly when the earbud's CAPSX_own carries sigHybridV1 (§3.9)
         form 0x01 (phase 1, host-anchored): htHash[32] ‖ sigEd[64]
                   the host checks htHash = SHA-256(HT) of its own HT, signs sigPq and sends sigEd ‖ sigPq
         form 0x02 (phase 2, earbud key):    htHash[32] ‖ mldsaKeyId[32] ‖ sigEd[64] ‖ sigPq[4627]
```

Media and events:

```
AUDIO_IN   = inner envelope (first byte 0x01 or 0x04), exactly as it came out of the outer open
AUDIO_OUT  = inner envelope produced by the earbud
MEDIA_CTRL = u8(h) ‖ u8(cmd) ‖ [u8(arg)]
             0x01 TX_PAUSE   stop capture and stop AUDIO_OUT (local hold, WIRE_SPEC §16.3)
             0x02 TX_RESUME
             0x03 MIC_MUTE   keep sending blocks, encode silence (constant rate)
             0x04 MIC_UNMUTE
             0x05 VOLUME arg 0..255
             0x06 TONE_START arg: 0x01 hold beep (WIRE_SPEC §16.4: 350 ms at 425 Hz, about −24 dBFS, every 4 s),
                  0x02 ringback, 0x03 incoming ring, 0x04 busy, 0x05 error
             0x07 TONE_STOP
             0x08 GATE arg 0x00 closed, 0x01 open: the media gate of §7.9; closed at CALL_BEGIN
             No MEDIA_CTRL command, and no other EPL message, changes or suppresses the capture indicator of §7.10 or
             arms the capture press of §7.10: only the earbud button arms it.
             Every command with h ≠ 0 is accepted only from the owner host of h (§9.13).
EVENT      = u8(code) ‖ LP(data)
             0x01 BUTTON        data = u8(gesture): 0x01 short, 0x02 double, 0x03 long; sent only to the host the
                                gesture table of §9.14 names, and only for gestures the table exports
             0x02 VOICE_SCORE   data = u8(dir) ‖ f32 LE score; dir 0x01 received (peer) voice, 0x02 own voice;
                                score in [0,1] with 1.0 = genuine human voice, −1.0 no audio yet, −2.0 NPU not ready
             0x03 AUDIO_STATS   data = BE32 txFrames ‖ BE32 rxFrames ‖ BE32 rxLate ‖ BE32 rxLost ‖ BE32 decodeFail
                                ‖ BE32 concealed ‖ BE16 jitterMs ‖ BE32 replayDrops ‖ BE32 authFails, every 10 s in a
                                call, and every 2 s while authFails grew in the previous period
             0x04 DIAG          data = the 32 B DIAG record of characteristic 0x90 (below), every 10 s
             0x05 STATE         data = u8(state) of the call context: 0x00 idle, 0x01 ringing, 0x02 handshake,
                                0x03 active, 0x04 held, 0x05 resuming; other values reserved (a host ignores the event)
             0x06 CELLULAR      data = u8(state) of a cellular call seen by the CCP client during an EP call:
                                0x00 none (the last one ended), 0x01 incoming, 0x02 outgoing (dialing or alerting),
                                0x03 active, 0x04 held (locally or remotely); other values reserved (ignored)
             0x07 LE_AUDIO_REFUSED  data = ∅
             0x08 LOG           data = u8(level) ‖ text (≤ 200 B, printable ASCII, no secret), at most 5 per second
             0x09 BATTERY       data = u8(percent), 0xFF unknown
             0x0A INNER_FAIL    data = BE16(fails) ‖ BE16(windowMs) ‖ u8(lastEpochByte) ‖ u8(path): sent at once
                                when at least 5 inner opens failed within 2,000 ms (about 15 % of a phone's 16.7
                                frames per second; path 0x04 = innerSealV2, 0x01 = legacy), at most one event per
                                2 s (§7.11). Exactly: at each inner failure at time t the earbud counts the failures
                                in (t − 2,000 ms, t]; when the count is 5 or more and no INNER_FAIL was sent in
                                (t − 2,000 ms, t], it sends one with fails = that count, windowMs = t minus the time
                                of the oldest failure counted (0 to 1,999), lastEpochByte = the epoch byte of the
                                envelope that failed at t (0x00 on the legacy path, which has none) and path = that
                                envelope's path. An inner failure is an envelope whose AEAD open fails under every
                                live slot or that the length check of §7.5 drops; a replay or reflection drop is not
                                one. AUDIO_STATS authFails counts the same failures
             0x0B CAPTURE       data = u8(state) ‖ u8(reason): state 0x00 encoding silence, 0x01 capturing;
                                reason 0x01 gate closed, 0x02 waiting for the capture press, 0x03 TX_PAUSE,
                                0x04 MIC_MUTE, 0x00 none (state 0x01 only). When several reasons apply at once the
                                earbud reports the first of 0x02, 0x01, 0x03, 0x04. "Waiting for the capture press"
                                is exactly the pair state 0x00, reason 0x02; it is sent right after CALL_BEGIN_OK and
                                after every RESUME_RESULT ok (§7.10)
```

Events of a call context go to its owner host; `BATTERY`, `LOG` and `DIAG` outside a call go to every `AUTHED`
session.

DIAG record, the value of characteristic `0x90` (WIRE_SPEC §7) and the data of `EVENT` DIAG: 32 bytes, packed, little
endian, the layout of `struct qaudion_diag_pkt` at `74a43d2` (`qaudion_gatt.c:211-248`, filled by `diag_read` at
`:1336`):

```
offset  0  u32  heap_used_kb        system heap in use, KiB (0 when heap statistics are not built in)
offset  4  u32  heap_free_kb        system heap free, KiB (same)
offset  8  u8   cpu_load_pct        0 = not measured
offset  9  u8   battery_pct         0..100; 0xFF = USB power or unknown (no battery node)
offset 10  u8   pdm_ok              1 = microphone path ready
offset 11  u8   tdm_ok              1 = speaker path ready
offset 12  u32  hs_count            call rounds whose keys the earbud derived since boot; 0 in a no-endpoint image
offset 16  u8   axon_ok             1 = voice-score NPU ready
offset 17  u8   call_state          the EVENT STATE value of the call context, 0x00 when there is none
offset 18  u16  ble_interval_125us  interval of the connection the record is read on (EVENT DIAG: of the receiving
                                    session's connection), in 1.25 ms units
offset 20  f32  deepfake_score      IEEE 754 binary32, the last voice score of the NPU (§11.3, without its direction);
                                    -1.0 = none yet, and also when axon_ok = 0
offset 24  u32  uptime_sec          seconds since boot
offset 28  u32  aead_ops_total      inner seal and open operations since the audio pipeline last started
```

Only two meanings change from `74a43d2`, because the retired plane that defined them goes (§8.4): `hs_count` counted
the retired GATT handshakes and `call_state` carried the retired CALL_STATE numbering.

### 4.6 Rules for host-supplied inputs

The host is trusted for the call context (call id, roles, DTLS fingerprints, its own capability tags, adverts and
relay keys) but never for the earbud's secrets. The earbud therefore checks every input it can check and documents the
rest:

- Lengths, `LP` bounds, CAPSX grammar (PQC §2.3), advEnc grammar, callId 1..255 B, round range. The earbud's own
  advEnc has at most 64 entries and every role byte `0x00` (the JSON of an earbud bundle carries no `pskRoles`, so a
  non-zero role byte would make the peer's rebuilt transcript differ, `sig_invalid`); this is a sender limit of this
  document, below WIRE_SPEC's `m ≤ 255`. The peer's advEnc is accepted up to WIRE_SPEC's limit of 255 entries.
- The earbud's own CAPSX MUST contain its required tags and MUST NOT contain its forbidden tags (§4.4 codes 0x03,
  0x04). Other host tags are accepted and logged. The earbud stores the round-1 `CAPSX_own` and requires every later
  round's `CAPSX_own` to be byte-identical (code `caps_changed`), which is the sender rule of PQC §2.6.
- CAPS9: the earbud forces `sframeV1` and `vkeyV1` to `0x00`; it cannot check the seven other bytes (§2.4).
- `dtlsFpSelf` is fixed at `CALL_BEGIN` for the call; the peer's fingerprint is pinned at round 1 and compared in every
  later round (WIRE_SPEC §3.8.2 step 5, R-CERT).
- Round rules of WIRE_SPEC §3.1 and §3.7: first OFFER of a call has round 1 and a 32-byte `sasCommit`, later rounds
  are strictly increasing and carry none; the ACCEPT echoes the round and `rekeyNonce` (a `PEER_ACCEPT` whose
  `roundEcho` differs from its `round` gets `round_rule`); `offerBindingEcho` equals the earbud's `offerBinding`.
- Values the earbud cannot check (the peer's CAPSX and EXTX, `relaySS`, `RELAYX`, the PSK bytes, the selected
  fingerprint string): a wrong value only changes keys or MACs that the remote peer computes from the real wire bytes,
  so the round fails its KCMAC (`kcmac_mismatch`) or the host's own outer layer fails. None of them can make the earbud
  derive a key that the host knows.
- The peer bundle itself, including the peer's key, is the input that an active host controls completely; the earbud
  cannot judge it (§1.4, §5.8, §5.9).
- Messages that name a call context are accepted only from that context's owner host (§9.13, code `not_owner`).

---

## 5. Call flows

### 5.1 Preconditions

Before an EP call the host has an authenticated EPL session (§4.3), `EP_INFO` with `protocolVersion = 0x02` and the
capability bits it needs (§8.2; bit 12, capture press required, is always among them, OD-6 (b)), and the earbud is not
in another call. Otherwise the call is a phone call, on the phone, and the host says why (§9.9; OD-3, decided
2026-11-17: a visible notice, never a refused call). The host decides once per call, before the first bundle,
whether the call is an EP call; it never changes that decision during the call. The session that sends `CALL_BEGIN`
makes its host the owner of the context (§9.13). Every context starts with the media gate closed (§7.9) and waiting
for the capture press (OD-6 (b), §7.10), unless the answer press of §5.3 step 2 already is that press: the earbud
sends encoded silence until both are released.

### 5.2 Caller, round 1

1. The user starts the call. The host creates the call's DTLS certificate and `fpSelf` (WIRE_SPEC §3.8.2 step 1) and
   sends `CALL_BEGIN` (role caller, `callId`, `fpSelf`, the link grace of its platform). The context waits for the
   capture press (§7.10): the earbud reports `EVENT` CAPTURE reason `0x02` right after `CALL_BEGIN_OK`, the host shows
   "Press the earbud to start talking" (§9.9), and the press can come at any time of the call.
2. `OFFER_PREP` (round 1). The earbud generates the round's ML-KEM-1024 key pair and X25519 key pair and answers
   `OFFER_EPH` with the X25519 public key.
3. The host computes its advert tags with `nonce_sender` from that X25519 public key (WIRE_SPEC §3.3.1), its
   `relayKem` key pair if it advertises `relayKemV1`, the earbud bundle's CAPSX and, when its device has a published
   ML-DSA key, `hybKeyId` (§3.9). It sends `OFFER_FINAL`.
4. The earbud mints `rekeyNonce` (8 B, once per call) and `sasNonce` (32 B), computes `sasCommit` (WIRE_SPEC §3.7.4),
   builds OFFER_v6 and signs it with EK, and with `sigHybridV1` also `HT` (§3.9). It answers `OFFER_SIGNED`; the host
   checks `htHash`, adds `sigPq` (phase 1), builds the JSON bundle by the mapping of §5.5, checks the 24 KiB rule
   (PQC §5.6) and sends `call_offer` and the opaque OFFER.
5. The ACCEPT arrives. The host parses it strictly, runs the malformed checks and the echo checks (`offerBinding` from
   `OFFER_SIGNED`, `rekeyNonce`, round), and binds round 1 to the first ACCEPT that passes, before any suspension point
   (R-COMMIT-BIND). It runs its identity policy on the peer (§3.7 for an earbud peer; its pins otherwise) and verifies
   the peer's `sigV6`. An invalid signature or an unresolved identity does not prevent binding, as today.
6. The host sends `PEER_ACCEPT` with the bound ACCEPT's fields, the PSK it resolved from the echoed selection, the
   peer's CAPSX and EXTX, and the outer mode of round 1.
7. The earbud rebuilds ACCEPT_v6 to compute `acceptBinding` (§5.8: it does not judge the peer's signature),
   decapsulates, computes the X25519 secret, derives the round keys (§6) and answers `ACCEPT_BOUND` with both MACs, the
   SAS-KDF output, the REVEAL payload and the export. `sasNonce` lives on only inside the cached `ACCEPT_BOUND`
   (§4.4), so a resend after a link drop gets the same `B`; it is erased with that cache when round 1's KCMAC is
   verified or the call ends (§6.7).
8. The host installs the outer keys, sends `<callId>|SASREVEAL:<base64(B)>`, then `<callId>|KCMAC:<base64(0x01 ‖
   kcMacOwn)>` right after it (R-KCMAC-NOGATE), arms the round in PENDING with `kcMacPeer` and the caller's 30 s window
   after the REVEAL (R-COMMIT-KCMAC-HOLD), and shows the SAS once `call_accepted` has arrived (WIRE_SPEC §3.5).
9. When the host attributes the callee's MAC to round 1 (R-KCMAC-ROUNDS step 3) it sends `KCMAC_VERIFIED`; the earbud
   checks the MAC against its own expected value and marks round 1 confirmed (§6.4).
10. The earbud seals round-1 audio from the moment its keys are installed (PQC B2, round-1 case) and sends
    `AUDIO_OUT` records; the host forwards them once its outer layer is installed (PQC B3 rule 2). Until the media
    gate opens (§7.9) and the capture press arrived (OD-6 (b), §7.10), those blocks are encoded silence.

### 5.3 Callee, round 1

1. While the call rings the host holds the OFFER (R-ANSWER-FIRST) and creates no call context in the earbud. It MAY
   ask the earbud to ring (`MEDIA_CTRL` TONE_START incoming ring with `h = 0`, which needs no call context); the first
   host that does so owns the ring until its `TONE_STOP`, its session closes or 90 s pass, and a second host's ring
   request gets `busy` (§9.13). A short press on the earbud while it rings is exported as `EVENT` BUTTON to the ring
   owner only: it is a hardware-button answer in the sense of WIRE_SPEC §3.5.
2. On that answer the host first creates the DTLS certificate and `fpSelf` and sends `CALL_BEGIN` (role callee). Only
   after `CALL_BEGIN_OK` does it send `call_accepted` for the hardware answer. If `CALL_BEGIN` fails (`busy`, timeout)
   the host sends no `call_accepted` for that press, keeps the call ringing on the phone and shows "Earbud
   unavailable, answer on the phone". An answer on the phone screen follows the same order when the call is to be an
   EP call. Then the host runs its identity policy on the caller. The capture press of §7.10 is the answer press
   itself when the user answered on the earbud and `CALL_BEGIN` reaches the earbud within `ANSWER_PRESS_WINDOW`
   (10 s) of that press; when the user answered on the phone's screen, or `CALL_BEGIN` comes later, the context waits
   for a press after its creation and the host shows "Press the earbud to start talking".
3. `PEER_OFFER` with the OFFER's fields. The earbud rebuilds OFFER_v6 to compute `offerBinding` (it does not judge the
   peer's signature, §5.8), checks the round rules, stores `offerBinding`, `sasCommit` and the peer's fingerprint,
   generates its X25519 ephemeral and answers `PEER_OFFER_OK`.
4. The host computes its own advert tags with `nonce_sender` from that X25519 public key, mirrors the dialect
   (WIRE_SPEC §3.3.1), selects the PSK from the OFFER's tags, encapsulates the peer's `relayKem` if `relayKemV1` is in
   effect (PQC B4, D9), and sends `ACCEPT_FINAL` (with `hybKeyId` when its device has a published ML-DSA key).
5. The earbud encapsulates to the peer's ML-KEM key, computes the X25519 secret, builds and signs ACCEPT_v6 (and `HT`
   with `sigHybridV1`), derives the round keys and answers `ACCEPT_SIGNED`; the host checks `htHash` and adds `sigPq`
   (phase 1).
6. The host builds the ACCEPT JSON, sends it before `call_answer` (WIRE_SPEC §3.8.2 step 4), starts the REVEAL timer
   (15 s) at the first send, installs its outer keys and arms the round in PENDING. It does not send its round-1 MAC
   yet (R-COMMIT-KCMAC-HOLD).
7. A REVEAL arrives. The host runs steps 1 to 4 of R-COMMIT-CHECK (routing, call context, sender, strict parse) and
   sends `REVEAL`. The earbud runs steps 5 to 7: `acceptBinding` against its own (`sibling` otherwise), duplicate or
   conflicting REVEAL, commitment check in constant time. `ok`: the earbud returns the SAS-KDF output; the host cancels
   the REVEAL timer, shows the SAS words, sends its round-1 MAC and starts the 15 s wait for the caller's MAC.
   `sibling`: the host leaves the call locally (R-COMMIT-SIBLING) and sends `CALL_END`. `commit_mismatch` or
   `conflicting`: `sas_commit_mismatch`.
8. The caller's MAC: `KCMAC_VERIFIED` as in §5.2 step 9.

### 5.4 Rekey rounds

Only the caller offers (PQC §2.6 R-OFFERER). The host's rekey scheduler decides when; the earbud enforces the spacing
of R-OFFERSPACING (one own round undecided at a time, at least 5 s between OFFERs), checked at `OFFER_PREP` only
(code `spacing`, §4.4).

Caller (earbud side offers round E + 1):

1. `OFFER_PREP`. The earbud returns its new X25519 public key and, with `rekeyChainV1` negotiated, `chainBase` = the
   greatest epoch whose peer MAC it confirmed and whose `ck` it still holds (PQC B13, D3). Before the round-1 KCMAC
   verified there is no base: the earbud answers `bad_state`, and the host defers the trigger as B13 (D12) requires.
   This check comes before the spacing check, so such an `OFFER_PREP` never gets `spacing` (§4.4); without
   `rekeyChainV1` there is no base rule and the same `OFFER_PREP` gets `spacing`, round 1 being undecided.
2. `OFFER_FINAL` with the round's adverts and, under `relayRotV1`, the round's fresh `relayKem` inputs.
3. `OFFER_SIGNED`; the host sends the rekey OFFER with the `chainBase` member and waits for its ACCEPT for 30 s
   (R-REKEY-ACCEPT-WAIT).
4. The ACCEPT that reaches the host in time goes in `PEER_ACCEPT`; `ACCEPT_BOUND` carries no SAS. The host sends the
   round's MAC at once, arms the round with the 15 s window and installs any new outer keys as staged.
5. Abandoned at T0 + 30 s, refused (phase 2, PQC §5.5) or failed: `ROUND_DROP`; the earbud erases the round's
   ephemerals and staged keys.

Callee (the earbud side accepts):

1. The host checks the rekey OFFER: round greater than the last, same `rekeyNonce`, the `chainBase` raw-token grammar
   of PQC B13 (a malformed token refuses the round at the host, before the earbud sees it) and, in an `auth=H` call of
   phase 2, the anchor rule of PQC §5.5.
2. `PEER_OFFER`. The earbud refuses with `chain_base` when it does not hold `ck_B`; the host logs
   `rekey=refused rreason=chain_base` and sends no ACCEPT (the round was never armed, the call goes on).
3. `ACCEPT_FINAL`, `ACCEPT_SIGNED`; the host sends the ACCEPT and its MAC at once (no hold in rekey rounds) and arms the
   round with the acceptor's 30 s window.

Both: on a verified peer MAC the host sends `KCMAC_VERIFIED`. Only then does the earbud move its inner send pointer to
the round (PQC B2 send switch); the host moves its outer send pointer by PQC B5. The earbud keeps at most
`EP_MAX_STAGED = 8` rounds armed and undecided (code `too_many_rounds` beyond), below `MAX_PENDING_ROUNDS = 16` of
WIRE_SPEC §3.7.1 and above the at most 7 pending rounds that R-OFFERSPACING allows.

### 5.5 JSON bundle of an EP call: who produces each member

| Member | Source |
|---|---|
| `kind`, `callId` | host |
| `pqcPublicKey` | `OFFER_SIGNED.pqcPub` |
| `x25519PublicKey` | `OFFER_EPH.x25519Pub` |
| `strongBoxPublicKey`, `dualCurvePublicKey` | absent (the earbud has neither) |
| `ciphertext.pqc` | `ACCEPT_SIGNED.ctPqc` |
| `ciphertext.x25519` | `PEER_OFFER_OK.x25519Pub` |
| `ciphertext.strongBox`, `ciphertext.dualCurve` | absent, also when the peer's OFFER carried those keys: they do not enter the v6 session key (WIRE_SPEC §3.7.1), and every verifier MUST accept an ACCEPT without them (vector in §13) |
| `capabilities` | host; the nine CAPS9 names MUST be true exactly where `CAPS9_signed` has `0x01`, and the other members with the value `true` MUST be exactly the names of `CAPSX_own` |
| `pskFingerprints` | host: lowercase hex of the entries of `advEnc_own`, same order; `pskRoles` absent |
| `selectedPskFingerprint` | host (ACCEPT) |
| `signerIdentityKey` | EK |
| `rekeyNonce` | `OFFER_SIGNED.rekeyNonce`; the ACCEPT echoes the OFFER's |
| `rekeyRound` | round |
| `sasCommit` | `OFFER_SIGNED` (round 1 only) |
| `dtlsFingerprint` | canonical text form of `fpSelf` |
| `sigV6` | `OFFER_SIGNED.sigV6` or `ACCEPT_SIGNED.sigV6` |
| `chainBase` | `OFFER_EPH.chainBase`, in rekey OFFERs of a call that negotiated `rekeyChainV1` |
| `relayKem` | host |
| `endpoint` | host, from its stored enrolment (§3.5) |
| `mldsaKeyId`, `sigHybrid` | phase 1: `hybKeyId` and `sigEd` of `HYB` form `0x01` followed by the host's `sigPq`; phase 2: `HYB` form `0x02` |
| `capsWithdrawn` | absent |

The host MUST NOT add any other member that changes a value the earbud signed or bound. A mismatch between the JSON and
what the earbud signed is caught by the peer as `sig_invalid` (transcript fields) or `kcmac_mismatch` (CAPSX, EXTX).

The JSON text is not canonical. The host may write the members above as any valid RFC 8259 text: member order,
insignificant whitespace and the escaping of `/` (or of any other character JSON allows to escape) are free; the text
has no duplicate member name, and integers are written in plain decimal. Nothing signs or binds the text: `sigV6`
covers the transcript (WIRE_SPEC §3.1) and CAPSX the decoded capability names. A receiver decodes it with the strict
parser of WIRE_SPEC §3.1 (D27, routing by D28, duplicates by its duplicate rule). A vector of §13.1 therefore pins a
bundle as a parsed JSON object: an emitted text conforms when its strict parse gives the same member names, each once,
with equal values (strings compared as sequences of Unicode code points after unescaping, integers as exact integers,
booleans as such, objects member by member, arrays element by element in order). The 24 KiB rule (PQC §5.6) is checked
on the bytes actually sent.

### 5.6 Timing against the protocol windows

Compute (spike, QEMU instruction counts, CPI 1.0 to 1.5 at 128 MHz, not measured on silicon): ML-KEM-1024 keygen
0.76 M, encapsulation 0.78 M, decapsulation 0.83 M, X25519 0.42 M, Ed25519 sign of a 1.8 KB message 0.46 M, verify
0.60 M instructions. A caller round costs about 1.7 M instructions before the OFFER and 1.9 M after the ACCEPT (13 to 22
ms each); a callee round about 2.3 M. ML-DSA-87 (phase 2) adds on average 107 to 160 ms per signature (p99 220 to
330 ms).

Transfer over the EPL with DLE 251: about 1.7 KB in each direction per round in phase 1, 6.4 KB out in phase 2. The
spike's model gives 10 to 68 ms ideal and up to about 1.1 s with a 3-PDU-per-event floor at long intervals; L2CAP
credits remove the per-write round trip that GATT writes with response would cost. Record sealing adds 16 bytes per
record. During a call the 512-byte record rule of §4.2 spreads a rekey's 1.7 KB (6.4 KB in phase 2) over 4 (13)
records interleaved with audio, which lengthens the rekey transfer by at most one audio record per data record; the
acceptance of §13.4 measures the audio gap budget of a phase-2 rekey under audio.

Against the windows: nothing starts a protocol timer while the earbud computes before a bundle is sent (the caller's
OFFER, the callee's ACCEPT after the answer), so that time is call-setup latency only. The callee's 15 s REVEAL timer
covers the caller's `PEER_ACCEPT` and `ACCEPT_BOUND` (well under 1.5 s), and the 15 s and 30 s KCMAC windows start at
arming, after the earbud answered. `EPL_RESPONSE_TIMEOUT` (5 s, 10 s with ML-DSA) is below every window.

### 5.7 Call end, sibling exit and hangup

- Any end of the call on the host (hangup, `call_hangup`, a security close reason, a sibling exit, the media watchdogs)
  sends `CALL_END` with the close reason. The earbud erases every secret of the call (§6.7), stops capture and
  playout, answers `CALL_ENDED` and returns to idle.
- The earbud never ends a call by itself, except on link loss after the grace of §5.10 and on the setup timeout of
  §4.4. A long press on the earbud during a call is an `EVENT` BUTTON to the owner host, which maps it to hangup; it
  never opens pairing mode while a context exists (§9.14).

### 5.8 Checks of the peer bundle in the earbud

For every `PEER_OFFER` and `PEER_ACCEPT` the earbud rebuilds the peer's transcript from the fields it received
(WIRE_SPEC §3.7, verifier inputs of the acceptor or the offerer), as a streamed SHA-256, to obtain `offerBinding` or
`acceptBinding`, and:

- does NOT verify the peer's `sigV6`. The host verifies it and applies the policy of WIRE_SPEC §3.8.6 (an invalid
  signature binds the round and holds media pending the SAS, which reaches the earbud as the closed media gate of
  §7.9). Reason (revision 2): the earbud learns the peer's key from the host, so its own verification would only
  prove that the host holds the key it supplied; it protects nothing against the host and nothing that the host's
  verification does not already cover, and dropping it removes the contiguous peer-transcript buffer that a 255-advert
  peer bundle would need (§12.3).
- applies the round rules, the `rekeyNonce` and round echo, the `offerBinding` echo and the fingerprint rule of §4.6,
  and refuses with the codes of §4.4.
- rejects an all-zero X25519 output (`crypto_failure`).
- accepts up to 255 adverts (WIRE_SPEC's limit) and the optional `strongBox` and `dualCurve` fields of the peer (it
  hashes them, it does not use them).

### 5.9 No earbud-side anchor for the peer's identity (OD-1)

Revision 1 proposed a TOFU table of peer keys in the earbud, keyed by a hash of the peer user id, with a button press
to accept a changed key. It is withdrawn: the peer user id, the peer key and the SAS the user sees all come from the
host, so a compromised host passes a user id the earbud has never seen and gets a silent first contact, or evicts a
genuine entry with rounds against peers it signs itself, and then shows the user the SAS of its own leg. The table
added a button press for honest flows and stopped nothing that it was introduced for.

The design therefore states the limit plainly (§1.4): an active host at call setup can run a man in the middle of an
EP call, as it can of a phone call it hosts. The only countermeasure known to this design is an earbud-rendered SAS:
the earbud plays the round-1 SAS, computed from its own `sasKdf`, in a form the remote user can compare by voice (for
example spoken digits from short Opus clips stored in flash, with a digit form of the SAS shown by every peer app).
That needs a new SAS representation in WIRE_SPEC §4 on every platform and flash for the clips. The owner decided on
2026-11-17 (OD-1 (a)) that the limit is stated and accepted and that no earbud-played SAS is built now; it stays
outside phases 1 and 2 and returns only with a new owner decision.

### 5.10 Link loss and resume

- If the EPL channel closes or the BLE link drops while a call context exists, in any state (handshake included), the
  earbud keeps the context, stops capture and playout, and waits the context's link grace `EP_LINK_GRACE`, which the
  host sets in `CALL_BEGIN` (5 to 15 s; proposed default 8 s on both platforms, to be tuned per platform from the
  phase-0 measurements of Android reconnect times and iOS background behaviour). The owner host reconnects, opens a
  session (§4.3) and sends `CALL_RESUME`; the earbud accepts it only from the session whose `hostEdPub` owns the
  context (`not_owner` otherwise). `RESUME_RESULT` ok resumes audio with the same keys and counters (the inner
  counters never reset, PQC B2). A request that was outstanding at the drop is resent unchanged and answered from the
  cache of §4.4.
- After the grace the earbud erases the call (§6.7). A later `CALL_RESUME` gets `bad_state`, and the host ends the call
  with the local, non-security reason `endpoint_lost`.
- Meanwhile the remote peer hears nothing and may show "Peer not audible" (WIRE_SPEC §16.6); its watchdogs are not
  changed.
- Lost during round 1 before the caller's REVEAL was sent: the resent `PEER_ACCEPT` returns the cached `ACCEPT_BOUND`
  with the same `B`, so the REVEAL can still be sent inside the callee's 15 s REVEAL window if the link returns in
  time; otherwise the peer ends the call with `sas_reveal_timeout` as for any late REVEAL.

### 5.11 Failure and retry rules

| Failure | Host action |
|---|---|
| EPL not available, version too old, earbud busy or in a cellular LE Audio call, before the first bundle | the call runs as a phone call, on the phone, with a visible notice that says why (OD-3, decided 2026-11-17); the call is not refused |
| Earbud request fails or times out before the first bundle of the call was sent | the same fallback to a phone call, with the notice "Earbud unavailable, this call is protected by the phone" (OD-3) |
| Failure after the first bundle was sent, in round 1 | end the call with `endpoint_failure` (local, non-security, the peer sees a normal hangup); the user redials. A bound round 1 without keys is a missing KCMAC context: `kcmac_mismatch` as WIRE_SPEC §3.7.3 requires |
| Failure in a rekey round, before its bundle was sent | the round is not sent (caller) or not accepted (callee): no OFFER or ACCEPT, the call stays on the current round, as PQC §5.5 prescribes for a signer failure |
| Failure after a rekey bundle was sent | `ROUND_DROP`; the KCMAC window decides as for any round |
| `htHash` differs from the host's own `SHA-256(HT)` (§3.9) | a programming error on one side: treated as a failure of that request by the rows above, logged `err code=ht_mismatch` |
| Link lost | §5.10 |
| Inner layer failing (`EVENT` INNER_FAIL) | §7.11 |

A host never retries a request with changed inputs inside the same round; a retried request is byte-identical and
gets the cached response (§4.4).

### 5.12 Phase 1b: hw_only PSKs held in the earbud

hw_only PSKs (KMS sovereign and earbud-exclusive keys imported with `KEY_IMPORT`, WIRE_SPEC §7) may only be used inside
the earbud. Phase 1b adds:

- `OFFER_EPH` and `PEER_OFFER_OK` gain an appended `LP(advEnc_hw)`: the tags of the earbud's hw_only PSKs computed in
  the earbud with the earbud's own X25519 public key (WIRE_SPEC §3.3.1, role 0). The host merges them into its advert
  list in the priority order it decides, within the 64-entry limit of the earbud's own advEnc (§4.6).
- `PEER_OFFER_OK` (callee) also gains `LP(matches)` = `u8(n) ‖ n × (u8(index in advEnc_peer) ‖ u8(slot))`: the
  received tags that one of the earbud's hw_only PSKs reproduces under some role (the 256-role search of WIRE_SPEC
  §3.3.1). The host picks the first received tag that either side reproduces and sends `PSKREF` kind `0x02` when it is
  an earbud PSK.
- `PSKREF` kind `0x02` makes the earbud use the slot's PSK as the HKDF salt and its static fingerprint in
  `kc_transcript`.
- Only rows delivered with a hardware proof of possession may be used: the admin `provision-exclusive` v2 path, or
  `provision-sovereign` once it carries `txn_id`, `server_nonce` and the expected PoP (gap noted by the review:
  `cmd/bcrypto-lite/main.go:12975-13013` enqueues sovereign rows without them). The epoch statement of those rows MUST
  be checked against a pinned server key, never a key from the frame (gap S-2).

---

## 6. Key schedule in the earbud

Nothing in this section is new cryptography. Each formula is the one of the cited section, computed in the earbud
instead of the phone. The KAT of §13 pins the bytes.

### 6.1 Inputs of a round

| Input | Origin |
|---|---|
| ML-KEM-1024 key pair (offerer) or encapsulation randomness (acceptor), X25519 ephemeral | earbud CSPRNG, per round |
| peer `pqcPub` or `ctPqc`, peer X25519 value | `PEER_OFFER` / `PEER_ACCEPT` |
| `callId`, `callIdL` (ASCII lowercase of the round-1 `callId`), role | `CALL_BEGIN` |
| `DTLSFP` own and peer | `CALL_BEGIN`, peer bundle (pinned at round 1) |
| CAPS9, CAPSX and EXTX of both bundles, adverts of both bundles | host, checked by §4.6 |
| PSK (salt) and its static fingerprint | `PSKREF`; the fingerprint is `SHA-256(psk)`, computed by the earbud |
| `relaySS`, `RELAYX` | `RELAY` mode `0x02` |
| `rekeyNonce`, `sasNonce` | earbud CSPRNG (caller); the peer's `rekeyNonce` (callee) |

### 6.2 Transcripts

OFFER_v6 and ACCEPT_v6 exactly as WIRE_SPEC §3.7, with these values for the earbud's own bundle: `signerIK32` = EK;
`epochId16` = 16 zero bytes; `LP(strongBox|∅)`, `LP(dualCurve|∅)` and the ciphertext counterparts = `0x0000`;
CAPS9 = the host's nine bytes with the second and third bytes (`sframeV1`, `vkeyV1`) set to `0x00`;
`ratchetV = 0x04`, `suiteId = 0x01`; `advEnc` as supplied; `LP(sasCommit)` = `0x0020 ‖ sasCommit` in round 1 and
`0x0000` otherwise. The earbud builds the peer's transcript with the verifier inputs of WIRE_SPEC §3.7 for its role.
`sigV6 = Ed25519(EK, OFFER_v6 | ACCEPT_v6)`. `offerBinding = SHA-256(OFFER_v6)`, `acceptBinding = SHA-256(ACCEPT_v6)`.

### 6.3 Session key

- Round 1, and every round of a call without `rekeyChainV1`: WIRE_SPEC §3.7.1,
  `sessionKey_E = HKDF(IKM = pqcSS ‖ x25519SS, salt = PSK bytes or "q-audion-hybrid-pqc-v1", info = "q-audion-session-key" ‖ acceptBinding_E, L = 32)`.
- Rounds `E ≥ 1` of a call that negotiated `rekeyChainV1` in round 1: PQC B13,
  `sessionKey_E = HKDF(IKM = pqcSS ‖ x25519SS ‖ ck_B, salt as above, info = "q-audion-session-key-c1" ‖ BE32(B) ‖ acceptBinding_E, L = 32)`,
  with `ck_X = HKDF-Expand(sessionKey_X, "qa-rekey-chain-v1" ‖ LP(callIdL) ‖ BE32(X), 32)` computed for every derived
  round and kept by the retention rule of B13. `rekeyChainV1` is negotiated iff both round-1 CAPSX contain it and
  `capsBindV1`.
- An all-zero X25519 output is `crypto_failure` (§5.8).

### 6.4 Key confirmation

- `kc_transcript` as WIRE_SPEC §3.7.1: `offerBinding_E`, `acceptBinding_E`, `LP(advEnc(initiator))`,
  `LP(advEnc(responder))` in received wire order, `u8(N)` with `N = 1` and the PSK's static fingerprint when a PSK was
  selected (else `N = 0`), `LP(mix_id) = 0x0000`, `ikInit` and `ikResp`. In an EP call `init` is the caller in every
  round (only the caller offers), so for the earbud of a caller `ikInit = EK` and for the earbud of a callee
  `ikResp = EK`.
- `ext_E` = `capsBindV1` in both bundles of the round. With `ext_E` the MAC input is `kc_transcript_x` of PQC §2.3 over
  `LP(CAPSX(OFFER_E)) ‖ LP(CAPSX(ACCEPT_E)) ‖ EXTX(OFFER_E) ‖ EXTX(ACCEPT_E)`.
- `K_kc = HKDF-Expand(sessionKey_E, "qa-kc-key-v1", 32)`; `kcMacInit = HMAC(K_kc, 0x01 ‖ T)`,
  `kcMacResp = HMAC(K_kc, 0x02 ‖ T)` with `T` the round's transcript hash above.
- The earbud returns `kcMacOwn` (its role's MAC) and `kcMacPeer` (the MAC the peer must send). Both values travel in
  clear on the signalling path once sent, so handing them to the host discloses nothing about `K_kc`; WIRE_SPEC
  §3.7.1 already lets a receiver compute the expected MAC at arming and keep only it. The host runs every rule of
  R-KCMAC-ROUNDS, R-KCMAC-ATOMIC, the windows, the re-send budget and R-COMMIT-KCMAC-DEVICE with these values.
- Confirmation in the earbud: `KCMAC_VERIFIED` with a MAC equal (constant time) to `kcMacPeer` of the round marks the
  round confirmed. A confirmed round moves the inner send pointer (§7.2), becomes a candidate chain base (B13) and
  starts the retention clocks of B13 and B14. A lying host can only make the earbud send under a key the peer does not
  hold yet, which silences the call; it cannot make the earbud use a key the host knows.

### 6.5 SAS (round 1)

- Caller earbud: `sasNonce` from the CSPRNG once per call, before it signs the round-1 OFFER;
  `sasCommit = SHA-256("qaudion-sas-commit-v6" ‖ LP(callId) ‖ sasNonce)`; at `ACCEPT_BOUND` it returns
  `B = acceptBinding ‖ sasNonce` and `SAS-KDF` of WIRE_SPEC §4 over the round-1 session key, `acceptBinding` and
  `sasNonce`; after that `sasNonce` exists only in the cached response (§4.4), erased with it (§6.7).
- Callee earbud: it stores the OFFER's `sasCommit` and its own `acceptBinding`; on `REVEAL` it runs steps 5 to 7 of
  R-COMMIT-CHECK and returns `SAS-KDF` on success.
- The host turns the 18 bytes into the six words of WIRE_SPEC §4 and never logs them (R-COMMIT-LOG).

### 6.6 Export to the host (one-way)

The earbud exports, per round, exactly the values of `EXPORT` (§4.5), and nothing else. They travel only in sealed
EPL records of an authenticated session (§4.3):

| Value | Formula | When |
|---|---|---|
| `m15_a2b`, `m15_b2a` | WIRE_SPEC §1.1: `HKDF(IKM = sessionKey_0, salt = "qaudion-srtp-salt-v1", info = "q-audion-srtp-master-v1:" ‖ callId ‖ ":a2b" / ":b2a", L = 32)`, with the exact `callId` bytes of `CALL_BEGIN`, not `callIdL`: this is the only export that keeps the case, while `kOut`, `kIn`, `ck_E` and `vconfKey_E` use the lowercase form (the `flows` vectors use a mixed-case `callId`, §13.1) | round 1 only, `RELAY` mode `0x01` (the M-15 sealer is installed once per call, W5) |
| `kOut_audio_o2a`, `kOut_audio_a2o` | PQC B4: `PRK_rel = HKDF-Extract("qaudion-relay-salt-v1", relaySS ‖ sessionKey_E)`, `kOut[audio][d] = HKDF-Expand(PRK_rel, "q-audion-relay-v1" ‖ LP(callIdL) ‖ LP("audio") ‖ LP(d) ‖ acceptBinding_E ‖ RELAYX, 32)` | round 1, and every rekey round under `relayRotV1`, `RELAY` mode `0x02` |
| `vconfKey_E` | `HKDF(IKM = sessionKey_E, salt = ∅, info = "voice-confidence-announce-v1\|" ‖ ASCII-lowercase(callId), L = 32)`, the key of the VCONF advisory (the label ends with a vertical bar, the byte `0x7C`, escaped in this table; Android `VoiceConfidenceAnnounceCipher.kt:55-62`; an empty salt and a null salt give the same HMAC key) | every round |

The kind `video` of `kOut` is never derived: an EP call has no video.

Never exported, never derived for export: `pqcSS`, `x25519SS`, `sessionKey_E`, `K_kc`, `ck_E`, `kIn` and the legacy
inner key, the ML-KEM and X25519 private keys, EK's private key, `ξ`. FrameCryptor keys (WIRE_SPEC §3.7.2, PQC B6) are
not derived at all. An EP call produces no call-derived message PSK (the persisted per-round message PSK of PQC B13
D17 does not exist in an EP call).

Why these are one-way: each exported value is an HKDF output whose PRK takes `sessionKey_E` as IKM (or as part of it),
under an info label that no other construction uses. Recovering `sessionKey_E` from an output needs an HMAC-SHA256
preimage, also for a host that knows `relaySS`, `RELAYX`, `callId` and the transcripts.

What this means for the protection level of PQC §6: the outer layer `ind` (`relayKemV1`) is independent of the inner
layer against everyone except the host, which holds the outer keys by design and none of the inner ones. The levels
and the `QA-PQLEVEL` tokens are reported as for any call (§11).

### 6.7 Erasure

Every erased secret is overwritten with CSPRNG bytes (never zeros, the WIRE_SPEC §3.7.2 R-SLOT rule) before release:

- ML-KEM decapsulation key and X25519 scalars of a round: right after the shared secrets are computed, or when the
  round is dropped.
- `pqcSS`, `x25519SS`: right after `sessionKey_E`. `sessionKey_E`: after `K_kc`, `ck_E`, the inner key and the exports
  are derived, except on the legacy inner path, where it is the inner key and lives in its receive slot.
- `K_kc`: after both MACs are computed.
- `ck_X`: by the retention rule of PQC B13.
- Inner receive slots: by PQC B2 and B14 (the previous slot 30 s after the current round confirmed, staged slots when
  their round fails, is refused or is dropped).
- `sasNonce`: caller, with the cached `ACCEPT_BOUND` of round 1, when round 1's KCMAC is verified (`KCMAC_VERIFIED`)
  or the call ends; the stored commitment and nonce of a callee after the REVEAL check.
- Cached responses (§4.4): when the context moves past their step.
- EPL session keys, `eE` and `ss`: when the session closes.
- At `CALL_END`, at the end of the link grace (§5.10), at the setup timeout (§4.4) and at boot: everything of the
  call. No call secret is ever written to NVS.

### 6.8 Randomness

All random values come from `psa_generate_random` (CRACEN): ML-KEM seeds and encapsulation randomness, X25519 scalars
(call rounds and EPL sessions), `sasNonce`, `rekeyNonce`, `nonceE`, the block filler, `ξ` and the hedged ML-DSA
randomness (phase 2). Deterministic
injection of these values exists only in test builds (§3.1).

---

## 7. Media

### 7.1 Frames the earbud sends

- Opus, 48 kHz mono, application VOIP, 20 ms frames, CBR, in-band FEC on, DTX off. Bitrate at most the ceiling of a
  120 B block (W-BLOCKSIZE: `blockBytes − 2` minus the safety margin); the firmware's current 40 kbps (100 B frames)
  fits.
- Block = `BE16(trueLen) ‖ Opus frame ‖ CSPRNG filler`, exactly 120 B. An encoder overshoot is sent as a block with
  `trueLen = 0` (the rule the phone code names `W-PADOVERFLOW`; normative here), never as a larger block and never
  dropped: the firmware drops it today (`qa_sealed_audio.c`), which breaks the constant rate.
- One block every 20 ms, also while muted, while the media gate is closed and while capture waits for its press
  (encoded silence in each case, §7.9, §7.10). Only `TX_PAUSE` stops the blocks (WIRE_SPEC §16.3: a held sender sends
  no frames at all).

### 7.2 Inner seal `innerSealV2` (PQC B2)

When both round-1 bundles carry `innerSealV2` and `capsBindV1`:

- `kIn["audio"][d] = HKDF(IKM = sessionKey_E, salt = "qaudion-inner-seal-salt-v2", info = "q-audion-inner-seal-v2" ‖ LP(callIdL) ‖ LP("audio") ‖ LP(d), L = 32)`.
- Nonce `0x02 ‖ dirTag(d) ‖ 0x01 ‖ 0x00 ‖ BE64(ctr)`, AAD `"qa-inner-v2" ‖ LP(callIdL) ‖ u8(dirTag) ‖ 0x01 ‖ BE32(E) ‖ BE64(ctr)`.
- Envelope `0x04 ‖ u8(E mod 256) ‖ BE64(ctr) ‖ BE16(ctLen) ‖ ct ‖ tag16`, `ctLen` including the tag. With a 120 B block
  the envelope is 148 B.
- One send counter per call for the earbud's direction, from 1, never reset (not on rekey, link resume or any other
  event).
- Send switch: round 1 from install; round `E ≥ 1` only after the round is confirmed (§6.4).
- Receive: the slots of PQC B14 (current confirmed round, previous round during its 30 s grace, staged rounds), the
  slot chosen by the envelope's epoch byte, one replay window of W = 1024 for the peer's direction for the whole call
  (check before the AEAD open, commit after). A frame whose `dirTag` is the earbud's own is dropped (reflection).

### 7.3 Legacy inner seal with the B1 nonce

When the peer's round-1 bundle lacks `innerSealV2` (an old build; the call is not refused, PQC §0.1 rule 1):

- Key: `sessionKey_E` itself (the key-use exception X1 of PQC §0.3).
- Nonce (PQC B1): `dirTag(own) ‖ 0x00 0x00 0x00 ‖ BE64(ctr_in)`, `ctr_in` per call from 1, never reset.
- Envelope `0x01 ‖ nonce(12) ‖ BE64(seq = ctr_in) ‖ BE16(ctLen) ‖ ct ‖ tag16`, byte for byte the envelope the platforms'
  codecs produce today (the Android `SealedAudioWire` and iOS `WireRelayFrameCodec` codecs that PQC B1 cites); the KAT of
  §13 pins it.
- Send switch as §7.2. Receive: the envelope has no epoch byte, so the earbud tries the live slots in the order
  current, staged (newest first), previous, and accepts the first that opens; no replay window on this path (PQC B1:
  the legacy path has none). Frames whose nonce byte 0 equals the earbud's own `dirTag` are dropped.

### 7.4 Envelopes on the host's legs

- Outbound: the host seals each `AUDIO_OUT` payload, unchanged, with its outer layer (`kOut` with the nonce
  `0x52 ‖ u8(epoch) ‖ dirTag ‖ kindTag(audio) ‖ BE64(ctrOut)` of PQC B4, or the legacy M-15 sealer), and sends it on the
  DataChannel `qaudion-audio` or on the WS `audio_frame` relay leg, one sealer set per call shared by both legs
  (PQC B3). Outer-off (B3 rule 3) carries the bare envelope on the DataChannel inside DTLS only.
- Inbound: outer open, then the first byte: `0x01` or `0x04` goes to the earbud as `AUDIO_IN` in arrival order while
  the media gate is open (§7.9; while it is closed the host discards them); `0x03` is the host's control lane
  (WIRE_SPEC §16); `0x02` (video) and anything else is dropped. Frames that arrive before the outer keys exist are
  buffered by the host, never forwarded raw (PQC B3 rule 2).
- The control frames HANGUP, NACK_REQUEST, OUTER_OFF, CALL_HOLD and CALL_HOLD_ACK have no inner layer (WIRE_SPEC §16.1,
  PQC D15): the host produces and consumes them; the earbud never sees them.

### 7.5 Frames the earbud receives

- Inner envelopes with blocks of 2 to 256 B: wire 30 to 284 B on the `0x04` path (28 bytes of header and tag) and 41
  to 295 B on the legacy `0x01` path (39 bytes); an envelope outside its path's range is dropped before the AEAD open
  and counted as an inner failure (`authFails`, §4.5). Opus frames of 20, 40 or 60 ms. The decoder buffer grows from
  960 to 2880 samples (+3,840 B RAM). A block with `trueLen = 0`, or with a `trueLen` larger than the block holds
  (`blockBytes − 2`), is a lost frame for concealment; the second case is also counted in `decodeFail`.
- Each counter is decoded at most once, on both paths: on the `0x04` path the replay window drops a duplicate before
  the open (§7.2); on the legacy path, which has no replay window (PQC B1), a duplicate opens again and the jitter
  buffer discards it after the open because its `seq` is already buffered or played (counted in `replayDrops`). The
  decoder takes the frames in counter order; a frame that arrives after its playout time is dropped and counted
  (`rxLate`). The `profileRx` vectors (§13.1) assume that every frame arrives before its playout time, so the decoded
  sequence is the counters in increasing order, each once, with every missing counter concealed.
- Basis in the firmware history: cherry-pick `e4aca5b` (length-aware unseal for 30 to 284 B, a silent frame on pad
  overflow, 284 B NSPE buffers) and `384527c` (loud decode failures) from `wip/audio-60ms-rx-2026-09-19`, and rework
  `3b18ef8` (60 ms decode) after the blockers its commit message lists. That branch's `AUDIO_PROFILE` characteristic
  `0xcb` is not adopted: the profile is the bundle tag `earbudEpV1`.
- Jitter buffer in the earbud: initial target one frame plus 20 ms, adapting between 40 and 200 ms, at most 400 ms;
  later frames are dropped and counted (`rxLate`). A lost frame is concealed with Opus PLC, or with the in-band FEC of
  the next frame when it is already buffered. Playout runs through the existing 20 ms TDM path in 20 ms slices.
- The NSPE limit of 160 B per sealed frame (`AL_SEALED_FRAME_MAX`) and the exact-148 B unseal check go.

### 7.6 Loss repair

Audio NACK (`audio-nack-v1`) is host-level: the host caches the final wire bytes of each outbound frame after the outer
seal and answers requests from that cache (PQC B12); it detects gaps in the peer's counter from the envelope headers
(the `0x04` envelope carries `ctr`, the `0x01` envelope `seq`, both outside the ciphertext) and requests them as today.
A resent lost frame passes the earbud's inner replay window once. Frames produced while the gate was closed or capture
waited for its press are encoded silence by construction, so the cache never holds audio captured before the gate
opened; inbound frames discarded under a closed gate are not requested again.

### 7.7 Hold, mute, volume and tones

- Local hold (CallKit `CXSetHeldCallAction`, Telecom `onHold`, a cellular call answered on the phone): the host sends
  `TX_PAUSE` and the `CALL_HOLD` frames of WIRE_SPEC §16.3; on resume it sends `CALL_HOLD` RESUMED, then `TX_RESUME`.
  `call-hold-v1` is therefore advertised in EP calls.
- Peer hold applied (WIRE_SPEC §16.4): the host sends `TONE_START` hold beep and `TONE_STOP` on RESUMED, hangup or
  expiry; the earbud plays the tone locally, never on the network.
- Mute: `MIC_MUTE` keeps the constant-rate blocks with encoded silence.
- Volume: `VOLUME` sets the earbud's speaker gain. `speaker_out_set_volume` is a weak no-op today (`stubs.c:44`) and
  must be implemented; the GATT characteristics MODE `0x50`, PTT `0x60` and VOLUME `0x80` are retired (§8.4).

### 7.8 Bandwidth

| Direction | Inner | Outer | Rate | Payload bit rate |
|---|---|---|---|---|
| earbud to peer | 148 B (`0x04`, 120 B block) | +28 B | 50 per second | 70.4 kbps |
| peer to earbud | 284 B (`0x04`, 256 B block) | +28 B | 16.7 per second | 41.6 kbps |

On the EPL the earbud sends about 168 B every 20 ms and receives about 304 B every 60 ms, record headers and the
16-byte record tag of §4.3 included, well inside a 2M PHY link with DLE 251.

### 7.9 Media gates in an EP call

The media gate of WIRE_SPEC §3.8.4 (the AND of DTLS check (b), the SAS hold of §3.8.6 for `sig_invalid`,
`identity_key_mismatch` and `identity_unresolved`, R-HELD-REKEY and the attach gates) stays a host decision, as in a
phone call. A phone applies it by disabling its local tracks and muting remote playout; in an EP call capture and
playout are in the earbud, so the host applies it with these EPL operations:

- Closed, the state of every context at `CALL_BEGIN`: the earbud encodes silence instead of the microphone (it keeps
  sending constant-rate blocks, as a disabled local track does) and plays nothing; the host discards inbound `0x01`
  and `0x04` envelopes instead of forwarding them as `AUDIO_IN`.
- Open: the host sends `MEDIA_CTRL` GATE open and starts forwarding `AUDIO_IN`. One command releases both directions
  together; there is no half-open state.
- Events that open it, all required: (1) DTLS check (b) passed, or the call runs on the WS relay leg where (b) does
  not apply (WIRE_SPEC §3.8.5); (2) no SAS hold applies, or the user confirmed the SAS that the hold waits for
  (WIRE_SPEC §3.8.6), which for a callee earbud is the end of the hold for an unknown caller; (3) the attach gates of
  the host's call path are open. A later reason to close (a hold, R-HELD-REKEY, a new hold reason in a rekey round)
  sends GATE closed; the next opening needs the same three conditions.
- The WIRE_SPEC rule that a FrameCryptor is never disabled as a gate has no counterpart: an EP call has no
  FrameCryptor.
- The gate is a host policy. A compromised host can open it (§1.4); the capture press of §7.10 does not depend on it.

### 7.10 Capture indicator and capture press

- Indicator, enforced by the firmware and not changeable by any EPL message: whenever the earbud starts capturing the
  microphone for a call context (also after a resume, a `TX_RESUME`, a `MIC_UNMUTE` or a gate opening) it plays a
  start cue (two rising tones of 150 ms, about −20 dBFS) and sets the capture LED pattern for as long as capture runs;
  while capture runs it plays a short low cue (one 80 ms tone, about −30 dBFS) every 60 s, counted from the most
  recent start cue: every start of capture (which plays the start cue) restarts the count, and any pause of capture
  (`MIC_MUTE`, `TX_PAUSE`, a closed gate, a link drop) stops it. Encoding silence (gate
  closed, `MIC_MUTE`, waiting for the press) is not capture: no cue, a distinct LED pattern. `EVENT` CAPTURE reports
  every change to the owner host.
- Capture press (owner decision OD-6 (b), 2026-11-17). The earbud captures the microphone of a call context only after
  a fresh press of its button in that call. The firmware enforces it and no EPL message can replace it:
  1. Every context has the flag `captureArmed`, false when the context is created. The earbud feeds the microphone to
     the encoder only while `captureArmed` is true, the media gate is open (§7.9), no `MIC_MUTE` and no `TX_PAUSE`
     applies and the link is up; in every other case it encodes silence (§7.1).
  2. `captureArmed` becomes true on a short press (under 500 ms, the short-press column of §9.14) that began after the
     context was created, while the context exists, at the instant the press acts: an EP context gives the double
     press a meaning, so that is `DOUBLE_PRESS_GAP` (400 ms) after the press's release, when no second press started
     in that gap (§9.14). The press is consumed by this function: it is not exported as
     `EVENT` BUTTON and does not refresh the FW-C2 timestamp (§9.14). A double press and a long press keep their
     meaning in this state (§9.14) and never arm capture.
  3. Answer press. When the earbud exports a short press in the ringing state to the ring owner (§9.14, §9.13) it
     also remembers the host key of the ring owner and the time of the press. A `CALL_BEGIN` with role callee from a
     session of that host key, received at most `ANSWER_PRESS_WINDOW = 10 s` after that press, creates its context
     with `captureArmed` already true, and the memory is cleared. The memory is also cleared by the expiry of the
     window, by a `CALL_BEGIN` from another host key or with role caller, by the start of a new ring and by a reboot.
     An incoming call answered on the phone's screen has no answer press: its context waits for a press after its
     creation. The window covers the time the host needs between the press and `CALL_BEGIN` (it builds the call's DTLS
     certificate first, §5.3 step 2, and the request timeout of §4.4 is 5 s).
  4. `captureArmed` belongs to one context and is never carried to another. Once true it stays true until the context
     ends: through hold and resume (§7.7), rekey rounds, mute and unmute, gate changes and a link resume (§5.10, where
     capture only pauses while the link is down).
  5. Report. Right after `CALL_BEGIN_OK` and right after every `RESUME_RESULT` ok the earbud reports the current
     `EVENT` CAPTURE pair. While `captureArmed` is false that pair is state `0x00` with reason `0x02`, "waiting for the
     capture press", and it is the only report of that condition: the host takes it from nothing else (§9.9). When
     `captureArmed` becomes true the earbud reports the reason that still keeps it silent (`0x01` gate closed, `0x03`
     TX_PAUSE, `0x04` MIC_MUTE) or, when none does, state `0x01` with reason `0x00` and plays the start cue. When
     several reasons apply at once the earbud reports the first of `0x02`, `0x01`, `0x03`, `0x04`. `EVENT` STATE
     (§4.5) is not changed by the press: a context waiting for its press is in the call state its round gives it
     (handshake or active).
- Why: an enrolled host that is malicious or compromised can create a context with a peer it controls (it then holds
  the inner keys of its own fake peer) and would otherwise get the earbud's microphone with nothing on the phone's
  screen (§1.4). The press ties capture to a physical action of the wearer in that call, which software cannot
  produce (no EPL message arms capture, §4.5) and which a host cannot reuse from an earlier call (rule 4); the
  indicator makes capture audible and visible.
- Limit, stated: a host that creates a context at the very moment the wearer presses the button for another reason
  gets capture. The start cue and the LED make that audible and visible; the press is not a proof of consent to a
  particular call.

### 7.11 Inner-layer failure in an EP call

The host cannot see inner failures: outer frames open fine while the earbud may be failing every inner open (a missing
slot, an epoch byte collision, a desynchronised round). The earbud reports them with `EVENT` INNER_FAIL at once and
with `AUDIO_STATS` every 2 s while `authFails` grows. Host rule:

- Caller host: an INNER_FAIL is a recovery trigger in the sense of PQC B13 (D12). It requests a rekey round, subject to
  R-OFFERSPACING and to the deferral before the round-1 KCMAC; triggers that fire while a round is pending coalesce.
- Callee host: no rekey (R-OFFERER: the callee never starts one); it relies on the caller's own triggers.
- Both: show the local state "Earbud audio not decoding" while failures continue and log `QA-EARBUD ev=inner_fail`
  (§11.1). This rule never ends a call; the user can hang up, and the peer's watchdogs are unchanged.

---

## 8. Versioning and anti-downgrade

### 8.1 PROTOCOL_VERSION (`0xa9`)

The characteristic returns `0x02` in every firmware image of this design: the GATT family of WIRE_SPEC §7, without the
retired relay dialect, which is removed from every profile (§8.4). `0x01` was that dialect (`qaudion_gatt.c:403-404`).
Whether an image carries the endpoint is said by `EP_INFO` (§8.2): the CI and bench images expose it and register the
EPL on PSM `0x00B5`; the authoritative and production images, which carry no EP code (OD-4, §10.1), expose neither.
Reading it still requires an encrypted link.

Host decision, made at every connection before any other characteristic is used, and again after Service Changed
(§8.4); a decision is never kept across a firmware change:

| PROTOCOL_VERSION read | `EP_INFO` characteristic | Host decision |
|---|---|---|
| `0x01` or lower, or absent, unreadable or not one byte long | any | refuse: the host uses no other characteristic, opens no channel, places no EP call and shows "Earbud firmware too old. Update the earbud." |
| `0x02` | absent from the GATT database | no endpoint: the host uses only the characteristics that WIRE_SPEC §7 keeps besides `EP_INFO` (DIAG, ATTEST_INFO, ATTEST_POP, ATTEST_PQ, KEY_IMPORT, PAIR_BEGIN, PAIR_RESP, PAIR_FIN, PSK_LIST), opens no EPL and places no EP call; every call runs on the phone (§5.1, §5.11) and the earbud settings say "This earbud's firmware has no call endpoint." |
| `0x02` | present | endpoint per `EP_INFO`: the record checks of §8.2 and the version checks of §8.3 apply; a record or a version they refuse makes the earbud "no endpoint" (the row above) with the notice they name |
| above `0x02` | any | refuse, as in the first row, with "Update the Q-Audion app to use this earbud." |

Unreadable, in the first row, means that the read fails on a link encrypted under a completed bond (an ATT error, or
no answer within the platform's GATT timeout). A read that fails because the bond is not complete (insufficient
authentication or insufficient encryption, a pairing still running, cancelled or failed, §9.2) is a bonding failure,
not a decision: the host uses no characteristic, shows the bonding step of §9.2 again and decides after the next
completed bond. It never shows "Earbud firmware too old" for a bonding failure.

### 8.2 EP_INFO (`0xd0`) and the Device Information Service

New read-only characteristic `f2c0aaaa-bcc0-4001-8000-0000000000d0`, read permission ENCRYPT, appended last in the
service's attribute table (the hard-coded attribute indices of `qaudion_gatt.c` require new characteristics at the
end). The same record is the `EP_INFO` of `EP_HELLO`.

```
EP_INFO = u8(infoVersion = 0x01)
        ‖ u8(protocolVersion = 0x02)
        ‖ u8(fwMajor) ‖ u8(fwMinor) ‖ BE16(fwPatch)
        ‖ gitSha[4]                    first 4 bytes of the firmware commit
        ‖ u8(buildProfile)             0x01 CI, 0x02 bench, 0x03 authoritative, 0x04 production
        ‖ u8(board)                    0x01 nRF54LM20 DK (nrf54lm20b/cpuapp); PCB values are assigned at bring-up
        ‖ BE32(capsBits)
        ‖ BE16(eplPsm = 0x00B5) ‖ BE16(eplMaxRecord = 4096)
        ‖ u8(maxOwnAdverts = 64) ‖ u8(maxPeerAdverts = 255) ‖ u8(maxHosts = EP_MAX_HOSTS = 4)
        ‖ u8(ekState)                  0x00 no EK, 0x01 EK present
        ‖ earbudId[32]
        ‖ epEdPub[32]                  32 zero bytes when ekState = 0x00
```

88 bytes. A reader accepts a longer record and ignores the bytes beyond the fields it knows (growth by appending
only). `capsBits`: bit 0 `sigV6` (always 1), bit 1 `sigHybridV1` with the earbud's own ML-DSA key (phase 2), bit 2
`innerSealV2`, bit 3 legacy inner seal with B1, bit 4 `rekeyChainV1`, bit 5 `kOut` export, bit 6 M-15 export, bit 7
receive of 60 ms / 256 B, bit 8 hw_only PSKs, bit 9 reserved (the revision-1 peer pin table, removed), bit 10 link
resume, bit 11 host-anchored `sigHybridV1` (phase 1, §3.9), bit 12 capture press required (OD-6 (b), §7.10: always 1
in an EP build; a host that reads 0 does not open an EP call, §8.3); other bits zero.

Record checks. An `EP_INFO` characteristic that is unreadable in the sense of §8.1 counts as an invalid record. A
record shorter than 88 bytes, or whose `infoVersion` is `0x00`, or whose `protocolVersion` is not
`0x02`, is invalid; a record whose `infoVersion` is above `0x01` describes an EPL that this host does not know (§8.7).
Read over GATT, either makes the earbud "no endpoint" (§8.1), with "This earbud's firmware is not supported by this
version of the app."; received in `EP_HELLO`, either makes the host close the channel.

The Device Information Service (`0x180A`, open read) is already enabled at `74a43d2` (`CONFIG_BT_DIS=y`, with
`CONFIG_BT_DIS_FW_REV=y` and Model Number String `Q-Audion Earbud`, `config/prj.conf:175-179`, `firmware/prj.conf:311`).
EP builds set its Firmware Revision String to `<major>.<minor>.<patch>+<git8>` and add the Hardware Revision String
= the board. The machine-readable source of truth is `EP_INFO`.

### 8.3 Minimum versions and rollback

- Each host release compiles in `EP_MIN_PROTOCOL = 0x02` and a minimum firmware version (`fwMajor`, `fwMinor`,
  `fwPatch` of `EP_INFO`). A PROTOCOL_VERSION below `EP_MIN_PROTOCOL` is refused (§8.1). An `EP_INFO` firmware version
  below the minimum makes the earbud "no endpoint" (§8.1): the host does not open the EPL and shows "Earbud firmware
  too old. Update the earbud to use it for calls."; the characteristics of the no-endpoint row of §8.1 (DIAG,
  attestation, KEY_IMPORT, FE-5 pairing, PSK_LIST) stay available.
- A host does not open an EP call when `capsBits` bit 12 (capture press required, §7.10) is clear: such a firmware does
  not enforce the capture press and the host could not state its UI rule (§9.9). It treats it as a firmware below the
  minimum (rule confirmed by the owner on 2026-11-17).
- A host keeps, per `earbudId`, the highest firmware version it has seen and treats a lower one as "no endpoint"
  (§8.1) with "Earbud firmware was downgraded". MCUboot keeps the image key (Ed25519, offline) and, decided on
  2026-11-17 (owner decision 4 and the anti-rollback decision), anti-rollback by the software version check: the
  bootloader refuses an image whose version is lower than the installed one (`CONFIG_MCUBOOT_DOWNGRADE_PREVENTION`). The hardware security counter in OTP
  (`SB_CONFIG_MCUBOOT_HARDWARE_DOWNGRADE_PREVENTION`; it burns OTP words and cannot be undone, and MCUboot offers it and
  the software check only as a choice) is not enabled by this document: it is decided later, together with the factory
  flow. Limit, stated: a software check can be undone with a chip erase (ERASEALL); that erase destroys EK and the
  host table (§3.8), so the unit comes back as a new endpoint that must be enrolled again. Gap O-1:
  `config/mcuboot.conf` must be wired to the LM20B sysbuild instead of the RSA default of `sysbuild.conf`.

### 8.4 Removal of the retired dialect

Removed in the same release as PROTOCOL_VERSION `0x02`, from every firmware profile, the authoritative and production
profiles included (OD-4 as decided in the second round of 2026-11-17, §14; hard switch, WIRE_SPEC §6):

| Repo | Removed |
|---|---|
| firmware | HSINIT `0x10`, HSRESP `0x20` (including the `0xFE` fragment), HSFIN `0x30`; CALL_STATE `0x40` and its two numberings; MODE `0x50`, PTT `0x60`, DEEPFAKE_SCORE `0x70` (replaced by `EVENT` VOICE_SCORE), VOLUME `0x80`; SAS_ENTROPY `0xb0` and `sas-words-v1`; MEDIA_KEY_INSTALL `0xc4` and the `key_store` BLE session key path; FP_ADV `0xc8` and KC_CONFIRM `0xc9` (the schema:4 diagnostic layer); the schema:3/schema:4 session KDF (`info_v3`, `info_v4`, ct_bind as a session input, the `qa-psk-sel-v1` negotiation digest); the 148 B sealed audio v2 frame and its exact-length unseal; the AudioLink server on PSM `0x00B3`; the BAP CIS consumer of the sealed TX queue |
| Android | `EarbudSecureMediaProvider` relay jobs, `FwPduCodec`, `HandshakePduCodec`, the `BleLeAudioTransport` call plane, `EarbudHandshakeResponder`, the EARBUDPDU, EARBUDMKD and FPSET piggy-backs, `EarbudMediaKeyDelivery`, `deriveSessionKeyV4`, the `earbud-relay-v1` constant and the `earbudPaired` capability gates |
| iOS | `EarbudFwPduCodec`, `EarbudHandshakeResponder`, `EarbudHsinitCounterAllocator`, `EarbudCounterpartyService`, the EARBUDPDU, EARBUDMKD and FPSET parsing, `CallCapabilities.earbudRelayV1` and the `earbudInCall` profile input |
| server | the earbud KMS `session_v4`, `kc_mac` and `fp_adv` derivations used only by the retired call path, and `POST /api/v1/kms/earbud-kc-mac`; the KMS key wrap, `KEY_IMPORT`, PoP and FE-5 pairing stay |

Kept unchanged: ATTEST_INFO `0xc0`, ATTEST_POP `0xc1`, ATTEST_PQ `0xc2`, KEY_IMPORT `0xc3`, PAIR_BEGIN, PAIR_RESP and
PAIR_FIN `0xc5`-`0xc7`, PSK_LIST `0xca`, DIAG `0x90`, PROTOCOL_VERSION `0xa9`. Removing characteristics changes the
GATT database hash; the firmware indicates Service Changed and bonded hosts rediscover. Both hosts MUST handle it on a
bonded earbud (Android `onServiceChanged`, iOS `peripheral(_:didModifyServices:)`), and the acceptance of §13.4 tests
the upgrade of a bonded unit on each platform, because a stale GATT cache would hide `EP_INFO`.

### 8.5 What replaces WIRE_SPEC §3.7.3

The retirement of the relay handshake stays: no client advertises or honours `earbud-relay-v1`, and no signalling field
weakens §3.7 or §3.8. The section is extended with the earbud endpoint rules: an earbud is a v6 endpoint like any
other, R-EP-VERIFY, R-EP-PROFILE, the tag rules of §2.4 and the audio-only rules. The exact text is
Appendix A; the new §7 is Appendix B; WIRE_SPEC.md carries both byte for byte (§17).

### 8.6 Peers without earbud support and the release gate

- A client that predates R-EP-VERIFY holds media pending the SAS on every EP call (unknown signer key, R-IDENTITY); a
  client that predates R-EP-PROFILE still decodes 20 ms blocks on the paths checked (Android's legacy receiver is
  block-size agnostic; iOS `QAudionEngine.swift:557-590`). A client without `capsBindV1` or `innerSealV2` gets the
  legacy inner seal (§7.3) and no CAPSX binding of `earbudEpV1`. Nothing breaks open; every such call is degraded.
  The acceptance of §13.4 runs an EP call against a build of the previous release of each platform.
- Release gate: no host build enables EP calls until Android, iOS, Desktop and the web app of the same release train
  ship R-EP-VERIFY and R-EP-PROFILE. Before launch this is the hard-switch rule of WIRE_SPEC §6.

### 8.7 Later versions

A change of the earbud's media profile or of the audio-only rules is a new tag (`earbudEpV2`). A change of the EPL is
a new `hostProto` and `infoVersion`, both checked at session start, and new domain strings of §4.3. A new EPC format
is a new domain string.

---

## 9. Host requirements (Android and iOS)

### 9.1 Discovery

The earbud advertises ASCS `0x184E` with the name `Q-Audion Earbud` in the scan response; the 128-bit service UUID is
not advertised (`ble_gap.c:94-100`). Hosts scan by name. A bonded earbud advertises with a filtered accept list, so a
second host (for example the user's iPhone after an Android phone) needs the earbud in pairing mode, opened with the
button (the 60 s window of `ble_gap_force_pairing_mode`); the host app explains that step.

### 9.2 Bonding

LESC numeric comparison gated by FW-C2: the earbud registers DisplayYesNo only so that the stack runs numeric
comparison, has no display, and confirms the comparison when the user pressed its button within the previous 30 s
(`ble_gap.c:667-700`, `button_handler.c:451-471` at `74a43d2`). The user never compares a number, so the bond is
nominally MITM-protected only: it gives confidentiality against passive observers, and an active attacker present at
the first pairing may hold the link keys. This design relies on the bond for nothing else; the EPL session protocol
of §4.3 and the enrolment code of §3.4 carry the security. The host app shows "Press the earbud button, then confirm
on the phone". Android waits for the bond for at least 60 s (the diagnostics flow waits 20 × 1 s today, too short for
the button step). On iOS the system pairing dialog appears at the first encrypted read, which is `PROTOCOL_VERSION`
(the first read of §9.3); a read that fails while that pairing runs is a bonding failure, not an unreadable
characteristic (§8.1). Every EP
firmware profile sets `CONFIG_BT_BONDING_REQUIRED=y` (the root `prj.conf` has `n`). Only presses that the gesture
table of §9.14 leaves unconsumed refresh the FW-C2 timestamp.

### 9.3 Version checks

Before anything else: read `PROTOCOL_VERSION` and, when the service has it, `EP_INFO`; apply the decision of §8.1 with
the checks of §8.2 and §8.3; show the result in the earbud settings.

### 9.4 L2CAP

- Android: `BluetoothDevice.createL2capChannel(0x00B5)` on the bonded device. EP hosting requires API 29 or later;
  below it the feature is hidden (the app's `minSdk 24` is unchanged). `createInsecureL2capChannel` MUST NOT be used,
  which also removes the open question whether the firmware's L4 server accepts it.
- iOS: `CBPeripheral.openL2CAPChannel(0x00B5)` (iOS 11 or later; the deployment target is 16.0). The input and output
  streams run on a dedicated thread with its own run loop; writes respect `hasSpaceAvailable`.
- Both parse records from the stream (§4.2) and never assume one record per read.

### 9.5 Background and OS call integration

- iOS: `UIBackgroundModes` already contains `voip`, `audio` and `bluetooth-central` (`Info.plist:174-183`). An EP call
  is a CallKit call like any other. The app MUST NOT start microphone capture or play call audio on the phone; it keeps
  the audio session as CallKit requires. That CallKit keeps an EP call alive in the background with no audio I/O on
  the phone is an assumption, measured in phase 0 (a locked phone, 10 minutes, §12.1) and repeated in the acceptance.
  Failure behaviour if it does not hold: iOS suspends the app, the EPL stalls, the earbud's link grace expires and the
  call ends with `endpoint_lost` (§5.10); the host logs the suspension at its next launch. If phase 0 shows that
  outcome, iOS hosting needs a different keep-alive (for example a silent audio unit kept by the app), which is then
  specified before phase 1 ships on iOS.
- Android: the call stays a self-managed ConnectionService call. Its foreground service declares the type
  `connectedDevice` in addition to `phoneCall`, and holds no microphone capture during an EP call. GATT and the L2CAP
  socket keep working with the screen off under that service; this is to be verified on the target phones.

### 9.6 Audio routing and exclusivity

- The host MUST NOT route OS call audio (SCO, LE Audio unicast) to the earbud during an EP call. Android keeps the
  exclusion of Q-Audion devices (`BluetoothHeadsetController.kt:316-340`, `AnswerRoutePolicy.kt:43-50`,
  `OutgoingStartRoute.kt:55-62`). iOS has no LE Audio route code; it MUST NOT select the earbud as an audio route.
- Firmware: during an EP call the EPL TX path is the only consumer of the sealed TX queue. Today both the AudioLink pump
  and the BAP CIS thread drain `nsc_get_encrypted_frame` (`audio_link_channel.c:437-438`, `ble_audio.c:385-399`), so a
  phone that opens an LE Audio stream could steal sealed frames. During an EP call the earbud refuses ASE enable
  (ASCS response "insufficient resources", `EVENT` LE_AUDIO_REFUSED), refuses the MODE CELLULAR switch, and releases
  LE Audio streams that run at `CALL_BEGIN`; `CALL_BEGIN` answers `busy` while a cellular call carried by LE Audio is
  active. After `CALL_END` LE Audio and the cellular passthrough behave as today. They stay in EP builds (owner decision
  OD-5, 2026-11-17); the rules above are what makes that safe.

### 9.7 Cellular calls during an EP call

The earbud's CCP client reports an incoming cellular call as `EVENT` CELLULAR. The phone OS rings on the phone. If the
user answers on the phone, the OS holds the Q-Audion call and the local hold of §7.7 runs; the cellular audio stays on
the phone, because the earbud does not enter CELLULAR mode while a call context exists. While a context exists the
earbud's button never reaches the CCP handlers (§9.14), so a press cannot answer or end the cellular call on the
earbud. Resuming lifts the hold.

### 9.8 Group calls, video, screen share and handover

- Group calls: never with the earbud as endpoint. A host MUST NOT promote an EP call to a group call. A promotion
  received in an EP call (the `<callId>|GRPPROMO:` token of `docs/GROUP_CALLS_V2.md` §2.7, Android
  `GroupPromotionToken.kt`, iOS `GroupPromotionToken.swift`) is not joined: the host answers the group invitation with
  `group_call_decline` (`docs/GROUP_CALLS_V2.md` §2.6) and shows "Group call invitation declined: end the earbud call
  to join on the phone". A remote peer whose peer bundle carries `earbudEpV1` disables its promote-to-group control
  for the call, as it disables video. A group call started while an earbud is connected runs on the phone's audio, and
  group media is never routed to the earbud.
- Video, screen share and every mid-call upgrade (WIRE_SPEC §8): refused. The host advertises no video capability
  (§2.4), sends no `call_upgrade_request`, and declines a received one by the decline path of WIRE_SPEC §8.4. A remote
  peer whose peer bundle carries `earbudEpV1` disables its video control.
- Hold: supported (§7.7).
- Handover between the earbud and the phone during a call: not supported. A SAS pins round 1's signer key and refuses a
  round signed by another key (R-COMMIT-SAS). "Continue on the phone" ends the call and redials it as a phone call.
- Left and right earbuds: one earbud is the endpoint of a call; the L/R interlink stays out of scope (fail-closed stubs
  today).

### 9.9 Host UI

- The in-call badge "Audio encrypted on your earbud" appears only while the EP call carries audio (exports installed,
  gate open and `AUDIO_OUT` flowing). The current Android badge, shown whenever a bonded earbud exists although audio
  is software (`InCallScreen.kt:3119`, gap AP-5), must follow this rule.
- Capture press (OD-6 (b), §7.10). The host shows the text "Press the earbud to start talking" (localised) while the
  last `EVENT` CAPTURE of the context it owns is state `0x00` with reason `0x02`, from `CALL_BEGIN_OK` until the first
  `EVENT` CAPTURE with another reason or the end of the call, and shows it in no other situation: not after the press,
  not in a call whose context started armed (answered on the earbud within the window), not from a guess of its own.
  It offers no phone-side control that starts capture; the user who does not want to press can end the call and redial
  it on the phone (§9.8). After a link resume the text follows the report that comes with `RESUME_RESULT`.
- SAS display, safety-code confirmation and every warning are those of a phone call.
- An earbud settings screen: enrol (with the enrolment code of §3.4), remove, the list of enrolled hosts from
  `HOST_LIST` with a remove action for each, firmware version and profile, battery, endpoint fingerprint, reset
  instructions.
- A message for every fallback of §5.11 and for the decisions and version checks of §8.1 to §8.3.

### 9.10 Remote peer UI

As §3.7 and §3.10: "Audio endpoint: <contact>'s Q-Audion earbud (reported by their device)", "development unit" when
the endpoint's profile is not production, the endpoint in the contact screen, the neutral notice for a new earbud,
the warning for a revoked one, no video control and no promote-to-group control in such a call. No remote string says
the earbud protects the call until endpoint attestation exists (gap S-3).

### 9.11 iOS specifics

The host role is a new iOS feature: EPL client, enrolment, CallKit integration and the EP call path. The compile gate
`QAUDION_EARBUD` (owner decision #283, `project-earbud.yml`) keeps it out of store builds until the owner ships it;
shipping needs the App Store usage text for Bluetooth to mention the earbud (`NSBluetoothAlwaysUsageDescription` speaks
of the mesh and in-person exchange only). The KMS relay fixes of gap AP-3 (big-endian offsets, PoP inputs first, service
UUID `...0001`, a connected proxy) and the DIAG read polling are prerequisites of phase 1b, not of phase 1.

### 9.12 Android specifics

Replace the hard-wired probes (`CallModule.kt:496`, `:686`) by a real one (a bonded earbud, an authenticated EPL,
`EP_INFO` protocol `0x02`) and a new EP media provider; remove the retired plane of §8.4 together with the tests that
cover it. `EarbudHandshakeRetiredInvariantTest` keeps asserting that the retired symbols stay unreachable; the EP path
uses none of them. The FE-5 diagnostics flow's SAS bypass (`EarbudDiagViewModel.kt:399`) is unrelated to EP calls and
must not be reused by them.

### 9.13 Several hosts connected at once

The firmware allows three simultaneous connections (`CONFIG_BT_MAX_CONN=3`, `config/prj.conf:158`,
`firmware/prj.conf:288`) and up to `EP_MAX_HOSTS` = 4 enrolled hosts of one account (OD-2). The server rings every
device of the user, so two enrolled phones can both be connected when a call arrives. Rules:

- Owner host. A call context belongs to the host whose session sent `CALL_BEGIN` (its `hostEdPub`). Every message
  that names the context (`h ≠ 0`: the round messages, `KCMAC_VERIFIED`, `ROUND_DROP`, `MEDIA_CTRL`, `CALL_RESUME`,
  `CALL_END`) is accepted only from a session of that host key, otherwise `not_owner`. Events of the context go only
  to that host. A second `CALL_BEGIN` while a context exists gets `busy`.
- Ring owner. With no context, the first host whose `TONE_START` incoming ring arrives owns the ring until its
  `TONE_STOP`, its session closes or 90 s pass; another host's ring request gets `busy`, and that host rings on the
  phone only. The answer gesture is exported only to the ring owner, which answers by `CALL_BEGIN` first and
  `call_accepted` after `CALL_BEGIN_OK` (§5.3). A sibling phone that loses the race leaves by the existing
  `answered_on_other_device` path of WIRE_SPEC (R-COMMIT-SIBLING, `call_cancel`); it never claimed the call for the
  earbud.
- Idle events. With no context and no ring, `EVENT` BUTTON goes to the host whose session authenticated most recently.
- An `UNAUTH` session is replaced by a new channel on the same connection and closed after its 5 s timeouts (§4.1,
  §4.3), so a bonded app that never authenticates cannot block the host.

### 9.14 Button gestures

The firmware's current handlers route a short press to the CCP client (answer when INCOMING, terminate when ACTIVE)
or to the retired PTT toggle, route a long press (at least 2 s) to "decline" when INCOMING and to the 60 s pairing
mode otherwise, ignore presses of 500 ms to 2 s, and record a FW-C2 timestamp on every debounced press
(`button_handler.c:236-285`, `:337-345` at `74a43d2`). An EP build replaces that routing with the table below. Each
press is consumed by exactly one row; a consumed press never refreshes the FW-C2 timestamp of another function.

| Earbud state | Short press (< 500 ms) | Double press | Long press (≥ 2 s) | Hold ≥ 3 s (confirm gesture) |
|---|---|---|---|---|
| Confirm window open (§3.4, `UNENROLL`) | cancels the window | ignored | nothing until 3 s | confirms, if it began after the prompt |
| EP ringing (a ring owner exists) | `EVENT` BUTTON short to the ring owner (answer); the earbud remembers this press for the capture press of §7.10 | ignored | `EVENT` BUTTON long to the ring owner (decline) | as long press |
| EP context, capture waiting for its press (`captureArmed` false, §7.10, OD-6 (b)) | arms capture (§7.10) and reports `EVENT` CAPTURE; not exported as `EVENT` BUTTON; no FW-C2 timestamp | `EVENT` BUTTON double | `EVENT` BUTTON long (hangup) | as long press |
| EP context with `captureArmed` true (capturing, held, muted or gate closed) | `EVENT` BUTTON short (the host maps it to mute toggle) | `EVENT` BUTTON double | `EVENT` BUTTON long (hangup) | as long press |
| No EP context, cellular call INCOMING or ACTIVE (CCP) | as today: accept or terminate | ignored | as today: decline when INCOMING; nothing when ACTIVE | as long press |
| Idle (no context, no ring, no cellular call) | `EVENT` BUTTON short to the idle host; FW-C2 timestamp | ignored | 60 s pairing mode, opens the 180 s enrolment window of §3.4 step 3 (b); FW-C2 timestamp | as long press |
| Power-on with the button held 10 s | | | | factory reset (§3.8) |

Rules the table implies: while a context or a ring exists, no gesture enters pairing mode and none reaches the CCP
handlers; a confirm window is never open while a context, a ring or a cellular call exists (§3.4); the retired PTT
toggle is gone. Medium presses (500 ms to 2 s) stay ignored. The gesture-to-event mapping is pinned by the timed
traces of §13.1.

Classification of a press. A press is classified at its release, by its duration: under 500 ms short, 500 ms to under
2 s medium (ignored), 2 s to under 3 s long, 3 s or more a hold (the confirm gesture inside a confirm window, a long
press elsewhere). Nothing acts when a threshold is reached during a press, except the factory reset, which acts when
the button has been held 10 s during power-on. A double press is two short presses whose second starts at most
400 ms after the first one's release (`DOUBLE_PRESS_GAP = 400 ms`). In a state where the table gives the double press
a meaning (an EP context) a short press acts only when 400 ms have passed after its release without a second press,
that is 400 ms after its release; in every other state it acts at its release. When a second press starts within the
400 ms and is not short (medium, long or a hold), the first press does not act at all, and the second press is
classified and acts by itself, as if it were alone. A confirm gesture counts only when it starts after the prompt and is
released before the confirm window ends; a hold still in progress when the window ends gives `no_press`.

---

## 10. Firmware requirements

### 10.1 Profiles

- Bench overlay (`config/bench_dev.conf` of PR #5), the dev-board target of owner decision (2). It already disables
  APPROTECT and sets `CONFIG_QA_ALLOW_UNBOUNDED_NSC=y` (its points 1 and 2: without them a locked unit loses SWD until
  ERASEALL, which also destroys EK, and every pointer-taking secure call fails closed). EP builds add DLE 251 and
  bonding required. Restricting INF logging (its point 3) to the EP modules is a PREREQUISITE of phase 1 on the bench,
  not an option: it frees 10,144 B (measured, `feat/ep-phase0` `1b759cc`), without which the bench keeps at most
  3,352 B after phase 1 on the estimate of §12.2 and has no room for phase 2.
- CI profile (`config/prj.conf`): the same EP features under the GA checks of `tools/check_config_flags.sh`, which
  hard-fail `CONFIG_QA_ALLOW_UNBOUNDED_NSC=y` (`check_config_flags.sh:277`; the profile sets it `n`,
  `config/prj.conf:421`). The EP path therefore must not depend on that escape hatch (§10.2). Until the on-target EP
  self-test of §13.4 (item 12) passes on a CI-profile image, the claims of §12 for the CI profile mean "builds and
  fits", not "works".
- Authoritative profile (`firmware/prj.conf`) and production profile (owner decision OD-4, 2026-11-17): no EP code is
  built into them and no RAM cut is made for it now (1,128 B free today; the cuts of §12.3 are decided with the PCB
  profile). Until the PCB profile exists, EP calls exist on the CI and bench profiles only. The retired relay plane
  (§8.4) is removed from these profiles too, in phase 1 (second round of 2026-11-17, §14): an image of these profiles
  reports PROTOCOL_VERSION `0x02`, exposes no `EP_INFO`, registers no PSM `0x00B5` (and no `0x00B3`) and carries none
  of the retired characteristics; a host reads it as "no endpoint" (§8.1) and runs every call as a phone call (§5.1,
  §5.11). A firmware CI check (confirmed by the owner on 2026-11-17) fails when an EP symbol is linked into an
  authoritative or production image (the counterpart of the check of §10.2). The `buildProfile`
  values `0x03` and `0x04` stay in the EPC and `EP_INFO` formats (§3.3, §8.2) for the PCB profile, and verifiers
  accept them from the first release.

### 10.2 Secure code without veneers, and without the NSC pointer check

In the single image no veneer exists: `CONFIG_BUILD_WITH_TFM` is dropped by Kconfig, the image has no `.gnu.sgstubs`
section and no `-mcmse` flag (spike). The "sgstubs full" notes in `secure_services.c` describe a TF-M build this tree
does not produce.

The existing `nsc_*` wrappers of `secure_services.c` call `nsc_validate_ptr()`, which has no NSPE bounds symbols in a
single image and fails closed unless `CONFIG_QA_ALLOW_UNBOUNDED_NSC=y` (`secure_services.c:96-170`); the bench
overlay says that without it "attestation, KEY_IMPORT, FE-5 pairing and the call path are dead"
(`config/bench_dev.conf:30-37`). The EP modules therefore do not go through those wrappers:

- The EPL parser, the call plane and the media path call the secret-holding EP functions directly, as ordinary C
  functions of the same image, with no `nsc_validate_ptr()`. Each EP function takes its inputs from, and writes its
  outputs to, buffers that the EP module owns (static buffers of the EP module, checked by `_Static_assert`ed sizes and
  explicit length arguments); no EP function accepts a caller pointer into memory it does not own. In a single image
  this is a code-structure rule, not isolation (§1.4).
- What the EP path needs from the existing secure code (the attestation key for `earbudId`, the KMU slot map, the
  ML-KEM path of PR #5) is reached through the same kind of direct internal call, never through an `nsc_*` wrapper.
- The `nsc_*` wrappers stay as they are for the GATT characteristics that §8.4 keeps (ATTEST, KEY_IMPORT, PAIR). On the
  CI and GA profiles those keep failing closed, as today, until the TF-M project; phase 1b's KEY_IMPORT path on those
  profiles depends on that project or on a direct-call rework of its own.
- A CI check rejects any call from the EP sources to `nsc_validate_ptr` or to an `nsc_*` wrapper (a symbol check on the
  linked objects).

The later TF-M project maps the EP functions to secure partitions called through `psa_call`, so the veneer table does
not grow, and gives the pointer rule a real boundary.

### 10.3 Threads and deadlines

Record parsing runs on the Bluetooth receive path; every cryptographic request runs on one worker thread with a stack
of at least 4 KB in phase 1 and at least 10 KB in phase 2 (ocrypto ML-DSA `_s` variant; 16 KB with `_m`), at a priority
below the audio threads, so that a 100 to 330 ms ML-DSA signature never delays a 20 ms audio deadline. The Bluetooth
receive thread (4,096 B in the CI and bench profiles) is too small for ML-DSA.

### 10.4 Storage

EK in the KMU (§3.1). The host table (`EP_MAX_HOSTS = 4` entries of about 420 B) in NVS. `ξ` wrapped in NVS (phase 2).
No call state and no EPL session key in NVS.

### 10.5 Board

The target is `nrf54lm20dk/nrf54lm20b/cpuapp`. The PCB board definition (PMIC, battery, L/R) is a separate bring-up;
`EP_INFO.board` identifies the board, and DIAG reports battery `0xFF` without a battery node.

### 10.6 KEM path

The call-handshake ML-KEM-1024 runs through the direct ocrypto API, as PR #5 does for the handshake (gap TC-1), with
the `_Static_assert`s on the ocrypto sizes kept.

---

## 11. Telemetry

### 11.1 Host log lines

The host writes earbud telemetry as single structured lines into its existing log pipeline, which already reaches
Loki (Android through the log allow-list, `LogSourceAllowList.kt`, which gains the two prefixes below; iOS through
`RTLog`). The earbud has no network path of its own.

```
QA-EARBUD-INFO v=1 ep=<earbudId, first 8 hex> fw=<major>.<minor>.<patch>+<git8> proto=2 prof=ci|bench|auth|prod
  board=<n> caps=<capsBits as 8 hex> ek=0|1 host=android|ios
QA-EARBUD v=1 call=<callId, first 8 chars>|- ep=<earbudId, first 8 hex> role=o|a|- ev=<event> [round=<E>] [st=<status>]
  [ms=<earbud response time measured by the host>] [k=v ...]
```

- `QA-EARBUD-INFO` at every authenticated EPL session start and whenever `EP_INFO` changes: this is the firmware
  version in the logs.
- Events of `QA-EARBUD`: `link_up`, `link_lost`, `resume_ok`, `resume_fail`, `auth` (with `res=`), `session_close`
  (with `why=` among `timeout`, `bad_tag`, `replaced`, `bye`), `enroll` (with `res=`, never the code), `unenroll`,
  `hosts` (with `n=`), `call_begin`, `offer_signed`, `accept_bound`, `accept_signed`, `reveal` (with `verdict=`),
  `kcmac_ok`, `round_drop` (with `reason=`), `export` (with `outer=`), `hyb` (with `form=host|ep`), `gate` (with
  `st=open|closed`), `capture` (with `st=` and `reason=`), `inner_fail` (with `fails=`, `win=`, `path=`), `audio` (the
  `AUDIO_STATS` fields, every 10 s, every 2 s while `authFails` grows), `voice` (`dir=`, `score=` × 1000, at most every
  5 s), `diag` (heap free, `hs_count`, `aead_ops`, battery, BLE interval, uptime, every 10 s), `cell`,
  `leaudio_refused`, `err` (`req=`, `code=`), `fwlog` (`lvl=`, sanitized text, at most 5 per second), `call_end`
  (`reason=`).
- `ms=` on the handshake events gives the response time of every `OFFER_SIGNED`, `ACCEPT_BOUND`, `ACCEPT_SIGNED` and
  `REVEAL_RESULT` in the field, which is the silicon timing measurement the spike could not make.
- Never logged: keys, MACs, nonces, `B`, SAS words, the enrolment code, transcripts, adverts, PSKs, full call ids or
  full earbud ids (R-COMMIT-LOG).

### 11.2 Existing lines

`R-CONFIRM-TELEMETRY` (WIRE_SPEC §3.7.4) and `QA-PQLEVEL` (PQC §6.4) are emitted by the host as for any call. In an EP
call `frame=-` (no FrameCryptor), `inner=v2` or `legacy` by the negotiation of §7, `relay` and `dcmux` by the outer mode,
`auth` from the peer's signature as today. On the remote peer, the R-EP-VERIFY line carries `ep=` (§3.7: `listed`,
`unlisted`, `unlisted_stale`, `revoked`, `pinned_offline`, `unverified_offline`, `cert_invalid`, `host_mismatch`,
`host_unresolved`, `absent`) and `ep_pq=host|ep|-` (§3.9) next to `pq_sig=` of PQC §5.5. `ep_pq` names the key the
ML-DSA half was checked against and `pq_sig` the result (`valid`, `invalid`, `unavailable`, `otherkey`, `absent`):
`ep_pq=host` when the bundle's `mldsaKeyId` is the host device's ML-DSA key id (pinned or fetched, phase 1),
`ep_pq=ep` when it is the key id of an earbud ML-DSA key listed for `K` (phase 2), and `ep_pq=-` when the bundle
carries no `sigHybrid` or names neither key. So an invalid host-anchored half is `ep_pq=host pq_sig=invalid`; an
earbud half that does not verify is `ep_pq=ep pq_sig=invalid`, and one whose `certPq` is missing, invalid or not under
the pinned host key is `ep_pq=ep pq_sig=unavailable` (§3.9); a key that cannot be obtained is
`ep_pq=- pq_sig=unavailable`, and another key id `ep_pq=- pq_sig=otherkey`.

### 11.3 Voice score

`EVENT` VOICE_SCORE (little-endian float32 in [0, 1], 1.0 = genuine human voice, −1.0 before any audio, −2.0 NPU not
ready; the opposite polarity and byte order of the stale `SPRINT21_GATT_SERVICE_SPEC.md`) with `dir = 0x01` (the
peer's voice) is the host's voice-confidence input in an EP call: the phone has no call audio to analyse. Android feeds
it through the existing earbud branch (EMA 0.15, `CallViewModel.kt:1548-1570`); iOS feeds its `ContactVoiceVerifier`
path the same way. The VCONF advisory (`<callId>|VCONF:`) is sealed and opened with `vconfKey_E` of §6.6 instead of a
key the host derives from a session key it does not have; the send and receive rules are unchanged.

---

## 12. Phasing and budget

### 12.1 Phases

| Phase | Content | Wire | Repos |
|---|---|---|---|
| 0 | PR #5 merged; bench overlay per §10.1 with the INF-log restriction (prerequisite, §12.2); an EP size spike: stubs of the EPL parser and session protocol, transcripts, KDF, KCMAC, SAS, exports, inner seal and replay window, jitter buffer and the state machines, with their real signatures and buffers, linked into the bench and CI builds, and the measured flash and RAM decide the cuts before phase 1 starts; on the DK: a RAW KMU Ed25519 key created, used and surviving a reboot, the KMU known-answer check of §3.1, Ed25519, ML-KEM and X25519 timed with DWT `CYCCNT`, a 6.4 KB EPL transfer each way with an Android and an iOS host, the connection interval iOS actually grants, an iOS host kept locked for 10 minutes with the EPL open (§9.5), Android reconnect times after a link drop (§5.10); flash freed by removing the retired plane measured; this document accepted; Appendix A and B and this file landed in the locked copies; KAT `earbud-ep-v1` generated and recomputed; server endpoint records, tombstones and the `endpoints` fetch member, with every rule of §3.6 | spec, server additive API | all |
| 1 | EP calls with `sigV6` and, when the host has a published ML-DSA key, the host-anchored `sigHybridV1` (§3.9): EPL with the session protocol and sealed records (§4.3), enrolment with the enrolment code and the confirm gesture, `HOST_LIST`, `EP_INFO`, PROTOCOL_VERSION `0x02`, transcripts and signing, round KEMs, key schedule and exports, `innerSealV2` and legacy B1, 20 ms TX with the pad-overflow rule, RX up to 60 ms / 256 B, jitter buffer, media gate, capture indicator and capture press (OD-6 (b)), gesture table, owner and ring rules, inner failure events, TX queue exclusivity and LE Audio refusal, events, idempotent requests and link resume, removal of the retired plane from every firmware profile (§8.4, §10.1); Android and iOS hosts; R-EP-VERIFY, R-EP-PQ and R-EP-PROFILE on every client | yes | all |
| 1b | hw_only PSKs held in the earbud (§5.12), the pinned KMS epoch key (gap S-2), hardware PoP for `provision-sovereign` rows, the iOS KMS relay fixes (gap AP-3) | yes | firmware, server, Android, iOS |
| 2 | the earbud's own ML-DSA-87 key: XC, `certPq` and their publication (§3.9), `HT` signed with both halves by the earbud every round, the worker stack of §10.3, the flash and RAM cuts below | yes | firmware, server, hosts |
| 3 | separate projects: TF-M isolation, endpoint attestation (gap S-3, for example a factory certificate over EK), earbud OTA from the phone (gap O-2), the earbud-rendered SAS (OD-1 (b), not chosen on 2026-11-17: it starts only with a new owner decision) | | |

By OD-4 (2026-11-17) phases 1 and 2 run on the CI and bench profiles; the authoritative and production profiles take
the EP code with the PCB profile, after the cuts of §12.3 are decided for it. They lose the retired relay plane in
phase 1 and report PROTOCOL_VERSION `0x02` without `EP_INFO` (second round of 2026-11-17, §8.1, §10.1).

PQ authentication by phase, toward a remote peer that implements PQC §5.5: in phase 1 a host with a published ML-DSA
key co-signs, so the call is `auth=H` and is judged by the contact's existing record of that host (§3.9); a host
without one gives `auth=C`, exactly as its phone calls do. There is no phase in which an endpoint call is classical
without a warning toward a contact who pinned the host's ML-DSA key. Phase 2 moves the ML-DSA half into the earbud
under `certPq`, without an anomaly for peers that pinned the host.

### 12.2 Flash (bytes, measured unless marked)

| | CI `config/prj.conf` | bench overlay | authoritative `firmware/prj.conf` |
|---|---|---|---|
| Headroom at `74a43d2`, `942,080 − signed.bin`, spike build (clone of `74a43d2` under `~/vol/spike-v6`) | 34,204 | 10,988 | 13,920 |
| Same commit, PR #5's own build (figures of the PR) | 34,396 | 11,204 | 14,096 |
| Bench INF logging restricted to the EP modules (prerequisite, §10.1), measured, revision 4 (`1b759cc`: 928,708 B of FLASH with INF everywhere, 918,564 B with INF in the 14 bring-up modules) | 0 | +10,144 | 0 |
| Ed25519 via PSA/CRACEN, RAW KMU key | −1,636 | −1,636 | −1,636 (not measured alone in this profile) |
| EP protocol code, ESTIMATE until the phase-0 size spike replaces it (EPL session protocol and records, enrolment, transcripts, `HT`, KDF, KCMAC, SAS, exports, inner seal and window, jitter buffer, gate and capture, gestures, events) | −6,000 to −10,000 | same | same |
| Removal of the retired plane (§8.4) | not measured, positive | same | same |
| After phase 1, spike baseline, before the logging and removal credits | 22,568 to 26,568 | −648 to 3,352 | 2,284 to 6,284 |
| After phase 1, with the measured logging credit, before the removal credit | 22,568 to 26,568 | 9,496 to 13,496 | 2,284 to 6,284 |
| ML-DSA-87 sign through direct ocrypto with seed expansion (`e4 − e1r`) | −7,416 | −7,416 | −7,436 |
| After phase 2, spike baseline, before the logging and removal credits | 15,152 to 19,152 | −8,064 to −4,064 | −5,152 to −1,152 |
| After phase 2, with the measured logging credit, before the removal credit | 15,152 to 19,152 | 2,080 to 6,080 | −5,152 to −1,152 |

By OD-4 (2026-11-17) the authoritative column is informative: EP is built on the CI and bench profiles until the PCB
profile exists, and no cut is made for the authoritative profile now.

The two baselines of the same commit differ by 192, 216 and 176 bytes. The spike attributes the difference to
path-dependent strings of the two checkouts; that was not re-derived, and the arithmetic uses the lower (spike)
figures. The estimate of the protocol code rests on the spike's comparison with existing modules (`sovkey_import`,
`ee_pair` and `key_store` compile to 1.8 / 1.8 / 2.3 KB for 357 / 365 / 581 lines); it is a guess for a feature of about
forty message types and is replaced by the phase-0 size spike (§12.1) before any cut is decided. The host-anchored
hybrid signature of phase 1 adds no code beyond a second Ed25519 signature call; the EPL session protocol reuses the
X25519, HKDF and AES-GCM code already linked. The bench overlay cannot take the EP code without the logging credit,
which is why that restriction is a prerequisite. With the measured credit of 10,144 B (revision 3 assumed up to
23,216 B) the bench keeps 9,496 to 13,496 B after phase 1 and 2,080 to 6,080 B after phase 2, before the removal
credit: phase 1 fits with room, phase 2 fits by a thin margin that rests on the estimate of the protocol code, which
the phase-0 size spike replaces. The 942,080 B ceiling is the MCUboot slot limit quoted by the build task; the spike
did not re-derive it.

The phase-0 self-test image (§12.1; the bench overlay with `config/phase0.conf`, which adds the KMU EK and the KMU
known-answer check, the timings and the L2CAP test server) has about 1.4 KB of headroom, measured, revision 4: 1,452 B
at `934e22a` (signed image 940,628 B, `docs/PHASE0_DK_RUNBOOK.md` §2) and 1,436 to 1,452 B in the builds of
`feat/ep-phase0` since. That is too little for ML-DSA-87, so the ML-DSA timing runs in a second phase-0 image built
without LE Audio and LC3. The phase-0 test code is never part of an EP image (`CONFIG_QA_PHASE0_TESTS` is refused
outside the bench test images), so this headroom does not bound phase 1.

Cuts, cheapest first (sizes from the spike's symbol tables unless marked): bench INF logging restricted to the EP
modules, measured at 10,144 B (`1b759cc`); the 23,216 B that revision 3 assumed is the whole difference between the
bench and CI profiles (928,708 against 905,492 B of FLASH), of which about 5 KB is float printf, which the bench keeps,
and the rest INF strings that the 14 bring-up modules still carry. It covers the bench in phase 1 and, by 2 to 6 KB,
in phase 2. Then MCUmgr and SMP 11.7 to 13.5 KB (OTA over BLE is postponed by owner decision 4); Memfault 3.6 KB
(authoritative profile); LC3 and the LE Audio host, 141,628 B of flash and 26,348 B of RAM, measured, revision 4 (NCS
v3.3.5, the phase-0 image of `feat/ep-phase0` at `201188a` built with and without them, Appendix C; revision 3
assumed 48 KB and 14.5 KB), which is not available as a cut: OD-5 keeps LE Audio and the cellular passthrough as
decided, at this measured cost (§14); the deepfake and Axon
glue 18.7 KB; Opus (327,289 B) only through a prebuilt library change.

### 12.3 RAM (bytes)

| | CI | bench | authoritative |
|---|---|---|---|
| Free at `74a43d2` (RAM 523,264 B) | 80,072 | 78,016 | 1,128 |
| Phase 1, ESTIMATE, buffers sized for the maxima of this specification (own transcript 4.0 KB with 64 own adverts, peer advert list 8.4 KB for 255 adverts kept for `kc_transcript`, two CAPSX 8.4 KB, one 4 KB record buffer with streamed parsing of the larger messages (§4.2), ML-KEM key or ciphertext 1.6 KB, state of 8 rounds about 1.6 KB, call state and response cache 1.2 KB, EPL session state 0.3 KB, host table 1.7 KB, worker stack 4 KB, 60 ms decoder +3.8 KB, jitter buffer about 1.2 KB; no peer-transcript buffer, §5.8) | about 40,000 | same | same |
| Phase 2, ESTIMATE, ML-DSA `_s`: stack 9.1 KB, signature buffer 4.7 KB, hash and MAC contexts 1.1 KB (less with ML-KEM and ML-DSA buffer reuse) | about +15,000 | same | same |

The CI and bench profiles fit both phases. The authoritative profile fits neither without cuts, and by OD-4 it gets
none now (no EP code until the PCB profile exists; in phase 1 it only loses the retired relay plane, a RAM credit
that is positive and not measured); candidates for those cuts, from the spike, with stack high-water
marks still to be measured: `mic_stack` and `encode_stack` 32,768 B each,
`s_rx_pump_stack` 24,576 B, `i2s_tx_slab` 46,080 B, `s_opus_enc_buf` 24,640 B, `mbedtls_heap` and `malloc_arena`
16,384 B each, LC3 states 14,536 B (LE Audio and LC3 together use 26,348 B, measured, revision 4, §12.2, and
stay by OD-5),
the Axon interlayer 8,192 B, the Memfault coredump region 8,192 B. The spike's own
phase-1 figure of about 4.2 KB assumed 4 adverts and no CAPSX storage; this document requires the specification
maxima. The phase-0 size spike measures the real figure.

### 12.4 Time

Phase 1 adds about 15 to 25 ms of computation and 0.1 to 1.1 s of transfer per handshake leg of the earbud (§5.6),
all of it before a protocol timer starts, plus the host's own ML-DSA signature when it co-signs (the time a phone
call already spends today). An EPL session start costs about 1.8 M instructions (two X25519 operations of 0.42 M, one
Ed25519 signature of 0.31 M and one verification of 0.60 M, spike figures), about 14 to 21 ms at 128 MHz. Phase 2 adds 107 to 160 ms on average per signature (p99 220 to 330 ms) and
about 4.7 KB per bundle sent. All figures are QEMU-based estimates until phase 0 measures them on silicon.

---

## 13. KAT plan

### 13.1 New family `earbud-ep-v1`

File `tools/kat/earbud-ep-v1/earbud-ep-v1-kat.json`, generated in the server repo by a Go generator
(`tools/kat/earbud-ep-v1/gen/main.go`, the pattern of the `pqc-hardening-v1/gen_*` generators) and recomputed by an
independent implementation in Python (`tools/kat/earbud-ep-v1/verify_ep_v1.py`), both run by server CI; sha256 pinned
in `tools/kat/katpin_test.go`. The Python verifier keeps that entry point and is required: the recomputation inside
the Go generator's own tests does not replace it, and server CI runs it on every change to the family. LF line
endings, `-text` in `.gitattributes`, byte-identical in every repo that carries it. Every random value of the earbud
and of the host is a fixed input of the vector.

| Section | Inputs | Outputs |
|---|---|---|
| `epInfo` | field values; PROTOCOL_VERSION values with and without an `EP_INFO` characteristic | the 88-byte record; a longer future record that a reader must accept; invalid records (87 bytes, `infoVersion` `0x00`, `protocolVersion` other than `0x02`) and an `infoVersion` `0x02` record (§8.2); the host decision of §8.1 for PROTOCOL_VERSION absent, `0x00`, `0x01`, `0x02` without and with `EP_INFO`, and `0x03` |
| `eplRecord` | message bodies | records: single, MORE continuation, interleaved audio records, the 512-byte split of §4.2, audio queued before the first record of a message (sent first); negatives: `len` 1 and 4095, a reserved flag bit, a message over its maximum |
| `eplSession` | HK seed, EK seed (or none), `earbudId`, `nonceE`, `nonceH`, X25519 scalars `eE` and `eH`, platform, a list of record plaintexts in both directions | `commitH`, `AUTH_H`, `sigH`, `AUTH_E`, `sigE`, `ss`, `th`, `kH2E`, `kE2H`, `enrolCode` and its four symbols, the sealed records with their `seq`; negatives: wrong `earbudId`, swapped nonces and `commitH` not matching the revealed values (each an `EP_AUTH` `0x02` with 96 zero bytes, then the channel closed), an unknown platform byte and `hostProto` `0x0001` and `0x0003` (each an `EP_AUTH` `0x03` with 96 zero bytes in place of `EP_HELLO`, then the channel closed), a record with a flipped tag bit, a record replayed with an old `seq`, an `enrol_only` session with zero `epEdPub` |
| `epc` | account UUID, `hostDeviceId`, HK and EK seeds, `earbudId`, `created_ms`, `buildProfile`, `board` | EPC bytes, `cert`, `pop`, the `endpoint` JSON member, `endpointId`, the Sigsum endpoint leaf; negatives: non-canonical base64, an extra or duplicated member, `kind` other than `earbud`, `v` other than 1, `created` as `1.0` or `-1`, `profile` as `256`, small-order EK or HK (from `ed25519Strict`), a `pop` over another host key, a `sender_device_id` other than `hostDeviceId` and an envelope without one; the publish body of §3.6 and its check-1 negatives (an unknown member, a duplicate member, a member name differing only in case) |
| `verifierPolicy` | host key state (pinned, published, unknown, other key), certificate and pop validity, server listing (listed, unlisted young, unlisted stale, tombstone, fetch failed with and without an endpoint pin), the verifier's clock, `sigV6` validity, the host's PQ record state (no key id, pinned, warning-only) and the `sigHybrid` result | verdict (`authenticated_endpoint`, `identity_key_mismatch`, `identity_unresolved`, `sig_invalid`), the `ep=` and `ep_pq=` log tokens (§11.2), the `auth=`, `pin=` and `pq_sig=` tokens of PQC §5.5, the pin actions and the effect of a SAS confirmed in the call for every row of the pin table of §3.7, the UI notice. Includes a bundle with `earbudEpV1` and no valid `endpoint` member (`ep=absent`), the host-key resolver failures (`ep=host_mismatch`, `ep=host_unresolved`), an endpoint pinned and no longer listed (stale at any age, pin deleted), and the "rogue EK under a pinned host" cases: a new EK with a valid Ed25519 `cert` and no valid host `sigPq` (phase 1), and with a missing or foreign `certPq` (phase 2), each giving the warning, `auth=C` and no endpoint pin |
| `hybridEp` | the `flows` inputs, the host's ML-DSA seed, fixed `rnd` | phase 1: `HT` with the host's key id, the earbud's `sigEd`, the host's `sigPq`, `htHash`, EXTX with `hybKeyId`; phase 2: `certPq` |
| `messages` | the inputs of `flows` | byte-exact bodies of every call-plane message of §4.5 for those inputs, the `EVENT` STATE and CELLULAR values and a DIAG record (§4.5), and the refusal layouts of §4.4 |
| `flows` | per call: ML-KEM seeds `(d, z)` and encapsulation randomness per round, X25519 scalars of both sides, EK and peer seeds, `sasNonce`, `rekeyNonce`, `relayKem` secrets, DTLS fingerprints, PSK, CAPS9 (the seven host bytes of §2.4), CAPSX and EXTX of both bundles, a mixed-case `callId` in every case, the M-15 case (c) included (§6.6: the M-15 export uses the exact `callId`, every other derivation `callIdL`) | per round: OFFER_v6, ACCEPT_v6, both `sigV6`, the JSON bundle the host emits as a parsed object (§5.5), `offerBinding`, `acceptBinding`, `sessionKey_E`, `ck_E`, `K_kc`, `kc_transcript` and `kc_transcript_x`, both MACs, SAS-KDF, words and `B` in round 1, every `EXPORT` value, two inner envelopes per direction (earbud TX 20 ms / 120 B, peer TX 60 ms / 256 B) |
| `flows` cases | (a) earbud caller and phone callee: rounds 1 to 3 with `rekeyChainV1`, `relayKemV1` and `relayRotV1`, a v3 PSK selected, host-anchored `sigHybridV1`; (b) phone caller and earbud callee, same depth, no PSK, no ML-DSA on the host; (c) a peer without `innerSealV2` (legacy inner seal with B1, M-15 export); (d) earbud to earbud; (e) a peer OFFER with `dualCurve` answered by an ACCEPT without `ciphertext.dualCurve` (accepted); (f) a peer OFFER with 255 adverts | as above |
| `timedFlows` | the `flows` cases with a monotonic fake clock: event times of requests, records, button edges and link drops | the expected state, message and timer outcome at each step: R-OFFERSPACING (5 s, refused at `OFFER_PREP`, §4.4), the previous inner slot erased 30 s after the current round confirmed, the link grace (5, 8 and 15 s, with a drop during round 1 and a resend answered from the cache), the setup timeout (120 s), the `UNAUTH` timeouts (5 s), the confirm window (30 s, a press before the prompt ignored, a 3 s hold after it accepted, a short press cancelling), the 180 s enrolment window, the ring owner (90 s), the INNER_FAIL threshold with the event bytes (`fails`, `windowMs`, §4.5) and one event for several failures at the same instant, the 15 and 30 s KCMAC windows and the 15 s REVEAL window as seen by the host, the gesture table of §9.14 for every state (the capture-press rows included) with the classification at release and the 400 ms double-press gap, and the answer-press window of §7.10 (10 s) |
| `capturePress` | per case, on a `flows` context with a monotonic fake clock: ring and answer-press times with the ring owner's host key, `CALL_BEGIN` times and roles, press edges with their start times and durations (short, double, long), `MEDIA_CTRL` GATE, TX_PAUSE, TX_RESUME, MIC_MUTE and MIC_UNMUTE, a link drop and `CALL_RESUME`, a `CALL_END` followed by a new `CALL_BEGIN` | the sequence of `EVENT` CAPTURE records (state, reason), the instants at which the earbud feeds the microphone to the encoder and plays the start cue and the 60 s cue, and the `EVENT` BUTTON records (none for a capture press). Cases: no press (silence, reason `0x02`, still silence after 60 s); a short press after `CALL_BEGIN_OK` with no second press (captures 400 ms after its release, `DOUBLE_PRESS_GAP` of §9.14, when the gate is open); a short press followed within 400 ms by a long press (does not arm; the long press is exported); a press while the gate is closed (reason `0x01`, capture at the gate opening) and while muted (reason `0x04`); every `MEDIA_CTRL` command sent without a press (no capture); a double and a long press (never arm); an idle press before `CALL_BEGIN` (does not arm); an answer press 9.9 s before `CALL_BEGIN` (arms) and 10.1 s before (does not); an answer press followed by a `CALL_BEGIN` of another host key or with role caller (does not arm, memory cleared); one answer press used by one context only; an answer on the phone's screen (waits); a second context after `CALL_END` (waits again); link drop and resume (stays armed, state re-reported); a mute of more than 60 s followed by an unmute (start cue at the unmute, the 60 s cue counted from it, §7.10) |
| `negative` | per case | expected status code of §4.4: round rule, `rekeyNonce` changed, fingerprint changed, `offerBinding` echo wrong, all-zero X25519, required tag missing, `frameKeyV6` present, `sigHybridV1` without `hybKeyId`, a second `PEER_ACCEPT` with a different body after a bound round (`already_bound`) and after a refused one (`bad_state`), a byte-identical `PEER_ACCEPT` of round 1 after `KCMAC_VERIFIED` released its cached `ACCEPT_BOUND` (`already_bound`), a `PEER_ACCEPT` whose `roundEcho` differs (`round_rule`), `chain_base` (also for a base below E whose `ck` the B13 retention erased), spacing, a rekey `OFFER_PREP` before `KCMAC_VERIFIED` of round 1 in a `rekeyChainV1` call (`bad_state`, not `spacing`), ninth staged round, own advEnc with 65 entries or a non-zero role byte, a rekey `CAPSX_own` different from round 1, a message from a non-owner host, `ENROLL_BEGIN` without a fresh bond or window, a retried request with a changed body; each response in the refusal layout of §4.4 |
| `innerRx` | envelopes of wire size 30 to 284 B (`0x04`) and 41 to 295 B (legacy), one byte outside each range, 20, 40 and 60 ms Opus frames, `trueLen = 0` and a `trueLen` larger than the block | the opened blocks and the decode or concealment decision (§7.5) |
| `profileRx` | a sequence of 20 ms / 120 B envelopes at 50 per second from an earbud peer, both envelope types, with a loss, a duplicate and a reordered frame, every frame before its playout time | the frames each receiver opens, and the decoded sequence: each counter once, in counter order, the missing one concealed, a legacy duplicate opened twice and decoded once (§7.5); consumed by every receiver (Android, iOS, Desktop, the web app and the firmware) |
| `kmuKnownAnswer` | EK seeds and messages from the sections below | for each message, its Ed25519 signature by EK: every message of the five kinds EK signs (§3.1) that this file contains, that is the `AUTH_E` of every `eplSession` vector in which the earbud holds EK (the authenticated sessions and the `enrol_only` session with EK), the pop message `"qaudion-endpoint-pop-v1" ‖ SHA-256(EPC)` of every `epc` vector, every `OFFER_v6` and `ACCEPT_v6` the earbud signs in `flows`, every hybrid `sigEd` message of `flows` and `hybridEp` and, in phase 2, the `xcEd` message of `epXcert`; the set the KMU known-answer check of §3.1 signs |
| `epXcert` (phase 2) | EK seed, `ξ`, `endpointId`, `mldsa_xc_created_ms` | XC, `xcEd`, `xcPq` with a fixed `rnd`, the publish body with `certPq` |
| `epSigHybrid` (phase 2) | the `flows` inputs, `ξ`, fixed `rnd` | `HT`, `sigEd`, `sigPq`, EXTX computed by the earbud from raw `relayKem` |

Tests that are not vectors:

- Fuzzing. The firmware's libFuzzer harness (`tests/fuzz/build.sh` and its targets at `74a43d2`) gains targets for the
  EPL record reassembly with MORE and interleaving, every call-plane message parser (the 16 KB `PEER_*` messages, `LP`
  fields, CAPSX, advEnc with 255 entries, `PSKREF`, `RELAY`, `EXTXIN`), `EP_INFO` parsing on the host side, and the
  `endpoint` JSON member on every client. Each target runs in CI for a fixed time budget on every change to its
  sources, with the corpus seeded from the vectors.
- KMU known-answer check. A DK test image signs the `kmuKnownAnswer` messages through a KMU-backed Ed25519 key
  imported from the vector seed and compares the signatures byte for byte (§3.1); it runs in each phase's acceptance.
  The phase-0 image is the only one that keeps its test keys afterwards, and `nrfutil device recover` follows it
  before any other image (§3.1).

### 13.2 Existing families the firmware must carry

Byte-identical, with their pins, under `portable/tests/kat_vectors/`:

| Family | Pin | Sections used |
|---|---|---|
| `handshake-sig-v6/handshake-sig-v6-kat.json` | `6151ad3b1d51afd22674ceefa3376654428c918fae89c8e15f28b300da91fb15` | `transcripts`, `kdf`, `commit`, `sas`, `reveal`, `canonical` |
| `pqc-hardening-v1/pqc-hardening-v1-kat.json` | `8da7f41050800cc65a8a6a9b32d7dcb812d932755a7b54ec7c3f4bf787ddd8db` | `innerNonceV1`, `innerSealV2`, `capsx`, `extx`, `kcmacExt`, `rekeyChain`, `relayKemV1` (`kOut`), `relayRotV1`, `ed25519Strict` |
| `wire_v1.0.0/ml_kem_1024` | as pinned by PR #5 | keygen and decapsulation through the ocrypto path |
| psk-advert-v3 (`tools/kat/gen_psk_advert_v3_kat.py`) | as pinned in the server | phase 1b |
| `mldsa87-v1/mldsa87-v1.json` | `dccdd89dd85b9a9619b28e0a26e4430aedf781c505dd64bdeffbb4fc0251dd04` | phase 2 |

The pins above are those of `tools/kat/katpin_test.go` at `c1790e7`. The S8b to S12 revision of the PQC KAT file
(PQC §7) moves its pin; the firmware takes the pin of the server commit it is built against.

### 13.3 Repos, pins and the WIRE_SPEC lock

- `earbud-ep-v1` is carried by the server, the firmware, Android, iOS, Desktop and the web app. Hosts consume every
  section except `innerRx`; Desktop and the web app consume `epc`, `verifierPolicy`, `hybridEp`, `profileRx` and the
  remote-peer half of `flows`; the firmware consumes all of them except `verifierPolicy`.
- The firmware repo becomes the sixth locked copy of `WIRE_SPEC.md` (at its root) and gets the `wire-spec-lock.yml`
  job; the comment and error text of the job (today "five repos" in the server and web copies, "four repos" in the
  Android, iOS and Desktop copies) say six in every copy, with the new hash, in one coordinated push. The stale
  `docs/SPRINT21_GATT_SERVICE_SPEC.md` of the firmware is replaced by a pointer to §7 of the locked copy (gap K-3).
- This document is normative for the EPL, the call plane, the key schedule and the verifier rules that Appendix A
  delegates to it, so it is locked the same way: the accepted revision is copied byte-identical to
  `docs/EARBUD_V6_ENDPOINT.md` in all six repos, and `wire-spec-lock.yml` gains a second expected hash for that path,
  checked by the same job and changed by the same coordinated push. Its review notes (§16), the lists of revision 3
  and revision 4 changes (§17) and the evidence index (Appendix C) are part of the locked bytes; they carry no rule.
- The firmware CI gains a test that hashes every vendored KAT file against its pin and fails on a mismatch, runs the
  families in the portable host build, and runs the ocrypto paths (ML-KEM now, ML-DSA in phase 2) in the QEMU harness
  of `tests/mlkem_kat_qemu`. No KAT test is skipped (today `portable/tests/test_mlkem.c` skips without liboqs).

### 13.4 Acceptance on hardware

Each phase ends with these on the nRF54LM20 DK (a CI-profile image and a bench-overlay image; by OD-4 the
authoritative profile is not an acceptance target until the PCB profile exists), the production release APK of the
Android host (from `sigstore-release.yml`) and a TestFlight build of the iOS host:

1. Enrolment from Android and from iOS (enrolment code played on both sides, confirm gesture, `HOST_LIST`, endpoint
   record visible on fetch); an enrolment attempt from a second app on an already bonded phone refused with
   `not_fresh`; a code mismatch left unconfirmed gives `no_press`.
2. Earbud with an Android host calls an Android peer, an iOS peer, a Desktop peer and a web app peer; then receives a
   call from each. Both sides: KCMAC verified, the same six SAS words, `QA-PQLEVEL` emitted, audio both ways, two
   rekey rounds, `auth=H` with a host that has a published ML-DSA key.
3. The same with an iOS host.
4. Peer side: R-EP-VERIFY verdict `authenticated_endpoint`, the endpoint label with the development-unit note, chat
   safety number unchanged; a peer on the previous release of each platform completes the call degraded (§8.6).
5. Earbud to earbud call.
6. Negative: a test relay strips `earbudEpV1` (`kcmac_mismatch`); a peer bundle with an invalid signature toward the
   earbud's host holds the gate closed until the SAS is confirmed, then audio flows both ways; an inner frame replayed
   is dropped by the window; a test host injecting inner garbage raises INNER_FAIL and, as caller, a recovery rekey.
7. Link loss of 5 s (resume) and of 20 s (`endpoint_lost`) during an active call, and a drop during round 1 between
   `PEER_ACCEPT` and its answer (the resend gets the cached `ACCEPT_BOUND`).
8. A cellular call during an EP call (hold, resume; the button does not answer the cellular call) and an LE Audio
   stream request during an EP call (refused).
9. Two enrolled phones connected: an incoming call rings both, the earbud answer goes to the ring owner only, the
   other phone exits as `answered_on_other_device`; the second phone cannot send `CALL_END` or `MEDIA_CTRL` for the
   first one's context (`not_owner`).
10. Covert capture (OD-6 (b)): a test host creates a context without any user action, as caller and as callee; the
    earbud encodes silence and reports `EVENT` CAPTURE reason `0x02` until a short press made after the context exists,
    and no EPL message arms capture (the test host sends every `MEDIA_CTRL` command, `GATE` open included); a call
    answered with the earbud's own answer press starts armed when `CALL_BEGIN` follows within 10 s and waits for a press
    when it does not; a call answered on the phone's screen waits for a press; a second call needs its own press; the
    earbud plays the start cue at capture start and the periodic cue every 60 s.
11. The KMU known-answer check over the `kmuKnownAnswer` set (§3.1, §13.1), with `nrfutil device recover` before
    any image that follows the phase-0 image.
12. An EP call on a CI-profile image (not the bench overlay), proving that the EP path does not depend on
    `CONFIG_QA_ALLOW_UNBOUNDED_NSC` (§10.1, §10.2).
13. Firmware upgrade of a bonded unit that removes characteristics: Android and iOS rediscover after Service Changed
    and read `EP_INFO`.
14. Platform measurements: the connection interval iOS grants, an iOS host locked for 10 minutes during an EP call,
    and a phase-2 rekey under audio with at most two concealed frames per rekey.
15. Loki shows `QA-EARBUD-INFO` with the firmware version and the call's `QA-EARBUD` events from both host platforms;
    no line carries a key, MAC, nonce, enrolment code or SAS word.
16. Phase 2: the peer logs `pq_sig=valid`, `ep_pq=ep` and `auth=H`; signing time logged with `ms=` is under 1 s at
    p99.
17. Host text of the capture press: on Android and on iOS the text "Press the earbud to start talking" is shown from
    `CALL_BEGIN_OK` until the first `EVENT` CAPTURE with a reason other than `0x02`, and not otherwise (not after the
    press, not in a call that started armed), in an outgoing call, in a call answered on the earbud and in a call
    answered on the phone's screen.
18. Host decision of §8.1, on Android and on iOS: an image of the authoritative profile, built for this check only,
    reports PROTOCOL_VERSION `0x02`, has no `EP_INFO`, no PSM `0x00B5` and none of the retired characteristics, and
    the host shows it as an earbud without call endpoint and places phone calls; an image that reports `0x01` (the
    firmware before the removal) is refused.

---

## 14. Owner decisions on the open points (decided 2026-11-17)

The owner accepted revision 2 on 2026-11-17 and decided the open points of its §14 as the "Owner decision" column
records. Each decision is normative where the last column points; the "Options" column is kept as the record of what
was offered.

| Id | Decision | Options | Owner decision (2026-11-17) | Normative in |
|---|---|---|---|---|
| OD-1 | Protection against an active host at call setup (§1.4, §5.9) | (a) none in this design: the limit is stated and the host is trusted at call setup, as for a phone call it hosts; (b) an earbud-rendered SAS as a phase-3 project: a digit form of the SAS on every platform (a WIRE_SPEC §4 change) and spoken-digit clips in the earbud's flash | (a): the limit is stated and accepted; no earbud-played SAS now | §1.3, §1.4, §5.9, §12.1 |
| OD-2 | Host devices per earbud | one; up to 4 of the same account | up to 4 of the same account: `EP_MAX_HOSTS = 4` | §3.2, §3.4, §3.6, §8.2, §9.13, §10.4 |
| OD-3 | Earbud unavailable before the first bundle of a call | the call runs on the phone with a visible notice; the call is not placed | the call runs on the phone with a visible notice | §5.1, §5.3, §5.11 |
| OD-4 | The authoritative profile (`firmware/prj.conf`) | accept RAM cuts of about 40 KB for phase 1 (and about 15 KB more for phase 2) from the list of §12.3; keep EP calls on the CI and bench profiles until the PCB profile exists | EP calls on the CI and bench profiles only until the PCB profile exists; no RAM cuts on the authoritative profile now | §10.1, §12.1 to §12.3, §13.4 |
| OD-5 | LE Audio and the cellular passthrough on the earbud | keep them, with the exclusivity of §9.6; drop LC3 and the LE Audio host from EP builds (offered as 48 KB flash and about 14.5 KB RAM; measured in revision 4 at 141,628 B flash and 26,348 B RAM, §12.2) | keep them, with the exclusivity of §9.6; the decision stands at the measured cost (second round, below) | §9.6, §9.7, §12.2 |
| OD-6 | Microphone capture of an EP call (§7.10) | (a) the capture indicator only; (b) the indicator, and capture starts only after a fresh earbud press in each call (the answer press counts when the call is answered on the earbud) | (b): the capture indicator plus a fresh earbud press in each call before the microphone opens | §1.4, §4.5, §5.1 to §5.3, §7.10, §8.2, §8.3, §9.9, §9.14, §13.1, §13.4 |
| MCUboot | Anti-rollback of the earbud image (§8.3) | the software version check; the hardware security counter in OTP | the software version check now; the hardware OTP counter is decided later, with the factory flow | §1.1, §8.3 |

Decided in this document and open to the owner's override; the owner accepted them as written on 2026-11-17 and
overrode none of them: the independent ML-DSA seed of §3.9 (forced by the
non-exportable KMU key); the host-anchored hybrid signature of phase 1 and the host certificate `certPq` of phase 2
(§3.9); the earbud not verifying the peer's signature (§5.8); permanent revocation tombstones and the 7-day window for
unlisted endpoints (§3.6, §3.7); the EPL session protocol with an audible enrolment code (§3.4, §4.3); the new PSM
`0x00B5` instead of reusing `0x00B3`; and the remote UI wording "reported by their device" until endpoint attestation
exists.

Second round, decided by the owner on 2026-11-17 in the evening, recorded in revision 4 and normative where the last
column points:

| Id | Decision (2026-11-17, evening) | Normative in |
|---|---|---|
| OD-4, second round | The retired relay plane (the `0x10`/`0x20`/`0x30` handshake, `0xc4` MEDIA_KEY_INSTALL, PSM `0x00B3` and every retired GATT characteristic) is removed from every firmware profile in phase 1. The authoritative and production images, which carry no EP code, report PROTOCOL_VERSION `0x02`, expose no `EP_INFO` and register no PSM `0x00B5`. A host decides by the table of §8.1: `0x01` or lower, refuse; `0x02` without `EP_INFO`, no endpoint (DIAG, attestation, key import, FE-5 pairing and PSK_LIST only, no EPL, no EP call); `0x02` with `EP_INFO`, an endpoint per `EP_INFO` | §0, §1.1, §1.5, §4.1, §8.1 to §8.4, §9.3, §10.1, §12.1, §12.3, §13.4, WIRE_SPEC §6 and §7 |
| Values of revision 3 | Confirmed: `ANSWER_PRESS_WINDOW = 10 s`; HTTP 409 for a registration over the endpoint or host limits; the `EVENT` CAPTURE reason order `0x02`, `0x01`, `0x03`, `0x04`; a host does not open an EP call when `capsBits` bit 12 is 0; the firmware CI fails when an EP symbol is linked into an authoritative or production image | §0, §3.6, §4.5, §7.10, §8.3, §10.1 |
| Refusing `EP_AUTH` | Result `0x02` or `0x03` carries 96 zero bytes in place of `epEdPub ‖ sigE`: a refusing `EP_AUTH` carries neither EK nor a signature, and the earbud signs nothing for a host it has not authenticated (EK itself is public and stays in `EP_INFO`, §8.2; wording scoped to `EP_AUTH` by §17.2 row 40). An unknown platform byte is refused with `0x03` and the channel is closed; every `hostProto` other than `0x0002`, `0x0001` included, is refused with `0x03` | §4.3 |
| `sender_device_id` | The envelope that carried an endpoint bundle MUST carry `sender_device_id`, equal to `hostDeviceId`; absent or different, media are held as for any R-EP-VERIFY failure | §3.7 step 2 |
| Server endpoint records | (a) only the host device publishes, and not while revoked (403 with a named code); (b) per-host removal without a tombstone, for a lost or replaced host phone, by any non-revoked device of the account; the records of a revoked or deleted host device are not counted toward `EP_MAX_HOSTS` and not listed; (c) `EP_MAX_TOMBSTONES_PER_USER = 32`, a new registration beyond it refused with 409, revocation always allowed; (d) account deletion erases the account's endpoint records, certificates and tombstones and keeps only the SHA-256 of each revoked EK, with no link to the account, so a revoked EK can never be registered again; (e) the per-device identity bundles in the DR and failover export, and no rollback of the primary below the first binary that stores endpoint records; (f) strict decoding of the publish body, stored fields and the server's own serialization | §3.6, §3.8 |
| OD-5, cost | LE Audio and the cellular passthrough stay as decided; their measured cost is 141,628 B of flash and 26,348 B of RAM | §12.2, §12.3 |

The reviewers' open questions and the open points of the KAT generator (`tools/kat/earbud-ep-v1/README.md`, TODO-1 to
TODO-19) are answered in revision 4 by clarifications that take the reading which refuses or holds media where the
text allowed two (§17.2); the owner may override any of them.

---

## 15. Where each known gap is answered

| Gap (alignment matrix of 2026-11-16) | Section |
|---|---|
| H-1 (how an earbud joins a v6 call) | the whole document; Appendix A |
| H-2 (v6 KDF, KCMAC, SAS, rekey in the earbud) | §6 |
| H-3 (PROTOCOL_VERSION, no downgrade check on phones) | §8.1 to §8.3 |
| H-4 (`qa-psk-sel-v1` digest), H-5 (`0xFE` fragment), H-6 (two CALL_STATE numberings) | §8.4, removed |
| A-1 (20 ms send, 60 ms receive, unsigned profile tag) | §2.3, §7.1, §7.5 |
| A-2 (inner nonce, `innerSealV2` or a withhold rule) | §7.2, §7.3: `innerSealV2` is implemented, so no withhold rule is needed |
| S-1 (no signing identity) | §3.1, §3.9 |
| S-2 (epoch key from the frame) | §5.12 (phase 1b) |
| S-3 (no hardware attestation) | §1.4, §12.1 phase 3 |
| FW-MKEY-1 (`0xc4` unusable) | §8.4, removed under Option A |
| K-1 (firmware outside the lock and katpin), K-3 (stale GATT docs) | §13.2, §13.3, Appendix B |
| AP-1 (Android call path dead), AP-2 (iOS cannot host), AP-5 (badge) | §9.12, §9.11, §9.9 |
| T-1 (telemetry into Loki), T-2 (`DEEPFAKE_SCORE` never sent) | §11.1, §11.3 |
| TC-3 (profile) | §10.1 |
| FW-NSC-1 (pointer validation) | §10.2 for the EP path (direct calls, no `nsc_validate_ptr`); the wrappers that remain keep failing closed on the CI and GA profiles until the TF-M project, so the gap stays open for ATTEST, KEY_IMPORT and PAIR |
| O-1 (MCUboot key), O-2 (OTA) | §8.3; OTA out of scope (owner decision 4) |
| Review: firmware version reporting | §8.2, §11.1 |
| Review: two consumers of the sealed TX queue, LE Audio and CELLULAR | §9.6, §9.7, OD-5 |
| Review: veneer limits | §10.2 |
| Review: APPROTECT | §10.1, §3.8 |
| Review: PCB board | §10.5 |
| Review: sovereign provisioning PoP | §5.12 |
| Review: LE Audio interoperability | §9.6, OD-5 |
| Review: transport adaptation to the current envelopes | §7.4 |
| Review: group calls, video and hold | §9.8, §7.7 |
| Review: MODE, PTT, VOLUME | §7.7, §8.4, §9.14 |
| Review: pairing procedure and button gate | §9.1, §9.2, §9.14 |
| Review of revision 1 (2026-11-17) | §16 |
| Reviews of revision 3 and the KAT open points TODO-1 to TODO-19 (2026-11-17) | §17.2 |
| Review of the first revision-4 text `641bf74` | §17.2 rows 40 to 52 |

---

## 16. Review notes (adversarial review of revision 1, 2026-11-17)

Every issue of the review was checked against the code and the specifications at the baselines of the table at the
top before it was accepted. "Fixed" names where revision 2 answers it; "rejected" gives the reason. Where the fix
differs from the reviewer's suggestion, the row says why.

| # | Severity | Issue | Outcome |
|---|---|---|---|
| 1 | high | Endpoint calls had a fresh PQ pin record keyed by EK, so a new EK' certified with a forged Ed25519 HK signature bypassed the contact's ML-DSA pin of the host, and in phase 2 the hybrid claim had Ed25519 strength | Fixed. Confirmed at PQC_HARDENING_V1.md:321-323 and :1633-1641. §3.7 step 5 and §3.9 (R-EP-PQ): the governing record is `(peer, hostKey)`; in phase 1 the ML-DSA half is the host device's own key over `HT` (host-anchored), which gives `auth=H` from phase 1 and makes a rogue EK' a visible anomaly; in phase 2 the earbud's key needs the host's `certPq`. The reviewer's `certPq` alone was not enough for phase 1, where EK signs with Ed25519 only and a quantum adversary could forge EK itself. Vectors: `verifierPolicy` rogue-EK cases, `hybridEp` |
| 2 | high | The earbud peer pin table did not deliver its claim: host-chosen user ids, LRU eviction by host traffic, an uninformed press, and a host-displayed SAS | Fixed by withdrawing the table (the reviewer's first option). §1.4 states that an active host at call setup is out of scope; §5.9 explains why; OD-1 now offers the earbud-rendered SAS as the only real countermeasure. Messages, codes and capability bits of the table are reserved |
| 3 | high | The enrolment gate reused the retroactive FW-C2 press (any press in the previous 30 s, also call answers), with no information about the requesting host | Fixed. Confirmed at `button_handler.c:142-148`, `:337`, `:451-471`. §3.4: fresh bond or pairing-mode window (180 s), a confirm window that clears earlier presses, a dedicated 3 s hold that must start after the prompt, no window during calls or rings, an audible enrolment code bound to the host key and committed (§4.3), `HOST_LIST` to show and remove unknown hosts |
| 4 | medium | An enrolled malicious host could open the microphone with a fabricated call context and no user signal | Fixed. §1.4 row, §7.10: a firmware-enforced capture indicator (start cue, LED, cue every 60 s) and, under the new OD-6 (b), capture only after a fresh press per call |
| 5 | medium | Gestures of the spec were not reconciled with the firmware's handlers (a long press during a call opened pairing mode; a short press could answer a cellular call) | Fixed. Confirmed at `button_handler.c:236-285`. §9.14 gesture table per state; no pairing mode and no CCP routing while a context or a ring exists; consumed presses do not refresh FW-C2 |
| 6 | medium | EPL integrity rested on a BLE bond whose numeric comparison is never compared by the user; a radio MITM at first pairing could read exports and rewrite records, including the SAS shown | Fixed. Confirmed at `ble_gap.c:650-700`. §4.3: committed X25519 exchange inside the signed `AUTH_H` and `AUTH_E`, AES-GCM on every record with per-direction counters; §4.1 and §9.2 say the bond gives passive confidentiality only; the first enrolment is protected by the audible committed code |
| 7 | medium | WIRE_SPEC's media gate was not mapped to EPL operations | Fixed. §7.9: gate closed at `CALL_BEGIN`, `MEDIA_CTRL` GATE, silence and no playout in the earbud, inbound discarded by the host, the three opening conditions, both directions together; §7.6 for the NACK cache; acceptance item 6 |
| 8 | medium | No arbitration between several connected hosts: rings, answers, `CALL_RESUME` and channel blocking | Fixed. Confirmed `CONFIG_BT_MAX_CONN=3` at `config/prj.conf:158`, `firmware/prj.conf:288`. §9.13: owner host recorded in the context, `not_owner`, ring owner, `CALL_BEGIN` before `call_accepted` (§5.3), `UNAUTH` timeouts and replacement (§4.1, §4.3); acceptance item 9 |
| 9 | medium | In the single image every `nsc_*` wrapper fails closed without `CONFIG_QA_ALLOW_UNBOUNDED_NSC`, which the GA checks forbid; the CI-profile claims and the FW-NSC-1 mapping were wrong | Fixed. Confirmed at `secure_services.c:96-170`, `config/prj.conf:421`, `check_config_flags.sh:277`, `bench_dev.conf:30-37`. §10.2: the EP path uses direct calls with module-owned buffers and a CI symbol check; §10.1: CI claims are "builds and fits" until acceptance item 12 passes; §15: FW-NSC-1 stays open for the remaining wrappers |
| 10 | medium | Revocations were deleted after 90 days and unlisted endpoints were accepted for ever | Fixed. §3.6: permanent tombstones, a revoked EK can never be registered again; §3.7 step 4: unlisted accepted only within 7 days of `created`, explicit offline rules |
| 11 | medium | The host could not see inner-layer failures and had no recovery rule | Fixed. §4.5 `EVENT` INNER_FAIL and 2 s `AUDIO_STATS`, §7.11 host rule (recovery rekey by the caller under R-OFFERSPACING and D12, a visible local state). The threshold is 5 failures in 2 s rather than a per-second burst, because a phone peer sends only 16.7 frames per second |
| 12 | medium | The only EP flash figure was an extrapolation, and the bench fitted only with an unmeasured credit | Fixed. §12.1 phase 0: a size spike of the EP skeleton linked into the bench and CI builds decides the cuts before phase 1; §10.1 and §12.2: the INF-log restriction is a prerequisite |
| 13 | medium | Gaps in the test plan: no receive-profile section, no timing traces, no fuzzing, no KAT of the KMU signing path, missing acceptance cases | Fixed. §13.1: `profileRx`, `timedFlows`, `eplSession`, `hybridEp`, fuzz targets on the existing `tests/fuzz` harness, the KMU known-answer check; §13.4: old-build peer, web app peer, two hosts, drop during round 1, Service Changed, platform measurements |
| 14 | low | Mid-handshake link loss: no idempotent responses, no timeout for a half-built context, `sasNonce` erased too early | Fixed. §4.4 cached idempotent responses and `EP_SETUP_TIMEOUT`, §5.10 grace for every context state, §6.5 and §6.7 `sasNonce` kept with the cached `ACCEPT_BOUND`. The suggested 20 s timeout was not taken: a caller's context must outlive the callee's ringing (server ring timeout 60 s, `main.go:1897`), so it is 120 s |
| 15 | low | Large call-plane records could delay audio on the shared channel during a rekey | Fixed. §4.2 sender rule (512-byte records during a call, audio first at record boundaries), §5.6, acceptance item 14 |
| 16 | low | The seven host-supplied CAPS9 bytes were unspecified although contacts pin some of them | Fixed differently. Confirmed at Android `HandshakeSigner.kt:337-353`, iOS `HandshakeSigningPolicy.swift:183-188`. The values are build-dependent (Android runtime switches, `PqcHandshake.kt:1782-1786`), so they cannot be constants and the earbud cannot check them; §2.4 requires the bytes the same host build would sign in a phone bundle of the same call, and the `flows` vectors pin them per case |
| 17 | low | Unchecked host inputs: rekey CAPSX, advert role bytes, and a 64-advert cap below WIRE_SPEC's 255 | Fixed. §4.6: round-1 `CAPSX_own` stored and compared (`caps_changed`), own role bytes 0, own adverts ≤ 64 (sender limit of this document), peer adverts up to 255; §5.8: the earbud no longer verifies the peer's signature, which removes the contiguous peer-transcript buffer that 255 adverts would need |
| 18 | low | Unverified platform assumptions: iOS interval rule, CallKit without phone audio I/O, the 8 s grace | Fixed. §4.1 requests 15 to 30 ms for iOS and sizes for 30 ms; §5.10 grace set per host in `CALL_BEGIN` (5 to 15 s); §9.5 failure behaviour; §12.1 phase 0 and acceptance item 14 measure all three. The Apple guideline is cited as external and unverified here |
| 19 | low | The "earbud-protected" claim was not a barrier: a host can certify a software key, and bench units look like production ones | Fixed. §1.4 row rewritten, §3.10, `buildProfile` and `board` in the EPC and the endpoint member, UI wording without "protected" (§3.7, §9.9, §9.10) |
| 20 | low | Per-user record limits counted host records, not endpoints | Fixed. §3.6: at most 4 distinct endpoints per user and `EP_MAX_HOSTS` records per endpoint. Revision 3: `EP_MAX_HOSTS` is 4 (OD-2), so at most 16 live records per user and 4 per host device |
| 21 | low | Stale or mislabelled facts: DIS said off, headroom not of the stated commit, code-level names cited as spec rules, the WIRE_SPEC §3.1 duplicate sentence | Fixed. §8.2 DIS corrected (`config/prj.conf:175-179`); §12.2 shows the spike and PR #5 figures of `74a43d2` side by side with the unverified attribution of the difference (not re-measured in this revision: no firmware change since); §2.3, §2.4 and §7.1 label `W-ALL60`, `W-PADOVERFLOW` and the unsigned strings as platform names, and Appendix A no longer names strings absent from WIRE_SPEC; Appendix A amends the §3.1 duplicate sentence |
| 22 | low | Normative parts lived in an unlocked document; the group-promotion decline was undefined and peers kept their promote control | Fixed. §13.3: this document is locked by hash in all six repos with the same job; §9.8: decline by `group_call_decline` of `docs/GROUP_CALLS_V2.md` §2.6, and `earbudEpV1` disables the peer's promote control |

No issue was rejected. Four suggestions were adapted, for the reasons given in rows 1, 11, 14 and 16.

---

## 17. Revision 3 and revision 4 changes (owner decisions of 2026-11-17)

This section carries no rule of its own: §17.1 lists the changes of revision 3 and §17.2 those of revision 4, each with
the text that now carries the rule.

### 17.1 Revision 3

Revision 3 is revision 2 as the owner accepted it, with the owner's decisions recorded and made normative. No byte
format, transcript, KDF, KCMAC, SAS, domain string, message type, status code, capability bit or key of revision 2
changed: the formats of §3 to §8 and the fenced text of Appendix A and Appendix B are byte for byte those of revision
2. Where a decision changes behaviour, the rows below name the text that now carries the rule. This section carries
no rule of its own.

| # | Change | Where |
|---|---|---|
| 1 | Status set to "Accepted by the owner 2026-11-17 (revision 2 + decisions)"; the baseline table gains the firmware PR #6 row read for the MCUboot decision | head, §0 |
| 2 | OD-1 (a) recorded: the active-host limit is stated and accepted and no earbud-played SAS is built now. Wording only; revision 2 already specified the limit | §1.3, §1.4, §5.9, §12.1, §14 |
| 3 | OD-2: `EP_MAX_HOSTS = 4` is a defined constant (revision 2 said "proposed 4"); `EP_INFO.maxHosts` is 4; the per-user budget is stated as at most 16 live records, at most 4 per host device, tombstones not counted, replacement of an existing `(hostDeviceId, endpointId)` not counted twice, and a registration over a limit is refused with 409 | §0, §3.2, §3.4, §3.6, §8.2, §9.13, §10.4, §16 row 20 |
| 4 | OD-3 recorded: a call that cannot use the earbud before the first bundle runs on the phone with a visible notice and is never refused. Wording only; revision 2 already specified the fallback | §5.1, §5.11 |
| 5 | OD-4: the authoritative and production profiles carry no EP code until the PCB profile exists, do not register PSM `0x00B5`, do not expose `EP_INFO` and never report PROTOCOL_VERSION `0x02`; a firmware CI check keeps EP symbols out of them; no RAM cut now; acceptance runs on CI and bench images. Superseded in part by §17.2 row 2: those images now report `0x02` without `EP_INFO` | §10.1, §12.1 to §12.3, §13.4 |
| 6 | OD-5 recorded: LE Audio and the cellular passthrough stay in EP builds under the rules of §9.6. Wording only | §9.6, §14 |
| 7 | OD-6 (b) made unconditional and complete: the `captureArmed` flag and its five rules, the answer press and the new constant `ANSWER_PRESS_WINDOW = 10 s` (chosen in revision 3; it is the host's time between the press and `CALL_BEGIN`, with margin, and phase 0 may tighten it; confirmed by the owner, §17.2 row 5, so a change now needs an owner decision), the exact `EVENT` CAPTURE pair for "waiting for the capture press" (state `0x00`, reason `0x02`) with the reporting points and the order of reasons, the statement that no EPL message arms capture, `capsBits` bit 12 always 1 in an EP build and a host not opening an EP call when it reads 0, the host text rules, the gesture-table cells, the KAT section `capturePress`, acceptance items 10 and 17 | §1.4, §4.5, §5.1 to §5.3, §7.10, §8.2, §8.3, §9.9, §9.14, §12.1, §13.1, §13.4 |
| 8 | MCUboot anti-rollback: the software version check now, the hardware OTP counter later with the factory flow; the limit of the software check is stated | §1.1, §8.3, §14, Appendix C |
| 9 | Appendix A and Appendix B are the text that landed in `WIRE_SPEC.md`: the headings and the introductory sentences say so, the fenced text is unchanged. Appendix B replaced lines 1686 to 1729 of the baseline `WIRE_SPEC.md` (the section up to the sentence ending "(audit D10-3)."), not 1686 to 1731: line 1731 is the `---` separator before §8, which stays | Appendix A, Appendix B |
| 10 | The lock job text of the Android, iOS and Desktop copies says "four repos" where the server and web copies say "five" (today's workflows); every copy says six after the landing. The web client's lock also covers `desktop.pin.json` and `spec/IMPLEMENTS.json` (`scripts/check-spec.mjs`), and the iOS engine tests read the `EXPECTED=` line | §13.3, Appendix C |
| 11 | Landing in the server repository: `WIRE_SPEC.md` after Appendix A, the consequential edits and Appendix B had sha256 `d59b321bbe1f6d298483aa23bd251899aadf17482e52256590a861de1da25092` at revision 3; after revision 4 and its review fixes it has sha256 `6a01ab50a8b49b19d9e46fc32d6ea087f927476332c20b9b3c7c9bbcd2ae4e0c` (§17.2 row 53); the two `PQC_HARDENING_V1.md` pointer sentences are added; `.github/workflows/wire-spec-lock.yml` checks `WIRE_SPEC.md` (the line `EXPECTED=`) and this file (the line `EXPECTED_EARBUD_EP=`) and lists both in its trigger paths; `.gitattributes` keeps this file at LF | §13.3, Appendix A, Appendix B |

### 17.2 Revision 4

Revision 4 records the second round of owner decisions of 2026-11-17 (§14) and answers the open questions of the
reviewers of revision 3 and of the KAT generator (`tools/kat/earbud-ep-v1/README.md`, TODO-1 to TODO-19, at
`e7cde5d`). Byte formats, KDFs, transcripts, domain strings, message types, status codes and capability bits are
those of revision 3, with the exceptions the owner decided: the authoritative and production images report
PROTOCOL_VERSION `0x02` without `EP_INFO` instead of never reporting it (row 2); a refusing `EP_AUTH` carries 96 zero
bytes in its `epEdPub ‖ sigE` fields, and an unknown platform or any `hostProto` other than `0x0002` gets result `0x03`
(row 6). Values that revision 3 named but did not number are now fixed (the `EVENT` STATE and CELLULAR values, the
DIAG layout as the firmware already has it, the HTTP error codes of §3.6, `DOUBLE_PRESS_GAP`); no value that revision 3
fixed has changed. A row marked "clarification" settles a point where the text allowed two readings, by the reading
that refuses or holds media: it is a clarification, conservative reading, and the owner may override it. The fenced
text of Appendix A and Appendix B follows the WIRE_SPEC changes of the rows that name them. Rows 40 to 52 answer the
review of the first revision-4 text (`641bf74`): its six findings and those of its questions that were plain
inconsistencies of the text; they change no byte format, KDF, transcript, domain string, message type, status code
or capability bit, and where they amend an earlier row of this table they say so.

| # | Change | Where |
|---|---|---|
| 1 | Status says revision 4; the baseline table gains the firmware branch `feat/ep-phase0` (`934e22a`) and the KAT branch (`e7cde5d`); §13.3 and §15 name the revision-4 lists; §17 is split into §17.1 and §17.2 | head, §13.3, §15, §17 |
| 2 | Owner decision (OD-4, second round): the retired relay plane (the `0x10`/`0x20`/`0x30` handshake, `0xc4` MEDIA_KEY_INSTALL, PSM `0x00B3`, the retired GATT characteristics) is removed from every firmware profile in phase 1; the authoritative and production images, which carry no EP code, report PROTOCOL_VERSION `0x02`, expose no `EP_INFO` and register no PSM `0x00B5`; new term "no-endpoint earbud". Supersedes §17.1 row 5 where it said those images never report `0x02` | §0, §1.1 item 6, §1.5, §4.1, §8.1, §8.4, §10.1, §12.1, §12.3, §14, WIRE_SPEC §6 and §7 (Appendix A, Appendix B) |
| 3 | Owner decision: the host decision table, `0x01` or lower refuse, `0x02` without `EP_INFO` no endpoint (DIAG, attestation, key import, FE-5 pairing and PSK_LIST only, no EPL, no EP call), `0x02` with `EP_INFO` an endpoint per `EP_INFO`; the same table in WIRE_SPEC §7 "Phone obligations"; KAT `epInfo` decision vectors and acceptance item 18 | §8.1, §8.3, §9.3, §9.9, §13.1, §13.4, WIRE_SPEC §7 (Appendix B) |
| 4 | Clarification, conservative reading, the owner may override: the rows the decision did not name. An absent, unreadable or not one-byte PROTOCOL_VERSION is refused as `0x01`; a value above `0x02` is refused ("Update the Q-Audion app"); a firmware version below the host's minimum, `capsBits` bit 12 clear or a downgrade makes the earbud "no endpoint"; the decision is made at every connection and again after Service Changed | §8.1, §8.3, WIRE_SPEC §7 (Appendix B) |
| 5 | Owner confirmation of the values chosen in revision 3, unchanged: `ANSWER_PRESS_WINDOW = 10 s`; HTTP 409 for a registration over the endpoint or host limits (now with the code `endpoint_limit`); the `EVENT` CAPTURE reason order `0x02`, `0x01`, `0x03`, `0x04`; a host does not open an EP call when `capsBits` bit 12 is 0; the firmware CI check against EP symbols in authoritative and production images | §0, §3.6, §4.5, §7.10, §8.3, §10.1, §14, §17.1 row 7 |
| 6 | Owner decision: a refusing `EP_AUTH` (`0x02`, `0x03`) carries 96 zero bytes for `epEdPub ‖ sigE`, so it carries neither EK nor a signature and the earbud signs nothing for a host it has not authenticated (scoped to `EP_AUTH` by row 40: EK stays in `EP_INFO`); the revision-3 sentence that could be read as "EK whenever the earbud holds it" is replaced; an unknown platform byte is refused with `0x03` and the channel closed; every `hostProto` other than `0x0002`, `0x0001` included, is refused with `0x03`; result `0x03` reads "protocol version or platform not supported" (KAT TODO-3, TODO-4); WIRE_SPEC §7 says that a refused host gets no key and no signature | §4.3, §13.1, WIRE_SPEC §7 (Appendix B) |
| 7 | Clarification, conservative reading, the owner may override: the earbud checks `hostProto` and `platform` when `HOST_HELLO` arrives and sends the refusing `EP_AUTH` `0x03` in place of `EP_HELLO`, so a refused host gets no `EP_INFO`, nonce or ephemeral key; a host ignores the 96 bytes of a refusing `EP_AUTH` | §4.3 |
| 8 | Owner decision: the envelope that carried an endpoint bundle MUST carry `sender_device_id`, equal to `hostDeviceId`; the sentence of §3.7 step 2 that made the check conditional ("If the envelope ... has a `sender_device_id`") is replaced; absent or different fails step 2 (`identity_key_mismatch`, `ep=cert_invalid`, media held). WIRE_SPEC §3.7.3 already said it unconditionally and is unchanged on this point | §3.7 step 2, §13.1 |
| 9 | Owner decision (server, a): only the host device publishes, and not while revoked, 403 `endpoint_host_mismatch` or `device_revoked`. Clarification, conservative reading, the owner may override: the order of the checks and the codes of the checks that revision 3 left unnamed (400 `endpoint_body_invalid`, `endpoint_key_invalid`, `endpoint_sig_invalid`; 409 `endpoint_host_key_mismatch`, `earbud_other_account`, `endpoint_key_taken`, `endpoint_limit`, `endpoint_tombstone_limit`; 410 `endpoint_revoked`; 412 `earbud_not_attested`; 404 `endpoint_not_found`), the error body `{"error":"<code>"}`, 200 on a publish and 204 on a deletion, the same caller rule for the phase-2 `mldsa` publication, and a host that retries a failed publication only after a network or 5xx failure, never after a 4xx answer | §3.4 step 9, §3.6 |
| 10 | Owner decision (server, b): per-host removal `DELETE .../endpoints/{endpointId}/hosts/{hostDeviceId}` by any non-revoked device of the account, without a tombstone; the records of a revoked or deleted host device are not counted toward `EP_MAX_HOSTS` and are not listed; what peers see afterwards (unlisted, step 4 (c)) and the earbud owner's `UNENROLL`; the lost-host case of §3.8 rewritten. Clarification, conservative reading, the owner may override: the definition of a live record, an endpoint counted toward `EP_MAX_ENDPOINTS_PER_USER` only while it has one, a restored device not bringing its hidden records back, and the publication-lag window stated as a limit | §3.6, §3.8 |
| 11 | Owner decision (server, c): `EP_MAX_TOMBSTONES_PER_USER = 32`; at 32 tombstones a new registration is refused with 409 `endpoint_tombstone_limit`; revocation is never refused. Clarification, conservative reading, the owner may override: the cap applies to a registration that adds a live record, not to the replacement of an existing one | §0, §3.6 |
| 12 | Owner decision (server, d): account deletion erases the account's endpoint records, certificates, proofs of possession and tombstones and keeps only the SHA-256 of each revoked EK, with no link to the account, so a revoked EK can never be registered again by any account (check 7). Clarification, conservative reading, the owner may override: the deletion first revokes the account's live endpoints, so every EK the account published enters that set | §3.6 |
| 13 | Owner decision (server, e): the per-device identity bundles are part of the DR and failover export, and the primary is never rolled back below the first binary that stores endpoint records, with the evidence at `c1790e7` (`bbolt.go:4629-4670`, the `?device_id=` fall-through of `users_identity_key.go:476-485`). Clarification, conservative reading, the owner may override: the export also carries the endpoint stores, the revoked-key set and the device revocation records (`revoked_keys`) that the per-host rule reads | §3.6, Appendix C |
| 14 | Owner decision (server, f): the publish body is decoded strictly (an unknown member, a duplicate name, a name differing only in case: 400 `endpoint_body_invalid`), the server stores the validated fields and serves its own serialization | §3.6, §13.1 |
| 15 | Clarification, conservative reading, the owner may override (question 1 of the review): after an R-EP-VERIFY failure (`ep=cert_invalid`, `host_mismatch`, `host_unresolved`, `revoked`, `unlisted_stale`, `unverified_offline`, or `sig_invalid`) a confirmed SAS releases the hold of that call and pins nothing, neither `K` as endpoint nor `K` as a device key nor `hostKey`; EK is never pinned as a device key; the pin table of §3.7 states every case | §3.7 steps 6 and 7, pin table, WIRE_SPEC §3.7.3 (Appendix A) |
| 16 | Question 2 of the review: the WIRE_SPEC §3.7.3 summary states the young-endpoint window as at most 7 days before and at most 1 day after the verifier's clock, as §3.7 step 4 (c) | WIRE_SPEC §3.7.3 (Appendix A) |
| 17 | Clarification, conservative reading, the owner may override (KAT TODO-7): `ep=host_mismatch` and `ep=host_unresolved` for the host-key resolver failures of step 3, `ep=absent` for an `earbudEpV1` bundle without a valid member; `ep_pq` names the key the ML-DSA half was checked against and `pq_sig` of PQC §5.5 the result, with the invalid and unavailable cases spelled out | §3.7, §11.2, §13.1 |
| 18 | Clarification, conservative reading, the owner may override (KAT TODO-8): a bundle without a valid `endpoint` member gets the R-IDENTITY verdict for `K` (`identity_key_mismatch` for `Unauthenticated`, `identity_unresolved` for `Unresolved`), media held; with `earbudEpV1` its SAS pins nothing | §3.5, §3.7, WIRE_SPEC §3.7.3 (Appendix A) |
| 19 | Clarification, conservative reading, the owner may override (KAT TODO-9): (a) an invalid `sigV6` gives `sig_invalid` and pins nothing; (b) an endpoint is pinned only with `ep=listed`, no step-5 anomaly and a valid `sigV6`, an endpoint accepted as `ep=unlisted` or `ep=pinned_offline` is not pinned anew, and an endpoint pinned and no longer listed is `unlisted_stale` at any age and its pin is deleted; (c) a SAS confirmed in a call with a step-5 anomaly pins nothing for the endpoint and the PQ record follows PQC §5.5. The WIRE_SPEC §3.7.3 summary says the same | §3.7 steps 4 (c), 6, 7, 8, pin table, WIRE_SPEC §3.7.3 (Appendix A) |
| 20 | Clarification, conservative reading, the owner may override (KAT TODO-1): an `EP_INFO` shorter than 88 bytes, with `infoVersion` `0x00` or with `protocolVersion` other than `0x02` is invalid, one with `infoVersion` above `0x01` describes an unknown EPL; over GATT the earbud is then "no endpoint", in `EP_HELLO` the host closes the channel | §8.2, §13.1 |
| 21 | Clarification, conservative reading, the owner may override (KAT TODO-2): audio queued before the first record of a message is sent before that record | §4.2, §13.1 |
| 22 | Clarification, conservative reading, the owner may override (KAT TODO-5): the JSON text of a bundle is not canonical; bundles are compared as parsed values under the strict parser of WIRE_SPEC §3.1; the 24 KiB rule applies to the bytes sent | §5.5, §13.1 |
| 23 | KAT TODO-6: the `EVENT` STATE values `0x00` to `0x05` and the `EVENT` CELLULAR values `0x00` to `0x04` (revision 3 named the states without numbers); the 32-byte DIAG record as `struct qaudion_diag_pkt` of `74a43d2`, with the meanings of `hs_count` and `call_state` that replace those of the retired plane; the WIRE_SPEC §7 DIAG row points to §4.5 | §4.5, §13.1, WIRE_SPEC §7 (Appendix B) |
| 24 | Clarification, conservative reading, the owner may override (KAT TODO-10): blocks of 2 to 256 B, wire 30 to 284 B on the `0x04` path and 41 to 295 B on the legacy path (revision 3 wrote "blocks of 30 to 256 B"); an envelope outside its range is dropped before the open and counted as an inner failure | §7.5, §13.1 |
| 25 | Clarification, conservative reading, the owner may override (KAT TODO-11): each counter is decoded at most once on both paths, a legacy duplicate is discarded after the open (`replayDrops`), decoding in counter order; the `profileRx` vectors assume every frame arrives before its playout time | §7.5, §13.1 |
| 26 | Clarification, conservative reading, the owner may override (KAT TODO-12): a press is classified at its release (the factory reset acts at 10 s); new constant `DOUBLE_PRESS_GAP = 400 ms`, chosen in revision 4; where a double press has a meaning a short press acts after the gap; a confirm gesture is released before the window ends | §9.14, §13.1 |
| 27 | Clarification, conservative reading, the owner may override (KAT TODO-13): `spacing` is returned only by `OFFER_PREP`, measured from the previous `OFFER_SIGNED` ok or while the previous own round is undecided | §4.4, §5.4, §13.1 |
| 28 | Clarification, conservative reading, the owner may override (KAT TODO-14): the `EVENT` INNER_FAIL bytes (`fails` over the window ending at the failure, `windowMs` the span from the oldest counted failure, `lastEpochByte` `0x00` on the legacy path), what counts as an inner failure, and `authFails` counting the same failures | §4.5, §7.5, §13.1 |
| 29 | Clarification, conservative reading, the owner may override (KAT TODO-15): the layout of a refusal, a typed response cut after `status` (with the `ENROLL_RESULT`, `CALL_BEGIN_OK` and `RESUME_RESULT` exceptions) or an `ERROR` record; a `CALL_END` for an unknown `h` gets `ERROR` `bad_state` | §4.4, §13.1 |
| 30 | Clarification, conservative reading, the owner may override (KAT TODO-16): a second `PEER_ACCEPT` with a different body gets `already_bound` when the round is bound and `bad_state` after a refused first one; a `PEER_ACCEPT` whose `roundEcho` differs from its `round` gets `round_rule` | §4.4, §4.6, §13.1 |
| 31 | Clarification, conservative reading, the owner may override (KAT TODO-17): a block whose `trueLen` exceeds what the block holds is a lost frame for concealment, counted in `decodeFail` | §7.5, §13.1 |
| 32 | Clarification, conservative reading, the owner may override (KAT TODO-18): the 60 s cue counts from the most recent start cue, and a pause of capture stops it | §7.10, §13.1 |
| 33 | Clarification, conservative reading, the owner may override (KAT TODO-19): `chain_base` also when the retention rule of PQC B13 erased `ck_B`; the refusal is the round's `PEER_OFFER_OK` with that status and the earbud keeps nothing of the round | §4.4, §13.1 |
| 34 | Question 4 of the review: the `kmuKnownAnswer` set is named (the `AUTH_E` of every session with EK, the `enrol_only` one included, every EPC pop, every `OFFER_v6` and `ACCEPT_v6` the earbud signs, every hybrid `sigEd` message, the phase-2 `xcEd`) and §3.1 points to it (revision 3 named a section `eplAuth` that does not exist); the M-15 export uses the exact `callId` while `kOut` uses `callIdL`, and every `flows` case, the M-15 case (c) included, uses a mixed-case `callId`; the Python verifier keeps `tools/kat/earbud-ep-v1/verify_ep_v1.py`, is required and is run by server CI | §3.1, §6.6, §13.1, §13.4 item 11 |
| 35 | Question 5 of the review: the phase-0 DK image alone keeps its KMU test keys (slots 124 to 127) and PSA test keys; `nrfutil device recover` is required before any other image is flashed on that board | §3.1, §13.1, §13.4 item 11 |
| 36 | Question 6 of the review, measured on NCS v3.3.5 at `74a43d2` and `feat/ep-phase0`: LC3 and the LE Audio host cost 141,628 B of flash and 26,348 B of RAM (revision 3: 48 KB and 14.5 KB); the bench INF-log restriction frees 10,144 B (revision 3: up to 23,216 B); the phase-0 image has about 1.4 KB of headroom (1,452 B at `934e22a`, 1,436 to 1,452 B in later builds) under the 942,080 B ceiling; the flash table gains the rows with the measured credit and the conclusions follow (phase 1 fits the bench with 9.5 to 13.5 KB, phase 2 by 2 to 6 KB); OD-5 stands as decided at the measured cost | §10.1, §12.2, §12.3, §14 |
| 37 | Question 7 of the review: the change log at the end of WIRE_SPEC gains the entry `Latest: 2026-11-17` for revisions 3 and 4 of this document, and the previous `Latest:` line becomes `Previous:` | WIRE_SPEC footer, Appendix A |
| 38 | Consistency of WIRE_SPEC with §13.3: its list of mirror copies names the six locked repositories (it named four) | WIRE_SPEC head, Appendix A |
| 39 | Appendix A and Appendix B carry the revision-4 text of WIRE_SPEC §3.7.3 and §7 (rows 2, 3, 4, 6, 15, 16, 18, 19, 23, 40, 49); Appendix A lists the revision-4 consequential edits (the §6 sentence, the head, the footer); Appendix C gains the evidence read for revision 4 | Appendix A, Appendix B, Appendix C |
| 40 | Review of `641bf74`, finding 1: the sentence "the earbud never sends EK or a signature to a host it has not authenticated" (§4.3, §14, row 6, and its WIRE_SPEC §7 counterpart) was false, because `EP_HELLO` carries `EP_INFO`, `epEdPub` included, before `HOST_AUTH`, and the characteristic `0xd0` serves the same record. It is scoped to `EP_AUTH`: a refusing `EP_AUTH` carries neither EK nor a signature, the earbud signs nothing for a host it has not authenticated, and EK, a public key, stays in `EP_INFO` (the 88-byte record and the `epInfo` vectors are unchanged). The owner decision, 96 zero bytes in a refusing `EP_AUTH`, is unchanged; the WIRE_SPEC §7 sentence and its change-log entry say the same; row 6 is corrected in place | §4.3, §14, WIRE_SPEC §7 and footer (Appendix B) |
| 41 | Review of `641bf74`, finding 2: check 7 refuses an EK that has a tombstone in any account (it said "in this account", which let a second account register an EK that the first account had revoked, while the first account exists), and check 8 refuses an EK that has a live record in another account (it said "registered", a term the section does not define); the revocation paragraph says that a revoked EK can never be registered again by any account. This restores the revision-3 rule (an EK with a revocation tombstone is refused) and owner decision (d) of the server records | §3.6 checks 7 and 8, Revocation |
| 42 | Review of `641bf74`, finding 3. Clarification, conservative reading, the owner may override: in a call that negotiated `rekeyChainV1`, an `OFFER_PREP` that arrives before `KCMAC_VERIFIED` of round 1 gets `bad_state` (no base, §5.4 caller step 1) and never `spacing`, although round 1 is then undecided: the base rule is checked first, as the D12 gate of PQC B13 runs before any rate limit; without `rekeyChainV1` the same `OFFER_PREP` gets `spacing`. Amends row 27 | §4.4 code `0x0A`, §5.4, §13.1 (`timedFlows`, `negative`) |
| 43 | Review of `641bf74`, finding 4: the `EVENT` INNER_FAIL rule checks that no event was sent in (t − 2,000 ms, t], an interval closed at t; it said open at t, so several failures at the same instant (several `AUDIO_IN` records of one SDU) each sent an event. Events are now at least 2,000 ms apart, as "at most one event per 2 s" says. Amends row 28 | §4.5, §13.1 (`timedFlows`) |
| 44 | Review of `641bf74`, finding 5 and the double-press question. Clarification, conservative reading, the owner may override: in an EP context a capture press acts, and capture can start, `DOUBLE_PRESS_GAP` (400 ms) after the short press's release when no second press started in that gap; the `capturePress` case that said "captures at once" says so, and §7.10 rule 2 names the instant. When a second press starts within the gap and is not short (medium, long or a hold), the first press does not act at all and the second is classified and acts by itself; a `capturePress` case pins a short press followed by a long press. Amends row 26 | §7.10 rule 2, §9.14, §13.1 (`capturePress`) |
| 45 | Review of `641bf74`, finding 6: what the host of a no-endpoint earbud may use is the same list everywhere, the list of §8.1 and WIRE_SPEC §7 (DIAG, attestation, KEY_IMPORT, FE-5 pairing, PSK_LIST); §0, §14 and row 3 said "attestation, key import and pairing" and §8.3 "diagnostics, attestation and the KMS relay"; row 3 is corrected in place | §0, §8.3, §14 |
| 46 | Review of `641bf74`, question on a second `PEER_ACCEPT`. Clarification, conservative reading, the owner may override: once a cached response was released (the context moved past its step) the earbud never recomputes it; a later request of that step gets `bad_state`, byte-identical or not, and a `PEER_ACCEPT` for a bound round gets `already_bound`, for example a byte-identical `PEER_ACCEPT` of round 1 after `KCMAC_VERIFIED` erased the cached `ACCEPT_BOUND` and `sasNonce`. The text promised a cached response that no longer existed. Amends row 30 | §4.4, code `0x10`, §13.1 (`negative`) |
| 47 | Review of `641bf74`, questions on the per-host removal. Clarification, conservative reading, the owner may override: a per-host `DELETE` for an endpoint that has a tombstone in the account answers 410 `endpoint_revoked`, checked before 404; the records of a revoked or deleted host device are hidden only as live entries, and the tombstones of such a device stay listed like every tombstone (they were "never listed" in one sentence and "listed for ever" in another) | §3.6 |
| 48 | Review of `641bf74`, question on publication retries (a gap of the flow). Clarification, the owner may override: check 6 refuses an earbud that was never attested and §3.4 never attested it, so before its first publication for an earbud the host runs the existing earbud attestation (`POST /api/v1/device/earbud-attest`, `cmd/bcrypto-lite/main.go:12843`); a 4xx answer is never retried automatically, and the same record is published again only after its cause was removed (an attestation for 412 `earbud_not_attested`, the user's removal of an endpoint or a host record for 409 `endpoint_limit`); every other 4xx answer stays final for that record. Amends row 9 | §3.4 step 9 |
| 49 | Review of `641bf74`, question on the first read: on iOS the first encrypted read is `PROTOCOL_VERSION`, which §9.3 reads first (§9.2 said `EP_INFO`). Clarification, conservative reading, the owner may override: "unreadable" in the first row of the host decision means a read that fails on a link encrypted under a completed bond; a read that fails because the bond is not complete is a bonding failure, after which the host uses no characteristic and decides again once bonded, and it never shows "Earbud firmware too old" for it; WIRE_SPEC §7 says the same; an unreadable `EP_INFO` counts as an invalid record (§8.2). Amends row 4 | §8.1, §8.2, §9.2, WIRE_SPEC §7 and footer (Appendix B) |
| 50 | Review of `641bf74`, question on the phase-0 test keys: §3.1 names every key that the phase-0 image keeps, from `docs/PHASE0_DK_RUNBOOK.md` at `86293ad`: the phase-0 EK in KMU slots 120 and 121, the known-answer keys in slots 124 to 127 and the persistent PSA ids `0x100` to `0x103`, `0x200` and `0x7000` (it named slots 124 to 127 only). Amends row 35 | §3.1, Appendix C |
| 51 | Review of `641bf74`, question on the LC3 and LE Audio cost: the measurement log is named. The figure of 141,628 B of flash and 26,348 B of RAM is the difference between two builds of the phase-0 image at `201188a`, with and without LE Audio and LC3 and both without ML-DSA (`~/vol/ep0-logs/fin-p0.build.log`, `fin-p0c.build.log`, Appendix C); revision 4 named `74a43d2` and `934e22a` as the commits and cited the `86293ad` artifacts, whose two phase-0 images differ by 132,948 B and 10,956 B because the second also adds ML-DSA-87. The figure, the conclusions and OD-5 are unchanged; the commit is corrected. Amends row 36 | §12.2, the baseline table, Appendix C |
| 52 | Review of `641bf74`, cosmetic points: the baseline table gives the firmware `main` after PR #5 (`235b994`) and the head of `feat/ep-phase0` on 2026-11-18 (`86293ad`); the `vconfKey_E` row of §6.6 escapes the vertical bar of its label, which GitHub rendered as an extra cell | head, §6.6 |
| 53 | Lock: `WIRE_SPEC.md` after revision 4 and the review fixes of rows 40 to 52 has sha256 `6a01ab50a8b49b19d9e46fc32d6ea087f927476332c20b9b3c7c9bbcd2ae4e0c`, recorded in §17.1 row 11; `EXPECTED` and `EXPECTED_EARBUD_EP` of `.github/workflows/wire-spec-lock.yml` are updated (this file cannot quote its own hash); `.gitattributes` is unchanged | §13.3, §17.1 row 11 |

---

## Appendix A. Text of WIRE_SPEC §3.7.3 (as landed)

Replaced lines 1139 to 1154 of `WIRE_SPEC.md` at `7a12b308...`. Revision 3 landed it; revision 4 amended its identity
bullet (§17.2 rows 15, 16, 18, 19). The text below is the exact current content of `WIRE_SPEC.md`, byte for byte,
together with the consequential edits listed after it; it lands with the new lock hash in every locked copy at once
(§13.3).

```markdown
#### 3.7.3 No unauthenticated handshake path; the hardware earbud endpoint (R-EARBUD, R-EARBUD-EP)

Every 1:1 call on every platform runs the v6 handshake of §3.7: signed OFFER/ACCEPT, DTLS binding (§3.8) and
KCMAC (§3.7.1). There is no other way to set up a 1:1 call.

- The hardware-earbud relay handshake (`earbud-relay-v1` capability, the EARBUDPDU frames, the PSK-less relay
  agreement) is **retired**. A client MUST NOT advertise `earbud-relay-v1`, and MUST ignore it when it is present in
  the unsigned `capabilities` of `call_incoming`, `call_answer` or any other server-relayed message: such a field
  never selects a different handshake, never exempts the DTLS binding checks (a) and (b), never skips KCMAC and never
  selects an audio profile. The capabilities that matter are the signed or bound ones inside the bundle (CAPS9, and
  CAPSX under `capsBindV1`).
- A signalling field that the server, or anyone on the path, can add or change MUST NOT turn off or weaken any step
  of §3.7 or §3.8. In particular there is no "exempt" state of the DTLS binding.
- If a KCMAC context is required for a round whose key was derived (§3.7.1) and is missing, the call ends with reason
  `kcmac_mismatch`. A missing context is a failure, never a reason to skip the check.

**Hardware earbud endpoint (R-EARBUD-EP).** A Q-Audion hardware earbud MAY be the endpoint of a 1:1 call, hosted by a
phone it is bonded to. It is a v6 endpoint like any other, and nothing of §3.7, §3.8, §4 or §11 changes for such a
call:

- The earbud signs OFFER_v6 and ACCEPT_v6 with its own Ed25519 key, which is the bundle's `signerIdentityKey`; it runs
  the round's ML-KEM-1024 and X25519 exchange and derives the session key, the KCMAC and the SAS of §3.7.1 and §4; it
  seals and opens the inner media layer. The host phone keeps signalling, DTLS, the outer layer, the KCMAC state
  machine and the UI, and receives from the earbud only the outer-layer keys and the voice-confidence key, each
  derived one way from the session key. The split, the phone-earbud link and the earbud's key schedule are defined in
  `docs/EARBUD_V6_ENDPOINT.md`, which is locked together with this file: every locked copy carries it byte-identical
  and the lock job checks its own expected hash.
- Identity (R-EP-VERIFY). Every bundle the earbud signs carries the member `endpoint`
  (`{v, kind, hostDeviceId, hostKey, earbudId, created, profile, board, cert, pop}`, `docs/EARBUD_V6_ENDPOINT.md`
  §3.5), a certificate by the host device's identity key over the earbud's key and a proof of possession by the
  earbud's key. A receiver whose identity resolution (pins, the per-device fetch, the published set) does not resolve
  `signerIdentityKey` verifies `cert` and `pop` (the uniform Ed25519 rule), requires the envelope's
  `sender_device_id` to equal `hostDeviceId`, resolves `hostKey` as the peer's device key with the same resolution,
  and checks the server's endpoint list of that device: a revocation tombstone gives `identity_key_mismatch`; an
  endpoint that the list does not contain is accepted only while its `created` time is at most 7 days before and at
  most 1 day after the verifier's clock, and never when the receiver had pinned it; otherwise, or when the list
  cannot be fetched and the endpoint is not pinned, it gives `identity_unresolved`. On success `signerIdentityKey` is
  authenticated as an endpoint of that device and the device pin stays the device key; only when the list contained
  the endpoint and the post-quantum check below gave no anomaly is the endpoint key pinned beside the device key, and
  only then does a SAS confirmed in the call confirm both. On any failure the existing rule applies: an unknown
  identity key holds media pending the SAS (§3.8.6), and a SAS confirmed after such a failure releases the hold of
  that call and pins nothing. A bundle whose `capabilities` carry `earbudEpV1` without a valid `endpoint` member is
  judged as an unknown identity key and its key is never pinned. The earbud's key is never part of the device key set
  of `?all=1`, is never pinned as a device key and never replaces a device pin.
- Post-quantum pins (R-EP-PQ). For an authenticated endpoint, every capability and post-quantum pin record of
  `docs/PQC_HARDENING_V1.md` §2.5 and §5.5 is the record of the host device key `hostKey`, never a record of the
  endpoint key. The ML-DSA half of the endpoint's `sigHybrid` is made by the host device's ML-DSA key, or by an
  earbud ML-DSA key that the host device's ML-DSA key certified; anything else is judged against the host device's
  record, so toward a contact who pinned that device an endpoint call is never classical without the warning.
- Tag `earbudEpV1` (requires `capsBindV1`). The earbud's bundles carry it; it is a declaration of the signer, applied
  whenever the peer's round-1 bundle carries it. It means: the signer sends 20 ms Opus frames in 120-byte blocks (50
  per second) and receives frames of 20, 40 or 60 ms in blocks of at most 256 bytes; the call is audio only (no
  video, screen share, mid-call upgrade of §8 or promotion to a group call); every bundle of the signer carries
  `endpoint`. Each side keeps its own constant send profile (R-EP-PROFILE): a phone keeps 60 ms / 256 B, and a
  receiver MUST accept the earbud's 20 ms / 120 B frames.
- The earbud's bundles carry `capsBindV1`, `earbudEpV1`, `innerSealV2` and `rekeyChainV1`, never `frameKeyV6`; the
  earbud signs CAPS9 with `sframeV1` and `vkeyV1` set to 0 and the other seven bytes as its host phone would sign
  them. In such a call the host does not advertise `audio-srtp-v1` or any capability string that offers video,
  SFrame, a mid-call upgrade or a 60 ms send profile (the platform strings are listed in
  `docs/EARBUD_V6_ENDPOINT.md` §2.4), declines a mid-call upgrade (§8.4) and never promotes the call to a group call;
  a peer whose peer bundle carries `earbudEpV1` disables its video and promote-to-group controls for the call.
- The earbud's BLE interfaces of §7 (the GATT family and the endpoint link) are local interfaces between a host and
  its earbud. They are not call-handshake paths and nothing of them crosses the server.
```

Consequential edits in the same lock change, exact sentences:

- §3.1, after the JSON example: "An earbud endpoint's bundle also carries the member `endpoint` (§3.7.3); it is
  outside the transcript and outside EXTX, and a receiver that does not implement §3.7.3 ignores it."
- §3.1, the sentence "No other duplicate rule exists, and no duplicate ends a call by itself." becomes "A duplicated
  top-level `endpoint` member, or a duplicate member inside `endpoint`, makes `endpoint` count as absent (§3.7.3). No
  other duplicate rule exists, and no duplicate ends a call by itself."
- `docs/PQC_HARDENING_V1.md` (not locked, same change set): §5.5 step 2 gains "For a bundle whose signer is an
  authenticated endpoint (WIRE_SPEC §3.7.3), the ML-DSA key and the pin record are those of the endpoint's host device
  (`docs/EARBUD_V6_ENDPOINT.md` §3.9)", and §2.5 gains the same pointer after the definition of the record key.
- §1.1, first paragraph: "(no SRTP HKDF label exists anywhere in `bcrypto-server`; the firmware SPE comment confirms
  "the session key NEVER leaves the SPE")" becomes "(no SRTP HKDF label exists anywhere in `bcrypto-server`). In a call
  whose endpoint is a hardware earbud the earbud derives these keys and hands them to its host phone (§3.7.3)."
- §6, first list: unchanged. Add after the hard-switch paragraph (revision 3; reworded by revision 4, §17.2 row 2):
  "The earbud endpoint of §3.7.3 and the GATT family of §7 (PROTOCOL_VERSION `0x02`) are a hard switch of this kind:
  the relay dialect of PROTOCOL_VERSION `0x01` is deleted from every earbud firmware image, not negotiated, and a phone
  refuses an earbud that reports it (§7)."
- Head (revision 4, §17.2 row 38): "the four client repos pull the updated spec" becomes "the client repos pull the
  updated spec", and the list of mirror copies becomes "Mirror copies live at the root of six repositories,
  byte-identical and checked by `.github/workflows/wire-spec-lock.yml` in each:" followed by `bcrypto-server` (this
  file), `qaudion-android-new`, `qaudion-desktop`, `qaudion-ios`, `qaudion-webapp` and `qaudion-firmware`, one per line.
- Change log at the end (revision 4, §17.2 row 37): a new first line `Latest: 2026-11-17 (hardware earbud as a v6 call
  endpoint, docs/EARBUD_V6_ENDPOINT.md revisions 3 and 4, ...)` that summarises §3.7.3, §3.1, §1.1, §6 and §7 as
  landed, and the line that began `Latest: 2026-11-13` begins `Previous: 2026-11-13`.

---

## Appendix B. Text of WIRE_SPEC §7 (as landed)

Replaced lines 1686 to 1729 of `WIRE_SPEC.md` at `7a12b308...` (the section up to the sentence ending "(audit
D10-3)."; the `---` separator at line 1731 stays). Revision 3 landed it; revision 4 amended it (§17.2 rows 2, 3, 4,
6, 23, 40 and 49). The text below is the exact current content of `WIRE_SPEC.md`, byte for byte.

```markdown
## 7. Earbud BLE contract: GATT family and endpoint link (PROTOCOL_VERSION 0x02)

The hardware earbud (nRF54LM20B firmware) exposes one GATT service to the phone it is bonded to and, in an image that
carries the endpoint, one L2CAP channel. FROZEN cross-platform contract: iOS and Android MUST use these exact values.
Source of truth: the firmware commit that introduces PROTOCOL_VERSION `0x02`,
`firmware/nspe/src/transport/qaudion_gatt.c`; the endpoint link and the call plane are specified in
`docs/EARBUD_V6_ENDPOINT.md` (§4 to §7), locked with this file (§3.7.3).

**Base UUID pattern:** `f2c0aaaa-bcc0-4001-8000-0000000000XX`, where `XX` is the characteristic's last byte; the
service is `...0001`. Every attribute needs an encrypted link; the bond is LESC numeric comparison, confirmed with a
press of the earbud button (FW-C2). The earbud has no display, so the bond gives link confidentiality against passive
observers only; the endpoint link authenticates itself (below). New characteristics are appended at the end of the
attribute table.

| Opcode | Name | Dir | Content |
|---|---|---|---|
| 0x90 | DIAG | read | 32-byte little-endian diagnostics record (heap, battery, handshake count, call state, BLE interval, voice score, uptime, AEAD operation count; layout in `docs/EARBUD_V6_ENDPOINT.md` §4.5) |
| 0xa9 | PROTOCOL_VERSION | read | 1 byte, `0x02` = this section, in every firmware image; `0x01` was the retired relay dialect (phone decision below) |
| 0xc0 | ATTEST_INFO | read | pk_se(32) ‖ earbud_id(32), earbud_id = SHA-256(pk_se) |
| 0xc1 | ATTEST_POP | write 48 B, read 32 B | attestation PoP (qa-attest-pop-v1); also returns the KMS PoP after KEY_IMPORT |
| 0xc2 | ATTEST_PQ | write 1 B, read 392 B | pk_pq (ML-KEM-1024 public key), 4 × 392 B chunks |
| 0xc3 | KEY_IMPORT | write, read | sealed KMS package and PoP inputs (big-endian offsets, PoP-INPUTS frame first); read-back `[status:u8][slot:u8]` |
| 0xc5 | PAIR_BEGIN | write | FE-5 earbud-exclusive msg1 = pk_se(32) ‖ pk_pq(1568) ‖ eid(32), little-endian offsets |
| 0xc6 | PAIR_RESP | write 1 B, read 408 B | FE-5 msg2 = pk_se(32) ‖ ct_ee(1568) ‖ eid(32), 4 chunks |
| 0xc7 | PAIR_FIN | write | FE-5 msg3 = SAS-confirm MAC (32 B) |
| 0xca | PSK_LIST | read | active hw_only PSK list: `[n:1] + n × [epoch_le8(8) + fp(32)]` |
| 0xd0 | EP_INFO | read | 88-byte endpoint information record (`docs/EARBUD_V6_ENDPOINT.md` §8.2): protocol and firmware version, build profile, board, capability bits, link parameters, earbud_id, endpoint key; present only in an image that carries the endpoint |

Retired with PROTOCOL_VERSION `0x02` and absent from the service of every firmware image: `0x10` HANDSHAKE_INIT,
`0x20` HANDSHAKE_RESPONSE, `0x30` HANDSHAKE_FINALIZE, `0x40` CALL_STATE, `0x50` MODE, `0x60` PTT, `0x70`
DEEPFAKE_SCORE, `0x80` VOLUME, `0xb0` SAS_ENTROPY, `0xc4` MEDIA_KEY_INSTALL, `0xc8` FP_ADV_REQUEST, `0xc9` KC_CONFIRM.
A phone MUST NOT write or subscribe to them.

**Endpoint link.** L2CAP LE credit-based channel on PSM `0x00B5`, registered exactly by the images that expose
EP_INFO, the earbud being the server, security level L4, one channel per connection; PSM `0x00B3` (AudioLink,
148-byte sealed frames) is retired from every image. The channel is a byte stream of records
`BE16(len) ‖ u8(type) ‖ u8(flags) ‖ body` (`2 ≤ len ≤ 4094`, flags bit 0 = more), independent of SDU boundaries.
Every channel starts with `HOST_HELLO` (a commitment), `EP_HELLO`, `HOST_AUTH` and `EP_AUTH`: an X25519 exchange whose
ephemeral keys are signed by the host's and the earbud's Ed25519 identity keys. A host that the earbud refuses (bad
signature or commitment, unsupported protocol version or platform) gets an `EP_AUTH` with no key and no signature,
and the channel closes: the earbud signs nothing for a host it has not authenticated. The endpoint key itself is
public and is not withheld: EP_INFO carries it and is readable before the endpoint link authenticates. The earbud
accepts the call plane only from a host whose enrolled identity key signed, and every later record in both directions
is sealed with AES-256-GCM under the session's keys. Enrolling a new host needs a fresh bond or a pairing-mode window
opened on the earbud, and a confirm gesture on the earbud after an audible code derived from the session. The
message catalogue, the call flows, the key schedule and the media envelopes are those of
`docs/EARBUD_V6_ENDPOINT.md`.

**Phone obligations.** Before it uses the earbud, a phone reads PROTOCOL_VERSION and, when the service has it,
EP_INFO, and decides:

| PROTOCOL_VERSION | EP_INFO | Phone decision |
|---|---|---|
| `0x01` or lower, or absent, unreadable or not one byte long | any | refused: the phone uses no other characteristic, opens no channel, places no call with the earbud as endpoint and shows "Earbud firmware too old" |
| `0x02` | absent | no endpoint (an image without the endpoint, `docs/EARBUD_V6_ENDPOINT.md` §10.1): only the other characteristics of the table above (DIAG, attestation, KEY_IMPORT, FE-5 pairing, PSK_LIST), no endpoint link, no call with the earbud as endpoint |
| `0x02` | present | an endpoint as EP_INFO describes it, after the record and version checks of `docs/EARBUD_V6_ENDPOINT.md` §8.2 and §8.3; a record or a firmware version those checks refuse (firmware below the phone's compiled minimum included) is handled as no endpoint, with the notice they name |
| above `0x02` | any | refused, as in the first row, with a notice to update the app |

A characteristic is unreadable when its read fails on a link encrypted under a completed bond. A read that fails
because the bond is not complete (insufficient authentication or encryption, a pairing still running, cancelled or
failed) is a bonding failure, not a decision: the phone uses no characteristic, shows the bonding step again and
decides after the next completed bond.

The phone handles Service Changed on a bonded earbud and decides again after it, never routes system call audio
(SCO, LE Audio) to the earbud during a call whose endpoint is the earbud, and uses `createL2capChannel` (Android,
API 29 or later) or `openL2CAPChannel` (iOS) on the bonded earbud.
```

---

## Appendix C. Evidence index

Every statement about existing code in this document rests on these reads (refs of the baseline table at the top).

| Claim | Evidence |
|---|---|
| R-EARBUD retired the relay handshake | server `WIRE_SPEC.md:1139-1154` |
| v6 transcripts, KCMAC, windows, SAS commitment, REVEAL | server `WIRE_SPEC.md:817-943`, `:944-1100`, `:1156-1446`, `:1589-1631` |
| Current §7 GATT family | server `WIRE_SPEC.md:1686-1731` |
| Lock hash | server `.github/workflows/wire-spec-lock.yml` (`EXPECTED=7a12b308...`) |
| B1, B2, B4, B5, B13, B14, §5.1 to §5.6, §6.4, D13, D29 | server `docs/PQC_HARDENING_V1.md:499-546`, `:548-654`, `:816-948`, `:950-1012`, `:1233-1374`, `:1376-1413`, `:1434-1857`, `:1936-1966`, `:2279`, `:2295` |
| Identity bundle publish overwrites the user's latest bundle | server `internal/store/identity_bundles.go:174-188`, `cmd/bcrypto-lite/users_identity_key.go:279`, `:330` |
| Fetch shapes and `bundlePayload` | server `cmd/bcrypto-lite/users_identity_key.go:386-516` |
| KAT pins | server `tools/kat/katpin_test.go:23-26` |
| Earbud attestation TOFU and 409 | server `cmd/bcrypto-lite/main.go:12836-12915` (alignment map) |
| `provision-sovereign` rows without PoP fields | server `cmd/bcrypto-lite/main.go:12975-13013` (alignment review) |
| Android identity resolution, published-set acceptance, R-IDENTITY | Android `feature/feature-call/.../domain/HandshakeSigner.kt:257-330`; `core/core-data/.../trust/EnsurePeerTrustPinnedUseCase.kt:402` |
| Android audio profile clause | Android `feature/feature-call/.../domain/CallCapabilities.kt:893-930` |
| Android probes hard-wired off | Android `feature/feature-call/.../di/CallModule.kt:496`, `:686` |
| Android call routing excludes Q-Audion devices | Android `feature/feature-call/.../peripheral/BluetoothHeadsetController.kt:316-340` |
| VCONF key derivation | Android `qaudion-engine/.../crypto/VoiceConfidenceAnnounceCipher.kt:55-62`; `CallController.kt:11612-11632` (current-round key) |
| Android badge | Android `feature/feature-call/.../ui/InCallScreen.kt:3119` (alignment map) |
| iOS trust evaluation and re-pin to a published key | iOS `QAudionEngine/Sources/QAudionEngine/Crypto/HandshakeSigningPolicy.swift:42`, `:111-200` |
| iOS block-size agnostic decode | iOS `QAudionEngine/Sources/QAudionEngine/Core/QAudionEngine.swift:557-590` |
| iOS background modes | iOS `QAudionApp/Info.plist:174-183` |
| iOS relay retired, profile read from the retired tag | iOS `QAudionCallIntegration.swift:5298-5301`, `CallService.swift:1715`, `CallCapabilities.swift:1421` (alignment map) |
| Firmware GATT, HSINIT/HSRESP, CALL_STATE, PROTOCOL_VERSION `0x01` | firmware `firmware/nspe/src/transport/qaudion_gatt.c:403-404`, `:855`, `:1040-1057` (alignment map, `38fad83`) |
| Two consumers of the sealed TX queue | firmware `firmware/nspe/src/transport/ble_audio.c:385-399`, `audio_link_channel.c:437-438` (alignment review) |
| Pairing gate, advertising | firmware `firmware/nspe/src/system/button_handler.c`, `firmware/nspe/src/transport/ble_gap.c:94-100`, `:590`, `:697` |
| FW-C2 press is retroactive (any debounced press in the previous 30 s, consumed once) and shared with call answer, terminate, PTT and pairing mode | firmware `74a43d2` `button_handler.c:142-148` (timestamp and window), `:236-262` (short press: CCP accept, terminate, PTT), `:267-285` (long press: decline or 60 s pairing mode), `:337` (timestamp set on every press), `:451-471` (`ble_gap_user_confirmed_pairing`) |
| Numeric comparison is confirmed by a button press, not by comparing a number | firmware `74a43d2` `ble_gap.c:650-660` (passkey not shown, "the earbud has no display"), `:667-700` (`auth_passkey_confirm_cb` gated on FW-C2, DisplayYesNo registered to get numeric comparison), `:446` (L4 requested) |
| Single-image NSC pointer check fails closed; GA forbids the escape hatch | firmware `74a43d2` `firmware/spe/src/secure_services.c:96-170`; `firmware/config/prj.conf:421`, `firmware/prj.conf:559` (`CONFIG_QA_ALLOW_UNBOUNDED_NSC=n`); `tools/check_config_flags.sh:265-282`; `firmware/config/bench_dev.conf:30-37`, `:77` |
| Three connections, four bonds; DIS already enabled | firmware `74a43d2` `config/prj.conf:158`, `:161`, `:175-179`; `firmware/prj.conf:288`, `:291`, `:311` |
| Fuzz harness exists | firmware `74a43d2` `tests/fuzz/build.sh`, `tests/fuzz/fuzz_*.c` |
| PQ pin records keyed by the signer key; the §5.5 policy table; `HT` | server `docs/PQC_HARDENING_V1.md:318-325`, `:1595-1618`, `:1620-1695` |
| Recovery triggers and callee never rekeys | server `docs/PQC_HARDENING_V1.md:1263-1268`, `:465-473` |
| Rekey bundles carry the round-1 tags | server `docs/PQC_HARDENING_V1.md:460-463` |
| advEnc `m ≤ 255`; the §3.1 duplicate sentence; the media gate; sibling exit | server `WIRE_SPEC.md:866`, `:358`, `:1545-1549`, `:1289-1296` |
| Server ring timeout | server `cmd/bcrypto-lite/main.go:1897` (`callOfferRingTimeout = 60 s`), `call_release.go:68` (sweep margin 30 s) |
| Group promotion token and decline | server `docs/GROUP_CALLS_V2.md` §2.6 (`group_call_decline`), §2.7; Android `614bc164` `feature/feature-call/.../domain/GroupPromotionToken.kt:1-90`; iOS `QAudionEngine/Sources/QAudionEngine/GroupCall/GroupPromotionToken.swift` |
| Sticky per-contact capability pins | Android `614bc164` `.../domain/HandshakeSigner.kt:337-353`; iOS `6859edb7` `.../Crypto/HandshakeSigningPolicy.swift:183-188` |
| Own CAPS9 values are build-dependent | Android `614bc164` `.../domain/PqcHandshake.kt:1781-1786` (`selfCapabilities`), `:3438-3459` (`SELF_CAPABILITIES`) |
| Phones sign `sigHybridV1` today | Android `614bc164` `.../domain/PqcHandshake.kt:155`, `:1934`, `core/core-data/.../security/DeviceKeyProvisioner.kt:501`; iOS `6859edb7` `.../Crypto/HybridSigPolicy.swift:37` |
| Call-handshake ML-KEM through direct ocrypto; bench overlay (APPROTECT off, unbounded NSC, INF logs) | firmware PR #5 `74a43d2`: `firmware/spe/src/crypto/cracen_mlkem.c` header, `firmware/config/bench_dev.conf` |
| 60 ms receive work | firmware `origin/wip/audio-60ms-rx-2026-09-19` `e4aca5b`, `384527c`, `3b18ef8` |
| Ed25519 KMU key, ML-DSA-87 sizes, stacks and timings, veneers, link parameters, RAM | spike of 2026-11-17, helsinki `/home/dev/vol/fwbuild/spike-logs` (build logs, `.mem.txt`, QEMU summaries `qemu-dsa-r5`, `qemu-dsa-r6`, `e4auth-ramoverflow.build.log:1430-1431`) |
| MCUboot offers the software version check and the hardware security counter only as a choice; the hardware counter burns OTP words | firmware PR #6 `03a83f3` `firmware/sysbuild.conf:39-54` (`SB_CONFIG_MCUBOOT_HARDWARE_DOWNGRADE_PREVENTION=y` there), `firmware/sysbuild/mcuboot.conf:5-8`; `firmware/config/bench_dev.conf:36` |
| Other repos' copies and lock files of `WIRE_SPEC.md` (all at `7a12b308...`) | Android `614bc164`, iOS `6859edb7`, Desktop `2904583`: `WIRE_SPEC.md` and `.github/workflows/wire-spec-lock.yml` (`EXPECTED=`, comment "four repos"); iOS also `QAudionEngine/Tests/QAudionEngineTests/Crypto/SasCommitTests.swift:911-913`; web `master` `308b89d7`: `WIRE_SPEC.md`, `.github/workflows/wire-spec-lock.yml` (comment "five repos"), `desktop.pin.json` (`wire_spec_sha256`), `spec/IMPLEMENTS.json` (`spec_sha256`, one entry per heading), `scripts/check-spec.mjs`; firmware `main` `38fad83`: no copy and no lock |
| Server tests that read `WIRE_SPEC.md` | server `tools/kat/wirespec_timing_test.go:18` (rule texts), `tools/katgen/location/location_test.go:942` (the §14.1 constants table), `internal/webui/gate_test.go:105` and `:200` (the web bundle's `wire_spec_sha256`, skipped while `internal/webui/webui.lock.json` is unpinned) |
| Revision 4: DR and failover export sets; the per-device bundle bucket; the device revocation bucket | server `c1790e7` `internal/store/bbolt.go:4629-4641` (`drExportBuckets`, with `bucketUserIdentityBundles` and without `bucketUserIdentityBundlesByDevice`), `:4650-4670` (`failoverExportBuckets`), `:175`, `:184` (`user_identity_bundles_v2`, `user_identity_bundles_by_device_v2`), `:78` (`revoked_keys`) |
| Revision 4: `?device_id=` falls through to the latest bundle | server `c1790e7` `cmd/bcrypto-lite/users_identity_key.go:452-454`, `:476-485`; `internal/store/identity_bundles.go:214-225` (`GetBundleForDevice` returns nothing for a device without a record) |
| Revision 4: the server's error body | server `c1790e7` `cmd/bcrypto-lite/main.go:4771-4775` (`jsonErr`, `{"error": msg}`) |
| Revision 4: the server stamps `sender_device_id` on live and replayed `opaque_message` | server `WIRE_SPEC.md` §3.7.4, R-COMMIT-KCMAC-DEVICE, its "Server fact" item |
| Revision 4: DIAG record layout | firmware `74a43d2` `firmware/nspe/src/transport/qaudion_gatt.c:211-248` (`struct qaudion_diag_pkt`), `:1336` (`diag_read`) |
| Revision 4: bench INF-log credit, phase-0 headroom, phase-0 test keys and `nrfutil device recover` | firmware `feat/ep-phase0`: commit `1b759cc` (928,708 B against 918,564 B of FLASH, 10,144 B freed), commit `934e22a` and `docs/PHASE0_DK_RUNBOOK.md` §1 (the phase-0 EK in KMU slot 120, two 16-byte slots, handle `0x7fff3078`; KMU slots 124 and 126 for the known-answer seeds; re-read at `86293ad`, whose §7 lists the persistent PSA ids `0x100` to `0x103`, `0x200` and `0x7000`), §2 (signed image 940,628 B, 1,452 B below 942,080 B), §4 (`nrfutil device recover` before any image other than a phase-0 one); helsinki `~/vol/ep0-artifacts/BUILD_INFO.txt` (a later build of the branch: 1,436 B) |
| Revision 4: LC3 and LE Audio host cost | two NCS v3.3.5 builds of the phase-0 image (`config/prj.conf`, `config/bench_dev.conf`, `config/phase0.conf`) of `feat/ep-phase0` at `201188a`, on 2026-11-17 at 19:22 and 19:28 UTC: helsinki `~/vol/ep0-logs/fin-p0.build.log` (application FLASH 936,652 B, RAM 497,244 B; `CONFIG_BT_AUDIO=y`, `CONFIG_LIBLC3=y`) and `~/vol/ep0-logs/fin-p0c.build.log` (FLASH 795,024 B, RAM 470,896 B; both unset, `CONFIG_QA_PHASE0_MLDSA` unset in both), a difference of 141,628 B and 26,348 B. Their `.config` files (`~/vol/fwbuild/ep0-fin-p0/firmware/zephyr/.config`, `~/vol/fwbuild/ep0-fin-p0c/...`) differ in 78 lines, all of them `CONFIG_LIBLC3` or Bluetooth symbols of the LE Audio host and its dependants (extended advertising, event buffer sizes). The phase-0 sizes are those that `~/vol/ep0-artifacts-201188a/BUILD_INFO.txt` records for `201188a`. Revision 4 cited `74a43d2`, `934e22a` and `~/vol/ep0-artifacts/BUILD_INFO.txt` (`86293ad`), whose `lm20b-phase0` and `lm20b-phase0-mldsa` images differ by 132,948 B and 10,956 B only, because the second also adds ML-DSA-87 (at `201188a`, `fin-p0m.build.log` against `fin-p0c.build.log`: 8,728 B of flash, 15,400 B of RAM) |
| Revision 4: the open points TODO-1 to TODO-19 | server branch `kat/earbud-ep-v1` `e7cde5d` `tools/kat/earbud-ep-v1/README.md` (section "Open points", the list TODO-1 to TODO-19) |
