import Foundation

/// Link-count rules of docs/mesh/MESH_LINK_SPEC.md sections 3.6, 3.7 and 8.4, free of Bluetooth types so that both
/// platforms implement the same arithmetic and can test it.
public enum MeshLinkTiming {
    /// Sections 3.3 / 3.4: a subscribed link, in either role, with no valid packet received and no frame sent for this
    /// long is closed.
    public static let linkIdleTimeoutMs: Int64 = 120_000
    /// Section 8.4: the ANNOUNCE period of one link.
    public static let announceIntervalMs: Int64 = 15_000
    /// Section 8.4: the periodic ANNOUNCEs of different links start at least this far apart (one per tick).
    public static let announceTickMs: Int64 = 1_000
    /// Section 13: the period of the `ann.sum` line.
    public static let announceSummaryMs: Int64 = 60_000
    /// Section 3.6: how long an address whose outgoing link was closed as a duplicate of node N is remembered; it is not
    /// dialled while a healthy link to N exists.
    public static let dupRedialSuppressMs: Int64 = 30_000
    /// Section 3.6: the memory of an address grows 30, 60, 120, 300 s while a healthy link to its node exists.
    public static let dupRedialBackoffMs: [Int64] = [30_000, 60_000, 120_000, 300_000]
    /// Hard cap of the tables of the collapse guard and of the redial memory; the oldest entry goes first.
    public static let tableCap = 64
    /// Sections 3.6 / 9: a direct send or a flood goes to at most this many links of one node.
    public static let maxLinksPerNode = 4
    /// Sections 3.3 / 3.4: a link may be evicted for a newcomer once it has been idle (no validated data, not newly bound) for this long.
    public static let evictMinAgeMs: Int64 = 30_000
    /// Sections 3.3 / 3.4: at most one link per role is evicted for a newcomer inside this window.
    public static let evictWindowMs: Int64 = 30_000
    /// Sections 3.3 / 3.4: a link that subscribed but has not announced within this time is closed.
    public static let unboundTimeoutMs: Int64 = 35_000
    /// Section 3.4: an incoming connection from a central whose link was evicted is refused for this long.
    public static let evictRefuseMs: Int64 = 60_000
    /// Section 3.3: the wait before an evicted address is dialled again grows 30, 60, 120, 300 s, and resets after this quiet time.
    public static let evictRedialBackoffMs: [Int64] = [30_000, 60_000, 120_000, 300_000]
    public static let evictMemoryResetMs: Int64 = 900_000
    /// Section 3.6: at most this many closes of one link key inside `collapseWindowMs`; beyond it the link is excluded.
    public static let collapseMaxPerWindow = 4
    public static let collapseWindowMs: Int64 = 300_000
}

/// One link already bound to a node by its ANNOUNCE. `key` is opaque to the policy.
public struct MeshLinkCandidate: Equatable, Sendable {
    public let key: String
    public let central: Bool
    /// The platform address (identifier) of the peer at the other end of this link.
    public let address: String
    public let subscribed: Bool
    public let lastActivityMs: Int64
    /// When the link was bound to its node id (set once, never by a later ANNOUNCE), not when it was created.
    public let boundAtMs: Int64
    /// The last time the link carried a validated DATA or RECEIPT packet (sent or received), 0 if it never did.
    public let lastDataMs: Int64
    /// The node the link is bound to, nil while it has no ANNOUNCE yet.
    public let nodeHex: String?

    public init(key: String, central: Bool, address: String, subscribed: Bool, lastActivityMs: Int64, boundAtMs: Int64,
                lastDataMs: Int64 = 0, nodeHex: String? = nil) {
        self.lastDataMs = lastDataMs
        self.nodeHex = nodeHex
        self.key = key
        self.central = central
        self.address = address
        self.subscribed = subscribed
        self.lastActivityMs = lastActivityMs
        self.boundAtMs = boundAtMs
    }
}

/// Section 3.6: links that claim one node.
public enum MeshNodeLinkPolicy {

    /// A link keeps the node id its first ANNOUNCE named. An ANNOUNCE that names another one is refused and the link is
    /// closed (`link.down reason=rebind`).
    public static func mayBind(boundTo: String?, announced: String) -> Bool {
        boundTo == nil || boundTo == announced
    }

