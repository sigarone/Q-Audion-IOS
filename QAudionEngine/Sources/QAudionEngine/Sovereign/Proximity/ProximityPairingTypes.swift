import Foundation
import CryptoKit

/// Proximity pairing v1: QR code + Bluetooth LE, hybrid ML-KEM-1024 + X25519.
///
/// The normative protocol is `docs/security/PROXIMITY_PAIRING_QR_BLE_SPEC.md`;
/// this file holds its constants and the types every other file in this
/// folder is built against. Change a value here only together with the spec,
/// the KAT generator (`scripts/kat/gen_proximity_pairing_kat.py`) and the
/// Android port.
public enum ProximityPairing {

    public static let protocolVersion: UInt8 = 0x01
    public static let urlScheme: String = "qaudion"
    public static let urlHost: String = "pair"
    public static let urlPrefix: String = "qaudion://pair/"

    // MARK: Sizes (bytes)

    public static let sessionIdBytes: Int = 16
    public static let sessionSecretBytes: Int = 32
    public static let commitmentBytes: Int = 32
    public static let frameKeyBytes: Int = 32
    public static let qrPayloadBytes: Int = 85
    public static let qrBase64Characters: Int = 114
    public static let nonceBytes: Int = 32
    public static let x25519PublicKeyBytes: Int = 32
    public static let ed25519PublicKeyBytes: Int = 32
    public static let ed25519PrivateKeyBytes: Int = 32
    public static let ed25519SignatureBytes: Int = 64
    public static let macBytes: Int = 32
    public static let mlKemPublicKeyBytes: Int = 1568
    public static let mlKemSecretKeyBytes: Int = 3168
    public static let mlKemCiphertextBytes: Int = 1568
    public static let sharedSecretBytes: Int = 32
    public static let pskBytes: Int = 32
    public static let sasBytes: Int = 8
    public static let sasDigits: Int = 6
    public static let maxUserIdBytes: Int = 256
    public static let maxMessageBytes: Int = 4096
    public static let helloBodyBytes: Int = 100

    // MARK: Timing (seconds)

    public static let frameRotationInterval: TimeInterval = 2.0
    public static let frameAcceptanceWindow: TimeInterval = 8.0
    public static let sessionLifetime: TimeInterval = 120.0
    public static let handshakeTimeout: TimeInterval = 20.0
    public static let userConfirmationTimeout: TimeInterval = 120.0
    public static let scannerConnectTimeout: TimeInterval = 15.0
    public static let completionLinkGrace: TimeInterval = 1.0

    // MARK: Bluetooth LE

    /// Scanner → displayer, write with response.
    public static let toDisplayerCharacteristicUUID: String = "51A0C2D0-7E2B-4F6B-9E1D-0A8B5C3F2D01"
    /// Displayer → scanner, notify.
    public static let toScannerCharacteristicUUID: String = "51A0D2C0-7E2B-4F6B-9E1D-0A8B5C3F2D02"

    // MARK: Domain-separation labels (ASCII, no NUL)

    public enum Label {
        public static let commit: Data = Data("qaudion-prox-v1/commit".utf8)
        public static let frame: Data = Data("qaudion-prox-v1/frame".utf8)
        public static let hello: Data = Data("qaudion-prox-v1/hello".utf8)
        public static let transcript: Data = Data("qaudion-prox-v1/transcript".utf8)
        public static let macScanner: Data = Data("qaudion-prox-v1/mac-scanner".utf8)
        public static let macDisplayer: Data = Data("qaudion-prox-v1/mac-displayer".utf8)
        public static let confirmScanner: Data = Data("qaudion-prox-v1/confirm-scanner".utf8)
        public static let confirmDisplayer: Data = Data("qaudion-prox-v1/confirm-displayer".utf8)
        public static let sas: Data = Data("qaudion-prox-v1/sas".utf8)
        public static let psk: Data = Data("qaudion-prox-v1/psk".utf8)
        public static let sigScanner: Data = Data("qaudion-prox-v1/sig-scanner".utf8)
        public static let sigDisplayer: Data = Data("qaudion-prox-v1/sig-displayer".utf8)
        public static let userConfirmed: Data = Data("qaudion-prox-v1/user-confirmed".utf8)
    }

