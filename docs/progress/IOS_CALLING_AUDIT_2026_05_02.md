# iOS Calling Pipeline Audit — 2026-05-02

Audit of the iOS calling stack against Android + Desktop, focused on what blocks
1:1 audio + video parity for Q-Audion 1.0 (plan §2.2-§2.4 + §2.8).

Scope intentionally narrow: the 8 numbered areas requested, citing file:line.
Verdicts are blunt — "stub", "wired", "production-ready", "missing".

---

## TL;DR

iOS has solid **CallKit + PushKit class-level** scaffolding, **no WebRTC at
all**, and a **bespoke encrypted PCM-over-WebSocket transport** that does not
match Android/Desktop's `RTCPeerConnection` plan from §2.2. The signaling
envelopes (`call_offer`/`call_answer`/`call_ice`/`call_hangup`) are wired to
the BCrypto server in iOS, but `call_ice`/`call_answer` carry no real SDP
because there is no peer-connection on iOS to produce one — the audio path
is a direct WS audio-frame relay.

The biggest *blocking* gaps for a working 1:1 iPhone↔Android call:

1. **No WebRTC/RTCPeerConnection on iOS.** Plan §2.2 demands a PeerConnection
   adapter on every platform; iOS has zero. A1 below.
2. **APNs delivery is implemented server-side but unactivated.** §10.1 option α
   (server APNs HTTP/2) shipped in `bcrypto-server@3ff8e47` (per
   `docs/progress/STATUS.md`) but the four env vars must be set on the deployed
   server before a single PushKit notification gets out the door. A2 below.
3. **iOS SAS does not derive from a transcript at all.** `SasVerificationViewModel`
   takes pre-computed words via `init`, but nothing on iOS computes them with
   `qaudion-sas-v1` salt + `sas-words-v1` info — Android-locked 2026-04-28. A4 below.
4. **No video pipeline.** `VideoCodecManager` exists in isolation
   (`QAudionEngine/Sources/QAudionEngine/Audio/VideoCodecManager.swift:11`) — no
   capture, no encoder feed, no `RTCVideoTrack`, nothing wired to a UI surface
   beyond the placeholder `VideoCallView`. A6 below.

---

## 1. CallKit integration depth

**File:** `QAudionEngine/Sources/QAudionEngine/Integration/CallKitProvider.swift:6`
backed by protocol `CallKitManaging.swift:6`.

**What's wired:**
- `CXProvider` constructed with `supportsVideo = true`, `maximumCallsPerCallGroup = 1`,
  `supportedHandleTypes = [.phoneNumber, .generic]` (`CallKitProvider.swift:15-22`).
- `reportIncomingCall` builds a `CXCallUpdate` with `localizedCallerName` + `hasVideo`
  and calls `provider.reportNewIncomingCall` (`:29-40`). Errors are *silently
  swallowed* (Focus mode rejects, or system race) — no upward propagation.
- `startOutgoingCall` posts a `CXStartCallAction` (`:54-61`).
- `setMuted`/`setOnHold` post `CXSetMutedCallAction`/`CXSetHeldCallAction`
  (`:67-75`).
- Delegate methods for `CXAnswerCallAction`/`CXEndCallAction`/`CXSetMutedCallAction`
  fulfil the action and forward to `onAnswerCall`/`onEndCall`/`onMutedChanged`
  closures (`:83-102`).
- `provider:didActivate` configures `AVAudioSession.playAndRecord + .voiceChat`
  with `.allowBluetoothHFP` (`:104-107`). `provider:didDeactivate` is a comment
  only — no actual mic-pause hook is invoked (`:109-111`).

**AppState wiring** (`QAudionApp/AppState.swift:284-309`):
- `onAnswerCall` → flips `isInCall = true` + stores `activeCallKitId`. **Does
  NOT trigger any signaling**. Compare to Android Telecom which actually drives
  the answer SDP.
- `onEndCall` → `endCall()`.
- `onMutedChanged` → forwards to `CallService.setMuted`.

**What's stub vs production:**

