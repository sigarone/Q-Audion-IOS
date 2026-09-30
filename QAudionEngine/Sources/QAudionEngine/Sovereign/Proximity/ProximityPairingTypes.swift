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
    /// SHA-256 output: TH1, TH_S, TH_D (spec §10).
    public static let transcriptHashBytes: Int = 32
    /// AES-256-GCM key: K_enc_S / K_enc_D (spec §4, §10).
    public static let aeadKeyBytes: Int = 32
    /// AES-256-GCM nonce. Always all zero: every K_enc seals exactly one message (spec §4).
    public static let aeadNonceBytes: Int = 12
    /// AES-256-GCM tag, appended to the ciphertext (spec §4, §8).
    public static let aeadTagBytes: Int = 16
    /// OFFER body: `ek_D[1568] ‖ xpk_D[32] ‖ nonce_D[32]`, ephemeral keys only (spec §8).
    public static let offerBodyBytes: Int = 1632
    /// `idBlock` bytes before `userId`: `idPub[32] ‖ encPub[32] ‖ u16be(n)` (spec §8).
    public static let idBlockFixedBytes: Int = 66
    /// A sealed box without its userId: `idBlock` fixed part ‖ sig[64] ‖ mac[32] ‖ tag[16].
    /// A sealed box is exactly `sealedIdentityFixedBytes + n` bytes (spec §8: FINISH = 178 + n).
    public static let sealedIdentityFixedBytes: Int = 178

    /// Spec §8 userId grammar: 1...256 bytes, each one of `[A-Za-z0-9._-]`.
    /// Server account ids are UUIDs, so this costs nothing — and it removes
    /// every way to present "the same id" as different bytes (padding,
    /// NBSP, zero-width or bidi characters, the pin store's `|` separator),
    /// which would otherwise show a known contact's name on the SAS screen
    /// while every exact-match lookup (pins, contacts, self check) missed.
    public static func isValidUserId(_ userId: String) -> Bool {
        let bytes: [UInt8] = Array(userId.utf8)
        guard bytes.count >= 1, bytes.count <= maxUserIdBytes else { return false }
        for byte in bytes {
            let isUpper: Bool = byte >= 0x41 && byte <= 0x5A
            let isLower: Bool = byte >= 0x61 && byte <= 0x7A
            let isDigit: Bool = byte >= 0x30 && byte <= 0x39
            let isPunctuation: Bool = byte == 0x2E || byte == 0x5F || byte == 0x2D
            if !(isUpper || isLower || isDigit || isPunctuation) { return false }
        }
        return true
    }
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
        public static let transcriptScanner: Data = Data("qaudion-prox-v1/transcript-scanner".utf8)
        public static let transcriptDisplayer: Data = Data("qaudion-prox-v1/transcript-displayer".utf8)
        public static let encScanner: Data = Data("qaudion-prox-v1/enc-scanner".utf8)
        public static let encDisplayer: Data = Data("qaudion-prox-v1/enc-displayer".utf8)
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

