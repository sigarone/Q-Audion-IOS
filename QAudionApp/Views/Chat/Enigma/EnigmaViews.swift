import SwiftUI
import QAudionEngine

// Enigma mode (visual effect only): the views. A bubble asks the host two questions about its own row, "is a scene running
// for me?" and "am I held back for at most 500 ms?", and otherwise draws exactly what it always drew.

/// The body of a text bubble (or the name line of a file card): the normal content, unless this row is the one being
/// animated, in which case the scene is drawn instead.
///
/// With the effect off the host never publishes a change, so this view is never invalidated by it and its body is the
/// normal content.
///
/// Accessibility: the scene is one element whose label is the FINAL text. VoiceOver never reads the scrambled frames.
struct EnigmaAwareBody<Normal: View>: View {
    @ObservedObject private var host: EnigmaHost = EnigmaHost.shared

    let rowId: String
    let fallback: String
    let lineLimit: Int?
    private let normal: Normal

    init(rowId: String, fallback: String, lineLimit: Int? = nil, @ViewBuilder normal: () -> Normal) {
        self.rowId = rowId
        self.fallback = fallback
        self.lineLimit = lineLimit
        self.normal = normal()
    }

    var body: some View {
        if host.activeId == rowId {
            EnigmaSceneView(frame: host.frame, fallback: fallback, lineLimit: lineLimit)
        } else if host.isHeldBack(rowId) {
            // Same size as the text that is about to appear, invisible for at most 500 ms (the host releases it).
            normal.opacity(0)
        } else {
            normal
        }
    }
}

/// One scene: the frame string, the true label, and (full level) the drums, their caption and the progress bar. Only this
/// view observes the frame model.
struct EnigmaSceneView: View {
    @ObservedObject var frame: EnigmaFrameModel
    let fallback: String
    let lineLimit: Int?

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type
    @Environment(\.qaudionExtras) private var extras

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            bodyText
            labelText
            if frame.full {
                fullExtras
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: fallback))
    }

    private var shownText: String {
        frame.text.isEmpty ? fallback : frame.text
    }

    private var bodyText: some View {
        Text(verbatim: shownText)
            .qaudionStyle(type.bodyMedium)
            .foregroundStyle(scheme.onSurface)
            .lineLimit(lineLimit)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var labelLine: String {
        let percent: Int = EnigmaUpload.percent(frame.progress)
        return EnigmaLabels.line(
            kind: frame.labelKind,
            packetBytes: frame.packetBytes,
            percent: percent,
            verifiedFormat: EnigmaStrings.verified,
            sealedFormat: EnigmaStrings.sealed
        )
    }

    private var labelText: some View {
        Text(verbatim: labelLine)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(scheme.onSurfaceVariant)
            .lineLimit(2)
    }

    @ViewBuilder
    private var fullExtras: some View {
        EnigmaRotorPanel(index: frame.rotorIndex, accent: extras.pqcAccent)
        Text(verbatim: EnigmaStrings.rotorsCaption)
            .qaudionStyle(type.labelSmall)
            .foregroundStyle(scheme.onSurfaceVariant)
        EnigmaProgressBar(fraction: frame.progress, accent: extras.pqcAccent)
    }
}

/// The 2 pt bar under the drums. Drawn as two capsules: no layout work per frame beyond one width.
struct EnigmaProgressBar: View {
    let fraction: Double
    let accent: Color

    var body: some View {
        let clamped: Double = fraction.isNaN ? 0 : min(1, max(0, fraction))
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(accent.opacity(0.2))
                Capsule()
                    .fill(accent)
                    .frame(width: geo.size.width * CGFloat(clamped))
            }
        }
        .frame(height: 2)
    }
}

/// The panel of an outgoing file while it uploads (full level only): the drums turned by the REAL progress of the upload, the
/// true label of what is being sent and the caption that the drums are graphics. It never reads the file or its name, and it
/// only ever goes forward. Hidden from accessibility (the bubble already says it is being sent).
struct EnigmaUploadPanel: View {
    @ObservedObject private var host: EnigmaHost = EnigmaHost.shared

    let rowId: String
    /// The real fraction of the upload (`ChatContainer.uploadProgress`), nil when the row is not uploading.
    let fraction: Double?

    @State private var peak: Double = 0

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type
    @Environment(\.qaudionExtras) private var extras

    var body: some View {
        if let value = fraction, host.activeId != rowId, host.allowsUploadPanel(rowId: rowId) {
            panel(for: value)
        }
    }

    private func panel(for value: Double) -> some View {
        let shown: Double = EnigmaUpload.monotonic(previous: peak, next: value)
        let target: Double = EnigmaUpload.rotorIndex(shown)
        let line: String = EnigmaStrings.fileLine(percent: EnigmaUpload.percent(shown))
        return VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: line)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(scheme.onSurfaceVariant)
            EnigmaRotorPanel(index: target, accent: extras.pqcAccent)
                .animation(.linear(duration: 0.45), value: target)
            Text(verbatim: EnigmaStrings.rotorsCaption)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
        }
        .padding(.top, 4)
        .accessibilityHidden(true)
        .onChange(of: shown) { newValue in
            if newValue > peak { peak = newValue }
        }
    }
}

/// The discreet line shown once after the governor lowered the effect.
struct EnigmaDegradeNotice: View {
    @ObservedObject private var host: EnigmaHost = EnigmaHost.shared
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type

    var body: some View {
        if host.showNotice {
            Text(verbatim: EnigmaStrings.degraded)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .allowsHitTesting(false)
        }
    }
}

/// Connects a chat screen to the effect: attaches on appear, detaches on disappear, tells the host when the list changed.
struct EnigmaChatBinding: ViewModifier {
    let conversationKey: String
    let changeToken: Int
    let rows: () -> [EnigmaRow]

    func body(content: Content) -> some View {
        content
            .onAppear(perform: attach)
            .onDisappear(perform: detach)
            .onChange(of: changeToken) { _ in
                EnigmaHost.shared.rowsChanged(flagOn: EnigmaFeature.flagOn)
            }
            .overlay(alignment: .top) {
                EnigmaDegradeNotice()
            }
    }

    private func attach() {
        EnigmaHost.shared.attach(flagOn: EnigmaFeature.flagOn, conversationKey: conversationKey, rows: rows)
    }

    private func detach() {
        EnigmaHost.shared.detach(flagOn: EnigmaFeature.flagOn)
    }
}

extension View {
    func enigmaChatBinding(conversationKey: String, changeToken: Int, rows: @escaping () -> [EnigmaRow]) -> some View {
        modifier(EnigmaChatBinding(conversationKey: conversationKey, changeToken: changeToken, rows: rows))
    }
}