| Surface | State | Notes |
|---|---|---|
| Incoming call UI ring | Wired | `reportNewIncomingCall` on a real device will ring. |
| Hold / resume | **Stub** | `CallKitManaging.setOnHold` exists but `CXSetHeldCallAction` delegate is **not implemented** in `CallKitProvider` (`:97-102` only has muted). |
| Audio route changes | **Missing** | No `AVAudioSession.routeChangeNotification` observer; no `CXProvider.reportCall:newCallUpdate` for route hints. |
| UUID handling | Wired | UUIDs are minted on outgoing, parsed from server `call_id` on incoming (`AppState.swift:619-622`). |
| `didDeactivate` mic pause | **Stub** | Comment-only — `AudioCapture.stop()` is NOT called when CallKit yields the session. |
| CallKit-driven `outgoingCall` connect timing | **Stub** | `reportCallConnected` exists but is **not invoked anywhere** — search shows zero callers. |

**Verdict:** ~70% of the surface is wired, but the two pieces that matter most
for cross-app behaviour (route changes during a call, `reportCallConnected` so
iOS sees the call as active) are missing. Hold is a one-line gap.

---

## 2. PushKit + APNs end-to-end

### 2.1 Token registration (iOS → server)

**File:** `QAudionApp/AppState.swift:313-344` constructs `PushKitProvider` with
two closures (token + incoming push).

The token closure:
1. Hex-encodes the 32B token (`AppState.swift:325`).
2. Caches in `pendingVoipPushTokenHex` (`:540`).
3. POSTs to `/api/v1/account/apns-voip-token` with body
   `{voip_token: "<64-hex>", bundle_id}` (`:551-558`). Path matches server
   handler `apnsVoipTokenLenHex = 64` validation
   (`bcrypto-server/cmd/bcrypto-lite/account_apns_voip_token.go:29,94`).

This path is **fully wired**. Token is also retried on each auth-success
(`AppState.swift:347-369, 386, 411`) so killed/reinstalled devices recover.

### 2.2 Server-side APNs emission

**File:** `bcrypto-server/internal/push/apns.go:36-117`.

Implementation present:
- `NewAPNsClient` reads `BCRYPTO_APNS_KEY_PATH/KEY_ID/TEAM_ID/BUNDLE_ID` — fails
  if any unset (`apns.go:41-43`).
- `SendVoIPIncomingCall` posts to `https://api.push.apple.com/3/device/<token>`
  with `apns-topic: <bundle>.voip`, `apns-push-type: voip`, `apns-priority: 10`
  (`apns.go:92-104`).
- Payload matches §5.7 wire spec exactly:
  `{type:"incoming_call", call_id, caller_id, caller_name, call_type}` plus an
  `aps` envelope (`apns.go:75-86`).
- Dispatcher (`internal/push/dispatcher.go:41-62`) routes
  `platform="ios-apns"` to APNs and falls back to FCM with a `slog.Warn` if
  `d.APNs == nil`.
- Fan-out (`cmd/bcrypto-lite/push_fanout.go:124-128`): when stored
  `Platform=="ios" && APNsVoipToken != ""`, dispatcher gets `platform=ios-apns`.

**Activation gate:** `NewAPNsClient` returns `nil + error` if env vars are
unset, and `dispatcher.go:43-46` then logs the warn-and-fall-back-to-FCM path.
On a server with no APNs config, **iOS PushKit will never fire**. The
deploy script `bcrypto-server/deploy-apns-key.py` exists for landing the .p8
but per `docs/progress/STATUS.md` "Activation: set
BCRYPTO_APNS_KEY_PATH/KEY_ID/TEAM_ID/BUNDLE_ID env vars" — nothing on the
production VPS as of this audit.

### 2.3 Spec §10.1 options recap

From `docs/superpowers/specs/2026-04-28-cross-platform-alignment-design.md:410-416`:

| Option | Meaning | Status |
|---|---|---|
| α | Server adds APNs HTTP/2. | **Implemented** in `bcrypto-server@3ff8e47`. **Not yet deployed** (env vars unset). |
| β | iOS holds persistent WS via VoIP background mode. | Partially in place (`AppState.connectPersistentSocket`, `:436-504`) but battery-fragile, unreliable for incoming calls when killed. |
| γ | Silent push + WS reconnect. | Not implemented. |
| δ | Degraded "missed call" only. | Implicit fallback today — peer offline → push fails silently → caller sees timeout, callee sees nothing. |

### 2.4 Concrete unblocking steps

1. SSH `217.160.65.35`, install `.p8` Apple Push Authentication Key under
   `/etc/bcrypto/apns.p8`.
2. Add to systemd unit / env:
   ```
   BCRYPTO_APNS_KEY_PATH=/etc/bcrypto/apns.p8
   BCRYPTO_APNS_KEY_ID=<10-char from Apple Dev portal>
   BCRYPTO_APNS_TEAM_ID=<10-char>
   BCRYPTO_APNS_BUNDLE_ID=com.qaudion.app
   ```
3. Restart `bcrypto-lite`. On startup `slog.Info("APNs configured", ...)` should
   appear (verify via `journalctl -u bcrypto-lite -f`).
4. iOS-side: confirm `Info.plist` `UIBackgroundModes` contains `voip` (not
   inspected in this audit but flagged as a Codemagic preservation rule in
   spec §12.1).
5. Smoke test from Android device → iPhone with iPhone backgrounded, watch for
   PushKit incoming-call payload in `[Q-Audion] PushKit VoIP token: ...`
   logger and `console.app` for the actual APNs delivery.

---

## 3. WebRTC peer-connection

**Verdict: completely absent on iOS.**

### 3.1 No dependency

`QAudionEngine/Package.swift:15-21` declares exactly **one** SPM dependency:
`onnxruntime-swift-package-manager` for the deepfake model. No
`GoogleWebRTC`, no `stasel/WebRTC`, no `react-native-webrtc`, no custom
libwebrtc binary. The codebase has **zero** `import WebRTC` and **zero**
`RTCPeerConnection` references in production code (only in
`PARITY_AUDIT_HONEST.md`, `INVARIANTS_VERIFIED.md`, and the predecessor plan
doc — all docs).

### 3.2 What iOS does instead

`CallService.swift` runs a hand-rolled audio loop:

1. `AudioCapture` taps `AVAudioEngine.inputNode` with VP I/O enabled
   (`AudioCapture.swift:33,44-51`).
2. Each PCM frame goes through `QAudionCallIntegration.processOutgoingAudio`
   (`QAudionCallIntegration.swift:220-224`) which:
   - Runs deepfake `voiceAnalysis` + `guardianMode` analysis.
   - `engine.processOutgoingAudio` (`QAudionEngine.swift:46-66`):
     - Opus encode (`OpusCodec.encode`, `OpusCodec.swift:54-72`).
     - AEAD encrypt with frame-level ratchet key.
     - Serialize as `EncryptedFrame{seq, ts, nonce, payload, tag}`.
3. `CallService.processAndSendEncryptedFrame` ships the bytes via
   `BCryptoWebSocketClient.sendAudioFrame` (`CallService.swift:294-296`).
4. Receiver path: WS handler `audio_frame` → `handleIncomingEncryptedFrame` →
   decrypt → Opus decode → `AudioPlayback.playFrame`
   (`CallService.swift:319-324, 234-257`).

This is **fundamentally different** from §2.2 of the plan, which calls for
`RTCPeerConnection` with SRTP. iOS uses a custom AEAD-over-WS replacement
that:

- Has **no DTLS-SRTP**.
- Has **no built-in ICE** (server `getRelays` is **defined but never called**
  in app layer — confirmed via grep on `QAudionApp/`).
- Has **no SDP**. `BCryptoCallingApiImpl.sendCallOffer` literally sends
  `"sdp": sdp` with whatever string the caller passes — and the caller
  doesn't exist (the whole call_offer triggering path through
  `BCryptoCallingApiImpl` is unreachable from `CallService.startCall` in the
  current iOS code; calls are driven entirely through opaque-message PQC
  capability exchange instead — `QAudionCallIntegration.swift:114-142`).
- **No video** (the WS `audio_frame` carries only audio).

