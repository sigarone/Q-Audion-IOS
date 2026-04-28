import Foundation

/// UserDefaults-backed persistence for the local-only sub-screens of the
/// Settings hub.
///
/// Server-synced settings (Account profile, Device list) are NOT covered
/// here — those round-trip via REST. `.qabk` Backup is also out of scope
/// (cross-platform container format is gated on Open Discrepancy §10).
///
/// Keys are namespaced with the prefix `qaudion.` and serialized via a
/// dedicated `JSONEncoder` so the on-disk format is forward-compatible
/// (additions are tolerated, removed fields are ignored on load).
public final class SettingsStore {

    private let defaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    // MARK: - Privacy

    public func loadPrivacy() -> PrivacySettingsViewModel {
        load(forKey: Key.privacy, default: PrivacySettingsViewModel(
            readReceiptsEnabled: true,
            typingIndicatorEnabled: true,
            presenceVisibleToContacts: true,
            disappearingMessagesDuration: 0,
            blockedUserIds: [],
            torEnabled: false
        ))
    }

    public func savePrivacy(_ vm: PrivacySettingsViewModel) {
        save(vm, forKey: Key.privacy)
    }

    // MARK: - Chat

    public func loadChat() -> ChatSettingsViewModel {
        load(forKey: Key.chat, default: ChatSettingsViewModel(
            readReceiptsEnabled: true,
            typingIndicatorsEnabled: true,
            messagePreviewInNotifications: false
        ))
    }

    public func saveChat(_ vm: ChatSettingsViewModel) {
        save(vm, forKey: Key.chat)
    }

    // MARK: - Calls

    public func loadCalls() -> CallsSettingsViewModel {
        load(forKey: Key.calls, default: CallsSettingsViewModel(
            codecPreference: .opus,
            isAecEnabled: true,
            isNsEnabled: true,
            isAgcEnabled: true,
            isVoipBackgroundModeActive: true,
            preferredCallQuality: .medium
        ))
    }

    public func saveCalls(_ vm: CallsSettingsViewModel) {
        save(vm, forKey: Key.calls)
    }

    // MARK: - Notifications

    public func loadNotifications() -> NotificationsSettingsViewModel {
        load(forKey: Key.notifications, default: NotificationsSettingsViewModel(
            ringtoneId: "qaudion-default",
            inAppSoundEnabled: true,
            vibrationEnabled: true,
            quietHours: NotificationsSettingsViewModel.QuietHours(
                startHour: 22, startMinute: 0, endHour: 8, endMinute: 0, enabled: false
            ),
            mutedContactsCount: 0
        ))
    }

    public func saveNotifications(_ vm: NotificationsSettingsViewModel) {
        save(vm, forKey: Key.notifications)
    }

    // MARK: - Transport

    public func loadTransport() -> TransportSettingsViewModel {
        load(forKey: Key.transport, default: TransportSettingsViewModel(
            mode: .auto,
            torEnabled: false,
            preferredTurnServerUrl: nil,
            lastConnectionMs: 0,
            lastTurnRoundTripMs: 0
        ))
    }

    public func saveTransport(_ vm: TransportSettingsViewModel) {
        save(vm, forKey: Key.transport)
    }

    // MARK: - Reset

    public func resetAll() {
        Key.allCases.forEach { defaults.removeObject(forKey: $0.rawValue) }
    }

    // MARK: - Internals

    private enum Key: String, CaseIterable {
        case privacy       = "qaudion.settings.privacy"
        case chat          = "qaudion.settings.chat"
        case calls         = "qaudion.settings.calls"
        case notifications = "qaudion.settings.notifications"
        case transport     = "qaudion.settings.transport"
    }

    private func load<T: Codable>(forKey key: Key, default fallback: T) -> T {
        guard let data = defaults.data(forKey: key.rawValue) else { return fallback }
        guard let decoded = try? decoder.decode(T.self, from: data) else { return fallback }
        return decoded
    }

    private func save<T: Codable>(_ value: T, forKey key: Key) {
        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: key.rawValue)
    }
}

// MARK: - Codable conformance for the ViewModels

// `PrivacySettingsViewModel`, `ChatSettingsViewModel`, etc. are public
// pure-Swift structs with public init. They need explicit Codable
// synthesis for SettingsStore to round-trip them.
//
// We add the conformances here (in the persistence layer) instead of on
// the view-model definitions themselves so the persistence concern stays
// out of the view-model's public surface.

extension PrivacySettingsViewModel: Codable {}
extension ChatSettingsViewModel: Codable {}
extension CallsSettingsViewModel: Codable {}
// CallsSettingsViewModel.Codec and CallsSettingsViewModel.CallQuality are
// String-backed enums — they gain Codable synthesis automatically once the
// parent struct conforms. Redundant explicit conformances are omitted to
// avoid "redundant conformance" compiler errors.
extension NotificationsSettingsViewModel: Codable {}
extension NotificationsSettingsViewModel.QuietHours: Codable {}
extension TransportSettingsViewModel: Codable {}
// TransportSettingsViewModel.Mode is a String-backed enum — Codable is
// synthesized automatically through the parent's conformance.
