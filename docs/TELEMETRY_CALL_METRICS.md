# Call monitoring metrics (iOS)

This file lists the call-quality numbers the iOS app writes to its runtime log and to the `call.audio.diag` telemetry record, so that an analysis tool can read every number it needs from a call. It describes the instrumentation added in the call-metrics change; the code is in `QAudionEngine/Sources/QAudionEngine/Diagnostics/CallMetrics.swift` and `NativeEchoProxy.swift` (pure logic, unit-tested) and `QAudionApp/Services/CallService+CallMetrics.swift` (the wiring).

Two rules hold for every line below. A value that was not measured is left out of the line (never printed as -1 or -1000 or 0), because the readers parse numbers and a sentinel would enter their statistics as a real value. And every line is numbers plus a fixed family word, because the log shipper's redactor is a fail-closed allow-list (see `scripts/ship-ios-logs.py`, `APP_VOCAB`).

## Heartbeat, every 5 s, native SRTP calls

Tag `call`. `audiosrtp hb=1` and `audiosrtp hb=2` already existed; what changed is described per field. All three lines are only written while a call id exists.

### hb=1 (instantaneous values)

Unchanged names and units: `tx` / `rx` (bytes, cumulative), `ptx` / `prx` (packets, cumulative), `lost` (packets, cumulative), `jitter` (ms, RFC 3550 interarrival jitter), `outp` (output port name), `vol` (0..100), `rtt` (ms, ICE pair), `rtx`, `mslvl` and `rxlvl` (audio level times 1000), `mseng`, `tsr`, `isd`, `rsa`, `clk`, `ch` and the string fields. Change: a field whose stats row does not exist is now omitted. Before, `lost=-1`, `jitter=-1000`, `ptx=-1` and the like were printed.

### hb=2 (resilience line)

Pre-existing, unchanged names and order: `rtt` (ms), `jitter_ms` (ms, average playout-buffer delay over the interval, not the RFC jitter), `target_ms` (ms, same for the buffer target), `plc` (concealed samples since the previous heartbeat), `fec_recv`, `fec_drop`, `nack` (packets or NACKs since the previous heartbeat), `remote_loss` (per mille, the peer's receiver report for our audio), `remote_rtt` (ms, the peer's round trip), `relay` (0 none, 1 udp, 2 tcp, 3 tls, 4 through the WSS bridge), `network_type` (0 unknown, 1 wifi, 2 ethernet, 3 cellular, 4 vpn). Missing values are now omitted (the first heartbeat of a call has none of the deltas).

New fields, the extremes of the 1 s samples inside the interval, so a spike between two heartbeats is no longer missed:

| field | unit | meaning |
|---|---|---|
| `rtt_max` | ms | largest ICE pair round trip seen in any 1 s sample of the interval |
| `jitter_max` | ms | largest RFC 3550 interarrival jitter of the inbound audio (same quantity as hb=1 `jitter`, not as `jitter_ms`) |
| `rtt_remote_max` | ms | largest peer-reported round trip |
| `lost_max` | packets | largest number of packets newly counted lost within one 1 s sample. The stats API exposes only the cumulative count, never the length of a consecutive run, so the real burst is at most this value and at least 1 when it is non-zero. |
| `plc_max` | samples | largest number of concealed samples within one 1 s sample (at 48 kHz, 48000 is one second of concealment) |
| `sample` | count | how many 1 s samples the extremes cover (4 or 5; fewer means the stats poll skipped a second) |

A field is absent when no sample of the interval carried it. Counters that go down (an ICE restart replaces the stats object) re-baseline instead of producing a delta.

Example:

    audiosrtp hb=2 rtt=7 jitter_ms=77 target_ms=80 plc=0 fec_recv=44 fec_drop=45 nack=0 remote_loss=0 remote_rtt=20 relay=0 network_type=1 rtt_max=12 jitter_max=3 rtt_remote_max=21 lost_max=0 plc_max=0 sample=5

### hb=4 (audible concealment)

New. `plc` of hb=2 is the delta of the inbound `concealedSamples`, which by the WebRTC stats spec includes `silentConcealedSamples` (concealment while the sender is silent or in DTX). A quiet peer therefore produces fully concealed windows (240000 samples in 5 s at 48 kHz) that nobody hears as a fault. hb=4 splits it. AUDIBLE concealment = concealed minus silent_concealed.

| field | unit | meaning |
|---|---|---|
| `plc_silent_ms` | ms | concealment of the interval produced while the sender was silent or in DTX (silentConcealedSamples delta, at 48 kHz) |
| `plc_hear_ms` | ms | the rest: (concealedSamples delta minus silentConcealedSamples delta), at 48 kHz. This is what the listener can hear as a fault. |
| `plc_event` | count | concealment events in the interval (concealmentEvents delta) |

