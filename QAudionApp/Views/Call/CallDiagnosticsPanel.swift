import SwiftUI
import QAudionEngine

/// Live readings of the call that more than one call screen needs.
enum CallLiveStats {

    /// Opus bitrate ACTUALLY applied to this call, in kbps; 0 until the encoder has really been reconfigured.
    ///
    /// Gated on a sealed TX frame or outbound RTP bytes having happened, because that is the first instant the
    /// reconfigure is guaranteed to have run: reporting the tuned rate before that would be a guess. The profile
    /// clamp is the engine's own (`QAudionEngine.reconfigureAudioCodec`), reproduced because the engine keeps the
    /// result private. See the audio call screen's CODEC column, which reads this too.
    @MainActor
    static func appliedAudioCodecKbps(_ appState: AppState) -> Int {
        let sealedFrames = appState.callService.framesEncryptedTx > 0
        let rtpSent = (appState.callService.getAudioRtpBytesSent?() ?? -1) > 0
        guard sealedFrames || rtpSent,
              let profile = appState.callService.callIntegration?.activeAudioProfile
        else { return 0 }
        return profile.clamp(kbps: min(max(AudioCodecPrefs.bitrateKbps, 8), 40))
    }

    /// The ML-KEM session key of this call, or nil while the call only holds the transitional key it starts with.
    @MainActor
    static func mlKemSessionKey(_ appState: AppState) -> Data? {
        CallSessionKeyShown.realKey(appState.callPqcSessionKey, source: appState.callSasKeySource)
    }
}

extension CallDiagnosticsInput {

    /// The readings of the call in progress. Everything comes from the same sources the rest of the call UI reads
    /// (the PeerConnection report, the audio RTP counters, the app's own wire counters); what a source does not have
    /// stays at its "not measured" value, which the model shows as a dash.
    @MainActor
    static func live(_ appState: AppState) -> CallDiagnosticsInput {
        let call = appState.callService
        let stats = call.getNativeAudioSrtpStats?()
        var input = CallDiagnosticsInput()

        switch appState.backendType {
        case "p2p": input.path = .p2p
        case "turn": input.path = .turn
        case "relay": input.path = .wsRelay
        default: input.path = .disconnected
        }
        input.videoOn = appState.isVideoCall

        input.audioCodecMime = stats?.codecMimeType
        input.audioCodecKbps = CallLiveStats.appliedAudioCodecKbps(appState)
        input.videoCodecLabel = appState.videoCodecLabel
        input.srtpCipher = stats?.transportSrtpCipher

        input.iceState = stats?.iceConnectionState
        input.localCandidateType = stats?.localCandidateType
        input.localCandidateProtocol = stats?.localCandidateProtocol
        input.localCandidateRelayProtocol = stats?.localCandidateRelayProtocol
        input.remoteCandidateType = stats?.remoteCandidateType
        input.remoteCandidateProtocol = stats?.remoteCandidateProtocol
        input.rttMs = call.mediaRttMs
        input.jitterBufferDelaySec = stats?.inboundJitterBufferDelaySec ?? -1
        input.jitterBufferEmittedCount = stats?.inboundJitterBufferEmittedCount ?? -1
        input.relayNodeUrl = stats?.localRelayCandidateUrl
        input.availableOutgoingBps = stats?.pairAvailableOutgoingBitrate ?? -1
        input.availableIncomingBps = stats?.pairAvailableIncomingBitrate ?? -1
        input.transportBytesSent = stats?.transportBytesSent ?? -1
        input.transportBytesReceived = stats?.transportBytesReceived ?? -1

        input.packetsSent = call.getAudioRtpPacketsSent?() ?? -1
        input.packetsReceived = call.getAudioRtpPacketsReceived?() ?? -1
        input.packetsLost = call.getAudioRtpPacketsLost?() ?? -1
        input.jitterSec = call.getAudioRtpJitterSec?() ?? -1
        input.nackCount = stats?.inboundNackCount ?? -1

        input.videoPipelineState = VideoPipelineState.resolve(
            pipelineRunning: appState.videoPipeline != nil,
            stalled: appState.isVideoStallLatched,
            overWsRelay: appState.videoPipeline != nil && !appState.isVideoSendCarriedByWebRtc).text
        if let key = CallLiveStats.mlKemSessionKey(appState) {
            input.mlKemFingerprint = LiveInCallScreen.sessionFingerprintFromKey(key)
        }

        input.wsFramesSent = call.effectiveAudioTxCount
        input.wsFramesReceived = call.effectiveAudioRxCount
        input.wsBytesSent = call.wireBytesSent
        input.wsBytesReceived = call.wireBytesReceived
        return input
    }
}

