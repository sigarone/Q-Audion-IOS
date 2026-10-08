import Foundation

/// One row of the open chat as the effect needs to know it: no message type of the app, no text of a non-text row.
public struct EnigmaRow: Equatable, Sendable {
    public enum Kind: Sendable {
        /// A plain text row: `text` is what the bubble shows.
        case text
        /// An outgoing file row: `text` is the file name the bubble shows (the scene shows it cleaned).
        case file
        /// Voice notes, placeholders, view-once rows, system rows: nothing to morph.
        case other
    }

    public let id: String
    public let isOutgoing: Bool
    public let kind: Kind
    public let text: String

    public init(id: String, isOutgoing: Bool, kind: Kind, text: String) {
        self.id = id
        self.isOutgoing = isOutgoing
        self.kind = kind
        self.text = text
    }
}

/// The logic between the two hooks and the screen, with no UI in it (so it runs on the CI test lane): which announced
/// packet belongs to which row, which received rows are held back while their scene is being decided, and the hard
/// time limit on that hold.
///
/// The hold-back is the part that can hurt a user: a received row stays invisible until its scene starts. It is bounded by
/// `receiveHideMaxMs` (500 ms) counted from the moment the packet is announced, whatever else happens: `expireHidden`
/// releases every row whose time is up (the screen calls it from a timer that does not depend on any bubble), and a
/// release of a row whose packet was never claimed counts as a stall; the second stall switches the effect off for the
/// session. (On Android a received row stayed invisible for ever once; this is the guard.)
public final class EnigmaCoordinator {
    /// The single limit of the hold-back of a received row, from the moment its packet is announced.
    public static let receiveHideMaxMs: Int64 = 500
    /// Rows nearer to the end of the list than this count as "next to the screen" (a new message scrolls in there).
    public static let nearEndRows: Int = 8

    public let effect: EnigmaEffect
    public let pending: EnigmaPending
    private let clock: () -> Int64
    private var hiddenAt: [String: Int64] = [:]
    private var knownIds: Set<String> = []

    /// The conversation of the open chat. Events of any other conversation are ignored (nothing is held back or counted
    /// for a row this screen does not show). Nil: no chat is attached, nothing is accepted.
    public var conversationKey: String?

    public init(effect: EnigmaEffect, pending: EnigmaPending = EnigmaPending(), clock: @escaping () -> Int64) {
        self.effect = effect
        self.pending = pending
        self.clock = clock
        effect.isVisible = { [weak self] id in self?.knownIds.contains(id) ?? false }
    }

    /// Rows currently held back (invisible).
    public var hiddenIds: Set<String> { Set(hiddenAt.keys) }

    public var hasHidden: Bool { !hiddenAt.isEmpty }

    /// True while a received packet is announced for the row `id`, its scene has not started yet and the time limit has
    /// not run out.
    public func awaitsScene(_ id: String) -> Bool {
        guard let since = hiddenAt[id] else { return false }
        return clock() - since < EnigmaCoordinator.receiveHideMaxMs
    }

    /// Milliseconds left before the row `id` must be shown whatever the state of the scene.
    public func hiddenRemainingMs(_ id: String) -> Int64 {
        guard let since = hiddenAt[id] else { return 0 }
        return max(0, since + EnigmaCoordinator.receiveHideMaxMs - clock())
    }

    /// A packet was sealed or opened for a row. Nothing is shown yet: the row may not even exist.
    public func accept(_ event: EnigmaWireEvent) {
        guard let key = conversationKey, key == event.conversationKey else { return }
        let now = clock()
        pending.add(EnigmaPending.Item(
            id: event.rowId, direction: event.direction, packetBytes: event.packetBytes,
            wire: event.wirePrefixBase64, atMs: now))
        // Only a row that a scene can really follow is held back: with the effect off nothing is hidden, ever.
        if event.direction == .receive && effect.wouldAnimate() { hiddenAt[event.rowId] = now }
    }

    /// The row is shown normally from now on. If its packet was still waiting, nobody ever decided the scene: that is a
    /// stall. Returns true when the row had been held back.
    @discardableResult
    public func releaseHidden(_ id: String) -> Bool {
        guard hiddenAt[id] != nil else { return false }
        let stalled = pending.takeIf(nowMs: clock()) { $0.id == id && $0.direction == .receive }
        hiddenAt.removeValue(forKey: id)
        if !stalled.isEmpty { effect.noteStall() }
        return true
    }

    /// Releases every held-back row whose time is up. Returns true when at least one row changed state.
    @discardableResult
    public func expireHidden() -> Bool {
        if hiddenAt.isEmpty { return false }
        let now = clock()
        var due: [String] = []
        for (id, since) in hiddenAt where now - since >= EnigmaCoordinator.receiveHideMaxMs { due.append(id) }
        for id in due { releaseHidden(id) }
        return !due.isEmpty
    }

    /// Starts the effect for every announced packet whose row is now in `rows`. `foreground` is the app's state (false
    /// plays nothing). Never throws; a misbehaving hand-off disables the effect and shows everything.
    public func resolve(rows: [EnigmaRow], foreground: Bool) {
        knownIds = Set(rows.map { $0.id })
        let now = clock()
        if pending.size > 0 {
            let taken = pending.takeIf(nowMs: now) { item in knownIds.contains(item.id) }
            for item in taken {
                hiddenAt.removeValue(forKey: item.id)
                guard let index = rows.firstIndex(where: { $0.id == item.id }) else { continue }
                play(item: item, row: rows[index], isNearEnd: index >= rows.count - EnigmaCoordinator.nearEndRows, foreground: foreground)
            }
        }
        // A row held for a packet that is no longer waiting (claimed elsewhere, expired) or that waited too long goes back
        // to normal now; the screen's own timer is the backstop when nothing calls this again.
        if !hiddenAt.isEmpty {
            var stale: [String] = []
            for (id, since) in hiddenAt where now - since >= EnigmaCoordinator.receiveHideMaxMs || !pending.contains(id: id, direction: .receive) {
                stale.append(id)
            }
            for id in stale { releaseHidden(id) }
        }
    }

    private func play(item: EnigmaPending.Item, row: EnigmaRow, isNearEnd: Bool, foreground: Bool) {
        let expectOutgoing = item.direction == .send
        if row.isOutgoing != expectOutgoing { return }
        let plain: String
        switch row.kind {
        case .text:
            plain = row.text
        case .file:
            // A file name only on the way out: the received side has no packet of its own to show for a name.
            if item.direction != .send { return }
            plain = EnigmaText.sceneName(row.text)
        case .other:
            return
        }
        if plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        let from = item.direction == .send ? plain : item.wire
        let to = item.direction == .send ? item.wire : plain
        effect.play(
            id: item.id,
            direction: item.direction,
            from: from,
            to: to,
            result: .ok(packetBytes: item.packetBytes),
            visible: foreground && isNearEnd
        )
    }

    /// Advances the running scene to the frame time `nowNanos`.
    @discardableResult
    public func step(nowNanos: Int64, nominalFrameMs: Double = EnigmaGovernor.referenceFrameMs) -> Bool {
        effect.onFrame(nowNanos: nowNanos, nominalFrameMs: nominalFrameMs)
    }

    /// Shows every result now: running scene, queue and held-back rows.
    public func stop() {
        effect.cancelAll()
        hiddenAt.removeAll()
        pending.clear()
    }

    /// The setting went off or the screen closed: forget announced packets and held rows, keep nothing.
    public func reset() {
        stop()
        knownIds = []
    }
}
