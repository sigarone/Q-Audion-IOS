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
| iOS | `QAudionEngine/Sources/QAudionEngine/Utils/PhoneHash.swift:74` | `hex(sha256(utf8(normalizeE164(input))))` lowercase | Strips `[\s ().\-/]`, replaces leading `00` with `+`, prepends `defaultCountry` (`+39`) when no `+`. Regex `^\+[1-9]\d{7,14}$`. |
| Android | `feature/feature-auth/src/main/java/com/bcrypto/qaudion/feature/auth/PhoneHashHelper.kt:61` | `hex(sha256(utf8(normalizeE164(input))))` lowercase | Same strip regex, same `00→+` substitution, same E.164 regex, same `defaultCountry = "+39"`. Byte-for-byte mirror of iOS per KDoc. |
| Desktop | `src/main/transport/BCryptoApi.ts:624` | (not computed; sends pre-hashed values from iOS/Android to `/contacts/discover`) | Desktop calls `/contacts/discover` with `phone_hashes` supplied externally; no local normalise+hash. Contact discovery initiated by mobile clients. |
| Server | `internal/api/account.go:180–185` | (not computed; validates 64-hex format only) | `GET /api/v1/contacts/discover` accepts `phone_hashes[]`; server rejects non-64-hex values via `isSHA256Hex` but never re-hashes. |

**Status:** ✅ verified — iOS and Android compute identical bytes for `+39 333 1234567` → `hex(sha256("+393331234567"))` lowercase (64-char hex). Desktop does not hash independently; it relays mobile-computed hashes.

### Username hash (peppered)

| Platform | Source | Algorithm | Notes |
|---|---|---|---|
| iOS | ❌ not implemented | — | No `username`, `pepper`, or `/discover/username` usage found anywhere in `QAudionEngine/Sources`. Phase B.7 gap. |
| Android | ❌ not implemented | — | No `username` hash or `/discover/pepper` call found in `qaudion-android-new`. Phase B.7 gap. |
| Desktop | `src/main/Application.ts:998–1004` | `base64(sha256(lower(handle) ‖ pepper)[:16])` | Fetches 32-byte pepper via `GET /api/v1/discover/pepper`; hashes with Node `createHash('sha256')`, truncates to 16 bytes, sends as base64 to `GET /discover/username?h=`. |
| Server | `cmd/bcrypto-lite/main.go:2247–2253` | `sha256(lower(username) ‖ pepper)[:16]` stored as raw bytes; base64-encoded in response | Pepper served at `GET /api/v1/discover/pepper`. Validates 3–32 chars `[a-zA-Z0-9_]`, normalises to lowercase. Returns `username_hash_b64` + `alg="sha256-peppered-v1"`. |

**Status:** ⚠️ Desktop and Server agree on `sha256(lower ‖ pepper)[:16]` (identical byte order, same truncation). iOS and Android have no implementation yet — see "Open discrepancies" §1.

### Contact-discovery hash v2 (peppered)

| Platform | Source | Algorithm | Notes |
|---|---|---|---|
| iOS | ❌ not implemented | — | `BCryptoContactsApiImpl.swift:9` calls legacy `/api/v1/contacts/discover` (v1, unpeppered) only. No `contacts/pepper` fetch or v2 endpoint. Phase B.7 gap. |
| Android | `feature/feature-contacts/src/main/java/com/bcrypto/qaudion/feature/contacts/domain/DiscoverContactsUseCase.kt:284–289` | `hex(sha256(pepper ‖ utf8(e164)))` lowercase | Fetches 32-byte pepper via `GET /api/v1/contacts/pepper`; calls `POST /contacts/discover-v2`. Falls back to v1 when pepper unavailable. Also registers own peppered hashes via `POST /contacts/phones`. |
| Desktop | ❌ not implemented | — | No `/contacts/pepper`, `/contacts/discover-v2`, or `RegisterPepperedPhones` call found anywhere in `src/`. Desktop relies solely on v1 unpeppered discovery. Phase B.7 gap. |
| Server | `internal/store/bbolt.go:88–90`, `cmd/bcrypto-lite/main.go:2007–2031` | (not computed; validates and stores client-supplied hex hashes) | Serves 32-byte random pepper at `GET /api/v1/contacts/pepper` (alg `sha256-peppered-v1`). Stores peppered hashes in `bucketPepperedPhones`; queries them at `POST /contacts/discover-v2`. Never recomputes. |

**Status:** ⚠️ Android implements v2 peppered discovery; iOS and Desktop use v1 (unpeppered) only — see "Open discrepancies" §2.

### Public-key fingerprint (display)

| Platform | Source | Algorithm | Notes |
|---|---|---|---|
| iOS | `QAudionEngine/Sources/QAudionEngine/Crypto/ContactKeyExchange.swift:142–144` | `hex(sha256(psk_bytes))` — full 64-char lowercase hex | No abbreviated display format. The full hex string is stored via `SovereignKeyVault.storePsk(fingerprint:)` and displayed verbatim (see `KeyManagementView.swift:19`). |
| Android | `qaudion-engine/src/main/java/com/bcrypto/qaudion/crypto/SovereignKeyVault.kt:656–658` | `sha256(key_bytes)` → take first 16 hex chars → group into 4×4 with dots: `xxxx.xxxx.xxxx.xxxx` | `fullFingerprint` = full 64-char hex; `fingerprint` = `formatDisplayFingerprint(fullHex)` = `fullHex.take(16).chunked(4).joinToString(".")`. Wire protocol uses `fullFingerprint` for PSK negotiation. |
| Desktop | `src/main/store/SovereignKeyVault.ts:362` | `sha256(material).digest('hex')` — full 64-char lowercase hex | Stored as `fingerprint` field in `PskEntry`; displayed as `fingerprint.slice(0, 28) + "…"` in UI (`CryptoProfileBody.svelte:135`). No dot-grouped abbreviated format. |
| Server | 🟡 not applicable | — | Server stores PSK metadata via KMS delivery; it does not compute PSK fingerprints directly. `internal/kms/handlers.go` surfaces the `fingerprint` field from the client-submitted key record. |

**Status:** ⚠️ All platforms compute `sha256(psk_bytes)` hex, but display formatting diverges: Android shows abbreviated `xxxx.xxxx.xxxx.xxxx` (first 16 hex chars in 4 groups), while iOS and Desktop show a full or truncated 64-char hex string without dot-grouping — see "Open discrepancies" §3.

