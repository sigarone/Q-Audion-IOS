import SwiftUI
import QAudionEngine

struct PhonebookImportView: View {
    @StateObject private var container: PhonebookImportContainer

    init(appState: AppState) {
        _container = StateObject(wrappedValue: PhonebookImportContainer(appState: appState))
    }

    var body: some View {
        VStack(spacing: 24) {
            switch container.viewModel.step {
            case .introduction:
                introContent
            case .requestingPermission:
                ProgressView("Requesting Contacts permission…")
            case .scanning(let p):
                ProgressView("Scanning phonebook…", value: p, total: 1.0)
            case .discovering(let p):
                ProgressView("Discovering Q-Audion users…", value: p, total: 1.0)
            case .results(let matched, let unmatched):
                resultsContent(matched: matched, unmatched: unmatched)
            case .error(let msg):
                errorContent(msg)
            }
        }
        .padding()
        .navigationTitle("Import Contacts")
    }

    private var introContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.rectangle.stack").font(.system(size: 64)).foregroundStyle(.blue)
            Text("Find Q-Audion users in your phonebook").font(.title2.bold())
            Text("We'll hash each phone number locally with a server-issued pepper, then ask the server which hashes correspond to known users. Your phonebook never leaves the device in plaintext.").font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Start") {
                container.startImport()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private func resultsContent(matched: [PhonebookImportViewModel.Match], unmatched: Int) -> some View {
        VStack {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(.green)
            Text("\(matched.count) Q-Audion users found").font(.title2.bold())
            Text("\(unmatched) of your contacts aren't on Q-Audion yet.").font(.body).foregroundStyle(.secondary)
            List(matched, id: \.userId) { m in
                VStack(alignment: .leading) {
                    Text(m.localName).font(.body)
                    Text(m.userId).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func errorContent(_ msg: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 64)).foregroundStyle(.red)
            Text("Import error").font(.title.bold())
            Text(msg).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }
}
