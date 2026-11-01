import SwiftUI

// MARK: - Layout (pure, tested)

/// The controls that can sit in the call dock. The dock is the same on every call screen: two rows of four cells of equal
/// width, the red end button always the last cell of the bottom row.
enum CallControlKind: String, CaseIterable, Sendable {
    case chat
    case share
    case add
    case buds
    case hand
    case reaction
    case mute
    case audio
    case video
    case end
}

/// Which call the dock is for. `connecting` is the outgoing ring: only the bottom row is drawn, so the end button does not
/// move when the call connects.
enum CallDockMode: Equatable, Sendable {
    case connecting
    case oneToOne
    case group
}

/// Which control sits in which cell. A control that is not available leaves its cell empty; the others do not move.
enum CallDockLayout {
    static let columns: Int = 4

    /// Bottom padding for a panel drawn above the dock (diagnostics): clears the two-row dock (about 204 pt) plus its margin.
    static let overlayClearance: CGFloat = 230

    /// The bottom row (the thumb zone): the most used controls, then the end button.
    static let bottomRow: [CallControlKind] = [.mute, .audio, .video, .end]

    /// The top row of a call: secondary controls. Empty while connecting.
    static func topRow(mode: CallDockMode, available: Set<CallControlKind>) -> [CallControlKind?] {
        let wanted: [CallControlKind]
        switch mode {
        case .connecting:
            return []
        case .oneToOne:
            wanted = [.chat, .share, .add, .buds]
        case .group:
            wanted = [.chat, .share, .hand, .reaction]
        }
        return wanted.map { available.contains($0) ? $0 : nil }
    }

    /// The rows to draw, top first. A top row with no control at all is not drawn (the dock gets shorter), the bottom row
    /// is always there.
    static func rows(mode: CallDockMode, available: Set<CallControlKind>) -> [[CallControlKind?]] {
        let bottom: [CallControlKind?] = bottomRow.map { Optional($0) }
        let top: [CallControlKind?] = topRow(mode: mode, available: available)
        if top.allSatisfy({ $0 == nil }) {
            return [bottom]
        }
        return [top, bottom]
    }
}

// MARK: - Item

/// One cell of the dock: the icon, the fixed name shown under it, the accessibility text and the colours.
struct CallDockItem {
    enum Badge: Equatable {
        case hidden
        case dot
        case count(Int)
    }

    let kind: CallControlKind
    let icon: String
    let label: String
    let accessibilityLabel: String
    var accessibilityValue: String
    var background: Color
    var iconColor: Color
    var isDisabled: Bool
    var isLocked: Bool
    var badge: Badge
    /// The button opens the system list of audio outputs (an invisible route picker sits over it).
    var usesRoutePicker: Bool
    let action: () -> Void
    let onLockedAction: () -> Void

    init(kind: CallControlKind,
         icon: String,
         label: String,
         accessibilityLabel: String,
         accessibilityValue: String = "",
         background: Color,
         iconColor: Color,
         isDisabled: Bool = false,
         isLocked: Bool = false,
         badge: Badge = .hidden,
         usesRoutePicker: Bool = false,
         action: @escaping () -> Void,
         onLockedAction: @escaping () -> Void = {}) {
        self.kind = kind
        self.icon = icon
        self.label = label
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityValue = accessibilityValue
        self.background = background
        self.iconColor = iconColor
        self.isDisabled = isDisabled
        self.isLocked = isLocked
        self.badge = badge
        self.usesRoutePicker = usesRoutePicker
        self.action = action
        self.onLockedAction = onLockedAction
    }
}

// MARK: - View

/// The call dock: a card anchored at the bottom with two rows of four cells (56 pt circles, the end button 68 pt) and a
/// visible name under every circle. The same on the audio call, the video call, the group call and the outgoing ring.
struct CallControlDock: View {
    @Environment(\.qaudionScheme) private var scheme

    /// Rows to draw, top first; a nil cell is empty. Build them with `CallDockLayout.rows` and `CallDockItems`.
    let rows: [[CallDockItem?]]

