# Q-Audion iOS

Post-quantum encrypted VoIP for iOS — the iPhone companion to Q-Audion Android.

## Architecture

```
QAudionEngine/           Swift Package (standalone engine)
├── Crypto/              ML-KEM-1024 + AES-256-GCM + HKDF Double Ratchet
├── Transport/           Wire format, adaptive CBR padding, loopback
├── Audio/               Opus codec, AVAudioEngine capture/playback, jitter buffer
├── Core/                Engine facade, config, state machine, trust anchor
├── Deepfake/            LFCC + CoreML deepfake detection, speaker verification
├── Analysis/            Pitch, stress, formants, speech rate, voice health
├── Backend/             BCrypto WS + REST, Signal upstream delegation
├── Registry/            Multi-backend selection, call routing
├── Integration/         Call integration, transport selector, KMS, OTA
├── Sovereign/           NFC read + QR PSK exchange
└── UI/                  SwiftUI (settings, enrollment, guardian overlay)
```

## Build

### Engine only (no Xcode needed)

```bash
cd QAudionEngine
swift build
swift test --parallel
```

### Full iOS app (requires Xcode + Signal-iOS fork)

```bash
cd Signal-iOS
pod install
open Signal.xcworkspace
```

## CI/CD

- **GitHub Actions**: Engine tests on every push (Linux, free)
- **Codemagic**: Full Xcode build on tag push (macOS M2, 500 min/month free)

## Protocol Compatibility

Wire format is byte-identical to Q-Audion Android:
- Frame: `[Version][Flags][SeqNum BE][Timestamp BE][Nonce][Payload][Tag][DeepfakeScore]`
- HKDF info strings: `q-audion-frame-key`, `q-audion-root-ratchet`, `q-audion-psk-mix`, `q-audion-next-chain`
- CBR padding: 256-byte constant frames with 2-byte BE length suffix

## Stubs (to be replaced)

| Stub | Replacement | Phase |
|------|-------------|-------|
| PqcKeyExchange | liboqs ML-KEM-1024 C target | 5a |
| OpusCodec | libopus 1.5.2 C target | 5b |
| VoiceprintAnalyzer | CoreML model (ONNX conversion) | 5c |

## License

Proprietary — BCrypto / Q-Audion
