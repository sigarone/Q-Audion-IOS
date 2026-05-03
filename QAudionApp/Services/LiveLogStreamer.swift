import Foundation

/// W417 — minimal API surface to test compile path.
@MainActor
public final class LiveLogStreamer {
    public static let shared = LiveLogStreamer()
    private init() {}

    /// Configures the streamer with primitive callbacks. Avoids
    /// referencing AppState directly in the signature (which broke
    /// the build in v1.0.394/395 — see bisect log v1.0.386→v1.0.396).
    public func start(serverUrl: String,
                      getToken: @escaping @MainActor () -> String?,
                      getUserId: @escaping @MainActor () -> String?) {
        // Body intentionally empty — confirming compile.
        _ = serverUrl
        _ = getToken
        _ = getUserId
    }

    public func stop() {}
}
