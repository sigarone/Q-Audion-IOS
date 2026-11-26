import SwiftUI
import QAudionEngine

/// Privacy settings: the switch "Recognise my contacts' voices" and the list of learned voices with "Delete all".
///
/// The switch is there only while the check is available to the account (the entitlement, fail closed). The list with "Delete all"
/// stays reachable whenever any learned voice exists, with or without the entitlement; nothing is deleted automatically when the
/// entitlement is missing. With no entitlement and no learned voice nothing is drawn.
struct ContactVoiceSettingsSection: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type

    struct Entry: Identifiable, Equatable {
        let id: String
        let name: String
        let summary: ContactVoiceSummary
    }

    @State private var ui: ContactVoiceUi = .hidden
    @State private var choice = true
    @State private var hasVoices = false
    @State private var entries: [Entry] = []
    @State private var confirmingDelete = false
    @State private var showingFailure = false

    private var toggle: Binding<Bool> {
        Binding(
            get: { choice },
            set: { newValue in
                choice = newValue
                DispatchQueue.global(qos: .userInitiated).async {
                    let ok = ContactVoiceSettings.shared.setOn(newValue)
                    DispatchQueue.main.async {
                        if !ok && !newValue { showingFailure = true }
                        refresh()
                    }
                }
            }
        )
    }

    var body: some View {
        Group {
            if ui != .hidden {
                content
            }
        }
        .onAppear { refresh() }
        .alert(Text("settings.contact_voice.confirm_title"), isPresented: $confirmingDelete) {
            Button("settings.contact_voice.confirm", role: .destructive) { deleteAll() }
            Button("settings.contact_voice.cancel", role: .cancel) {}
        } message: {
            Text("settings.contact_voice.confirm_body")
        }
        .alert(Text("settings.contact_voice.failed"), isPresented: $showingFailure) {
            Button("OK", role: .cancel) {}
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader("settings.contact_voice.section")
            VStack(spacing: 8) {
                if ui == .full {
                    SettingsToggleRow(
                        title: "settings.contact_voice.title", subtitle: "settings.contact_voice.subtitle", isOn: toggle)
                } else {
                    Text("settings.contact_voice.unavailable")
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .padding(.horizontal, 14)
                }
                voicesList
            }
        }
    }

    private var voicesList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("settings.contact_voice.list_title")
                .qaudionStyle(type.titleSmall)
                .foregroundStyle(scheme.onSurface)
            if entries.isEmpty {
                Text("settings.contact_voice.list_empty")
                    .qaudionStyle(type.bodyMedium)
                    .foregroundStyle(scheme.onSurfaceVariant)
            }
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .qaudionStyle(type.bodyMedium)
                        .foregroundStyle(scheme.onSurface)
                    Text(ContactVoiceRowText.text(summary: entry.summary, ownerOn: true))
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                }
            }
            if hasVoices {
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Text("settings.contact_voice.delete_all")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(scheme.surfaceVariant.opacity(0.4)))
    }

    private func deleteAll() {
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = VoiceCallWiring.deleteAllLearnedVoices()
            DispatchQueue.main.async {
                if !ok { showingFailure = true }
                refresh()
            }
        }
    }

    private func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let setting = ContactVoiceSettings.shared
            let has = VoiceCallWiring.hasLearnedVoices()
            let state = setting.ui(hasRecords: has)
            var found: [Entry] = []
            if has {
                let contacts = ContactsStore().load()
                let summaries = VoiceCallWiring.summaries(contactIds: contacts.map { $0.userId })
                found = contacts.compactMap { c in
                    summaries[c.userId].map { Entry(id: c.userId, name: c.displayName, summary: $0) }
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
            let stored = setting.choice
            DispatchQueue.main.async {
                ui = state
                hasVoices = has
                entries = found
                choice = stored
            }
        }
    }
}
