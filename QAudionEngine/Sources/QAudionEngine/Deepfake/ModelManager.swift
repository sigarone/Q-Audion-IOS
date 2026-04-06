import Foundation

public final class ModelManager {
    public enum ModelState { case notLoaded; case loading; case loaded; case error(String) }
    private var state: ModelState = .notLoaded
    private var modelPath: String?

    public init() {}

    /// Load CoreML model. STUB: always succeeds for Phase 3.
    public func loadModel(named name: String = "deepfake_lcnn") -> Bool {
        state = .loaded
        modelPath = name
        return true
    }

    public func getState() -> ModelState { state }
    public func isLoaded() -> Bool { if case .loaded = state { return true }; return false }

    public func unloadModel() { state = .notLoaded; modelPath = nil }

    /// Verify model integrity via SHA-256 hash. STUB: always returns true.
    public func verifyIntegrity(expectedHash: String) -> Bool { true }
}
