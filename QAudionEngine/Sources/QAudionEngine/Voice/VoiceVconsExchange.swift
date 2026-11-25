import Foundation

/// The announcement of ONE call, both directions. The clock, the keys, the sender and the receiver are injected.
///
/// Sending: at `start()` and then 4 more times every 3 s; a change of the learning or verifying bits or of the local route class
/// restarts the series (at once, then 4 more every 3 s). A change is looked for every `tickMs`. Every message has a new, increasing
/// `seq`. The message always says allow = 1 and withdraw = 0, whatever this device's owner setting is.
///
/// Receiving (`onReceived`, called only with what came from the call's registered peer): opened with the current session key and,
/// when the tag fails, with the previous one; a message that does not open is dropped and the call goes on as if it had not arrived.
/// The newest `seq` wins (unsigned comparison), except that allow = 0 or withdraw = 1 holds for the rest of the call, so a late older
/// message that restricts is still passed on. Nothing here gates processing.
public final class VoiceVconsExchange: @unchecked Sendable {
    public static let prefix = "VCONS:"
    public static let tickMs = 250
    public static let series = 5
    static let seriesPeriodTicks = 3000 / VoiceVconsExchange.tickMs

    /// The part of this device's state that the message reports.
    public struct Local: Equatable, Sendable {
        public var flags: Int
        public var routeClass: Int
        public init(flags: Int, routeClass: Int) {
            self.flags = flags
            self.routeClass = routeClass
        }
    }

    private let callId: String
    private let keys: () -> Data?
    private let send: (String) -> Void
    private let local: () -> Local
    private let onPeer: (VoiceVconsCodec.Fields) -> Void
    private let onDropped: (String) -> Void
    private let nowMs: () -> Int64
    private let queue = DispatchQueue(label: "com.bcrypto.qaudion.voice.vcons", qos: .utility)
    private var timer: DispatchSourceTimer?

    // confined to `queue`
    private var nextSeq: UInt32 = 0
    private var lastSent: Local?
    private var remaining = 0
    private var ticksToNext = 0
    private var peerSeq: UInt32?
    private var lastKey: Data?
    private var previousKey: Data?

    public init(
        callId: String, keys: @escaping () -> Data?, send: @escaping (String) -> Void, local: @escaping () -> Local,
        onPeer: @escaping (VoiceVconsCodec.Fields) -> Void, onDropped: @escaping (String) -> Void = { _ in },
        nowMs: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.callId = callId
        self.keys = keys
        self.send = send
        self.local = local
        self.onPeer = onPeer
        self.onDropped = onDropped
        self.nowMs = nowMs
    }

    /// The sender check: a message counts only when it comes from the registered peer of the call that is running and names that
    /// call. A call with no registered peer drops everything.
    public static func isFromRegisteredPeer(registeredPeer: String?, senderId: String, activeCallId: String?, messageCallId: String) -> Bool {
        guard let peer = registeredPeer, !peer.isEmpty, peer == senderId, let active = activeCallId, !active.isEmpty else { return false }
        return active.lowercased() == messageCallId.lowercased()
    }

    /// Starts the sender; the first message goes out at once. Idempotent.
    public func start() {
        queue.sync {
            if timer != nil { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(Self.tickMs), leeway: .milliseconds(50))
            t.setEventHandler { [weak self] in self?.step() }
            timer = t
            t.resume()
        }
    }

    /// Stops the sender and clears the key copies.
    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            clearKeys()
        }
    }

    /// One tick of the sender (tests call it by hand).
    func tick() {
        queue.sync { step() }
    }

    /// Waits until what was handed over has been handled (tests).
    func flush() {
        queue.sync {}
    }

    private func clearKeys() {
        lastKey?.resetBytes(in: 0..<(lastKey?.count ?? 0))
        previousKey?.resetBytes(in: 0..<(previousKey?.count ?? 0))
        lastKey = nil
        previousKey = nil
    }

    /// The current key, as a copy; the key that it replaced is kept as the previous one.
    private func track() -> (current: Data, previous: Data?)? {
        guard let now = keys(), !now.isEmpty else { return nil }
        if let last = lastKey, last != now {
            previousKey?.resetBytes(in: 0..<(previousKey?.count ?? 0))
            previousKey = last
        }
        lastKey = Data(now)
        return (Data(now), previousKey.map { Data($0) })
    }

    private func step() {
        guard var k = track() else { return } // no session key yet: nothing is sent, the next tick tries again
        defer {
            k.current.resetBytes(in: 0..<k.current.count)
        }
        let now = local()
        if now != lastSent { // a flag or route change (or the start): a new series, at once
            lastSent = now
            remaining = Self.series
            ticksToNext = 0
        }
        if remaining <= 0 { return }
        if ticksToNext > 0 {
            ticksToNext -= 1
            return
        }
        remaining -= 1
        ticksToNext = Self.seriesPeriodTicks - 1
        let f = VoiceVconsCodec.Fields(
            seq: nextSeq, allow: true, withdraw: false,
            learning: now.flags & VoiceVconsCodec.flagLearning != 0, verifying: now.flags & VoiceVconsCodec.flagVerifying != 0,
            routeClass: now.routeClass, platform: VoiceVconsCodec.platformIos, unixMs: nowMs())
        guard let sealed = VoiceVconsCodec.seal(sessionKey: k.current, callId: callId, fields: f) else { return }
        nextSeq &+= 1
        send(Self.prefix + sealed)
    }

    /// One message from the registered peer: the string after `VCONS:`.
    public func onReceived(_ sealed: String) {
        queue.async { [self] in
            guard var k = track() else {
                onDropped("tag")
                return
            }
            defer {
                k.current.resetBytes(in: 0..<k.current.count)
                if var p = k.previous { p.resetBytes(in: 0..<p.count) }
            }
            switch VoiceVconsCodec.open(current: k.current, previous: k.previous, callId: callId, string: sealed) {
            case .rejected(let reason):
                onDropped(reason)
            case .ok(let f):
                accept(f)
            }
        }
    }

    private func accept(_ f: VoiceVconsCodec.Fields) {
        let newest = peerSeq == nil || f.seq > peerSeq!
        if newest { peerSeq = f.seq }
        let restricts = !f.allow || f.withdraw
        if !newest && !restricts { return } // an older message that restricts nothing
        onPeer(f)
    }
}
