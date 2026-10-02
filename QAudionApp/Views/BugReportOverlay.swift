import SwiftUI

/// W559 — Bug report overlay sheet.
/// Presented automatically by ContentView when `BugReporter.shared.isShowingOverlay` is true.
/// Shows a compact card (not full-screen) with screenshot thumbnail, note field, skip and send buttons.
struct BugReportOverlay: View {

    @ObservedObject var reporter = BugReporter.shared
    @State private var note: String = ""

    var body: some View {
        Color.clear
            .sheet(isPresented: Binding(
                get: { reporter.isShowingOverlay },
                set: { if !$0 { reporter.dismiss() } }
            )) {
                BugReportCard(reporter: reporter, note: $note)
                    .presentationDetents([.height(380)])
                    .presentationDragIndicator(.visible)
            }
    }
}

// MARK: - Card content

private struct BugReportCard: View {

    @ObservedObject var reporter: BugReporter
    @Binding var note: String

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            contentRow
                .padding(.horizontal, 16)
                .padding(.top, 16)
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
            .padding(.bottom, openedByText == nil ? 12 : 4)
            if let openedBy = openedByText {
                Text(openedBy)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
        }
    }

    /// W-BUGREPPHANTOM (2026-10-02): the sheet says what opened it. It used to open by
    /// itself at a 1:1 -> group hand-over (the audio route change moved the volume) and,
    /// with a red bug and a red button, read like an error of the call; now it also tells
    /// the user how to leave if they did not mean to report anything.
    private var openedByText: String? {
        switch reporter.pendingReport?.source ?? 0 {
        case BugReporter.TriggerSource.volumeGesture.rawValue:
            return String(localized: "bug_report.opened_by_volume",
                          defaultValue: "Si è aperto con i tasti del volume. Se non volevi segnalare nulla, tocca Salta.",
                          comment: "Bug report sheet — subtitle when the sheet was opened by the volume-button gesture; 'Salta' is the dismiss button of the same sheet")
        case BugReporter.TriggerSource.shake.rawValue:
            return String(localized: "bug_report.opened_by_shake",
                          defaultValue: "Si è aperto scuotendo il telefono. Se non volevi segnalare nulla, tocca Salta.",
                          comment: "Bug report sheet — subtitle when the sheet was opened by shaking the phone; 'Salta' is the dismiss button of the same sheet")
        default:
            return nil
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
                reporter.send(note: capturedNote)
                note = ""
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
