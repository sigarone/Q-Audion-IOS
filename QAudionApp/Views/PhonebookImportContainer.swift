import SwiftUI
import QAudionEngine
import Contacts

/// Container / presenter that drives `PhonebookImportView` through its full
/// state machine by delegating to `PhonebookSyncCoordinator`.
///
/// Lifecycle:
///   introduction → requestingPermission → scanning → discovering → results
///                                        ↘ error (at any step)
@MainActor
final class PhonebookImportContainer: ObservableObject {

    @Published private(set) var viewModel: PhonebookImportViewModel
    @Published private(set) var progress: PhonebookSyncCoordinator.ScanProgress?
    /// Whether the system has not asked for Contacts access yet: the first screen is then the one that leads to the request.
    /// True while the system Contacts request is on screen: the button that opened it is disabled meanwhile.
    @Published private(set) var requestingSystemPermission: Bool = false
    @Published private(set) var permissionNotDetermined: Bool = CNContactStore.authorizationStatus(for: .contacts) == .notDetermined

    private let coordinator: PhonebookSyncCoordinator

    /// Designated initializer — wires coordinator with the live AppState.
    init(appState: AppState) {
        self.coordinator = PhonebookSyncCoordinator(appState: appState)
        self.viewModel = PhonebookImportViewModel()  // starts at .introduction
    }

    // MARK: - Actions

    /// Called by "Continua" on the screen shown before the system Contacts request: asks for the permission and nothing
    /// else. Nothing is scanned or sent; the import starts only when the user taps "Importa" afterwards.
    func requestPermissionOnly() {
        guard !requestingSystemPermission else { return }
        requestingSystemPermission = true
        Task { [self] in
            let granted = (try? await coordinator.requestPermission()) ?? false
            requestingSystemPermission = false
            permissionNotDetermined = CNContactStore.authorizationStatus(for: .contacts) == .notDetermined
            if !granted {
                viewModel.transition(to: .error(
                    message: PhonebookSyncCoordinator.Error.permissionDenied.localizedDescription
                ))
            }
        }
    }

    /// Called by the View's "Importa" button.  Drives the full pipeline.
    func startImport() {
        Task { [self] in
            do {
                // 1. Request Contacts permission.
                viewModel.transition(to: .requestingPermission)
                let granted = try await coordinator.requestPermission()
                guard granted else {
                    viewModel.transition(to: .error(
                        message: PhonebookSyncCoordinator.Error.permissionDenied.localizedDescription
                    ))
                    return
                }

                // 2. Scanning — show indeterminate progress until enumeration finishes.
                viewModel.transition(to: .scanning(progress: 0))

                // 3. Run the full scan + discover pipeline.
                //    Progress closure is called twice:
                //      - After local enumeration (resolvedUserCount == 0).
                //      - After discover-v2 completes (resolvedUserCount > 0).
                let matches = try await coordinator.scanAndDiscover { [weak self] p in
                    guard let self else { return }
                    self.progress = p
                    if p.resolvedUserCount == 0 {
                        // Enumeration complete; transition to "discovering".
                        let scanFraction = p.totalContacts > 0
                            ? Double(p.processedContacts) / Double(p.totalContacts)
                            : 1.0
                        self.viewModel.transition(to: .scanning(progress: scanFraction))
                        self.viewModel.transition(to: .discovering(progress: 0))
                    }
                    // The second callback (resolvedUserCount > 0) is followed immediately
                    // by the results transition below — no separate step needed.
                }

                // 4. Results.
                let vmMatches: [PhonebookImportViewModel.Match] = matches.map { m in
                    PhonebookImportViewModel.Match(
                        userId: m.userId,
                        localName: m.displayName,
                        phoneHash: m.phoneHash
                    )
                }
                let unmatchedCount: Int
                if let p = progress {
                    unmatchedCount = unmatchedNumbers(p, matchCount: matches.count)
                } else {
                    unmatchedCount = 0
                }
                viewModel.transition(to: .results(
                    matched: vmMatches,
                    unmatched: unmatchedCount
                ))

            } catch {
                viewModel.transition(to: .error(message: error.localizedDescription))
            }
        }
    }

    /// Numbers that were looked up and are not on Q-Audion. Numbers the server never
    /// looked up (rate limit) are not "not on Q-Audion", so they are left out of this
    /// count; the results screen reports them through `incompleteNotice` instead.
    private func unmatchedNumbers(_ p: PhonebookSyncCoordinator.ScanProgress, matchCount: Int) -> Int {
        // Both operands count numbers: `validE164Count` every normalized number,
        // `pendingNumberCount` the numbers whose hash was not looked up (a hash
        // count would undercount when several contacts share a number).
        let lookedUp: Int = p.validE164Count - p.pendingNumberCount
        let unmatched: Int = lookedUp - matchCount
        return max(0, unmatched)
    }

    /// Shown on the results screen when the discovery pass was stopped part-way
    /// (server rate limit), so the user knows the list may be missing people and
    /// that running the import again continues the search. Nil for a full pass.
    var incompleteNotice: String? {
        guard let p = progress, p.pendingNumberCount > 0 else { return nil }
        let pending: Int = p.pendingNumberCount
        guard let wait = p.retryAfterSeconds else {
            let plain: String = String(localized: "contact.phonebook.partial_notice", defaultValue: "Ricerca parziale: \(pending) numeri non ancora controllati. Riprova più tardi.", comment: "Notice on the address-book import results when the server stopped the search part-way. %lld is how many phone numbers were not checked yet")
            return plain
        }
        let timed: String = String(localized: "contact.phonebook.partial_notice_wait", defaultValue: "Ricerca parziale: \(pending) numeri non ancora controllati. Riprova tra circa \(wait) secondi.", comment: "Notice on the address-book import results when the server stopped the search part-way and asked to wait. First %lld is how many phone numbers were not checked yet, second %lld is the number of seconds to wait")
        return timed
    }

    /// Allow the View to restart from the terminal `.error` or `.results` state.
    func reset() {
        viewModel = PhonebookImportViewModel()
        progress = nil
    }
}
