import SwiftUI

/// TrustShield component matching Android's TrustShield.kt.
/// Shows the trust level of a contact with visual indicators.
public struct TrustShieldView: View {

    public enum TrustLevel: Int, Comparable {
        case unknown = 0
        case unverified = 1
        case tofu = 2        // Trust On First Use
        case verified = 3    // SAS verified
        case pskBound = 4    // PSK + SAS verified

        public static func < (lhs: TrustLevel, rhs: TrustLevel) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        public var label: String {
            switch self {
            case .unknown: return "Unknown"
            case .unverified: return "Unverified"
            case .tofu: return "First Contact"
            case .verified: return "Verified"
            case .pskBound: return "PSK Verified"
            }
        }

        public var color: Color {
            switch self {
            case .unknown: return .gray
            case .unverified: return .orange
            case .tofu: return .yellow
            case .verified: return .green
            case .pskBound: return .blue
            }
        }

        public var icon: String {
            switch self {
            case .unknown: return "questionmark.shield"
            case .unverified: return "exclamationmark.shield"
            case .tofu: return "shield"
            case .verified: return "checkmark.shield.fill"
            case .pskBound: return "lock.shield.fill"
            }
        }
    }

    public let trustLevel: TrustLevel
    public let compact: Bool

    public init(trustLevel: TrustLevel, compact: Bool = false) {
        self.trustLevel = trustLevel
        self.compact = compact
    }

    public var body: some View {
        if compact {
            Image(systemName: trustLevel.icon)
                .foregroundColor(trustLevel.color)
                .font(.caption)
        } else {
            HStack(spacing: 6) {
                Image(systemName: trustLevel.icon)
                    .foregroundColor(trustLevel.color)
                Text(trustLevel.label)
                    .font(.caption2)
                    .foregroundColor(trustLevel.color)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(trustLevel.color.opacity(0.15))
            .cornerRadius(8)
        }
    }
}
