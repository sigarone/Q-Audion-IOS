import Foundation
import QAudionEngine

/// Routes a scanned QR-code string to one of the three §5/§6 payload codecs.
///
/// Q-Audion has three distinct QR shapes that the in-app scanner has to
/// distinguish purely from text content:
///
/// - **Identity** (`QAUDION:1:<userId>:<pubkey-b64>:<checksum-b64>`) — printable
///   "show my identity" / "scan contact" surface (`IdentityQrCode`).
/// - **Device link** (`qaudion://link/<base64url>`) — binary §5.6 device-linking
///   QR (`DeviceLinkBinaryQR`).
/// - **Fast setup** (`qaudion://setup/<base64url>`) — server-issued onboarding
///   bypass (`FastSetupQrCode`).
///
/// The router cheaply discriminates by prefix before paying the (slightly)
/// more expensive base64 + JSON / binary parses inside the codecs themselves.
/// Validation errors are surfaced via `.invalid(reason:)` so the scanner UI
/// can display *why* the scan was rejected (expired, tampered, wrong version,
/// …) instead of "unknown QR".
public enum QrPayloadRouter {

    /// Discriminated union of the three accepted payload shapes plus error
    /// cases for unrecognised / malformed strings.
    public enum Decoded: Equatable {
        case identity(IdentityQrCode.Identity)
        case deviceLink(DeviceLinkBinaryQR.Decoded)
        case fastSetup(FastSetupQrCode.Payload)
        /// Recognised prefix but inner decode failed (with reason).
        case invalid(kind: Kind, reason: String)
        /// Prefix didn't match any known shape.
        case unknown(prefix: String)

        public enum Kind: String, Equatable {
            case identity, deviceLink, fastSetup
        }

        public static func == (lhs: Decoded, rhs: Decoded) -> Bool {
            switch (lhs, rhs) {
            case (.identity(let a), .identity(let b)): return a == b
            case (.deviceLink(let a), .deviceLink(let b)): return a == b
            case (.fastSetup(let a), .fastSetup(let b)): return a == b
            case (.invalid(let ka, let ra), .invalid(let kb, let rb)): return ka == kb && ra == rb
            case (.unknown(let a), .unknown(let b)): return a == b
            default: return false
            }
        }
    }

    /// Strip whitespace + try every codec by prefix. The caller is expected
    /// to scan a single QR symbol; we don't attempt multi-payload parsing.
    public static func route(_ raw: String) -> Decoded {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .unknown(prefix: "")
        }

        // Identity QR: textual "QAUDION:" prefix.
        if trimmed.hasPrefix(IdentityQrCode.prefix + ":") {
            do {
                let id = try IdentityQrCode.decode(string: trimmed)
                return .identity(id)
            } catch {
                return .invalid(kind: .identity, reason: error.localizedDescription)
            }
        }

        // qaudion:// URL — distinguish by host (link vs setup).
        if let url = URL(string: trimmed), url.scheme == FastSetupQrCode.urlScheme {
            switch url.host {
            case DeviceLinkBinaryQR.urlHost:
                do {
                    let dec = try DeviceLinkBinaryQR.decode(url: url)
                    return .deviceLink(dec)
                } catch {
                    return .invalid(kind: .deviceLink, reason: error.localizedDescription)
                }
            case FastSetupQrCode.urlHost:
                do {
                    let dec = try FastSetupQrCode.decode(url: url)
                    return .fastSetup(dec)
                } catch {
                    return .invalid(kind: .fastSetup, reason: error.localizedDescription)
                }
            default:
                return .unknown(prefix: "qaudion://\(url.host ?? "")")
            }
        }

        // Surface a 16-char prefix so the scanner UI can show the user what
        // it actually saw, without leaking arbitrarily long strings into the
        // crash logs / UI.
        return .unknown(prefix: String(trimmed.prefix(16)))
    }
}
