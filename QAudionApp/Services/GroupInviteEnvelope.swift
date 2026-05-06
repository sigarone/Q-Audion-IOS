import Foundation

/// W403 — `qa_grp:1` envelope variants for cross-platform group
/// membership signaling.
///
/// **Cross-platform alignment (verified 2026-05-02):**
/// - Desktop (`GroupMembershipService.ts`) ships `t` tokens **without**
///   the `group_` prefix: `member_added`, `member_removed`, `member_left`.
/// - Android (qaudion-android-new) onboards via QR code +
///   `POST /api/v1/groups/:id/join` REST. Only `sender_key_init` /
///   `sender_key_rotate` qa_grp envelopes are recognised over 1:1.
/// - iOS (W399) originally shipped its own prefixed wire (`group_invite`,
///   `group_member_added`, `group_member_removed`, `group_invite_decline`)
///   that did not interoperate with either Desktop or Android.
///
/// **W403 strategy — iOS as superset:**
/// 1. Outbound: emit BOTH the legacy iOS `group_invite` envelope (for
///    iOS↔iOS UX continuity — the modal sheet) AND the Desktop-aligned
///    `member_added` events that Desktop/Android consume.
/// 2. All membership envelopes now carry `e: UInt32` (group epoch)
///    bound to `state.groupEpoch` so a replayed legacy envelope cannot
///    roll back state (rationale: cross-platform code review flagged
///    a replay/downgrade vector when accepting both prefixed and
///    unprefixed forms).
/// 3. Inbound dispatcher accepts BOTH new (`member_added`) and legacy
///    (`group_member_added`) tokens. Legacy form is gated on `e ≥
///    state.epoch`. Legacy decoder will be removed in a future release.
/// 4. New `member_left` envelope distinguishes voluntary leave from
///    admin kick (`member_removed`) — Desktop already does this.
/// 5. `group_invite_decline` is dropped (dead code: a declined invite
///    is just an ignored sender_key_init; no Desktop equivalent).
///
/// **Wire shapes:**
///
/// ```
/// // Desktop-aligned (preferred, cross-platform):
/// { qa_grp:1, t:"member_added",   g:<gidHex>, e:<epoch>, member:<uid>, from:<adminUid>, ts:<unix> }
/// { qa_grp:1, t:"member_removed", g:<gidHex>, e:<epoch>, member:<uid>, from:<adminUid>, ts:<unix> }
/// { qa_grp:1, t:"member_left",    g:<gidHex>, e:<epoch>, member:<uid>, from:<leaverUid>, ts:<unix> }
///
/// // iOS-only enhancement (Desktop/Android log-and-ignore as unknown):
/// { qa_grp:1, t:"group_invite",   g:<gidHex>, name:<plain>, members:[uid...],
///   admins:[uid...], from:<adminUid>, e:<epoch>, ts:<unix> }
///
/// // Legacy iOS (W399) — accepted on inbound for one release cycle,
/// // then removed:
/// { qa_grp:1, t:"group_member_added"  | "group_member_removed", g, member, ts, [e?] }
/// ```
public enum GroupInviteEnvelope {

    /// iOS-only enhancement — full group state on first contact.
    /// Desktop/Android peers log `unknown qa_grp envelope` and rely
    /// on the parallel `member_added` fan-out to learn the roster.
    public struct Invite: Codable, Equatable {
        public let qa_grp: Int
        public let t: String          // "group_invite"
        public let g: String          // groupId hex
        public let name: String
        public let members: [String]
        public let admins: [String]
        public let from: String       // sender admin userId
        /// W403: group epoch at the time of invite. Receiver gates
        /// future state mutations against this baseline.
        public let e: UInt32
        public let ts: Int64

        public init(g: String, name: String, members: [String],
                    admins: [String], from: String, e: UInt32, ts: Int64) {
            self.qa_grp = 1
            self.t = "group_invite"
            self.g = g
            self.name = name
            self.members = members
            self.admins = admins
            self.from = from
            self.e = e
            self.ts = ts
        }
    }

