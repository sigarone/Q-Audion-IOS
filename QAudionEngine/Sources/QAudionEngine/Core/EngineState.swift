import Foundation

public enum EngineState: String, CaseIterable, Equatable {
    case uninitialized
    case initialized
    case sessionActive
    case processing
    case error
    case destroyed

    public func canTransitionTo(_ target: EngineState) -> Bool {
        switch (self, target) {
        case (.uninitialized, .initialized): return true
        case (.initialized, .sessionActive), (.initialized, .error), (.initialized, .destroyed): return true
        case (.sessionActive, .processing), (.sessionActive, .error), (.sessionActive, .destroyed), (.sessionActive, .initialized): return true
        case (.processing, .sessionActive), (.processing, .error), (.processing, .destroyed): return true
        case (.error, .destroyed), (.error, .initialized): return true
        default: return false
        }
    }

    public var isTerminal: Bool { self == .destroyed }
    public var isError: Bool { self == .error }
    public var isProcessing: Bool { self == .processing }

    public var description: String {
        switch self {
        case .uninitialized: return "Engine not yet initialized"
        case .initialized: return "Engine initialized, ready for session"
        case .sessionActive: return "Cryptographic session active"
        case .processing: return "Processing audio frames"
        case .error: return "Error state"
        case .destroyed: return "Engine destroyed"
        }
    }
}
