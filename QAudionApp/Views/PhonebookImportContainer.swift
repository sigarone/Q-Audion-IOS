import SwiftUI
import QAudionEngine

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

    private let coordinator: PhonebookSyncCoordinator

    /// Designated initializer — wires coordinator with the live AppState.
    init(appState: AppState) {
        self.coordinator = PhonebookSyncCoordinator(appState: appState)
        self.viewModel = PhonebookImportViewModel()  // starts at .introduction
    }

    // MARK: - Actions

    /// Called by the View's "Start" button.  Drives the full pipeline.
    func startImport() {
        Task {
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
                    unmatchedCount = max(0, p.validE164Count - matches.count)
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

    /// Allow the View to restart from the terminal `.error` or `.results` state.
    func reset() {
        viewModel = PhonebookImportViewModel()
        progress = nil
    }
}
