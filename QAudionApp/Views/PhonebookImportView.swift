import SwiftUI
import QAudionEngine
import Contacts

struct PhonebookImportView: View {
    @StateObject private var container: PhonebookImportContainer
    @Environment(\.dismiss) private var dismiss

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
                QAudionLoadingState(message: String(localized: "contact.phonebook.requesting_permission", defaultValue: "Richiesta permesso Contatti in corso…", comment: "Loading message while the app asks iOS for access to the address book"))
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
        // The screen that only precedes the system Contacts request (permission not decided yet) leads to it and has no
        // way to postpone it. Once the permission is decided the screen can be closed again.
        .interactiveDismissDisabled(isPriming)
        .toolbar {
            if !isPriming {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isIntroduction ? LocalizedStringKey("Annulla") : LocalizedStringKey("Fatto")) { dismiss() }
                }
            }
        }
    }

    private var isIntroduction: Bool {
        if case .introduction = container.viewModel.step { return true }
        return false
    }

    private var isPriming: Bool {
        if case .introduction = container.viewModel.step { return container.permissionNotDetermined }
        return false
    }

    /// Indeterminate-or-determinate progress block. Wraps a labeled
    /// linear ProgressView so scanning / discovering steps share the
    /// same shell.
    private func progressBlock(label: LocalizedStringKey, value: Double) -> some View {
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
            Group {
                if container.permissionNotDetermined {
                    // Only the system request: nothing is scanned or sent until the user taps "Importa".
                    Button("Continua") {
                        container.requestPermissionOnly()
                    }
                    .disabled(container.requestingSystemPermission)
                } else {
                    Button("Importa") {
                        container.startImport()
                    }
                }
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
            if let notice = container.incompleteNotice {
                Text(notice).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
            }
            List(matched, id: \.userId) { m in
                // The "ID: 7f3b…" caption that used to sit under the name is
                // gone. Truncating a UUID does not make it a thing to show a
                // user — there is nothing they can do with eight characters
                // of a server id, and no raw id belongs on a user-facing
                // surface. The name here comes from their own phonebook,
                // which is what they actually recognise. Unlike the
                // group-call picker, this row has no short number to put in
                // its place: PhonebookImportViewModel.Match carries only
                // userId, localName and phoneHash.
                Text(m.localName).font(.body)
            }
        }
    }

    private func errorContent(_ msg: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 64)).foregroundStyle(.red)
            Text("Errore di importazione").font(.title.bold())
            Text(msg).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if CNContactStore.authorizationStatus(for: .contacts) == .denied {
                Button("Apri Impostazioni") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
        }
    }
}
