import Foundation

/// Fase 1A — client for the server-authoritative group membership REST
/// endpoints (admin add / admin remove), plus the byte-deterministic
/// canonical envelope the server verifies with the actor's Ed25519
/// identity key.
///
/// Server contract (verified against
/// `bcrypto-server/cmd/bcrypto-lite/groups_membership.go`, 2026-07-14):
///   - ADD:    `POST   /api/v1/groups/{gid}/members`
///             body `{user_id, signed_envelope_b64, admin_signature_b64}`
///             envelope `t = "member_added"`, admin-only, 201 Created.
///   - REMOVE: `DELETE /api/v1/groups/{gid}/members/{uid}`
///             body `{signed_envelope_b64, admin_signature_b64}`
///             envelope `t = "member_removed"`, admin-only, 200 OK.
/// Both reply `membershipResponse {group_id, group_epoch, members[],
/// admins[], ...}` — `group_epoch` is the NEW server-canonical membership
/// epoch, learned synchronously by the actor here (asynchronously by the
/// other members via the `group_membership_changed` WS broadcast).
///
/// `{gid}` and the envelope `g` field are the DASHED-UUID wire form (the
/// server treats the id opaquely as a string — see Android
/// `MembershipEnvelope` KDoc). This is `UUID().uuidString.lowercased()`,
/// NOT the dash-stripped hex the local `GroupRegistry` keys on.
///
/// Pattern mirrors `TrackBSyncService`: cert-pinned session, Bearer JWT,
/// best-effort (a network/HTTP failure never rolls back the local crypto
/// or the P2P `member_added/removed` envelope fan-out).

// MARK: - Canonical envelope

/// Byte-identical to:
///   - Server `buildCanonicalEnvelope()` (groups_membership.go)
///   - Android `MembershipEnvelope.build()`
///   - Desktop `src/main/group/MembershipEnvelope.ts`
///
/// Wire shape (no whitespace, lex-sorted keys):
///   `{"by":"<actor>","e_proposed":<u32>,"g":"<gid>","t":"<op>","ts":<unix_s>,"uid":"<subject>"}`
enum GroupMembershipEnvelope {
    static let opAdd = "member_added"
    static let opRemove = "member_removed"
    static let opLeave = "member_left"
    /// Fase 1C — envelope `t` for `PUT …/metadata` (rename/avatar). `uid`
    /// carries the lowercase-hex SHA-256 of the RAW pre-base64 encrypted
    /// blob bytes, not a user id (server contract, verbatim).
    static let opMetadataUpdated = "metadata_updated"
    /// Fase 1C — envelope `t` for `POST/DELETE …/admins/{uid}`. `uid` is
    /// the TARGET user id being promoted/demoted. NOTE: distinct from the
    /// inbound `group_membership_changed` WS `operation` values, which are
    /// `"admin_add"`/`"admin_remove"` (server contract, verbatim).
    static let opAdminAdd = "admin_added"
    static let opAdminRemove = "admin_removed"

    /// Render the canonical envelope bytes.
    /// - Parameters:
    ///   - actorUserId: `by` — the user signing this envelope.
    ///   - eProposed: `e_proposed` — the new server `group_epoch` the actor
    ///     claims results from this op. Post-mutation value: `current` for
    ///     add (§7.1 — add does not bump the CRYPTO epoch but the server
    ///     still stores current here per Android), `current + 1` for
    ///     remove/leave.
    ///   - groupIdWire: `g` — the dashed-UUID group id (server-opaque).
    ///   - operation: `t` — `opAdd` / `opRemove` / `opLeave`.
    ///   - tsUnixSeconds: `ts` — wall-clock unix SECONDS (not ms).
    ///   - subjectUserId: `uid` — user being added/removed (== actor for leave).
    static func build(
        actorUserId: String,
        eProposed: UInt32,
        groupIdWire: String,
        operation: String,
        tsUnixSeconds: Int64,
        subjectUserId: String
    ) -> Data {
        var s = "{"
        s += "\"by\":"; appendJsonString(&s, actorUserId)
        s += ",\"e_proposed\":\(eProposed)"
        s += ",\"g\":"; appendJsonString(&s, groupIdWire)
        s += ",\"t\":"; appendJsonString(&s, operation)
        s += ",\"ts\":\(tsUnixSeconds)"
        s += ",\"uid\":"; appendJsonString(&s, subjectUserId)
        s += "}"
        return Data(s.utf8)
    }

