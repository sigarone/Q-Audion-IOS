import SwiftUI
import QAudionEngine

struct RegisterView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var userId = ""
    @State private var credential = ""
    @State private var confirmCredential = ""
    @State private var serverUrl = "https://bcrypto.example.com"
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showError = false

    private var passwordsMatch: Bool {
        !credential.isEmpty && credential == confirmCredential
    }

    private var formValid: Bool {
        !userId.isEmpty && passwordsMatch
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "person.badge.shield.checkmark.fill")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("Create Account")
                .font(.title)
                .fontWeight(.bold)

            VStack(spacing: 16) {
                TextField("User ID", text: $userId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(10)

                SecureField("Credential", text: $credential)
                    .textContentType(.newPassword)
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(10)

                SecureField("Confirm Credential", text: $confirmCredential)
                    .textContentType(.newPassword)
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(10)

                if !confirmCredential.isEmpty && !passwordsMatch {
                    Label("Credentials do not match", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

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

            Button(action: register) {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text("Create Account")
                        .fontWeight(.semibold)
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(formValid ? Color.blue : Color.blue.opacity(0.4))
            .foregroundStyle(.white)
            .cornerRadius(12)
            .disabled(!formValid || isLoading)
            .padding(.horizontal)

            Spacer()
        }
        .padding()
        .navigationTitle("Register")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Registration Failed", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
    }

    private func register() {
        isLoading = true
        errorMessage = nil
        appState.serverUrl = serverUrl
        Task {
            do {
                _ = try await appState.authService.register(
                    phoneNumber: userId, inviteCode: credential, serverUrl: serverUrl
                )
                await appState.login(userId: userId, credential: credential)
                if appState.isAuthenticated { dismiss() }
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
            isLoading = false
        }
    }
}