    /// The node id in an ANNOUNCE is only a claim, so links with different addresses that claim one node are all kept.
    /// A link is closed only when it provably duplicates another one on the same physical device: the same peer address
    /// in the opposite role. Of such a pair the link in the role where the lower node id is central stays (both ends reach
    /// the same answer), the other is returned.
    public static func sameDeviceDuplicates(localHex: String, peerHex: String, links: [MeshLinkCandidate]) -> [String] {
        let preferCentral = localHex < peerHex
        var close: [String] = []
        let groups = Dictionary(grouping: links.filter { $0.subscribed }, by: { $0.address })
        for (_, group) in groups {
            guard group.contains(where: { $0.central }), group.contains(where: { !$0.central }) else { continue }
            close.append(contentsOf: group.filter { $0.central != preferCentral }.map { $0.key })
        }
        return close.sorted()
    }

    /// The links a frame for a node goes to: every healthy link bound to it, so a claim cannot stand in the way of the real
    /// node.
    public static func directTargets(links: [MeshLinkCandidate], nowMs: Int64) -> [String] {
        links.filter { $0.subscribed && nowMs - $0.lastActivityMs <= MeshLinkTiming.linkIdleTimeoutMs }.map { $0.key }
    }

    /// The links of ONE node a send goes to: every healthy link, up to ``MeshLinkTiming/maxLinksPerNode``. Only above that is
    /// there a ranking: the link bound to the node earliest first, then the others by the most recent validated data (ties:
    /// the older bind). Claimants therefore push the real node out only when more than four addresses claim it.
    public static func fanOut(links: [MeshLinkCandidate], nowMs: Int64) -> [String] {
        let healthy = links.filter { $0.subscribed && nowMs - $0.lastActivityMs <= MeshLinkTiming.linkIdleTimeoutMs }
        let byBind = healthy.sorted { a, b in a.boundAtMs != b.boundAtMs ? a.boundAtMs < b.boundAtMs : a.key < b.key }
        if byBind.count <= MeshLinkTiming.maxLinksPerNode { return byBind.map { $0.key } }
        let rest = byBind.dropFirst().sorted { a, b in
            if a.lastDataMs != b.lastDataMs { return a.lastDataMs > b.lastDataMs }
            if a.boundAtMs != b.boundAtMs { return a.boundAtMs < b.boundAtMs }
            return a.key < b.key
        }.prefix(MeshLinkTiming.maxLinksPerNode - 1)
        return [byBind[0].key] + rest.map { $0.key }
    }

    /// Where a flood goes: every link not yet bound to a node, and for each node at most ``MeshLinkTiming/maxLinksPerNode``
    /// of its links (``fanOut(links:nowMs:)``). The link a packet arrived on, and ALL links of the node it came from, are
    /// left out.
    public static func floodTargets(links: [MeshLinkCandidate], excludingKey: String?, excludingNode: String?, nowMs: Int64) -> [String] {
        let usable = links.filter { $0.subscribed && $0.key != excludingKey && ($0.nodeHex == nil || $0.nodeHex != excludingNode) }
        let unbound = usable.filter { $0.nodeHex == nil }.map { $0.key }
        var bound: [String] = []
        for node in Set(usable.compactMap { $0.nodeHex }).sorted() {
            bound.append(contentsOf: fanOut(links: usable.filter { $0.nodeHex == node }, nowMs: nowMs))
        }
        return unbound + bound
    }

    /// Where a relayed packet goes: the (capped) links to its recipient when it is directly linked, otherwise a flood.
    public static func relayTargets(links: [MeshLinkCandidate], recipientNode: String?, arrivalKey: String?,
                                    arrivalNode: String?, nowMs: Int64) -> [String] {
        if let recipientNode, recipientNode != arrivalNode {
            let direct = fanOut(links: links.filter { $0.nodeHex == recipientNode && $0.key != arrivalKey }, nowMs: nowMs)
            if !direct.isEmpty { return direct }
        }
        return floodTargets(links: links, excludingKey: arrivalKey, excludingNode: arrivalNode, nowMs: nowMs)
    }

    /// Whether a newcomer may make an eviction at all: only after it sent a valid ANNOUNCE (it is bound) and is subscribed.
    public static func canTriggerEviction(newcomer: MeshLinkCandidate) -> Bool {
        newcomer.subscribed && newcomer.nodeHex != nil
    }

