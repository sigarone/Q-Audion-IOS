import SwiftUI

/// The one-time Bluetooth mesh consent screen.
///
/// Says in plain words what turning the mesh on means: this phone relays the
/// encrypted messages of other app users who are nearby, it cannot read them, and
/// it can be turned off in Settings. Two answers and no way to slide the sheet
/// away without choosing: "Attiva" starts the mesh, "Non ora" leaves it off.
///
/// Takes no AppState (CLAUDE.md section 16): what happens on each answer is the
/// caller's closure. Shown by HomeView the first time, and again from the chat's
/// mesh panel and the Settings switch for a user who has not accepted yet. All
/// three present it through `meshConsentSheet`, so a call always goes first.
struct MeshConsentSheet: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type

    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                paragraph(Self.bodyOne)
                paragraph(Self.bodyTwo)
                paragraph(Self.bodyThree)
                acceptButton
                    .padding(.top, 8)
                declineButton
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
        }
        .background(scheme.background)
        .interactiveDismissDisabled(true)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(scheme.primary)
            Text(Self.title)
                .qaudionStyle(type.titleMedium)
                .foregroundStyle(scheme.onSurface)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .qaudionStyle(type.bodyMedium)
            .foregroundStyle(scheme.onSurface)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var acceptButton: some View {
        Button(action: onAccept) {
            Text(Self.acceptLabel)
                .qaudionStyle(type.labelLarge)
                .foregroundStyle(scheme.onPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(scheme.primary, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var declineButton: some View {
        Button(action: onDecline) {
            Text(Self.declineLabel)
                .qaudionStyle(type.labelLarge)
                .foregroundStyle(scheme.onSurface)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(scheme.surfaceVariant, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    // The strings are computed, not stored, so a change of the in-app language shows on the next render (Section 13: no
    // formatting inside view builders). Keyed by identifier like the Enigma settings texts; the Italian default is the source.
    private static var title: String { String(localized: "mesh_consent.title", defaultValue: "Mesh Bluetooth", comment: "Title of the one-time consent screen for the Bluetooth mesh.") }
    private static var bodyOne: String { String(localized: "mesh_consent.body_1", defaultValue: "Quando non c'è rete, Q-Audion può far arrivare i messaggi cifrati passando da un telefono all'altro, via Bluetooth.", comment: "Consent screen for the Bluetooth mesh, first paragraph: what the mesh is.") }
    private static var bodyTwo: String { String(localized: "mesh_consent.body_2", defaultValue: "Se attivi la mesh, questo telefono inoltra anche i messaggi cifrati di altri utenti dell'app che si trovano vicino a te. Non può leggerli: restano cifrati da chi li scrive a chi li riceve. Finché la mesh è accesa, il telefono annuncia anche un identificativo fisso che gli altri telefoni Q-Audion vicini possono vedere.", comment: "Consent screen for the Bluetooth mesh, second paragraph: this phone relays encrypted messages of other app users nearby and cannot read them, and while the mesh is on it announces a fixed identifier that other Q-Audion phones nearby can see. This is the thing the user consents to.") }
    private static var bodyThree: String { String(localized: "mesh_consent.body_3", defaultValue: "L'inoltro usa il Bluetooth e un po' di batteria. Puoi spegnerlo quando vuoi con l'interruttore Mesh Bluetooth nelle Impostazioni.", comment: "Consent screen for the Bluetooth mesh, third paragraph: the cost, and where to turn it off. 'Mesh Bluetooth' is the title of the switch in Settings.") }
    private static var acceptLabel: String { String(localized: "mesh_consent.accept", defaultValue: "Attiva", comment: "Consent screen for the Bluetooth mesh: button that turns the mesh on.") }
    private static var declineLabel: String { String(localized: "mesh_consent.decline", defaultValue: "Non ora", comment: "Consent screen for the Bluetooth mesh: button that leaves the mesh off.") }
}

// MARK: - Who goes first: the call

/// Presents `MeshConsentSheet` under the order rules of `MeshConsentPresentation`: never while a call is busy, taken down at
/// once when a call arrives, and reported to `MeshConsentArbiter` from the moment it is requested until it is gone from the
/// screen, so the root's call cover can wait for it (`meshAwareCallCover`).
///
/// `wanted` is whoever wants the question asked: HomeView's first run (a read-only binding derived from the stored answer, so
/// the sheet comes back by itself after a call), or the `@State` of the Settings switch and the mesh panel (a request made
/// over a call, or interrupted by one, is dropped: the user taps again).
///
/// After a call the sheet stays away a moment longer (`MeshConsentPresentation.settleAfterCall`), so it does not come up while
/// the call cover is still sliding away.
struct MeshConsentSheetHost: ViewModifier {
    @Binding var wanted: Bool
    let callBusy: Bool
    let onAccept: () -> Void
    let onDecline: () -> Void
    @State private var token = UUID()
    /// True from the moment a call is busy until a moment after it ended.
    @State private var settling: Bool = false
    /// Counts the changes of `callBusy`, so only the timer of the last call to end lowers `settling`.
    @State private var settleGeneration: Int = 0

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: shownBinding, onDismiss: sheetGone) {
                MeshConsentSheet(onAccept: onAccept, onDecline: onDecline)
                    .onAppear(perform: sheetAppeared)
            }
            .onAppear {
                if shown { sheetAppeared() }
            }
            .onChange(of: shown) { isShown in
                if isShown { sheetAppeared() }
            }
            .onChange(of: callBusy) { busy in
                if busy { wanted = false }
                noteCallBusyChanged(busy)
            }
            .onChange(of: wanted) { isWanted in
                if isWanted && held { wanted = false }
            }
            .onDisappear(perform: sheetGone)
    }

    /// A call is busy, or ended a moment ago.
    private var held: Bool {
        callBusy || settling
    }

    /// The sheet is up only for a wanted question and never over a call (`MeshConsentPresentation.sheetShown`).
    private var shown: Bool {
        MeshConsentPresentation.sheetShown(wanted: wanted, callBusy: held)
    }

    private var shownBinding: Binding<Bool> {
        Binding(
            get: { shown },
            set: { isShown in
                if !isShown { wanted = false }
            }
        )
    }

    /// Keeps the sheet away while a call is busy and for a moment after it ended: it must not come up under a cover that is
    /// still leaving. Only the timer of the last change lowers the flag.
    private func noteCallBusyChanged(_ busy: Bool) {
        settleGeneration += 1
        if busy {
            settling = true
            return
        }
        let generation: Int = settleGeneration
        let nanos: UInt64 = UInt64(MeshConsentPresentation.settleAfterCall * 1_000_000_000)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: nanos)
            if generation == settleGeneration { settling = false }
        }
    }

    private func sheetAppeared() {
        MeshConsentArbiter.shared.sheetAppeared(token)
    }

    private func sheetGone() {
        MeshConsentArbiter.shared.sheetGone(token)
    }
}

/// The call cover of the root (1:1 ring, group ring, live group call), made to wait for a consent sheet that is still on
/// screen. `callWanted` is what used to be the cover's own condition; `callBusy` is mirrored into `MeshConsentArbiter` for
/// the sheets that cannot see `AppState`.
struct MeshAwareCallCover<Cover: View>: ViewModifier {
    let callWanted: Bool
    let callBusy: Bool
    let cover: () -> Cover
    @ObservedObject private var arbiter = MeshConsentArbiter.shared

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: coverBinding) {
                cover()
            }
            .onAppear { arbiter.setCallBusy(callBusy) }
            .onChange(of: callBusy) { busy in
                arbiter.setCallBusy(busy)
            }
            .task(id: waiting) { [waiting = self.waiting] in
                await Self.writeOffIfStuck(waiting: waiting)
            }
    }

    /// A call is wanted but a consent sheet is still on screen (or sliding away): the cover is held back.
    private var waiting: Bool {
        callWanted && arbiter.consentSheetOnScreen
    }

    private var coverBinding: Binding<Bool> {
        Binding(
            get: {
                MeshConsentPresentation.callCoverShown(
                    callWanted: callWanted, consentSheetOnScreen: arbiter.consentSheetOnScreen)
            },
            set: { _ in }
        )
    }

    /// A consent sheet that never reports back (it was never really shown, or its dismissal callback was lost) must not hold
    /// a call hostage: after `maxWaitForSheet` it is written off and the call is shown. Cancelled the moment the wait ends.
    private static func writeOffIfStuck(waiting: Bool) async {
        guard waiting else { return }
        let nanos: UInt64 = UInt64(MeshConsentPresentation.maxWaitForSheet * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanos)
        guard !Task.isCancelled else { return }
        await MainActor.run {
            MeshConsentArbiter.shared.clearSheets()
        }
    }
}

extension View {
    /// The consent sheet, with the call going first (see `MeshConsentSheetHost`).
    func meshConsentSheet(
        wanted: Binding<Bool>,
        callBusy: Bool,
        onAccept: @escaping () -> Void,
        onDecline: @escaping () -> Void
    ) -> some View {
        modifier(MeshConsentSheetHost(wanted: wanted, callBusy: callBusy, onAccept: onAccept, onDecline: onDecline))
    }

    /// The root's call cover, waiting for a consent sheet that is still on screen (see `MeshAwareCallCover`).
    func meshAwareCallCover<Cover: View>(
        callWanted: Bool,
        callBusy: Bool,
        @ViewBuilder cover: @escaping () -> Cover
    ) -> some View {
        modifier(MeshAwareCallCover(callWanted: callWanted, callBusy: callBusy, cover: cover))
    }
}
