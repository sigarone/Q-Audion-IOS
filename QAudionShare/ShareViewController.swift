import UIKit
import SwiftUI
import UserNotifications

/// The share sheet entry of Q-Audion. It lets the user pick a chat, copies the shared items into the queue of the App Group
/// container and ends. The app sends them (see `ShareQueue.swift`); this process holds no keys and does no networking.
final class ShareViewController: UIViewController {

    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.providers = (extensionContext?.inputItems as? [NSExtensionItem])?
            .flatMap { $0.attachments ?? [] } ?? []
        model.onFinish = { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
        model.onCancel = { [weak self] in
            self?.extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }
        let host = UIHostingController(rootView: ShareRootView(model: model))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
    }
}

/// State of the sheet.
@MainActor
final class ShareModel: ObservableObject {

    enum Phase: Equatable {
        case choosing
        case working
        case done
        case failed(String)
    }

    @Published var phase: Phase = .choosing
    let chats: [ShareRecentChat]
    /// The app lock is on: the app shows no chat names here.
    let namesHidden: Bool
    var providers: [NSItemProvider] = []
    var onFinish: () -> Void = {}
    var onCancel: () -> Void = {}

    private let store: ShareQueueStore

    init(store: ShareQueueStore = ShareQueueStore()) {
        self.store = store
        self.chats = store.readRecentChats()
        self.namesHidden = store.recentsHidden
    }

    func choose(_ chat: ShareRecentChat) {
        guard phase == .choosing else { return }
        phase = .working
        let providers = self.providers
        let store = self.store
        Task {
            do {
                let began = try store.beginEntry()
                do {
                    let items = try await ShareExtractor(store: store).extract(from: providers, into: began.folder)
                    let entry = ShareEntry(id: began.id, createdAt: Date(), peerUserId: chat.peerUserId, items: items)
                    try store.commit(entry, in: began.folder)
                } catch {
                    store.abandon(folder: began.folder)
                    throw error
                }
                await Self.postReadyNotice()
                phase = .done
                try? await Task.sleep(nanoseconds: 900_000_000)
                onFinish()
            } catch {
                phase = .failed(Self.message(for: error))
            }
        }
    }

    /// A local notice that the share waits for the app. It carries no name and no text; it only shows if the app was
    /// allowed to notify.
    private static func postReadyNotice() async {
        let content = UNMutableNotificationContent()
        content.title = "Q-Audion"
        content.body = String(localized: "share.notice.body", defaultValue: "Tocca per finire l'invio in Q-Audion.",
                              comment: "Local notification after sharing into Q-Audion: the app finishes the sending.")
        let request = UNNotificationRequest(identifier: "qaudion.share.ready", content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        try? await UNUserNotificationCenter.current().add(request)
    }

    private static func message(for error: Error) -> String {
        switch error {
        case ShareQueueError.queueFull:
            return String(localized: "share.error.queue_full", defaultValue: "Ci sono già condivisioni in attesa. Apri Q-Audion per concluderle.",
                          comment: "Share sheet error: too many shares are waiting for the app.")
        case ShareQueueError.itemTooLarge, ShareExtractor.Failure.tooLarge:
            return String(localized: "share.error.too_large", defaultValue: "Un elemento è troppo grande per essere condiviso.",
                          comment: "Share sheet error: a shared item is above the size limit.")
        case ShareExtractor.Failure.nothingShareable, ShareQueueError.emptyShare:
            return String(localized: "share.error.nothing", defaultValue: "Non c'è nulla che Q-Audion possa condividere.",
                          comment: "Share sheet error: none of the shared items is something the app can send.")
        default:
            return String(localized: "share.error.generic", defaultValue: "Non è stato possibile preparare la condivisione.",
                          comment: "Share sheet error: the copy of the shared items failed.")
        }
    }
}

struct ShareRootView: View {
    @ObservedObject var model: ShareModel

    var body: some View {
        NavigationView {
            content
                .navigationTitle(Text(String(localized: "share.title", defaultValue: "Invia con Q-Audion",
                                             comment: "Title of the share sheet of the app.")))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "share.cancel", defaultValue: "Annulla", comment: "Button that closes the share sheet.")) {
                            model.onCancel()
                        }
                        .disabled(model.phase == .working)
                    }
                }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .choosing:
            if model.namesHidden {
                message(String(localized: "share.locked", defaultValue: "Apri Q-Audion per scegliere la chat: con il blocco app attivo qui non si mostrano i nomi.",
                               comment: "Share sheet: the app lock is on, so no chat names are shown; the user opens the app instead."))
            } else if model.chats.isEmpty {
                message(String(localized: "share.empty", defaultValue: "Apri Q-Audion e inizia una conversazione: poi potrai condividere qui.",
                               comment: "Share sheet: no chat to choose from yet."))
            } else {
                List {
                    Section(header: Text(String(localized: "share.choose", defaultValue: "Scegli la chat", comment: "Share sheet: header of the list of chats."))) {
                        ForEach(model.chats, id: \.peerUserId) { chat in
                            Button { model.choose(chat) } label: {
                                Text(chat.displayName).foregroundColor(.primary)
                            }
                        }
                    }
                }
            }
        case .working:
            VStack(spacing: 12) {
                ProgressView()
                Text(String(localized: "share.working", defaultValue: "Preparazione…", comment: "Share sheet: the items are being copied."))
                    .foregroundColor(.secondary)
            }
        case .done:
            message(String(localized: "share.done", defaultValue: "Fatto. Apri Q-Audion per finire l'invio.",
                           comment: "Share sheet: the items are ready, the app sends them."))
        case .failed(let text):
            message(text)
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .multilineTextAlignment(.center)
            .foregroundColor(.secondary)
            .padding(24)
    }
}
