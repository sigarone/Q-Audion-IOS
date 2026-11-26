import SwiftUI
import QAudionEngine

/// The words of the "Voice recognition" row of the contact screen and of the list of learned voices in Settings: Off, Learning
/// (net speech "35 of 120 s", sessions, days), Partly learned, Learned on <date>, May have changed. The date is the one of the
/// record (`enrolledS`), never a field of the contact database, formatted for the language of the app.
enum ContactVoiceRowText {
    enum Kind: Equatable {
        case off
        case learning
        case partly
        case learned
        case changed
    }

    static func kind(summary: ContactVoiceSummary?, ownerOn: Bool) -> Kind {
        if !ownerOn { return .off }
        switch summary?.kind {
        case nil, .learning?: return .learning // no record yet: learning starts at the next qualifying call
        case .partlyLearned?: return .partly
        case .learned?: return .learned
        case .mayHaveChanged?: return .changed
        }
    }

    /// The date of "Learned on <date>": a pure function so that a test can pin the locale and the time zone.
    static func learnedDate(enrolledS: Int, locale: Locale, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(enrolledS)))
    }

    static func text(summary: ContactVoiceSummary?, ownerOn: Bool,
                     locale: Locale = Locale(identifier: AppLanguageManager.effectiveLanguageCode)) -> String {
        switch kind(summary: summary, ownerOn: ownerOn) {
        case .off:
            return String(localized: "contact_detail.voice_rec.off", defaultValue: "Disattivato",
                          comment: "Contact screen, voice recognition row: the owner setting is off")
        case .partly:
            return String(localized: "contact_detail.voice_rec.partly", defaultValue: "Appresa in parte",
                          comment: "Contact screen, voice recognition row: the voice is partly learned")
        case .changed:
            return String(localized: "contact_detail.voice_rec.changed", defaultValue: "Potrebbe essere cambiata",
                          comment: "Contact screen, voice recognition row: the learned voice may no longer fit")
        case .learned:
            if let s = summary, s.enrolledS > 0 {
                let format = String(localized: "contact_detail.voice_rec.learned", defaultValue: "Appresa il %@",
                                    comment: "Contact screen, voice recognition row: the voice is learned; %@ is the date")
                return String(format: format, learnedDate(enrolledS: s.enrolledS, locale: locale))
            }
            return String(localized: "contact_detail.voice_rec.learned_nodate", defaultValue: "Appresa",
                          comment: "Contact screen, voice recognition row: the voice is learned (no date)")
        case .learning:
            let format = String(localized: "contact_detail.voice_rec.learning", defaultValue: "In apprendimento: %1$lld di %2$lld s",
                                comment: "Contact screen, voice recognition row: progress as net speech")
            let head = String(format: format, Int64(summary?.speechS ?? 0), Int64(summary?.targetS ?? 120))
            guard let s = summary, s.sessions > 0 else { return head }
            let sessionsFormat = String(localized: "contact_detail.voice_rec.sessions", defaultValue: "Sessioni: %lld",
                                        comment: "Contact screen, voice recognition row: number of calls the voice was learned from")
            let daysFormat = String(localized: "contact_detail.voice_rec.days", defaultValue: "Giorni: %lld",
                                    comment: "Contact screen, voice recognition row: number of days the voice was learned over")
            let sessions = String(format: sessionsFormat, Int64(s.sessions))
            let days = String(format: daysFormat, Int64(s.days))
            return head + " · " + sessions + " · " + days
        }
    }
}

/// The "Voice recognition" row of the contact screen. It reads the record of the contact (state, net speech, sessions, days, date),
/// never the contact database. With the check available it shows for every contact; without the entitlement it shows only for a
/// contact that has a learned voice, and then offers only "Forget this voice": deleting never depends on the entitlement.
struct ContactVoiceRecognitionRow: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type

    let userId: String

    @State private var ui: ContactVoiceUi = .hidden
    @State private var summary: ContactVoiceSummary?
    @State private var ownerOn = true

    var body: some View {
        Group {
            if ui != .hidden, ui == .full || summary != nil {
                card
            }
        }
        .task(id: userId) { await reload() }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "contact_detail.voice_rec.label", defaultValue: "Riconoscimento della voce",
                        comment: "Contact screen, voice recognition row: title"))
                .qaudionStyle(type.titleSmall)
                .foregroundStyle(scheme.onSurface)
            Text(ContactVoiceRowText.text(summary: summary, ownerOn: ownerOn && ui == .full))
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurfaceVariant)
            if let summary {
                HStack(spacing: 16) {
                    Button(String(localized: "contact_detail.voice_rec.forget", defaultValue: "Dimentica questa voce",
                                  comment: "Contact screen, voice recognition row: deletes the learned voice")) { forget() }
                    if summary.canRelearn, ui == .full {
                        Button(String(localized: "contact_detail.voice_rec.relearn", defaultValue: "Apprendi di nuovo",
                                      comment: "Contact screen, voice recognition row: deletes the learned voice so that it is learned again")) { forget() }
                    }
                }
                .qaudionStyle(type.labelMedium)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(scheme.surface))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(scheme.outline.opacity(0.5), lineWidth: 1))
    }

    private func forget() {
        let id = userId
        VoiceCallWiring.forgetVoice(userId: id) { _ in
            Task { @MainActor in await reload() }
        }
    }

    private func reload() async {
        let id = userId
        let result: (ContactVoiceUi, ContactVoiceSummary?, Bool) = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let setting = ContactVoiceSettings.shared
                let has = VoiceCallWiring.hasLearnedVoices()
                let ui = setting.ui(hasRecords: has)
                let found = has ? VoiceCallWiring.summaries(contactIds: [id])[id] : nil
                cont.resume(returning: (ui, found, setting.choice))
            }
        }
        ui = result.0
        summary = result.1
        ownerOn = result.2
    }
}