## §5.2 — Symmetric crypto

| Item | Spec value | iOS | Android | Desktop | Server | Status |
|---|---|---|---|---|---|---|
| AEAD | AES-256-GCM, 12B nonce, 16B tag | `AES.GCM` (CryptoKit); `nonceSize=12`, `tagSize=16` — `CryptoConstants.swift:15–16`, enforced in `AeadCipher.swift:36,43` | `"AES/GCM/NoPadding"`; `GCMParameterSpec(128, nonce)`, `NONCE_SIZE=12`, `TAG_SIZE=16` — `CryptoConstants.kt:15,25–29`, `AeadCipher.kt:110–113` | `AES_KEY_SIZE_BYTES=32`, `GCM_NONCE_SIZE_BYTES=12`, `GCM_TAG_SIZE_BYTES=16` — `src/shared/protocol/constants.ts:14–16` | `NonceSize=12`, `cipher.NewGCM` via `crypto/aes`+`crypto/cipher` — `internal/kms/kms.go:18,104` | ✅ identical |
| Hash | SHA-256 everywhere | `SHA256` (CryptoKit) — used in `MessageCrypto.swift:124`, `SessionManager.swift:89`, `HybridPqcKeyExchange.swift:218`, `ContactKeyExchange.swift:134` | `HmacSHA256` for HKDF (`CryptoConstants.kt:41`), `MessageDigest("SHA-256")` for digests — `CertificatePinning.kt:144`, `RecoveryCrypto.kt:87–88` | Web Crypto `SubtleCrypto.digest('SHA-256')` + `hkdf` with `hash:'SHA-256'` — used in `PqcKeyExchange.ts`, `MessageCrypto.ts` | `crypto/sha256` stdlib — `internal/kms/kms.go:8,44,52` | ✅ identical |
| HKDF | HKDF-SHA256, 32B output | `HKDF<SHA256>.deriveKey(…, outputByteCount: 32)` (CryptoKit) — `MessageCrypto.swift:124`, `SessionManager.swift:89`, `HybridPqcKeyExchange.swift:218` | `HKDFBytesGenerator(SHA256Digest())` (Bouncy Castle) → 32B — `DeviceLinkingProtocol.kt:171`, `HybridPqcKeyExchange.kt:11`, `RecoveryCrypto.kt:86–90` | `crypto.subtle.deriveBits({name:'HKDF', hash:'SHA-256', …}, key, 256)` — `PqcKeyExchange.ts`, `PqcHandshake.ts:47–50` | `hkdf.New(sha256.New, …)` via `golang.org/x/crypto/hkdf` → 32B — `internal/kms/kms.go:13,92–94` | ✅ identical |

## §5.3 — HKDF labels

> Note on spec column for rows 6–8: the spec table used constant *names* (`FRAME_CHAIN_AUDIO`, `FRAME_CHAIN_VIDEO`, `FILE_KEY`) as placeholders. The canonical wire bytes are defined in Desktop `src/shared/protocol/constants.ts` and reproduced below.

| Purpose | Spec salt | Spec info | iOS source | Android source | Desktop source | Status |
|---|---|---|---|---|---|---|
| Message conversation key | per-pair (random 32B) | `"q-audion-msg-key"` | `CryptoConstants.HKDF_INFO_MSG_KEY = "q-audion-msg-key"` — `CryptoConstants.swift:39`; used in `MessageCrypto.swift:46,94` | `HKDF_INFO = "q-audion-msg-key"` — `MessageCrypto.kt:95`; used at line 229 | `HKDF_LABELS.MSG_KEY = 'q-audion-msg-key'` — `constants.ts:22`; used in `MessageCrypto.ts:20` | ✅ identical |
| Device-link PSK | `"qaudion-link-salt"` | `"qaudion-device-link-v1"` | ❌ not implemented — no `DeviceLinkingProtocol` or these label strings found anywhere in `QAudionEngine/Sources`. Phase B.6 gap. | `HKDF_INFO = "qaudion-device-link-v1"` (companion object) + `"qaudion-link-salt".toByteArray()` at call site — `DeviceLinkingProtocol.kt:42,174` | ❌ not implemented — no device-link HKDF or `qaudion-link-salt` found in `src/`. Desktop has no multi-device linking flow. | ⚠️ Android only — see "Open discrepancies" §4 |
| NFC collaborative PSK | `sha256(sorted(pubA, pubB))` | `"Q-Audion NFC Collaborative PSK v1"` | `CryptoConstants.hkdfNfcCollaborativePskInfo = "Q-Audion NFC Collaborative PSK v1"` — `CryptoConstants.swift:52` | `HKDF_INFO_COLLAB = "Q-Audion NFC Collaborative PSK v1"` — `NfcProtocol.kt:135` | ❌ not implemented — NFC pairing not present in Desktop (`src/`). | ⚠️ iOS+Android match; Desktop N/A — see "Open discrepancies" §5 |
| Hybrid PQC session key | `HYBRID_PQC_SALT_V1` = `"q-audion-hybrid-pqc-v1"` | `HYBRID_PQC_INFO` = `"q-audion-session-key"` | `hybridKdfSalt = "q-audion-hybrid-pqc-v1"`, `hybridKdfInfo = "q-audion-session-key"` — `CryptoConstants.swift:85,87`; consumed in `HybridPqcKeyExchange.swift:215–216` | `HYBRID_KDF_SALT = "q-audion-hybrid-pqc-v1"`, `HYBRID_KDF_INFO = "q-audion-session-key"` — `CryptoConstants.kt:124,127`; used in `HybridPqcKeyExchange.kt:42` | `HYBRID_PQC_SALT_V1: 'q-audion-hybrid-pqc-v1'`, `HYBRID_PQC_INFO: 'q-audion-session-key'` — `constants.ts:38,40`; consumed in `PqcHandshake.ts:48,50` and `PqcKeyExchange.ts:227–228` | ✅ identical |
| Recovery seed → secret | `"recovery-auth-v1"` (spec) | BIP-39 mnemonic (spec) | ❌ not implemented — iOS sends `recoverySecret` as an opaque string via `BCryptoAccountApiImpl.swift:71` but no local HKDF derivation with `"recovery-auth-v1"` exists in `QAudionEngine/Sources`. Phase B.8 gap. | `info = "recovery-auth-v1"`, `salt = "bcrypto-recov-v1"`, `ikm = entropy` — `RecoveryCrypto.kt:70–71`. Note: actual salt is `"bcrypto-recov-v1"`, not `"recovery-auth-v1"` as the spec salt column states — see "Open discrepancies" §6. | ❌ not implemented — no recovery HKDF in `src/`. Desktop has no seed-phrase recovery flow. | ⚠️ Android only; spec salt/info description inaccurate — see "Open discrepancies" §6 |
| Frame chain (audio) | chainKey | `"q-audion-frame-key"` (spec column used constant name `FRAME_CHAIN_AUDIO`; canonical bytes from Desktop) | `hkdfInfoChain = "q-audion-frame-key"` — `CryptoConstants.swift:28`; used in `SessionManager.swift:41,72` | `HKDF_INFO_CHAIN = "q-audion-frame-key"` — `CryptoConstants.kt:54` | `FRAME_CHAIN_AUDIO: 'q-audion-frame-key'` — `constants.ts:24` | ✅ identical |
| Frame chain (video) | chainKey | `"q-audion-video-frame-key"` (spec column used constant name `FRAME_CHAIN_VIDEO`) | `hkdfInfoVideoChain = "q-audion-video-frame-key"` — `CryptoConstants.swift:34` | `HKDF_INFO_VIDEO_CHAIN = "q-audion-video-frame-key"` — `CryptoConstants.kt:67` | `FRAME_CHAIN_VIDEO: 'q-audion-video-frame-key'` — `constants.ts:26` | ✅ identical |
| Attachment | contactPSK | `"q-audion-file-key"` (spec column used constant name `FILE_KEY`) | `HKDF_INFO_FILE_KEY = "q-audion-file-key"` — `CryptoConstants.swift:40`; consumed in `FileTransfer.swift:26` | `HKDF_INFO = "q-audion-file-key"` — `FileCrypto.kt:38` | `FILE_KEY: 'q-audion-file-key'` — `constants.ts:34`; referenced in `FileTransfer.ts:34–35` | ✅ identical |

