import Foundation
import CoreGraphics
import os
#if canImport(WebRTC)
import WebRTC
#endif

/// VIDEODIAG (WIRE_SPEC §8.7) — per-call video-path counters for the
/// self-heal watchdog. One log line pinpoints the broken hop, same
/// diagnostic philosophy as MEDIADIAG on Android/Desktop:
///
///   transport in (rxVideoFramesArrived) → cryptor open → decoder out
///   (rxFramesDecoded) → renderer drew (rxFramesRendered)
///
/// NEVER-BLOCK: counters are bumped on EXISTING hot paths only — the
/// per-frame render callback increments through a single
/// `os_unfair_lock` (`OSAllocatedUnfairLock`: non-allocating,
/// uncontended CAS fast-path; the closest primitive to a lock-free
/// atomic available without the swift-atomics dependency — see
/// SFrameVideoSealer's same note). No per-frame task spawning, zero
/// allocation on the increment path. Arrival/decode counts ride the
/// controller's EXISTING 3 s stats poll (`video.stats` telemetry),
/// not a new poller.
final class VideoPathDiag: @unchecked Sendable {

    struct Snapshot {
        /// Inbound video frames at the transport/RTP hop (stats
        /// `framesReceived`, delta-merged across cumulative resets,
        /// -1-sentinel-safe; monotonic — adds are never negative).
        var rxVideoFramesArrived: Int64 = 0
        /// Inbound frames out of the decoder (stats `framesDecoded`,
        /// same delta merge).
        var rxFramesDecoded: Int64 = 0
        /// Frames the REAL UI renderer actually consumed (counted by the
        /// forwarding wrapper WebRTCRemoteVideoView attaches around
        /// RTCMTLVideoView — renderer detached ⇒ this counter stops).
        var rxFramesRendered: Int64 = 0
        /// Local encoder IDRs forced by the §8.7 honor/self-heal paths.
        var txKeyframesForced: Int64 = 0
        /// Monotonic ms of the last inbound `call_media_ready`; 0 = never.
        var lastPeerMediaReadyAtMs: Int64 = 0
        /// Monotonic ms of the last outbound `video_keyframe_request`
        /// attempt; 0 = never.
        var lastKeyframeRequestAtMs: Int64 = 0
        /// Previous cumulative `framesReceived` / `framesDecoded` stats
        /// totals — merge bases for reset detection across mid-call
        /// controller/PeerConnection rebuilds; -1 = no sample yet.
        /// Merge state, NOT hop counters (Android
        /// VideoPathDiag.statsFramesRecBase/DecBase parity).
        var statsFramesRecBase: Int64 = -1
        var statsFramesDecBase: Int64 = -1
    }

    private let state = OSAllocatedUnfairLock(initialState: Snapshot())

