import SwiftUI

/// Welcome/onboarding view matching Android WelcomeActivity.
public struct WelcomeView: View {
    @EnvironmentObject var appState: QAudionAppState

    public init() {}

    public var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Logo
            Image(systemName: "shield.checkered")
                .font(.system(size: 80))
                .foregroundColor(QColors.qGreen)

            Text("Q-Audion")
                .font(.largeTitle.bold())
                .foregroundColor(QColors.textPrimary)

            Text("Comunicazioni sicure\npost-quantistiche")
                .font(.title3)
                .foregroundColor(QColors.textSecondary)
                .multilineTextAlignment(.center)

            Spacer()

            // Feature badges
            VStack(spacing: 12) {
                featureBadge("lock.shield.fill", "Crittografia ML-KEM-1024 + X25519")
                featureBadge("waveform", "Anti-deepfake vocale AI")
                featureBadge("person.badge.shield.checkmark.fill", "Identita' sovrana senza numero")
            }
            .padding(.horizontal, 32)

            Spacer()

            // Action buttons
            VStack(spacing: 12) {
                Button(action: { appState.authState = .login }) {
                    Text("Accedi con Telefono")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(QColors.qGreen)
                        .foregroundColor(QColors.textOnPrimary)
                        .cornerRadius(12)
                }

                Button(action: { appState.authState = .sovereignSetup }) {
                    Text("Crea Identita' Sovrana")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(QColors.cardSurface)
                        .foregroundColor(QColors.qGreen)
                        .cornerRadius(12)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(QColors.qGreen, lineWidth: 1))
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .background(QColors.deepSpace)
    }

    private func featureBadge(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(QColors.qGreen)
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
                .foregroundColor(QColors.textSecondary)
            Spacer()
        }
    }
}

// MARK: - Login View

public struct LoginView: View {
    @EnvironmentObject var appState: QAudionAppState
    @State private var phoneNumber = ""
    @State private var inviteCode = ""
    @State private var isRegistering = false
    @State private var isLoading = false

    public init() {}

    public var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "phone.fill")
                    .font(.system(size: 48))
                    .foregroundColor(QColors.qGreen)

                Text(isRegistering ? "Registrazione" : "Accedi")
                    .font(.title.bold())
                    .foregroundColor(QColors.textPrimary)

                VStack(spacing: 16) {
                    TextField("Numero di telefono", text: $phoneNumber)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.phonePad)

                    if isRegistering {
                        TextField("Codice invito", text: $inviteCode)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(.horizontal, 24)

                if let error = appState.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(QColors.error)
                        .padding(.horizontal, 24)
                }

                Button(action: {
                    isLoading = true
                    Task {
                        if isRegistering {
                            await appState.register(phoneNumber: phoneNumber, inviteCode: inviteCode.isEmpty ? nil : inviteCode)
                        } else {
                            await appState.login(phoneNumber: phoneNumber, password: inviteCode)
                        }
                        isLoading = false
                    }
                }) {
                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding()
                    } else {
                        Text(isRegistering ? "Registrati" : "Accedi")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                }
                .background(QColors.qGreen)
                .foregroundColor(QColors.textOnPrimary)
                .cornerRadius(12)
                .disabled(phoneNumber.isEmpty || isLoading)
                .padding(.horizontal, 24)

                Button(isRegistering ? "Hai gia' un account? Accedi" : "Non hai un account? Registrati") {
                    isRegistering.toggle()
                }
                .font(.subheadline)
                .foregroundColor(QColors.qBlue)

                Spacer()
            }
            .background(QColors.deepSpace)
            .navigationBarBackButtonHidden(false)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Indietro") { appState.authState = .welcome }
                }
            }
        }
    }
}

// MARK: - Sovereign Setup View

public struct SovereignSetupView: View {
    @EnvironmentObject var appState: QAudionAppState
    @State private var displayName = ""
    @State private var isLoading = false

    public init() {}

    public var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 48))
                    .foregroundColor(QColors.qGold)

                Text("Identita' Sovrana")
                    .font(.title.bold())
                    .foregroundColor(QColors.textPrimary)

                Text("Nessun numero di telefono richiesto.\nLa tua identita' e' protetta da chiavi crittografiche.")
                    .font(.subheadline)
                    .foregroundColor(QColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                VStack(spacing: 8) {
                    TextField("Nome visualizzato (opzionale)", text: $displayName)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal, 24)

                    Text("X25519 + Ed25519 + ML-KEM-1024")
                        .font(.caption)
                        .foregroundColor(QColors.qGreen)
                }

                if let error = appState.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(QColors.error)
                }

                Button(action: {
                    isLoading = true
                    Task {
                        await appState.registerSovereign(displayName: displayName.isEmpty ? nil : displayName)
                        isLoading = false
                    }
                }) {
                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding()
                    } else {
                        Text("Genera Identita'")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                }
                .background(QColors.qGold)
                .foregroundColor(QColors.textOnPrimary)
                .cornerRadius(12)
                .disabled(isLoading)
                .padding(.horizontal, 24)

                Spacer()
            }
            .background(QColors.deepSpace)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Indietro") { appState.authState = .welcome }
                }
            }
        }
    }
}