    /// Mirrors the Go `writeJSONString` byte-for-byte: only RFC-mandatory
    /// escapes; other control bytes as lowercase `\uXXXX`; non-ASCII passes
    /// through as raw UTF-8 (Ed25519 signs raw bytes).
    private static func appendJsonString(_ s: inout String, _ value: String) {
        s += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": s += "\\\""
            case "\\": s += "\\\\"
            case "\n": s += "\\n"
            case "\r": s += "\\r"
            case "\t": s += "\\t"
            default:
                if scalar.value < 0x20 {
                    s += String(format: "\\u%04x", scalar.value)
                } else {
                    s.unicodeScalars.append(scalar)
                }
            }
        }
        s += "\""
    }
}

// MARK: - Fase 1C — metadata payload (packed BEFORE encryption)

/// The plaintext JSON packed into the 0xE4 group wire, per the server
/// contract (verbatim): `{name, avatar_ref}` — `avatar_ref` omitted
/// (nil) for "no avatar". Never sent over HTTP directly; only its
/// ENCRYPTED wire bytes (`metadata_blob_b64`) are.
struct GroupMetadataPayload: Codable, Equatable {
    let name: String
    let avatarRef: String?

    enum CodingKeys: String, CodingKey {
        case name
        case avatarRef = "avatar_ref"
    }
}

// MARK: - REST client

struct GroupMembershipResult {
    let groupEpoch: UInt32
    let members: [String]
    let admins: [String]
    /// The HTTP status the server returned (201/200 on success; 401 not
    /// admin, 404 group/member not found, 409 already member, 410
    /// dissolved / last admin, 422 envelope mismatch).
    let statusCode: Int
    var isSuccess: Bool { (200..<300).contains(statusCode) }
}

/// Fase 1C — reply of `PUT …/metadata`: `{group_id, metadata_version,
/// server_ts}`.
struct GroupMetadataResult {
    let metadataVersion: UInt32
    let statusCode: Int
    var isSuccess: Bool { (200..<300).contains(statusCode) }
}

/// Fase 1C — reply of `GET /api/v1/groups/{gid}` (group load/join
/// recovery). `metadataBlobB64`/`metadataVersion` are omitted server-side
/// when unset — nil / 0 here means "this group has no metadata yet".
struct GroupFetchResult {
    let groupEpoch: UInt32
    let members: [String]
    let admins: [String]
    let metadataBlobB64: String?
    let metadataVersion: UInt32
    let statusCode: Int
    var isSuccess: Bool { (200..<300).contains(statusCode) }
}

/// One entry of `GET /api/v1/groups`'s `groups[]` array — same fields as
/// `GroupFetchResult` plus the group id, since a list response (unlike the
/// single-group GET) doesn't already have the id from the request path.
struct GroupListEntry {
    let groupIdWire: String
    let groupEpoch: UInt32
    let members: [String]
    let admins: [String]
    let metadataBlobB64: String?
    let metadataVersion: UInt32
}

@MainActor
final class GroupMembershipApi {

    private let baseURL: URL?
    private let token: String?
    private let session: URLSession

    init(serverUrl: String, accessToken: String?) {
        self.baseURL = URL(string: serverUrl)
        self.token = accessToken
        self.session = PinnedURLSession.make(for: serverUrl)
    }

    /// Convenience factory — nil (no-op) if unauthenticated.
    static func from(serverUrl: String, token: String?) -> GroupMembershipApi? {
        guard let token = token, !token.isEmpty else { return nil }
        return GroupMembershipApi(serverUrl: serverUrl, accessToken: token)
    }

