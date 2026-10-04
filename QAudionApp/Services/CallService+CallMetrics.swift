import Foundation
import AVFoundation
import QAudionEngine

/// CALL-METRICS (2026-10-04) -- the call-monitoring instrumentation of `CallService`: per-second extremes, the route
/// line, the echo / VP-IO heartbeat line and the native-path `call.audio.diag`. Telemetry only: nothing here changes
/// what the audio path does. The arithmetic, the numeric lines and the attribute set are pure and unit-tested in
/// QAudionEngine (`CallMetricsTests`, `NativeEchoProxyTests`); this file only reads the live values and hands them over.
/// Field names, units and example lines: docs/TELEMETRY_CALL_METRICS.md.
///
/// CLAUDE.md traps respected: no AppState parameter (§16), every string built into a `let` before the call (§13),
/// ASCII only.
extension CallService {

    /// One 1 s sample for the per-interval extremes. Called by `sampleWireThroughput` while a call id exists.
    func noteCallMetricsSample(rttMs: Double?) {
        let native: Bool = getUsesNativeAudioSrtp?() == true
        let jitterSec: Double = getAudioRtpJitterSec?() ?? -1
        let lost: Int64 = getAudioRtpPacketsLost?() ?? -1
        var concealed: Int64 = -1
        var remoteRttSec: Double = -1
        if native, let stats = getNativeAudioSrtpStats?() {
            concealed = stats.inboundConcealedSamples
            remoteRttSec = stats.remoteInboundRoundTripTimeSec
        }
        let firstSample: Bool = callMetrics.noteSample(rttMs: rttMs, jitterSec: jitterSec, remoteRttSec: remoteRttSec,
                               lostCumulative: lost, concealedCumulative: concealed, native: native)
        // The echo probe is process-wide and the render hook also runs during group calls: start every call from zero.
        if firstSample { NativeEchoProbe.shared.resetForNewCall() }
    }

    /// The route right now: ledger update, and (for a change or the first heartbeat) the `audioroute` line.
    /// `reason` is the raw `AVAudioSession.RouteChangeReason`, or `CallRouteDiagnostics.reasonCallStart` for the sample
    /// taken at the first heartbeat. Tag "call": the log shipper's tag allow-list is deny-by-default and has no
    /// "audioroute" tag, so the line family word `audioroute` rides in the body of a "call" line.
    func noteAudioRoute(reason: Int, previousPortType: String?, isChange: Bool, force: Bool) {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        let outputPort: String? = route.outputs.first?.portType.rawValue
        let inputPort: String? = route.inputs.first?.portType.rawValue
        let sampleRate: Double = session.sampleRate
        let shouldLog: Bool = callMetrics.noteRoute(outputPort: outputPort, inputPort: inputPort,
                                                    sampleRateHz: sampleRate, isChange: isChange, force: force)
        guard shouldLog else { return }
        let line: String = CallRouteDiagnostics.routeLine(
            reason: reason, previousOutputPort: previousPortType, outputPort: outputPort, inputPort: inputPort,
            sampleRateHz: sampleRate, outputChannels: session.outputNumberOfChannels,
            inputChannels: session.inputNumberOfChannels, volume: session.outputVolume)
        RTLog.info("call", line)
    }

    /// An `AVAudioSession.routeChangeNotification` during a 1:1 call (AppState forwards plain values, §16).
    /// Group calls log their own `grp route` lines.
    func noteAudioRouteChange(reason: Int, previousPortType: String?) {
        guard getCallId?() != nil, isGroupCallActive?() != true else { return }
        noteAudioRoute(reason: reason, previousPortType: previousPortType, isChange: true, force: false)
    }

    /// Everything that rides on the 5 s heartbeat besides hb=1 / hb=2: the route sample (the first one is logged), the
    /// `audiosrtp hb=3` echo / VP-IO line, and the one mid-call `call.audio.diag`.
    func emitCallMetricsAtHeartbeat(heartbeat: Int) {
        let first: Bool = heartbeat == 1
        noteAudioRoute(reason: CallRouteDiagnostics.reasonCallStart, previousPortType: nil, isChange: false, force: first)
        let state = callMetricsEngineState()
        var window: NativeEchoProxy.WindowReport?
        if state.engine == 1 {
            window = NativeEchoProbe.shared.closeWindow()
        }
        let line: String = CallMetricsLines.hb3(engine: state.engine, vpio: state.vpio, duck: state.duck, echo: window)
        RTLog.info("call", line)
        if callMetrics.takeMidCallDiagSlot() {
            emitNativeAudioDiag(final: false)
        }
    }

    /// The `call.audio.diag` attributes of a call that ran on native SRTP, where the app's own audio engine (the source
    /// of the legacy diag) never starts. nil for a call that was never on native SRTP.
    func nativeAudioDiagAttrs(final: Bool) -> [String: Any]? {
        guard callMetrics.sawNativeCall else { return nil }
        let snapshot = callMetrics.snapshot()
        let echo: NativeEchoProxy.CallReport = NativeEchoProbe.shared.callReport()
        let state = callMetricsEngineState()
        let attrs: [String: Any] = NativeCallAudioDiag.attrs(
            final: final, heartbeats: snapshot.heartbeats, echo: echo, callMax: snapshot.callMax,
            route: snapshot.route, vpioConfigured: state.vpio)
        return attrs
    }

    /// Emits that diag: once mid-call (`final` false, 15 s in, so a call that never reaches a clean teardown still leaves
    /// a record) and at the end of the call (`final` true). Does nothing for a call that was never on native SRTP.
    func emitNativeAudioDiag(final: Bool) {
        guard let attrs = nativeAudioDiagAttrs(final: final) else { return }
        let callId: String? = getCallId?()
        Task { @MainActor in
            TelemetryService.shared.emit(kind: "call.audio.diag", callId: callId, attrs: attrs)
        }
    }

    /// The native extras for a legacy diag that is being emitted anyway (a native call whose ICE-loss fallback ran the
    /// legacy engine): one record per call, the legacy names win where both exist, the native-only keys are added.
    func mergeNativeAudioDiag(into attrs: inout [String: Any]) {
        guard let extras = nativeAudioDiagAttrs(final: true) else { return }
        // The legacy echo buckets count 20 ms frames, the native ones 10 ms: when the legacy record has its buckets, none of the
        // native echo_* keys (nor echo_frame_ms) is added, so the unit of the merged record stays unambiguous.
        let legacyHasEcho: Bool = attrs["echo_active_frames"] != nil
        for (key, value) in extras where attrs[key] == nil {
            if legacyHasEcho && key.hasPrefix("echo_") { continue }
            attrs[key] = value
        }
    }

    /// Called from `teardownAudioStack` at the end of a call (or the defensive teardown of a new one: nothing to
    /// report then, the state was reset) and BEFORE the per-call state is reset.
    func finishCallMetrics(legacyDiagEmitted: Bool) {
        if !legacyDiagEmitted {
            emitNativeAudioDiag(final: true)
        }
        callMetrics.reset()
        NativeEchoProbe.shared.resetForNewCall()
    }
}
