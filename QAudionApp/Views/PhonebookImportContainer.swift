import SwiftUI
import QAudionEngine

@MainActor
final class PhonebookImportContainer: ObservableObject {
    @Published var viewModel: PhonebookImportViewModel = PhonebookImportViewModel()

    private let coordinator: PhonebookSyncCoordinator

    init(coordinator: PhonebookSyncCoordinator = PhonebookSyncCoordinator()) {
        self.coordinator = coordinator
    }

    func startImport() async {
        viewModel.transition(to: .requestingPermission)
        let granted = await coordinator.requestPermission()
        guard granted else {
            viewModel = PhonebookImportViewModel(
                step: .error(message: "Contacts permission denied"),
                totalLocalContacts: 0, permissionDenied: true
            )
            return
        }

        viewModel.transition(to: .scanning(progress: 0))
        do {
            let contacts = try coordinator.scanLocalContacts()
            viewModel = PhonebookImportViewModel(
                step: .scanning(progress: 1.0),
                totalLocalContacts: contacts.count
            )
            viewModel.transition(to: .discovering(progress: 0))
            // Discovery requires pepper from server first — for now, simulate.
            // Real wire-up: fetch pepper via BCryptoContactsDiscoverV2Client.fetchPepper(),
            // then call discover. Pepper fetch + discover is a single async chain.
            viewModel.transition(to: .results(matched: [], unmatched: contacts.count))
        } catch {
            viewModel.transition(to: .error(message: error.localizedDescription))
        }
    }
}
