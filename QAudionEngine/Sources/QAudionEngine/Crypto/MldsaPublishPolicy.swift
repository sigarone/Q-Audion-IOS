import Foundation

/// The server answered 400 with `ed25519_bundle_stored: true`: the extra signature fields were refused on their own
/// and the Ed25519 bundle of the same request is stored. Thrown by `BCryptoRestClient` for that answer only; every
/// other 400 stays `BCryptoError.httpError(400)`.
public struct BCryptoIdentityBundleStored: Error, Equatable, Sendable {
    /// A short, printable-ASCII server text. No key material.
    public let reason: String

    public init(reason: String) { self.reason = reason }
}

/// What a publish of the identity bundle does with the extra signature fields (design notes section 5.3),
/// kept apart from the app target so it can be tested without a network. Mirrors Android `MldsaPublishPolicy`.
///
/// The extra part is additive and never blocking:
///  - HTTP 400 with the JSON boolean `ed25519_bundle_stored: true` means the Ed25519 bundle is stored and only the
///    extra fields were refused. That is a successful Ed25519 publish: the caller marks the bundle published and does
///    not retry, so a refused certificate cannot turn into a publish loop.
///  - HTTP 400 without that marker, or 413, with the fields attached: a server or proxy that dislikes the body. One
///    single fallback publish without the fields, so the Ed25519 path never fails because of them.
///  - Anything else (network, 401, 429, 5xx) is rethrown exactly as before.
public enum MldsaPublishPolicy {

    /// Server flag that can only switch the publication off. On by default: absent or non-Bool leaves it on, a
    /// `true` changes nothing.
    public static let flagKey = "pqc.mldsa_publish"
    public static let compiledDefault = true

    public enum Outcome: Equatable, Sendable {
        /// Published without the extra fields (disabled, or no usable device id).
        case plain
        /// The server stored the key: the ack carried this key's id.
        case accepted
        /// The Ed25519 bundle is stored; the extra fields are not (`reason` is short, no key material).
        case refused(reason: String)
        /// A 200 whose ack did not carry this key's id (a server that ignores the fields): the Ed25519 bundle is
        /// stored, the key is not treated as accepted, and nothing is retried.
        case unacknowledged
    }

    private static let maxReasonChars = 120

    /// Sends `fields` through `send`, which returns the `mldsa_key_id_b64` of the ack (or nil).
    public static func publish(
        _ fields: MldsaIdentityPublication.Fields?,
        send: (MldsaIdentityPublication.Fields?) async throws -> String?
    ) async throws -> Outcome {
        guard let fields else {
            _ = try await send(nil)
            return .plain
        }
        do {
            let ackKeyId = try await send(fields)
            return ackMatches(ackKeyId, fields) ? .accepted : .unacknowledged
        } catch let stored as BCryptoIdentityBundleStored {
            return .refused(reason: stored.reason)
        } catch BCryptoError.httpError(let code) where code == 400 || code == 413 {
            // One bounded fallback. Its own failure propagates (it is then a real Ed25519 publish failure).
            _ = try await send(nil)
            return .refused(reason: "fallback_after_http_\(code)")
        }
    }

    /// The ack names this key: `mldsa_key_id_b64` decodes to SHA-256 of the key we sent.
    static func ackMatches(_ ackKeyId: String?, _ fields: MldsaIdentityPublication.Fields) -> Bool {
        guard let ackKeyId, !ackKeyId.isEmpty, let ack = Data(base64Encoded: ackKeyId),
              let ours = Data(base64Encoded: fields.keyIdB64) else { return false }
        return ack == ours
    }

    /// `mldsa_key_id_b64` of a publish acknowledgement body, or nil.
    public static func ackKeyId(in body: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        return object["mldsa_key_id_b64"] as? String
    }

    /// True only for the JSON literal `true`: a quoted "true", a number or null do not count.
    public static func ed25519BundleStored(_ body: Data?) -> Bool {
        guard let body, let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let value = object["ed25519_bundle_stored"] as? NSNumber else { return false }
        return CFGetTypeID(value) == CFBooleanGetTypeID() && value.boolValue
    }

    /// The server's `error` text cut to printable ASCII and 120 characters; "refused" when there is none.
    public static func refusalReason(_ body: Data?) -> String {
        guard let body, let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let text = object["error"] as? String else { return "refused" }
        var kept = String.UnicodeScalarView()
        var n = 0
        for scalar in text.unicodeScalars where (0x20...0x7E).contains(scalar.value) {
            if n >= maxReasonChars { break }
            kept.append(scalar)
            n += 1
        }
        let cut = String(kept)
        return cut.isEmpty ? "refused" : cut
    }
}

/// Parts of the dedupe fingerprint that belong to the extra fields.
extension IdentityPublishFingerprint {
    /// "m0" when the extra fields are not published for this device (switch off, or no usable device id), else
    /// "m1:<device id>": a device republishes once when the switch flips or the id the certificate is bound to
    /// changes.
    public static func mldsaBindingToken(enabled: Bool, deviceId: String?) -> String {
        guard enabled, MldsaIdentityPublication.isPublishableDeviceId(deviceId), let deviceId else { return "m0" }
        return "m1:\(deviceId)"
    }
}