Values are in ms, not samples, so no number reaches 6 digits (the shipper drops a line with more than two such numbers). Fields are omitted when a counter is missing or the pair is inconsistent. Example: `audiosrtp hb=4 plc_silent_ms=5000 plc_hear_ms=0 plc_event=1`.

### hb=3 (echo and voice-processing state)

New. Written on every heartbeat of every call, native or not.

| field | unit | meaning |
|---|---|---|
| `eng` | code | 1 = WebRTC's own audio unit carries the call (native SRTP), 2 = the app's AVAudioEngine (legacy call, or the native call's ICE-loss fallback) |
| `vpio` | 0/1 | Voice-Processing I/O. On `eng=2` it is read from the audio pipeline: 1 active, 0 bypassed or off. On `eng=1` it is the configuration: 1 when the unit is enabled and WebRTC's factory is built with voice processing on. iOS does not let an app read whether the echo canceller inside that unit works, so `vpio=1` on `eng=1` is "configured", not proof. |
| `duck` | 0/1 | the bypass echo ducker is armed (`eng=2` only; always 0 on `eng=1`, which has no software suppression stage) |
| `echo_act` | frames | 10 ms microphone frames in this interval that were captured while the far end had been audible within the last 200 ms |
| `echo_idle` | frames | microphone frames captured while it had not |
| `echo_far` | frames | render callbacks seen (loud or not). 0 means the far-end hook did not run and the proxy was blind |
| `echo_active_db` | dBFS | RMS of the active bucket, whole dB below full scale (negative). Absent when the bucket is empty. |
| `echo_idle_db` | dBFS | the same for the idle bucket |
| `echo_suspect` | 0/1 | the proxy below |

The echo fields appear only on `eng=1`; the legacy engine has its own buckets in `call.audio.diag`.

Example:

    audiosrtp hb=3 eng=1 vpio=1 duck=0 echo_act=120 echo_idle=380 echo_far=500 echo_active_db=-23 echo_idle_db=-41 echo_suspect=1

#### What `echo_suspect` is, and is not

It is a proxy. It is not an ERLE and not an echo return loss, and the app does not call it that anywhere. iOS offers no per-frame echo-cancellation figure through a public API, and on the native path the canceller is inside WebRTC's voice-processing unit.

Two hooks that already ran on every native call are used. The capture post-processing hook sees the microphone after the hardware canceller, which is the signal that is encoded and sent. The render pre-processing hook sees the far-end signal about to be played. A capture frame counts as active when a far-end frame of RMS 0.01 of full scale (about -40 dBFS) or more was played in the last 200 ms, otherwise idle. These are the same thresholds as the legacy engine's `echo_active_*` and `echo_idle_*` buckets. A window (one heartbeat interval) is flagged `echo_suspect=1` when both buckets hold at least 50 frames (0.5 s), the active bucket is at least -40 dBFS, and the active RMS is at least 3 times the idle RMS (about +9.5 dB), with the idle RMS floored at 0.002 (-54 dBFS) so digital silence cannot make a trivial ratio.

Limits to keep in mind when reading it. Double talk: when the near-end person speaks while the far end plays, the active bucket is louder for a reason that is not echo, so a flag is a suspicion to read next to `rxlvl`, `mslvl` and the route, never a verdict. An earpiece route has no acoustic path from loudspeaker to microphone at all. There is no sample alignment, only "some far-end energy was audible recently". If `echo_far` is 0 the render hook did not run and every frame is idle.

## Audio route line

New. Tag `call`, the family word `audioroute` at the start of the body (the shipper's tag allow-list is deny-by-default and has no `audioroute` tag, so the word rides in a `call` line). Written at every `AVAudioSession` route change during a 1:1 call, and once at the first heartbeat of the call (`why=99`). At most 40 lines per call; the change count keeps counting after that.

| field | unit | meaning |
|---|---|---|
| `why` | code | raw `AVAudioSession.RouteChangeReason`: 1 new device, 2 old device gone, 3 category change, 4 override, 6 wake from sleep, 7 no suitable route, 8 configuration change; 99 = the sample at the first heartbeat (not an Apple code) |
| `old` | code | output the route left (same codes as `out`); absent when there is no previous route |
| `out` | code | output now: 1 earpiece, 2 loudspeaker, 3 Bluetooth, 4 wired, 5 car, 9 other, 0 none |
| `in` | code | input now: 1 built-in microphone, 3 Bluetooth, 4 wired headset microphone, 5 car, 9 other, 0 none |
| `profile` | code | Bluetooth profile: 1 HFP (hands-free, an 8 or 16 kHz mono voice link), 2 A2DP (stereo music profile, output only, the microphone stays the built-in one), 3 LE Audio, 0 not Bluetooth. HFP wins when the input is HFP. |
| `sr` | Hz | the session's actual hardware sample rate. 16000 or 8000 on `profile=1` is a real band limit of the link. |
| `out_ch`, `in_ch` | channels | channel count of the output and the input |
| `vol` | 0..100 | output volume |

Fields that cannot be read are omitted. Examples:

    audioroute why=1 old=1 out=3 in=3 profile=1 sr=16000 out_ch=1 in_ch=1 vol=50
    audioroute why=99 out=1 in=1 profile=0 sr=48000 out_ch=1 in_ch=1 vol=100

## `call.audio.diag` telemetry record

### Why it was missing on a native call, and what changed

The record was written by `teardownAudioStack` only when the app's own audio engine had been started or had counted frames, and its fields come from that engine's capture and pipeline objects. On a native-SRTP call WebRTC's own audio unit carries the audio and the app's engine never starts (the start path returns at the native gate before it marks an attempt), and the sealed-audio frame counters stay at zero, so the entry condition did not hold and nothing was written. (Inside the block the fields additionally need the engine's capture and pipeline objects, which a native call does not drive.) This was found by reading the code, not by examining a call.

Now a call that was seen on native SRTP always writes the record: once about 15 s into the call (`diag_final=false`, so a call that never reaches a clean teardown still leaves one) and once at the end (`diag_final=true`). If the native call also ran the legacy engine through the ICE-loss fallback, the legacy record is written (one record per call) and the native-only keys are merged into it, except every `echo_*` key and `echo_frame_ms`: the legacy buckets count 20 ms frames and win, so the unit of the record stays unambiguous. The mid-call record is taken only once the call is seen on native SRTP, so a long ring does not use it up. A call that was never native keeps the previous behaviour; its legacy record now also carries `diag_final=true`.

### Fields written on a native call

Names that already exist in the legacy record keep their name and unit, so existing readers of the echo and route fields work on both. A key is omitted when it was not measured.

| field | unit | meaning |
|---|---|---|
| `diag_final` | bool | false for the mid-call record, true for the end-of-call record |
| `diag_native` | bool | true: this record is from the native-SRTP path |
| `hb_n` | count | heartbeats counted in the call |
| `echo_active_frames`, `echo_idle_frames` | frames | whole-call totals of the echo buckets above (one frame = 10 ms here; the legacy record counts 20 ms frames) |
| `echo_frame_ms` | ms | the frame length for the two fields above (10) |
| `echo_active_rms_pct`, `echo_idle_rms_pct` | percent of full scale | RMS of each bucket over the whole call, one decimal; absent when the bucket is empty |
| `echo_far_frames` | frames | render callbacks seen over the call |
| `echo_eval_win`, `echo_suspect_win` | windows | heartbeat windows that were large enough to judge, and how many of them were flagged `echo_suspect` |
| `vpio_cfg` | bool | WebRTC's voice-processing unit configured on and enabled. Configured, not proven (see `vpio` above). The legacy names `vpio_ever_active` and `vpio_bypassed_ever` are not written on the native path on purpose: their value is unknown there and a false would read as "bypassed". |
| `rtt_max_ms`, `jitter_max_ms`, `remote_rtt_max_ms` | ms | call-wide maxima of the per-interval extremes |
| `lost_max` | packets | call-wide maximum of `lost_max` |
| `plc_max` | samples | call-wide maximum of `plc_max` |
| `route_changes` | count | route-change notifications during the call |
| `speaker_route_ever`, `bt_route_ever`, `bt_hfp_ever`, `bt_a2dp_ever` | bool | the route was ever the loudspeaker, any Bluetooth, hands-free, A2DP |
| `granted_sr`, `min_sr` | Hz | last and lowest session sample rate seen (sampled every heartbeat and at every route change) |
| `output_route`, `input_route` | text | last output and input port names |

## Where the numbers come from

Everything is read from values the app already had: the 1 Hz stats poll that feeds the in-call readout (`sampleWireThroughput`), the heartbeat that emits hb=1 and hb=2, the `AVAudioSession` route-change notification the app already observes, and the two WebRTC audio-processing hooks that already ran on every native call (they now also measure the RMS of each 10 ms frame, a single pass without allocation, never blocking the audio thread). No new timer, no new network request, no new permission.
