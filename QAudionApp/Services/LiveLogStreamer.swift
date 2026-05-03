import Foundation

public final class LiveLogStreamer: @unchecked Sendable {
    public static let shared = LiveLogStreamer()
    private init() {}
    public func start(appState: AppState) {}
    public func stop() {}
}
