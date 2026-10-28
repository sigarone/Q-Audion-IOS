import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The Live Activity widget extension: draws the activities the app starts (a live location share, a large file transfer) on the
/// lock screen and in the Dynamic Island. It only shows the state the app hands it; it reads nothing else and has no network.

@main
struct QAudionLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        QAudionActivityWidget()
    }
}

struct QAudionActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: QAudionActivityAttributes.self) { context in
            LockScreenActivityView(attributes: context.attributes, state: context.state)
                .padding(16)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ActivitySymbol(kind: context.attributes.kind)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ActivityTrailing(kind: context.attributes.kind, state: context.state)
                }
                DynamicIslandExpandedRegion(.center) {
                    ActivityTitle(kind: context.attributes.kind, state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ActivityDetail(attributes: context.attributes, state: context.state)
                }
            } compactLeading: {
                ActivitySymbol(kind: context.attributes.kind)
            } compactTrailing: {
                ActivityTrailing(kind: context.attributes.kind, state: context.state)
                    .frame(maxWidth: 52)
            } minimal: {
                ActivitySymbol(kind: context.attributes.kind)
            }
        }
    }
}

// MARK: - Pieces

private struct ActivitySymbol: View {
    let kind: LiveActivityKind

    var body: some View {
        Image(systemName: name)
            .foregroundStyle(.tint)
    }

    private var name: String {
        switch kind {
        case .locationShare: return "location.fill"
        case .fileSend: return "arrow.up.circle.fill"
        case .fileReceive: return "arrow.down.circle.fill"
        }
    }
}

private struct ActivityTitle: View {
    let kind: LiveActivityKind
    let state: LiveActivityContent

    var body: some View {
        switch kind {
        case .locationShare:
            if let name = state.contactName {
                Text("live.location.with \(name)")
                    .font(.headline)
                    .lineLimit(1)
            } else {
                Text("live.location.active")
                    .font(.headline)
                    .lineLimit(1)
            }
        case .fileSend:
            Text("live.file.send")
                .font(.headline)
                .lineLimit(1)
        case .fileReceive:
            Text("live.file.receive")
                .font(.headline)
                .lineLimit(1)
        }
    }
}

/// The system timer of a share, or the percentage of a transfer.
private struct ActivityTrailing: View {
    let kind: LiveActivityKind
    let state: LiveActivityContent

    var body: some View {
        switch kind {
        case .locationShare:
            if let end = state.endDate, end > Date() {
                Text(timerInterval: state.startDate...end, countsDown: true)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
            }
        case .fileSend, .fileReceive:
            Text(state.progress, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
        }
    }
}

/// The end time of a share with its Stop button (iOS 17 and later), or the progress bar of a transfer.
private struct ActivityDetail: View {
    let attributes: QAudionActivityAttributes
    let state: LiveActivityContent

    var body: some View {
        switch attributes.kind {
        case .locationShare:
            HStack {
                if let end = state.endDate {
                    Text("live.location.until \(end, style: .time)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StopButton(shareId: attributes.itemId)
            }
        case .fileSend, .fileReceive:
            ProgressView(value: state.progress)
        }
    }
}

private struct StopButton: View {
    let shareId: String

    var body: some View {
        if #available(iOS 17.0, *) {
            Button(intent: StopLocationShareIntent(shareId: shareId)) {
                Text("live.stop")
            }
            .buttonStyle(.bordered)
        }
    }
}

private struct LockScreenActivityView: View {
    let attributes: QAudionActivityAttributes
    let state: LiveActivityContent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ActivitySymbol(kind: attributes.kind)
                    .font(.title3)
                ActivityTitle(kind: attributes.kind, state: state)
                Spacer()
                ActivityTrailing(kind: attributes.kind, state: state)
                    .font(.headline)
            }
            ActivityDetail(attributes: attributes, state: state)
        }
    }
}