extension VideoPipelineState {
    /// The value shown in the "Pipeline video" row.
    var text: String {
        switch self {
        case .active:
            return String(localized: "video.diag.pipeline_active", defaultValue: "attiva",
                          comment: "Value in the call diagnostics panel: the video pipeline is running.")
        case .stalled:
            return String(localized: "video.diag.pipeline_stalled", defaultValue: "bloccata",
                          comment: "Value in the call diagnostics panel: the video pipeline is running but frames are stuck.")
        case .relay:
            return String(localized: "video.diag.pipeline_relay", defaultValue: "relay (WS)",
                          comment: "Value in the call diagnostics panel: the video goes through the server relay over WebSocket.")
        case .idle:
            return String(localized: "video.diag.pipeline_inactive", defaultValue: "inattiva",
                          comment: "Value in the call diagnostics panel: the video pipeline is not running.")
        }
    }
}

extension CallDiagnosticsModel.Field {

    /// Italian label (the source language of the catalog), looked up per field.
    var label: String {
        switch self {
        case .audioCodec:
            return String(localized: "call.diag.field.audioCodec", defaultValue: "Codec audio",
                          comment: "Call diagnostics panel — row label: audio codec")
        case .videoCodec:
            return String(localized: "call.diag.field.videoCodec", defaultValue: "Codec video",
                          comment: "Call diagnostics panel — row label: video codec")
        case .cipher:
            return String(localized: "call.diag.field.cipher", defaultValue: "Cifra",
                          comment: "Call diagnostics panel — row label: media encryption cipher")
        case .iceState:
            return String(localized: "call.diag.field.iceState", defaultValue: "Stato ICE",
                          comment: "Call diagnostics panel — row label: ICE connection state")
        case .pair:
            return String(localized: "call.diag.field.pair", defaultValue: "Coppia",
                          comment: "Call diagnostics panel — row label: the selected ICE candidate pair (types and protocol)")
        case .localCandidate:
            return String(localized: "call.diag.field.localCandidate", defaultValue: "Candidato locale",
                          comment: "Call diagnostics panel — row label: local ICE candidate")
        case .remoteCandidate:
            return String(localized: "call.diag.field.remoteCandidate", defaultValue: "Candidato remoto",
                          comment: "Call diagnostics panel — row label: remote ICE candidate")
        case .rtt:
            return String(localized: "call.diag.field.rtt", defaultValue: "RTT",
                          comment: "Call diagnostics panel — row label: round-trip time on the selected pair")
        case .jitterBufferAverage:
            return String(localized: "call.diag.field.jitterBufferAverage", defaultValue: "Jitter buffer medio",
                          comment: "Call diagnostics panel — row label: average delay of the audio playout buffer")
        case .relayNode:
            return String(localized: "call.diag.field.relayNode", defaultValue: "Nodo relay",
                          comment: "Call diagnostics panel — row label: the TURN node the call goes through")
        case .bandwidth:
            return String(localized: "call.diag.field.bandwidth", defaultValue: "Banda in uscita / in entrata",
                          comment: "Call diagnostics panel — row label: estimated available bandwidth, outgoing then incoming")
        case .bytes:
            return String(localized: "call.diag.field.bytes", defaultValue: "Byte inviati / ricevuti",
                          comment: "Call diagnostics panel — row label: bytes sent then received")
        case .loss:
            return String(localized: "call.diag.field.loss", defaultValue: "Perdita",
                          comment: "Call diagnostics panel — row label: share of audio packets lost")
        case .jitter:
            return String(localized: "call.diag.field.jitter", defaultValue: "Jitter",
                          comment: "Call diagnostics panel — row label: audio jitter")
        case .packets:
            return String(localized: "call.diag.field.packets", defaultValue: "Pacchetti inviati / ricevuti",
                          comment: "Call diagnostics panel — row label: audio packets sent then received")
        case .nack:
            return String(localized: "call.diag.field.nack", defaultValue: "NACK",
                          comment: "Call diagnostics panel — row label: retransmission requests (negative acknowledgements)")
        case .videoPipeline:
            return String(localized: "call.diag.field.videoPipeline", defaultValue: "Pipeline video",
                          comment: "Call diagnostics panel — row label: state of the video pipeline")
        case .mlKemSession:
            return String(localized: "call.diag.field.mlKemSession", defaultValue: "Sessione ML-KEM",
                          comment: "Call diagnostics panel — row label: fingerprint of the ML-KEM session key")
        case .path:
            return String(localized: "call.diag.field.path", defaultValue: "Percorso",
                          comment: "Call diagnostics panel — row label: the path the audio takes (WS relay)")
        case .format:
            return String(localized: "call.diag.field.format", defaultValue: "Formato",
                          comment: "Call diagnostics panel — row label: wire format of the audio relay")
        case .frames:
            return String(localized: "call.diag.field.frames", defaultValue: "Frame inviati / ricevuti",
                          comment: "Call diagnostics panel — row label: audio frames sent then received")
        case .lastSend:
            return String(localized: "call.diag.field.lastSend", defaultValue: "Ultimo invio",
                          comment: "Call diagnostics panel — row label: how long ago the last frame was sent")
        case .lastReceive:
            return String(localized: "call.diag.field.lastReceive", defaultValue: "Ultima ricezione",
                          comment: "Call diagnostics panel — row label: how long ago the last frame was received")
        case .discardedRefused:
            return String(localized: "call.diag.field.discardedRefused", defaultValue: "Scartati / rifiutati",
                          comment: "Call diagnostics panel — row label: frames the socket discarded, then packets it refused")
        }
    }
}

