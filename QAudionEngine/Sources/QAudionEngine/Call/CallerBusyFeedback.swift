import Foundation

/// W-BUSYHOLD (2026-10-04) — how long the caller SEES "Occupato" and HEARS the busy tone after the callee answered
/// `call_busy`, and the state of that showing as a pure value so the whole life of it can be tested without `AppState`.
///
/// ## Why one constant
///
/// The owner decision is 4000 ms, the same as Android: long enough to read the word and to hear the tone, short
/// enough not to feel stuck. #169 shipped 3 s, and the three things that must agree on the number each had their own
/// copy of it: the outcome hold (`CallerTerminalOutcome.holdSeconds`), the length of the tone buffer
/// (`QAudionSynth.busyToneSeconds`, three 1 s bursts) and the delay after which the app disposes the system sound that
/// plays it (`CallerBusyTone`, 3.5 s). Moving only the first would have left a tone that ends a second before the
/// screen does, and moving the tone without the third would have had the app cut its own last burst. All three now
/// derive from ``holdMs``.
public enum CallerBusyFeedback {

    /// How long the "Occupato" screen stays up and the busy tone sounds (owner decision, same as Android).
    public static let holdMs: Int = 4_000

    /// ``holdMs`` in seconds.
    public static var holdSeconds: TimeInterval { TimeInterval(holdMs) / 1_000 }

    /// One burst of the 425 Hz signal plus its pause: 0.5 s on, 0.5 s off.
    public static let toneCycleMs: Int = 1_000

    /// How many bursts fill the hold exactly: the tone is as long as the screen, never shorter.
    public static var toneRepetitions: Int { holdMs / toneCycleMs }

    /// The app disposes the system sound that plays the tone this long AFTER the hold (a sound id that outlives its
    /// tone is a leak; one disposed before the tone ended cuts its last burst).
    public static let soundDisposeGraceMs: Int = 500

    /// When the system sound is disposed, measured from the moment it starts playing.
    public static var soundDisposeAfterMs: Int { holdMs + soundDisposeGraceMs }
}

/// W-BUSYHOLD — the outcome screen of the caller (busy / unreachable callee) from the moment it is shown to the moment
/// it closes, one showing at a time.
///
/// ## What it guarantees
///
/// - **First terminal wins.** A call has one outcome. Asking to show another one for the SAME call (a duplicate
///   `call_busy`, or a `call_peer_offline` after it) answers ``ShowResult/alreadyShown``: the first showing keeps its
///   screen, its tone and its clock. On Android a second terminal state of the same call overwrote the busy one and
///   the screen closed at once; the id gate in front of the iOS handlers already drops such an envelope, and this is
///   the second line behind it.
/// - **A timer closes only its own showing.** Every showing has a serial; a hold timer of an earlier showing finds the
///   serial gone and does nothing, so it can neither close a later outcome early nor re-close a closed one.
/// - **Nothing else closes it.** The only ways out are the hold timer and ``close(by:nowMs:)`` (the close button, a
///   redial). A teardown, a second `endCall`, a late CallKit callback have no way in: they do not know this value.
///
/// Time is injected (`nowMs`, milliseconds on any clock that only moves forward; only differences are read), so the
/// tests run without waiting.
public struct CallerOutcomeHold: Equatable, Sendable {

    /// Why a showing closed.
    public enum CloseReason: String, Equatable, Sendable {
        /// The hold elapsed.
        case timeout
        /// The user closed it, or started another call (which is the user acting).
        case user
        /// Another call's outcome took the screen while this one was still up. Should not happen (a redial closes
        /// the previous showing first); the showing is closed, never left dangling, and the log says so.
        case replaced
    }

    /// One showing of an outcome.
    public struct Showing: Equatable, Sendable {
        public let outcome: CallerTerminalOutcome
        /// The wire call id, lowercased.
        public let callId: String
        /// Identifies this showing to its hold timer.
        public let serial: Int
        public let shownAtMs: Int

        /// How long this showing stays up.
        public var holdMs: Int { outcome.holdMs }

        /// The log line for the moment it is shown. No PII: the first 8 characters of the call id, as every other call
        /// log line.
        public var shownLine: String {
            "\(outcome.feedbackLogLabel) feedback shown call=\(Self.shortId(callId)) holdMs=\(holdMs)"
        }

        static func shortId(_ id: String) -> String { String(id.prefix(8)) }
    }

    /// A showing that has closed.
    public struct Closed: Equatable, Sendable {
        public let outcome: CallerTerminalOutcome
        public let callId: String
        public let by: CloseReason
        /// How long it was up, in milliseconds.
        public let heldMs: Int

        public var closedLine: String {
            "\(outcome.feedbackLogLabel) feedback closed call=\(Showing.shortId(callId)) by=\(by.rawValue) ms=\(heldMs)"
        }
    }

    public enum ShowResult: Equatable, Sendable {
        /// A new showing began (play the tone, schedule the hold timer for `showing.holdMs` with `showing.serial`).
        /// `replaced` is the showing it took over from, closed, when there was one.
        case started(Showing, replaced: Closed?)
        /// This call's outcome is already on screen: change nothing, restart nothing.
        case alreadyShown
    }

    /// The showing on screen, `nil` when none.
    public private(set) var showing: Showing?
    private var serial: Int = 0

    public init() {}

    /// The caller-side terminal envelope of `callId` was acted on: put its outcome on screen.
    public mutating func show(_ outcome: CallerTerminalOutcome, callId: String, nowMs: Int) -> ShowResult {
        let id = callId.lowercased()
        var replaced: Closed?
        if let current = showing {
            if !id.isEmpty && current.callId == id { return .alreadyShown }
            replaced = Closed(
                outcome: current.outcome, callId: current.callId, by: .replaced, heldMs: max(0, nowMs - current.shownAtMs))
        }
        serial &+= 1
        let next = Showing(outcome: outcome, callId: id, serial: serial, shownAtMs: nowMs)
        showing = next
        return .started(next, replaced: replaced)
    }

    /// The hold timer of the showing `serial` fired. Closes it when it is still the one on screen; `nil` for a timer
    /// of an earlier showing or of one that already closed.
    public mutating func holdElapsed(serial: Int, nowMs: Int) -> Closed? {
        guard let current = showing, current.serial == serial else { return nil }
        showing = nil
        return Closed(
            outcome: current.outcome, callId: current.callId, by: .timeout, heldMs: max(0, nowMs - current.shownAtMs))
    }

    /// Closes whatever is on screen (the close button, a redial). `nil` when nothing is.
    public mutating func close(by reason: CloseReason, nowMs: Int) -> Closed? {
        guard let current = showing else { return nil }
        showing = nil
        return Closed(
            outcome: current.outcome, callId: current.callId, by: reason, heldMs: max(0, nowMs - current.shownAtMs))
    }
}