## §5.4 — Asymmetric crypto

### ML-KEM-1024 (FIPS 203 / NIST Level 5)

| Platform | Source | Library / binding | Key sizes | Observation |
|---|---|---|---|---|
| iOS | `QAudionEngine/Sources/QAudionEngine/Crypto/PqcKeyExchange.swift:22` | `CLiboqs` — `OQS_KEM_new("ML-KEM-1024")` via C bindings | pk=1568B, sk=3168B, ct=1568B, ss=32B | Raw byte format natively. `extractRawPublicKey` strips any header if encoded key >1568B. |
| Android | `qaudion-engine/src/main/java/com/bcrypto/qaudion/crypto/PqcKeyExchange.kt:80` | BouncyCastle `KyberParameters.kyber1024` (bc lightweight API, no JCE) | pk=1568B (`pubParams.encoded`), sk=3168B, ss=32B | BC's `KyberKEMGenerator.generateEncapsulated` + `KyberKEMExtractor.extractSecret`. Wire-compatible with iOS raw format per KDoc comment. |
| Desktop | `src/main/crypto/PqcKeyExchange.ts:44–47`, `src/main/crypto/MlKem.ts` | `@noble/post-quantum` `ml-kem-1024` — byte-identical to BC per KAT gate | pk=1568B, sk=3168B, ct=1568B, ss=32B | `MlKem1024Compat.generateKeyPair/encap/decap`. Comment confirms KAT-verified compatibility with BouncyCastle. |
| Server | 🟡 not applicable | — | — | Server lite does not perform ML-KEM operations; acts as relay only for `opaque_message` PQC handshake payloads. |

### X25519 (RFC 7748 ephemeral ECDH)

| Platform | Source | Library / binding | Key size | Observation |
|---|---|---|---|---|
| iOS | `HybridPqcKeyExchange.swift:86`, `SovereignIdentityManager.swift:59` | CryptoKit `Curve25519.KeyAgreement` | sk=32B, pk=32B | `PrivateKey().sharedSecretFromKeyAgreement(with:)`. Also used as identity encryption key (`SovereignIdentity.encryptionPrivate/Public`). |
| Android | `HybridKeyAgreement.kt:7` (`X25519Agreement`, `X25519KeyPairGenerator`), `DeviceLinkingProtocol.kt:5` | BouncyCastle `X25519Agreement` | sk=32B, pk=32B | Raw byte output 32B. Matches iOS CryptoKit raw representation. |
| Desktop | `src/main/crypto/PqcKeyExchange.ts:34`, `src/main/identity/IdentityKeyStore.ts:39` | `@noble/curves/ed25519` (`x25519` sub-export) | sk=32B, pk=32B | `x25519.getSharedSecret(sk, remotePk)`. Same RFC 7748 Curve25519 — output bytes identical. |
| Server | 🟡 not applicable | — | — | Server does not perform X25519; forwards opaque encrypted payloads. |

### Ed25519 (RFC 8032 signing)

| Platform | Source | Library / binding | Key size | Observation |
|---|---|---|---|---|
| iOS | `SovereignIdentityManager.swift:28–29`, `SovereignIdentityManager.swift:60` | CryptoKit `Curve25519.Signing` | seed=32B, pk=32B, sig=64B | `signingPrivate` = seed, `signingPublic` = compressed public key. Used for challenge-response auth at `:112`. |
| Android | `qaudion-engine/src/main/java/com/bcrypto/qaudion/crypto/Ed25519DeviceSigner.kt:11–13`, `:36` | BouncyCastle `Ed25519PrivateKeyParameters` / `Ed25519Signer` | pk=32B (`KEY_SIZE`), sig=64B | Device signing identity; public key registered as `sign_pub_key`. Matches iOS 32B public key encoding. |
| Desktop | `src/main/identity/IdentityKeyStore.ts:12`, `src/main/identity/IdentityBundleCodec.ts:14` | `@noble/curves/ed25519` (`ed25519` export) | seed=32B, pk=32B, sig=64B | `IK_ed` key. Used to sign `IdentityBundle` (long-term device identity). |
| Server | `internal/api/version.go:21` | Go stdlib `crypto/ed25519` | seed=32B, pk=32B | OTA update signing (`"ota_signing":"Ed25519"`). Server does not sign call messages directly. |

