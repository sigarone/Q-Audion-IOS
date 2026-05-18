import Foundation
#if canImport(CoreNFC)
import CoreNFC
#endif

/// Handles NFC-based PSK (Pre-Shared Key) exchange.
///
/// ## iOS vs Android NFC architecture
///
/// **iOS (this class):** reads passive NDEF tags via `NFCNDEFReaderSession`.
/// The Android app can write a static PSK record (MIME type
/// `application/x-qaudion-psk`, payload `[nameLen|name|32B key]`) to any
/// writable NFC tag; iOS scans and imports it.
///
/// **Android Phase 14c+ interactive handshake:** Android also implements an
/// APDU-based Host Card Emulation (HCE) protocol (AID `F0 BC F1 07 3A 51 00`)
/// with commands `GET_IDENTITY_KEY (0xC4)`, `PUSH_PEER_IDENTITY (0xC5)`,
/// `KEY_EXCHANGE (0x01)` that performs a live Ed25519-identity-bound X25519
/// key exchange with SAS verification. **iOS cannot participate in this flow**
/// because:
///   - iOS has no HCE API — it cannot emulate a smart card to a reader.
///   - `NFCTagReaderSession` can read ISO 7816 tags but only from passive
///     hardware tags, not from another smartphone acting as a host.
///
/// **Consequence:** when an Android peer uses the Phase 14c interactive NFC
/// pairing, iOS must fall back to QR code exchange. The Android app must
/// detect that the peer is iOS (or that the APDU SELECT fails) and offer
/// QR pairing automatically.
///
/// **Future fix options:**
///   1. Add BLE-based key exchange as a universal pairing channel.
///   2. Add server-mediated key delivery via the KMS (`/api/v1/kms/pending`).
///   3. Have Android write a plain NDEF PSK tag as a fallback for iOS scanners
///      (loses the Ed25519 identity binding but provides a PSK).
///
/// All NFC session code is wrapped in `#if canImport(CoreNFC)` so the class
/// compiles on macOS (used by CI / unit tests) where CoreNFC is unavailable.
/// The data-parsing helpers (``parsePskPayload(_:)`` and
/// ``generateQrPayload(name:key:)``) work on every platform.
public final class NfcProtocol: NSObject {

    // MARK: - Public types

    public enum NfcState: Equatable {
        case idle
        case reading
        case complete
        case error(String)

