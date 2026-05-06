import Foundation

public struct InCallViewModel: ViewModelProtocol {

    public enum SecurityState: Equatable, Sendable {
        case secure          // hybrid PQC handshake completed, frame keys flowing
        case verifying       // handshake in progress, audio NOT yet relayed
        case insecureFallback  // server-mediated relay, no E2E (warn user)
    }

    public struct Controls: Equatable, Sendable {
        public enum EndCallStyle: Equatable, Sendable { case red, neutral }

        public let isMuted: Bool
        public let isSpeakerOn: Bool
        public let isOnHold: Bool
        public let endCallStyle: EndCallStyle

        public init(isMuted: Bool, isSpeakerOn: Bool, isOnHold: Bool, endCallStyle: EndCallStyle) {
            self.isMuted = isMuted
            self.isSpeakerOn = isSpeakerOn
            self.isOnHold = isOnHold
            self.endCallStyle = endCallStyle
        }
    }

    public struct PeerInfo: Equatable, Sendable {
        public let userId: String
        public let displayName: String
        public let avatarUrl: URL?
        public let fingerprint: String  // §5.1 format

        public init(userId: String, displayName: String, avatarUrl: URL?, fingerprint: String) {
            self.userId = userId
            self.displayName = displayName
            self.avatarUrl = avatarUrl
            self.fingerprint = fingerprint
        }
    }

    public let peer: PeerInfo
    public let security: SecurityState
    public let callDuration: TimeInterval
    /// Normalized 0…1 amplitude for the green TX waveform (mic input).
    public let waveformTx: Double
    /// Normalized 0…1 amplitude for the orange RX waveform (peer audio).
    public let waveformRx: Double
    /// Normalized 0…1 amplitude for the cipher channel (post-AEAD ciphertext energy).
    public let waveformCipher: Double
    public let controls: Controls
    public let shouldShowSasPrompt: Bool
    public let showVideoPip: Bool

    public init(peer: PeerInfo, security: SecurityState, callDuration: TimeInterval,
                waveformTx: Double, waveformRx: Double, waveformCipher: Double,
                controls: Controls, shouldShowSasPrompt: Bool, showVideoPip: Bool) {
        self.peer = peer
        self.security = security
        self.callDuration = callDuration
        self.waveformTx = waveformTx
        self.waveformRx = waveformRx
        self.waveformCipher = waveformCipher
        self.controls = controls
        self.shouldShowSasPrompt = shouldShowSasPrompt
        self.showVideoPip = showVideoPip
    }

    public static let mock = InCallViewModel(
        peer: PeerInfo(
            userId: "user-aabbccdd-1122-3344-5566-778899aabbcc",
            displayName: "Alice (Pixel 7)",
            avatarUrl: nil,
            fingerprint: (try? Fingerprint.format(pubkey: Data(repeating: 0x43, count: 32))) ?? "????.????.????.????"
        ),
        security: .secure,
        callDuration: 47.3,
        waveformTx: 0.62,
        waveformRx: 0.41,
        waveformCipher: 0.88,
        controls: Controls(isMuted: false, isSpeakerOn: false, isOnHold: false, endCallStyle: .red),
        shouldShowSasPrompt: true,
        showVideoPip: false  // A.4 audio-only scope; video upgrade is Track B
    )
}
