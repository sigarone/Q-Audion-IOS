import SwiftUI

public struct ContactDetailView: View {
    public let viewModel: ContactDetailViewModel
    public var onCall: (() -> Void)?
    public var onChat: (() -> Void)?
    public var onVerifySas: (() -> Void)?
    public var onBlock: (() -> Void)?
    public var onDelete: (() -> Void)?
    /// 2026-08-06 fix: "Delete contact" used to fire onDelete?() immediately
    /// on tap, no confirmation -- a single mis-tap on a destructive-role
    /// button permanently deleted the contact, unlike the newer
    /// ContactDetailScreen which has an alert. Confirmed via @State here.
    @State private var confirmingDelete = false

    public init(viewModel: ContactDetailViewModel = .mock,
                onCall: (() -> Void)? = nil,
                onChat: (() -> Void)? = nil,
                onVerifySas: (() -> Void)? = nil,
                onBlock: (() -> Void)? = nil,
                onDelete: (() -> Void)? = nil) {
        self.viewModel = viewModel
        self.onCall = onCall
        self.onChat = onChat
        self.onVerifySas = onVerifySas
        self.onBlock = onBlock
        self.onDelete = onDelete
    }

    /// Back-compat shim: existing callers that pass a `DiscoveredContact` +
    /// `TrustShieldView.TrustLevel` continue to compile without changes.
    public init(contact: DiscoveredContact,
                trustLevel: TrustShieldView.TrustLevel = .unknown,
                onCall: @escaping () -> Void = {},
                onVideoCall: @escaping () -> Void = {},
                onMessage: @escaping () -> Void = {},
                onVerify: @escaping () -> Void = {},
                onBlock: @escaping () -> Void = {}) {
        let mappedTrust: ContactDetailViewModel.TrustLevel
        switch trustLevel {
        case .pskBound: mappedTrust = .both
        case .verified: mappedTrust = .sasVerified
        case .unknown, .unverified, .tofu: mappedTrust = .unverified
        }
        self.viewModel = ContactDetailViewModel(
            userId: contact.userId,
            displayName: contact.displayName ?? contact.userId,
            phoneHash: contact.phoneHash,
            fingerprint: "",
            avatarUrl: contact.avatarUrl.flatMap { URL(string: $0) },
            trustLevel: mappedTrust,
            isBlocked: false,
            lastSeen: nil,
            recentCallCount: 0,
            unreadMessageCount: 0
        )
        self.onCall = onCall
        self.onChat = onMessage
        self.onVerifySas = onVerify
        self.onBlock = onBlock
        self.onDelete = nil
    }

    public var body: some View {
        Form {
            avatarHeader
            identitySection
            actionsSection
            statsSection
            dangerSection
        }
        .navigationTitle(viewModel.displayName)
        .alert("Eliminare questo contatto?", isPresented: $confirmingDelete) {
            Button("Elimina", role: .destructive) { onDelete?() }
            Button("Annulla", role: .cancel) { }
        } message: {
            Text("Questa azione non può essere annullata.")
        }
    }

    @ViewBuilder
    private var avatarHeader: some View {
        Section {
            HStack {
                Spacer()
                avatarImage
                Spacer()
            }
            .padding(.vertical, 16)
        }
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private var avatarImage: some View {
        if let url = viewModel.avatarUrl {
            AsyncImage(url: url) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                placeholderAvatar
            }
            .frame(width: 100, height: 100)
            .clipShape(Circle())
        } else {
            placeholderAvatar
        }
    }

    private var placeholderAvatar: some View {
        Circle()
            .fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 100, height: 100)
            .overlay(
                Text(initials)
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
            )
    }

    private var initials: String {
        let words = viewModel.displayName.split(separator: " ")
        let firstChars = words.prefix(2).compactMap { $0.first }
        return String(firstChars).uppercased()
    }

    private var identitySection: some View {
        Section("Identità") {
            LabeledContent("ID utente") {
                Text(viewModel.userId).font(.caption.monospaced()).lineLimit(1)
            }
            LabeledContent("Impronta") {
                Text(viewModel.fingerprint).font(.body.monospaced())
            }
            HStack {
                Text("Fiducia")
                Spacer()
                trustBadge
            }
        }
    }

    private var trustBadge: some View {
        Group {
            switch viewModel.trustLevel {
            case .unverified:
                Label("Non verificato", systemImage: "questionmark.circle")
                    .foregroundStyle(.orange)
            case .sasVerified:
                Label("SAS verificato", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            case .nfcPaired:
                Label("Associato via NFC", systemImage: "wave.3.right")
                    .foregroundStyle(.blue)
            case .both:
                Label("Completamente verificato", systemImage: "shield.lefthalf.filled")
                    .foregroundStyle(.green)
            }
        }
        .font(.caption.weight(.semibold))
    }

    private var actionsSection: some View {
        Section("Azioni") {
            Button(action: { onCall?() }, label: {
                Label("Chiama", systemImage: "phone.fill")
            })
            Button(action: { onChat?() }, label: {
                Label("Chat", systemImage: "message.fill")
            })
            if viewModel.trustLevel == .unverified {
                Button(action: { onVerifySas?() }, label: {
                    Label("Verifica SAS", systemImage: "lock.shield")
                })
            }
        }
    }

    private var statsSection: some View {
        Section("Statistiche") {
            LabeledContent("Chiamate recenti") {
                Text("\(viewModel.recentCallCount)")
            }
            LabeledContent("Messaggi non letti") {
                Text("\(viewModel.unreadMessageCount)")
            }
            if let last = viewModel.lastSeen {
                LabeledContent("Ultimo accesso") {
                    Text(last, style: .relative)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var dangerSection: some View {
        Section {
            Button(role: viewModel.isBlocked ? .none : .destructive,
                   action: { onBlock?() },
                   label: {
                Label(viewModel.isBlocked ? "Sblocca" : "Blocca",
                      systemImage: viewModel.isBlocked ? "lock.open" : "hand.raised.fill")
            })
            Button(role: .destructive, action: { confirmingDelete = true }, label: {
                Label("Elimina contatto", systemImage: "trash")
            })
        }
    }
}

#Preview {
    NavigationStack { ContactDetailView() }
}
