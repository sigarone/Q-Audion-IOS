import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif
#if canImport(AppIntents)
import AppIntents
#endif

// Compiled into the app AND into the QAudionLiveActivity widget extension (project.yml): the data both sides agree on.
// Foundation, ActivityKit and AppIntents only; no engine, no stores.

/// The kinds of Live Activity the app shows.
enum LiveActivityKind: String, Codable, Hashable {
    /// A live location share this device is sending.
    case locationShare
    /// A file this device is uploading.
    case fileSend
    /// A file this device is downloading.
    case fileReceive
}

/// What a Live Activity shows. Updated locally by the app; nothing here ever travels to a server.
struct LiveActivityContent: Codable, Hashable {
    /// The contact of a location share, only when notification previews are allowed; otherwise `nil` and a generic line is shown.
    var contactName: String?
    /// When the activity began.
    var startDate: Date
    /// When a location share ends (drives the system timer); `nil` for a file.
    var endDate: Date?
    /// A file's progress, `0...1`; unused for a location share.
    var progress: Double
}

#if canImport(ActivityKit)
/// The attributes of every Live Activity of the app.
@available(iOS 16.1, *)
struct QAudionActivityAttributes: ActivityAttributes {
    typealias ContentState = LiveActivityContent

    var kind: LiveActivityKind
    /// The id of the share or of the transfer.
    var itemId: String
}
#endif

/// The way from a button of the widget extension to the app. The extension never runs the action itself: the system performs a Live
/// Activity intent in the app's process, where the app has set the handler at launch. With no handler (a process that began a moment
/// ago) the action does nothing, which is right: a process that starts again never resumes a share.
@MainActor
enum LiveActivityActionHub {
    static var stopLocationShare: ((String) -> Void)?

    static func stop(shareId: String) {
        stopLocationShare?(shareId)
    }
}

#if canImport(AppIntents)
/// "Stop" on the Live Activity of a location share (iOS 17 and later; on 16.x the activity only shows).
@available(iOS 17.0, *)
struct StopLocationShareIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "live.stop.intent.title"
    static let isDiscoverable: Bool = false

    @Parameter(title: "live.stop.intent.parameter")
    var shareId: String

    init() {}

    init(shareId: String) {
        self.shareId = shareId
    }

    func perform() async throws -> some IntentResult {
        await LiveActivityActionHub.stop(shareId: shareId)
        return .result()
    }
}
#endif
