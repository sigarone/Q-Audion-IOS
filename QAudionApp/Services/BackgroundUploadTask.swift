import Foundation
import UIKit

/// W-BGUP: background-execution grace period for in-flight attachment
/// sends (voice note / image / file).
///
/// **What this solves.** `TusUploadClient.upload()` (and the small-file
/// multipart path) run inside a plain `Task` kicked off from
/// `ChatContainer.sendVoiceNote` / `sendImage` / `sendFileAttachment`. If
/// the user backgrounds the app mid-upload, iOS gives the process roughly
/// ~30 s (sometimes more) before suspending it — but ONLY if the app asks
/// for that grace period via `UIApplication.beginBackgroundTask`. Without
/// it, backgrounding can suspend the process mid-chunk with zero error
/// surfaced to the user (suspected root cause of a real 113 MB transfer
/// that silently stopped mid-upload).
///
/// **What this does NOT solve.** This is purely an in-process grace-period
/// extension — it does not survive the OS fully terminating the app, and
/// it does not persist upload state to resume after a cold relaunch. True
/// cross-launch TUS resume (using the server's `HEAD /files/tus/{id}`
/// endpoint to pick up where a killed process left off) is a separate,
/// deliberately deferred piece of work — see the note at the call sites
/// in `ChatContainer.swift`.
///
/// **A nuance worth being honest about.** Calling `endBackgroundTask`
/// (whether from the normal completion path or from the expiration
/// handler) does NOT itself cancel the in-flight `URLSession` task — it
/// only stops asking iOS for extra process time. The pending PATCH/POST
/// request may complete a moment later, or the OS may suspend/kill the
/// process shortly after the assertion ends before the request finishes.
/// Either way, from the caller's perspective the upload `Task` either
/// finishes normally or the underlying request eventually fails with a
/// network/cancellation error, which flows into the existing
/// `catch`/`markFailed(reason: .uploadFailure)` handling in
/// `ChatContainer` unchanged — no special-casing needed here beyond
/// logging that expiration fired.
enum BackgroundUploadTask {

    /// Runs `operation` under a `UIApplication.beginBackgroundTask`
    /// assertion, guaranteeing `endBackgroundTask` is called exactly once
    /// — on normal return, on thrown error, and (if the OS's grace period
    /// runs out first) from the expiration handler.
    ///
    /// - Parameters:
    ///   - name: passed through to `beginBackgroundTask(withName:)`,
    ///     surfaced in Xcode's background-task debugger / device logs.
    ///   - application: injected so this is unit-testable against a fake
    ///     conforming to `BackgroundTaskProviding` instead of the real
    ///     `UIApplication.shared` singleton. Defaults to the real app.
    ///   - operation: the async work to protect (upload + seal + announce
    ///     — the whole logical send, not just the raw byte-PATCH loop).
    ///
    /// If `beginBackgroundTask` itself returns `.invalid` (e.g. called
    /// from a context where the OS won't grant extra time, or under
    /// memory pressure), this degrades gracefully: `operation` still
    /// runs, just without the extra protection — never blocks, never
    /// throws on that account.
    static func run<T>(
        name: String,
        application: BackgroundTaskProviding = UIApplication.shared,
        operation: () async throws -> T
    ) async rethrows -> T {
        // Guards double-ending: the expiration handler and the normal
        // completion path both race to call `endOnce()`, and exactly one
        // of them must actually call `endBackgroundTask`. `NSLock` keeps
        // this correct even though the expiration handler fires
        // asynchronously (Apple's contract: main thread, once time is
        // nearly up — never synchronously inside `beginBackgroundTask`
        // itself) while the normal path may still be running on the
        // calling Task's executor.
        //
        // `state.assign(taskId)` runs synchronously immediately after
        // `beginBackgroundTask` returns, before any `await` — so by the
        // time the expiration handler could possibly fire, `state`
        // already has the real id (never reads a stale `.invalid`).
        let state = EndOnceGuard()

        let taskId = application.beginBackgroundTask(withName: name) {
            // Expiration handler: the OS is telling us the grace period
            // is up. We cannot force-cancel the in-flight URLSession
            // request from here (no reference to it at this layer), and
            // we don't need to — see the type-level doc comment on why
            // ending the assertion is sufficient and the natural failure
            // path already covers this. Best-effort: log + end exactly
            // once.
            print("[BackgroundUploadTask] '\(name)' expired — grace period ran out before completion")
            state.endOnce(application)
        }
        state.assign(taskId)

        if taskId == .invalid {
            // beginBackgroundTask couldn't grant an assertion. Degrade
            // gracefully: run unprotected rather than blocking the send.
            print("[BackgroundUploadTask] '\(name)' beginBackgroundTask returned .invalid — proceeding without background protection")
        }

        defer {
            // Normal exit path (success or thrown error). If the
            // expiration handler already fired and ended the task, this
            // is a no-op (EndOnceGuard enforces exactly-once).
            state.endOnce(application)
        }

        return try await operation()
    }

    /// Serializes the "end at most once" race between the expiration
    /// handler (which can fire on an arbitrary queue) and the normal
    /// completion path.
    private final class EndOnceGuard: @unchecked Sendable {
        private let lock = NSLock()
        private var taskId: UIBackgroundTaskIdentifier = .invalid
        private var ended = false

        func assign(_ id: UIBackgroundTaskIdentifier) {
            lock.lock()
            defer { lock.unlock() }
            taskId = id
        }

        func endOnce(_ application: BackgroundTaskProviding) {
            lock.lock()
            let id = taskId
            let alreadyEnded = ended
            ended = true
            lock.unlock()

            guard !alreadyEnded, id != .invalid else { return }
            application.endBackgroundTask(id)
        }
    }
}

/// Thin seam over the two `UIApplication` background-task APIs so
/// `BackgroundUploadTask.run` can be exercised with a fake in unit tests
/// without touching the real `UIApplication.shared` singleton (which
/// isn't meaningfully usable outside a running app host).
protocol BackgroundTaskProviding {
    func beginBackgroundTask(withName taskName: String?, expirationHandler handler: (() -> Void)?) -> UIBackgroundTaskIdentifier
    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier)
}

extension UIApplication: BackgroundTaskProviding {}
