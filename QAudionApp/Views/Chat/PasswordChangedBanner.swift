import SwiftUI

/// Non-blocking notice on the chat list: another device changed this account's password. Dismissable;
/// the state lives on `AppState.passwordChangedElsewhere`.
struct PasswordChangedBanner: View {
    @Binding var isVisible: Bool

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    var body: some View {
        if isVisible {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "key.fill")
                    .qaudionScaledFont(size: 16, weight: .semibold)
                    .foregroundStyle(extras.warning)
                    .padding(.top, 2)
                Text(Self.messageText)
                    .qaudionStyle(type.bodySmall)
                    .foregroundStyle(scheme.onSurface)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    isVisible = false
                } label: {
                    Image(systemName: "xmark")
                        .qaudionScaledFont(size: 13, weight: .semibold)
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .padding(6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.dismissText)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(extras.warning.opacity(0.18))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(extras.warning.opacity(0.45), lineWidth: 1)
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .accessibilityElement(children: .contain)
        }
    }

    static var messageText: String {
        String(localized: "account_notice.password_changed.banner",
               defaultValue: "Password cambiata su un altro dispositivo; se non sei stato tu contatta l'amministratore.",
               comment: "Banner on the chat list: another device changed the account password.")
    }

    static var dismissText: String {
        String(localized: "account_notice.password_changed.dismiss",
               defaultValue: "Chiudi",
               comment: "Accessibility label of the button that closes the password-changed banner.")
    }
}
