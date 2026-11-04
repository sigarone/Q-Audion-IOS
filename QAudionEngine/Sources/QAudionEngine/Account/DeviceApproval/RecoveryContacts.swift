import Combine
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
    case failed
}

public protocol RecoveryContactsApi: Sendable {
    /// `GET /api/v1/account/recovery-contacts`.
    func fetch() async throws -> RecoveryContactsStatus
    /// `POST /api/v1/account/recovery-contacts/{email|phone}`: stores the value as unverified and sends a code.
    func start(kind: RecoveryContactKind, value: String) async throws
    /// `POST /api/v1/account/recovery-contacts/{email|phone}/verify` with the code.
    func verify(kind: RecoveryContactKind, code: String) async throws
    /// `DELETE /api/v1/account/recovery-contacts/{email|phone}`.
    func remove(kind: RecoveryContactKind) async throws
}

public final class BCryptoRecoveryContactsApi: RecoveryContactsApi, @unchecked Sendable {
    public var getRestClient: (() -> BCryptoRestClient?)?

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
        let body = try JSONSerialization.data(withJSONObject: [key: value])
        try await post("\(Self.basePath)/\(kind.rawValue)", body: body, codeFailure: .invalidValue)
    }

    public func verify(kind: RecoveryContactKind, code: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["code": code])
        try await post("\(Self.basePath)/\(kind.rawValue)/verify", body: body, codeFailure: .invalidCode)
    }

    public func remove(kind: RecoveryContactKind) async throws {
        guard let rest = getRestClient?() else { throw BCryptoError.unauthorized }
        do {
            _ = try await rest.delete("\(Self.basePath)/\(kind.rawValue)")
        } catch BCryptoError.httpError(404) {
            return
        }
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
