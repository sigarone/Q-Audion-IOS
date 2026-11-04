import CryptoKit
import Foundation

/// A sign-in waiting for this device to approve it. `choices` are three two-digit numbers, one of which is
/// the code shown on the new device; the server never says which.
public struct LoginApprovalRequest: Equatable, Identifiable, Sendable {
    public let id: String
    public let deviceName: String
    public let platform: String
    /// Country and kind of network ("Italia, rete mobile"), never an IP address.
    public let area: String
    public let createdAt: Date?
    public let choices: [String]

    public init(id: String, deviceName: String, platform: String, area: String, createdAt: Date?, choices: [String]) {
        self.id = id
        self.deviceName = deviceName
        self.platform = platform
        self.area = area
        self.createdAt = createdAt
        self.choices = choices
    }
}

/// How an approve or deny call ended.
public enum ApprovalResult: Equatable, Sendable {
    case done
    /// 403 `wrong_code` on approve: the number was not the right one and the server closed the entry as denied.
    /// Any other 403 (`device_key_required`: this device has no key row yet) is NOT this: the entry is still
    /// pending and the call is reported as a failure the person can retry.
    case wrongCode
    /// 409: someone else (another device, the administrator, the person on the new device) got there first.
    case alreadyResolved
    /// 404 / 410: the entry is gone (expired, swept).
    case gone
}

public enum DeviceApprovalError: Error, Equatable, Sendable {
    /// No device key, no device id or no REST client: nothing reached the server.
    case notReady
    case malformedChallenge
    case malformedAnswer
}

/// One device of the account, as `GET /api/v1/account/devices` lists it.
public struct AccountDevice: Equatable, Identifiable, Sendable {
    public let deviceId: String
    public let label: String
    public let platform: String
    public let lastSeen: Date?
    /// The device that is asking: it can never be picked for the disconnect.
    public let current: Bool
    public var id: String { deviceId }

    public init(deviceId: String, label: String, platform: String, lastSeen: Date?, current: Bool) {
        self.deviceId = deviceId
        self.label = label
        self.platform = platform
        self.lastSeen = lastSeen
        self.current = current
    }
}

/// The calls of the approving device and of the disconnect prompt.
public protocol DeviceApprovalApi: Sendable {
    /// `GET /api/v1/account/pending-logins`.
    func fetchPending() async throws -> [LoginApprovalRequest]
    /// `POST /api/v1/account/pending-logins/{id}/approve`, signed with the device key.
    func approve(id: String, matchCode: String) async throws -> ApprovalResult
    /// `POST /api/v1/account/pending-logins/{id}/deny`, signed with the device key.
    func deny(id: String) async throws -> ApprovalResult
    /// `POST /api/v1/account/devices/revoke-others`, signed with the device key: every other device of the
    /// account is disconnected. The answer carries the fresh session of THIS device (the old pair is
    /// superseded by the revoke stamp); the caller must store it.
    func revokeOthers() async throws -> PasswordChangeResult
    /// `GET /api/v1/account/devices`: the devices of the caller's account.
    func listDevices() async throws -> [AccountDevice]
    /// `DELETE /api/v1/devices/{id}`: disconnects one other device (the server refuses the current one).
    func revokeDevice(id: String) async throws
}

/// Production `DeviceApprovalApi` on top of `BCryptoRestClient` (bearer and 401 refresh included). The
/// closures are read at call time because the client, the device id and the key can be absent or replaced
/// over the life of this object. The signing is the revoke-device pattern: a single-use nonce from
/// `/auth/device-challenge`, an Ed25519 signature over a domain-tagged blob (`DeviceApprovalBlob`).
public final class BCryptoDeviceApprovalApi: DeviceApprovalApi, @unchecked Sendable {
    public var getRestClient: (() -> BCryptoRestClient?)?
    /// The 32-byte Ed25519 seed of the device key, nil when it is not provisioned.
    public var loadDeviceKeySeed: (() throws -> Data?)?
    public var loadDeviceId: (() -> String?)?

