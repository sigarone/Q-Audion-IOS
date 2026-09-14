import Foundation
import QAudionEngine

/// Resolves mesh node ids <-> known contacts for the mesh sheet. Deliberately
/// takes only primitives in its initializer (CLAUDE.md section 16) — never
/// `AppState` — and reaches `ContactsStore` directly, the same lightweight
/// engine-level data-access type existing files (`ContactsScreen`,
/// `NameResolutionService`, ...) already instantiate directly without going
/// through `AppState`.
///
/// Mirrors the Android sibling's `MeshNodeIdentity` (core-data) folded
/// together with `MeshViewModel`'s label-resolution helper, since iOS has no
/// separate DI-bound "identity" service layer to split it across.
@MainActor
final class MeshSheetViewModel: ObservableObject {

    @Published var selectedNodeHex: String?
    @Published var relaysExpanded: Bool = false

    let conversationId: String
    /// userId of the contact this chat belongs to, so the radar can
    /// auto-highlight that contact's device — set once at sheet-open time.
    let chatPeerUserId: String?

    private let contactsStore = ContactsStore()

    /// True once the user has made their own selection decision in this sheet
    /// (tapped a device, or dismissed the detail card). [autoSelectChatPeer]
    /// never fights that — an auto-select that keeps overriding a person is
    /// worse than none at all.
    private var selectionTouchedByUser = false

    init(conversationId: String, chatPeerUserId: String?) {
        self.conversationId = conversationId
        self.chatPeerUserId = chatPeerUserId
    }

    /// Record that the selection changed because the user said so.
    func markSelectionTouched() {
        selectionTouchedByUser = true
    }

    /// R2 — select this chat's own contact once their device is on the radar.
    ///
    /// The sheet already knew which contact the chat belonged to and already
    /// drew a halo for it; nothing ever assigned the selection, so reaching
    /// that person still meant finding their row and tapping it.
    ///
    /// Three guards, matching the Android sibling's `autoSelectTarget` so the
    /// two platforms behave the same: never override a user decision, never
    /// yank the sheet off a current selection, and never select a device that
    /// is not actually in range — the last one matters because selecting an
    /// absent node would arm a target that cannot be reached and make the
    /// pre-send indicator promise a route that does not exist.
    ///
    /// Selection only: it does not arm mesh routing for the conversation. That
    /// stays explicit, so opening the radar to look around can never silently
    /// move a chat off the public network.
    func autoSelectChatPeer(visibleNodeHexes: [String]) {
        guard !selectionTouchedByUser, selectedNodeHex == nil else { return }
        // W-MESHUNKNOWN-IOS: a contact can have more than one candidate hex
        // when sources briefly disagree (see MeshFeature.nodeHexes) — match
        // against whichever one is actually visible, not just the first.
        guard let target = currentChatPeerNodeHexes.first(where: visibleNodeHexes.contains) else { return }
        selectedNodeHex = target
    }

    /// Every node id hex this chat's own contact could be advertising,
    /// resolved from every authenticated identity key known for them — empty
    /// when unknown/unpaired/never called.
    var currentChatPeerNodeHexes: Set<String> {
        guard let chatPeerUserId,
              let contact = contactsStore.load().first(where: { $0.userId == chatPeerUserId })
        else { return [] }
        return MeshFeature.nodeHexes(forContact: contact)
    }

    /// Single-hex convenience for callers that only ever compare against one
    /// value (the radar halo, `MeshSheetView`'s reachability chip) — picking
    /// `.first` is a non-issue there: those are cosmetic, and a contact with
    /// more than one candidate hex is the rare disagreement window
    /// `MeshFeature.nodeHexes` documents, not the normal case.
    var currentChatPeerNodeHex: String? {
        currentChatPeerNodeHexes.first
    }

    /// (displayName, isKnownContact) for a node hex — linear scan over the
    /// contact list, same complexity tradeoff the Android sibling's
    /// `MeshNodeIdentity.resolveNode` documents as fine at BLE-range peer
    /// counts (tens, not thousands).
    func label(forNodeHex nodeHex: String) -> (name: String, known: Bool) {
        if let contact = resolveContact(nodeHex: nodeHex) {
            return (contact.displayName, true)
        }
        return ("Dispositivo non identificato", false)
    }

    /// Reverse lookup: which known contact (if any) owns `nodeHex`.
    ///
    /// W-MESHUNKNOWN (2026-08-17) — used to check ONLY `contact.pubkey`,
    /// which is populated exclusively by the QR-scan/NFC pairing flow
    /// (`ContactsStore.StoredContact.pubkey` doc). A contact added through
    /// the ordinary phone-number flow has `pubkey == nil` and could never
    /// resolve here, however well "known" they are elsewhere in the app —
    /// exactly the "unknown user" symptom reported live, since most real
    /// contacts are never QR/NFC-paired. `presenceAuth?.peerIdentityKey` is
    /// the SAME long-term Ed25519 identity key, already written whenever a
    /// call with this contact reached NFC-authenticated presence (S2) — it
    /// was just never consulted here. No new data, no schema change: this
    /// only widens the lookup to a source that already exists on disk.
    /// Mirrors Android's `MeshNodeIdentity.resolveNode()`, which already
    /// unions its own multiple stored-key columns for the same reason.
    func resolveContact(nodeHex: String) -> ContactsStore.StoredContact? {
        contactsStore.load().first { MeshFeature.matchesNodeHex(nodeHex, contact: $0) }
    }
}
