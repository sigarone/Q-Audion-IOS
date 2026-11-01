import SwiftUI

/// W559 — Bug report overlay sheet.
/// Presented when `BugReporter.shared.isShowingOverlay` is true, by the host that matches how the report was opened.
/// Shows a compact card (not full-screen) with screenshot thumbnail, note field, skip and send buttons.
struct BugReportOverlay: View {

    /// Which view presents the sheet. A sheet cannot appear over a full-screen cover presented by an ancestor, so the
    /// group call screen (shown in such a cover) hosts the sheet of its own report button; every other report is
    /// presented from the root.
    enum Host {
        case root
        case groupCall

        func presents(_ source: Int) -> Bool {
            let isGroupCall = source == BugReporter.TriggerSource.inGroupCall.rawValue
            switch self {
            case .root: return !isGroupCall
            case .groupCall: return isGroupCall
            }
        }
    }

    let host: Host
    @ObservedObject var reporter = BugReporter.shared
    @State private var note: String = ""
    @State private var attachLogs: Bool = true

    var body: some View {
        Color.clear
            .sheet(isPresented: Binding(
                get: { reporter.isShowingOverlay && host.presents(reporter.pendingReport?.source ?? 0) },
                set: { if !$0 { reporter.dismiss() } }
            )) {
                BugReportCard(reporter: reporter, note: $note, attachLogs: $attachLogs)
                    .presentationDetents([.height(520)])
                    .presentationDragIndicator(.visible)
            }
    }
}

// MARK: - Card content

private struct BugReportCard: View {

    @ObservedObject var reporter: BugReporter
    @Binding var note: String
    @Binding var attachLogs: Bool

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            contentRow
                .padding(.horizontal, 16)
                .padding(.top, 16)
            Text(String(localized: "bug_report.privacy_hint",
                        defaultValue: "Il report è cifrato: solo il team di Q-Audion può leggerlo.",
                        comment: "Bug report sheet — note under the text field: the report is end-to-end encrypted and only the Q-Audion team can read it."))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 10)
            logConsentRow
                .padding(.horizontal, 16)
                .padding(.top, 14)
            Spacer(minLength: 0)
            actionRow
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
        }
        .padding(.top, 12)
        .background(Color(.systemBackground))
        .cornerRadius(16)
    }

    // MARK: Header

    private var headerBar: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "ladybug.fill")
                    .foregroundColor(.red)
                    .font(.system(size: 18, weight: .semibold))
                Text("Segnala un problema")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
                Button {
                    reporter.dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Color(.systemGray3))
                        .font(.system(size: 22))
                }
                .accessibilityLabel("Chiudi")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    // MARK: Thumbnail + note

    private var contentRow: some View {
        HStack(alignment: .top, spacing: 12) {
            screenshotThumbnail
            noteField
        }
    }

    @ViewBuilder
    private var screenshotThumbnail: some View {
        if let img = reporter.pendingReport?.screenshot {
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 100, height: 160)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(.systemGray4), lineWidth: 1)
                )
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.systemGray6))
                .frame(width: 100, height: 160)
                .overlay(
                    Image(systemName: "photo")
                        .foregroundColor(Color(.systemGray3))
                        .font(.system(size: 28))
                )
        }
    }

    private var noteField: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.systemGray6))
            if note.isEmpty {
                Text("Cosa non va?")
                    .foregroundColor(Color(.placeholderText))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                    .font(.system(size: 14))
                    .allowsHitTesting(false)
            }
            TextEditor(text: $note)
                .font(.system(size: 14))
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .background(Color.clear)
                .scrollContentBackground(.hidden)
                .frame(height: 160)
        }
        .frame(height: 160)
    }

    // MARK: Log consent

    /// Per-report consent for the log attachment. On by default; the subtitle says exactly what is sent.
    private var logConsentRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $attachLogs) {
                Text(String(localized: "bug_report.attach_logs",
                            defaultValue: "Allega log diagnostici della chiamata",
                            comment: "Bug report sheet — checkbox: attach the app's technical log of the call to this report."))
                    .font(.system(size: 14, weight: .medium))
            }
            Text(String(localized: "bug_report.attach_logs_hint",
                        defaultValue: "Vengono inviati solo gli ultimi minuti del registro tecnico dell'app (eventi, stato di rete e audio, errori), con i dati personali oscurati. Nessun messaggio, nessun contenuto di chiamata. Se lo disattivi non parte nessuna riga di log.",
                        comment: "Bug report sheet — subtitle of the log checkbox: exactly what is sent when it is on."))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Actions

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                reporter.dismiss()
            } label: {
                Text("Salta")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color(.systemGray6))
                    .cornerRadius(10)
            }

            Button {
                let capturedNote = note
                reporter.send(note: capturedNote, attachLogs: attachLogs)
                note = ""
                attachLogs = true
            } label: {
                Text("Invia report")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.red)
                    .cornerRadius(10)
            }
        }
    }
}