    static let listPath = "/api/v1/account/pending-logins"
    static let revokeOthersPath = "/api/v1/account/devices/revoke-others"
    static let devicesPath = "/api/v1/account/devices"

    public init() {}

    public func fetchPending() async throws -> [LoginApprovalRequest] {
        guard let rest = getRestClient?() else { throw BCryptoError.unauthorized }
        do {
            return try Self.parseList(try await rest.get(Self.listPath))
        } catch BCryptoError.httpError(404) {
            return []
        }
    }

    public func approve(id: String, matchCode: String) async throws -> ApprovalResult {
        let signed = try await sign(tag: DeviceApprovalBlob.tagApprove, subject: id)
        let body = try JSONSerialization.data(withJSONObject: [
            "match_code": matchCode, "nonce": signed.nonceHex, "sig": signed.sigHex,
        ])
        return try await send(path: Self.actionPath(id: id, action: "approve"), body: body, forbiddenIsWrongCode: true)
    }

    public func deny(id: String) async throws -> ApprovalResult {
        let signed = try await sign(tag: DeviceApprovalBlob.tagDeny, subject: id)
        let body = try JSONSerialization.data(withJSONObject: ["nonce": signed.nonceHex, "sig": signed.sigHex])
        return try await send(path: Self.actionPath(id: id, action: "deny"), body: body, forbiddenIsWrongCode: false)
    }

    public func revokeOthers() async throws -> PasswordChangeResult {
        guard let rest = getRestClient?(), let deviceId = loadDeviceId?(), !deviceId.isEmpty,
              let seed = try loadDeviceKeySeed?() else { throw DeviceApprovalError.notReady }
        let challenge = try await fetchChallenge(rest: rest, deviceId: deviceId)
        let epochMs = Int64(Date().timeIntervalSince1970 * 1000)
        let blob = DeviceRenewBlob.buildRevokeOthers(requestingDeviceId: deviceId, nonce: challenge.nonce,
                                                     epochMs: UInt64(epochMs))
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let signature = try key.signature(for: blob)
        let body = try JSONSerialization.data(withJSONObject: [
            "requesting_device_id": deviceId,
            "nonce_hex": challenge.nonceHex,
            "epoch_ms": epochMs,
            "signature_hex": DeviceRenewBlob.hexEncode(signature),
        ] as [String: Any])
        let data = try await rest.post(Self.revokeOthersPath, body: body)
        guard let result = try? JSONDecoder().decode(PasswordChangeResult.self, from: data),
              !result.accessToken.isEmpty, !result.refreshToken.isEmpty, !result.deviceId.isEmpty else {
            throw DeviceApprovalError.malformedAnswer
        }
        return result
    }

    public func listDevices() async throws -> [AccountDevice] {
        guard let rest = getRestClient?() else { throw BCryptoError.unauthorized }
        return try Self.parseDevices(try await rest.get(Self.devicesPath))
    }

    public func revokeDevice(id: String) async throws {
        guard let rest = getRestClient?() else { throw BCryptoError.unauthorized }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let escaped = id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
        _ = try await rest.delete("/api/v1/devices/\(escaped)")
    }

    // MARK: - Internals

    private func send(path: String, body: Data, forbiddenIsWrongCode: Bool) async throws -> ApprovalResult {
        guard let rest = getRestClient?() else { throw BCryptoError.unauthorized }
        let answer = try await rest.postOutcome(path, body: body)
        return try Self.mapAnswer(status: answer.status, data: answer.data, forbiddenIsWrongCode: forbiddenIsWrongCode)
    }

    /// 2xx is done. 403 is a wrong number only when the body says `wrong_code`: the server also answers 403
    /// `device_key_required` (this device has no live key row) before it looks at the number, and then the
    /// entry stays pending, so that case is thrown as a failure the person can retry.
    static func mapAnswer(status: Int, data: Data, forbiddenIsWrongCode: Bool) throws -> ApprovalResult {
        if (200...299).contains(status) { return .done }
        switch status {
        case 403 where forbiddenIsWrongCode && ApprovalWire.errorCode(data).contains("wrong_code"): return .wrongCode
        case 409: return .alreadyResolved
        case 404, 410: return .gone
        case 401: throw BCryptoError.unauthorized
        case 402: throw BCryptoError.paymentRequired
        default: throw BCryptoError.httpError(status)
        }
    }

