import Foundation

/// Pure rules of the signalling socket's keepalive: when to send a ping and when the socket is declared dead.
/// All times are seconds on one clock (the client uses the reference date).
///
/// A socket is dead when a ping has been outstanding for `pongTimeout`, measured from the FIRST unanswered
/// ping (no further ping is sent while one is outstanding, so its send time is never moved), or, as a
/// backstop, when nothing at all has arrived for `pingInterval + pongTimeout`.
enum WebSocketKeepalivePolicy {

    enum Action: Equatable {
        case wait
        case sendPing
        case declareDead
    }

    /// Smallest tick that keeps the dead verdict within about one tick of its deadline without waking the
    /// radio needlessly: a sixth of the pong timeout, between 5 s and the ping interval.
    static func tickInterval(ping: TimeInterval, pongTimeout: TimeInterval) -> TimeInterval {
        let sixth: TimeInterval = pongTimeout / 6.0
        let finest: TimeInterval = max(5.0, sixth)
        let capped: TimeInterval = min(ping, finest)
        return max(1.0, capped)
    }

    /// `lastInbound`: time of the last frame of any kind received. `lastPingSent`: time of the oldest ping not
    /// answered yet, or of the last ping when all were answered (0 when none was sent on this client yet).
    static func decide(now: TimeInterval,
                       lastInbound: TimeInterval,
                       lastPingSent: TimeInterval,
                       pingInterval: TimeInterval,
                       pongTimeout: TimeInterval) -> Action {
        let pingOutstanding: Bool = lastPingSent > lastInbound
        let sincePing: TimeInterval = now - lastPingSent
        let silence: TimeInterval = now - lastInbound
        let silenceLimit: TimeInterval = pingInterval + pongTimeout
        if pingOutstanding && sincePing >= pongTimeout {
            return .declareDead
        }
        if silence > silenceLimit {
            return .declareDead
        }
        if pingOutstanding {
            return .wait
        }
        if sincePing >= pingInterval {
            return .sendPing
        }
        return .wait
    }
}