### 3.3 SDP / codec negotiation

There is none. `BCryptoCallingApiImpl.sendCallOffer` (`:24-37`) hard-codes
`"call_type": "audio"` with the comment *"SDP-less PQC path uses 'audio'"*
and the field name `sdp` is a vestigial wire field — server accepts it as a
string but iOS never produces a real SDP blob. Compare to Android's
`QAudionPeerConnection` (referenced in plan §2.2 as "skeleton-only" but at
least *generating* an offer SDP through libwebrtc).

### 3.4 ICE / TURN

`BCryptoCallingApiImpl.getRelays()` exists at `:103-107` and decodes the
server response. **No iOS code calls it.** Grep result:

```
QAudionEngine/.../UpstreamCallingApiImpl.swift:74  (impl)
QAudionEngine/.../BCryptoCallingApiImpl.swift:103  (impl)
QAudionEngine/.../CallingApi.swift:10              (protocol)
```

Only the implementation sites. No usage in `QAudionApp/`. The TURN credentials
the server pre-derives (per `INVARIANTS_VERIFIED.md:201-204`) are unused on iOS
because no `RTCPeerConnection` exists to hand them to.

### 3.5 Compare to Android + Desktop

- **Desktop** (`apps/qaudion-desktop/src/main/calling/MediaTransport.ts` per the
  task brief, not re-read here): real `RTCPeerConnection`, fetches
  `getRelays()`, builds ICE servers list. Call-of-record cross-platform shape.
- **Android**: per plan §2.2 the `QAudionPeerConnection.kt` is a *skeleton*
  but it at least imports libwebrtc and creates a peer connection.
- **iOS**: nothing.

**Implication:** an Android↔iOS call cannot use SDP/ICE/SRTP today. The only
way calls work today is the bespoke `audio_frame` WS relay, which Android
either *also* implements as a fallback path or *does not* — needs verifying
on the Android side. If Android only speaks WebRTC, **today these two clients
do not interoperate at all**.

---

## 4. Audio pipeline

### 4.1 AVAudioSession

`AudioProcessingPipeline.configureForVoIP()`
(`AudioProcessingPipeline.swift:72-97`) sets:

- `category = .playAndRecord`
- `mode = .voiceChat` ← matches plan §2.4.
- options: `.defaultToSpeaker`, `.allowBluetoothHFP`, `.allowBluetoothA2DP`,
  `.interruptSpokenAudioAndMixWithOthers`.
- `setPreferredIOBufferDuration(0.005)` (5ms).
- `setPreferredSampleRate(48000)`.

`CallKitProvider.swift:104-107` *also* configures the session in
`provider:didActivate`. Two configurators racing — the CallKit one likely
wins on incoming calls. Worth deduping.

### 4.2 AEC / NS / AGC

Hardware DSP via Apple Voice Processing I/O:
`AudioProcessingPipeline.enableVoiceProcessing(on:)`
(`:107-123`) calls `inputNode.setVoiceProcessingEnabled(true)` (iOS 13+).
This enables the same chain as FaceTime/Signal/WhatsApp: AEC + NS + AGC.

A *supplemental* software spectral subtraction layer runs on top
(`AudioProcessingPipeline.applyNoiseReduction`, `:145-186`) — adaptive
noise-floor estimation, soft-gating below threshold. This is iOS-only;
Android+Desktop don't have an equivalent. Likely fine, but worth verifying
it doesn't *fight* the hardware NS (double-suppression artefacts).

### 4.3 Opus

`OpusCodec.swift:30-46` initialises `opus_encoder_create` with
`OPUS_APPLICATION_VOIP`, **CBR mode** (`vbr=0` — anti-traffic-analysis
choice, `:39`), bitrate from `Config.bitrate` (default 32_000), complexity 5.

Three preset configs: `secure()` 32kbps, `highQuality()` 64kbps,
`lowLatency()` 24kbps (`:18-20`). Plan §2.3 calls for "16/32kHz adaptive";
iOS hardcodes 48kHz capture (`AudioConstants.sampleRate = 48000`) and the
codec runs at that rate. **No adaptive bitrate** — `reconfigure(_:)` exists
(`:110-116`) but no caller adjusts it based on packet loss, RTT, or any
bandwidth probe.

