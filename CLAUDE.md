# CLAUDE.md — Agent Onboarding for Q-Audion iOS

You are an AI agent working on **Q-Audion iOS**, a post-quantum encrypted voice-calling app. Read this file end-to-end before your first action. It captures the hard-won state of the build pipeline so you don't repeat the work.

## 🚨 CI / BUILD PLATFORM — READ THIS BEFORE SAYING ANYTHING ABOUT CI

**iOS builds run on GitHub Actions. Not Codemagic. Not Xcode Cloud.**

- **Active workflow**: `.github/workflows/ios-testflight.yml`
- **Trigger**: push of a tag matching `v*` (e.g. `git tag v1.0.420 && git push origin v1.0.420`) or manual `workflow_dispatch`
- **Runner**: `macos-latest` with Xcode 26.x (auto-selected by the discovery step)
- **Output**: signed IPA uploaded to TestFlight Internal group `Q-Audion testers` via `xcrun altool` (no beta-review submission)
- **Repository secrets** (configure at github.com/sigarone/Q-Audion-IOS/settings/secrets/actions): `APP_STORE_CONNECT_KEY_IDENTIFIER`, `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_PRIVATE_KEY`, `CERTIFICATE_PRIVATE_KEY`

### Things that look like Codemagic but are NOT

- `codemagic-cli-tools` — Python package (pip-installable) that wraps the App Store Connect API and keychain helpers. The GitHub Actions workflow `pipx install`s this inside the `macos-latest` runner. **It is a CLI library, not a hosted-build service.** Do not infer "Codemagic builds the iOS app" from its presence.
- Mentions of "Codemagic" further down in this file — these are **historical context** (the GH Actions workflow was a drop-in replacement for the old `codemagic.yaml`, so the bash steps look similar). Ignore them when answering questions about the current pipeline.

### Other CI-related files in this repo

