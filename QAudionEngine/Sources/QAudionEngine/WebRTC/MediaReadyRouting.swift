import Foundation

/// R-READY (WIRE_SPEC §8.7) — what an inbound `call_media_ready` means.
///
/// Two different announcements travel under the same message:
///
/// - the FIRST-VIDEO ready ("my video receiver cryptor is keyed and bound to the negotiated mid"):
///   the sender releases its video TX-hold and forces an IDR. It carries the video `mid`, and its
///   `key_epoch` is the key round epoch `E` of the key the receiver was keyed with, which is NOT 0
///   for a call that starts audio-only and upgrades to video in a later round;
/// - a REKEY ready ("I installed your new round for this media kind"): the peer may switch its own
///   sender of that kind to epoch `E`. It carries NO `mid`.
///
/// `key_epoch > 0` alone cannot tell them apart. Before this rule a first-video ready whose `E`
/// happened to equal the epoch a video rekey gate was armed for was taken as the rekey ready, so
/// the TX-hold release and the forced IDR were skipped. The rekey reading is therefore taken only
/// for a ready that has no `mid` (video) AND matches the epoch the gate is actually armed for.
public enum MediaReadyRouting {

    public enum Route: Equatable {
        /// A rekey ready for exactly the epoch the gate of `media` is armed for: try the sender
        /// switch and stop.
        case rekeyReady(media: String, epoch: Int32)
        /// The first-video ready (or a stall-recovery re-announce of it): release the TX-hold and
        /// force the IDR.
        case firstVideoReady
        /// Nothing to do (an audio ready that is not the rekey this side is waiting on).
        case ignore
    }

    /// - Parameters:
    ///   - media: the wire `media` field (`"audio"` or `"video"`; anything else counts as video,
    ///     which is what a peer that predates the field meant).
    ///   - mid: the wire `mid` (empty when absent).
    ///   - keyEpoch: the wire `key_epoch`.
    ///   - armedEpoch: the epoch the sender-switch gate of the given media kind is armed for, or
    ///     a negative number when it is not armed.
    public static func route(
        media: String, mid: String, keyEpoch: Int, armedEpoch: (String) -> Int32
    ) -> Route {
        let kind = (media == "audio") ? "audio" : "video"
        if keyEpoch > 0,
           let epoch = Int32(exactly: keyEpoch),
           kind == "audio" || mid.isEmpty,
           armedEpoch(kind) == epoch {
            return .rekeyReady(media: kind, epoch: epoch)
        }
        // An audio ready never carries first-video meaning (no TX-hold release, no IDR).
        return kind == "audio" ? .ignore : .firstVideoReady
    }
}