    /// Monotonic clock (same source as KeyframeForcingVideoEncoder.nowMs —
    /// wall-clock jumps must not fake or starve any window).
    static func nowMs() -> Int64 {
        return Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    // MARK: - Increments (existing choke points)

    /// Per-frame render hot path (DiagForwardingVideoRenderer.renderFrame).
    func noteFrameRendered() {
        state.withLock { $0.rxFramesRendered += 1 }
    }

    /// Fed from the controller's EXISTING `video.stats` telemetry poll
    /// (3 s cadence). WebRTC totals are CUMULATIVE per PeerConnection and
    /// a mid-call controller rebuild (video-upgrade wiring sites) restarts
    /// them at 0 — so merge by DELTA against the previous sample (Android
    /// VideoPathDiag.publishWebrtcInboundTotals parity): a new total BELOW
    /// the previous one is a counter reset and re-bases, contributing the
    /// fresh total as all-new frames — never a rollback. The old
    /// max()-merge would FREEZE the counters after a rebuild until the new
    /// totals out-grew the pre-rebuild max, making stalls undetectable
    /// exactly in the post-upgrade window. -1 sentinels are still ignored
    /// and every add is >= 0, so the counters stay monotonic.
    func noteVideoStats(kind: String, attrs: [String: Any]) {
        guard kind == "video.stats" else { return }
        let rec = (attrs["in_frames_rec"] as? Int) ?? -1
        let dec = (attrs["in_frames_dec"] as? Int) ?? -1
        guard rec >= 0 || dec >= 0 else { return }
        state.withLock { s in
            if rec >= 0 {
                s.rxVideoFramesArrived += Self.cumulativeContribution(
                    newTotal: Int64(rec), prevTotal: &s.statsFramesRecBase)
            }
            if dec >= 0 {
                s.rxFramesDecoded += Self.cumulativeContribution(
                    newTotal: Int64(dec), prevTotal: &s.statsFramesDecBase)
            }
        }
    }

    /// Merge one cumulative stats total against its previous sample:
    /// monotonic advance contributes the delta; a first sample (prev -1)
    /// or a cumulative reset (new < prev — fresh PeerConnection after a
    /// mid-call controller rebuild) contributes the whole new total as a
    /// fresh base. Never returns a negative contribution. `newTotal` must
    /// already be >= 0 (the -1 sentinel is filtered by the caller).
    private static func cumulativeContribution(
        newTotal: Int64, prevTotal: inout Int64) -> Int64 {
        defer { prevTotal = newTotal }
        if prevTotal >= 0 && newTotal >= prevTotal {
            return newTotal - prevTotal
        }
        return newTotal
    }

    func noteTxKeyframeForced() {
        state.withLock { $0.txKeyframesForced += 1 }
    }

    func notePeerMediaReady() {
        let now = Self.nowMs()
        state.withLock { $0.lastPeerMediaReadyAtMs = now }
    }

    func noteKeyframeRequested() {
        let now = Self.nowMs()
        state.withLock { $0.lastKeyframeRequestAtMs = now }
    }

    // MARK: - Read / reset

    func snapshot() -> Snapshot {
        return state.withLock { $0 }
    }

    /// Per-call reset (hangup / video-leg rollback).
    func reset() {
        state.withLock { $0 = Snapshot() }
    }
}

#if canImport(WebRTC)
/// Counting FORWARDING renderer wrapped around the REAL UI renderer
/// (RTCMTLVideoView). It is the ONLY sink WebRTCRemoteVideoView attaches to
/// the remote track: it bumps the rendered-hop counter, then forwards the
/// frame to the wrapped view. Counting AT the real renderer (not beside it)
/// is load-bearing for the §8.7 watchdog: libwebrtc feeds EVERY attached
/// sink, so a standalone side-sink would keep counting while the actual UI
/// renderer is detached — hiding exactly the detached-renderer black-video
/// class that rung 2 (sink re-attach) exists to heal. Invariant: real
/// renderer detached (or deallocated) ⇒ this wrapper stops counting ⇒ the
/// stall latches ⇒ rung 2 re-publishes the track and SwiftUI re-attaches.
/// NEVER-BLOCK: zero allocation per frame — one unfair-lock add plus a
/// direct forward on WebRTC's render thread (the same thread that fed the
/// view when it was attached directly).
final class DiagForwardingVideoRenderer: NSObject, RTCVideoRenderer {
    private let diag: VideoPathDiag
    /// Weak: the UI owns the view. If SwiftUI deallocates it while this
    /// wrapper is still attached to the track, frames stop being counted
    /// too — a dead renderer must never look alive to the watchdog.
    private weak var target: RTCVideoRenderer?

    init(diag: VideoPathDiag, forwarding target: RTCVideoRenderer) {
        self.diag = diag
        self.target = target
        super.init()
    }

    func setSize(_ size: CGSize) {
        target?.setSize(size)
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let target = target else { return }  // renderer gone ⇒ counter stops
        if frame != nil { diag.noteFrameRendered() }
        target.renderFrame(frame)
    }
}
#endif
