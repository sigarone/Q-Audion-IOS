import Foundation

/// Who may download a file the sender uploads: one account (a 1:1 chat, or an avatar sent to one contact) or the members of one
/// group (WIRE_SPEC 12.11: ONE token with group scope, checked against the group's membership at download time, instead of a
/// map of one token per member that would not fit the 8 KiB descriptor for a large group).
///
/// The scope decides the token request of the create call (`recipient_user_id` or `group_id`, exactly one of them). A group is
/// named on the wire by its DASHED lowercase UUID, while the app keys groups on the 32-character hex form: `forGroup` accepts
/// either and writes the one the server expects, or refuses an identifier that is neither (a send is never made with a token
/// the server would refuse).
public enum FileV2Audience: Sendable, Equatable {
    /// One account (its server user id, as the server issued it).
    case recipient(String)
    /// A group, by its lowercase dashed UUID.
    case group(String)

    /// The group `raw` names, in the form of the token request: lowercase, hyphens at 8, 13, 18 and 23. Accepts the dashed form
    /// in any case and the 32-character hex form; anything else (wrong length, a character that is not hex, a misplaced
    /// hyphen) is `nil`.
    public static func forGroup(_ raw: String) -> FileV2Audience? {
        guard let dashed = dashedGroupID(raw) else { return nil }
        return .group(dashed)
    }

    /// `nil` unless `raw` is a UUID in the dashed form (any case) or in the 32-hex form.
    static func dashedGroupID(_ raw: String) -> String? {
        let lower = Array(raw.lowercased().utf8)
        func isHex(_ byte: UInt8) -> Bool { (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66) }
        var digits: [UInt8] = []
        if lower.count == 36 {
            for (index, byte) in lower.enumerated() {
                if index == 8 || index == 13 || index == 18 || index == 23 {
                    guard byte == UInt8(ascii: "-") else { return nil }
                } else {
                    guard isHex(byte) else { return nil }
                    digits.append(byte)
                }
            }
        } else if lower.count == 32 {
            guard lower.allSatisfy(isHex) else { return nil }
            digits = lower
        } else {
            return nil
        }
        var out: [UInt8] = []
        out.reserveCapacity(36)
        for (index, byte) in digits.enumerated() {
            if index == 8 || index == 12 || index == 16 || index == 20 { out.append(UInt8(ascii: "-")) }
            out.append(byte)
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// The token the create call asks for. `maxUses` is the budget of each presenting account (a group token gives every
    /// member a budget of their own).
    public func tokenRequest(maxUses: Int) -> FileV2TokenRequest {
        switch self {
        case .recipient(let user): return .forRecipient(user, maxUses: maxUses)
        case .group(let group): return .forGroup(group, maxUses: maxUses)
        }
    }

    /// `true` for a group (the descriptor then travels in the group payload and one token serves every member).
    public var isGroup: Bool {
        if case .group = self { return true }
        return false
    }

    /// A recipient with an identifier, or a group in the canonical lowercase dashed form (what `forGroup` returns). The sender
    /// refuses anything else before it creates an object.
    public var isWellFormed: Bool {
        switch self {
        case .recipient(let user): return !user.isEmpty
        case .group(let group): return Self.dashedGroupID(group) == group
        }
    }
}