    /// POST /api/v1/groups — register the group server-side (Fase 1A).
    ///
    /// Body is byte-identical to the Android/Desktop `createGroupRequest`
    /// (`bcrypto-server/cmd/bcrypto-lite/groups.go` — `{group_id, members,
    /// admins}`); the server assigns `group_epoch = 1` and requires the
    /// caller to be present in BOTH `members` and `admins`. Reply is
    /// `groupResponse {group_id, created_at, group_epoch, members, admins}`
    /// — the same `group_epoch`/`members`/`admins` fields `fire` parses.
    ///
    /// Idempotent by contract of the CALLER: an already-existing group
    /// (Android/Desktop created it first, iOS re-creates) surfaces as a
    /// non-2xx `GroupMembershipResult` (the caller keeps its local crypto
    /// state and does not hard-fail). `groupIdWire` is the DASHED-UUID wire
    /// form the server + Android key on (`AppState.hexToDashedUUID`).
    func createGroup(
        groupIdWire: String,
        members: [String],
        admins: [String]
    ) async -> GroupMembershipResult? {
        guard let url = endpoint("/api/v1/groups") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        addAuth(&req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "group_id": groupIdWire,
            "members": members,
            "admins": admins,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return await fire(req, label: "groups.create[\(groupIdWire)]")
    }

    /// POST /api/v1/groups/{gid}/members — admin adds `userId`.
    func addMember(
        groupIdWire: String,
        userId: String,
        signedEnvelopeB64: String,
        adminSignatureB64: String
    ) async -> GroupMembershipResult? {
        guard let url = endpoint("/api/v1/groups/\(groupIdWire)/members") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        addAuth(&req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "user_id": userId,
            "signed_envelope_b64": signedEnvelopeB64,
            "admin_signature_b64": adminSignatureB64,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return await fire(req, label: "groups.addMember[\(userId)]")
    }

    /// DELETE /api/v1/groups/{gid}/members/{uid} — admin removes `userId`.
    func removeMember(
        groupIdWire: String,
        userId: String,
        signedEnvelopeB64: String,
        adminSignatureB64: String
    ) async -> GroupMembershipResult? {
        guard let url = endpoint("/api/v1/groups/\(groupIdWire)/members/\(userId)") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        addAuth(&req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "signed_envelope_b64": signedEnvelopeB64,
            "admin_signature_b64": adminSignatureB64,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return await fire(req, label: "groups.removeMember[\(userId)]")
    }

    /// POST /api/v1/groups/{gid}/admins/{uid} — admin promotes `userId`.
    func promoteAdmin(
        groupIdWire: String,
        userId: String,
        signedEnvelopeB64: String,
        adminSignatureB64: String
    ) async -> GroupMembershipResult? {
        guard let url = endpoint("/api/v1/groups/\(groupIdWire)/admins/\(userId)") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        addAuth(&req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "signed_envelope_b64": signedEnvelopeB64,
            "admin_signature_b64": adminSignatureB64,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return await fire(req, label: "groups.promoteAdmin[\(userId)]")
    }

    /// DELETE /api/v1/groups/{gid}/admins/{uid} — admin demotes `userId`.
    /// Server replies 409 if `userId` is the last remaining admin.
    func demoteAdmin(
        groupIdWire: String,
        userId: String,
        signedEnvelopeB64: String,
        adminSignatureB64: String
    ) async -> GroupMembershipResult? {
        guard let url = endpoint("/api/v1/groups/\(groupIdWire)/admins/\(userId)") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        addAuth(&req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "signed_envelope_b64": signedEnvelopeB64,
            "admin_signature_b64": adminSignatureB64,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return await fire(req, label: "groups.demoteAdmin[\(userId)]")
    }

    /// PUT /api/v1/groups/{gid}/metadata — admin renames / sets the avatar.
    /// `metadataBlobB64` is the base64 of the ENCRYPTED (0xE4 wire) blob,
    /// NOT the plaintext JSON.
    func updateMetadata(
        groupIdWire: String,
        metadataBlobB64: String,
        signedEnvelopeB64: String,
        adminSignatureB64: String
    ) async -> GroupMetadataResult? {
        guard let url = endpoint("/api/v1/groups/\(groupIdWire)/metadata") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        addAuth(&req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "metadata_blob_b64": metadataBlobB64,
            "signed_envelope_b64": signedEnvelopeB64,
            "admin_signature_b64": adminSignatureB64,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, status) = await fireRaw(req, label: "groups.updateMetadata") else { return nil }
        guard (200..<300).contains(status) else {
            return GroupMetadataResult(metadataVersion: 0, statusCode: status)
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let version: UInt32
        if let n = json?["metadata_version"] as? NSNumber {
            version = UInt32(truncatingIfNeeded: n.int64Value)
        } else {
            version = 0
        }
        return GroupMetadataResult(metadataVersion: version, statusCode: status)
    }

    /// GET /api/v1/groups/{gid} — group load/join recovery (Fase 1C: a
    /// fresh device that only has the roster from `group_membership_changed`
    /// pulls the current `metadata_blob_b64`/`metadata_version` here so it
    /// can decrypt+apply the group name/avatar without waiting for the
    /// next live rename).
    func fetchGroup(groupIdWire: String) async -> GroupFetchResult? {
        guard let url = endpoint("/api/v1/groups/\(groupIdWire)") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        addAuth(&req)
        guard let (data, status) = await fireRaw(req, label: "groups.fetch[\(groupIdWire)]") else { return nil }
        guard (200..<300).contains(status) else {
            return GroupFetchResult(groupEpoch: 0, members: [], admins: [],
                                     metadataBlobB64: nil, metadataVersion: 0, statusCode: status)
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let epochAny = json?["group_epoch"]
        let epoch: UInt32
        if let n = epochAny as? NSNumber {
            epoch = UInt32(truncatingIfNeeded: n.int64Value)
        } else {
            epoch = 0
        }
        let versionAny = json?["metadata_version"]
        let version: UInt32
        if let n = versionAny as? NSNumber {
            version = UInt32(truncatingIfNeeded: n.int64Value)
        } else {
            version = 0
        }
        return GroupFetchResult(
            groupEpoch: epoch,
            members: json?["members"] as? [String] ?? [],
            admins: json?["admins"] as? [String] ?? [],
            metadataBlobB64: json?["metadata_blob_b64"] as? String,
            metadataVersion: version,
            statusCode: status)
    }

    /// GET /api/v1/groups — reconciliation backstop (2026-07-17): the server
    /// fan-out for `group_membership_changed`/`group_metadata_changed` is
    /// live-WS-only best-effort (no APNs/FCM wake) — a member added while
    /// offline, or one whose WS reconnects mid-event, never receives it and
    /// had NO other way to discover the group (the per-group GET above
    /// requires already knowing `group_id`). Lists every group the caller
    /// is CURRENTLY a member of, full roster + epoch + opaque metadata
    /// blob. Call on launch + WS reconnect (see `AppState.reconcileAllGroupsFromServer`).
    /// Returns nil only on a transport-level failure or non-2xx — an empty
    /// array is a valid "no groups" response, not a failure.
    func fetchAllGroups() async -> [GroupListEntry]? {
        guard let url = endpoint("/api/v1/groups") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        addAuth(&req)
        guard let (data, status) = await fireRaw(req, label: "groups.fetchAll") else { return nil }
        guard (200..<300).contains(status) else { return nil }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let arr = json["groups"] as? [[String: Any]] else {
            return []
        }
        return arr.compactMap { g -> GroupListEntry? in
            guard let groupIdWire = g["group_id"] as? String, !groupIdWire.isEmpty else { return nil }
            let epoch: UInt32
            if let n = g["group_epoch"] as? NSNumber {
                epoch = UInt32(truncatingIfNeeded: n.int64Value)
            } else {
                epoch = 0
            }
            let version: UInt32
            if let n = g["metadata_version"] as? NSNumber {
                version = UInt32(truncatingIfNeeded: n.int64Value)
            } else {
                version = 0
            }
            return GroupListEntry(
                groupIdWire: groupIdWire,
                groupEpoch: epoch,
                members: g["members"] as? [String] ?? [],
                admins: g["admins"] as? [String] ?? [],
                metadataBlobB64: g["metadata_blob_b64"] as? String,
                metadataVersion: version)
        }
    }

    // MARK: - Internals

    private func endpoint(_ path: String) -> URL? {
        guard let base = baseURL else { return nil }
        return URL(string: base.absoluteString + path)
    }

    private func addAuth(_ req: inout URLRequest) {
        if let t = token, !t.isEmpty {
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
    }

    private func fire(_ req: URLRequest, label: String) async -> GroupMembershipResult? {
        guard let (data, status) = await fireRaw(req, label: label) else { return nil }
        guard (200..<300).contains(status) else {
            return GroupMembershipResult(groupEpoch: 0, members: [], admins: [], statusCode: status)
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let epochAny = json?["group_epoch"]
        let epoch: UInt32
        if let n = epochAny as? NSNumber {
            epoch = UInt32(truncatingIfNeeded: n.int64Value)
        } else {
            epoch = 0
        }
        let members = json?["members"] as? [String] ?? []
        let admins = json?["admins"] as? [String] ?? []
        return GroupMembershipResult(
            groupEpoch: epoch, members: members, admins: admins, statusCode: status)
    }

    /// Fase 1C — raw fetch shared by `fire` (membershipResponse shape) and
    /// the new metadata/GET endpoints (different reply shapes). Returns nil
    /// only on a transport-level failure (no HTTP response at all); any
    /// HTTP status — including 4xx/5xx — is returned so the caller can
    /// surface it via its own result struct's `statusCode`.
    private func fireRaw(_ req: URLRequest, label: String) async -> (data: Data, status: Int)? {
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return nil }
            let status = http.statusCode
            if !(200..<300).contains(status) {
                print("[GroupMembershipApi] \(label) HTTP \(status)")
            }
            return (data, status)
        } catch {
            print("[GroupMembershipApi] \(label) error: \(error.localizedDescription)")
            return nil
        }
    }
}
