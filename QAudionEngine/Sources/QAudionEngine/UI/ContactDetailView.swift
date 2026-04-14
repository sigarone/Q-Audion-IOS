import SwiftUI

/// Contact detail view matching Android's ContactDetailScreen.
/// Shows contact info, trust level, and action buttons.
public struct ContactDetailView: View {
    public let contact: DiscoveredContact
    public let trustLevel: TrustShieldView.TrustLevel
    public let onCall: () -> Void
    public let onVideoCall: () -> Void
    public let onMessage: () -> Void
    public let onVerify: () -> Void
    public let onBlock: () -> Void

    public init(contact: DiscoveredContact,
                trustLevel: TrustShieldView.TrustLevel = .unknown,
                onCall: @escaping () -> Void = {},
                onVideoCall: @escaping () -> Void = {},
                onMessage: @escaping () -> Void = {},
                onVerify: @escaping () -> Void = {},
                onBlock: @escaping () -> Void = {}) {
        self.contact = contact
        self.trustLevel = trustLevel
        self.onCall = onCall; self.onVideoCall = onVideoCall
        self.onMessage = onMessage; self.onVerify = onVerify; self.onBlock = onBlock
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Avatar
                Circle()
                    .fill(Color(.systemGray4))
                    .frame(width: 80, height: 80)
                    .overlay(
                        Text(String((contact.displayName ?? "?").prefix(1)).uppercased())
                            .font(.title)
                            .foregroundColor(.white)
                    )

                // Name + Trust Shield
                VStack(spacing: 8) {
                    Text(contact.displayName ?? contact.userId)
                        .font(.title2.bold())
                    TrustShieldView(trustLevel: trustLevel)
                    if let status = contact.statusMessage {
                        Text(status)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }

                // Action buttons
                HStack(spacing: 24) {
                    actionButton("phone.fill", "Call", action: onCall)
                    actionButton("video.fill", "Video", action: onVideoCall)
                    actionButton("message.fill", "Message", action: onMessage)
                    actionButton("checkmark.shield", "Verify", action: onVerify)
                }
                .padding()

                Divider()

                // Info section
                VStack(alignment: .leading, spacing: 12) {
                    infoRow("User ID", contact.userId)
                    infoRow("Phone Hash", String(contact.phoneHash.prefix(16)) + "...")
                }
                .padding()

                // Block button
                Button(role: .destructive, action: onBlock) {
                    Label("Block Contact", systemImage: "hand.raised.fill")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(12)
                }
                .padding(.horizontal)
            }
            .padding()
        }
        .navigationTitle("Contact")
    }

    private func actionButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(Circle())
                Text(label)
                    .font(.caption2)
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundColor(.primary)
        }
    }
}
