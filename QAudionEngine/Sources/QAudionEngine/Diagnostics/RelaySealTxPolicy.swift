import Foundation

/// W-M15ORDER (2026-10-03) — what the relay sender does with one outgoing frame, given whether
/// the call negotiated the M-15 per-direction relay seal (`srtpDirKeyV1`) and whether the send
/// sealer already exists.
///
/// Why this is a decision of its own: once a call negotiated M-15 the PEER's receive sealer is
/// installed (the callee installs it while ringing). A frame that reaches it UNSEALED can never
/// authenticate, and it is not harmless: the old receiver recorded the counter it read from the
/// frame's (random) inner-nonce bytes before it verified anything, so one such frame pushed the
/// replay window's highest counter to a huge value and every later sealed frame was rejected as
/// "too old" for the whole call (three live calls, 28/9 and 3/10). The send sealer is
/// installed a few milliseconds after the engine gets its session key, so the first mic frame
/// (and an early hang-up or NACK control frame) could go out before it. The rule: when M-15 is
/// negotiated and the sealer is missing, the frame is HELD (dropped and counted), never sent
/// plain. When M-15 was not negotiated (legacy peer, or `srtpDirKeyV1` off) the relay stays
/// plain, exactly as before (`PqcRtpFrameSealer` is then not part of the call at all).
public enum RelaySealTxPolicy {

    public enum Decision: Equatable {
        /// A send sealer exists: seal the frame and send it.
        case seal
        /// No M-15 on this call: send the frame as it is (pre-existing behaviour).
        case sendPlain
        /// M-15 negotiated but the sealer is not installed yet: do not send the frame.
        case hold
    }

    /// - Parameters:
    ///   - m15Negotiated: both peers advertised `srtpDirKeyV1` for this call
    ///     (`QAudionCallIntegration.negotiatedSrtpDirKey`, set when the handshake bundle is
    ///     received, i.e. BEFORE the engine holds a session key).
    ///   - sealerInstalled: `relaySealerSend != nil`.
    public static func decide(m15Negotiated: Bool, sealerInstalled: Bool) -> Decision {
        if sealerInstalled { return .seal }
        return m15Negotiated ? .hold : .sendPlain
    }

    /// The bytes that may go on the wire for `frame`, or nil when the frame must NOT be sent:
    /// held (M-15 negotiated, no sealer yet) or the seal itself failed. A frame is never sent plain
    /// once the call negotiated M-15 or a sealer exists.
    public static func frameForWire(
        _ frame: Data, m15Negotiated: Bool, sealer: PqcRtpFrameSealer?
    ) -> Data? {
        switch decide(m15Negotiated: m15Negotiated, sealerInstalled: sealer != nil) {
        case .seal:
            guard let sealer = sealer else { return nil }
            return try? sealer.seal(frame)
        case .sendPlain:
            return frame
        case .hold:
            return frame   // TEMP-MUTANT-M3: sends the frame plain while held
        }
    }
}
