import SwiftUI

/// Root view of the Q-Audion app. Routes between auth flow and main app.
/// This is the SwiftUI entry point matching Android's QAudionNavGraph.
public struct QAudionRootView: View {
    @StateObject private var appState = QAudionAppState()

    public init() {}

    public var body: some View {
        Group {
            switch appState.authState {
            case .loading:
                splashView
            case .welcome:
                WelcomeView()
                    .environmentObject(appState)
            case .login:
                LoginView()
                    .environmentObject(appState)
            case .sovereignSetup:
                SovereignSetupView()
                    .environmentObject(appState)
            case .authenticated:
                QAudionMainView()
                    .environmentObject(appState)
            }
        }
        .qAudionTheme()
    }

    private var splashView: some View {
        ZStack {
            QColors.deepSpace.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "shield.checkered")
                    .font(.system(size: 64))
                    .foregroundColor(QColors.qGreen)
                Text("Q-Audion")
                    .font(.title.bold())
                    .foregroundColor(QColors.textPrimary)
                ProgressView()
                    .tint(QColors.qGreen)
            }
        }
    }
}
