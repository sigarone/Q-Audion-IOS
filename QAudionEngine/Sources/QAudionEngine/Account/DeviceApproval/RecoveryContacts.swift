import Combine
import CryptoKit
import Foundation

public enum RecoveryContactKind: String, Sendable {
    case email
    case phone
}

/// What the server holds as recovery contacts of the account: a masked hint and whether it is verified.
/// Never the address or the number itself.
public struct RecoveryContactsStatus: Equatable, Sendable {
    public var emailMasked: String?
    public var emailVerified: Bool
    public var phoneMasked: String?
    public var phoneVerified: Bool

    public init(emailMasked: String? = nil, emailVerified: Bool = false,
                phoneMasked: String? = nil, phoneVerified: Bool = false) {
        self.emailMasked = emailMasked
        self.emailVerified = emailVerified
        self.phoneMasked = phoneMasked
        self.phoneVerified = phoneVerified
    }
}

public enum RecoveryContactError: Error, Equatable, Sendable {
    case invalidValue
    case invalidCode
    case rateLimited
    /// 400 `signature_required`: the server wanted the device signature and the request had none.
    case signatureRequired
    /// 400 `epoch_ms outside skew window`: the clock of this device is wrong.
    case clockSkew
    case failed
}

/// The bytes the device key signs to add, replace or remove a recovery contact (server
/// `auth.BuildRecoveryContactBlob`): `tag 00 deviceId 00 kind 00 sha256Hex(value) 00 nonce(32) 00 epochMs(u64 BE)`.
/// The hash is over the value exactly as sent (trimmed, email not lowercased, phone with its `+`); empty for a remove.
public enum RecoveryContactBlob {
    public static let tag = "QAUDION-RECOVERY-CONTACT-v1"

    public static func valueHash(_ value: String?) -> String {
        guard let value else { return "" }
        return DeviceRenewBlob.hexEncode(Data(SHA256.hash(data: Data(value.utf8))))
    }

    public static func build(deviceId: String, kind: RecoveryContactKind, value: String?, nonce: Data,
                             epochMs: UInt64) -> Data {
        var out = Data()
        for part in [tag, deviceId, kind.rawValue, valueHash(value)] {
            out.append(contentsOf: part.utf8)
            out.append(0x00)
        }
        out.append(nonce)
        out.append(0x00)
        var be = epochMs.bigEndian
        withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
        return out
    }
}

public protocol RecoveryContactsApi: Sendable {
    /// `GET /api/v1/account/recovery-contacts`.
    func fetch() async throws -> RecoveryContactsStatus
    /// `POST /api/v1/account/recovery-contacts/{email|phone}`, signed with the device key: stores the value as
    /// unverified and sends a code.
    func start(kind: RecoveryContactKind, value: String) async throws
    /// `POST /api/v1/account/recovery-contacts/{email|phone}/verify` with the code.
    func verify(kind: RecoveryContactKind, code: String) async throws
    /// `DELETE /api/v1/account/recovery-contacts/{email|phone}`, signed with the device key (the signature goes in
    /// the body of the DELETE).
    func remove(kind: RecoveryContactKind) async throws
}

public final class BCryptoRecoveryContactsApi: RecoveryContactsApi, @unchecked Sendable {
    public var getRestClient: (() -> BCryptoRestClient?)?
    /// The 32-byte Ed25519 seed of the device key, nil when it is not provisioned.
    public var loadDeviceKeySeed: (() throws -> Data?)?
    public var loadDeviceId: (() -> String?)?
    /// Publishes the device key on the server before a signed call (the server answers 403 `device_key_required`
    /// for a device without a key row). Best effort.
    public var ensureDeviceKeyPublished: (() async -> Void)?

    static let basePath = "/api/v1/account/recovery-contacts"

    public init() {}