### Hybrid KEX combine (HKDF combiner)

Two distinct hybrid schemes exist across platforms; both are in production:

| Scheme | Platforms | IKM | HKDF | Salt | Info | Output |
|---|---|---|---|---|---|---|
| **Dual hybrid** (fallback) | iOS + Android + Desktop | `ML-KEM-ss ‖ X25519-ss` | HKDF-SHA-256 | `"q-audion-hybrid-pqc-v1"` | `"q-audion-session-key"` | 32B |
| **Triple hybrid** (preferred) | Android + Desktop | `ML-KEM-ss ‖ X25519-ss ‖ X448-ss` | HKDF-SHA-512 | `"qaudion-triple-hybrid-v1"` | `"session-key"` | 64B |

iOS implements **dual hybrid only** (`HybridPqcKeyExchange.swift:214–225`; `CryptoConstants.swift:85,87`) — no X448. Android `HybridKeyAgreement.kt:60–63` defines `HKDF_SALT="qaudion-hybrid-v1"` / `HKDF_INFO="key-agreement"` for the dual-curve (X25519+X448) sub-combine, and `CryptoConstants.kt:124,127` define the triple-hybrid outer combine matching Desktop `constants.ts:42,44`. Desktop `PqcKeyExchange.ts:22–28` documents both paths.

**Status:** ✅ ML-KEM-1024, X25519, Ed25519 are byte-identical across iOS/Android/Desktop. ⚠️ iOS does not implement X448 or the triple-hybrid path — when negotiating with Android or Desktop clients that send X448 public keys, iOS falls back to the 32B dual-hybrid result; Android/Desktop expect a 64B triple-hybrid result. This is an open interop gap — see "Open discrepancies" §7.

## §5.5 — NFC collaborative pairing

| Item | Canonical value | iOS source | Android source | Desktop |
|---|---|---|---|---|
| AID | `F0BCF1073A5100` (7 bytes) | N/A (reader only) | `NfcConstants.AID_HEX = "F0BCF1073A5100"` — `app/src/main/java/com/bcrypto/qaudion/nfc/NfcConstants.kt:37` | 🟡 N/A |
| APDU SELECT | `00 A4 04 00 07 F0 BC F1 07 3A 51 00` | N/A | `NfcConstants.SELECT_AID_HEADER` — `NfcApduService.kt:8` | 🟡 N/A |
| KEY_EXCHANGE payload | 64B: `[32B X25519 pubkey ‖ 32B random entropy]` | `NfcProtocol.swift:114–122` (reads `[nameLen:1][name:N][key:32]` for NDEF mode); see note below | `NfcProtocol.kt:114–115` (`COLLAB_PAYLOAD_SIZE = X25519_KEY_SIZE + ENTROPY_SIZE = 64`) | 🟡 N/A |
| HKDF info (X25519-only) | `"Q-Audion NFC Collaborative PSK v1"` | `CryptoConstants.hkdfNfcCollaborativePskInfo` — `CryptoConstants.swift:52` | `HKDF_INFO_COLLAB = "Q-Audion NFC Collaborative PSK v1"` — `NfcProtocol.kt:135` | 🟡 N/A |
| HKDF info (hybrid PQC) | `"Q-Audion NFC Hybrid PQC PSK v1"` | `CryptoConstants.hkdfNfcHybridPqcPskInfo` — `CryptoConstants.swift:54` | `HKDF_INFO_HYBRID = "Q-Audion NFC Hybrid PQC PSK v1"` — `NfcProtocol.kt:136` | 🟡 N/A |
| HKDF salt | `sha256(sorted_lex(pubA, pubB))` where sorted = lexicographic byte-order, concatenated | `CryptoConstants.swift:52` (comment) | `NfcProtocol.kt:281–286` (`sortPublicKeys` + `MessageDigest.SHA-256`) | 🟡 N/A |
| IKM (X25519-only) | `X25519_shared ‖ entropy_a ‖ entropy_b` | `CryptoConstants.swift:52` (comment) | `NfcProtocol.kt:288–301` | 🟡 N/A |
| IKM (hybrid PQC) | `X25519_shared ‖ ML-KEM-ss ‖ entropy_a ‖ entropy_b` | `CryptoConstants.swift:54` (comment) | `NfcProtocol.kt:289–301` (adds `pqcSharedSecret` when `pqcActive=true`) | 🟡 N/A |
| HKDF output | 32B PSK | Derived at `SovereignKeyVault.storePsk` | `NfcProtocol.kt:309` (`PSK_SIZE=32`) | 🟡 N/A |

**iOS limitation:** iPhone cannot act as NFC HCE host (no `HostApduService` equivalent on iOS). iOS devices can only READ NDEF tags or respond via `TAG`-format CoreNFC. For iOS-to-iOS pairing the QR code fallback (`NfcProtocol.generateQrPayload`) is used instead. The collaborative APDU exchange (INITIATOR ↔ RESPONDER roles) is an Android-to-Android flow; iOS participates only as the READER scanning an Android HCE device. This is documented in `NfcProtocol.swift:7–12`.

> Note: iOS `NfcProtocol.parsePskPayload` uses an NDEF `[nameLen:1][name:N][key:32]` format (for NFC tag read-back of pre-shared keys written by Android). The 64B collaborative APDU payload (`[pubkey32][entropy32]`) is a different code path used in the full APDU exchange; the iOS NDEF reader path is for legacy simple tag writes, not the collaborative ceremony.

**Status:** ✅ HKDF labels, salt construction, and key sizes are byte-identical between iOS and Android. Desktop is N/A (no NFC hardware).

## §5.6 — Device-linking binary QR