    static let circleSize: CGFloat = 56
    static let endCircleSize: CGFloat = 68
    static let maxWidth: CGFloat = 440

    var body: some View {
        VStack(spacing: 12) {
            ForEach(0..<rows.count, id: \.self) { index in
                rowView(rows[index])
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: Self.maxWidth)
        // The dock floats over the call: one Liquid Glass surface for the whole group (its buttons keep their own solid
        // state colours on top of it), the opaque card with its outline where glass is not available.
        .qaudionGlassSurface(in: RoundedRectangle(cornerRadius: 28),
                             fallback: scheme.surface.opacity(0.9),
                             fallbackStroke: scheme.outline.opacity(0.4))
        .accessibilityElement(children: .contain)
    }

    private func rowView(_ items: [CallDockItem?]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<items.count, id: \.self) { index in
                cellView(items[index])
            }
        }
    }

    @ViewBuilder
    private func cellView(_ item: CallDockItem?) -> some View {
        if let item {
            CallDockCell(item: item)
        } else {
            Color.clear
                .frame(maxWidth: .infinity, minHeight: 72)
                .accessibilityHidden(true)
        }
    }
}

private struct CallDockCell: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras

    let item: CallDockItem

    private var isEnd: Bool { item.kind == .end }
    private var diameter: CGFloat { isEnd ? CallControlDock.endCircleSize : CallControlDock.circleSize }

    var body: some View {
        Button(action: tap) {
            VStack(spacing: 4) {
                circleView
                Text(item.label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(scheme.onSurfaceVariant)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            }
            .frame(maxWidth: .infinity, minHeight: isEnd ? 88 : 72, alignment: .top)
            .contentShape(Rectangle())
            .opacity(item.isDisabled ? 0.38 : 1.0)
        }
        .buttonStyle(CallDockPressStyle())
        .disabled(item.isDisabled)
        .accessibilityLabel(item.accessibilityLabel)
        .accessibilityValue(item.accessibilityValue)
        .accessibilityHint(item.isLocked ? CallControlText.unavailableHint : "")
    }

    private var circleView: some View {
        Circle()
            .fill(item.background)
            .frame(width: diameter, height: diameter)
            .overlay {
                Image(systemName: item.icon)
                    .font(.system(size: diameter * 0.40, weight: .semibold))
                    .foregroundStyle(item.iconColor)
            }
            .overlay {
                if item.usesRoutePicker {
                    SystemRoutePickerOverlay()
                        .clipShape(Circle())
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .topTrailing) {
                badgeView
            }
            .overlay(alignment: .topTrailing) {
                lockView
            }
    }

    @ViewBuilder
    private var badgeView: some View {
        switch item.badge {
        case .hidden:
            EmptyView()
        case .dot:
            Circle()
                .fill(extras.riskHigh)
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(scheme.surface, lineWidth: 2))
                .offset(x: 2, y: -2)
                .accessibilityHidden(true)
        case .count(let number):
            Text(number > 99 ? "99+" : number.description)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(extras.riskHigh))
                .offset(x: 6, y: -4)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var lockView: some View {
        if item.isLocked {
            Image(systemName: "lock.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.black.opacity(0.6)))
                .offset(x: 2, y: -2)
                .accessibilityHidden(true)
        }
    }

    private func tap() {
        if item.usesRoutePicker {
            SystemRoutePicker.present()
            return
        }
        if item.isLocked {
            item.onLockedAction()
            return
        }
        switch item.kind {
        case .mute, .audio, .video:
            HapticFeedback.callControl()
        default:
            break
        }
        item.action()
    }
}

private struct CallDockPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
    }
}

// MARK: - Items (one builder per control, shared by every call screen)

/// The colour tokens the dock uses; the same names on Android.
struct CallDockStyle {
    let scheme: QAudionColorScheme
    let extras: QAudionColorsExtra
}

/// Builds the item of each control. Every call screen goes through these builders, so the same control has the same icon,
/// name, accessibility text and colours everywhere.
enum CallDockItems {

