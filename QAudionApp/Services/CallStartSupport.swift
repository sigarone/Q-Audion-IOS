import Foundation

// Two small, dependency-free pieces extracted from `AppState` so that the call
// start path has real, running unit coverage (AppState itself is a large
// dependency-injected @MainActor class with no lightweight test init):
//
//  - `CallStartGate`: the in-flight latch for `startCall`.
//  - `CallEngineLifecycle`: who owns the call engine, and how it comes back
//    after a logout.
//
// Both are generic over / independent of the engine type on purpose, so the
// app-hosted test bundle (which does not link QAudionEngine, see
// `QAudionApp/project-apptests.yml`) can drive them with a stand-in.

/// In-flight latch for `AppState.startCall`.
///
/// `startCall` used to dedupe only on `isInCall`, which it set somewhere after
/// a long run of side effects (Siri donation, telemetry, banner resets). Two
/// starts fired from one tap (audio + video in the same millisecond, report
/// 1caed57d) therefore both did all of that work before the second one was
/// rejected, and the rejected one still reset the banners of the call that
/// had just been admitted. The gate is taken as the very first statement, so
/// a second start is refused before it touches anything.
///
/// Contract: `tryBegin()` is called synchronously at the top of the start,
/// BEFORE any `await`; `end()` is called once the start has either committed
/// (`isInCall` took over as the guard) or failed. Not thread-safe by design:
/// it is only ever touched from the main actor.
struct CallStartGate {
    private(set) var inFlight = false

    /// Returns true when the caller now owns the gate. False means another
    /// start is already between entry and commit.
    mutating func tryBegin() -> Bool {
        if inFlight { return false }
        inFlight = true
        return true
    }

    /// Releases the gate. Safe to call when it is not held.
    mutating func end() {
        inFlight = false
    }
}

/// What `CallEngineLifecycle.ensure` did.
enum CallEngineEnsureOutcome: Equatable {
    /// An engine already existed; nothing was created.
    case existing
    /// First engine of this process.
    case created
    /// A new engine, after an earlier one had been torn down (logout).
    case recreated
    /// The factory threw; there is no engine. The next `ensure` retries.
    case failed(String)
}

/// Owns the one call engine and makes (re)creation idempotent.
///
/// The engine used to be created once, from `AppState.initialize()` (which
/// runs once per process, at launch) and set to nil by `logout()`. After a
/// logout and a new login nothing ever created it again, so every call
/// aborted with "engine not available" until the app was relaunched (report
/// bea72b22). `ensure` is now called on login and again at the start of every
/// call, so a missing engine is rebuilt on demand and an existing one is
/// never replaced (no second instance, nothing to leak).
///
/// `Engine` is a class so the previous instance can be handed to `release`
/// exactly once; the closures keep this type free of the concrete engine.
final class CallEngineLifecycle<Engine: AnyObject> {
    private let make: () throws -> Engine
    private let release: (Engine) -> Void
    private(set) var engine: Engine?
    /// How many engines this lifecycle has built successfully. Distinguishes
    /// "created" from "recreated" for logging.
    private(set) var builtCount = 0

    init(make: @escaping () throws -> Engine, release: @escaping (Engine) -> Void) {
        self.make = make
        self.release = release
    }

    /// Returns the existing engine, or builds one. Never builds a second
    /// engine while one exists.
    @discardableResult
    func ensure() -> CallEngineEnsureOutcome {
        if engine != nil { return .existing }
        do {
            let fresh = try make()
            engine = fresh
            builtCount += 1
            return builtCount == 1 ? .created : .recreated
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// Releases and drops the engine (logout). A no-op when there is none.
    /// Returns true when an engine was actually torn down.
    @discardableResult
    func teardown() -> Bool {
        guard let current = engine else { return false }
        engine = nil
        release(current)
        return true
    }
}