| Item | Spec value | iOS | Android | Desktop |
|---|---|---|---|---|
| Binary layout | `[32B X25519 pubkey ‖ 4B BE length ‖ userId UTF-8 ‖ 16B auth code]` | ❌ not implemented — no `DeviceLinkingProtocol` in `QAudionEngine/Sources` | `DeviceLinkingProtocol.encodeLinkQr:94–104` — `ByteBuffer.allocate(32+4+userIdBytes.size+16)`; `putInt(userIdBytes.size)` = big-endian 4B | 🟡 not implemented — no QR device-link flow in Desktop `src/` |
| Base64 encoding | base64url, no padding | ❌ not implemented | `Base64.URL_SAFE or Base64.NO_WRAP` — `DeviceLinkingProtocol.kt:103` | 🟡 N/A |
| URL scheme | `qaudion://link/<blob>` | ❌ not implemented | `QR_SCHEME = "qaudion://link/"` — `DeviceLinkingProtocol.kt:37` | 🟡 N/A |
| HKDF (sync key) | `HKDF-SHA256(X25519_shared, salt="qaudion-link-salt", info="qaudion-device-link-v1", 32B)` | ❌ not implemented | `DeviceLinkingProtocol.deriveSyncKey:174–178` — `HKDFParameters(sharedSecret, "qaudion-link-salt".toByteArray(), HKDF_INFO.toByteArray())` where `HKDF_INFO="qaudion-device-link-v1"` | 🟡 N/A |
| AES-256-GCM (sync payload) | 12B nonce, 128-bit tag, `"AES/GCM/NoPadding"` | ❌ not implemented | `DeviceLinkingProtocol.kt:15–16`: `GCM_NONCE_SIZE=12`, `GCM_TAG_BITS=128` | 🟡 N/A |

**Status:** ⚠️ Android is the sole implementation. iOS and Desktop have no device-link QR flow. Binary layout confirmed at `DeviceLinkingProtocol.kt:86–104`. The 4B integer written by `ByteBuffer.putInt()` is big-endian (Java `ByteBuffer` defaults to big-endian). See also "Open discrepancies" §4 (tracked as Phase B.6).

## §5.7 — VoIP push payload

Spec form: `{type:"incoming_call", call_id, caller_id, caller_name, call_type}`.

| Platform | Source | Push channel | Payload | Status |
|---|---|---|---|---|
| iOS | ❌ not implemented | PushKit / APNs VoIP (planned) | No `PKPushRegistry` or `CXProvider.reportNewIncomingCall` found in `QAudionEngine/Sources` or `QAudionApp/`. Scaffolding is a Phase A.5 deliverable. | ❌ Phase A.5 (PushKit scaffolding) |
| Android | `app/src/main/java/com/bcrypto/qaudion/push/FcmService.kt:99,110–113,327` | FCM data message (`type = "call_incoming"`) | `data["call_id"]`, `data["caller_id"]`, `data["caller_name"]`, `data["call_type"]` (defaults to `CALL_TYPE_AUDIO`) — `FcmService.kt:111–114` | ✅ FCM implemented |
| Desktop | 🟡 N/A | Electron desktop app — no mobile push mechanism | — | 🟡 N/A |
| Server | ❌ APNs not implemented in lite (FCM only) | BCrypto lite pushes via FCM (`internal/push/`) only | No APNs VoIP (`voip.apns`) path found in `bcrypto-server/internal/push/` — only FCM token registration and send. APNs VoIP (PushKit) requires a separate `com.apple.voip` APNs certificate path. | ❌ APNs not implemented in lite (FCM only) |

> Note: Android FCM payload uses key `"call_incoming"` (value of `TYPE_CALL_INCOMING` constant, `FcmService.kt:327`) as the `type` field, while `ANDROID_REFERENCE.md` documents `"incoming_call"`. The actual wire constant is `"call_incoming"`. This is an intra-Android documentation discrepancy; the code is authoritative.

**Status:** ⚠️ Android FCM call push is implemented and functional. iOS PushKit is not implemented. Server has no APNs VoIP path — see "Open discrepancies" §8.

## §5.8 — WebSocket envelope

Server-authoritative definition: `internal/signaling/messages.go:55–59`:
```go
type Envelope struct {
    Type string          `json:"type"`
    Data json.RawMessage `json:"data,omitempty"`
    ID   string          `json:"id,omitempty"` // Request ID for correlation
}
```
`ID` is present in the struct but tagged `omitempty`. **Server's `NewEnvelope` constructor (`messages.go:266–275`) never sets `ID`** — server-emitted messages have no `id` field. The server dispatcher does not read `env.ID` from client messages (verified by absence of `env.ID` reads in `cmd/bcrypto-lite/main.go`).

| Platform | Source | Envelope emitted | `id` field | Observation |
|---|---|---|---|---|
| iOS | `BCryptoWebSocketClient.swift:151–159` | `{"type":"...", "data":{...}, "id":"<UUID>"}` | ✅ present — `"id": UUID().uuidString` added on every outbound message | iOS always emits `id`; server accepts but ignores it (`omitempty`, never read). Comment at line 149 references `internal/signaling/messages.go`. |
| Android | `WsCodec.kt:38–44` | `{"type":"...", "data":{...}}` or `{"type":"...", "data":{...}, "id":"..."}` | ✅ conditional — `command.correlationId?.let { put("id", it) }` at line 43 | `id` is only included when the `WsCommand` has a non-null `correlationId`. Most commands have `correlationId=null`, so most Android envelopes omit `id`. |
| Desktop | `BCryptoSocket.ts:14–22` (imports `Envelope` from `@shared/protocol/messages`) | `{"type":"...", "data":{...}}` | ❌ not emitted — Desktop constructs envelopes via `WS_MESSAGE_TYPES` dispatch; no `id` injection found in `BCryptoSocket.ts` | Desktop sends minimal `{type, data}` envelopes. `randomUUID` import at line 15 is used elsewhere (not for envelope ID). |
| Server | `internal/signaling/messages.go:266–275` | `{"type":"...", "data":{...}}` | ❌ never set — `NewEnvelope` only populates `Type` and `Data`; `ID` is zero-value (`omitempty` → omitted) | Server fan-out messages have no `id`. |

**Note on `id` handling:** iOS always sends `id`; server never reads it. There is no correlation mechanism on the server for request/response pairing — the comment in `messages.go:58` ("Request ID for correlation") is aspirational. In practice the `id` field is a one-way client annotation that is silently dropped.

> Open discrepancy: `ANDROID_REFERENCE.md` claim `{type, data, id}` states `id` is "present on both directions" — this is stale. Android only sends `id` when `correlationId` is non-null (typically null). Server never sends `id`. F2.3 will update `ANDROID_REFERENCE.md`. See "Open discrepancies" §9.

**Status:** ✅ Core envelope `{type, data}` is identical across all platforms. ⚠️ iOS sends a spurious `id` field that server and Android ignore; Desktop does not send `id`.

## §5.9 — TURN credentials

