import SwiftUI
import QAudionEngine

/// The chat of a 1:1 call, opened over the call screen without leaving the call: read, answer, send a file, check a number.
///
/// What it is: the ordinary `ChatDetailScreen` of the conversation with the peer, presented as a cover of the call screen, which
/// stays mounted underneath (`LiveInCallScreen` for an audio call, `VideoCallView` for a video call). Nothing of the call is touched:
/// no audio, no handshake, no CallKit, no audio session, no video pipeline. The back chevron of the chat closes the cover and the call
/// screen is there again.
///
/// What it is not: a way out of the call into the rest of the app. Anything that plays or records audio would take over the shared
/// audio session the call lives on, so while a call is up the chat itself refuses what does it (`ChatDetailScreen.callAudioBlock`: a
/// voice note recorded or played, a video played), and in a video call it refuses the camera (`ChatDetailScreen.callCameraBlock`: the
/// capture session is the call's). Its call buttons are off. The group call has its own panel (`GroupCallChatPanel`).
///
/// The cover is a presentation of its own, so the snackbar host of `ContentView` (the root overlay) is behind it: this view brings
/// its own, and the chat's notices ("Messaggio non inviato", the audio notice) show here.
struct InCallChatCover: View {
    let target: InCallChatTarget

    @StateObject private var snackbarHost = QAudionSnackbarHostState()

    var body: some View {
        ZStack(alignment: .top) {
            NavigationStack {
                ChatDetailScreen(
                    conversationId: target.conversationId,
                    peerUserId: target.peerUserId,
                    peerDisplayName: target.peerDisplayName
                )
            }
            QAudionSnackbarHost(state: snackbarHost)
        }
        .environment(\.qaudionSnackbar, snackbarHost)
    }
}

/// Which chat the cover shows: the conversation with the person on the call.
struct InCallChatTarget: Identifiable, Equatable {
    let conversationId: UUID
    let peerUserId: String
    let peerDisplayName: String

    var id: UUID { conversationId }
}

// MARK: - State shared by the two 1:1 call screens

/// What a 1:1 call screen needs to offer the chat: the dot on the button and the action. Handed down through the environment by
/// `InCallChatHost`; `nil` (no host, or the call has no peer) hides the button. A value, rebuilt by the host on every change, so the
/// screens redraw when the dot appears or goes away.
struct InCallChatAccess {
    /// A message of the peer is waiting in that chat.
    let hasUnread: Bool
    /// Opens the chat with the peer; the argument is the name the call screen shows for them.
    let open: (_ peerDisplayName: String) -> Void
}

private struct InCallChatAccessKey: EnvironmentKey {
    static let defaultValue: InCallChatAccess? = nil
}

extension EnvironmentValues {
    /// The chat of the call, if this call screen is under an `InCallChatHost`.
    var inCallChat: InCallChatAccess? {
        get { self[InCallChatAccessKey.self] }
        set { self[InCallChatAccessKey.self] = newValue }
    }
}

/// The chat opened over the call and the unread dot of its button: one instance for the whole call (`InCallChatHost` owns it), so
/// the audio screen and the video screen, which `ContentView` swaps while the call goes on, share it and the chat stays open across
/// the swap.
@MainActor
final class InCallChatController: ObservableObject {
    /// The chat being shown over the call. nil = closed.
    @Published var target: InCallChatTarget? = nil
    /// A message of the peer is waiting in that chat: the dot on the button. Read from the store when a chat event arrives and when
    /// the cover closes, never on the per-second tick of the call screens.
    @Published private(set) var hasUnread: Bool = false

    /// Opens the chat with the person on the call (it is created empty when there is none yet).
    func open(peerUserId: String, conversationId: UUID, peerDisplayName: String) {
        target = InCallChatTarget(
            conversationId: conversationId, peerUserId: peerUserId, peerDisplayName: peerDisplayName)
    }

    /// The dot on the chat button: the conversation with the peer has unread messages and the chat is not open.
    func refreshUnread(peerUserId: String?) {
        guard target == nil, let peer = InCallChatPolicy.chatPeer(callContactId: peerUserId) else {
            hasUnread = false
            return
        }
        let unread = ConversationStore().loadConversations().first(where: { $0.peerUserId == peer })?.unreadCount ?? 0
        hasUnread = unread > 0
    }
}

/// Wraps the 1:1 call screens (`ContentView.inCallStack`) for the life of the call: owns the `InCallChatController`, presents the
/// chat cover over whichever call screen is up, and hands the screens their `InCallChatAccess`.
///
/// It sits above the swap between `LiveInCallScreen` and `VideoCallView` (a video call falls back to the audio screen while both sides
/// have their camera paused, and back), so a chat that is open when the swap happens stays open; a cover owned by one of the two
/// screens would be torn down with it. It is created when `isInCall` turns true and released when it turns false, so a call never
/// starts with the chat of the previous one.
///
/// A cover (not a sheet) so that the SAS words and the identity on the call screen are not visible behind it. The call itself is
/// untouched. On the way back the secure window of the call screen is put back (the chat releases it when it goes away, like on every
/// screen it leaves) and the unread dot is recomputed.
@MainActor
struct InCallChatHost<Content: View>: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var capabilityGate: CapabilityGate
    @StateObject private var chat = InCallChatController()

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .environment(\.inCallChat, access)
            .fullScreenCover(item: $chat.target, onDismiss: {
                ScreenshotLockService.lock()
                chat.refreshUnread(peerUserId: appState.callContactId)
            }) { target in
                InCallChatCover(target: target)
                    .environmentObject(appState)
                    .environmentObject(capabilityGate)
            }
            .onAppear {
                chat.refreshUnread(peerUserId: appState.callContactId)
            }
            .onChange(of: appState.callContactId) { peer in
                chat.refreshUnread(peerUserId: peer)
            }
            .onReceive(NotificationCenter.default.publisher(for: AppState.chatRefreshNotification)) { _ in
                chat.refreshUnread(peerUserId: appState.callContactId)
            }
    }

    /// nil while the call has no peer to talk to.
    private var access: InCallChatAccess? {
        guard let peer = InCallChatPolicy.chatPeer(callContactId: appState.callContactId) else { return nil }
        let chat = self.chat
        let appState = self.appState
        return InCallChatAccess(
            hasUnread: chat.hasUnread,
            open: { peerDisplayName in
                chat.open(
                    peerUserId: peer,
                    conversationId: appState.resolveOrCreateConversationId(forPeerUserId: peer),
                    peerDisplayName: peerDisplayName)
            })
    }
}
