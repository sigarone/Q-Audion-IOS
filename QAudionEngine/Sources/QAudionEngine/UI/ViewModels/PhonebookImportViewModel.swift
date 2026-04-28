import Foundation

public struct PhonebookImportViewModel: ViewModelProtocol {

    public enum Step: Equatable, Sendable {
        case introduction                     // explain consent
        case requestingPermission              // showing CN permission alert
        case scanning(progress: Double)        // hashing local contacts
        case discovering(progress: Double)     // server discover-v2
        case results(matched: [Match], unmatched: Int)
        case error(message: String)

        fileprivate var rank: Int {
            switch self {
            case .introduction: return 0
            case .requestingPermission: return 1
            case .scanning: return 2
            case .discovering: return 3
            case .results: return 4
            case .error: return 5
            }
        }
    }

    public struct Match: Equatable, Sendable, Hashable {
        public let userId: String
        public let localName: String
        public let phoneHash: String

        public init(userId: String, localName: String, phoneHash: String) {
            self.userId = userId
            self.localName = localName
            self.phoneHash = phoneHash
        }
    }

    public private(set) var step: Step
    public let totalLocalContacts: Int
    public let permissionDenied: Bool

    public init(step: Step = .introduction, totalLocalContacts: Int = 0,
                permissionDenied: Bool = false) {
        self.step = step
        self.totalLocalContacts = totalLocalContacts
        self.permissionDenied = permissionDenied
    }

    public mutating func transition(to next: Step) {
        switch (step, next) {
        case (.error, _), (.results, _):
            step = next  // restart from terminal allowed
        case (let cur, let nxt) where nxt.rank >= cur.rank:
            step = next
        default:
            break
        }
    }

    public static let mock = PhonebookImportViewModel(
        step: .results(
            matched: [
                Match(userId: "user-alice", localName: "Alice", phoneHash: "abc123"),
                Match(userId: "user-bob", localName: "Bob", phoneHash: "def456")
            ],
            unmatched: 47
        ),
        totalLocalContacts: 49,
        permissionDenied: false
    )
}