Server-authoritative formula (`internal/turn/server.go:207–218`):
- `username = fmt.Sprintf("%d:%s", expiry_unix_timestamp, userID)` where `expiry = now + TTL`
- `password = base64.StdEncoding(HMAC-SHA1(secret, username))`
- `ttl = cfg.CredentialTTL` hours (default 1h → 3600s)

| Platform | Source | Endpoint called | Parsing | Observation |
|---|---|---|---|---|
| iOS | `BCryptoCallingApiImpl.swift:47–50` + `CallingApi.swift:30–35` | `GET /api/v1/calling/relays` | `RelayServer: Codable { urls:[String], username:String, credential:String, ttl:Int }` — `CallingApi.swift:30–35` | Decodes `username`, `credential`, `ttl` directly from JSON. Does not re-derive HMAC locally. |
| Android | `RelayCredentialsProvider.kt:94–113` via `api.getRelays()` | `GET /api/v1/calling/relays` | `RelayServer(urls, username?, credential?)` — `RelayCredentialsProvider.kt:27–31` | Caches bundle with TTL-aware refresh (`REFRESH_BEFORE_TTL_MS = 5min`). `ttlSeconds` comes from `RelaysResponse.relays[n].ttl`. |
| Desktop | `BCryptoApi.ts:783–784` + `rest.ts:105–119` | `GET /api/v1/calling/relays` (note: path is `/calling/relays` not `/api/v1/calling/relays` — prefix added by `BCryptoApi.json()`) | `IceServerEntry { urls, username?, credential?, ttl? }` — `rest.ts:105–109` | Passes `username`/`credential` directly into `RTCPeerConnection` ICE servers. |
| Server | `internal/turn/server.go:207–218` + `cmd/bcrypto-lite/main.go:2574–2640` | Issues credentials at `GET /api/v1/calling/relays` handler | `GenerateCredentials(userID)`: `expiry=now+TTL`, `username="${expiry}:${userID}"`, `password=base64(HMAC-SHA1(secret, username))`, `ttl=int(seconds)` | Pion TURN server validates credentials with same formula at `validateTURNCredential` (`server.go:237–261`). |

**TURN credential format (wire):**
- `username`: `"<unix_expiry_timestamp>:<userID>"` — e.g. `"1745000000:a3b4c5d6-..."`
- `password`: `base64-standard(HMAC-SHA1(turn_secret_bytes, utf8(username)))`
- `ttl`: integer seconds (default 3600)

**Status:** ✅ All three client platforms call `GET /api/v1/calling/relays` and consume `{urls, username, credential, ttl}` directly from the server response. No client re-derives the HMAC — the server pre-computes it.

## §5.10 — Backup file format `.qabk`

### Desktop — canonical container layout (authoritative)

Source: `qaudion-desktop/src/main/backup/BackupService.ts:1–51`

```
Offset  Len  Field
──────────────────────────────────────────────────────
 0       4   magic: 0x51 0x41 0x42 0x4B  ("QABK")
 4       1   version: 0x01
 5       1   reserved: 0x00
 6       2   scrypt log2N (uint16 big-endian; default 15 → N=32768)
 8       1   scrypt r (uint8; default 8)
 9       1   scrypt p (uint8; default 1)
10      32   salt (random, 32 bytes)
42      12   GCM nonce (random, 12 bytes)
54       N   ciphertext (AES-256-GCM encrypted JSON snapshot)
54+N    16   GCM tag (128-bit)
```

- **KDF:** `scrypt(passphrase_NFKC_normalized, salt, N=2^log2N, r, p, dkLen=32)` → 32B AES-256 key.
- **AEAD:** AES-256-GCM, 12B nonce, 16B tag.
- **AAD:** `"qaudion-backup:v1"` (17 UTF-8 bytes) — `BackupService.ts:51`.
- **Plaintext:** JSON-serialized `BackupSnapshot { schema:1, createdAt, identity, vault, contacts, messages, callLog }`.
- scrypt params in header are read back on decrypt (forward-compatible if future versions change N).

### iOS container layout

Source: `QAudionEngine/Sources/QAudionEngine/Crypto/BackupKeyVault.swift`

`BackupKeyVault.swift` is a **key storage wrapper only** — it stores/restores named keys via `QAudionKeyStore` (Keychain). It contains no scrypt, no AES-GCM encrypt/decrypt, no file serialization, and no magic bytes. **iOS has no `.qabk` backup container implementation.** This is a Phase 4 / Phase A.2 dependency.

### Android container layout

Source: `feature/feature-settings/src/main/java/com/bcrypto/qaudion/feature/settings/domain/BackupEncryptUseCase.kt`

```
Offset  Len  Field
──────────────────────────────────────────────────────
 0       4   magic: 0x51 0x41 0x55 0x44  ("QAUD")  ← DIFFERS from Desktop "QABK"
 4       1   version: 0x01
 5      16   salt (random, 16 bytes)               ← DIFFERS from Desktop (32B salt)
21      12   GCM nonce (random, 12 bytes)
33       N   AES-256-GCM ciphertext (includes 16B tag appended by JCE doFinal)
```

- **KDF:** `scrypt(N=2^DEFAULT_LOG_N, r=8, p=1, dkLen=32)` where `DEFAULT_LOG_N=17` (N=131072) — `BackupEncryptUseCase.kt:123`. **DIFFERS from Desktop (N=2^15 = 32768).**
- **AEAD:** `"AES/GCM/NoPadding"`, GCMParameterSpec(128, nonce). Tag is appended inside ciphertext by JCE.
- **AAD:** `"qaudion.backup.v1"` (17 bytes) — `BackupEncryptUseCase.kt:120`. **DIFFERS from Desktop (`"qaudion-backup:v1"` — uses hyphen not dot, same 17B but different byte values at positions 8 and 15).**

### Cross-platform comparison

| Item | Desktop | Android | iOS |
|---|---|---|---|
| Magic | `QABK` (`0x51,0x41,0x42,0x4B`) | `QAUD` (`0x51,0x41,0x55,0x44`) | ❌ not implemented |
| Salt size | 32B | 16B | ❌ not implemented |
| scrypt log2N (default) | 15 (N=32768) | 17 (N=131072) | ❌ not implemented |
| scrypt r, p | 8, 1 | 8, 1 | ❌ not implemented |
| Nonce | 12B (in header) | 12B (in ciphertext prefix) | ❌ not implemented |
| GCM tag | 16B (separate, after ciphertext) | 16B (appended by JCE inside ciphertext blob) | ❌ not implemented |
| AAD | `"qaudion-backup:v1"` (hyphen) | `"qaudion.backup.v1"` (dot) | ❌ not implemented |
| Log2N in header | ✅ yes (2B uint16 BE at offset 6) | ❌ no (hardcoded) | ❌ not implemented |