    private func fetchChallenge(rest: BCryptoRestClient, deviceId: String) async throws
        -> (nonceHex: String, serverId: String, nonce: Data) {
        let encoded = deviceId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? deviceId
        let data = try await rest.get("/api/v1/auth/device-challenge?device_id=\(encoded)")
        guard let object = ApprovalWire.object(data),
              let nonceHex = object["nonce_hex"] as? String,
              let serverId = object["server_id"] as? String,
              let nonce = DeviceRenewBlob.hexDecode(nonceHex),
              nonce.count == DeviceRenewBlob.nonceLenBytes else { throw DeviceApprovalError.malformedChallenge }
        return (nonceHex, serverId, nonce)
    }

    /// Fetches a nonce and signs the blob of `tag` for `subject` (the pending id). The seed lives in memory
    /// only for the duration of the call.
    private func sign(tag: String, subject: String) async throws -> (nonceHex: String, sigHex: String) {
        guard let rest = getRestClient?(), let deviceId = loadDeviceId?(), !deviceId.isEmpty,
              let seed = try loadDeviceKeySeed?() else { throw DeviceApprovalError.notReady }
        let challenge = try await fetchChallenge(rest: rest, deviceId: deviceId)
        let blob = DeviceApprovalBlob.build(tag: tag, serverId: challenge.serverId, pendingId: subject,
                                            approverDeviceId: deviceId, nonce: challenge.nonce)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let signature = try key.signature(for: blob)
        return (challenge.nonceHex, DeviceRenewBlob.hexEncode(signature))
    }

    static func actionPath(id: String, action: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let escaped = id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
        return "\(listPath)/\(escaped)/\(action)"
    }

    /// `{"devices":[{device_id,label,platform,last_seen_ms,current}]}`. A row without `device_id` is left out.
    static func parseDevices(_ data: Data) throws -> [AccountDevice] {
        guard let object = ApprovalWire.object(data), let rows = object["devices"] as? [[String: Any]] else {
            throw BCryptoError.decodingError
        }
        return rows.compactMap { row in
            guard let id = ApprovalWire.string(row["device_id"]), !id.isEmpty else { return nil }
            return AccountDevice(
                deviceId: id,
                label: ApprovalWire.string(row["label"]) ?? "",
                platform: ApprovalWire.string(row["platform"]) ?? "",
                lastSeen: ApprovalWire.date(row["last_seen_ms"]),
                current: (row["current"] as? Bool) ?? false)
        }
    }

    /// An array, or an object whose first array value is the list. An entry without `id` is left out; a
    /// list with fewer than three choices is shown as it is (the server decides what is a valid entry).
    static func parseList(_ data: Data) throws -> [LoginApprovalRequest] {
        let parsed = try? JSONSerialization.jsonObject(with: data)
        var rows: [[String: Any]]?
        if let array = parsed as? [[String: Any]] {
            rows = array
        } else if let object = parsed as? [String: Any] {
            rows = object.values.compactMap { $0 as? [[String: Any]] }.first ?? []
        }
        guard let rows else { throw BCryptoError.decodingError }
        return rows.compactMap { row in
            guard let id = ApprovalWire.string(row["id"]), !id.isEmpty else { return nil }
            let choices = (row["choices"] as? [Any])?.compactMap { ApprovalWire.string($0) } ?? []
            return LoginApprovalRequest(
                id: id,
                deviceName: ApprovalWire.string(row["device_name"]) ?? "",
                platform: ApprovalWire.string(row["platform"]) ?? "",
                area: ApprovalWire.string(row["area"]) ?? "",
                createdAt: ApprovalWire.date(row["created_at"]),
                choices: choices)
        }
    }
}
