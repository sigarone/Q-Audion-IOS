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

    /// W301: visible entries — full list or just the top 5.
    private var visibleEntries: [ReleaseNote] {
        if latestOnly {
            return Array(ReleaseNote.releaseNotes.prefix(5))
        }
        return ReleaseNote.releaseNotes
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
                    Spacer().frame(height: 24)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
        }
        .navigationTitle("Cosa c'è di nuovo")
        .navigationBarTitleDisplayMode(.inline)
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
}

#Preview {
    NavigationStack {
        WhatsNewScreen()
    }
    .qAudionTheme(dark: true)
}