    /// First byte of every reassembled protocol message (spec §8).
    public enum MessageType: UInt8 {
        case hello = 0x01
        case offer = 0x02
        case accept = 0x03
        case finish = 0x04
        case confirm = 0x05
        case abort = 0x06
        case busy = 0x07
    }

    /// ABORT reason byte (spec §8). ABORT is unauthenticated: it may only end a pairing.
    public enum AbortReason: UInt8 {
        case userRejected = 1
        case authenticationFailed = 2
        case protocolViolation = 3
        case timeout = 4
        case identityRejected = 5
        case cancelled = 6
        case internalError = 7
        case frameExpired = 8
    }
}

public enum ProximityRole: String, Equatable, Sendable {
    case displayer
    case scanner
}

/// The 85-byte QR payload (spec §5). Construction validates every length, so a
/// value of this type is always well-formed. Codec: `ProximityQrPayload+Codec.swift`.
public struct ProximityQrPayload: Equatable, Sendable {
    public let version: UInt8
    public let sessionId: Data
    public let commitment: Data
    public let frameIndex: UInt32
    public let frameKey: Data

    public init(sessionId: Data, commitment: Data, frameIndex: UInt32, frameKey: Data) throws {
        guard sessionId.count == ProximityPairing.sessionIdBytes else {
            throw ProximityPairingError.invalidQrCode("sessionId length")
        }
        guard commitment.count == ProximityPairing.commitmentBytes else {
            throw ProximityPairingError.invalidQrCode("commitment length")
        }
        guard frameKey.count == ProximityPairing.frameKeyBytes else {
            throw ProximityPairingError.invalidQrCode("frameKey length")
        }
        self.version = ProximityPairing.protocolVersion
        self.sessionId = Data(sessionId)
        self.commitment = Data(commitment)
        self.frameIndex = frameIndex
        self.frameKey = Data(frameKey)
    }
}

/// A peer's long-term identity as carried in OFFER / ACCEPT.
public struct ProximityPeerIdentity: Equatable, Sendable {
    /// Server account id.
    public let userId: String
    /// Ed25519 identity public key — the key call handshakes are signed with.
    public let signingPublicKey: Data
    /// X25519 identity public key — the contact key shown in the identity QR.
    public let encryptionPublicKey: Data

    public init(userId: String, signingPublicKey: Data, encryptionPublicKey: Data) throws {
        let userIdBytes = Data(userId.utf8).count
        guard userIdBytes >= 1, userIdBytes <= ProximityPairing.maxUserIdBytes else {
            throw ProximityPairingError.protocolViolation("userId length")
        }
        guard signingPublicKey.count == ProximityPairing.ed25519PublicKeyBytes else {
            throw ProximityPairingError.protocolViolation("signing key length")
        }
        guard encryptionPublicKey.count == ProximityPairing.x25519PublicKeyBytes else {
            throw ProximityPairingError.protocolViolation("encryption key length")
        }
        self.userId = userId
        self.signingPublicKey = Data(signingPublicKey)
        self.encryptionPublicKey = Data(encryptionPublicKey)
    }
}

/// This device's identity for a pairing. Holds the Ed25519 private key only for
/// the duration of the session that uses it.
public struct ProximityLocalIdentity {
    public let userId: String
    public let signingPrivateKey: Data
    public let signingPublicKey: Data
    public let encryptionPublicKey: Data

    /// Derives the Ed25519 public key from `signingPrivateKey` (raw 32-byte
    /// seed) rather than trusting a caller-supplied one, so the two can never
    /// disagree.
    public init(userId: String, signingPrivateKey: Data, encryptionPublicKey: Data) throws {
        guard signingPrivateKey.count == ProximityPairing.ed25519PrivateKeyBytes else {
            throw ProximityPairingError.identityUnavailable
        }
        let key: Curve25519.Signing.PrivateKey
        do {
            key = try Curve25519.Signing.PrivateKey(rawRepresentation: signingPrivateKey)
        } catch {
            throw ProximityPairingError.identityUnavailable
        }
        let publicIdentity = try ProximityPeerIdentity(
            userId: userId,
            signingPublicKey: key.publicKey.rawRepresentation,
            encryptionPublicKey: encryptionPublicKey
        )
        self.userId = publicIdentity.userId
        self.signingPrivateKey = Data(signingPrivateKey)
        self.signingPublicKey = publicIdentity.signingPublicKey
        self.encryptionPublicKey = publicIdentity.encryptionPublicKey
    }