    static func mute(_ style: CallDockStyle, muted: Bool, held: Bool = false, heldLabel: String = "",
                     action: @escaping () -> Void) -> CallDockItem {
        let off: Bool = muted || held
        let label: String
        if held {
            label = heldLabel
        } else {
            label = muted ? CallControlText.muteA11yOff : CallControlText.muteA11yOn
        }
        return CallDockItem(
            kind: .mute,
            icon: off ? "mic.slash.fill" : "mic.fill",
            label: CallControlText.mute,
            accessibilityLabel: label,
            background: off ? style.extras.warning : style.scheme.surfaceVariant,
            iconColor: off ? style.extras.onWarning : style.scheme.onSurface,
            isDisabled: held,
            action: action)
    }

    /// The audio output button of a 1:1 call: the earpiece or the loudspeaker, a tap switches.
    static func audio(_ style: CallDockStyle, speakerOn: Bool, action: @escaping () -> Void) -> CallDockItem {
        return audio(style, route: speakerOn ? .speaker : .earpiece, action: action)
    }

    /// The audio output button: the icon and the colour follow the current route. With `usesRoutePicker` a tap opens the
    /// system list of outputs instead of calling `action`.
    static func audio(_ style: CallDockStyle, route: CallAudioRoute, usesRoutePicker: Bool = false,
                      action: @escaping () -> Void) -> CallDockItem {
        let background: Color
        let iconColor: Color
        switch route {
        case .speaker:
            background = style.extras.success
            iconColor = style.extras.onSuccess
        case .bluetooth, .car:
            background = style.scheme.primary
            iconColor = style.scheme.onPrimary
        default:
            background = style.scheme.surfaceVariant
            iconColor = style.scheme.onSurface
        }
        return CallDockItem(
            kind: .audio,
            icon: route.icon,
            label: CallControlText.audio,
            accessibilityLabel: CallControlText.audioA11y(route: route.spokenName),
            background: background,
            iconColor: iconColor,
            usesRoutePicker: usesRoutePicker,
            action: action)
    }

    /// `callHasVideo` is false on an audio call (the button upgrades it to video); `cameraOn` is our camera sending.
    static func video(_ style: CallDockStyle, callHasVideo: Bool, cameraOn: Bool, isDisabled: Bool = false,
                      isLocked: Bool = false, action: @escaping () -> Void,
                      onLocked: @escaping () -> Void = {}) -> CallDockItem {
        let label: String
        if !callHasVideo {
            label = CallControlText.videoA11yUpgrade
        } else {
            label = cameraOn ? CallControlText.videoA11yOff : CallControlText.videoA11yOn
        }
        let sending: Bool = callHasVideo && cameraOn
        return CallDockItem(
            kind: .video,
            icon: sending ? "video.fill" : "video.slash.fill",
            label: CallControlText.video,
            accessibilityLabel: label,
            background: sending ? style.extras.success : style.scheme.surfaceVariant,
            iconColor: sending ? style.extras.onSuccess : style.scheme.onSurface,
            isDisabled: isDisabled,
            isLocked: isLocked,
            action: action,
            onLockedAction: onLocked)
    }

    /// `unreadCount` > 0 shows the number; otherwise `unreadDot` shows a dot (the 1:1 call only knows that a message waits).
    static func chat(_ style: CallDockStyle, unreadDot: Bool = false, unreadCount: Int = 0,
                     action: @escaping () -> Void) -> CallDockItem {
        let badge: CallDockItem.Badge
        var value: String = ""
        if unreadCount > 0 {
            badge = .count(unreadCount)
            value = CallControlText.chatA11yUnread(count: unreadCount)
        } else if unreadDot {
            badge = .dot
            value = CallControlText.chatA11yWaiting
        } else {
            badge = .hidden
        }
        return CallDockItem(
            kind: .chat,
            icon: "bubble.left.fill",
            label: CallControlText.chat,
            accessibilityLabel: CallControlText.chatA11y,
            accessibilityValue: value,
            background: style.scheme.surfaceVariant,
            iconColor: style.scheme.onSurface,
            badge: badge,
            action: action)
    }