PLC: `decodePLC()` (`:97-106`) generates an interpolated frame on packet
loss, but this is invoked **only** in test code paths — production
`processIncomingAudio` does no loss-detection-and-PLC; missing frames just
skip. Compare to the WebRTC default jitter buffer + NetEQ on Desktop.

### 4.4 Jitter buffer

`AudioConstants.swift:11-13`:
- P2P: 3 frames (60ms).
- WS-relay: 8 frames (160ms) — what iOS uses today.
- Signal-relay: 150 frames (3s).

`QAudionAudioProcessor` instantiates a buffer of size 8 by default
(`QAudionEngine.swift:26-29`). Implementation not re-inspected here, but
note that `CallService.handleIncomingEncryptedFrame` decrypts and immediately
calls `playback.playFrame` (`:248-250`) — there is no obvious jitter-buffer
de-queueing on the playback side beyond Opus + scheduleBuffer's own ring.
This may explain choppiness reports under packet loss.

### 4.5 MOS @ 3% loss target

Plan §2.3 demands MOS ≥ 3.8 at 3% packet loss. Without working PLC + adaptive
bitrate + jitter buffer integration, this target is not currently met on iOS.
No automated MOS measurement scaffolding exists.

---

## 5. Video pipeline (1:1)

**Verdict: scaffolding only, zero wire-level capability.**

### 5.1 Codec selection

`VideoCodecManager.swift:11-66` exists. Picks HEVC (`activeCodec = .hevc`) when
`isHEVCHardwareEncoderAvailable()` returns true, else H.264. Plan §2.4 says
H.264 baseline default, H.265 opt-in — iOS picks the **opposite**: HEVC
default, H.264 fallback. This is wrong for 1.0 ship since cross-platform
parity expects H.264 default.

### 5.2 Encoder feed

There is **no AVCaptureSession** wired for video. `VideoCallView`
(`QAudionApp/Views/VideoCallView.swift`) is a placeholder UI. No
`AVCaptureVideoDataOutput`, no `VTCompressionSession`, no per-frame encode
hook into the call transport. `VideoCodecManager` is import-only — its
output never feeds anything.

### 5.3 Adaptive bitrate / resolution

Nothing. `targetBitrateKbps` is a static accessor (`:32-37`).
360p/540p/720p ladder is undefined. No `RTCRtpSender.setParameters` (because
no peer-connection).

### 5.4 Implication for 1.0

Per plan §2.4 "1:1 video", iOS contributes essentially zero working code. A
TODO at minimum needs:
- `AVCaptureSession` + camera-preview surface in `VideoCallView`.
- `VTCompressionSession` configured for H.264 baseline @ 720p.
- A wire frame `video_frame` analogous to the existing `audio_frame` WS path
  (or, preferably, the proper `RTCPeerConnection` adapter that §2.2 requires
  on every platform).

Background blur is correctly out per plan §2.4.

---

## 6. SAS + safety-number cross-platform parity

### 6.1 iOS SAS state

`QAudionEngine/Sources/QAudionEngine/UI/ViewModels/SasVerificationViewModel.swift:3-36`:

The view-model takes `sasWords: [String]` via `init`. `mock` static at `:30`
hardcodes `["abandon", "ability", "able", "about"]` (4 words). The view
(`SasVerificationView.swift:9-44`) renders whatever it receives.

**Nothing on iOS computes the words.** Grep on `qaudion-sas-v1` and
`sas-words-v1` across the iOS repo:
- 0 hits in production code.
- Hits only in `docs/superpowers/plans/2026-04-28-track-a-foundation.md`
  and the mock instance.

Compare Android `qaudion-engine/src/main/java/com/bcrypto/qaudion/crypto/SasConstants.kt:43-87`:
```kotlin
const val SALT: String = "qaudion-sas-v1"
const val INFO_WORDS: String = "sas-words-v1"
const val WORD_COUNT: Int = 6
```