    /// The link of a role to evict when its slots are over the cap: the longest idle one. A link is idle since the later of its
    /// last validated data and its bind, and counts only once idle for more than ``MeshLinkTiming/evictMinAgeMs``. Never the
    /// newcomer, never a link bound to the node the newcomer itself claims, and never the earliest-bound healthy link of its
    /// node (the newcomer is not counted in that decision). Nil when there is none.
    public static func evictionVictim(links: [MeshLinkCandidate], centralRole: Bool, excludingKey: String?, nowMs: Int64) -> String? {
        let newcomerNode = links.first(where: { $0.key == excludingKey })?.nodeHex
        let healthy = links.filter {
            $0.key != excludingKey && $0.subscribed && nowMs - $0.lastActivityMs <= MeshLinkTiming.linkIdleTimeoutMs
        }
        func earliestOfItsNode(_ link: MeshLinkCandidate) -> Bool {
            link.nodeHex != nil && healthy.contains(where: { $0.key == link.key })
                && !healthy.contains(where: {
                    $0.key != link.key && $0.nodeHex == link.nodeHex
                        && ($0.boundAtMs < link.boundAtMs || ($0.boundAtMs == link.boundAtMs && $0.key < link.key))
                })
        }
        func idleSince(_ link: MeshLinkCandidate) -> Int64 { max(link.lastDataMs, link.boundAtMs) }
        return links.filter {
            $0.central == centralRole && $0.key != excludingKey
                && nowMs - idleSince($0) > MeshLinkTiming.evictMinAgeMs
                && (newcomerNode == nil || $0.nodeHex != newcomerNode) && !earliestOfItsNode($0)
        }.min { a, b in idleSince(a) != idleSince(b) ? idleSince(a) < idleSince(b) : a.key < b.key }?.key
    }

    /// Whether a link that subscribed at `subscribedAtMs` and has no node yet has waited too long for its ANNOUNCE.
    public static func unboundExpired(subscribedAtMs: Int64, nodeHex: String?, nowMs: Int64) -> Bool {
        nodeHex == nil && subscribedAtMs != 0 && nowMs - subscribedAtMs > MeshLinkTiming.unboundTimeoutMs
    }

    /// What to do with the links to close: `close` those the guard allows, `exclude` the others from routing. The guard
    /// budget is per link key, so one peer cannot use up the budget of another. A link the guard refuses stays open but is
    /// excluded from routing until the next decision.
    public static func plan(toClose: [String], allow: (String) -> Bool) -> (close: [String], exclude: [String]) {
        var close: [String] = []
        var exclude: [String] = []
        for key in toClose {
            if allow(key) { close.append(key) } else { exclude.append(key) }
        }
        return (close, exclude)
    }

    /// Whether a scan result at `target` is skipped because a healthy link already exists at that very identifier (the same
    /// device in the other role). A healthy link to the same node at another identifier does not skip it.
    public static func dialBlockedByLink(target: String, healthyLinkIdentifiers: Set<String>) -> Bool {
        healthyLinkIdentifiers.contains(target)
    }
}

/// Sections 3.3 / 3.4: at most one eviction per role inside ``MeshLinkTiming/evictWindowMs``.
public struct MeshEvictionLimiter {
    private var lastMs: [Bool: Int64] = [:]

    public init() {}

    /// True (and recorded) when a link of the role may be evicted now.
    public mutating func allow(centralRole: Bool, nowMs: Int64) -> Bool {
        if let last = lastMs[centralRole], nowMs - last < MeshLinkTiming.evictWindowMs { return false }
        lastMs[centralRole] = nowMs
        return true
    }
}

