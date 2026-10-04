import Foundation

/// W-MISSEDQUIET (2026-10-04) — how the local "Chiamata persa" notification is presented, as a pure decision so the
/// rule is testable without `UNUserNotificationCenter`.
///
/// ## The rule
///
/// A call that reaches a user who is busy is recorded as missed and announced with a local notification
/// (`AppState.handleMissedCallEvent`, category `QAUDION_MISSED_CALL`, its own thread, never the chat one). That
/// notification arrives WHILE the user is in another call, the very reason it exists. Presented the ordinary way it
/// brings the default chime along (`willPresent` returned `[.banner, .sound, .list, .badge]` when the in-app sound
/// is on, and the notification content carries `.default`): a ping in the middle of someone's conversation.
///
/// While a call is in flight (in a call, ringing, or a CallKit call still open), the missed-call notification is
/// shown quietly: banner and list, no sound, no badge. Outside a call nothing changes, and no other category is ever
/// affected (a chat message during a call keeps whatever it had).
public enum MissedCallAlertPolicy {

    /// What the foreground presentation of a notification includes (`UNNotificationPresentationOptions`, as plain
    /// values so the engine does not import UserNotifications).
    public struct Presentation: Equatable, Sendable {
        public let banner: Bool
        public let list: Bool
        public let sound: Bool
        public let badge: Bool

        public init(banner: Bool, list: Bool, sound: Bool, badge: Bool) {
            self.banner = banner
            self.list = list
            self.sound = sound
            self.badge = badge
        }
    }

    /// The foreground presentation of a notification (`willPresent`).
    ///
    /// The three `Bool`s before `isMissedCall` are the existing W405 gates, unchanged: banners off or quiet hours
    /// leave only the list (and the badge); otherwise a banner, with the sound when the in-app sound is on.
    public static func foreground(
        bannersEnabled: Bool,
        quietNow: Bool,
        inAppSoundEnabled: Bool,
        isMissedCall: Bool,
        callInFlight: Bool
    ) -> Presentation {
        let base: Presentation
        if !bannersEnabled || quietNow {
            base = Presentation(banner: false, list: true, sound: false, badge: true)
        } else {
            base = Presentation(banner: true, list: true, sound: inAppSoundEnabled, badge: true)
        }
        guard isMissedCall && callInFlight else { return base }
        return Presentation(banner: base.banner, list: base.list, sound: false, badge: false)
    }

    /// Whether the content of a LOCAL notification carries a sound (`scheduleLocal`): the in-app sound toggle, and
    /// never for a missed call while a call is in flight (the notification can also be delivered while the app is
    /// not in the foreground, where `willPresent` is not asked and the content's sound is all there is).
    public static func localContentHasSound(
        inAppSoundEnabled: Bool,
        isMissedCall: Bool,
        callInFlight: Bool
    ) -> Bool {
        inAppSoundEnabled && !(isMissedCall && callInFlight)
    }
}
