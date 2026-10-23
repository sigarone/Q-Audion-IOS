import SwiftUI
import UIKit
import QAudionEngine

/// The card of a location message in a 1:1 chat (docs/LOCATION_SHARING.md 1.5): a pin, or a live share. It decides the state of the card
/// from the row and the live-share store (`LocationShareCenter.cardState`) and hands it to `LocationCardView`, which draws it.
struct LocationBubbleContent: View {
    @ObservedObject private var center: LocationShareCenter = LocationShareCenter.shared

    let message: Message

    var body: some View {
        let initial: LocationCardState = center.cardState(for: message)
        Group {
            if initial.kind == .liveActive || initial.kind == .liveStale {
                // A running share shows how long ago it was updated: the card is redrawn every second while it is on screen.
                TimelineView(.periodic(from: Date(), by: 1)) { context in
                    LocationCardView(state: center.cardState(for: message), timeText: LocationCardFormat.clock(message.sentAt),
                                     now: context.date, onStop: { stop() })
                }
            } else {
                LocationCardView(state: initial, timeText: LocationCardFormat.clock(message.sentAt), now: Date(), onStop: { stop() })
            }
        }
    }

    private func stop() {
        guard let id = message.clientMsgId else { return }
        center.stopFromUser(startClientMsgId: id)
    }
}

/// The card of a pin in a group chat: a pin only (a live share is 1:1 only), read from the body the row keeps.
struct GroupLocationBubbleContent: View {
    let locationBody: String
    let mine: Bool
    /// The time of the message, already formatted (the group row carries it that way).
    let timeText: String

    var body: some View {
        let state: LocationCardState = LocationCardResolver.resolve(rowText: locationBody, outgoing: mine, ownShareEndAt: nil, view: nil)
        LocationCardView(state: state, timeText: timeText, now: Date(), onStop: nil)
    }
}

/// What the card says and offers, drawn locally (a stylised pin on a plain ground, the accuracy, the times): no map tile and no snapshot
/// is ever fetched, because a map preview from a map service would send the region to that service. "Apri" hands the position to the
/// application the user picks.
///
/// What each state says:
///   pin             "Posizione", the accuracy, the time of the message
///   live, active    own: "fino alle HH:MM" and "Interrompi"; received: "aggiornata 20 s fa · fino alle HH:MM"
///   live, stale     "Ultimo aggiornamento N min fa", the last position stays
///   live, ended     "Condivisione terminata": no position, no actions
///   unreadable      "Impossibile mostrare la posizione."
///
/// One accessibility element, read as "Posizione condivisa, precisione 12 metri", with the actions exposed as custom actions.
struct LocationCardView: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type

    let state: LocationCardState
    /// The time of the message, shown on a pin.
    let timeText: String
    let now: Date
    /// The "Interrompi" of an own running share; `nil` where the card has none (a group).
    let onStop: (() -> Void)?

    @State private var gpxTarget: LocationGpxTarget? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                LocationPinGlyph(active: state.kind == .liveActive || state.kind == .pin,
                                 ended: state.kind == .liveEnded || state.kind == .unreadable)
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: titleText)
                        .qaudionStyle(type.titleSmall)
                        .foregroundStyle(scheme.onSurface)
                        .lineLimit(2)
                    Text(verbatim: detailText)
                        .qaudionStyle(type.bodySmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .lineLimit(3)
                }
                Spacer(minLength: 0)
            }
            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityText))
        .modifier(LocationCardAccessibilityActions(
            state: state,
            canStop: onStop != nil,
            onOpenApple: { openApple() },
            onOpenGoogle: { openGoogle() },
            onShareGpx: { shareGpx() },
            onCopy: { copy() },
            onStop: { onStop?() }))
        .sheet(item: $gpxTarget) { target in
            ActivityShareSheet(activityItems: [target.url], onComplete: {
                LocationCardActions.removeGpxFile(target.url)
            })
        }
    }

    // MARK: Actions row

    private var canStop: Bool {
        state.kind == .liveActive && state.own && onStop != nil
    }

    private var canOpen: Bool {
        state.hasPosition && (state.kind == .pin || state.kind == .liveActive || state.kind == .liveStale)
    }

    @ViewBuilder
    private var actions: some View {
        if canStop {
            Button(action: { onStop?() }) {
                Text(verbatim: LocationCardStrings.stop)
                    .qaudionStyle(type.labelMedium)
                    .foregroundStyle(scheme.onError)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Capsule().fill(scheme.error))
            }
            .buttonStyle(.plain)
        } else if canOpen {
            openMenu
        }
    }

    private var openMenu: some View {
        Menu {
            Button(action: { openApple() }) {
                Label(LocationCardStrings.openInMaps, systemImage: "map")
            }
            Button(action: { openGoogle() }) {
                Label(LocationCardStrings.openInGoogleMaps, systemImage: "location.north.circle")
            }
            Button(action: { shareGpx() }) {
                Label(LocationCardStrings.shareGpx, systemImage: "square.and.arrow.up")
            }
            Button(action: { copy() }) {
                Label(LocationCardStrings.copyCoordinates, systemImage: "doc.on.doc")
            }
        } label: {
            Text(verbatim: LocationCardStrings.open)
                .qaudionStyle(type.labelMedium)
                .foregroundStyle(scheme.onPrimary)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Capsule().fill(scheme.primary))
        }
    }

    // MARK: Texts

    private var titleText: String {
        switch state.kind {
        case .pin:
            return LocationCardStrings.pinTitle
        case .liveActive, .liveStale, .liveEnded:
            return LocationCardStrings.liveTitle
        case .unreadable:
            return LocationCardStrings.unreadable
        }
    }

    private var detailText: String {
        switch state.kind {
        case .pin:
            return pinDetail
        case .liveActive:
            if state.own {
                return LocationCardStrings.until(LocationCardFormat.clock(state.endAt))
            }
            let ago: String = LocationCardFormat.elapsed(since: state.lastUpdateAt, now: now)
            let until: String = LocationCardStrings.until(LocationCardFormat.clock(state.endAt))
            return LocationCardStrings.updated(ago: ago) + " · " + until
        case .liveStale:
            return LocationCardStrings.lastUpdate(ago: LocationCardFormat.elapsed(since: state.lastUpdateAt, now: now))
        case .liveEnded:
            return LocationCardStrings.ended
        case .unreadable:
            return ""
        }
    }

    private var pinDetail: String {
        var parts: [String] = []
        if state.approximate {
            parts.append(LocationCardStrings.approximate)
        } else if let accuracy = state.accuracy {
            parts.append(LocationCardStrings.accuracy(metres: accuracy))
        }
        parts.append(timeText)
        return parts.joined(separator: " · ")
    }

    private var accessibilityText: String {
        var text: String = LocationCardActions.sharedPositionLabel
        if state.kind == .liveEnded {
            return text + ", " + LocationCardStrings.ended
        }
        if state.kind == .unreadable {
            return LocationCardStrings.unreadable
        }
        if let accuracy = state.accuracy, !state.approximate {
            text += ", " + LocationCardStrings.accessibilityAccuracy(metres: accuracy)
        }
        if state.kind == .liveActive || state.kind == .liveStale {
            text += ", " + LocationCardStrings.liveTitle
        }
        return text
    }

    // MARK: Actions

    private func openApple() {
        guard let lat = state.latE7, let lon = state.lonE7 else { return }
        LocationCardActions.openInAppleMaps(latE7: lat, lonE7: lon)
    }

    private func openGoogle() {
        guard let lat = state.latE7, let lon = state.lonE7 else { return }
        LocationCardActions.openInGoogleMaps(latE7: lat, lonE7: lon)
    }

    private func shareGpx() {
        guard let lat = state.latE7, let lon = state.lonE7,
              let url = LocationCardActions.writeGpxFile(latE7: lat, lonE7: lon) else { return }
        gpxTarget = LocationGpxTarget(url: url)
    }

    private func copy() {
        guard let lat = state.latE7, let lon = state.lonE7 else { return }
        LocationCardActions.copyCoordinates(latE7: lat, lonE7: lon)
    }
}

