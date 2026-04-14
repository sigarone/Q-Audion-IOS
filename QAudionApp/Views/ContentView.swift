import SwiftUI
import QAudionEngine

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if appState.isInCall && appState.isVideoCall {
                VideoCallView()
            } else if appState.isInCall {
                CallView()
            } else if appState.isAuthenticated {
                HomeView()
            } else {
                NavigationView {
                    LoginView()
                }
                .navigationViewStyle(.stack)
            }
        }
        .animation(.easeInOut, value: appState.isAuthenticated)
        .animation(.easeInOut, value: appState.isInCall)
        .animation(.easeInOut, value: appState.isVideoCall)
    }
}