        public static func == (lhs: NfcState, rhs: NfcState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.reading, .reading), (.complete, .complete):
                return true
            case let (.error(a), .error(b)):
                return a == b
            default:
                return false
            }
        }
    }

    // MARK: - Public properties

    /// Called when a valid PSK payload has been read from an NFC tag.
    public var onPskReceived: ((String, Data) -> Void)?

    /// Called whenever ``state`` changes.
    public var onStateChanged: ((NfcState) -> Void)?

    // MARK: - Internal state

    private(set) var state: NfcState = .idle {
        didSet { onStateChanged?(state) }
    }

    /// The MIME type used for PSK NDEF records written by Q-Audion Android.
    static let pskMimeType = "application/x-qaudion-psk"

    #if canImport(CoreNFC)
    private var nfcSession: NFCNDEFReaderSession?
    #endif

    // MARK: - Init

    public override init() {
        super.init()
    }

    // MARK: - Session lifecycle

    /// Start an NFC NDEF reader session.
    ///
    /// On platforms where CoreNFC is not available (macOS) this is a no-op
    /// and ``state`` transitions directly to `.error`.
    public func startReading() {
        #if canImport(CoreNFC)
        guard NFCNDEFReaderSession.readingAvailable else {
            state = .error("NFC reading is not available on this device")
            return
        }

        // Invalidate any previous session before starting a new one.
        nfcSession?.invalidate()

        nfcSession = NFCNDEFReaderSession(
            delegate: self,
            queue: nil,
            invalidateAfterFirstRead: true
        )
        nfcSession?.alertMessage = "Hold your device near the Q-Audion NFC tag."
        nfcSession?.begin()
        state = .reading
        #else
        state = .error("NFC is not available on this platform")
        #endif
    }

    /// Programmatically stop a running NFC session (if any).
    public func stopReading() {
        #if canImport(CoreNFC)
        nfcSession?.invalidate()
        nfcSession = nil
        #endif
        if state == .reading {
            state = .idle
        }
    }

    // MARK: - Payload helpers (platform-independent)

    /// Parse PSK data from an NDEF record payload.
    ///
    /// Expected binary format: `[nameLen: UInt8][name: UTF-8 bytes][key: 32 bytes]`
    ///
    /// ## ⚠️ SECURITY H-7 — UNAUTHENTICATED TOFU. READ BEFORE TRUSTING.
    ///
    /// A static NDEF tag carries NO peer-identity binding and NO
    /// signature. ANY tag the phone is tapped against can inject an
    /// ARBITRARY 32-byte "PSK" — a rogue/cloned tag silently
    /// substitutes an attacker-known key (full MITM of the resulting
    /// session). The imported PSK is therefore Trust-On-First-Use
    /// ONLY and **MUST NOT be trusted until the two users have
    /// completed out-of-band SAS (Short Authentication String)
    /// verification** of the derived session before any sensitive
    /// traffic. The integration layer is responsible for forcing the
    /// SAS step after `onPskReceived`.
    ///
    /// TODO (SECURITY H-7, protocol-coordinated v2): replace the bare
    /// `[len|name|key]` record with an Ed25519-signed payload v2
    /// `[len|name|key|32B issuerPub|64B sig]` where `sig =
    /// Ed25519(issuerPriv, name‖key)` and the verifier pins
    /// `issuerPub` against the SovereignKeyVault identity. Requires a
    /// matching Android writer change — do not ship unilaterally.
    ///
    /// Input hardening (SECURITY M-5): `nameLen` is bounded to 64,
    /// non-UTF-8 names are REJECTED (not silently replaced), and
    /// bidi / zero-width / BOM scalars are stripped before the name
    /// reaches trust UI (homograph / RTL-spoof defense).
    ///
    /// - Parameter data: Raw payload bytes.
    /// - Returns: A tuple of `(name, key)` or `nil` when the data is
    ///   malformed, the name is too long, or the name is not valid UTF-8.
    public func parsePskPayload(_ data: Data) -> (name: String, key: Data)? {
        // 1 byte length + at least 1 byte name + 32 bytes key
        guard data.count >= 34 else { return nil }
        // Data slices from CoreNFC may not be zero-based; normalize.
        let bytes = Data(data)
        let nameLen = Int(bytes[bytes.startIndex])
        // SECURITY M-5 — hard upper bound; an attacker-set length
        // could otherwise drive a huge allocation / oversized name.
        guard nameLen >= 1, nameLen <= 64 else { return nil }
        guard bytes.count >= 1 + nameLen + 32 else { return nil }
        let nameStart = bytes.startIndex + 1
        let nameEnd = nameStart + nameLen
        let nameData = bytes.subdata(in: nameStart..<nameEnd)
        // SECURITY M-5 — REJECT non-UTF-8 instead of substituting
        // "unknown": a silently-mangled name in the trust UI lets an
        // attacker hide which key the user is actually accepting.
        guard let rawName = String(data: nameData, encoding: .utf8) else { return nil }
        let name = NfcProtocol.sanitizeDisplayName(rawName)
        let keyStart = nameEnd
        let key = bytes.subdata(in: keyStart..<(keyStart + 32))
        return (name, Data(key))
    }

    /// SECURITY M-5 — strip Unicode bidi-override, zero-width and BOM
    /// scalars so a tag-supplied display name cannot RTL-spoof or
    /// hide characters in the pairing-trust UI.
    static func sanitizeDisplayName(_ s: String) -> String {
        let blocked: Set<Unicode.Scalar> = {
            var out: Set<Unicode.Scalar> = []
            // Bidi embedding/override 0x202A–0x202E
            for v in 0x202A...0x202E { if let u = Unicode.Scalar(v) { out.insert(u) } }
            // Bidi isolates 0x2066–0x2069
            for v in 0x2066...0x2069 { if let u = Unicode.Scalar(v) { out.insert(u) } }
            // Zero-width / formatting 0x200B–0x200F
            for v in 0x200B...0x200F { if let u = Unicode.Scalar(v) { out.insert(u) } }
            // BOM / ZWNBSP
            if let u = Unicode.Scalar(0xFEFF) { out.insert(u) }
            return out
        }()
        var scalars = String.UnicodeScalarView()
        for sc in s.unicodeScalars where !blocked.contains(sc) {
            scalars.append(sc)
        }
        return String(scalars)
    }

    /// Generate a QR-code payload for iOS-to-iOS PSK exchange.
    ///
    /// The format mirrors ``parsePskPayload(_:)`` so either side can decode.
    ///
    /// SECURITY L-3 — the name is clamped to the first 64 UTF-8 bytes
    /// BEFORE the length byte is written, so `UInt8(nameData.count)`
    /// can never wrap (a >255-byte name previously truncated via
    /// `UInt8` overflow, producing a corrupt length prefix and a
    /// payload the peer mis-parses). 64 matches the M-5 parse bound.
    public func generateQrPayload(name: String, key: Data) -> Data {
        var payload = Data()
        var nameData = Data(name.prefix(64).utf8)
        // Defensive: grapheme-heavy input could exceed 64 bytes even
        // after `prefix(64)`. Clamp the byte count so the UInt8
        // length prefix can never overflow / wrap.
        if nameData.count > 64 {
            nameData = nameData.prefix(64)
        }
        let nameLen: Int = nameData.count        // now always 0...64
        payload.append(UInt8(nameLen))
        payload.append(nameData)
        payload.append(key)
        return payload
    }

    /// Current NFC state accessor.
    public func getState() -> NfcState { state }
}