    public func fetch() async throws -> RecoveryContactsStatus {
        guard let rest = getRestClient?() else { throw BCryptoError.unauthorized }
        let data = try await rest.get(Self.basePath)
        guard let object = ApprovalWire.object(data) else { throw BCryptoError.decodingError }
        return RecoveryContactsStatus(
            emailMasked: Self.nonEmpty(object["email_masked"]),
            emailVerified: (object["email_verified"] as? Bool) ?? false,
            phoneMasked: Self.nonEmpty(object["phone_masked"]),
            phoneVerified: (object["phone_verified"] as? Bool) ?? false)
    }

    public func start(kind: RecoveryContactKind, value: String) async throws {
        // The phone key matches the other OTP calls (`phone_number`, E.164).
        let key = kind == .email ? "email" : "phone_number"
        let sent = value.trimmingCharacters(in: .whitespacesAndNewlines)
        try await sendSigned("POST", "\(Self.basePath)/\(kind.rawValue)", kind: kind, value: sent,
                             extra: [key: sent], codeFailure: .invalidValue)
    }

    public func verify(kind: RecoveryContactKind, code: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["code": code])
        try await post("\(Self.basePath)/\(kind.rawValue)/verify", body: body, codeFailure: .invalidCode)
    }

    public func remove(kind: RecoveryContactKind) async throws {
        do {
            try await sendSigned("DELETE", "\(Self.basePath)/\(kind.rawValue)", kind: kind, value: nil,
                                 extra: [:], codeFailure: .failed)
        } catch BCryptoError.httpError(404) {
            return
        }
    }

    /// Publishes the device key, fetches a single-use nonce and signs the recovery-contact blob. The seed lives in
    /// memory only for the duration of the call.
    private func signedFields(kind: RecoveryContactKind, value: String?) async throws -> [String: Any] {
        await ensureDeviceKeyPublished?()
        guard let rest = getRestClient?(), let deviceId = loadDeviceId?(), !deviceId.isEmpty,
              let seed = try loadDeviceKeySeed?() else { throw DeviceApprovalError.notReady }
        let encoded = deviceId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? deviceId
        let data = try await rest.get("/api/v1/auth/device-challenge?device_id=\(encoded)")
        guard let object = ApprovalWire.object(data), let nonceHex = object["nonce_hex"] as? String,
              let nonce = DeviceRenewBlob.hexDecode(nonceHex),
              nonce.count == DeviceRenewBlob.nonceLenBytes else { throw DeviceApprovalError.malformedChallenge }
        let epochMs = Int64(Date().timeIntervalSince1970 * 1000)
        let blob = RecoveryContactBlob.build(deviceId: deviceId, kind: kind, value: value, nonce: nonce,
                                             epochMs: UInt64(epochMs))
        let signature = try Curve25519.Signing.PrivateKey(rawRepresentation: seed).signature(for: blob)
        return [
            "requesting_device_id": deviceId,
            "nonce_hex": nonceHex,
            "epoch_ms": epochMs,
            "signature_hex": DeviceRenewBlob.hexEncode(signature),
        ]
    }

    /// Signs and sends. The nonce is single use, so a retry never replays a body: after a 401 the session is
    /// refreshed (`GET /auth/device-challenge` is unauthenticated, so reading the challenge proves nothing about the
    /// bearer token) and the whole call is rebuilt, with a new nonce and a new signature, once.
    private func sendSigned(_ method: String, _ path: String, kind: RecoveryContactKind, value: String?,
                            extra: [String: Any], codeFailure: RecoveryContactError) async throws {
        var refreshedOnce = false
        while true {
            var fields = try await signedFields(kind: kind, value: value)
            for (key, item) in extra { fields[key] = item }
            let body = try JSONSerialization.data(withJSONObject: fields)
            guard let rest = getRestClient?() else { throw BCryptoError.unauthorized }
            let answer = try await rest.sendOnce(method, path, body: body)
            if (200...299).contains(answer.status) { return }
            if answer.status == 404, method == "DELETE" { throw BCryptoError.httpError(404) }
            if answer.status == 401, !refreshedOnce {
                refreshedOnce = true
                if await rest.refreshSession(trigger: .rest401).isSuccess { continue }
            }
            throw Self.mapSigned(status: answer.status, data: answer.data, codeFailure: codeFailure)
        }
    }

    /// 400 `signature_required` and 400 `epoch_ms outside skew window` (wrong device clock) are their own errors;
    /// a 401 (bad signature, replayed or expired nonce, or a bearer that could not be refreshed) and a 403
    /// (`device_key_required`, a device that is not the bearer's) are failures of the signing, never "the value is
    /// wrong".
    static func mapSigned(status: Int, data: Data, codeFailure: RecoveryContactError) -> RecoveryContactError {
        if status == 400 {
            let code = ApprovalWire.errorCode(data)
            if code.contains("signature_required") { return .signatureRequired }
            if code.contains("epoch_ms outside skew window") { return .clockSkew }
        }
        if status == 401 || status == 403 { return .failed }
        return map(status: status, codeFailure: codeFailure)
    }

    private func post(_ path: String, body: Data, codeFailure: RecoveryContactError) async throws {
        guard let rest = getRestClient?() else { throw BCryptoError.unauthorized }
        let answer = try await rest.postOutcome(path, body: body)
        if (200...299).contains(answer.status) { return }
        // A wrong verification code is a 401 `invalid code`: the person's mistake, not a dead session, and
        // postOutcome did not spend a token refresh on it. Any other 401 is a rejected session.
        if answer.status == 401 {
            if ApprovalWire.errorCode(answer.data) == "invalid code" { throw codeFailure }
            throw BCryptoError.unauthorized
        }
        if answer.status == 402 { throw BCryptoError.paymentRequired }
        throw Self.map(status: answer.status, codeFailure: codeFailure)
    }

    static func map(status: Int, codeFailure: RecoveryContactError) -> RecoveryContactError {
        switch status {
        case 400, 403, 409, 422: return codeFailure
        case 429: return .rateLimited
        default: return .failed
        }
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }
}

