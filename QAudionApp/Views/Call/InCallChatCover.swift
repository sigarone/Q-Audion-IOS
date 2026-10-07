import SwiftUI
import QAudionEngine

/// The chat of a 1:1 call, opened over the call screen without leaving the call: read, answer, send a file, check a number.
///
/// What it is: the ordinary `ChatDetailScreen` of the conversation with the peer, presented as a cover of `LiveInCallScreen`, which
/// stays mounted underneath. Nothing of the call is touched: no audio, no handshake, no CallKit, no audio session. The back chevron
/// of the chat closes the cover and the call screen is there again.
///
/// What it is not: a way out of the call into the rest of the app. Anything that plays or records audio would take over the shared
/// audio session the call lives on, so while a call is up the chat itself refuses what does it (`ChatDetailScreen.callAudioBlock`: a
/// voice note recorded or played, a video played) and its call buttons are off. The group call has its own panel
/// (`GroupCallChatPanel`).
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