    static func share(_ style: CallDockStyle, sharing: Bool, action: @escaping () -> Void) -> CallDockItem {
        return CallDockItem(
            kind: .share,
            icon: sharing ? "arrow.up.forward.app.fill" : "arrow.up.forward.app",
            label: CallControlText.share,
            accessibilityLabel: sharing ? CallControlText.shareA11yOff : CallControlText.shareA11yOn,
            background: sharing ? style.extras.success : style.scheme.surfaceVariant,
            iconColor: sharing ? style.extras.onSuccess : style.scheme.onSurface,
            action: action)
    }

    static func add(_ style: CallDockStyle, isLocked: Bool = false, action: @escaping () -> Void,
                    onLocked: @escaping () -> Void = {}) -> CallDockItem {
        return CallDockItem(
            kind: .add,
            icon: "person.badge.plus",
            label: CallControlText.add,
            accessibilityLabel: CallControlText.addA11y,
            background: style.scheme.surfaceVariant,
            iconColor: style.scheme.onSurface,
            isLocked: isLocked,
            action: action,
            onLockedAction: onLocked)
    }

    static func hand(_ style: CallDockStyle, raised: Bool, action: @escaping () -> Void) -> CallDockItem {
        return CallDockItem(
            kind: .hand,
            icon: raised ? "hand.raised.fill" : "hand.raised",
            label: CallControlText.hand,
            accessibilityLabel: raised ? CallControlText.handA11yLower : CallControlText.handA11yRaise,
            background: raised ? style.extras.warning : style.scheme.surfaceVariant,
            iconColor: raised ? style.extras.onWarning : style.scheme.onSurface,
            action: action)
    }

    static func reaction(_ style: CallDockStyle, action: @escaping () -> Void) -> CallDockItem {
        return CallDockItem(
            kind: .reaction,
            icon: "face.smiling",
            label: CallControlText.reaction,
            accessibilityLabel: CallControlText.reactionA11y,
            background: style.scheme.surfaceVariant,
            iconColor: style.scheme.onSurface,
            action: action)
    }

    /// The red end button. `ended` is the outgoing screen after the call failed: the same cell closes the screen.
    static func end(_ style: CallDockStyle, group: Bool = false, ended: Bool = false,
                    action: @escaping () -> Void) -> CallDockItem {
        let label: String
        let spoken: String
        if ended {
            label = CallControlText.close
            spoken = CallControlText.close
        } else {
            label = CallControlText.end
            spoken = group ? CallControlText.endA11yGroup : CallControlText.endA11y
        }
        return CallDockItem(
            kind: .end,
            icon: "phone.down.fill",
            label: label,
            accessibilityLabel: spoken,
            background: style.extras.riskHigh,
            iconColor: style.scheme.onPrimary,
            action: action)
    }

    /// The bottom row, shared by the outgoing ring (where `video` is disabled) and the connected calls.
    static func assemble(mode: CallDockMode, items: [CallDockItem]) -> [[CallDockItem?]] {
        var byKind: [CallControlKind: CallDockItem] = [:]
        for item in items {
            byKind[item.kind] = item
        }
        let layout: [[CallControlKind?]] = CallDockLayout.rows(mode: mode, available: Set(byKind.keys))
        return layout.map { (row: [CallControlKind?]) -> [CallDockItem?] in
            row.map { (kind: CallControlKind?) -> CallDockItem? in
                guard let kind else { return nil }
                return byKind[kind]
            }
        }
    }
}

// MARK: - Text

