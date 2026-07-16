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
///
/// W-XPTTL: also sweeps `GroupMessageStore` — group attachments gained a
/// TTL/view-once field this stage and had NO expiry sweep whatsoever
/// before it (unlike the 1:1 path, which this janitor already covered).
/// `GroupMessageStore` is `@MainActor`-isolated (UserDefaults-backed, not
/// GRDB), so that half of the sweep hops to the main actor via `Task`
/// rather than running inline like the GRDB-backed 1:1 half above.
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
        // W-XPTTL: GroupMessageStore is @MainActor-isolated; hop via Task
        // rather than requiring this whole class (and its Timer-driven
        // nonisolated `sweep()`) to become MainActor-isolated just for
        // this one call.
        Task { @MainActor in
            GroupMessageStore.shared.deleteExpiredMessages()
        }
    }
}
