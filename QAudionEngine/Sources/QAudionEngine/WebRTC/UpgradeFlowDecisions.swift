import Foundation

/// WIRE_SPEC §8 — pure decision helpers for the mid-call media-upgrade
/// state machine. These are the platform-independent CHOICES the upgrade
/// flow makes; they contain NO WebRTC / PeerConnection state so they can be
/// unit-tested directly against `tools/kat/upgrade-flow/upgrade-flow-kat.json`
/// (see `UpgradeFlowKatTests.swift`) without a live call.
///
/// AppState wires the imperative side effects (ship SDP, start camera,
/// rollback the PC) around these decisions; keeping the branch logic here
/// means the KAT vectors gate the exact same code the app runs.
///
/// Cross-platform sisters: Android `CallUpgradeDecisions.kt` / Desktop
/// `upgradeDecisions.ts` (same rules, §8.2/§8.3/§8.7).
public enum UpgradeFlowDecisions {

    // MARK: - Aligned timeouts (WIRE_SPEC §8.2)

    /// Requester watchdog for our own outbound `call_upgrade_request`.
    public static let requesterWatchdogSeconds: Int = 30
    /// Responder auto-decline for an un-answered incoming consent prompt.
    /// ALIGNED with the requester watchdog per §8.2 (both 30s).
    public static let responderAutoDeclineSeconds: Int = 30

    // MARK: - Media consent routing (WIRE_SPEC §8.1)

    /// What to do with an incoming `call_upgrade_request` given its `media`
    /// tag. `"screen"` auto-accepts (viewing exposes nothing of ours);
    /// `"camera"` requires explicit consent; ANY OTHER / unknown value is
    /// treated as `"camera"` (fail-safe: consent required — §8.1).
    public enum MediaConsent: Equatable {
        /// Show the consent dialog, open no camera until the user decides.
        case requireConsent
        /// Answer immediately, never open the local camera.
        case autoAccept
    }

    public static func resolveMediaConsent(media: String) -> MediaConsent {
        return media == "screen" ? .autoAccept : .requireConsent
    }

    // MARK: - Renegotiation controller strategy (WIRE_SPEC §8.7, W-SPKAEC)

    /// Which controller-side action to take when a mid-call media
    /// renegotiation (`call_upgrade_request`, camera OR screen) is being
    /// answered. Both `acceptPendingIncomingUpgrade` (camera) and
    /// `acceptIncomingScreenShareRenegotiation` (screen) drive this same
    /// decision from the same two inputs: whether a live WebRTC controller
    /// already exists, and whether the peer actually sent SDP.
    public enum RenegotiationControllerStrategy: Equatable {
        /// `sdp` is empty — no real WebRTC renegotiation is in flight for
        /// this accept (e.g. the iOS↔iOS WS-relay path, where the peer's
        /// own controller build/announce carries the video). Answer with
        /// the empty-SDP "accept without renegotiation" escape hatch; do
        /// NOT touch any controller.
        case noRenegotiation
        /// A live PeerConnection controller already exists — renegotiate on
        /// it directly (`acceptUpgradeOffer`).
        case useExisting
        /// `sdp` is non-empty but no controller exists yet — typical for an
        /// audio-only call carried on the WS-relay path (its audio never
        /// built a WebRTC PeerConnection). One must be built on-demand
        /// BEFORE answering (`acceptUpgradeOfferBuildingPeerConnection`);
        /// falling through to the empty-SDP escape hatch here is the bug
        /// this case exists to prevent — the peer sent a REAL offer
        /// expecting a REAL answer, and an empty answer makes the peer's
        /// libwebrtc throw on `setRemoteDescription` and abort the
        /// renegotiation on both ends.
        case buildOnDemand
    }

    public static func resolveRenegotiationControllerStrategy(
        hasExistingController: Bool, sdp: String
    ) -> RenegotiationControllerStrategy {
        guard !sdp.isEmpty else { return .noRenegotiation }
        return hasExistingController ? .useExisting : .buildOnDemand
    }

    // MARK: - Glare resolution (WIRE_SPEC §8.3)

    /// Which side of the call the local endpoint originally was. Politeness
    /// is keyed to the ORIGINAL call role, NOT the upgrade role.
    public enum CallRole: Equatable {
        /// We placed the call (impolite on glare).
        case caller
        /// We answered the call (polite on glare).
        case callee
    }

    /// The action to take when a peer's `call_upgrade_request` collides with
    /// our own in-flight upgrade request.
    public enum GlareResolution: Equatable {
        /// Polite (original callee): JSEP-rollback our pending local offer,
        /// then accept the peer's offer; treat our own request as satisfied.
        case politeAcceptPeer
        /// Impolite (original caller): ignore the peer's colliding request
        /// (send NO decline) and wait for the response to our own.
        case impoliteIgnorePeer
    }

    /// Resolve a glare collision from the ORIGINAL call role (§8.3):
    /// polite = original CALLEE, impolite = original CALLER.
    public static func glareResolution(callRole: CallRole) -> GlareResolution {
        switch callRole {
        case .callee: return .politeAcceptPeer
        case .caller: return .impoliteIgnorePeer
        }
    }

    // MARK: - Phantom transceiver (WIRE_SPEC §8.6)

    /// Decide whether an inbound video track on `incomingMid` should be
    /// bound as the render sink + receiver-cryptor, or IGNORED as a phantom.
    ///
    /// - `establishedMid`: the mid the receiver is already bound to (nil if
    ///   none established yet).
    /// - `incomingMid`: the mid the new track arrived on.
    /// - `transceiverIsRecvOnly`: true when the new transceiver is RECV_ONLY
    ///   with no sender track (the M144 phantom signature).
    /// - `establishedTransceiverStopped`: true when the previously-bound
    ///   transceiver has been stopped (legitimate re-latch case §8.6).
    ///
    /// Returns the mid the sink + cryptor should be bound to AFTER this
    /// event (unchanged for a phantom; the new mid for a legitimate relatch).
    public enum SinkBinding: Equatable {
        /// Ignore the incoming track; keep the existing binding.
        case keepPhantomIgnored(mid: String?)
        /// Re-latch sink + cryptor onto the new mid.
        case relatch(mid: String)
        /// First video for this call — bind to the incoming mid.
        case bindInitial(mid: String)
    }

    public static func resolveSinkBinding(
        establishedMid: String?,
        incomingMid: String,
        transceiverIsRecvOnly: Bool,
        establishedTransceiverStopped: Bool
    ) -> SinkBinding {
        // No established video yet → this is the first, bind it.
        guard let established = establishedMid else {
            return .bindInitial(mid: incomingMid)
        }
        // Same mid as the established binding → nothing changes.
        if established == incomingMid {
            return .keepPhantomIgnored(mid: established)
        }
        // Different mid, and the established transceiver is gone → the video
        // legitimately moved; re-latch (§8.6 "new mid after stop").
        if establishedTransceiverStopped {
            return .relatch(mid: incomingMid)
        }
        // Different mid, established still live, incoming is RECV_ONLY with no
        // sender track → phantom (M144). Keep the established binding (§8.6:
        // "Last receiver wins" sink policies are forbidden).
        if transceiverIsRecvOnly {
            return .keepPhantomIgnored(mid: established)
        }
        // Different mid, established still live, incoming is a real sendrecv
        // track (unusual but not a phantom) → re-latch to it.
        return .relatch(mid: incomingMid)
    }
}