/// The names under the dock buttons and their accessibility text. Names are fixed (they do not change with the state);
/// the state is read from the icon, the colour and the accessibility text.
enum CallControlText {
    static var mute: String {
        String(localized: "call.control.mute", defaultValue: "Microfono", comment: "Name under the microphone button of the call controls.")
    }
    static var audio: String {
        String(localized: "call.control.audio", defaultValue: "Audio", comment: "Name under the audio output button of the call controls.")
    }
    static var video: String {
        String(localized: "call.control.video", defaultValue: "Video", comment: "Name under the camera button of the call controls.")
    }
    static var chat: String {
        String(localized: "call.control.chat", defaultValue: "Chat", comment: "Name under the chat button of the call controls.")
    }
    static var share: String {
        String(localized: "call.control.share", defaultValue: "Condividi", comment: "Name under the screen sharing button of the call controls.")
    }
    static var add: String {
        String(localized: "call.control.add", defaultValue: "Aggiungi", comment: "Name under the add participant button of the call controls.")
    }
    static var hand: String {
        String(localized: "call.control.hand", defaultValue: "Mano", comment: "Name under the raise hand button of the group call controls.")
    }
    static var reaction: String {
        String(localized: "call.control.reaction", defaultValue: "Reazione", comment: "Name under the reaction button of the group call controls.")
    }
    static var end: String {
        String(localized: "call.control.end", defaultValue: "Termina", comment: "Name under the red end call button of the call controls.")
    }
    static var close: String {
        String(localized: "call.outgoing.dismiss", defaultValue: "Chiudi", comment: "Accessibility label of the button that closes the outgoing call screen after the call ended (callee busy or unreachable)")
    }
    static var decline: String {
        String(localized: "call.control.decline", defaultValue: "Rifiuta", comment: "Name under the red decline button of the incoming call screen.")
    }
    static var accept: String {
        String(localized: "call.control.accept", defaultValue: "Accetta", comment: "Name under the green accept button of the incoming call screen.")
    }
    static var acceptNoVideo: String {
        String(localized: "call.control.accept_no_video", defaultValue: "Senza video", comment: "Name under the green accept button of an incoming video call when the user chose to answer without video.")
    }
    static var answerAudioOnly: String {
        String(localized: "call.control.answer_audio_only", defaultValue: "Rispondi senza video", comment: "Switch on the incoming video call screen: answer with the camera off.")
    }