    /// The identity as the peer will see it in OFFER / ACCEPT.
    public var publicIdentity: ProximityPeerIdentity {
        // Force-try is safe: every field was validated by the initializer above.
        // swiftlint:disable:next force_try
        return try! ProximityPeerIdentity(userId: userId,
                                          signingPublicKey: signingPublicKey,
                                          encryptionPublicKey: encryptionPublicKey)
    }
}

/// Outcome of the identity policy run before the SAS is shown (spec §12).
public enum ProximityIdentityDecision: Equatable {
    case accept
    /// Proceed, but show `message` prominently on the confirmation screen.
    case acceptWithWarning(String)
    case reject(String)
}

/// Delivered only after BOTH users confirmed the SAS and the peer's CONFIRM MAC verified.
public struct ProximityPairingResult: Equatable {
    public let role: ProximityRole
    public let peer: ProximityPeerIdentity
    /// 32-byte pre-shared key. Store it, then drop every other copy.
    public let psk: Data
    /// `lowercase_hex(SHA-256(psk))` — the canonical fingerprint (WIRE_SPEC §3.3).
    public let pskFingerprint: String
    public let sas: String
    /// Non-nil when the identity policy accepted with a warning.
    public let identityWarning: String?

    public init(role: ProximityRole, peer: ProximityPeerIdentity, psk: Data,
                pskFingerprint: String, sas: String, identityWarning: String?) {
        self.role = role
        self.peer = peer
        self.psk = Data(psk)
        self.pskFingerprint = pskFingerprint
        self.sas = sas
        self.identityWarning = identityWarning
    }
}

public enum ProximityPairingError: Error, Equatable {
    case bluetoothUnavailable(String)
    case identityUnavailable
    case invalidQrCode(String)
    case expiredQrCode
    case timeout(String)
    case transportFailed(String)
    case protocolViolation(String)
    case authenticationFailed(String)
    case identityRejected(String)
    case sessionBusy
    case peerAborted(UInt8)
    case userRejected
    case cancelled
    case cryptoFailure(String)

    /// The ABORT reason to send to the peer when this error ends a pairing locally.
    public var abortReason: ProximityPairing.AbortReason {
        switch self {
        case .userRejected: return .userRejected
        case .authenticationFailed: return .authenticationFailed
        case .protocolViolation, .invalidQrCode: return .protocolViolation
        case .timeout: return .timeout
        case .identityRejected: return .identityRejected
        case .cancelled: return .cancelled
        case .expiredQrCode: return .frameExpired
        case .bluetoothUnavailable, .identityUnavailable, .transportFailed,
             .sessionBusy, .peerAborted, .cryptoFailure:
            return .internalError
        }
    }

    /// Whether a fresh attempt could succeed without the user changing anything.
    public var isRetryable: Bool {
        switch self {
        case .bluetoothUnavailable, .identityUnavailable, .identityRejected, .userRejected, .cancelled:
            return false
        default:
            return true
        }
    }

    /// Italian, user-facing.
    public var userMessage: String {
        switch self {
        case .bluetoothUnavailable:
            return "Bluetooth non disponibile: attivalo e consenti a Q-Audion di usarlo per associare un contatto di persona."
        case .identityUnavailable:
            return "Identità non ancora inizializzata: completa la configurazione prima di associare un contatto."
        case .invalidQrCode:
            return "Questo non è un codice di associazione Q-Audion valido."
        case .expiredQrCode:
            return "Il codice è scaduto: inquadra di nuovo il codice mostrato sull'altro telefono."
        case .timeout:
            return "L'altro telefono non ha risposto in tempo. Avvicinate i telefoni e riprovate."
        case .transportFailed:
            return "Connessione Bluetooth interrotta. Riprova tenendo i telefoni vicini."
        case .protocolViolation, .authenticationFailed:
            return "Verifica di sicurezza non superata: associazione annullata, nessuna chiave salvata."
        case .identityRejected(let reason):
            return reason
        case .sessionBusy:
            return "Questo codice è già in uso da un altro telefono. Chiedi di mostrarne uno nuovo."
        case .peerAborted(let raw):
            switch ProximityPairing.AbortReason(rawValue: raw) {
            case .userRejected?:
                return "L'altra persona ha annullato l'associazione."
            case .frameExpired?:
                return "Il codice è scaduto: inquadra di nuovo il codice mostrato sull'altro telefono."
            case .authenticationFailed?, .protocolViolation?:
                return "L'altro telefono ha rifiutato la verifica di sicurezza: nessuna chiave salvata."
            default:
                return "L'altro telefono ha annullato l'associazione."
            }
        case .userRejected, .cancelled:
            return "Associazione annullata."
        case .cryptoFailure:
            return "Errore crittografico: associazione annullata, nessuna chiave salvata."
        }
    }
}

