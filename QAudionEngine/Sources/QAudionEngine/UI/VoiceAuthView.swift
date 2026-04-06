#if canImport(SwiftUI)
import SwiftUI

public struct VoiceAuthView: View {
    @State private var isAuthenticating = false
    @State private var authResult: String?
    @State private var challenge = "Say: one four seven two"

    public var onAuthenticated: ((Bool) -> Void)?

    public init(onAuthenticated: ((Bool) -> Void)? = nil) {
        self.onAuthenticated = onAuthenticated
    }

    public var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "person.wave.2.fill")
                .font(.system(size: 64))
                .foregroundColor(.blue)

            Text("Voice Authentication Required")
                .font(.title2)
                .fontWeight(.bold)

            Text(challenge)
                .font(.title3)
                .foregroundColor(.secondary)
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)

            Button(isAuthenticating ? "Listening..." : "Authenticate") {
                isAuthenticating = true
                // Simulate authentication
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    isAuthenticating = false
                    authResult = "Authenticated"
                    onAuthenticated?(true)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isAuthenticating)

            if let result = authResult {
                Label(result, systemImage: "checkmark.shield.fill")
                    .foregroundColor(.green)
            }

            Spacer()
        }
        .padding()
    }
}
#endif
