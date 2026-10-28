import Combine
import SwiftUI
import QAudionEngine

/// What the root view adds for the legal layer, in one place:
///  - the blocking re-acceptance screen of an existing account (an overlay, not a presentation, so a call that
///    starts takes it down at once and never has to wait for it to slide away);
///  - the receipt of a withdrawal, above everything, until it is closed;
///  - the emergency notice before the first outgoing call.
struct LegalRootModifier: ViewModifier {
    let appState: AppState
    @StateObject private var gate: TermsGateModel
    @ObservedObject private var emergency = EmergencyNoticeCenter.shared
    @ObservedObject private var receipts = WithdrawalReceiptStore.shared
    @Environment(\.scenePhase) private var scenePhase
    private let callBusy: AnyPublisher<Bool, Never>

    init(appState: AppState) {
        self.appState = appState
        _gate = StateObject(wrappedValue: TermsGateModel(
            api: AppStateLegalApi(appState: appState),
            languageCode: { LegalService.documentLanguage }))
        // The same rule the mesh consent sheet uses to stay away from a call: ringing, being set up or running, 1:1 or group.
        callBusy = Publishers.CombineLatest4(
            appState.$isInCall, appState.$callState, appState.$incomingCallRingVisible, appState.$incomingGroupCallInvite)
            .combineLatest(appState.$groupCallControllerState)
            .map { first, groupState in
                MeshConsentPresentation.callIsBusy(
                    isInCall: first.0, callIdle: first.1 == .idle, oneToOneRinging: first.2,
                    groupInvitePending: first.3 != nil, groupCallIdle: groupState == .idle)
            }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    func body(content: Content) -> some View {
        ZStack {
            content
            if gate.isPresented {
                TermsGateScreen(appState: appState, model: gate)
                    .transition(.opacity)
                    .zIndex(10)
            }
            if let receipt = receipts.receipt {
                WithdrawalReceiptScreen(receipt: receipt) { receipts.close() }
                    .transition(.opacity)
                    .zIndex(11)
            }
        }
        .alert(
            LegalStrings.emergencyTitle,
            isPresented: Binding(get: { emergency.pendingText != nil }, set: { _ in }),
            actions: {
                Button(LegalStrings.emergencyAck) { emergency.acknowledge() }
            },
            message: {
                Text(verbatim: emergency.pendingText ?? "")
            })
        .onAppear {
            EmergencyNoticeCenter.shared.configure { [weak weakState = appState] in
                weakState.map { AppStateLegalApi(appState: $0) }
            }
        }
        .onReceive(callBusy) { busy in gate.setCallBusy(busy) }
        .onReceive(appState.$isAuthenticated) { authenticated in
            if authenticated {
                Task { await refreshWithOneRetry() }
            } else {
                gate.reset()
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active && appState.isAuthenticated {
                Task { await gate.refresh() }
            }
        }
    }

    /// Launch: the session may not be ready for the first read, so an unread status is asked once more shortly after.
    private func refreshWithOneRetry() async {
        await gate.refresh()
        guard gate.requirement == .unknown else { return }
        try? await Task.sleep(nanoseconds: 6_000_000_000)
        guard appState.isAuthenticated else { return }
        await gate.refresh()
    }
}

extension View {
    func legalRoot(appState: AppState) -> some View {
        modifier(LegalRootModifier(appState: appState))
    }
}