**Status:** ⚠️ Desktop and Android have INCOMPATIBLE `.qabk` container formats (different magic, salt size, scrypt N, AAD string). A backup file produced by Desktop cannot be decrypted by Android and vice versa. iOS has no implementation. This must be aligned before backup cross-platform restore works — see "Open discrepancies" §10.

## §5.11 — Frozen wire types

All 24 WebSocket command/event types and the ~38 REST endpoints were fully audited in:
- **PHASE1_AUDIT.md** (commit `1c113ac`, date 2026-04-20) — WS command coverage matrix across iOS vs Android
- **PHASE1_REST_AUDIT.md** (commit `82cb970`, date 2026-04-20) — 35 Android-authoritative REST endpoints vs iOS

Last confirmed frozen: **2026-04-20**. The tables below summarize status; for full drift details see those two docs.

### WebSocket types (24 total — Android `WsCommand` + server `WsEvent`)

| Type | Direction | iOS | Android | Desktop | Server |
|---|---|---|---|---|---|
| `authenticate` | C→S | ✅ | ✅ | ✅ | ✅ |
| `ping` / `pong` | C→S / S→C | ✅ | ✅ | ✅ | ✅ |
| `call_offer` | C→S | ⚠️ field drift | ✅ | ✅ | ✅ |
| `call_answer` | C→S | ⚠️ field drift | ✅ | ✅ | ✅ |
| `call_ice` | C→S | ⚠️ field drift | ✅ | ✅ | ✅ |
| `call_hangup` | C→S | ⚠️ field drift | ✅ | ✅ | ✅ |
| `call_processing` | C→S | ✅ | ✅ | ✅ | ✅ |
| `call_ready` | C→S | ✅ | ✅ | ✅ | ✅ |
| `call_incoming` | S→C | ✅ | ✅ | ✅ | ✅ |
| `call_ring` | S→C | ✅ | ✅ | ✅ | ✅ |
| `call_peer_offline` | S→C | ✅ | ✅ | ✅ | ✅ |
| `call_cancel` | S→C | ✅ | ✅ | ✅ | ✅ |
| `audio_frame` | C→S | ✅ | ✅ | ✅ | ✅ |
| `opaque_message` | C→S | ✅ | ✅ | ✅ | ✅ |
| `presence_subscribe` | C→S | ✅ | ✅ | ✅ | ✅ |
| `presence_update` | S→C | ✅ | ✅ | ✅ | ✅ |
| `group_call_create` | C→S | ⚠️ schema split | ✅ | ✅ | ✅ |
| `group_call_join` | C→S | ✅ | ✅ | ✅ | ✅ |
| `group_call_leave` | C→S | ✅ | ✅ | ✅ | ✅ |
| `group_call_forward` | C→S | ⚠️ schema split | ✅ | ✅ | ✅ |
| `group_call_end` | C→S | ✅ | ✅ | ✅ | ✅ |
| `msg_send` / `msg_delivered` / `msg_read` / `msg_typing` | C→S | ❌ Phase 8 | ✅ | ✅ | ✅ |
| `video_frame` / `call_upgrade_*` / `call_video_state` | C→S/S→C | ❌ Phase 7 | ✅ | ✅ | ✅ |

### REST endpoints (~38 total, 35 Android-authoritative + iOS-only extras)

Key ✅ / ⚠️ / ❌ per PHASE1_REST_AUDIT.md (all 4 platforms verified 2026-04-20):

| Endpoint | iOS | Android | Desktop | Server |
|---|---|---|---|---|
| `POST register` | ⚠️ field drift | ✅ | ✅ | ✅ |
| `POST auth/login` | ⚠️ field drift | ✅ | ✅ | ✅ |
| `POST auth/refresh` | ✅ | ✅ | ✅ | ✅ |
| `DELETE auth/logout` | ✅ | ✅ | ✅ | ✅ |
| `GET profile` | ✅ | ✅ | ✅ | ✅ |
| `POST contacts/discover` | ✅ | ✅ | ✅ | ✅ |
| `GET contacts` | ✅ | ✅ | ✅ | ✅ |
| `GET calling/relays` | ✅ | ✅ | ✅ | ✅ |
| `POST files/upload` | ✅ | ✅ | ✅ | ✅ |
| `GET files/{id}` | ✅ | ✅ | ✅ | ✅ |
| `GET config/client` | ✅ | ✅ | ✅ | ✅ |
| `POST kms/acknowledge/{id}` | ✅ | ✅ | ✅ | ✅ |
| Other (recovery, directory, users/{id}, OTA, zk-*, wipe, version, health) | ❌ / ⚠️ | ✅ | varies | ✅ |

Full drift details: `docs/progress/PHASE1_REST_AUDIT.md` §3. Remaining drifts are being tracked per phase (B.6–B.9 for recovery/zk/linking; F2.x for schema fixes).

**Status:** ✅ frozen wire type vocabulary verified as of 2026-04-20. Noted drifts are payload-level and tracked per the audit doc, not wire-type additions.

## Open discrepancies (require user / server-team decision)

### §1 — Username hash: iOS and Android not implemented (F0.2)

iOS and Android have no `@handle` registration or `username_hash` computation. Desktop and Server agree on `sha256(lower(handle) ‖ pepper)[:16]` (base64-encoded). The two mobile platforms must implement the same algorithm before handle-based discovery can function cross-platform. Tracking: Phase B.7.

### §2 — Contact-discovery v2 (peppered): iOS and Desktop use v1 only (F0.2)

Android implements `sha256(pepper ‖ e164)` via `DiscoverContactsUseCase.peppered()` and calls `POST /contacts/discover-v2`. iOS (`BCryptoContactsApiImpl`) and Desktop have no `/contacts/pepper` fetch and no v2 endpoint call — both fall back to legacy v1 `POST /contacts/discover` (unpeppered). This means iOS and Desktop contacts cannot be discovered by Android peers using the v2 flow until they register peppered hashes. Tracking: Phase B.7.

