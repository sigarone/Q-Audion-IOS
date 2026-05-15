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
    /// - Parameter data: Raw payload bytes.
    /// - Returns: A tuple of `(name, key)` or `nil` when the data is malformed.
    public func parsePskPayload(_ data: Data) -> (name: String, key: Data)? {
        // 1 byte length + at least 1 byte name + 32 bytes key
        guard data.count >= 34 else { return nil }
        let nameLen = Int(data[0])
        guard data.count >= 1 + nameLen + 32 else { return nil }
        let name = String(data: data[1 ..< (1 + nameLen)], encoding: .utf8) ?? "unknown"
        let key = data[(1 + nameLen) ..< (1 + nameLen + 32)]
        return (name, Data(key))
    }

    /// Generate a QR-code payload for iOS-to-iOS PSK exchange.
    ///
    /// The format mirrors ``parsePskPayload(_:)`` so either side can decode.
    public func generateQrPayload(name: String, key: Data) -> Data {
        var payload = Data()
        let nameData = Data(name.utf8)
        payload.append(UInt8(nameData.count))
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