/// Section 3.3: addresses whose link was evicted. The address is not dialled again before a wait that grows with every repeat
/// (30, 60, 120, 300 s) and is forgotten after a quiet quarter of an hour. Unlike ``MeshRedialMemory`` it does not depend on a
/// healthy link: an evicted newcomer has none, and would be dialled, bound and evicted again at once.
public struct MeshEvictionMemory {
    private struct Entry {
        var untilMs: Int64
        var strikes: Int
        var stampMs: Int64
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public mutating func note(_ address: String, nowMs: Int64) {
        var strikes = 0
        if let existing = entries[address], nowMs - existing.stampMs < MeshLinkTiming.evictMemoryResetMs {
            strikes = min(existing.strikes + 1, MeshLinkTiming.evictRedialBackoffMs.count - 1)
        }
        entries[address] = Entry(untilMs: nowMs + MeshLinkTiming.evictRedialBackoffMs[strikes], strikes: strikes, stampMs: nowMs)
        while entries.count > MeshLinkTiming.tableCap,
              let oldest = entries.min(by: { $0.value.stampMs < $1.value.stampMs })?.key {
            entries.removeValue(forKey: oldest)
        }
    }

    public func blocks(_ address: String, nowMs: Int64) -> Bool {
        (entries[address]?.untilMs ?? 0) > nowMs
    }
}

/// Sections 3.4 / 3.6: keys whose incoming connections are refused until a time; only expiry removes an entry.
public struct MeshRefusalTable {
    private var until: [String: Int64] = [:]

    public init() {}

    public mutating func refuse(_ key: String, untilMs: Int64) {
        until[key] = untilMs
    }

    public func isRefused(_ key: String, nowMs: Int64) -> Bool {
        (until[key] ?? 0) > nowMs
    }

    public mutating func prune(nowMs: Int64) {
        until = until.filter { $0.value > nowMs }
    }
}

/// Section 3.6: addresses whose outgoing link was closed as a same-device duplicate. The address is not dialled while a
/// healthy link to that node exists, for 30 s; the time doubles with every repeat (60, 120, 300 s). It is forgotten as
/// soon as no healthy link to the node exists.
public struct MeshRedialMemory {
    private struct Entry {
        var node: String
        var untilMs: Int64
        var strikes: Int
        var stampMs: Int64
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public mutating func note(_ address: String, node: String, nowMs: Int64) {
        var strikes = 0
        // Only a link that duplicates the keeper on the same device is ever noted, so the wait may grow without a claim
        // being able to stretch the block on the real node.
        if let existing = entries[address], existing.node == node {
            strikes = min(existing.strikes + 1, MeshLinkTiming.dupRedialBackoffMs.count - 1)
        }
        entries[address] = Entry(node: node, untilMs: nowMs + MeshLinkTiming.dupRedialBackoffMs[strikes], strikes: strikes,
                                 stampMs: nowMs)
        while entries.count > MeshLinkTiming.tableCap,
              let oldest = entries.min(by: { $0.value.stampMs < $1.value.stampMs })?.key {
            entries.removeValue(forKey: oldest)
        }
    }

    /// True when `address` must not be dialled now. `healthy` tells whether a healthy link to a node exists.
    public mutating func blocks(_ address: String, nowMs: Int64, healthy: (String) -> Bool) -> Bool {
        guard let entry = entries[address] else { return false }
        if !healthy(entry.node) {
            entries.removeValue(forKey: address)
            return false
        }
        return entry.untilMs > nowMs
    }

    /// The node an address was last closed for, if remembered.
    public func node(of address: String) -> String? {
        entries[address]?.node
    }
}

/// Section 3.6: a peer that keeps redialling a link we close would make us close it for ever; after a few, leave it.
public struct MeshCollapseGuard {
    private var events: [String: [Int64]] = [:]

    public init() {}

    /// True (and recorded) when a collapse for `nodeHex` is allowed now.
    public mutating func allow(_ nodeHex: String, nowMs: Int64) -> Bool {
        var recent = (events[nodeHex] ?? []).filter { nowMs - $0 < MeshLinkTiming.collapseWindowMs }
        if recent.count >= MeshLinkTiming.collapseMaxPerWindow {
            events[nodeHex] = recent
            return false
        }
        recent.append(nowMs)
        events[nodeHex] = recent
        if events.count > MeshLinkTiming.tableCap {
            events = events.filter { ($0.value.last ?? 0) > nowMs - MeshLinkTiming.collapseWindowMs }
            while events.count > MeshLinkTiming.tableCap,
                  let oldest = events.min(by: { ($0.value.last ?? 0) < ($1.value.last ?? 0) })?.key {
                events.removeValue(forKey: oldest)
            }
        }
        return true
    }
}

/// Section 8.4: the periodic ANNOUNCE of each link every 15 s, never on all links at one instant.
public enum MeshAnnouncePacer {

