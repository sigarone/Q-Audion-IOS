import Foundation

@MainActor
public final class LiveLogStreamer {
    public static let shared = LiveLogStreamer()
    private init() {}
    public func start(appState: AppState) {}
    public func stop() {}
}
