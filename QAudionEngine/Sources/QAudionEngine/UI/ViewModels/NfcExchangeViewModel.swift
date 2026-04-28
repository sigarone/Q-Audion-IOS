import Foundation

public struct NfcExchangeViewModel: ViewModelProtocol {

    public enum State: Equatable, Sendable {
        case idle
        case waiting              // user has tapped "Start", phone listening for tag
        case exchanging           // tag detected, APDU + payload exchange in flight
        case success(peerDeviceName: String)
        case error(message: String)

        fileprivate var rank: Int {
            switch self {
            case .idle: return 0
            case .waiting: return 1
            case .exchanging: return 2
            case .success, .error: return 3
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
    /// (user dismisses an error and starts over) and `.success → .idle` (same).
    public mutating func transition(to next: State) {
        switch (state, next) {
        case (.error, .idle), (.success, .idle):
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
