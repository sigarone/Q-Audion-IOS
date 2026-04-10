import SwiftUI
import QAudionEngine

@main
struct QAudionApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .onAppear { appState.initialize() }
        }
    }
}
