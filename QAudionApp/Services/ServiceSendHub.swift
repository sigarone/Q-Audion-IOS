import Foundation
import QAudionEngine

/// 2026-09-19 service-message root fix — the app's single
/// `ServiceSendCoordinator` (the bounded per-peer hold queue for service
/// payloads that cannot be sealed on CONTROL yet).
///
/// Primitive closures only (CLAUDE.md §16): `AppState.wireServiceSendHub`
/// binds them (from `AppState.initialize()`, and again on every
/// `connectPersistentSocket`), each reading the CURRENT provider / ratchet at
/// call time, so a provider swap needs nothing beyond `configure` running
/// again — and the held queue survives it. The one thing that clears the queue
/// is `reset()`: the account it belongs to is gone.
@MainActor
final class ServiceSendHub {

    static let shared = ServiceSendHub()

    private var coordinator: ServiceSendCoordinator?

    /// Idempotent. First call creates the coordinator; later calls only swap
    /// its hooks.
    func configure(
        hasControlSession: @escaping ServiceSendCoordinator.ControlSessionCheck,
        isSocketReady: @escaping ServiceSendCoordinator.SocketReadyCheck,
        ensureSession: @escaping ServiceSendCoordinator.SessionEnsurer,
        sealAndSend: @escaping ServiceSendCoordinator.Shipper
    ) {
        let hooks = ServiceSendCoordinator.Hooks(
            nowMs: { Int64(Date().timeIntervalSince1970 * 1000) },
            hasControlSession: hasControlSession,
            isSocketReady: isSocketReady,
            ensureSession: ensureSession,
            sealAndSend: sealAndSend,
            log: { line in RTLog.warn("chat", line) }
        )
        if let existing = self.coordinator {
            existing.replaceHooks(hooks)
        } else {
            self.coordinator = ServiceSendCoordinator(hooks: hooks)
        }
    }

    func submit(
        peerId: String,
        plaintext: String,
        label: String,
        delivery: ServiceSendCoordinator.Delivery
    ) async -> ServiceSendCoordinator.Submission {
        guard let coordinator = self.coordinator else {
            RTLog.warn("chat", "service_send dropped=1 reason=unconfigured label=\(label)")
            return .dropped
        }
        return await coordinator.submit(
            peerId: peerId, plaintext: plaintext, label: label, delivery: delivery)
    }

    /// A CONTROL session was just installed for `peerId` (call handshake or
    /// pre-bootstrap): flush whatever is held for them.
    func controlSessionInstalled(peerId: String) {
        self.coordinator?.controlSessionInstalled(peerId: peerId)
    }

    /// The persistent socket just authenticated: flush every held peer.
    func socketBecameReady() {
        self.coordinator?.socketBecameReady()
    }

    /// Logout, remote wipe or account deletion: whatever is held is plaintext
    /// for the account that just left and must never be flushed under the next
    /// identity. The coordinator itself (and its hooks) stays.
    func reset() {
        self.coordinator?.reset()
    }
}
