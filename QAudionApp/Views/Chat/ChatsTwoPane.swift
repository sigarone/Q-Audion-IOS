import SwiftUI

/// What the Chats tab can have open: a one-to-one conversation or a group.
enum QAudionChatTarget: Hashable, Identifiable {
    case conversation(id: UUID, peerUserId: String, peerDisplayName: String)
    case group(id: UUID, name: String, memberCount: Int)

    var id: String {
        switch self {
        case .conversation(let id, _, _): return "c-\(id.uuidString)"
        case .group(let id, _, _): return "g-\(id.uuidString)"
        }
    }
}

/// The chat that is open, kept above the Chats tab so it outlives a change of layout. The folded and the unfolded
/// foldable iPhone, or a window that changes size, rebuild the tab with another arrangement (a stack, or the list next
/// to the chat); the open chat is read from here in both. Whatever the user has typed lives in `ComposerDraftStore`,
/// so a rebuilt chat shows the same draft.
final class ChatSelectionModel: ObservableObject {
    /// Used by a `ChatListScreen` built without a host (previews): selects nothing, shared by nobody.
    static let detached = ChatSelectionModel()

    @Published var selected: QAudionChatTarget?

    init(selected: QAudionChatTarget? = nil) {
        self.selected = selected
    }

    /// Closes the open chat; publishes nothing when none is open.
    func clear() {
        if selected != nil { selected = nil }
    }
}

private struct ChatShowsBackKey: EnvironmentKey {
    static let defaultValue: Bool = true
}

extension EnvironmentValues {
    /// False for a chat shown in the detail column next to the list: there is nothing to go back to.
    var qaudionChatShowsBack: Bool {
        get { self[ChatShowsBackKey.self] }
        set { self[ChatShowsBackKey.self] = newValue }
    }
}

/// A row of the chat list. In a stack it pushes the chat (a `NavigationLink`, as before); next to the open chat it selects
/// it instead and marks the selected row.
struct ChatRowLink<Destination: View, Label: View>: View {
    @Environment(\.qaudionScheme) private var scheme

    let target: QAudionChatTarget
    let twoPane: Bool
    @ObservedObject var selection: ChatSelectionModel
    private let destination: () -> Destination
    private let label: () -> Label

    init(target: QAudionChatTarget,
         twoPane: Bool,
         selection: ChatSelectionModel,
         @ViewBuilder destination: @escaping () -> Destination,
         @ViewBuilder label: @escaping () -> Label) {
        self.target = target
        self.twoPane = twoPane
        self.selection = selection
        self.destination = destination
        self.label = label
    }

    var body: some View {
        if twoPane {
            Button {
                selection.selected = target
            } label: {
                label()
                    .padding(.horizontal, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(selection.selected == target ? scheme.primary.opacity(0.16) : Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(destination: destination()) {
                label()
            }
        }
    }
}

/// The screen a `QAudionChatTarget` stands for.
struct ChatPaneContent: View {
    let target: QAudionChatTarget

    var body: some View {
        switch target {
        case .conversation(let id, let peerUserId, let peerDisplayName):
            ChatDetailScreen(conversationId: id, peerUserId: peerUserId, peerDisplayName: peerDisplayName)
        case .group(let id, let name, let memberCount):
            GroupChatScreen(
                groupId: id,
                initial: GroupChatUiState(name: name, memberCount: memberCount, messages: []))
        }
    }
}

/// The Chats tab. On a narrow window it is the list with the chat pushed over it, exactly as before. On a regular window
/// wide enough for two columns (the unfolded foldable iPhone, an iPad) it is the list next to the open chat.
struct ChatsRootView: View {
    @Binding var path: NavigationPath
    @ObservedObject var selection: ChatSelectionModel

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    /// The width this tab is given: the window's at the first frame, then measured (no `GeometryReader` around the
    /// navigation stack, which would change how it meets the safe area).
    @State private var width: CGFloat = QAudionAdaptive.sceneWidth()

    var body: some View {
        content
            .qaudionReportsWidth($width)
    }

    @ViewBuilder
    private var content: some View {
        if QAudionAdaptive.chatsAreTwoPane(horizontalRegular: horizontalSizeClass == .regular, width: width) {
            twoPane(width: width)
        } else {
            NavigationStack(path: $path) {
                ChatListScreen(selection: selection, twoPane: false)
            }
        }
    }

    private func twoPane(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            NavigationStack(path: $path) {
                ChatListScreen(selection: selection, twoPane: true)
            }
            .frame(width: QAudionAdaptive.listPaneWidth(totalWidth: width))

            Rectangle()
                .fill(scheme.outline.opacity(0.3))
                .frame(width: 0.5)

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let target = selection.selected {
            ChatPaneContent(target: target)
                .id(target)
                .environment(\.qaudionChatShowsBack, false)
        } else {
            ZStack {
                scheme.background.ignoresSafeArea()
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 56, weight: .regular))
                    .foregroundStyle(extras.pqcAccent.opacity(0.35))
                    .accessibilityHidden(true)
            }
        }
    }
}
