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
                // W35: design-token loading placeholder (vs stock
                // ProgressView). Stesso pattern dei restanti screen di
                // attesa server.
                QAudionLoadingState(message: "Richiesta permesso Contatti in corso…")
            case .scanning(let p):
                progressBlock(label: "Scansione rubrica…", value: p)
            case .discovering(let p):
                progressBlock(label: "Ricerca utenti Q-Audion…", value: p)
            case .results(let matched, let unmatched):
                resultsContent(matched: matched, unmatched: unmatched)
            case .error(let msg):
                errorContent(msg)
            }
        }
        .padding()
        .navigationTitle("Importa contatti")
    }

    /// Indeterminate-or-determinate progress block. Wraps a labeled
    /// linear ProgressView so scanning / discovering steps share the
    /// same shell.
    private func progressBlock(label: String, value: Double) -> some View {
        VStack(spacing: 12) {
            Text(label)
                .font(.body)
                .foregroundStyle(.secondary)
            ProgressView(value: value, total: 1.0)
                .progressViewStyle(.linear)
                .frame(maxWidth: 320)
        }
    }

    private var introContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.rectangle.stack").font(.system(size: 64)).foregroundStyle(.blue)
            Text("Trova utenti Q-Audion nella tua rubrica").font(.title2.bold())
            Text("Calcoliamo l'hash di ogni numero localmente con un pepper fornito dal server, poi chiediamo al server quali hash corrispondono a utenti noti. La tua rubrica non lascia mai il dispositivo in chiaro.").font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Inizia") {
                container.startImport()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private func resultsContent(matched: [PhonebookImportViewModel.Match], unmatched: Int) -> some View {
        VStack {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(.green)
            Text("\(matched.count) utenti Q-Audion trovati").font(.title2.bold())
            Text("\(unmatched) dei tuoi contatti non sono ancora su Q-Audion.").font(.body).foregroundStyle(.secondary)
            List(matched, id: \.userId) { m in
                VStack(alignment: .leading) {
                    Text(m.localName).font(.body)
                    // Technical id caption — short8, never the full UUID
                    // (central rule, see DisplayName.swift).
                    Text("ID: " + String(m.userId.prefix(8)) + "…")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func errorContent(_ msg: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 64)).foregroundStyle(.red)
            Text("Errore di importazione").font(.title.bold())
            Text(msg).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }
}