extension CallDiagnosticsModel.Subtitle {
    var text: String {
        switch self {
        case .p2p:
            return String(localized: "call.diag.subtitle.p2p", defaultValue: "Rete P2P",
                          comment: "Call diagnostics panel — subtitle: the call is connected peer to peer")
        case .turn:
            return String(localized: "call.diag.subtitle.turn", defaultValue: "Rete TURN",
                          comment: "Call diagnostics panel — subtitle: the call goes through a TURN relay")
        case .wsRelay:
            return String(localized: "call.diag.subtitle.wsRelay", defaultValue: "Relay audio (WS)",
                          comment: "Call diagnostics panel — subtitle: the audio goes through the server relay over WebSocket")
        case .waiting:
            return String(localized: "call.diag.subtitle.waiting", defaultValue: "In attesa di connessione…",
                          comment: "Call diagnostics panel — subtitle: the call is not connected yet")
        }
    }
}

/// The in-call diagnostics panel, ONE view for the audio and the video call screen. It reads the live call
/// itself, once a second, and draws the rows `CallDiagnosticsModel` decides on. `extra` is an optional block under
/// the rows (the video call screen keeps its collapsed technical-data block there).
struct CallDiagnosticsPanel<Extra: View>: View {
    @EnvironmentObject private var appState: AppState

    let onClose: () -> Void
    private let extra: Extra

    init(onClose: @escaping () -> Void, @ViewBuilder extra: () -> Extra) {
        self.onClose = onClose
        self.extra = extra()
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            panel(CallDiagnosticsModel.make(CallDiagnosticsInput.live(appState)))
        }
    }

    private func panel(_ model: CallDiagnosticsModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(model)
            if !model.rows.isEmpty {
                Divider().background(Color.white.opacity(0.2))
                // Landscape or a small screen: the rows scroll instead of running under the dock.
                ViewThatFits(in: .vertical) {
                    rowsView(model)
                    ScrollView { rowsView(model) }
                }
            }
            extra
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.88)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.35), lineWidth: 1))
    }

    private func header(_ model: CallDiagnosticsModel) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.green)
                Text(String(localized: "call.diag.title", defaultValue: "DIAGNOSTICA",
                            comment: "Call diagnostics panel — title (capitals)"))
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundColor(.green)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.gray)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Chiudi")
            }
            Text(model.subtitle.text)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.gray)
        }
    }

    private func rowsView(_ model: CallDiagnosticsModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(model.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    Text(row.field.label)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(.gray)
                        .frame(width: 150, alignment: .leading)
                    Text(row.value)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

extension CallDiagnosticsPanel where Extra == EmptyView {
    init(onClose: @escaping () -> Void) {
        self.init(onClose: onClose) { EmptyView() }
    }
}