// MARK: - Transport contracts (implemented by ProximityBleTransport.swift and by test doubles)
//
// Deliberately NOT `@MainActor`: a class that lists a global-actor protocol in
// its primary declaration is inferred to be isolated to that actor, which would
// drag the CoreBluetooth delegate witnesses across isolation — the exact break
// `IOSEarbudGattProxy`'s trailing comment records for this package's simulator
// build. Contract instead: every member is called on the main thread, and
// CoreBluetooth managers are created with `queue: nil` so their callbacks are
// on the main thread too. The state machines that drive these are `@MainActor`.

/// One established, bidirectional message channel to a single peer. The
/// transport does the fragmentation (`ProximityFraming`); these calls deal in
/// whole protocol messages (`type ‖ body`). Callbacks are delivered on the main
/// thread, never re-entrantly from inside `send`.
public protocol ProximityPairingLink: AnyObject {
    func send(_ message: Data)
    /// Idempotent. Does not fire `onClosed`.
    func close()
    var onMessage: ((Data) -> Void)? { get set }
    /// Fires once when the peer disconnects or the transport fails.
    var onClosed: ((ProximityPairingError?) -> Void)? { get set }
}

public protocol ProximityDisplayerTransport: AnyObject {
    /// Publish the GATT service whose UUID is the 16 `serviceId` bytes and advertise it.
    /// Replaces any previous service/advertisement.
    func startAdvertising(serviceId: Data)
    func stopAdvertising()
    /// Stop advertising, drop every link, release the radio. Idempotent.
    func shutdown()
    /// A central connected and subscribed; hands over a link bound to it.
    var onIncomingLink: ((ProximityPairingLink) -> Void)? { get set }
    /// Bluetooth off / unauthorized / unsupported, or the service could not be published.
    var onUnavailable: ((ProximityPairingError) -> Void)? { get set }
}

public protocol ProximityScannerTransport: AnyObject {
    /// Scan for the service UUID `serviceId`, connect to the first match, discover
    /// both characteristics and subscribe. `completion` fires exactly once.
    func connect(serviceId: Data, timeout: TimeInterval,
                 completion: @escaping (Result<ProximityPairingLink, ProximityPairingError>) -> Void)
    /// Stop scanning / connecting and drop any link. Idempotent.
    func cancel()
}

// MARK: - Scheduling (injectable so the state machines are testable without real time)

public protocol ProximityCancellable: AnyObject {
    func cancel()
}

@MainActor
public protocol ProximityScheduler: AnyObject {
    /// Monotonic seconds.
    func now() -> TimeInterval
    @discardableResult
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> ProximityCancellable
}

/// Production scheduler: monotonic uptime clock, main-actor tasks.
@MainActor
public final class ProximityMainScheduler: ProximityScheduler {

    private final class TaskCancellable: ProximityCancellable {
        let task: Task<Void, Never>
        init(task: Task<Void, Never>) { self.task = task }
        func cancel() { task.cancel() }
    }

    public init() {}

    public func now() -> TimeInterval {
        return ProcessInfo.processInfo.systemUptime
    }

    @discardableResult
    public func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> ProximityCancellable {
        let nanos: UInt64 = UInt64(max(0, delay) * 1_000_000_000)
        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: nanos)
            if Task.isCancelled { return }
            action()
        }
        return TaskCancellable(task: task)
    }
}
