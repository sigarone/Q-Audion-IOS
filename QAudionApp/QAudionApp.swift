import SwiftUI
import QAudionEngine

@main
struct QAudionApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .onAppear {
                    // W416: capture every print()/stderr line into the
                    // ring buffer FROM LAUNCH, with auto-rotation FIFO
                    // 5000 entries (≈ 1.25MB). The user can grab the
                    // dump anytime via Settings → Diagnostica → Carica
                    // al server, no opt-in needed; after ~50 calls the
                    // buffer simply wraps over and never grows further.
                    RuntimeLogSink.shared.attachStdoutTee()
                    appState.initialize()
                }
        }
    }
}
