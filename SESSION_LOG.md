# Q-Audion iOS — Session Log

## 2026-04-20 — iOS ↔ Android full-parity effort (Phase 0 kickoff)

Plan: `docs/superpowers/plans/2026-04-20-ios-android-parity.md` (13 phases).
Branch: `feature/ios-android-parity` (off `main` @ 4516e01).
Last shipped tag: `v1.0.23`. Next verification tag: `v1.0.24-ph0` (after Phase 0).

### Task 0.1 — Apple Developer portal capability (BLOCKER, manual) ✅ DONE 2026-04-20
Owner: **USER** (cannot be automated). **Completed 2026-04-20** — screenshot
confirmed Push Notifications capability enabled on `com.qaudion.app` (NFC
Tag Reading also still enabled, unchanged). No APNs certificate created
— Codemagic generates the provisioning profile via ASC API, which now
includes `aps-environment` since the capability is set.

Original checklist:
1. Log in to https://developer.apple.com/account ✅
2. Identifiers → `com.qaudion.app` → enable **Push Notifications** → Save ✅
3. Confirm the identifier lists "Push Notifications" under capabilities ✅
4. Log the completion date back into this file ✅ (this line)

Reason: `app-store-connect fetch-signing-files --create` (codemagic.yaml)
will only include `aps-environment` in the provisioning profile if the
identifier has Push Notifications enabled. Without it, Task 0.2's
`aps-environment=production` entitlement becomes a signing mismatch
and the build fails at the "Set up signing" step.

---

## 2026-04-10/11 — Sessione completa: da CI rotto a app funzionante su 2 telefoni

### Fase 1: Fix CI Codemagic (da rotto a green)
- Fix Xcode 26.2 beta → pinnato a 16.2 stabile
- Fix ONNX Runtime iOS Simulator (`#if !targetEnvironment(simulator)`)
- Fix macro duplicati (`OQS_ENABLE_KEM_ml_kem_1024`)
- Fix GitHub Actions runner (`macos-14`)
- Workflow unificato `swift build` + `swift test`
- **Risultato: CI green in 41s su Mac mini M2**

### Fase 2: Test Coverage (da 21 a 35 test file)
- TestHelpers.swift (generatori PCM sintetici)
- 7 test Analysis (Pitch, Stress, Formant, Health, SpeechRate, Confidence, Engine)
- 3 test Deepfake (SpeakerVerifier, VoiceprintStore, RespiratoryAnalyzer)
- 3 test Sovereign/Integration/Registry (NFC, OTA, BackendFailover)
- Code coverage + SwiftLint in CI

### Fase 3: NFC Protocol Implementation
- `NFCNDEFReaderSession` reale (sostituisce stub)
- `#if canImport(CoreNFC)` per compatibilità macOS
- NfcExchangeView collegata a NfcProtocol

### Fase 4: iOS App Shell (16 file Swift, ~3500 righe)
- Login/Register con BCryptoAccountApiImpl
- HomeView (4 tab: Calls, Messages, Keys, Settings)
- CallView con CallSecurityBadge (compact + expanded)
- VideoCallView con PiP e 5 controlli
- WaveformView (TX cyan, RX verde, Cipher arancione)
- ConversationListView + ChatView + MessageBubbleView
- SettingsView (9 sezioni matching Android)
- AppState + AuthService + CallService

### Fase 5: Security Hardening (stato dell'arte)
- HybridPqcKeyExchange (ML-KEM-1024 + X25519 + Secure Enclave P-256)
- SecureEnclaveManager (chiavi P-256 nel chip SEP)
- ForwardSecrecy (X25519 DH ogni 50 frame + key erasure)
- ThreatDetector (replay, injection, timing, key-reuse)
- ZeroKnowledgeAuth (OPAQUE-inspired blind password)
- SecureMemory (mlock + memset_s zeroization)
- CertificatePinning (SPKI SHA-256 fail-closed)
- CryptoComplianceInfo (FIPS 140-3, SP 800-56C, etc.)

### Fase 6: P2P Transport + VoIP Audio
- StunClient (RFC 5389, Google/Cloudflare STUN servers)
- IceAgent (RFC 8445, host + srflx candidates, connectivity check)
- TransportSelector riscritto: P2P first → relay fallback
- AudioProcessingPipeline (`setVoiceProcessingEnabled(true)`)
- Hardware AEC/NS/AGC via Apple VoIP DSP
- HEVC (H.265) primary codec, H.264 fallback

### Fase 7: Allineamento Globale
- **Android**: 8 file Kotlin crypto allineati (HybridPQC, ThreatDetector, ForwardSecrecy, ZKAuth, SecureMemory, CertPinning, Compliance, Constants)
- **Server**: ZK auth endpoints, PQC relay, threat reporting, cert-info, compliance API
- **Firmware**: hybrid_pqc.c, threat_detector.c, qa_security.h, test_security.c
- Stringhe HKDF identiche cross-platform

### Fase 8: Android Hardware Crypto + DSP
- HardwareCryptoPipeline (StrongBox FIPS 140-2 L3 / TEE)
- SecureAudioPipeline (Mic→Opus→HW encrypt→wire)
- KnoxSecurityManager (attestation, root detection, integrity)
- MicrophoneController (patent: mic locked, auth-gated, emergency cut)
- NNAPI delegate per deepfake su NPU
- AacEldCodec (MediaCodec HW encoder+decoder su DSP)
- AudioCodecSelector (AAC-ELD HW → Opus fallback)
- GuardianMode adattivo (throttle per RAM disponibile)
- Fix dead handler crash in BCryptoVideoCallActivity

### Fase 9: Design con Google Stitch
- 3 schermate generate (Login, Call, Settings)
- Icon set con progressive simplification (1024px → 16px)
- DESIGN.md (Aegis Cipher design system)

### Fase 10: Build & Deploy
- iOS: Codemagic v1.0.3 green, IPA generation configurata
- Android: APK firmato `qaudion-release.jks`, installato su 2 device
- Device: Samsung Galaxy A50 (Exynos) + Samsung Galaxy S26 Ultra (Qualcomm)

## Device identificati
- R58R21SFXZW = Samsung Galaxy A50 (SM-A505FN), Exynos 9610, Android 11, 3.6GB RAM
- RFGL10618QP = Samsung Galaxy S26 Ultra (SM-S948B), Qualcomm, Android 16, 12GB RAM, StrongBox 400, Knox 40

## Repository pushati
- Q-Audion-iOS: github.com/sigarone/Q-Audion-IOS
- Q-Audion-Android: github.com/sigarone/Q-Audion-Android
- bcrypto-server: github.com/sigarone/Bcrypto-server
- qaudion-firmware: github.com/sigarone/qaudion-firmware

## Prossimi passi
- [ ] Apple Developer Account ($99) per iOS signing
- [ ] AltStore per sideload iOS senza account dev
- [ ] Signal-Desktop allineamento
- [ ] End-to-end integration test iOS↔Android↔Server
- [ ] ONNX model file reale nel bundle
- [ ] BCrypto server deployment
