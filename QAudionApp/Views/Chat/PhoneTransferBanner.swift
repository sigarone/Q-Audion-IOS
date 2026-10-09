import SwiftUI
import QAudionEngine

/// Banner shown to the holder of a login phone number while someone else's request to move that
/// number is waiting. It says what is happening, how long is left, and offers one action: cancel the
/// transfer. Without an action the number stops being a way into this account when the time is up.
///
/// The state is `PhoneTransferNoticeModel`, fed from the server on every entry point; this view only
/// draws it. Takes the model, never `AppState` (CLAUDE.md section 16). The hours left (rounded down,
/// "less than 1 hour" below the first) are computed from the server's expiry on a one-minute tick. The
/// banner stays until the server stops listing the transfer: the device clock never hides it.
struct PhoneTransferBanner: View {
    @ObservedObject var model: PhoneTransferNoticeModel

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let pending = model.current {
                card(hours: pending.hoursRemaining(at: context.date))
            }
        }
    }

    private func card(hours: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(extras.warning)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(Self.titleText)
                        .qaudionStyle(type.titleSmall)
                        .foregroundStyle(scheme.onSurface)
                    Text(hours < 1 ? Self.expirySoonText : Self.expiryText(hours: hours))
                        .qaudionStyle(type.labelLarge)
                        .foregroundStyle(scheme.onSurface)
                    Text(Self.infoText)
                        .qaudionStyle(type.bodySmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                    Text(Self.cancelNoteText)
                        .qaudionStyle(type.bodySmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                }
            }
            if let message = problemText {
                Text(message)
                    .qaudionStyle(type.bodySmall)
                    .foregroundStyle(extras.riskHigh)
            }
            actions
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

    private var actions: some View {
        HStack(spacing: 12) {
            QAudionButton(
                action: cancelTransfer,
                label: Self.cancelText,
                variant: .primary,
                loading: model.isCancelling
            )
            if model.problem == .refreshFailed {
                Button(action: retryRefresh) {
                    Text(Self.retryText)
                        .qaudionStyle(type.labelLarge)
                        .foregroundStyle(scheme.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var problemText: String? {
        switch model.problem {
        case .refreshFailed: return Self.refreshFailedText
        case .cancelFailed: return Self.cancelFailedText
        case nil: return nil
        }
    }

    private func cancelTransfer() {
        Task { await model.cancel() }
    }

    private func retryRefresh() {
        Task { await model.refresh() }
    }

    // MARK: - Texts

    static var titleText: String {
        String(localized: "phone_transfer.title",
               defaultValue: "Qualcuno sta spostando il numero di telefono collegato a questo account",
               comment: "Banner shown to the account holder while someone else's request to move the phone number linked to the account is waiting.")
    }

    static func expiryText(hours: Int) -> String {
        String(localized: "phone_transfer.expiry",
               defaultValue: "Scadenza tra circa \(hours) h",
               comment: "Phone number transfer banner: time left before the transfer completes; %lld is the number of hours, h is the abbreviation for hours.")
    }

    static var expirySoonText: String {
        String(localized: "phone_transfer.expiry_soon",
               defaultValue: "Scadenza tra meno di 1 ora",
               comment: "Phone number transfer banner: less than one hour is left before the transfer completes.")
    }

    static var infoText: String {
        String(localized: "phone_transfer.info",
               defaultValue: "Se non fai nulla, alla scadenza il numero non sarà più un accesso a questo account.",
               comment: "Phone number transfer banner: what happens if the holder does nothing.")
    }

    static var cancelNoteText: String {
        String(localized: "phone_transfer.cancel_note",
               defaultValue: "Se annulli, per 24 ore non verranno accettate nuove richieste di spostamento per questo numero.",
               comment: "Phone number transfer banner: what cancelling does, new requests for the number are refused for 24 hours.")
    }

    static var cancelText: String {
        String(localized: "phone_transfer.cancel",
               defaultValue: "Annulla il trasferimento",
               comment: "Phone number transfer banner: button that cancels the transfer.")
    }

    static var retryText: String {
        String(localized: "phone_transfer.retry",
               defaultValue: "Riprova",
               comment: "Phone number transfer banner: button that reads the transfer status again after a failure.")
    }

    static var cancelFailedText: String {
        String(localized: "phone_transfer.error.cancel",
               defaultValue: "Non è stato possibile annullare il trasferimento. Controlla la connessione e riprova.",
               comment: "Phone number transfer banner: the cancel request failed (network or server error); the button stays available.")
    }

    static var refreshFailedText: String {
        String(localized: "phone_transfer.error.refresh",
               defaultValue: "Non è stato possibile aggiornare lo stato del trasferimento. Riprova.",
               comment: "Phone number transfer banner: the status could not be read (network or server error).")
    }
}
