import Foundation

public final class NfcProtocol {
    public enum NfcState { case idle; case reading; case complete; case error(String) }

    private var state: NfcState = .idle
    public var onPskReceived: ((String, Data) -> Void)?

    public init() {}

    /// Start NFC reading session. iOS can only READ NFC tags (no HCE).
    /// For PSK exchange: Android writes tag, iOS reads.
    #if canImport(CoreNFC)
    public func startReading() {
        state = .reading
        // Real implementation uses NFCNDEFReaderSession
        // Stub: immediately set to idle
        state = .idle
    }
    #endif

    /// Parse PSK data from NDEF record payload.
    public func parsePskPayload(_ data: Data) -> (name: String, key: Data)? {
        // Expected format: [nameLen(1)][name(N)][key(32)]
        guard data.count >= 34 else { return nil }  // 1 + 1 + 32 minimum
        let nameLen = Int(data[0])
        guard data.count >= 1 + nameLen + 32 else { return nil }
        let name = String(data: data[1..<(1 + nameLen)], encoding: .utf8) ?? "unknown"
        let key = data[(1 + nameLen)..<(1 + nameLen + 32)]
        return (name, Data(key))
    }

    /// Generate QR code content for PSK exchange (iOS-to-iOS fallback).
    public func generateQrPayload(name: String, key: Data) -> Data {
        var payload = Data()
        let nameData = Data(name.utf8)
        payload.append(UInt8(nameData.count))
        payload.append(nameData)
        payload.append(key)
        return payload
    }

    public func getState() -> NfcState { state }
}
