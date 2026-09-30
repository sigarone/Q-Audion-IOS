import XCTest
@testable import QAudionApp

/// Pins `AppState.resolveFilesServerUrl` — the selection rule behind
/// `AppState.filesServerUrl`, the accessor legacy `/api/v1/files/{id}`
/// avatar/thumbnail URL construction sites (`ChatListScreen`,
/// `GroupChatScreen`, `ContentView`, `DiagnosticsExportScreen`) now read
/// instead of `serverUrl` directly.
///
/// `serverUrl` is whatever `ServerSelector` currently points calling/
/// signaling traffic at, and can legitimately be a DR/failover node with no
/// shared file storage. `filesServerUrl` must keep resolving to the
/// certificate-pinned primary (`BCryptoRestClient.pinnedPrimaryServerUrl`,
/// read through `AppState.liveProvider`) regardless of where `serverUrl`
/// has moved, falling back to `serverUrl` only when there is no live
/// provider yet to read a pinned value from.
///
/// `resolveFilesServerUrl` takes the already-read `pinnedPrimary` value
/// rather than an `AppState`/`BCryptoBackendProvider` instance, precisely so
/// this selection logic is a pure function testable without a live
/// provider, network, or server config.
///
/// Wired into CI: this file is on the include list of
/// `QAudionApp/project-apptests.yml` (an app-hosted unit-test bundle limited to
/// the files listed there) and runs in `.github/workflows/ios-app-tests.yml`.
/// The rest of `QAudionAppTests/` still has no target. Keep this file pure: it
/// must not need a Keychain or engine static state.
///
/// `@MainActor` on the class (review fix, 2026-09-30): `AppState` itself
/// is `@MainActor`, which isolates ALL of its members, including static
/// ones — `resolveFilesServerUrl` is a `static func` on `AppState`, so
/// it's MainActor-isolated too, and calling it from a plain synchronous
/// `XCTestCase` method (no actor context) does not type-check. Same
/// pattern `CapabilityGateTests`/`ContactsListContainerProximityPairingTests`
/// already use for the identical reason.
@MainActor
final class AppStateFilesServerUrlTests: XCTestCase {

    /// The whole point of the fix: once a live provider exists, its pinned
    /// primary wins even when `serverUrl` (post-failover) disagrees.
    func test_pinnedPrimary_windsOverServerUrlOnFailover() {
        let resolved = AppState.resolveFilesServerUrl(
            pinnedPrimary: "https://primary.example.invalid",
            fallback: "https://failover.example.invalid")
        XCTAssertEqual(resolved, "https://primary.example.invalid")
    }

    /// Normal case (no failover): pinned primary and `serverUrl` agree, so
    /// this is also just a not-a-regression check.
    func test_pinnedPrimary_matchesServerUrl_whenNoFailoverHappened() {
        let resolved = AppState.resolveFilesServerUrl(
            pinnedPrimary: "https://primary.example.invalid",
            fallback: "https://primary.example.invalid")
        XCTAssertEqual(resolved, "https://primary.example.invalid")
    }

    /// No live provider yet (e.g. before first connect) — nothing pinned to
    /// read, so falling back to `serverUrl` is the only option, not a bug.
    func test_noPinnedValue_fallsBackToServerUrl() {
        let resolved = AppState.resolveFilesServerUrl(
            pinnedPrimary: nil,
            fallback: "https://primary.example.invalid")
        XCTAssertEqual(resolved, "https://primary.example.invalid")
    }
}
