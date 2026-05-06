# Security Policy — Q-Audion iOS

Q-Audion iOS is the native Swift client for the Q-Audion E2EE post-quantum messenger.

**Authoritative protocol spec:** `apps/bcrypto-server/docs/WIRE_SPEC.md`
**Master security policy:** `apps/bcrypto-server/SECURITY.md`

## Reporting

Please do **not** open a public GitHub issue. Email `security@bcrypto.com` (PGP key TBD). Use GitHub private security advisory for sensitive reports.

We acknowledge within 48 business hours, triage within 5 business days, follow a 90-day coordinated-disclosure default.

## Scope (iOS)

In scope:
- All Swift code under `QAudionEngine/Sources/` and `QAudionApp/Sources/`
- Cryptographic implementations:
  - **ML-KEM-1024** via `liboqs` C target (pinned commit SHA in `Package.swift`) — fallback to RNG if unavailable is documented but must NEVER ship in release config
  - **X25519** via Apple `CryptoKit.Curve25519.KeyAgreement`
  - **Ed25519** via `CryptoKit.Curve25519.Signing`
  - **AES-256-GCM** via `CryptoKit.AES.GCM`
  - **HKDF-SHA-256/512** via `CryptoKit.HKDF`
  - **ChaCha20-Poly1305** via `CryptoKit.ChaChaPoly`
  - **Opus** via `libopus` C target (pinned 1.5.2)
  - **ONNX Runtime 1.17.0** for AASIST deepfake detection
- Secure Enclave (P-256 identity key) usage and Keychain access controls
- WebSocket transport security (TLS pinning, certificate validation)
- VoIP push (PushKit) handling — `BCryptoPushNotifications.swift`
- Wire-spec compliance with `WIRE_SPEC.md` v1.0.0
- 12 known wire drifts documented in `docs/progress/PHASE1_REST_AUDIT.md` — fixes pending for 1.0 freeze

Out of scope:
- iOS / iPadOS / macOS Catalyst CVEs (report to Apple)
- Issues requiring jailbreak
- TestFlight-only build artifacts (canary channel) — but we still appreciate reports

## Cryptographic invariants

- liboqs commit SHA pinned and verified in CI
- Keys never leave Secure Enclave (P-256 identity); ML-KEM and X25519 secrets live in Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
- HKDF labels versioned per WIRE_SPEC.md §5.1
- KAT cross-platform vectors (Android BouncyCastle ↔ Desktop noble ↔ iOS liboqs+CryptoKit) gated in CI (Codemagic)
- All ML-KEM private operations are wrapped + zeroized after use

## Recent significant work

- 2026-04 Phase 0 complete (TestFlight v1.0.24-ph0 LIVE)
- 2026-04 Phase 1 REST audit complete (12 drifts flagged, Tasks 1.4-a/b1/b2 already RESOLVED on iOS, remaining drifts D-6/7/8/10/11-15/iOS-WS-camelCase/iOS-call_id queued for 1.0 freeze)
- 2026-04 Cross-platform alignment design accepted (`docs/superpowers/specs/2026-04-28-cross-platform-alignment-design.md`)

## Bug bounty

Live via HackerOne / Intigriti before public 1.0. Until then, good-faith rewards case-by-case.
