import Foundation

/// Encodes / decodes the device-linking binary QR per spec §5.6.
///
/// Layout: `[32B X25519 pubkey ‖ 4B big-endian length ‖ userId UTF-8 ‖ 16B auth code]`.
/// Encoded as base64url without padding, wrapped in `qaudion://link/<blob>`.
///
/// Cross-platform parity:
/// - iOS:     this file
/// - Android: `DeviceLinkingProtocol.kt:42,86–104`
/// - Desktop: not implemented (no multi-device linking on desktop client yet)
public enum DeviceLinkBinaryQR {

    public static let pubkeyLength = 32
    public static let authCodeLength = 16
    public static let lengthFieldBytes = 4
    public static let urlScheme = "qaudion"
    public static let urlHost = "link"

    public struct Decoded: Equatable {
        public let pubkey: Data       // 32 bytes X25519 public key
        public let userId: String     // variable-length UTF-8
        public let authCode: Data     // 16 bytes server-issued nonce

        public init(pubkey: Data, userId: String, authCode: Data) {
            self.pubkey = pubkey
            self.userId = userId
            self.authCode = authCode
        }
    }

    public enum Error: Swift.Error, LocalizedError {
        case wrongPubkeyLength(Int)
        case wrongAuthCodeLength(Int)
        case invalidUrl
        case base64Failed
        case tooShort
        case lengthMismatch
        case invalidUserIdEncoding

        public var errorDescription: String? {
            switch self {
            case .wrongPubkeyLength(let n): return "Pubkey must be 32B, got \(n)"
            case .wrongAuthCodeLength(let n): return "Auth code must be 16B, got \(n)"
            case .invalidUrl: return "URL must be qaudion://link/<base64url>"
            case .base64Failed: return "base64url decode failed"
            case .tooShort: return "Blob shorter than minimum (32+4+16=52B)"
            case .lengthMismatch: return "Encoded userId length doesn't match remaining blob"
            case .invalidUserIdEncoding: return "userId not valid UTF-8"
            }
        }
    }

    /// Encode → URL.
    public static func encode(pubkey: Data, userId: String, authCode: Data) throws -> URL {
        let blob = try encodeBlob(pubkey: pubkey, userId: userId, authCode: authCode)
        let b64 = blob.base64UrlEncodedNoPadding()
        guard let url = URL(string: "\(urlScheme)://\(urlHost)/\(b64)") else {
            throw Error.invalidUrl
        }
        return url
    }

    /// Encode → raw blob (without URL wrapping).
    public static func encodeBlob(pubkey: Data, userId: String, authCode: Data) throws -> Data {
        guard pubkey.count == pubkeyLength else { throw Error.wrongPubkeyLength(pubkey.count) }
        guard authCode.count == authCodeLength else { throw Error.wrongAuthCodeLength(authCode.count) }

        let userIdData = Data(userId.utf8)
        let length = UInt32(userIdData.count)
        let lengthBytes = Data([
            UInt8((length >> 24) & 0xFF),
            UInt8((length >> 16) & 0xFF),
            UInt8((length >>  8) & 0xFF),
            UInt8( length        & 0xFF),
        ])

        var blob = Data()
        blob.reserveCapacity(pubkeyLength + lengthFieldBytes + userIdData.count + authCodeLength)
        blob.append(pubkey)
        blob.append(lengthBytes)
        blob.append(userIdData)
        blob.append(authCode)
        return blob
    }

    /// Decode URL → Decoded triple.
    public static func decode(url: URL) throws -> Decoded {
        guard url.scheme == urlScheme, url.host == urlHost else { throw Error.invalidUrl }

        // The base64url blob is the path component minus the leading "/".
        let path = url.path
        let blobString = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard !blobString.isEmpty else { throw Error.invalidUrl }

        guard let blob = Data(base64UrlEncodedNoPadding: blobString) else {
            throw Error.base64Failed
        }
        return try decodeBlob(blob)
    }

    /// Decode raw blob → Decoded triple.
    public static func decodeBlob(_ rawBlob: Data) throws -> Decoded {
        // ROBUSTNESS: `Data` slices from upstream (`prefix`, `dropFirst`,
        // CoreNFC) may carry a non-zero `startIndex`. Every offset below
        // (`subdata(in:)`, `prefix`, integer index math) assumes a
        // zero-based buffer; an absolute-index slice would read OOB or
        // decode garbage. Normalize to a fresh zero-based copy first —
        // same defensive pattern as `NfcProtocol.parsePskPayload`.
        let blob = Data(rawBlob)
        let minSize = pubkeyLength + lengthFieldBytes + authCodeLength
        guard blob.count >= minSize else { throw Error.tooShort }

        let pubkey = blob.prefix(pubkeyLength)
        let lengthBytes = blob.subdata(in: pubkeyLength..<(pubkeyLength + lengthFieldBytes))
        let length = (UInt32(lengthBytes[0]) << 24) |
                     (UInt32(lengthBytes[1]) << 16) |
                     (UInt32(lengthBytes[2]) << 8)  |
                      UInt32(lengthBytes[3])

        // SECURITY M-27: a malicious QR can declare a userId length up
        // to 4 GiB (UInt32 max). Without an upper bound the subdata /
        // String allocation below is an attacker-controlled OOM. A
        // userId is a short identifier; 1 KiB is far above any legitimate
        // value. Reject before any allocation.
        guard length <= 1024 else { throw Error.lengthMismatch }

        let userIdStart = pubkeyLength + lengthFieldBytes
        let userIdEnd = userIdStart + Int(length)
        let authStart = userIdEnd

        guard userIdEnd <= blob.count - authCodeLength,
              authStart + authCodeLength == blob.count else {
            throw Error.lengthMismatch
        }

        let userIdData = blob.subdata(in: userIdStart..<userIdEnd)
        guard let userId = String(data: userIdData, encoding: .utf8) else {
            throw Error.invalidUserIdEncoding
        }

        let authCode = blob.subdata(in: authStart..<(authStart + authCodeLength))

        return Decoded(pubkey: Data(pubkey), userId: userId, authCode: authCode)
    }
}

// MARK: - base64url helpers

extension Data {
    /// base64url encoding without padding (RFC 4648 §5).
    /// Replaces `+ → -`, `/ → _`, strips `=`.
    public func base64UrlEncodedNoPadding() -> String {
        return self.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// base64url decoding, accepts both padded and unpadded input.
    public init?(base64UrlEncodedNoPadding s: String) {
        var b64 = s
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Restore `=` padding.
        while b64.count % 4 != 0 { b64.append("=") }
        guard let data = Data(base64Encoded: b64) else { return nil }
        self = data
    }
}
