import Foundation
import QAudionEngine

/// W441 — Periodic background sweep that deletes expired messages.
///
/// Mirrors Android's EphemeralMessageJanitor (feature-chat module).
/// Fires every 60 seconds on a background-friendly RunLoop.
/// Start once at app launch via `EphemeralMessageJanitor.shared.start()`.
///
/// Messages become eligible when `expiresAt` is non-nil and in the past.
/// The sweep delegates to `ConversationStore.deleteExpiredMessages()` which
/// runs a single SQL DELETE ... WHERE expiresAt IS NOT NULL AND expiresAt <= ?
final class EphemeralMessageJanitor {

    static let shared = EphemeralMessageJanitor()

    private let store: ConversationStore
    private var timer: Timer?

    private init(store: ConversationStore = ConversationStore()) {
        self.store = store
    }

    /// Start the janitor. Idempotent — safe to call multiple times.
    func start() {
        guard timer == nil else { return }
        // Run on a background thread; ConversationStore uses GRDB which is
        // thread-safe. We don't need to hop to main — no UI updates here.
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.sweep()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        sweep()   // immediate first pass on launch
    }

    private func sweep() {
        store.deleteExpiredMessages()
    }
}