/// State of Settings > Account > "Email e numero per il recupero". Optional contacts, never forced.
/// Per contact: nothing set, a code asked (the value is stored as unverified), verified. Rules, pinned by
/// `RecoveryContactsModelTests`:
///  - a value that is not an email address / an E.164 number is refused locally, no request;
///  - the code step is only reachable after the server accepted the value; a wrong code keeps the step;
///  - removing needs no code; after a remove or a verified add the status is read again from the server;
///  - a rejected session clears the state; other failures raise a plain problem the screen can retry.
@MainActor
public final class RecoveryContactsModel: ObservableObject {
    public enum Step: Equatable, Sendable {
        case idle
        case sending
        case awaitingCode
        case verifying
        case removing
    }

    public enum Problem: Equatable, Sendable {
        case invalidValue
        case invalidCode
        case rateLimited
        /// The clock of this device is wrong (the server refused the signed time).
        case clockWrong
        case failed
    }

    public struct Slot: Equatable, Sendable {
        public var masked: String?
        public var verified = false
        public var step: Step = .idle
        public var problem: Problem?
    }

    @Published public private(set) var email = Slot()
    @Published public private(set) var phone = Slot()
    @Published public private(set) var loadFailed = false

    private let api: RecoveryContactsApi
    private var epoch = 0

    public init(api: RecoveryContactsApi) {
        self.api = api
    }

    public func slot(_ kind: RecoveryContactKind) -> Slot {
        kind == .email ? email : phone
    }

    public func load() async {
        let startedIn = epoch
        do {
            let status = try await api.fetch()
            guard startedIn == epoch else { return }
            loadFailed = false
            apply(status)
        } catch {
            guard startedIn == epoch else { return }
            if case BCryptoError.unauthorized = error { reset() } else { loadFailed = true }
        }
    }

