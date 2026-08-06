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
                    .presentationDetents([.height(340)])
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
