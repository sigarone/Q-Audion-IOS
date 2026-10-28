import Foundation
import QAudionEngine

/// Keeps the notification key of this installation registered with the server.
///
/// The key (X25519, in the notify keychain group) is created when first needed and registered with
/// `PUT /api/v1/account/notify-key` only right after the server accepted the APNs alert token, and again after every
/// such registration. A `409 no_alert_token` is not retried in a loop: the next alert-token registration sends the key
/// again. Logout deletes the key on the server and on the device.
@MainActor
final class NotifyKeyService {

    static let shared = NotifyKeyService()

    private var inFlight = NotifyKeyInFlight()

    private init() {}

    /// Call after the server answered an alert-token registration with success.
    func alertTokenRegistered(serverUrl: String, bearer: String?, session: URLSession) {
        guard NotifyKeyRegistration.shouldRegister(
            authenticated: bearer?.isEmpty == false, alertTokenJustRegistered: true),
              let bearer,
              let keychain = NotifyKeychain.production(),
              let key = NotifyKeyRegistration.ensureKey(in: keychain),
              let request = NotifyKeyRegistration.putRequest(
                serverUrl: serverUrl, publicBase64: key.publicBase64, bearer: bearer),
              let ticket = inFlight.begin() else { return }
        Task { [weak self, session] in
            var status: Int?
            do {
                let (_, response) = try await session.data(for: request)
                status = (response as? HTTPURLResponse)?.statusCode
            } catch {
                status = nil
            }
            let outcome = NotifyKeyRegistration.outcome(statusCode: status)
            if outcome != .registered { print("[NotifyKey] registration not done: \(outcome)") }
            await MainActor.run { self?.inFlight.finish(ticket: ticket) }
        }
    }

    /// Logout: asks the server to forget the key (best effort, with the bearer of the session that is ending) and
    /// removes everything notification-related that is local.
    func accountLeft(serverUrl: String, bearer: String?, session: URLSession) {
        if let bearer, !bearer.isEmpty,
           let request = NotifyKeyRegistration.deleteRequest(serverUrl: serverUrl, bearer: bearer) {
            Task { _ = try? await session.data(for: request) }
        }
        wipeLocal()
    }

    /// Deletes the local key and the list of names and avatars (logout, remote wipe, account deletion).
    func wipeLocal() {
        NotifyKeychain.production()?.delete()
        // What the extension donated to Siri belongs to the account that left.
        NotifyDonations.deleteAll()
        NotifyRubricaSync.shared.clear()
        inFlight.reset()
    }
}
