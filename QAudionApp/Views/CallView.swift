import SwiftUI
import QAudionEngine

// MARK: - CallView (navigation entry point — preserved)

/// Navigation entry point for the in-call screen. Keeps its place in the SwiftUI
/// navigation graph; body is now delegated to InCallView via InCallContainer.
///
/// @StateObject requires the wrapped value at init time, but EnvironmentObject
/// is only available after body evaluation. The private `InCallContainerHost`
/// inner view receives `appState` as a plain argument so `@StateObject` can
/// be initialised correctly.
struct CallView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        InCallContainerHost(appState: appState)
    }
}

// MARK: - InCallContainerHost

/// Private host that owns the @StateObject InCallContainer.
/// Separated from CallView so the EnvironmentObject is available before
/// @StateObject is initialized.
private struct InCallContainerHost: View {
    @StateObject private var container: InCallContainer

    init(appState: AppState) {
        _container = StateObject(wrappedValue: InCallContainer(appState: appState))
    }

    var body: some View {
        InCallView(container: container)
    }
}