/// The GPX file waiting in the share sheet.
struct LocationGpxTarget: Identifiable {
    let id: UUID = UUID()
    let url: URL
}

/// The actions of the card for VoiceOver, one custom action each, only the ones the state offers.
private struct LocationCardAccessibilityActions: ViewModifier {
    let state: LocationCardState
    let canStop: Bool
    let onOpenApple: () -> Void
    let onOpenGoogle: () -> Void
    let onShareGpx: () -> Void
    let onCopy: () -> Void
    let onStop: () -> Void

    func body(content: Content) -> some View {
        if state.kind == .liveActive && state.own && canStop {
            content
                .accessibilityAction(named: Text(verbatim: LocationCardStrings.stop), onStop)
        } else if state.hasPosition && (state.kind == .pin || state.kind == .liveActive || state.kind == .liveStale) {
            content
                .accessibilityAction(named: Text(verbatim: LocationCardStrings.openInMaps), onOpenApple)
                .accessibilityAction(named: Text(verbatim: LocationCardStrings.openInGoogleMaps), onOpenGoogle)
                .accessibilityAction(named: Text(verbatim: LocationCardStrings.shareGpx), onShareGpx)
                .accessibilityAction(named: Text(verbatim: LocationCardStrings.copyCoordinates), onCopy)
        } else {
            content
        }
    }
}

/// A stylised pin on a plain ground with a few faint lines, drawn here: not a map, and nothing of the real surroundings.
struct LocationPinGlyph: View {
    @Environment(\.qaudionScheme) private var scheme

    let active: Bool
    let ended: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(scheme.surfaceVariant.opacity(0.7))
            Canvas { context, size in
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height * 0.62))
                path.addCurve(to: CGPoint(x: size.width, y: size.height * 0.38),
                              control1: CGPoint(x: size.width * 0.35, y: size.height * 0.40),
                              control2: CGPoint(x: size.width * 0.65, y: size.height * 0.70))
                context.stroke(path, with: .color(scheme.outline.opacity(0.35)), lineWidth: 2)
                var cross = Path()
                cross.move(to: CGPoint(x: size.width * 0.5, y: 0))
                cross.addLine(to: CGPoint(x: size.width * 0.5, y: size.height))
                context.stroke(cross, with: .color(scheme.outline.opacity(0.18)), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            if active {
                Circle()
                    .stroke(scheme.primary.opacity(0.35), lineWidth: 2)
                    .frame(width: 34, height: 34)
            }
            Image(systemName: ended ? "mappin.slash" : "mappin.circle.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(ended ? scheme.onSurfaceVariant : scheme.primary)
        }
        .accessibilityHidden(true)
    }
}
