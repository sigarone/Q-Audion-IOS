import Foundation

/// W417 — Diagnostic stub. The real LiveLogStreamer body is being
/// re-introduced incrementally after v1.0.386-388 hit a Swift compile
/// error in the original implementation that we couldn't surface
/// without log access. This stub is a no-op so we can confirm the
/// build pipeline is otherwise clean before re-adding the upload
/// logic feature-by-feature.
@MainActor
public final class LiveLogStreamer {
    public static let shared = LiveLogStreamer()
    private init() {}
    public func start(appState: AppState) {}
    public func stop() {}
}