iOS is **completely missing**:
- Canonical `SasConstants` equivalent.
- HKDF derivation from PQC handshake transcript.
- PGP word list for Int → word lookup.
- 4-byte short-auth-string and 60-digit safety-number formula referenced in
  the task brief.

The desktop commit `e901d36` (per task brief) locked the canonical labels;
Android adopted them in `SasConstants.kt`. iOS has not.

### 6.2 Word count drift

`SasVerificationViewModel.mock` uses **4 words**; Android `WORD_COUNT = 6`;
the in-call `InCallScreen.swift:184,308-315` lays out **6 word slots** —
the view-model's mock is stale by 2 words. Real interop will deliver 6 words
once derivation is implemented.

### 6.3 Fingerprint

`Fingerprint.format` (per `INVARIANTS_VERIFIED.md` reference) does produce
the canonical `xxxx.xxxx.xxxx.xxxx` 4-group hex. That side is fine. The
60-digit safety-number formula is not implemented.

### 6.4 Verdict

iOS SAS is **UI-only**. The two-line gap is:
1. Add `SasConstants.swift` mirroring `SasConstants.kt`.
2. Add `ComputeSas` use-case using `CryptoKit.HKDF<SHA256>` over the
   `QAudionCallIntegration` PQC shared secret, splitting first 32 bits into
   word indices via the PGP word list.

Without this, **a user on iOS cannot verify a call against an Android
caller** — they see four hardcoded mock words while Android shows six real
ones derived from the actual handshake. Either the user calls "MISMATCH"
(call torn down) or unsafely accepts mismatched words (no MitM defence).

---

## 7. WS signaling for call setup

### 7.1 Outbound types iOS sends

`BCryptoCallingApiImpl.swift`:

| Type | Fields | Line |
|---|---|---|
| `call_offer` | `recipient_id`, `call_id`, `sdp` (vestigial), `call_type="audio"` | `:24-37` |
| `call_answer` | `call_id`, `sdp` | `:39-48` |
| `call_ice` | `call_id`, `candidate`, `sdp_mid`, `sdp_mline_index` | `:50-61` |
| `call_hangup` | `call_id`, `reason` | `:63-74` |
| `call_processing` | `call_id`, `caller_id` | `:86-91` (responder pre-neg ACK) |
| `call_ready` | `call_id`, `caller_id` | `:96-101` (responder pre-neg ACK) |

The historical bug at `:7-12` (camelCase `recipientId` rejected by Go's
`recipient_id` struct tag) is fixed.

### 7.2 Inbound types iOS handles

`AppState.swift` registers WS handlers (`:454, 459, 482, 616-672`):

| Type | Action |
|---|---|
| `call_incoming` | Reports incoming call to CallKit, sets `isInCall = true`, `callState = .ringing`. Binds incoming `call_id` so subsequent answer/hangup carry the same id (`:617-651`). |
| `call_hangup` | Translates `reason` → `CallEndReason`, calls `reportCallEnded`, then `endCall()` (`:652-671`). |
| `audio_frame` | Decoded base64, decrypted, played (`CallService.swift:319-324`). |
| `msg_receive` / `msg_delivered` / `msg_read` / `msg_typing` | Chat envelopes (`AppState.swift:691-732`). |
| `opaque_message` | PQC capability exchange + `qa_ctl:1` (`AppState.swift:482`). |

### 7.3 Missing on iOS

The pre-negotiation entry-points `onCallProcessingReceived`,
`onCallReadyReceived`, `onCallRingReceived`, `onPeerOfflineReceived`,
`onCallCancelReceived` are **defined** on `QAudionCallIntegration`
(`QAudionCallIntegration.swift:281-331`) but I see **no WS handler in
`AppState.wireIncomingCallHandlers`** that registers `call_processing`,
`call_ready`, `call_ring`, `call_peer_offline`, or `call_cancel`. This
means:

- iOS caller never flips UI from "Calling" → "Connecting" → "Ringing" — the
  state stays at `outgoingOffering` even after Android has acked.
- iOS responder never sees `call_cancel` from the WS — caller hanging up
  before pickup leaves iOS ringing forever (until OS times out).
