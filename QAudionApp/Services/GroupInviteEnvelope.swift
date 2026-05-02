import Foundation

/// W399 — `qa_grp:1` envelope variants beyond sender_key_init/rotate
/// for membership signaling.
///
/// **Wire shapes** (all wrapped in 1:1 ratchet — same path as
/// sender_key_init from W390):
///
/// 1. `group_invite` — admin asks a peer to join.
///    ```
///    { qa_grp:1, t:"group_invite",
///      g:<gidHex>, name:<plain>,
///      members:[<userId>...], admins:[<userId>...],
///      from:<adminUserId>, ts:<unix> }
///    ```
///
/// 2. `group_member_added` — admin announces a new member to all
///    other existing members.
///    ```
///    { qa_grp:1, t:"group_member_added",
///      g:<gidHex>, member:<userId>, ts:<unix> }
///    ```
///
/// 3. `group_member_removed` — admin announces a member departure.
///    ```
///    { qa_grp:1, t:"group_member_removed",
///      g:<gidHex>, member:<userId>, ts:<unix> }
///    ```
///
/// 4. `group_invite_decline` — invitee tells the admin they didn't
///    accept. Optional ("ignore the invite" is also valid behavior).
///    ```
///    { qa_grp:1, t:"group_invite_decline",
///      g:<gidHex>, ts:<unix> }
///    ```
///
/// All four ride the same per-pair PSK / v3 ratchet that
/// sender_key_init uses (W390). The dispatcher detects via
/// GroupChatService.detectGroupCtlType (already gates on qa_grp:1).
public enum GroupInviteEnvelope {

    public struct Invite: Codable, Equatable {
        public let qa_grp: Int
        public let t: String          // "group_invite"
        public let g: String          // groupId hex
        public let name: String
        public let members: [String]
        public let admins: [String]
        public let from: String       // sender admin userId
        public let ts: Int64

        public init(g: String, name: String, members: [String],
                    admins: [String], from: String, ts: Int64) {
            self.qa_grp = 1
            self.t = "group_invite"
            self.g = g
            self.name = name
            self.members = members
            self.admins = admins
            self.from = from
            self.ts = ts
        }
    }

    public struct MemberAdded: Codable, Equatable {
        public let qa_grp: Int
        public let t: String          // "group_member_added"
        public let g: String
        public let member: String
        public let ts: Int64

        public init(g: String, member: String, ts: Int64) {
            self.qa_grp = 1
            self.t = "group_member_added"
            self.g = g
            self.member = member
            self.ts = ts
        }
    }

    public struct MemberRemoved: Codable, Equatable {
        public let qa_grp: Int
        public let t: String          // "group_member_removed"
        public let g: String
        public let member: String
        public let ts: Int64

        public init(g: String, member: String, ts: Int64) {
            self.qa_grp = 1
            self.t = "group_member_removed"
            self.g = g
            self.member = member
            self.ts = ts
        }
    }

    public struct InviteDecline: Codable, Equatable {
        public let qa_grp: Int
        public let t: String          // "group_invite_decline"
        public let g: String
        public let ts: Int64

        public init(g: String, ts: Int64) {
            self.qa_grp = 1
            self.t = "group_invite_decline"
            self.g = g
            self.ts = ts
        }
    }

    // MARK: - Encode helpers

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

    public static func encodeInviteDecline(_ env: InviteDecline) -> String? {
        guard let data = try? JSONEncoder().encode(env) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Decode helpers

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

    public static func decodeInviteDecline(_ json: String) -> InviteDecline? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(InviteDecline.self, from: data)
    }
}
