import SwiftUI
import QAudionEngine

/// "Cosa c'è di nuovo" — elenco delle novità per versione.
/// Lista scritta a mano di release entries (versione + data + punti
/// principali), quindi non serve alcun fetch di rete. Si aggiorna
/// aggiungendo un `ReleaseNote` in `ReleaseNote.releaseNotes`
/// (`WhatsNewData.swift`). Non sostituisce l'OTA catalog (W42), che
/// gestisce release firmate Ed25519; questo è puramente informativo.
public struct ReleaseNote: Identifiable, Equatable {
    public let id: String   // tag, es. "v1.0.96"
    public let date: String // ISO short, es. "2026-04-30"
    public let title: String
    public let bullets: [String]

    public init(id: String, date: String, title: String, bullets: [String]) {
        self.id = id; self.date = date; self.title = title; self.bullets = bullets
    }
}

// W302: extension ReleaseNote { releaseNotes: [...] } moved to
// WhatsNewData.swift to keep this file under the type-checker
// danger zone — see TODO_AUDIT.md §6 + CLAUDE.md §13.

struct WhatsNewScreen: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    /// W310: share-sheet item for the export-as-text action. Set to
    /// non-nil triggers the .sheet to present a UIActivityViewController.
    @State private var sharingText: ChangelogShareItem? = nil

    /// Entries shown in the list and in the exported text.
    private var visibleEntries: [ReleaseNote] {
        ReleaseNote.releaseNotes
    }

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    intro
                    ForEach(visibleEntries) { note in
                        releaseCard(note)
                    }
                    Spacer().frame(height: 24)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
        }
        .navigationTitle("Cosa c'è di nuovo")
        .navigationBarTitleDisplayMode(.inline)
        // W310: trailing toolbar button → export the visible entries
        // as plain text via UIActivityViewController (Mail / Messages /
        // Files / etc.). Useful for testers who want to paste the
        // changelog into an external doc without screenshotting.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    let payload = Self.formatChangelog(visibleEntries)
                    sharingText = ChangelogShareItem(text: payload)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Esporta cambiamenti")
            }
        }
        .sheet(item: $sharingText) { item in
            ChangelogShareSheet(text: item.text)
        }
    }

    /// W310: build a plain-text representation of the changelog.
    /// Each entry: '## v1.0.X — date' header, blank line, '- bullet'
    /// list, blank line. Static so the call-site stays trivial per
    /// CLAUDE.md §13.
    private static func formatChangelog(_ entries: [ReleaseNote]) -> String {
        var lines: [String] = []
        lines.append("Q-Audion iOS — Changelog")
        lines.append("")
        for note in entries {
            lines.append("## " + note.id + " — " + note.date)
            lines.append(note.title)
            lines.append("")
            for bullet in note.bullets {
                lines.append("- " + bullet)
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Intro

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CHANGELOG")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(scheme.primary)
            Text("Novità delle ultime versioni, con i cambiamenti principali di ogni aggiornamento.")
                .qaudionStyle(type.bodySmall)
                .foregroundStyle(scheme.onSurface)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(scheme.surfaceVariant.opacity(0.5))
        )
    }

    // MARK: - Release card

    private func releaseCard(_ note: ReleaseNote) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(note.id)
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundStyle(scheme.onSurface)
                Spacer(minLength: 0)
                Text(note.date)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(scheme.onSurfaceVariant)
            }
            Text(note.title)
                .qaudionStyle(type.titleSmall)
                .fontWeight(.semibold)
                .foregroundStyle(scheme.primary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(note.bullets, id: \.self) { bullet in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                            .foregroundStyle(scheme.primary)
                        Text(bullet)
                            .qaudionStyle(type.bodySmall)
                            .foregroundStyle(scheme.onSurface)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(scheme.surfaceVariant.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(scheme.outline.opacity(0.4), lineWidth: 1)
        )
    }
}

#Preview {
    NavigationStack {
        WhatsNewScreen()
    }
    .qAudionTheme(dark: true)
}

// MARK: - W310 share-sheet helpers

/// W310: identifiable wrapper for the share-sheet payload so the
/// `.sheet(item:)` modifier can present it.
struct ChangelogShareItem: Identifiable {
    let id = UUID()
    let text: String
}

/// W310: thin SwiftUI wrapper around UIActivityViewController so the
/// changelog can be shared via Mail / Messages / Files / etc.
struct ChangelogShareSheet: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text],
                                 applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController,
                                context: Context) {}
}