> Note: Android hashes `pepper ‖ e164` (pepper first); the server's `bbolt.go` comment also documents `SHA-256(pepper || e164)`. These are consistent. If iOS/Desktop implement v2, they MUST use this order.

### §3 — PSK fingerprint display format divergence (F0.2)

All platforms derive `sha256(psk_bytes)` for the fingerprint, but the display string differs:
- **Android**: `sha256(key)` → first 16 hex chars → `xxxx.xxxx.xxxx.xxxx` (dot-grouped, 19 chars displayed)
- **iOS**: full 64-char hex (no grouping)
- **Desktop**: first 28 chars of full 64-char hex + `"…"` (UI truncation, no grouping)

The spec calls for `xxxx.xxxx.xxxx.xxxx` from `sha256(pubkey)[:8]` (4 hex groups × 4 chars = 16 hex chars = 8 bytes). Android matches the spec format exactly. iOS and Desktop need to adopt the same `formatDisplayFingerprint` logic for cross-platform out-of-band verification to work. Wire-level PSK negotiation already uses full hex on all platforms; this is a display-only discrepancy.

### §4 — Device-link PSK: iOS and Desktop not implemented (F0.3)

Android's `DeviceLinkingProtocol.kt` derives the sync key via `HKDF-SHA256(X25519_shared, salt="qaudion-link-salt", info="qaudion-device-link-v1", 32B)`. iOS has no `DeviceLinkingProtocol` or these label constants anywhere in `QAudionEngine/Sources`. Desktop has no multi-device linking flow. Until iOS implements the same protocol with byte-identical labels, cross-platform device linking (Android ↔ iOS) cannot function. Tracking: Phase B.6.

### §5 — NFC collaborative PSK: Desktop not implemented (F0.3)

iOS (`CryptoConstants.hkdfNfcCollaborativePskInfo = "Q-Audion NFC Collaborative PSK v1"`) and Android (`NfcProtocol.kt:135`, same literal) agree exactly on the NFC PSK info string and salt construction (`sha256(sorted(pubA, pubB))`). Desktop has no NFC pairing code at all — this is expected given hardware constraints, but means NFC-paired PSKs established on mobile cannot be bootstrapped from a Desktop session.

### §6 — Recovery HKDF: spec description inaccurate; iOS and Desktop not implemented (F0.3)

The spec table lists salt=`"recovery-auth-v1"` / info=BIP-39 mnemonic. The actual Android implementation (`RecoveryCrypto.kt:70–71`) uses: `ikm=entropy`, `salt="bcrypto-recov-v1"`, `info="recovery-auth-v1"`, `length=32`. The spec's salt and info are transposed relative to the code — the server comment in `cmd/bcrypto-lite/main.go:1769` matches the Android code (not the spec table). The spec table needs to be corrected: actual values are `salt="bcrypto-recov-v1"`, `info="recovery-auth-v1"`. Separately, iOS and Desktop have no local HKDF derivation for recovery at all (iOS merely passes an opaque `recoverySecret` string up to the API — caller must derive it externally). Tracking: Phase B.8.

### §7 — Triple-hybrid KEX: iOS missing X448 component (F0.4)

iOS implements only dual-hybrid (ML-KEM-1024 + X25519, HKDF-SHA-256, 32B output) in `HybridPqcKeyExchange.swift`. Android (`HybridKeyAgreement.kt` + `CryptoConstants.kt:92–99`) and Desktop (`PqcKeyExchange.ts:21–28`) implement the triple-hybrid (ML-KEM-1024 + X25519 + X448, HKDF-SHA-512, 64B output) as the preferred path when peers support X448. When an Android or Desktop peer sends an X448 public key in the hybrid handshake, iOS has no X448 agreement capability and must fall back to dual-hybrid — producing a 32B secret while the peer expects a 64B secret. This breaks session key agreement in triple-hybrid mode. iOS must add X448 support (`@noble/curves/ed448` equivalent — `CryptoKit` has no X448; BouncyCastle bindings would be needed) or both sides must negotiate fallback explicitly. Also note: iOS `CryptoConstants.swift:91–99` defines `tripleHybridKdfSalt = "qaudion-triple-hybrid-v1"` and `tripleHybridKdfInfo = "session-key"` constants (matching Android/Desktop exactly) but no code uses them — dead code awaiting implementation. Tracking: Phase B.5.

### §8 — APNs VoIP push: server lite emits no APNs push (F0.4)

Android FCM incoming-call push is implemented end-to-end: server `internal/push/` sends FCM data messages; Android `FcmService.kt` handles `type=call_incoming`. For iOS PushKit (APNs VoIP), no APNs path exists in `bcrypto-server/internal/push/` — only FCM. iOS `QAudionApp/` has no `PKPushRegistry` registration or `CXProvider.reportNewIncomingCall` call. Per design spec §10.1, APNs VoIP is required for reliable background call delivery on iOS. Until server adds an APNs certificate + `apns-push-type: voip` sending path, and iOS adds PushKit integration, iOS calls will fail to wake the app from background. Tracking: Phase A.5.

### §9 — WS envelope `id` field: ANDROID_REFERENCE.md claim is stale (F0.4)

`ANDROID_REFERENCE.md` line 17 states `"id" is present on both directions`. Actual code: Android sends `id` only when `command.correlationId != null` (usually null — `WsCodec.kt:43`); Desktop never sends `id`; Server never emits `id` (Go `omitempty`, `NewEnvelope` sets zero-value); iOS always sends `id` (but server ignores it). F2.3 will update `ANDROID_REFERENCE.md` to reflect the actual behavior.

### §10 — `.qabk` backup format: Desktop and Android are incompatible (F0.4)

Desktop `BackupService.ts` and Android `BackupEncryptUseCase.kt` produce containers with different magic bytes (`QABK` vs `QAUD`), different salt sizes (32B vs 16B), different scrypt N parameters (2^15 vs 2^17), and different AAD strings (`"qaudion-backup:v1"` with hyphen vs `"qaudion.backup.v1"` with dot). A backup file from one platform cannot be decrypted by the other. iOS has no backup container implementation at all. A unified `.qabk` spec must be defined (Desktop layout is more complete — it includes scrypt params in the header for forward-compatibility) before cross-platform restore can work. Tracking: Phase 4 / Phase A.2.
