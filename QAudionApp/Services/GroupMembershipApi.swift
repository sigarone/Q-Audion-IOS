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
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return nil }
            let status = http.statusCode
            guard (200..<300).contains(status) else {
                print("[GroupMembershipApi] \(label) HTTP \(status)")
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
        } catch {
            print("[GroupMembershipApi] \(label) error: \(error.localizedDescription)")
            return nil
        }
    }
}
