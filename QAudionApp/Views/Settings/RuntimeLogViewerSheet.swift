import SwiftUI

/// W415 — modal viewer for the in-memory runtime log buffer.
/// Reads `RuntimeLogSink.shared` and renders the most recent N
/// entries with monospaced styling + level badges. Reverse-chrono
/// (newest first) so the user sees what just happened.
struct RuntimeLogViewerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var sink = RuntimeLogSink.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    let entries = sink.snapshotEntries.reversed()
                    ForEach(Array(entries.enumerated()), id: \.element.id) { _, e in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .top, spacing: 6) {
                                Text(e.level.symbol).font(.system(size: 10))
                                Text("[\(e.tag)]")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text(formatTime(e.timestamp))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            Text(e.message)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .foregroundStyle(.primary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        Divider().opacity(0.3)
                    }
                    if entries.isEmpty {
                        Text("Buffer vuoto. Le righe RTLog appariranno qui in tempo reale.")
                            .qaudionStyle(QAudionTypography.standard.bodySmall)
                            .foregroundStyle(.secondary)
                            .padding(20)
                    }
                }
                .padding(.vertical, 8)
            }
            .navigationTitle("Log runtime — \(sink.entryCount)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Chiudi") { dismiss() }
                }
            }
        }
    }

    // ⚡ Bolt: Cache DateFormatter to avoid expensive allocations during scroll/render.
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private func formatTime(_ d: Date) -> String {
        return Self.timeFormatter.string(from: d)
    }
}
