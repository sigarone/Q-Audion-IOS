import Foundation

public struct NfcExchangeViewModel: ViewModelProtocol {

    public enum State: Equatable, Sendable {
        case idle
        case waiting              // user has tapped "Start", phone listening for tag
        case exchanging           // tag detected, APDU + payload exchange in flight
        /// First tap done, nothing persisted yet; the user must confirm that the 6-digit code matches the one on
        /// the other phone before this can advance.
        case sasConfirm(sas: String, peerDeviceName: String)
        /// The code was confirmed here; the phones must be held together again to finish (second tap).
        case holdAgain(peerDeviceName: String)
        /// Second tap running.
        case confirming(peerDeviceName: String)
        /// Second tap running and the other person has not decided yet.
        case waitingForPeer(peerDeviceName: String)
        case success(peerDeviceName: String)
        /// The other person rejected; nothing was saved.
        case peerRejected(peerDeviceName: String)
        case error(message: String)

        fileprivate var rank: Int {
            switch self {
            case .idle: return 0
            case .waiting: return 1
            case .exchanging: return 2
            case .sasConfirm: return 3
            case .holdAgain: return 4
            case .confirming, .waitingForPeer: return 5
            case .success, .peerRejected, .error: return 6
            }
        }
    }

    public private(set) var state: State

    /// The 7-byte AID we SELECT into. Frozen per §5.5.
    public let aidHex: String = "F0BCF1073A5100"

    public init(state: State = .idle) {
        self.state = state
    }

    /// Forward-only state transitions. Rejects backward moves except `.error → .idle`
    /// (user dismisses an error and starts over), `.success → .idle` and `.peerRejected → .idle` (same), and
    /// `.confirming`/`.waitingForPeer → .holdAgain` (the second tap ended with the other person undecided or the
    /// field lost: the user holds the phones together again).
    public mutating func transition(to next: State) {
        switch (state, next) {
        case (.error, .idle), (.success, .idle), (.peerRejected, .idle):
            state = next
        case (.confirming, .holdAgain), (.waitingForPeer, .holdAgain):
            state = next
        case (.holdAgain, .confirming), (.holdAgain, .waitingForPeer):
            state = next
        case (let cur, let nxt) where nxt.rank > cur.rank:
            state = next
        case (let cur, let nxt) where nxt.rank == cur.rank:
            state = next  // e.g. update error message
        default:
            return  // reject backward transition
        }
    }

    public static let mock = NfcExchangeViewModel(state: .idle)
}