    /// Desktop-aligned wire (`t:"member_added"`, no `group_` prefix).
    /// Outbound iOS emits this AS WELL AS the legacy `Invite` envelope.
    /// Inbound dispatcher accepts EITHER `t:"member_added"` (preferred)
    /// or `t:"group_member_added"` (legacy iOS, with epoch gate).
    public struct MemberAdded: Codable, Equatable {
        public let qa_grp: Int
        public let t: String          // "member_added"
        public let g: String
        public let e: UInt32          // W403: epoch (must match state.epoch)
        public let member: String
        public let from: String       // W403: signing admin userId
        public let ts: Int64

        public init(g: String, e: UInt32, member: String, from: String, ts: Int64) {
            self.qa_grp = 1
            self.t = "member_added"
            self.g = g
            self.e = e
            self.member = member
            self.from = from
            self.ts = ts
        }
    }

    public struct MemberRemoved: Codable, Equatable {
        public let qa_grp: Int
        public let t: String          // "member_removed"
        public let g: String
        public let e: UInt32
        public let member: String
        public let from: String
        public let ts: Int64

        public init(g: String, e: UInt32, member: String, from: String, ts: Int64) {
            self.qa_grp = 1
            self.t = "member_removed"
            self.g = g
            self.e = e
            self.member = member
            self.from = from
            self.ts = ts
        }
    }

    /// W403 — voluntary leave path, distinct from `member_removed`
    /// (admin kick). Desktop renders these differently in the UI;
    /// without this distinction, a leave looks like a kick.
    public struct MemberLeft: Codable, Equatable {
        public let qa_grp: Int
        public let t: String          // "member_left"
        public let g: String
        public let e: UInt32
        public let member: String     // userId leaving (== from in this case)
        public let from: String       // sender userId (== member)
        public let ts: Int64

        public init(g: String, e: UInt32, member: String, from: String, ts: Int64) {
            self.qa_grp = 1
            self.t = "member_left"
            self.g = g
            self.e = e
            self.member = member
            self.from = from
            self.ts = ts
        }
    }

    /// LEGACY decoder shape — accepts the W399 prefixed wire when the
    /// remote peer hasn't upgraded yet. The dispatcher converts to the
    /// canonical `MemberAdded`/`MemberRemoved` shape after epoch gate.
    /// Optional `e` for forward-compat: W399 didn't include it; legacy
    /// envelopes without `e` are accepted as `e = 0` (will pass any
    /// epoch ≥ 1 state, but only on initial bootstrap).
    public struct LegacyMemberDelta: Codable, Equatable {
        public let qa_grp: Int
        public let t: String          // "group_member_added" | "group_member_removed"
        public let g: String
        public let member: String
        public let e: UInt32?         // W403 — present only on post-W403 senders
        public let from: String?      // W403 — present only on post-W403 senders
        public let ts: Int64
    }

    // MARK: - Encode

    public static func encodeInvite(_ env: Invite) -> String? {
        guard let data = try? JSONEncoder().encode(env) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func encodeMemberAdded(_ env: MemberAdded) -> String? {
        guard let data = try? JSONEncoder().encode(env) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func encodeMemberRemoved(_ env: MemberRemoved) -> String? {
        guard let data = try? JSONEncoder().encode(env) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func encodeMemberLeft(_ env: MemberLeft) -> String? {
        guard let data = try? JSONEncoder().encode(env) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Decode

    public static func decodeInvite(_ json: String) -> Invite? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Invite.self, from: data)
    }

    public static func decodeMemberAdded(_ json: String) -> MemberAdded? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MemberAdded.self, from: data)
    }

    public static func decodeMemberRemoved(_ json: String) -> MemberRemoved? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MemberRemoved.self, from: data)
    }

    public static func decodeMemberLeft(_ json: String) -> MemberLeft? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MemberLeft.self, from: data)
    }

    public static func decodeLegacyMemberDelta(_ json: String) -> LegacyMemberDelta? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(LegacyMemberDelta.self, from: data)
    }
}