// MARK: - NFCNDEFReaderSessionDelegate

#if canImport(CoreNFC)
extension NfcProtocol: NFCNDEFReaderSessionDelegate {

    public func readerSessionDidBecomeActive(_ session: NFCNDEFReaderSession) {
        // Session is active; the system NFC sheet is visible.
    }

    public func readerSession(
        _ session: NFCNDEFReaderSession,
        didDetectNDEFs messages: [NFCNDEFMessage]
    ) {
        for message in messages {
            for record in message.records {
                guard
                    record.typeNameFormat == .media,
                    let mimeType = String(data: record.type, encoding: .utf8),
                    mimeType == Self.pskMimeType
                else {
                    continue
                }

                if let parsed = parsePskPayload(record.payload) {
                    DispatchQueue.main.async { [weak self] in
                        self?.state = .complete
                        self?.onPskReceived?(parsed.name, parsed.key)
                    }
                    session.alertMessage = "Key received!"
                    session.invalidate()
                    return
                }
            }
        }

        // No matching record found in any message.
        DispatchQueue.main.async { [weak self] in
            self?.state = .error("No Q-Audion PSK record found on this tag")
        }
        session.invalidate(errorMessage: "No compatible record found.")
    }

    public func readerSession(
        _ session: NFCNDEFReaderSession,
        didInvalidateWithError error: Error
    ) {
        nfcSession = nil

        let nfcError = error as? NFCReaderError

        // User-cancelled is not a real error.
        if nfcError?.code == .readerSessionInvalidationErrorUserCanceled {
            DispatchQueue.main.async { [weak self] in
                self?.state = .idle
            }
            return
        }

        // System timeout is informational when invalidateAfterFirstRead is true.
        if nfcError?.code == .readerSessionInvalidationErrorFirstNDEFTagRead {
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.state = .error(error.localizedDescription)
        }
    }
}
#endif
