import Foundation

/// 2026-09-19 service-message root fix — when is a CONTROL session that is
/// PRESENT but keeps failing worth dropping?
///
/// One failed 0xE6 frame proves nothing: it can be a replay, a frame sealed
/// under a session the peer has just replaced, or one that raced ahead of the
/// pre-bootstrap that installs its session. Dropping a healthy CONTROL session
/// from a single failure is exactly the churn this fix removes (live
/// 2026-09-19 08:49). A session that has really diverged fails EVERY frame, so
/// the repair waits for ``quorum`` DISTINCT failed frames inside ``windowMs``,
/// and then holds off for ``cooldownMs`` so a repair cannot itself become a
/// storm. Repair is only the existing drop-then-ensure step; this type only
/// decides when.
///
/// Pure value type; the caller passes `nowMs`.
public struct ControlFailureTracker: Equatable, Sendable {

    public static let quorum: Int = 3
    public static let windowMs: Int64 = 120_000
    public static let cooldownMs: Int64 = 600_000

    private struct Failure: Equatable, Sendable {
        let frameId: String
        let atMs: Int64
    }

    private var failures: [String: [Failure]] = [:]
    private var lastRepairMs: [String: Int64] = [:]

    public init() {}

    /// Records one failed CONTROL frame from `peerId`. Returns `true` exactly
    /// when the quorum is reached and the caller should repair now.
    public mutating func record(peerId: String, frameId: String, nowMs: Int64) -> Bool {
        var list = (failures[peerId] ?? []).filter { nowMs - $0.atMs < Self.windowMs }
        if !list.contains(where: { $0.frameId == frameId }) {
            list.append(Failure(frameId: frameId, atMs: nowMs))
        }
        if let last = lastRepairMs[peerId], nowMs - last < Self.cooldownMs {
            failures[peerId] = list
            return false
        }
        if list.count >= Self.quorum {
            failures.removeValue(forKey: peerId)
            lastRepairMs[peerId] = nowMs
            return true
        }
        failures[peerId] = list
        return false
    }

    /// A frame from `peerId` opened: the session is fine, forget the failures.
    public mutating func recordSuccess(peerId: String) {
        failures.removeValue(forKey: peerId)
    }

    /// Whether ONE failed CONTROL frame is evidence about the session that is
    /// installed NOW, i.e. whether the caller may feed it to ``record``.
    ///
    /// A quorum of failed frames is only meaningful if each of them was
    /// really opened against the current session and did not fit it:
    /// - a frame that did not arrive live (a `msg_pending_sync` replay) can be
    ///   older than the session installed since, and fails by construction;
    /// - a frame whose server timestamp predates the install was sealed before
    ///   this session existed here (an earlier session, or the peer's new one
    ///   sealing ahead of the pre-bootstrap that installs it on this side);
    /// - a frame with no server timestamp cannot be placed, so a session
    ///   younger than ``windowMs`` gets the benefit of the doubt.
    /// Three of those used to reach the quorum, drop a healthy session and start
    /// a ping-pong with the peer's own repair.
    ///
    /// `sessionInstalledAtMs` is `nil` when this process never installed the
    /// session (it predates the launch): there is nothing to compare with, so
    /// a live frame counts.
    public static func isEvidence(
        arrivedLive: Bool,
        serverTimestampMs: Int64?,
        sessionInstalledAtMs: Int64?,
        nowMs: Int64
    ) -> Bool {
        guard arrivedLive else { return false }
        guard let installedAt = sessionInstalledAtMs else { return true }
        if let sealedAt = serverTimestampMs {
            return sealedAt >= installedAt
        }
        return nowMs - installedAt >= windowMs
    }
}
