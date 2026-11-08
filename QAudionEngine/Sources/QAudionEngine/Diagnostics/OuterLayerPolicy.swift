import Foundation

/// The outer seal of the sealed-audio legs, as one call-wide decision.
///
/// Sealed audio travels on two legs that carry the same bytes: the sealed-audio DataChannel (inside the
/// PeerConnection's DTLS) and the WS relay. The outer seal (`relaySealerSend` / `relaySealerRecv`) is a property of
/// the call, not of a leg. This policy says, for one frame, what each leg may do with it. It is pure so the rules
/// can be tested without a call.
public enum OuterLayerMode: Equatable, Sendable {
    /// The handshake has not told us yet (no peer bundle seen): behave as before, nothing is held.
    case unknown
    /// Both peers negotiated the per-direction outer keys: every frame on both legs is sealed.
    case sealed
    /// The peer does not take part in the outer seal. The DataChannel carries the inner-sealed frames inside DTLS; the relay leg is not armed.
    case noOuter
    /// This side could not install its outer sealer: same as `.noOuter` for the call.
    case offLocalInstall
    /// The peer told us on the DataChannel that it could not install its outer sealer: same as `.noOuter` for the call.
    case offPeerInstall

    /// True for the modes in which no outer seal is applied and the relay leg is closed.
    public var isOuterOff: Bool { self == .noOuter || self == .offLocalInstall || self == .offPeerInstall }
}

public enum OuterLayerLeg: Equatable, Sendable {
    case dataChannel
    case wsRelay
}

public enum OuterLayerPolicy {

    // MARK: Send side

    public enum Tx: Equatable, Sendable {
        /// Seal with the outer sealer and send on whichever leg is up.
        case seal
        /// Sealed call, sealer not installed yet: do not send the frame.
        case hold
        /// No outer seal for this call: send the frame as it is on the DataChannel only, never on the relay.
        case plainDataChannelOnly
        /// Handshake outcome not known and no sealer: pre-existing behaviour (plain, either leg).
        case plainEitherLeg
    }

    public static func tx(mode: OuterLayerMode, sealerInstalled: Bool) -> Tx {
        switch mode {
        case .sealed:
            return sealerInstalled ? .seal : .hold
        case .unknown:
            return sealerInstalled ? .seal : .plainEitherLeg
        case .noOuter, .offLocalInstall, .offPeerInstall:
            return .plainDataChannelOnly
        }
    }

    // MARK: Receive side

    public enum Rx: Equatable, Sendable {
        /// Open with the outer sealer; a failed open drops the frame.
        case open
        /// Sealed call, sealer not installed yet: keep the frame in the bounded buffer, never deliver it raw.
        case hold
        /// Deliver the frame as it is (inner layer only).
        case passThrough
        /// Drop the frame (relay leg of a call without outer seal).
        case drop
    }

    public static func rx(mode: OuterLayerMode, leg: OuterLayerLeg, recvSealerInstalled: Bool) -> Rx {
        switch mode {
        case .sealed:
            return recvSealerInstalled ? .open : .hold
        case .unknown:
            return recvSealerInstalled ? .open : .passThrough
        case .noOuter, .offLocalInstall, .offPeerInstall:
            return leg == .dataChannel ? .passThrough : .drop
        }
    }

    // MARK: Control frame `outer-off-v1`

    /// The control frame itself: the control mux byte `0x03`, then kind `0x03`, empty body. Two bytes, so it can never be
    /// an outer-sealed frame (`nonce(12) || ct || tag(16)`, at least 28 bytes).
    public static let outerOffFrame = Data([0x03, 0x03])

    /// Smallest possible sealed frame.
    public static let minSealedFrameLength = 28

    /// True only for exactly the two bytes `0x03 0x03` that arrived on the DataChannel. The same bytes on the relay, and
    /// any other bytes, are not this frame (the caller then takes its normal path).
    public static func isOuterOffFromDataChannel(_ frame: Data, leg: OuterLayerLeg) -> Bool {
        guard leg == .dataChannel, frame.count == 2 else { return false }
        return frame == outerOffFrame
    }

    /// How many inner-sealed frames repeat the announcement after the first send.
    public static let outerOffRepeats = 3
}
