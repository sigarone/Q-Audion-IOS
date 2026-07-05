import SwiftUI
import QAudionEngine

/// W49: "Cosa c'è di nuovo" — changelog viewer per i tester TestFlight.
/// Hardcoded list di release entries (tag + data + bullet di feature)
/// così non serve un fetch network e non c'è dipendenza dall'engine.
/// Pensato per essere aggiornato manualmente a ogni tag — l'autore della
/// release deve aggiungere un nuovo `ReleaseNote` in `releaseNotes` qui
/// sotto. Non sostituisce l'OTA catalog (W42), che gestisce release
/// firmate Ed25519; questo è puramente informativo.
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

    /// W301: 'Latest only' toggle. When true, only the top 5 entries
    /// are rendered. Useful when the changelog grows past the user's
    /// patience threshold but they only want to know what's new since
    /// the last build they ran.
    @State private var latestOnly: Bool = false

    /// W310: share-sheet item for the export-as-text action. Set to
    /// non-nil triggers the .sheet to present a UIActivityViewController.
    @State private var sharingText: ChangelogShareItem? = nil

    /// W301: visible entries — full list or just the top 5.
    private var visibleEntries: [ReleaseNote] {
        if latestOnly {
            return Array(ReleaseNote.releaseNotes.prefix(5))
        }
        return ReleaseNote.releaseNotes
    }

    /// Auto-generated per-build changelog (WhatsNewData.generated.swift),
    /// produced by scripts/gen_changelog.py from real git tag/commit
    /// history and regenerated on every release by ios-release.ps1.
    /// Distinct from `releaseNotes` above (hand-curated, per-milestone):
    /// this one is per-tag, unfiltered beyond stripping the mechanical
    /// version-bump commit, newest first, capped to the last 20 tags by
    /// the generator itself. Empty until the first release runs the
    /// generator (e.g. a fresh checkout before any release) — in that
    /// case the "Cronologia versioni" section below renders nothing,
    /// no placeholder, no fabricated example.
    private var generatedEntries: [ReleaseNote] {
        ReleaseNote.generatedReleaseNotes
    }

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    intro
                    // W301: filter toggle row above the list. Compact
                    // styling so it doesn't compete with the intro.
                    HStack(spacing: 8) {
                        Toggle(isOn: $latestOnly) {
                            Text("Solo ultime 5")
                                .qaudionStyle(type.labelSmall)
                                .foregroundStyle(scheme.onSurface)
                        }
                        .toggleStyle(.switch)
                        .tint(scheme.primary)
                    }
                    .padding(.vertical, 4)
                    ForEach(visibleEntries) { note in
                        releaseCard(note)
                    }
                    // Auto-generated per-build history — only rendered
                    // when the generator has actually produced entries
                    // (see `generatedEntries` doc above).
                    if !generatedEntries.isEmpty {
                        versionHistorySection
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
        lines.append("Source: feature/ios-android-parity")
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
            Text("Lista delle ultime release TestFlight con i cambiamenti principali. Aggiornata manualmente a ogni tag — la versione canonica del changelog vive nel repository git su `feature/ios-android-parity`.")
                .qaudionStyle(type.bodySmall)
                .foregroundStyle(scheme.onSurface)
            // W285: surface the count of release entries. Helps testers
            // gauge how many milestones have been delivered without
            // counting cards by hand. Pre-bound count via a static
            // computed property — see CLAUDE.md §13.
            HStack(spacing: 6) {
                Text(Self.releaseCountLabel)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(scheme.onSurfaceVariant)
            }
            .padding(.top, 4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(scheme.surfaceVariant.opacity(0.5))
        )
    }

    /// W285: pre-bound count label. Computed once per screen open from
    /// the `releaseNotes` array (a static let so it's free to read).
    /// String concat to avoid type-checker risk.
    private static var releaseCountLabel: String {
        let n = ReleaseNote.releaseNotes.count
        return String(n) + " entries · feature/ios-android-parity"
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

    // MARK: - Version history (auto-generated, per-build)

    /// "Cronologia versioni" — the auto-generated counterpart to the
    /// hand-curated cards above. One card per git tag (up to the last
    /// 20), each showing version + date + the real commit subjects for
    /// that release, exactly as produced by scripts/gen_changelog.py.
    /// Kept as a visually distinct section (separate header, compact
    /// card style) so testers don't confuse per-tag noise with the
    /// curated per-milestone highlights above.
    private var versionHistorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("CRONOLOGIA VERSIONI")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(scheme.primary)
                Text("Ultime \(generatedEntries.count) versioni, generate automaticamente dalla cronologia git a ogni release.")
                    .qaudionStyle(type.bodySmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
            }
            .padding(.top, 8)
            ForEach(generatedEntries) { note in
                versionHistoryCard(note)
            }
        }
    }

    /// Compact card for a single auto-generated entry. Unlike
    /// `releaseCard`, there's no separate `title` line — generated
    /// entries set `title == id` (see gen_changelog.py), so showing it
    /// twice would be redundant.
    private func versionHistoryCard(_ note: ReleaseNote) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(note.id)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(scheme.onSurface)
                Spacer(minLength: 0)
                Text(note.date)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(scheme.onSurfaceVariant)
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(note.bullets, id: \.self) { bullet in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                            .foregroundStyle(scheme.onSurfaceVariant)
                        Text(bullet)
                            .qaudionStyle(type.labelSmall)
                            .foregroundStyle(scheme.onSurface)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(scheme.surfaceVariant.opacity(0.3))
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
