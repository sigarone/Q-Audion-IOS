import Foundation

/// W417 — bisect stub. No-op shell exposing the API surface that
/// AppState.initialize() calls. Real implementation will be added
/// after the bisect identifies which v1.0.386-389 change broke the
/// build.
@MainActor
public final class LiveLogStreamer {
    public static let shared = LiveLogStreamer()
    private init() {}
    public func start(appState: AppState) {}
    public func stop() {}
}