    static var muteA11yOn: String {
        String(localized: "call.control.mute_a11y_on", defaultValue: "Disattiva microfono", comment: "VoiceOver label of the microphone button while the microphone is live (tapping mutes).")
    }
    static var muteA11yOff: String {
        String(localized: "call.control.mute_a11y_off", defaultValue: "Riattiva microfono", comment: "VoiceOver label of the microphone button while muted (tapping turns the microphone back on).")
    }
    static func audioA11y(route: String) -> String {
        String(localized: "call.control.audio_a11y", defaultValue: "Uscita audio: \(route). Tocca per cambiare", comment: "VoiceOver label of the audio output button. %@ is the current output.")
    }
    static var routeEarpiece: String {
        String(localized: "call.control.route_earpiece", defaultValue: "Auricolare", comment: "Name of the phone earpiece as an audio output.")
    }
    static var routeSpeaker: String {
        String(localized: "call.control.route_speaker", defaultValue: "Altoparlante", comment: "Name of the loudspeaker as an audio output.")
    }
    static var routeWired: String {
        String(localized: "call.control.route_wired", defaultValue: "Cuffie", comment: "Name of wired headphones as an audio output.")
    }
    static var routeBluetooth: String {
        String(localized: "call.control.route_bluetooth", defaultValue: "Bluetooth", comment: "Name of a Bluetooth device as an audio output.")
    }
    static var routeCar: String {
        String(localized: "call.control.route_car", defaultValue: "Auto", comment: "Name of the car as an audio output.")
    }
    static var videoA11yUpgrade: String {
        String(localized: "call.control.video_a11y_upgrade", defaultValue: "Passa a videochiamata", comment: "VoiceOver label of the camera button on an audio call (tapping switches the call to video).")
    }
    static var videoA11yOff: String {
        String(localized: "call.control.video_a11y_off", defaultValue: "Disattiva video", comment: "VoiceOver label of the camera button while the camera is on (tapping turns it off).")
    }
    static var videoA11yOn: String {
        String(localized: "call.control.video_a11y_on", defaultValue: "Attiva video", comment: "VoiceOver label of the camera button while the camera is off (tapping turns it on).")
    }
    static var chatA11y: String {
        String(localized: "call.control.chat_a11y", defaultValue: "Apri la chat", comment: "VoiceOver label of the button on the call screen that opens the chat with the person on the call.")
    }
    static func chatA11yUnread(count: Int) -> String {
        String(localized: "call.control.chat_a11y_unread", defaultValue: "Nuovi messaggi: \(count)", comment: "VoiceOver value of the chat button when messages are waiting. %lld is the number of unread messages.")
    }
    static var chatA11yWaiting: String {
        String(localized: "in_call.chat.unread", defaultValue: "Nuovo messaggio", comment: "Accessibility value of the chat button on the call screen when a message from the person on the call is waiting.")
    }
    static var shareA11yOn: String {
        String(localized: "call.control.share_a11y_on", defaultValue: "Condividi schermo", comment: "VoiceOver label of the screen sharing button while not sharing (tapping starts sharing).")
    }
    static var shareA11yOff: String {
        String(localized: "call.control.share_a11y_off", defaultValue: "Interrompi condivisione schermo", comment: "VoiceOver label of the screen sharing button while sharing (tapping stops).")
    }
    static var addA11y: String {
        String(localized: "call.control.add_a11y", defaultValue: "Aggiungi partecipante", comment: "VoiceOver label of the add participant button of the call controls.")
    }
    static var handA11yRaise: String {
        String(localized: "call.control.hand_a11y_raise", defaultValue: "Alza la mano", comment: "VoiceOver label of the raise hand button while the hand is down.")
    }
    static var handA11yLower: String {
        String(localized: "call.control.hand_a11y_lower", defaultValue: "Abbassa la mano", comment: "VoiceOver label of the raise hand button while the hand is raised.")
    }
    static var reactionA11y: String {
        String(localized: "call.control.reaction_a11y", defaultValue: "Invia una reazione", comment: "VoiceOver label of the reaction button of the group call.")
    }
    static var endA11y: String {
        String(localized: "call.control.end_a11y", defaultValue: "Termina chiamata", comment: "VoiceOver label of the end call button.")
    }
    static var endA11yGroup: String {
        String(localized: "call.control.end_a11y_group", defaultValue: "Lascia la chiamata", comment: "VoiceOver label of the red button of a group call (the call goes on for the others).")
    }
    static var flipA11y: String {
        String(localized: "call.control.flip_a11y", defaultValue: "Cambia fotocamera", comment: "VoiceOver label of the button on the local preview that switches between the front and the back camera.")
    }
    static var reportA11y: String {
        String(localized: "call.control.report_a11y", defaultValue: "Segnala un problema", comment: "VoiceOver label of the report a problem button in the top bar of the call screens.")
    }
    static var layoutA11yGrid: String {
        String(localized: "call.control.layout_a11y_grid", defaultValue: "Passa a vista griglia", comment: "VoiceOver label of the button that switches the group call from speaker view to grid view.")
    }
    static var layoutA11ySpeaker: String {
        String(localized: "call.control.layout_a11y_speaker", defaultValue: "Passa a vista relatore", comment: "VoiceOver label of the button that switches the group call from grid view to speaker view.")
    }
    static var securityA11y: String {
        String(localized: "call.control.security_a11y", defaultValue: "Apri sicurezza chiamata", comment: "VoiceOver label of the shield button in the top bar of the call screens, which opens the call security.")
    }
    static var unavailableHint: String {
        String(localized: "call.action.unavailable_hint", defaultValue: "Non disponibile", comment: "VoiceOver hint of a round call action button that is disabled.")
    }
}

// MARK: - Top bar button

/// A 48 pt button of the top bar of the call screens (shield, report a problem, group layout).
struct CallTopBarButton: View {
    @Environment(\.qaudionScheme) private var scheme

    let icon: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(scheme.onSurface)
                .frame(width: 40, height: 40)
                .background(Circle().fill(scheme.surfaceVariant.opacity(0.7)))
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}