- `call_peer_offline` doesn't surface "User is offline" to the caller.

### 7.4 vs Android + Desktop

Android + Desktop both implement the full pre-negotiation protocol per the
2026-04-28 alignment design. iOS has the *integration-layer hooks* but not
the *WS dispatch* — a 5-line patch in `wireIncomingCallHandlers`.

---

## 8. P0 next-10 actions (ranked)

### P0-1 (M, ship-blocker) — Activate APNs on production server

**Where:** `217.160.65.35` env vars; `bcrypto-server/internal/push/apns.go:36-43`
already validates them.
**Tasks:** install `.p8`, set `BCRYPTO_APNS_KEY_PATH/KEY_ID/TEAM_ID/BUNDLE_ID`,
restart `bcrypto-lite`. Confirm `journalctl` shows APNs initialised, then
smoke-test Android → backgrounded iPhone.
**Effort:** ~1 hour ops.

### P0-2 (S, ship-blocker) — Implement iOS SAS computation

**Where:** new file
`QAudionEngine/Sources/QAudionEngine/Crypto/SasConstants.swift` mirroring
`apps/qaudion-android-new/qaudion-engine/src/main/java/com/bcrypto/qaudion/crypto/SasConstants.kt:43-87`.
Plus `ComputeSas.swift` taking the `QAudionCallIntegration` shared secret +
both peers' identity-public-keys, running HKDF-SHA256 with salt
`"qaudion-sas-v1"` info `"sas-words-v1"`, output 6 words via PGP word list.
Caller: `CallService` after `state == .active` should call this and stuff
the result into the `InCallScreen.sasWords` binding.
**Effort:** ~4 hours.

### P0-3 (M) — Wire the missing pre-negotiation WS handlers

**Where:** `QAudionApp/AppState.swift:616-672` `wireIncomingCallHandlers`.
**Tasks:** add handlers for `call_processing`, `call_ready`, `call_ring`,
`call_peer_offline`, `call_cancel` that forward to the corresponding
`QAudionCallIntegration` entry-points (`QAudionCallIntegration.swift:281-331`).
**Effort:** ~2 hours; tests in `AppStateTests` if they exist.

### P0-4 (S) — Fix CallKit `provider:didDeactivate` mic pause + hold action

**Where:** `CallKitProvider.swift:90-102, 109-111`.
**Tasks:**
- Implement `func provider(_:perform:CXSetHeldCallAction)` calling
  `onHoldChanged` closure. Mirror `onMutedChanged`.
- In `didDeactivate`, post a `Notification` or invoke a closure on
  `CallKitProvider` so `CallService.audioCapture?.stop()` is called when the
  system yields the audio session (CarPlay handover, Siri interrupt).
**Effort:** ~2 hours.

### P0-5 (S) — Default video codec H.264, not HEVC

**Where:** `VideoCodecManager.swift:48-66`.
**Tasks:** flip the order so H.264 is the default; HEVC behind a Settings
toggle later. Plan §2.4 demands H.264 baseline default.
**Effort:** ~30 min.

### P0-6 (L, ship-blocker for video) — Decide WebRTC vs custom transport

**Decision needed before any video work:** does iOS adopt
`stasel/WebRTC` (or `react-native-webrtc` underlying lib) and migrate the
audio path to SRTP, or does iOS extend the bespoke
`audio_frame` WS path with a parallel `video_frame`? The answer changes
**everything** above.
**Recommendation:** adopt `stasel/WebRTC` (~14MB binary, well-maintained,
matches plan §2.2). Migrate audio out of the custom AEAD-over-WS path so
iOS, Android, Desktop all use the same SRTP+DTLS+ICE pipeline.
**Effort:** L (1-2 weeks for audio migration), then video comes "for free"
via the same PeerConnection.

### P0-7 (M, conditional on P0-6) — Audio path migration to RTCPeerConnection

If P0-6 adopts WebRTC: replace `CallService.startCall` audio path with an
`RTCPeerConnection` driven by `BCryptoCallingApiImpl.sendCallOffer` (real
SDP this time). Wire `getRelays()` results into ICE servers list (currently
unreachable, see §3.4).
**Effort:** ~1 week.

