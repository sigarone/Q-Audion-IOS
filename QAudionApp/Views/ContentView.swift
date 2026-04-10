import SwiftUI
import QAudionEngine

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if appState.isAuthenticated && appState.isInCall {
                CallView()
            } else if appState.isAuthenticated {
                HomeView()
            } else {
                NavigationStack {
                    LoginView()
                }
            }
        }
        .animation(.easeInOut, value: appState.isAuthenticated)
        .animation(.easeInOut, value: appState.isInCall)
    }
}