    public func start(_ kind: RecoveryContactKind, value rawValue: String) async {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard slot(kind).step == .idle || slot(kind).step == .awaitingCode else { return }
        guard Self.isValid(kind, value) else {
            update(kind) { $0.problem = .invalidValue }
            return
        }
        update(kind) { $0.step = .sending; $0.problem = nil }
        let startedIn = epoch
        do {
            try await api.start(kind: kind, value: value)
            guard startedIn == epoch else { return }
            update(kind) { $0.step = .awaitingCode; $0.verified = false }
        } catch {
            guard startedIn == epoch else { return }
            update(kind) { $0.step = .idle; $0.problem = Self.problem(error) }
        }
    }

    public func verify(_ kind: RecoveryContactKind, code rawCode: String) async {
        guard slot(kind).step == .awaitingCode else { return }
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 6, code.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            update(kind) { $0.problem = .invalidCode }
            return
        }
        update(kind) { $0.step = .verifying; $0.problem = nil }
        let startedIn = epoch
        do {
            try await api.verify(kind: kind, code: code)
            guard startedIn == epoch else { return }
            update(kind) { $0.step = .idle }
            await load()
        } catch {
            guard startedIn == epoch else { return }
            update(kind) { $0.step = .awaitingCode; $0.problem = Self.problem(error) }
        }
    }

    public func remove(_ kind: RecoveryContactKind) async {
        guard slot(kind).step == .idle else { return }
        update(kind) { $0.step = .removing; $0.problem = nil }
        let startedIn = epoch
        do {
            try await api.remove(kind: kind)
            guard startedIn == epoch else { return }
            update(kind) { $0 = Slot() }
            await load()
        } catch {
            guard startedIn == epoch else { return }
            update(kind) { $0.step = .idle; $0.problem = Self.problem(error) }
        }
    }

    /// The person left the code step without finishing: the value stays stored as unverified on the server.
    public func cancelCode(_ kind: RecoveryContactKind) {
        if slot(kind).step == .awaitingCode { update(kind) { $0.step = .idle; $0.problem = nil } }
    }

    public func reset() {
        epoch += 1
        email = Slot()
        phone = Slot()
        loadFailed = false
    }

    private func apply(_ status: RecoveryContactsStatus) {
        update(.email) {
            $0.masked = status.emailMasked
            $0.verified = status.emailVerified
            if $0.step == .awaitingCode, status.emailVerified { $0.step = .idle }
        }
        update(.phone) {
            $0.masked = status.phoneMasked
            $0.verified = status.phoneVerified
            if $0.step == .awaitingCode, status.phoneVerified { $0.step = .idle }
        }
    }

    private func update(_ kind: RecoveryContactKind, _ change: (inout Slot) -> Void) {
        if kind == .email {
            var slot = email
            change(&slot)
            email = slot
        } else {
            var slot = phone
            change(&slot)
            phone = slot
        }
    }

    static func problem(_ error: Error) -> Problem {
        switch error as? RecoveryContactError {
        case .invalidValue: return .invalidValue
        case .invalidCode: return .invalidCode
        case .rateLimited: return .rateLimited
        case .clockSkew: return .clockWrong
        default: return .failed
        }
    }

    static func isValid(_ kind: RecoveryContactKind, _ value: String) -> Bool {
        switch kind {
        case .email:
            let parts = value.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !value.contains(" ") else { return false }
            let domain = parts[1].split(separator: ".", omittingEmptySubsequences: false)
            return domain.count >= 2 && domain.allSatisfy { !$0.isEmpty }
        case .phone:
            guard value.hasPrefix("+"), (8...16).contains(value.count) else { return false }
            let digits = value.dropFirst()
            return digits.allSatisfy { $0.isASCII && $0.isNumber } && digits.first != "0"
        }
    }
}