| Path | Status | Read it? |
|---|---|---|
| `.github/workflows/ios-testflight.yml` | **ACTIVE** — TestFlight build | YES, this is the pipeline |
| `.github/workflows/engine-tests.yml` | ACTIVE — Swift package tests on every push | reference if engine tests fail |
| `.github/workflows/kat-cross-platform.yml` | `workflow_dispatch` only since 2026-07-30 — its test (`WireV1CrossPlatformKatTests.swift`) is real and PASSES, but only via `engine-tests.yml`'s xcodebuild+simulator path; bare `swift test` here can't resolve LiveKit's binary `LiveKitWebRTC` xcframework, so this standalone job can't work without duplicating engine-tests.yml's cost | reference `engine-tests.yml` instead for KAT status |
| `.github/workflows/artifact-cleanup.yml` | ACTIVE — scheduled artifact retention | leave alone |
| `.github/workflows/ios-ui-smoke.yml` | ACTIVE, manual-only (`workflow_dispatch`) — builds QAudionApp for iOS Simulator (no signing) + runs Maestro UI flows from `maestro/*.yaml`. Added 2026-08-06, GREEN as of run [31079859197](https://github.com/sigarone/Q-Audion-IOS/actions/runs/31079859197) (13m51s) after 3 fix iterations (xcodegen not installed; a device-only quiche.xcframework — since removed with the MASQUE/QUIC transport; QAudionPacketTunnel/WireGuardKitGo is device-only too and is still stripped from a local project.yml copy — see the workflow file's own header for the full iteration log) | yes if it fails again — read the uploaded `build-sim-log`/`maestro-debug` artifacts first |
| `.github/workflows/ios-wda-provision.yml` | ACTIVE, manual-only (`workflow_dispatch`, input `device_udid`) — registers a real test iPhone + builds/signs WebDriverAgentRunner (appium/WebDriverAgent v16.1.5, IOS_APP_DEVELOPMENT signing) for interactive UI debug from Windows via go-ios (see global CLAUDE.md "go-ios + WebDriverAgent"). Added 2026-08-06, UNVERIFIED — first Development-type signing in this repo's CI (everything else here is IOS_APP_STORE), see file header for the certificate-reuse caveat | yes if it fails — read `wda-build-log` artifact; check whether `WDA_CERTIFICATE_PRIVATE_KEY` secret needs setting after a first successful cert creation |
| `XCODE_CLOUD_MIGRATION.md` | **HISTORICAL** — proposal for Xcode Cloud, never adopted | **do not follow its instructions** |
| `ci_scripts/` | **REMOVED 2026-09-12** (App Store readiness audit FIX-24) — they were Xcode Cloud hooks never run by the GH Actions pipeline, and would have executed unreviewed if Xcode Cloud were ever switched on | do not recreate |
| `codemagic.yaml` | **REMOVED** 2026-05-06 — deleted from the repo when CI moved to GH Actions | n/a |

### If a CI run fails

1. Open the failed run on GitHub Actions: https://github.com/sigarone/Q-Audion-IOS/actions
2. The "Diagnose Swift compile (raw xcodebuild)" step (when present) uploads `diag.log` as an artifact — read it before guessing.
3. Do NOT push tags repeatedly to "see if it works" — macOS runner minutes cost money. Reproduce locally with `xcodebuild` if possible.

## ⚡ AUTOMATION RULE — iOS runtime log fetch (auto-pump v1.0.398+)

**Build v1.0.398+ (W417) ships the auto-upload log shipper — OPT-IN,
default OFF since the MASVS-PRIVACY remediation (2026-08-20).** Once the
user enables Settings > Privacy > Diagnostica > "Log diagnostici in tempo
reale" (`LiveLogStreamer.isEnabled`), the device pumps a chunk file to
`/api/v1/files/upload` every ~3 seconds (background, throttled,
single-flight, non-interfering with calls). Without that consent nothing
leaves the device; ask the tester to flip the toggle before debugging.

**Filename pattern**:
```
qaudion-live-<userIdPrefix8>-<bootSessionUUID>-<seqZeroPad6>.log
```

**Trigger:** every time the user reports an iOS-side runtime problem
you MUST AUTOMATICALLY run:

```bash
python scripts/fetch-ios-live.py --minutes 60 --limit 80
```

The script:
1. SSH to the VPS using credentials from
   `apps/bcrypto-server/VPS_ACCESS.md` or env vars `QAUDION_VPS_HOST/USER/PASS`
2. Lists files modified in the last N minutes under `/opt/bcrypto/data/files/`
   (sharded `<id[0:2]>/<id>` layout — server discards original
   filenames, every blob is a UUID)
3. Downloads each candidate via SFTP, parses as UTF-8, and identifies
   W417 chunks via heuristic (first line matches ISO8601 timestamp regex)
4. Concatenates matching chunks in chronological order to
   `.cache/ios-logs/live-<timestamp>.log`
5. Prints summary: chunk count, byte total, ERROR/WARN count,
   top tag distribution

The full dump is the primary diagnostic source — every line has a
millisecond timestamp + level + tag + message, so call/dial/crypto
flow can be reconstructed exactly.

**Auth:** the script reads VPS credentials from env vars
`QAUDION_VPS_HOST` / `QAUDION_VPS_USER` / `QAUDION_VPS_PASS`, or
falls back to `apps/bcrypto-server/VPS_ACCESS.md` (private repo, not
in the iOS repo). Fallback: `scripts/fetch-ios-log.sh` uses
`QAUDION_USER_TOKEN` env var to fetch a single fileId via REST.

**Why the auto-pump exists:** user reported 2026-05-03 that the
Settings screen freezes. W417 makes telemetry independent of any UI —
even if SwiftUI wedges, the streamer keeps shipping chunks via Task.
The maintainer always has a trail server-side.

**Server-side list endpoint (TODO):** the proper REST way is to add
`GET /api/v1/files/recent` server-side and use HTTP fetch instead of
SSH. Until that's done, SSH+SFTP is the working path.

**Since v1.0.1180 (W-LIVELOGOFFMAIN) — where the pump lives now.** Redaction, JSON
serialisation, the bounded backlog and the upload run OFF the main thread on the
`LiveLogWorker` actor (`QAudionApp/Services/LiveLogWorker.swift`); `LiveLogStreamer` is only
the consent / start / stop facade, and `LogRedactor` is the (unchanged) redactor split out of
the main-actor `RuntimeLogSink`. Only a short per-tick copy of the NEW ring entries and the
token / kill-switch read (every 30 s) still touch the main thread. On HTTP 429 / 503 the pump
honours `Retry-After`, else backs off 5 s doubling to 120 s (+ up to 20% jitter), and keeps
collecting into a bounded backlog (2000 lines / 512 KiB, oldest dropped and counted) instead
of retrying. Lines to look for in the shipped log (tag `net`): `livelog upload error seq=..
reason=..` (unchanged), `livelog backoff n=<streak> s=<seconds> ra=<0|1>` (one per throttled
failure) and `livelog backlog drop=<n>` (reported after the next confirmed chunk). The chunk
format is unchanged and pinned by `LiveLogBlobTests`; the pure decisions are `LiveLogBackoff`,
`LiveLogBacklog`, `LiveLogBlob` in `QAudionEngine/.../Diagnostics/`.

**Since v1.0.1180 (W-HBTELEM) — call-quality telemetry.** The 5 s `call.media.heartbeat` now
also carries, when the counter exists: `rx_frames_d`, `tx_frames_d`, `rx_gap_d`,
`jb_underrun_d`, `jb_overrun_d`, `jb_hard_drop_d`, `jb_silence_drop_d`, `jb_concealed_d`,
`jb_stretch_d`, `jb_depth_now`, `jb_target_now`, `iat_max_ms`, `fec_rec_d`, `transport`
(`dc` / `ws` / `dc+ws` / `srtp`) and `main_stall_ms_max` (how much later than 5 s the heartbeat
timer fired = how long the main thread was blocked at that instant). `_d` = count since the
previous heartbeat of the same call (`HeartbeatDeltaTracker`, never negative, survives counter
resets). `nack_req_d` / `nack_srv_d` are NOT sent: iOS has no NACK counters. The new 1:1
in-call "Disturbo" pill emits `call.disturbance.marker` (`since_start_ms`, `source=button`, a
copy of the last completed window's attributes and the live `jb_depth_now`), at most one per
second; same consent gate, batching and transport as the heartbeat. Query them in the server's
`telemetry/*.jsonl` by `kind`.

**Reading those numbers (known limits, W-HBTELEM / W-LIVELOGOFFMAIN).**
`main_stall_ms_max` is ONE sample per window (how late the 5 s heartbeat timer fired), not a
maximum: it only sees a stall that overlaps the timer's due instant, and timer coalescing gives
it a floor of a few tens of ms, so read anything under ~100-150 ms as zero.
`iat_max_ms` is the largest arrival gap over the last `5000 / frameMs` arrivals of the jitter
buffer (about the last 5 s, not aligned to the heartbeat): it never reads below one frame; a
stall late in a window shows up again in the next one; a burst right after a stall can push the
stall out of the window before the heartbeat looks; and an arrival is the push after
decrypt/decode on the main thread, so a main-thread stall also appears here (compare it with
`main_stall_ms_max`). On the native SRTP path (`transport=srtp`) the sealed-frame counters do not
exist, so `rx_frames_d` / `tx_frames_d` are LEFT OUT there, never sent as 0; and a window in which
no sealed frame moved has no `transport` at all (on the server that window forms its own cluster,
because `transport` is part of the cluster signature). The "Disturbo" pill is shown only while the
operational-diagnostics consent is on (without it the emitter discards every event). In the log
shipper, `livelog backlog drop=N` undercounts: it counts lines the worker left out of a
collection (the first collection after a (re)start or a long period without a token keeps only
the newest 2000 ring lines), not lines the 5000-entry ring had already evicted before it looked.

**Since v1.0.1181 (W-KEYSCRUB) -- key bytes never enter the app log.** The iPhone native crypto
library prints key material to stdout during handshakes and re-keys (`derived_key [1,2,..,32] len 32`,
`secret [..] len 32 slat << [] len 0`; "slat" is the library's typo of salt) and the stdout tee
recorded it, so the live-log shipper uploaded it in clear (299 lines in 90 blobs in 7 days). The pure
function `KeyMaterialScrubber` (`QAudionEngine/.../Diagnostics/KeyMaterialScrubber.swift`, a
hand-written linear byte scanner, no regex) replaces it with `[REDACTED:keybytes]`. It runs at ring
entry (`RuntimeLogSink.record`: the ring, the on-screen viewer, the export, the bug-report tail, the
shipper, the OSLog mirror and `BugReporter.onError` only see scrubbed text) and again at the start of
both `LogRedactor` entry points (`redact` for the stdout tee, off-main; `redactStructured` for every
egress incl. `TelemetryService` attrs and `ReportCrypto`), plus on the `OSLogStore` lines of the log
export. **The app calls `scrubLines(_:)` only** (via `LogRedactor.scrubKeyMaterial`): it cuts the text
at every line feed and scans each line on its own (per-line 256 KiB cap), because
`ReportCrypto.buildDiagSummary` runs `redactStructured` on the whole multi-line `recentLogsAsString`
tail, and `scrub(_:)` (one log entry: `derived_key` takes the rest of the TEXT) is not idempotent on a
blob of already-scrubbed lines: it turned every line after a `derived_key <marker>` line into one
marker, so the 200-character `diag_summary` showed an old slice instead of the newest lines.
Patterns: `derived_key` + the rest of the line; `secret`/`slat`/`salt` + a bracketed group;
any `[..]`/`(..)` list of 8+ integers 0-255; 8+ hex bytes separated by space or colon; the head and the
tail of a key line that the 4096-byte pipe read cut in two. **Policy: over-scrubbing is deliberate** (8
small numbers in brackets are scrubbed in ANY line). To see where it acted: `grep REDACTED:keybytes`.
Known limits: builds up to 1.0.1180 still ship the bytes; the raw byte forward of the tee to the
original stdout (a debugger console) is not scrubbed; a key in a shape none of the patterns knows
(bare base64 with no keyword) is left to `LogRedactor`'s long-run rules; hex runs cut in two below 8
pairs each are not caught; a list of integers spread over 3+ lines is not caught in its middle lines
(one line feed, the way the tee cuts a key line, is). Tests: `KeyMaterialScrubberTests` (engine) and
`python scripts/test_keymaterial_scrub_parity.py` (Python port, same golden vectors
`Diagnostics/Resources/key-material-scrub-vectors.json`, `vectors` for `scrub` and `lineVectors` for
`scrubLines`); the port is what replays the real blobs.

**Since v1.0.1182 (W-KEYLOGGATE) -- the iPhone no longer lets WebRTC INFO lines reach stderr.** The key
prints (`api/crypto/frame_crypto_transformer.cc`, `RTC_LOG(LS_INFO)` at ~260 and ~284) only got into the
stdout/stderr tee because W-AUNITTRACE (2026-09-10) called `RTCSetMinDebugLogLevel(.info)`. It now uses
`QAudionPeerConnectionFactory.stderrDebugLogLevel` = `.warning` (pinned by
`testStderrDebugLogLevelStaysAtWarningOrAbove`; do not lower it). `RTCSetMinDebugLogLevel` sets ONLY the
debug/stderr severity (`LogMessage::LogToDebug`, `rtc_base/logging.cc`); the `RTCCallbackLogger` (severity
`.info`, same function) filters on its own level, so the W-AUNITTRACE `aunit ...` lines keep coming (they
never depended on stderr). Trade-off: WebRTC INFO lines are gone from the shipped log (in the last 7 days
these were `channel.cc` "Changing voice/video state", `thread.cc` "took Nms to dispatch", `connection.cc`
"Updating local candidate type", `cpu_info.cc`); WARNING and ERROR lines stay (TURN "Connection with server
failed", `RTCAudioSession` "Failed to setActive", ...) and can hold IP addresses, which the shipper redactor
handles. Limits: builds up to 1.0.1181 still print; the callback still receives the key prints in memory
(`handleNativeLogLine` only pattern-matches, it must never store `message`); `LiveKitWebRTC` (group calls) is a
separate WebRTC copy with its own debug level, untouched here; rebuilding WebRTC without the two prints is the
complete fix, and `KeyMaterialScrubber` stays as defence in depth.

**After v1.0.1181 (W-VPIOOBS / W-VPIOWD / W-BYPASSDUCK, branch `fix/vpio-observability-suppressor`) -- VP-IO
tap latency, watchdog generation, bypass echo ducker.** Why: on the test iPhone Apple's
Voice-Processing I/O never delivers a tap buffer inside the W-AEC-FIX window (71/71 built-in-mic calls in bypass,
~1% elsewhere), and the app could not say why or how late. Numeric log lines (tag `call`, accurate timestamp; numeric
on purpose, for the shipper's redactor, but see the end of this block for what was verified):
`audioVp ev=arm gen=N since_start_ms=0 eng_ms=..` (watchdog armed; `eng_ms` =
`engine.start()` -> end of `start()`), `ev=ff gen=N ms=.. eng_ms=..` (first tap buffer, ms from the end of `start()`
/ from `engine.start()`; `ms` is the tap's own timestamp, the line's timestamp is that of the check: the +1.2 s
watchdog, or earlier the next `start()` / `stop()` / the diag read when the engine is replaced or the call ends
first), `ev=fire gen=N since_start_ms=.. stale=0 er=0|1` (watchdog restarted the engine without
VP-IO; `er` = `AVAudioEngine.isRunning`, 0 = the engine had been stopped, e.g. by a configuration change),
`ev=stale gen=N cur=M ff=0|1 since_start_ms=..` (a timer of a replaced engine expired and was IGNORED),
`ev=noop gen=N since_start_ms=..` (an `.override` route change with an unchanged route was ignored), `ev=cfg gen=N
eng_ms=..` (an `AVAudioEngineConfigurationChange` on the live engine; the observer is registered BEFORE
`engine.start()`, a change posted during the start is counted once `start()` returns), `ev=duck gen=N on= en= vpio=
spk=` (per engine start: ducker eligible / remote switch / VP-IO active / loudspeaker). `call.audio.diag` (same
consent gate as every field there; a key is omitted when it was not measured): `vpio_watchdog_gen` (+1 per start and
per stop), `vpio_starts`, `vpio_first_frame_ms` / `vpio_first_frame_eng_ms` (FIRST VP-IO start; absent = it delivered
nothing before the 1.2 s window closed, the engine was replaced or the call ended), `vpio_last_frame_ms`,
`vpio_starve_fired`, `vpio_starve_stale`, `vpio_starve_gen`, `vpio_starve_ms`, `engine_cfg_changes_2s`, and once per call `hw_machine` (sysctl), `os_build`, `mic_mode`
(0 standard, 1 wide spectrum, 2 voice isolation), `input_ports`, `preferred_input` (AVAudioSession port types;
`ContinuityMicrophone` ships as `ContinuityMic`, the on-device redactor masks a 20+ character run), `tap_fmt_before` /
`tap_fmt_after` (`<Hz>/<channels>` of the input node before / after enabling voice processing). `engine_running_at_end`
is now real (it was false on every record: `stop()` latched it after the stats were consumed). Reading: no
`vpio_first_frame_ms` + `vpio_starve_fired>=1` = the tap stayed silent for the whole 1.2 s window (the window is
NOT widened, so "late" vs "never" past 1.2 s is still unknown); `tap_fmt_before` != `tap_fmt_after` = the format
moves when VP-IO is enabled; `er=0` / `engine_cfg_changes_2s>0` = the engine was stopped under the tap.
`vpio_starve_stale>0` used to mean a false starve (an older engine's timer judging a newer one); it is ignored now.
Watchdog fix: the timer only judges the engine generation it was armed for (`VpioWatchdogDecisions.starveVerdict`),
and an `.override` within 1.5 s of a start whose effective route (input/output port type + uid, speaker flag) equals
the one the engine was built for does not rebuild the engine (`isOverrideNoOp`); a real speaker toggle still does.
The shared throttle / suppress window is deliberately NOT armed at the end of `start()`: `AppState` re-asserts
`setSpeaker(true)` right after `start()` on the CallKit `didActivate` path and that window would drop the rebuild.
Ducker (`BypassEchoDuck`): only with VP-IO NOT active on the engine AND the built-in loudspeaker as output; while the
far end is audible (RX frame RMS >= 1% within 200 ms) and the mic is not clearly local speech the TX gain goes to
0.25 (-12 dB) in 100 ms, is held 120 ms, released in 300 ms (100 ms when local speech dominates). "Local speech" =
mic >= 1.4 x (leave: 1.0 x) the PEAK-HELD RX level (`heldPlayedRms`, 500 ms decay: the mic hears a frame 0.3-0.4 s
after it was stamped on arrival, so the last frame's level would read the echo of a strong syllable as local speech).
Folded into the make-up AGC as its last multiplier (the AGC is not limited; a duck before the AGC would be undone by
it). Kill switch: `flags.json` key `ios_bypass_echo_duck` (default ON; publishing it `false` for the first calls is
the A/B without a new build). Telemetry: `echo_duck_enabled`, `echo_duck_frames`, `echo_duck_active_pct`,
`echo_duck_gain_min`, `echo_duck_near_pct` (0 = the near-end test never fired). Uncalibrated on iOS (no ERLE
measured): the raw iPhone mic is quiet, so in practice it is a -12 dB gate on the TX while the far end talks. With the
ducker active, tx `rms_pct` / `peak_pct` / `clip_samples` in `call.audio.diag` are measured AFTER the duck (about 12 dB
lower while the far end talks) and do not compare with the earlier series when `echo_duck_active_pct > 0`; `agc_gain`
is the AGC law alone (the duck is not in it). The server's `TELEMETRY_ATTRIBUTE_CONTRACT.md` (bcrypto-server/docs)
does not list the new keys yet (they are additive, so nothing breaks; add them to that document alongside this
change). Log pipeline: replaying the seven `audioVp` line forms (synthetic values) through the redactor of `main` as
of #111 (`scripts/ship-ios-logs.py`) gave 2 of 7 verbatim (`ff`, `noop`); `arm` came back with `since_start_ms`
masked; `fire`, `stale`, `cfg` and `duck` were dropped. Which redactor version runs on the log pipeline is not
verified, and real phone logs were not tested; the `call.audio.diag` fields use a different path and are not
affected. If that stricter redactor is, or becomes, the one running there, its vocabulary needs `gen`, `cur`, `ff`,
`er`, `stale`, `since_start_ms`, `eng_ms`, `ms`, `on`, `en`, `vpio`, `spk` and the `ev` words: that is a separate
shipper-vocabulary change, not part of this branch.
Tests: `VpioObservabilityTests`, `VpioWatchdogDecisionsTests`, `BypassEchoDuckTests` (engine).

## Project snapshot

- **Repo:** `github.com/sigarone/Q-Audion-IOS`
- **Platform:** iOS 16.0+ / iPadOS 16.0+, Xcode 16.2
- **Team:** configured in GitHub Secrets (paid Apple Developer account)
- **Bundle id:** `com.qaudion.app`
- **Current status:** ✅ Distribution pipeline green; app v1.0.0 (build 1) is on TestFlight and installed on the internal testers' devices.

### Top-level layout

```
QAudionApp/          # The iOS app (SwiftUI) — XcodeGen-generated project
  project.yml        # XcodeGen spec; .xcodeproj is NOT committed
  Info.plist
  QAudion.entitlements
  Assets.xcassets/   # icon_1024.png MUST be opaque (no alpha)
  Services/, Views/
QAudionEngine/       # Swift package with crypto + audio C libs
  Package.swift      # swift-tools-version 5.9
  Sources/
    CLiboqs/         # ML-KEM-1024 (post-quantum KEM)
    COpus/           # Opus + SILK + CELT audio codec
    QAudionEngine/   # Swift API layer
  Resources/
    aasist_raw_*.onnx  # Deepfake detection models (run via onnxruntime)
.github/workflows/
  engine-tests.yml   # macOS Swift test CI (every push)
  ios-testflight.yml # TestFlight build pipeline (tag v*)
  kat-cross-platform.yml  # KAT cross-platform interop tests
```

> **Build platform = GitHub Actions** (decommission of Codemagic
> 2026-05-06 per user directive — `codemagic.yaml` removed from the
> repo, the `ios-testflight.yml` workflow is the drop-in replacement).
> The `codemagic-cli-tools` Python package is still used inside the
> GitHub Actions steps because it produces the same Distribution
> cert / provisioning profile flow the Apple API expects, so the
> hard-won lessons below transfer 1:1 to the new pipeline.

## Build / release pipeline (CRITICAL — read before changing `.github/workflows/ios-testflight.yml`)

### How a release happens

1. Developer pushes a git tag `v*` (e.g. `v1.0.23`) to `origin/main`.
2. GitHub Actions fires workflow `TestFlight build` (file
   `.github/workflows/ios-testflight.yml`) on a `macos-latest` runner.
3. XcodeGen generates `QAudionApp.xcodeproj` from `project.yml`.
4. Code-signing script (running `app-store-connect` from the
   `codemagic-cli-tools` Python package) creates/fetches Distribution
   cert + App Store profile via the Apple API.
5. `xcode-project build-ipa` produces `QAudionApp/build/ios/ipa/QAudionApp.ipa`.
6. **Post-build patch step** (see "Known ONNX bug" below) rewrites
   `onnxruntime.framework/Info.plist` and re-signs the bundle.
7. Publishing uploads the IPA to App Store Connect; internal tester
   group **`Q-Audion testers`** gets the build automatically.

### Trigger philosophy

- **Tag push `v*`** → full TestFlight pipeline (`ios-testflight.yml`).
- **Workflow_dispatch** with optional `tag` input → ad-hoc rebuild.
- **Main branch push** → `engine-tests.yml` (macOS Swift unit + cross-platform
  KAT, same job) only — no iOS build. `kat-cross-platform.yml` doesn't
  auto-trigger (see the workflow table above for why).
- **Never** trigger TestFlight builds from branches — always tag.

## Hard-won lessons — DO NOT REPEAT THESE MISTAKES

### 1. App Store Connect API key — managed via GitHub Secrets

GitHub Actions reads the ASC credentials from repository secrets
(`Settings → Secrets and variables → Actions`):

| Secret | Content |
|---|---|
| `APP_STORE_CONNECT_KEY_IDENTIFIER` | Key ID of the Admin ASC API Key |
| `APP_STORE_CONNECT_ISSUER_ID`      | Issuer UUID from ASC → Users & Access → Integrations |
| `APP_STORE_CONNECT_PRIVATE_KEY`    | Full content of the .p8 file |
| `CERTIFICATE_PRIVATE_KEY`          | PEM content of the Distribution cert's RSA 2048 private key |

The workflow exposes these as env vars to the codemagic-cli-tools
steps using the same names — no other rewriting needed.

### 2. API key role — Admin or nothing

`app-store-connect fetch-signing-files --create` needs to create a
Distribution certificate and App Store provisioning profile via the
Apple API. Only **Admin** role keys can do this. App Manager /
Developer roles cannot.

The current working Key ID is stored in the `APP_STORE_CONNECT_KEY_IDENTIFIER`
GitHub secret. If it's ever revoked, the replacement MUST be Admin-role
and the new value goes in that same secret.

### 3. Distribution cert private key must be supplied

`fetch-signing-files --create` needs an RSA private key to sign the
CSR. GitHub Secret `CERTIFICATE_PRIVATE_KEY` stores it in PEM format
(with `-----BEGIN PRIVATE KEY-----` / `-----END PRIVATE KEY-----`).

The PEM source of truth lives OUTSIDE the repo (local developer
machine only). **Never commit it.** If lost, a new Distribution cert
must be revoked & recreated (Apple allows max 2 per team).

The correct CLI flag is `--certificate-key "@file:$CERT_KEY_PATH"`,
NOT `--certificate-key-path`.

### 4. ONNX Runtime — pinned exact, always patch the Info.plist

The dependency is **pinned exact** in `QAudionEngine/Package.swift` (currently **1.24.2**):

```swift
.package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", exact: "1.24.2"),
```

**History:** 1.17.0 was the original pin. It ships with a broken `onnxruntime.framework/Info.plist` where `MinimumOSVersion=""` (empty string) — Apple's altool rejects this. The framework's Mach-O (`LC_BUILD_VERSION`) correctly declared iOS 16.0 minimum, so the CI patch step was introduced to set `MinimumOSVersion = "16.0"` to match. Bumped to 1.24.2 (commit `b33d4f4`) because it declares iOS 15+ in its own Package.swift, avoiding the iOS 18 issue seen in intermediate releases (1.20+). ⚠️ **First TestFlight build with 1.24.2 not yet validated** — if ITMS-90208 appears after the next tag push, read the CI `diag.log` artifact and check that the Mach-O `minos` still matches 16.0.

**Upgrade rule:** Before bumping to any new version, verify its XCFramework Mach-O `minos` with `otool -l onnxruntime.framework/onnxruntime | grep -A3 LC_BUILD_VERSION`. The value patched into `Info.plist` (16.0) must be **≥ the Mach-O minos** or ITMS-90208 fires.

**Workaround in `.github/workflows/ios-testflight.yml` — the "Patch onnxruntime.framework" step**:
1. Unzip the IPA produced by `xcode-project build-ipa`.
2. `plutil -replace MinimumOSVersion -string "16.0" Payload/QAudionApp.app/Frameworks/onnxruntime.framework/Info.plist` — **must match or exceed the Mach-O `minos`**. Mismatch triggers ITMS-90208.
3. Re-sign the framework with `codesign --force --sign "$IDENTITY"`.
4. Re-sign the app with its original entitlements (dumped to a REAL file, not via `<(…)` process substitution — the latter creates `/dev/fd/63` which codesign can't stat).
5. Repackage the IPA and let publishing pick it up.

This step is version-agnostic — it runs on every build regardless of the pinned version. Do not remove it.

### 5. XcodeGen system frameworks

In `QAudionApp/project.yml`, system SDK frameworks must use `sdk:`, not `framework:`:

```yaml
dependencies:
  - package: QAudionEngine
  - sdk: CoreAudio.framework
  - sdk: AudioToolbox.framework
  - sdk: Accelerate.framework
```

`framework:` causes XcodeGen to look for a local path and error with `No such file or directory`.

### 6. Platform declaration in Package.swift

`swift-tools-version: 5.9` only supports `.iOS(.v13)` through `.iOS(.v17)`. **`.iOS(.v18)` is Swift 6.0+ only** and breaks SwiftPM resolution with "Failed to show build settings" (exit 74).

Use the string form `.iOS("18.0")` if you need iOS 18+ on the 5.9 tools version. Currently we're at `.iOS(.v16)` which is safe.

### 7. IPA artifact path

`xcode-project build-ipa` runs with `cd QAudionApp` and writes to `QAudionApp/build/ios/ipa/*.ipa` (relative to repo root). The `artifacts:` block must include `QAudionApp/build/ios/ipa/*.ipa` — otherwise publishing emits `Skip publishing to App Store Connect: no IPAs or PKGs found` silently.

### 8. TestFlight beta group name

The group in App Store Connect is **`Q-Audion testers`** (lowercase "t", with hyphen). The `app-store-connect publish --testflight --beta-group "Q-Audion testers"` step in `ios-testflight.yml` must match exactly — the publish step fails silently (2s step) if the group doesn't exist.

### 9. Apple-required Info.plist keys

Current keys that must NOT be removed:

- `NSMicrophoneUsageDescription` — voice calls
- `NFCReaderUsageDescription` — NFC key import from Android
- `NSCameraUsageDescription` — QR code key exchange
- `NSContactsUsageDescription` — required, and NOT a false-positive: the app genuinely uses `CNContactStore` (manual phone-book import in `PhoneContactImportView`/`PhonebookSyncCoordinator`, and auto-save-from-call device-contact enrichment in `NameResolutionService`). The string must describe that real usage — see `Info.plist` (fixed 2026-07-29; it used to falsely claim "does not access your contacts", which this same file used to also assert — don't reintroduce either claim)
- `UISupportedInterfaceOrientations~ipad` — must contain all 4 orientations for iPad multitasking, even if iPhone is Portrait-only

### 10. NFC entitlement format

`com.apple.developer.nfc.readersession.formats` accepts `TAG` (generic tag reading) on iOS SDK 18.2. **`NDEF`** is disallowed — Apple rejects the bundle with "NDEF is disallowed, TAG is missing in the entitlement".

The Swift code that handles NFC may need to be reviewed if it was written against the NDEF API — with TAG format the delegate receives `[NFCTag]` not `[NFCNDEFMessage]`. Confirm with runtime testing before assuming it works.

### 11. App icon alpha channel

`QAudionApp/Assets.xcassets/AppIcon.appiconset/icon_1024.png` **must be opaque RGB**, no alpha. ITMS-90208 rejects RGBA icons. If the icon is re-exported from a design tool, run:

```python
from PIL import Image
img = Image.open(path).convert('RGBA')
bg = Image.new('RGB', img.size, (255, 255, 255))
bg.paste(img, mask=img.split()[-1])
bg.save(path, 'PNG', optimize=True)
```

### 12. Xcode 26 / iOS 26 SDK deadline ✅ RISOLTO

**Storico:** Apple emise **ITMS-90725** (informational) su ogni upload con build Xcode 16.2: "starting **April 28, 2026**, App Store Connect will only accept builds made with Xcode 26 / iOS 26 SDK".

**Stato attuale (post W396 + GH-Actions migration 2026-05-06):** il workflow `.github/workflows/ios-testflight.yml` runa su `macos-latest` (GitHub Actions automatically rolls the image as Apple ships new Xcode); the workflow has a discovery step that fails fast if Xcode 26+ isn't available so the build never silently falls back to an older SDK.

GitHub Actions Xcode availability windows on the `macos-latest` runner:

- **macos-15** ships Xcode 16.x default + Xcode 26.x as a non-default install path.
- **macos-26** (rolling out 2026-Q3+) ships Xcode 26.x default.

If GitHub Actions ever drops Xcode 26 from `macos-latest` before
Apple raises the SDK floor again, pin the runner to a specific image
(e.g. `runs-on: macos-15`) and use `sudo xcode-select -s /Applications/Xcode_26.4.app`
explicitly in a step.

**Quindi:** la deadline 28/04/2026 NON è un problema — i build di questa repo usano l'SDK richiesto. ITMS-90725 non viene più emesso post-W347.

## Known open issues / next debugging topics

The app is on TestFlight but has not been exercised end-to-end. Expect to debug:

1. **NFC key import** — entitlement switched from `NDEF` to `TAG` for Apple compliance; Swift code may need adaptation.
2. **Post-quantum key exchange** (ML-KEM-1024 via liboqs) — runtime correctness across iPhone hardware/accelerators.
3. **Voice call quality** — Opus + SILK with our SILK source patches from v1.0.4; cross-platform interop with the Android client (see commit `e350b6a fix(compat): align wire format with Android`).
4. **AASIST deepfake detection** — onnxruntime 1.17.0 inference on iOS; currently patched frameworks may introduce subtle issues. Watch for crashes or weird spoofing scores on the first run.
5. **Memory / battery profile** — post-quantum crypto is heavy; Instruments run overdue.
6. **Group call (`GroupCallView`)** — added in commit `c3d5426`, never tested on TestFlight before.
7. **Export compliance for External TestFlight / public App Store** — ML-KEM post-quantum is NOT standard "mass market" cryptography; consult legal before enabling External testers or submitting for App Store review.

## Reference files & commits

- `IOS_BUILD_ERRORS.md` — historical list of Swift compile errors resolved
- `SESSION_LOG.md` — work log per session
- Last green build on TestFlight: tag `v1.0.22` (commit `626c807`)
- The debugging saga from "nothing to TestFlight" spans tags `v1.0.4` → `v1.0.22`; read git log for the blow-by-blow:
  ```
  git log --oneline v1.0.3..v1.0.22
  ```

## Rules for subsequent agents

1. **Never touch code signing config** (`integrations`, `environment.ios_signing`, `auth: integration`) without re-reading sections 1–3 above — the Personal Account topology is fragile.
2. **Before upgrading `onnxruntime-swift-package-manager`** verify the new XCFramework's Mach-O `minos` with `otool -l` (see sec 4). The CI patch step forces `MinimumOSVersion = "16.0"` — safe as long as the Mach-O minos is ≤ 16.0. Currently pinned to **1.24.2** (iOS 15+ minos, compatible).
3. **Never remove the "Patch onnxruntime.framework" step** in `.github/workflows/ios-testflight.yml` — the pipeline breaks silently on validation otherwise.
4. **Always bump the tag** for a new release (e.g. `v1.0.23`). Don't re-use old tags; don't build from branches.
5. **Treat Apple emails after upload as canonical**. The publish step reporting "publishing succeeded" only means the upload HTTP call returned 2xx. Apple may still reject on validation minutes later via email. Always check inbox before declaring victory.
6. **Use `TodoWrite` for multi-step tasks** and follow the superpowers skill guidance when relevant.
7. **New testable logic (parsing, policy, formatting, decision functions) goes into `QAudionEngine`**, where
   `engine-tests.yml` runs `QAudionEngineTests` on pushes to main/develop and on PRs. `QAudionAppTests/` is not wired into any
   build target (`QAudionApp/project.yml` declares no unit-test target and no workflow runs that folder), so
   app-level tests do not run today; keep the app side a thin call into the engine.

### 13. Swift type-checker timeout traps (Xcode 26.4)

Xcode 26.4 / Swift 6's type-checker is **less forgiving** than earlier versions for multi-segment string interpolation inside `@Sendable` closures or `Task { @MainActor in ... }` blocks. Patterns to avoid:

```swift
// ❌ TYPE-CHECKER TIMEOUT (silent build failure):
Task { @MainActor in
    print("[X] received \(obj.field) at \(timestamp)ms (\(other.nested))")
    snackbar?.show(.init(text: "\(a) of \(b) failed.", ...))
}

// ✅ Pre-bind locals or use String + concat:
Task { @MainActor in
    let a = obj.field
    let b = timestamp
    let c = other.nested
    print("[X] received " + String(a) + " at " + String(b) + "ms (" + c + ")")
    let msg: String = "\(a) of \(b) failed."
    await MainActor.run { snackbar?.show(.init(text: msg, ...)) }
}
```

**v1.0.253 update — pre-binding alone is NOT enough.** Even this pattern still trips the type-checker:

```swift
// ❌ STILL TIMES OUT (v1.0.251 → v1.0.252 broke on this exact line):
let errMsg: String = error.localizedDescription
print("[VoiceNote] start failed: " + errMsg)
```

The reason: `print` has many overloads (variadic, separator:, terminator:, to: &Output). Combined with `String + String → String` operator overloads, the type-checker explores too many resolution paths. The `+` MUST live outside the `print(...)` call:

```swift
// ✅ WORKS:
let errMsg: String = error.localizedDescription
let line: String = "[VoiceNote] start failed: " + errMsg
print(line)
```

**Rule of thumb**: if a closure builds a String for `print` / `snackbar.show` / any function with overloads, build the full String into a `let line: String = ...` first, then pass that single String. Never do the concatenation or interpolation inline at the call site.

**v1.0.255 update — `String(numericValue)` is also a trap.** `String(_:)` has many numeric overloads (Int, UInt, Int64, UInt64, Double, Float, NSNumber, Substring, Character, CChar, …). Inside a complex closure, even an unambiguous `Int` argument can trigger overload-resolution timeout:

```swift
// ❌ TIMES OUT (rec.durationMs is Int):
let recDur: String = String(rec.durationMs)

// ✅ WORKS — String(describing:) has a single overload:
let recDur: String = String(describing: rec.durationMs)
```

Other safe alternatives that don't go through `String(_:)`'s overload set:
- `"\(rec.durationMs)"` (single-segment interpolation of a primitive — usually fine)
- `rec.durationMs.description`
- Any explicit cast first: `let n = Int(rec.durationMs); let s = "\(n)"`

**v1.0.256 update — even pre-bound `+` concat with explicit types times out.** The most stubborn variant:

```swift
// ❌ TIMES OUT, even with both sides explicitly typed as String:
let errMsg: String = error.localizedDescription
let line: String = "[VoiceNote] start failed: " + errMsg
print(line)
```

The `+` operator has many overloads (String+String, Array+Array, AdditiveArithmetic, custom Self+Self conformances, …). Inside a deeply nested closure (e.g. `Task { do { try await ... } catch { ... } }` inside a SwiftUI ViewBuilder argument), the type-checker exhausts its budget exploring all `+` candidates plus all the closure's surrounding constraints.

**Pragmatic rule for debug prints in nested closures**: don't build the String at all. Either:
1. Drop the print (debug-only logs aren't load-bearing — `_ = error` to suppress unused-variable warnings)
2. Use multiple `print()` calls with single-literal arguments (no concatenation)
3. Move the formatting to a top-level helper function called from the closure (lifts type inference out of the nested context)

Production code should use `os_log` / `Logger` anyway, never `print`.

**v1.0.258 update — even trivial function calls time out at sufficient closure depth.** v1.0.256 dropped all the String construction. v1.0.257 build STILL failed:

```
ChatDetailScreen.swift:145:29: error: the compiler is unable to type-check this expression in reasonable time
container.markFailed(messageId: UUID(), reason: .generic)
^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
```

A bog-standard method call with two arguments — but inside `closure → Task → do/catch with pattern matching` it's enough to exhaust the type-checker.

**The structural fix**: extract the inline closure body into a named method.

```swift
// ❌ BEFORE — 4 levels of closure constraints:
onStartVoiceNote: {
    HapticFeedback.recordingStart()
    Task {
        do {
            try await voiceNoteRecorder.start()
        } catch VoiceNoteRecorder.RecorderError.permissionDenied {
            container.markFailed(messageId: UUID(), reason: .generic)  // TIMES OUT
        } catch {
            _ = error
        }
    }
},

// ✅ AFTER — closure is trivial, type-checker has clean scope per method:
onStartVoiceNote: handleVoiceNoteStart,

private func handleVoiceNoteStart() {
    HapticFeedback.recordingStart()
    Task { await self.startVoiceNoteAsync() }
}

private func startVoiceNoteAsync() async {
    do {
        try await voiceNoteRecorder.start()
    } catch {
        await MainActor.run {
            container.markFailed(messageId: UUID(), reason: .generic)
        }
    }
}
```

**Rule of thumb**: any inline closure body deeper than `closure → Task → do/catch` should be moved to a method. Reference the method by name in the closure-binding parameter (no `{ ... }` at the call site).

Symptoms: the build console shows just `Failed to archive` with **no `error:`/`warning:` lines** — xcbeautify is consuming the diagnostic before tee can capture it.

**Mitigation:** `.github/workflows/ios-testflight.yml` has a "Diagnose Swift compile (raw xcodebuild)" step that runs before `xcode-project build-ipa` with `CODE_SIGNING_ALLOWED=NO`. That output is uploaded as the `diag.log` artifact and is grepped at the end of the build step. Always check the diagnose step in failed runs, not just the Build IPA step.

### 14. Single-file Swift compile budget

`ChatDetailScreen.swift` is the largest user-facing file (~830 lines after the v1.0.225 markdown extraction). Adding more state observers or complex view-builder branches risks the type-checker timeout. **Extract any new helper > 40 lines into its own `Services/*.swift` file** — see `Services/MarkdownLiteParser.swift` (W148/W149/W127/W152) as the reference pattern.

### 15. `guard let self = self` patterns in @Sendable closures

Xcode 26.4 elevates `value 'self' was defined but never used` from warning to **error** in some compile modes. If the closure body doesn't actually call `self.foo`, replace:

```swift
{ [weak self] _, _ in
    DispatchQueue.main.async {
        guard let self = self else { return }   // ❌
        print("...")
    }
}
```

with:

```swift
{ [weak self] _, _ in
    DispatchQueue.main.async {
        guard self != nil else { return }       // ✅
        print("...")
    }
}
```

(Already fixed at AppState.swift:1327 — see commit `d31f34e`.)

### 16. NEVER take `AppState` as a direct parameter type in a NEW Swift file

**Symptom:** add a brand-new Swift file with even a trivial method
signature `func foo(appState: AppState)` and the build fails at
"Build IPA" exit 65 with NO actionable error in xcbeautify's filtered
console output. Step 6 "Diagnose Swift compile" succeeds (it always
exits 0) but Step 7 fails. Searching for `error:` in the artifact
log gives no useful match — the failure is silent.

**Bisect proof (2026-05-03, v1.0.386→v1.0.397, 13 build cycles):**

| Stub class body | Build |
|---|---|
| `func start(appState: AppState) {}` (with or without @MainActor) | ❌ |
| `func start(serverUrl: String) {}` | ✅ |
| `func start(getToken: @MainActor () -> String?) {}` | ✅ |
| No method, just `static let shared = Self()` | ✅ |

**Root cause hypothesis (we couldn't always read the actual diag.log
because `xcode-project build-ipa` filters Swift errors through
xcbeautify before they reach our captured output; under GitHub
Actions the diag.log is now uploaded as a normal artifact and is
inspectable directly from the run page):** Swift 6's
strict-concurrency Sendable inference walks the AppState type when
it appears as a parameter type. AppState is ~2000 lines, has dozens
of `@Published` properties wrapping non-Sendable Combine publishers,
references many third-party types (RTCIceServer, BackendProvider,
QAudionEngine internals) — the inference graph apparently exceeds
some compiler budget and the diagnostic is then swallowed by
xcbeautify, surfacing only as a non-zero exit.

**The rule:** ANY new file that needs to interact with `AppState`
state MUST take primitive values (`String`, `Bool`, `Int`) plus
`@MainActor () -> T?` closures. Never the AppState type directly:

```swift
// ❌ Will silently break the build:
public func start(appState: AppState) { ... }

// ✅ Use primitives + closures:
public typealias TokenProvider = @MainActor () -> String?
public typealias UserIdProvider = @MainActor () -> String?
public func start(serverUrl: String,
                  getToken: @escaping TokenProvider,
                  getUserId: @escaping UserIdProvider) { ... }
```

Then in AppState.initialize():
```swift
LiveLogStreamer.shared.start(
    serverUrl: serverUrl,
    getToken: { [weak self] in self?.authService.loadToken() },
    getUserId: { [weak self] in self?.currentUserId }
)
```

The closures capture only the specific values at call sites, never
dragging the AppState type into the parameter signature.

**Why existing files work:** files that have always referenced
AppState (e.g. `CallService`, `ChatContainer`, `SecurityDashboard`)
were created before some Swift toolchain update, so their AppState
references are baked into the project's incremental compile graph in
a way that doesn't trip the new diagnostic. Adding a NEW file with
the same pattern is what triggers it.

**Reference:** see `LiveLogStreamer.swift` (W417) for the canonical
shape. The bisect commit chain is v1.0.386→v1.0.397 if this happens
again — `git log --oneline v1.0.385..v1.0.398` reads like a story.

## Audio / call-path changes — mandatory gate (added 2026-08-30 after a 13-build regression spiral)

Before ANY build that touches the audio, session or crypto path:

1. Pull the FULL telemetry corpus (not greps) and lay the key metrics out build
   by build. First question is always "did my own last change break this?".
2. Name the log line or file:line that PROVES the cause. No proof, no build.
3. Android is the specification. Read its implementation and port its exact
   rule, ordering and constants — never invent an iOS mechanism to match.
4. Adopting an SDK mechanism means reading every related class in the
   xcframework headers first, not one property.
5. One hypothesis-driven build maximum. If it misses, stop shipping and run the
   systematic cross-platform analysis instead.

Full rationale and the incident that produced this: memory
`feedback_no_blind_ship_regression_discipline`.
