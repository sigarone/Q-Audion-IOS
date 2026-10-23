import SwiftUI
import UIKit

/// IN-CALL NARROWBAND BLUETOOTH NOTICE (2026-10-22) -- the small banner of the call screens (1:1 audio, 1:1 video, group)
/// shown while the call audio runs over a Bluetooth hands-free link limited to 8 kHz: what it means ("reduced voice
/// quality"), a "use the phone" button that moves the call to the built-in microphone and receiver, and a close button
/// that keeps it away for the rest of the call.
///
/// Whether it shows is decided by `NarrowbandBluetoothBannerModel` with the engine's rules (`NarrowbandBluetoothBannerState`);
/// this view only draws what the model publishes. It is part of the layout of each screen, above the content and not over
/// it (a safe-area inset on the 1:1 audio screen, a row of the column on the video and group screens), so it never sits
/// on a call control. Nothing is reserved while it is hidden: it draws nothing at all.
///
/// Design system as the other call banners: `qaudionType` roles (Dynamic Type), `qaudionScheme` and `qaudionExtras`
/// colours. The buttons keep a 44 pt touch area.
struct NarrowbandBluetoothBanner: View {

    @ObservedObject private var model = NarrowbandBluetoothBannerModel.shared
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Space left and right of the banner; each screen passes the margin of its own content.
    private let horizontalInset: CGFloat

    init(horizontalInset: CGFloat = 16) {
        self.horizontalInset = horizontalInset
    }

    var body: some View {
        Group {
            if model.isVisible {
                banner
                    .padding(.horizontal, horizontalInset)
                    .padding(.vertical, 6)
                    .transition(.opacity)
            }
        }
        .animation(fade, value: model.isVisible)
    }

    /// The fade of the banner; none with Reduce Motion on.
    private var fade: Animation? {
        if reduceMotion { return nil }
        return Animation.easeInOut(duration: 0.2)
    }

    // MARK: - Texts

    static var messageText: String {
        String(localized: "call.bt_narrowband.message",
               defaultValue: "Bluetooth a banda stretta: voce di qualità ridotta",
               comment: "In-call banner — the Bluetooth hands-free link runs at 8 kHz or less, so the voice quality is reduced")
    }

    static var usePhoneText: String {
        String(localized: "call.bt_narrowband.use_phone",
               defaultValue: "Usa il telefono",
               comment: "In-call banner — button that moves the call audio from the Bluetooth headset to the phone's own microphone and receiver")
    }

    static var usePhoneHint: String {
        String(localized: "call.bt_narrowband.use_phone_hint",
               defaultValue: "Sposta l'audio della chiamata sul microfono e sul ricevitore del telefono",
               comment: "Accessibility hint — the Use phone button of the narrowband Bluetooth banner")
    }

    static var dismissLabel: String {
        String(localized: "call.bt_narrowband.dismiss_a11y",
               defaultValue: "Nascondi avviso Bluetooth",
               comment: "Accessibility label — close button of the narrowband Bluetooth banner; hides it for the rest of the call")
    }

    // MARK: - Pieces

    private var banner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "headphones")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(extras.warning)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.messageText)
                    .qaudionStyle(type.labelMedium)
                    .foregroundStyle(scheme.onSurface)
                    .fixedSize(horizontal: false, vertical: true)
                usePhoneButton
            }
            Spacer(minLength: 0)
            dismissButton
        }
        .padding(.leading, 12)
        .padding(.trailing, 2)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(scheme.surfaceVariant)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(extras.warning.opacity(0.55), lineWidth: 1)
                )
        )
        .accessibilityElement(children: .contain)
        .onAppear {
            UIAccessibility.post(notification: .announcement, argument: Self.messageText)
        }
    }

    private var usePhoneButton: some View {
        Button {
            model.switchToPhone()
        } label: {
            Text(Self.usePhoneText)
                .qaudionStyle(type.labelMedium)
                .foregroundStyle(extras.warning)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .overlay(Capsule().stroke(extras.warning.opacity(0.6), lineWidth: 1))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Self.usePhoneHint)
    }

    private var dismissButton: some View {
        Button {
            model.dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(scheme.onSurfaceVariant)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.dismissLabel)
    }
}
