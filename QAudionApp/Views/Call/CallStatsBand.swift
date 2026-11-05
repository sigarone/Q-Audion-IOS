import SwiftUI

/// Value formats of the call stats band (DURATA / CODEC / FLUSSO / RITARDO and the video row). An unmeasured value is
/// always the dash: an absent value is information, a stale or synthesised one is a lie the user cannot detect.
enum CallStatsFormat {

    static let dash = "—"

    /// "3:07".
    static func duration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Applied coding level "32 kbps", or the dash when it is not known.
    static func codec(kbps: Int) -> String {
        guard kbps > 0 else { return dash }
        return String(kbps) + " kbps"
    }

    /// Live wire rate as "tx/rx" whole kbps, e.g. "45/43". Either side may be a dash on its own; both absent give a
    /// single dash. The unit lives in the column label.
    static func flow(tx: Double?, rx: Double?) -> String {
        guard tx != nil || rx != nil else { return dash }
        let txText = tx.map { String(format: "%.0f", $0) } ?? dash
        let rxText = rx.map { String(format: "%.0f", $0) } ?? dash
        return txText + "/" + rxText
    }

    /// Round trip "128ms", or "128+40ms" once the jitter-buffer delay is 10 ms or more, or the dash.
    static func delay(rttMs: Double?, bufMs: Int?) -> String {
        guard let rttMs else { return dash }
        if let bufMs, bufMs >= 10 {
            return String(format: "%.0f+%dms", rttMs, bufMs)
        }
        return String(format: "%.0fms", rttMs)
    }

    /// The video cells are dashes while no video lane is on, which keeps the two rows aligned.
    static func videoFlow(videoOn: Bool, tx: Double?, rx: Double?) -> String {
        videoOn ? flow(tx: tx, rx: rx) : dash
    }
}

/// The always-available stats band of the video call screen: the same two-row box as Android's, DURATA / CODEC /
/// FLUSSO kbps / RITARDO on the first row and the video cells under CODEC and FLUSSO on the second. Refreshed every
/// second from the live call.
struct CallStatsBand: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            content
        }
    }

    private var content: some View {
        let call = appState.callService
        let codecKbps = CallLiveStats.appliedAudioCodecKbps(appState)
        let rtt = call.mediaRttMs
        let buf = call.mediaJitterBufferMs
        let videoOn = appState.isVideoCall
        let codecColor = Self.codecColor(kbps: codecKbps, scheme: scheme, extras: extras)
        return VStack(spacing: 4) {
            HStack(alignment: .center, spacing: 0) {
                cell("DURATA", CallStatsFormat.duration(Int(call.callDurationSeconds)), extras.success)
                cell("CODEC", CallStatsFormat.codec(kbps: codecKbps), codecColor)
                cell("FLUSSO kbps", CallStatsFormat.flow(tx: call.wireTxKbps, rx: call.wireRxKbps), scheme.onSurface)
                cell("RITARDO", CallStatsFormat.delay(rttMs: rtt, bufMs: buf), delayColor(rtt: rtt, buf: buf))
            }
            HStack(alignment: .center, spacing: 0) {
                Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                // The video encode rate is not published by the encoder on iOS: the cell stays a dash.
                cell("VIDEO", CallStatsFormat.dash, scheme.onSurfaceVariant)
                cell("FLUSSO VIDEO",
                     CallStatsFormat.videoFlow(videoOn: videoOn, tx: call.videoTxKbps, rx: call.videoRxKbps),
                     videoOn ? scheme.onSurface : scheme.onSurfaceVariant)
                Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 4).fill(scheme.surface.opacity(0.75)))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(scheme.outline.opacity(0.5), lineWidth: 1))
    }

    /// Warning for the 1...16 kbps constrained profile, success otherwise, neutral while unknown.
    private static func codecColor(kbps: Int, scheme: QAudionColorScheme, extras: QAudionColorsExtra) -> Color {
        guard kbps > 0 else { return scheme.onSurfaceVariant }
        return (1...16).contains(kbps) ? extras.warning : extras.success
    }

    /// Android's thresholds: red above 400 ms of RTT plus buffer, warning above 200 ms, neutral when unmeasured.
    private func delayColor(rtt: Double?, buf: Int?) -> Color {
        guard let rtt else { return scheme.onSurfaceVariant }
        let total = rtt + Double(buf ?? 0)
        if total > 400 { return extras.riskHigh }
        if total > 200 { return extras.warning }
        return extras.success
    }

    private func cell(_ label: LocalizedStringKey, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .qaudionScaledFont(size: 8.5, weight: .medium, design: .monospaced, family: .label, maxSize: .xLarge)
                .tracking(1.0)
                .foregroundStyle(scheme.onSurfaceVariant)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(value)
                .qaudionScaledFont(size: 14, weight: .semibold, design: .monospaced, maxSize: .xLarge)
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
    }
}