/// A peer's long-term identity as carried, sealed, in ACCEPT / FINISH (the
/// `idBlock` of spec §8). Never on the air in clear.
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
        guard ProximityPairing.isValidUserId(userId) else {
            throw ProximityPairingError.protocolViolation("userId charset")
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

    /// The identity as the peer will see it once it opens our sealed box
    /// (ACCEPT for the scanner, FINISH for the displayer).
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

/// Whether the claimed account's server-published identity keys contained the
/// Ed25519 key the peer's phone proved during the pairing (spec §12) — the
/// three-way outcome behind `ProximityPairingSummary.serverIdentityConfirmed`.
/// Purely a UI/telemetry classification: it never feeds back into the
/// protocol or the trust the current logic already grants (`.confirmed` is
/// the ONLY case that counts as "verified" anywhere downstream).
public enum ProximityServerCheckOutcome: String, Equatable, Sendable {
    /// The presented key was one the account published.
    case confirmed = "ok"
    /// Offline, nothing published, the lookup timed out, or no lookup was
    /// configured by the host — the check simply could not run.
    case unavailable
    /// The account published keys and this is none of them (the SAS
    /// ceremony still completed — the user was shown the warning and chose
    /// to confirm anyway).
    case mismatch
}

/// What a completed pairing reports to the host app, AFTER its PSK is in the
/// vault: everything in `ProximityPairingResult` except the key. The PSK then
/// never travels through SwiftUI closures and view state, where no copy of it
/// could be scrubbed.
public struct ProximityPairingSummary: Equatable, Sendable {
    public let role: ProximityRole
    public let peer: ProximityPeerIdentity
    /// `lowercase_hex(SHA-256(psk))` — the fingerprint the vault entry carries.
    public let pskFingerprint: String
    public let sas: String
    public let identityWarning: String?
    /// The full three-way server-check result (see `ProximityServerCheckOutcome`).
    public let serverCheckOutcome: ProximityServerCheckOutcome
    /// Wall-clock milliseconds from the screen's `start()` to this
    /// completion — UI/telemetry only (the `ms` attribute of the
    /// `pairing.proximity.completed` event), never used by the protocol.
    public let elapsedMs: Int

    /// True only when the claimed account's server-published identity keys
    /// contained the Ed25519 key the peer's phone proved (spec §12). False
    /// when the keys differed, the check could not run, or it timed out:
    /// then the userId is only the peer's own claim. Derived from
    /// `serverCheckOutcome` — kept as a computed property so existing
    /// call sites (`verified: result.serverIdentityConfirmed`) are unchanged.
    public var serverIdentityConfirmed: Bool { serverCheckOutcome == .confirmed }

    public init(_ result: ProximityPairingResult,
                serverCheckOutcome: ProximityServerCheckOutcome = .unavailable,
                elapsedMs: Int = 0) {
        self.role = result.role
        self.peer = result.peer
        self.pskFingerprint = result.pskFingerprint
        self.sas = result.sas
        self.identityWarning = result.identityWarning
        self.serverCheckOutcome = serverCheckOutcome
        self.elapsedMs = elapsedMs
    }

    /// Back-compat convenience for existing callers/tests that only had a
    /// bool (pre-dates the three-way `ProximityServerCheckOutcome`).
    public init(_ result: ProximityPairingResult, serverIdentityConfirmed: Bool) {
        self.init(result, serverCheckOutcome: serverIdentityConfirmed ? .confirmed : .unavailable)
    }
}

/// A lifecycle event a pairing screen (displayer or scanner) reports to the
/// host for telemetry, so the maintainer can see on the server that a
/// pairing happened, or why it did not (spec/UX gap — no protocol change).
/// Deliberately carries NO ids, keys, SAS digits or names: only role/stage/
/// cause enums and counts, so it is safe to forward as-is into a structured
/// telemetry event's `attrs`.
public enum ProximityPairingTelemetryEvent: Equatable, Sendable {
    /// Where in the ceremony a `failed`/`cancelled` event happened.
    ///
    /// Review fix (W-PAIRFB cross-platform telemetry audit): explicit
    /// snake_case raw value on `showingCode` — Android's
    /// `ProximityPairingViewModel.telemetryStage` wire value for this stage
    /// is `"showing_code"`; Swift's default synthesized raw value for this
    /// case would have shipped the literal case name `"showingCode"`
    /// instead, splitting the `stage` attribute's vocabulary by platform.
    /// The other four cases already coincide with Android's strings under
    /// default synthesis (single lowercase words), so only this one needed
    /// an explicit override.
    public enum Stage: String, Equatable, Sendable {
        case preparing
        case showingCode = "showing_code"
        case connecting
        case exchanging
        case confirming
    }

    /// Closed cause taxonomy for `failed` — mirrors `ProximityPairingError`
    /// without leaking any of its associated string payloads (those can
    /// carry the peer's userId/claims).
    public enum FailureCause: String, Equatable, Sendable {
        // W-PAIRFB fuzz-check: `LogRedactor.redactStructured`'s fail-closed
        // residual sweep (`QAudionApp/Services/LogRedactor.swift`) redacts
        // ANY run of 20+ letters/digits/`+/=_-` with no separator — a plain
        // camelCase rawValue at or above that length would silently come
        // back as "***REDACTED***" over the wire, not a privacy problem
        // (nothing leaks) but a USELESS telemetry attribute (the whole
        // point of `cause` is to say WHY, on the server, without a phone in
        // hand). `bluetoothUnavailable`/`authenticationFailed` (auto
        // rawValue = the case name) are exactly 20 chars — the two explicit
        // overrides below keep every rawValue at 19 chars or under. Keep
        // this comment in sync with any new case: check `.rawValue.count`.
        case bluetoothUnavailable = "bleUnavailable"
        case identityUnavailable
        case invalidQrCode
        case expiredQrCode
        case timeout
        case transportFailed
        case protocolViolation
        case authenticationFailed = "authFailed"
        case identityRejected
        case sessionBusy
        case peerAborted
        case userRejected
        case cryptoFailure
        case screenCaptured
        case qrRenderFailed
        case other

        public init(_ error: ProximityPairingError) {
            switch error {
            case .bluetoothUnavailable: self = .bluetoothUnavailable
            case .identityUnavailable: self = .identityUnavailable
            case .invalidQrCode: self = .invalidQrCode
            case .expiredQrCode: self = .expiredQrCode
            case .timeout: self = .timeout
            case .transportFailed: self = .transportFailed
            case .protocolViolation: self = .protocolViolation
            case .authenticationFailed: self = .authenticationFailed
            case .identityRejected: self = .identityRejected
            case .sessionBusy: self = .sessionBusy
            case .peerAborted: self = .peerAborted
            case .userRejected: self = .userRejected
            case .cryptoFailure: self = .cryptoFailure
            case .cancelled: self = .other
            }
        }
    }

    case started(role: ProximityRole)
    case failed(cause: FailureCause, stage: Stage)
    case cancelled(stage: Stage)
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

    /// Monotonic and, unlike `systemUptime`, still counting while the device
    /// sleeps (Darwin's CLOCK_MONOTONIC), so a QR frame's 8 s window is 8 s
    /// of real time even across a screen lock.
    public func now() -> TimeInterval {
        let nanos: UInt64 = clock_gettime_nsec_np(CLOCK_MONOTONIC)
        return TimeInterval(nanos) / 1_000_000_000
    }

    @discardableResult
    public func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> ProximityCancellable {
        // UInt64(_:) traps on NaN/inf/overflow. Every in-tree delay is a
        // small constant, but clamp anyway so a bad value degrades to
        // "fire soon" / "fire in an hour" instead of crashing the app.
        let bounded: TimeInterval = delay.isFinite ? min(max(0, delay), 3600) : 0
        let nanos: UInt64 = UInt64(bounded * 1_000_000_000)
        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: nanos)
            if Task.isCancelled { return }
            action()
        }
        return TaskCancellable(task: task)
    }
}
