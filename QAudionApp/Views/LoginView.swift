import SwiftUI
import QAudionEngine

struct LoginView: View {
    @EnvironmentObject var appState: AppState

    @State private var userId = ""
    @State private var credential = ""
    @State private var serverUrl = "https://bcrypto.example.com"
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "shield.lock.fill")
                .font(.system(size: 56))
                .foregroundStyle(.blue)

            Text("Q-Audion")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Post-Quantum Encrypted Calls")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(spacing: 16) {
                TextField("User ID", text: $userId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(10)

                SecureField("Credential", text: $credential)
                    .textContentType(.password)
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(10)

                TextField("Server URL", text: $serverUrl)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(10)
            }
            .padding(.horizontal)

            Button(action: signIn) {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text("Sign In")
                        .fontWeight(.semibold)
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(userId.isEmpty || credential.isEmpty ? Color.blue.opacity(0.4) : Color.blue)
            .foregroundStyle(.white)
            .cornerRadius(12)
            .disabled(userId.isEmpty || credential.isEmpty || isLoading)
            .padding(.horizontal)

            NavigationLink("Create Account") {
                RegisterView()
            }
            .font(.footnote)

            Spacer()
        }
        .padding()
        .alert("Sign In Failed", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
    }

    private func signIn() {
        isLoading = true
        errorMessage = nil
        appState.serverUrl = serverUrl
        appState.userId = userId
        appState.credential = credential
        appState.login { error in
            isLoading = false
            if let error {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }
}
