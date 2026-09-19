import Foundation

/// W-RXGATE (2026-09-19) — what an inbound audio frame that failed to decode
/// MEANS, so that only a real decrypt failure is treated as one.
///
/// The receive path used to count every error thrown by
/// `QAudionEngine.processIncomingAudio` as an "AEAD decrypt failure": it fed
/// `rx_dec_err`, the post-call `AudioAutoTuner` (which persists a new PLP for
/// the NEXT call from `errors / received`) and `AudioAeadFailureRekeyMeter`
/// (whose burst forces a mid-call PQC re-key). But one of the errors it throws
/// is not a decrypt failure at all: `.noActiveSession`, thrown while this side
/// has no session key yet.
///
/// That state is routine for the CALLER. The callee derives its key when it
/// processes the OFFER and starts sending as soon as it answers, while the
/// caller only derives its own key when the ACCEPT has been processed. Any
/// delay in between (a caller app that is inactive for a few seconds, a slow
/// callee cold start) means seconds of the callee's audio reach a caller that
/// cannot open it yet. Field evidence, call bf0bfc55 on 2026-09-19: the callee
/// answered at 17:22:36.2, the caller processed the ACCEPT at 17:22:40.3, and
/// 74 of 185 inbound frames (4.4 s at 16.7 frames/s is 73) were counted as
/// decrypt errors. That produced a 40% "loss" that made the tuner write
/// PLP 40 for the next call, and a burst of failures that asked for a re-key
/// 0.26 s after the session came up, which cost the callee 10 more frames.
///
/// The transmit side already separates the mirror case (`tx_pre_hs`,
/// W-TXGATE: frames dropped before the session key exists are not
/// `tx_enc_err`). This is the receive-side twin.
///
/// A genuinely drifted key still fails as an AEAD authentication error, which
/// classifies as `.decrypt` and keeps feeding the burst meter unchanged. In this
/// code base the engine leaves `.sessionActive` only when a call site ends the
/// session (`destroySession`/`release`); a re-key round never lowers it. So a
/// frame that throws `.noActiveSession` is never evidence about the live key.
public enum RxDecodeFailureKind: Equatable {

    /// The frame reached the decoder while this side had no session: not yet
    /// established (this includes an engine that was never initialised) or
    /// already ended. Expected and not a fault: drop it,
    /// count it apart (`rx_pre_hs`), and do not let it reach the failure
    /// burst meter or the loss estimate.
    case preSession

    /// Anything else the receive path throws: an AEAD authentication failure,
    /// a malformed or replayed frame, or an active engine whose key material is
    /// missing. These are real and keep their existing handling.
    case decrypt

    public static func classify(_ error: Error) -> RxDecodeFailureKind {
        if let engineError = error as? QAudionEngineError,
           case .noActiveSession = engineError {
            return .preSession
        }
        return .decrypt
    }
}