### P0-8 (M, conditional on P0-6) — Video pipeline

Once P0-7 lands: add `RTCVideoTrack` + `AVCaptureSession` + camera permission
+ `VideoCallView` real preview. H.264 baseline via VideoToolbox is what
WebRTC already uses on iOS, so "free" except for the wiring.
**Effort:** ~3-5 days.

### P0-9 (S) — Adaptive bitrate / packet-loss-driven Opus reconfigure

**Where:** `OpusCodec.swift:110-116` `reconfigure` is unused; wire it to a
new packet-loss observer (frame-loss counter on RX side, diff over rolling
window, drop bitrate from 32→24→16 kbps under load).
**Effort:** ~1 day. Only meaningful if the bespoke audio path stays
(otherwise WebRTC handles it).

### P0-10 (S) — Dedupe AVAudioSession configuration

**Where:** `CallKitProvider.swift:104-107` and
`AudioProcessingPipeline.configureForVoIP()` both set the session category;
the second one fights the first on incoming calls (CallKit's `didActivate`
runs *after* `CallService.startCall` already ran). Pick one
configurator — recommend CallKitProvider for incoming, pipeline for
outgoing — and add a guard so they don't both run.
**Effort:** ~1 hour.

---

## Appendix: file:line index of every cited surface

- `QAudionApp/AppState.swift:171, 280-369, 436-672, 690-732`
- `QAudionApp/Services/CallService.swift:107-403`
- `QAudionEngine/Sources/QAudionEngine/Integration/CallKitProvider.swift:6-112`
- `QAudionEngine/Sources/QAudionEngine/Integration/CallKitManaging.swift:6-33`
- `QAudionEngine/Sources/QAudionEngine/Integration/PushKitProvider.swift:6-96`
- `QAudionEngine/Sources/QAudionEngine/Integration/QAudionCallIntegration.swift:8-339`
- `QAudionEngine/Sources/QAudionEngine/Backend/BCrypto/BCryptoCallingApiImpl.swift:13-138`
- `QAudionEngine/Sources/QAudionEngine/Backend/Protocols/CallingApi.swift:3-39`
- `QAudionEngine/Sources/QAudionEngine/Audio/AudioCapture.swift:5-74`
- `QAudionEngine/Sources/QAudionEngine/Audio/AudioPlayback.swift:5-40`
- `QAudionEngine/Sources/QAudionEngine/Audio/AudioProcessingPipeline.swift:13-245`
- `QAudionEngine/Sources/QAudionEngine/Audio/AudioConstants.swift:3-16`
- `QAudionEngine/Sources/QAudionEngine/Audio/OpusCodec.swift:6-131`
- `QAudionEngine/Sources/QAudionEngine/Audio/VideoCodecManager.swift:11-66`
- `QAudionEngine/Sources/QAudionEngine/Core/QAudionEngine.swift:4-80`
- `QAudionEngine/Sources/QAudionEngine/UI/ViewModels/SasVerificationViewModel.swift:3-36`
- `QAudionEngine/Sources/QAudionEngine/UI/SasVerificationView.swift:9-44`
- `QAudionEngine/Package.swift:15-21`
- `bcrypto-server/cmd/bcrypto-lite/account_apns_voip_token.go:29-155`
- `bcrypto-server/cmd/bcrypto-lite/push.go:1-191`
- `bcrypto-server/cmd/bcrypto-lite/push_fanout.go:18-128`
- `bcrypto-server/internal/push/apns.go:24-117`
- `bcrypto-server/internal/push/dispatcher.go:9-82`
- `apps/qaudion-android-new/qaudion-engine/src/main/java/com/bcrypto/qaudion/crypto/SasConstants.kt:43-87`
- `docs/superpowers/specs/2026-04-28-cross-platform-alignment-design.md:406-418`
- `docs/progress/STATUS.md` (Wave 13 § "RESOLVED in Wave 13")
- `docs/progress/INVARIANTS_VERIFIED.md:201-211`