    /// The one link whose periodic ANNOUNCE is due at `nowMs`, or nil. `lastSentMs` maps a link key to the time its last
    /// ANNOUNCE went out. The most overdue link goes first; the others wait for a later tick
    /// (``MeshLinkTiming/announceTickMs``), which is what spreads them over the period.
    public static func next(lastSentMs: [String: Int64], nowMs: Int64) -> String? {
        lastSentMs
            .filter { nowMs - $0.value >= MeshLinkTiming.announceIntervalMs }
            .min { a, b in a.value != b.value ? a.value < b.value : a.key < b.key }?
            .key
    }
}

/// Section 13: `ann.sum`, one line per ``MeshLinkTiming/announceSummaryMs`` instead of a line per ANNOUNCE. `claim` is the
/// number of nodes that more than one distinct address claimed in the window.
public struct MeshAnnounceSummary {
    private static let maxAddressesPerNode = 8

    private var windowStartMs: Int64
    private var tx = 0
    private var txFail = 0
    private var rx = 0
    private var addressesByNode: [String: Set<String>] = [:]

    public init(startMs: Int64) {
        windowStartMs = startMs
    }

    public mutating func recordTx(ok: Bool) {
        tx += 1
        if !ok { txFail += 1 }
    }

    public mutating func recordRx(node: String, address: String) {
        rx += 1
        if var set = addressesByNode[node] {
            if set.count < Self.maxAddressesPerNode {
                set.insert(address)
                addressesByNode[node] = set
            }
        } else if addressesByNode.count < MeshLinkTiming.tableCap {
            addressesByNode[node] = [address]
        }
    }

    /// Emits the line and starts a new window when the window is over and something happened; otherwise does nothing.
    public mutating func flushIfDue(nowMs: Int64, links: Int) {
        guard nowMs - windowStartMs >= MeshLinkTiming.announceSummaryMs else { return }
        if tx != 0 || rx != 0 {
            let claim = addressesByNode.values.filter { $0.count > 1 }.count
            MeshLog.emit(.annSum, [("tx", String(tx)), ("fail", String(txFail)), ("rx", String(rx)),
                                   ("links", String(links)), ("claim", String(claim)),
                                   ("s", String((nowMs - windowStartMs) / 1000))])
        }
        windowStartMs = nowMs
        tx = 0
        txFail = 0
        rx = 0
        addressesByNode.removeAll()
    }
}

/// Rate limit for the `tx.frame.fail` warning (section 13). The first failure for a (link, reason) is logged; further
/// ones inside `windowMs` are only counted, and the next line that gets through carries the count as `rep=N`.
public struct MeshTxFailThrottle {
    public static let windowMs: Int64 = 60_000
    private static let maxKeys = 256

    private struct State {
        var lastLoggedMs: Int64
        var suppressed: Int
    }

    private var states: [String: State] = [:]
    private let window: Int64

    public init(windowMs: Int64 = MeshTxFailThrottle.windowMs) {
        window = windowMs
    }

    public mutating func warn(link: String, ph: String, idx: Int, total: Int, reason: String, nowMs: Int64) {
        let key = link + "/" + reason
        var rep = 0
        if var state = states[key] {
            if nowMs - state.lastLoggedMs < window {
                state.suppressed += 1
                states[key] = state
                return
            }
            rep = state.suppressed
            state.lastLoggedMs = nowMs
            state.suppressed = 0
            states[key] = state
        } else {
            if states.count >= Self.maxKeys {
                states = states.filter { nowMs - $0.value.lastLoggedMs < window }
                while states.count >= Self.maxKeys,
                      let oldest = states.min(by: { $0.value.lastLoggedMs < $1.value.lastLoggedMs })?.key {
                    states.removeValue(forKey: oldest)
                }
            }
            states[key] = State(lastLoggedMs: nowMs, suppressed: 0)
        }
        var fields: [(String, String)] = [("link", link), ("ph", ph), ("idx", String(idx)), ("total", String(total)), ("reason", reason)]
        if rep > 0 { fields.append(("rep", String(rep))) }
        MeshLog.emit(.txFrameFail, fields)
    }
}
