import Foundation

/// Decisions of the Siri Intents extension that do not need any Intents type, so they can be unit tested without
/// SiriKit. This file is compiled into BOTH the app and the QAudionIntents extension (see `project.yml`), next to
/// `SiriMessageBridgeStore.swift`, and links nothing but Foundation.
///
/// The glue in `QAudionIntents/IntentHandler.swift` turns an `INPerson` into `SiriPersonFacts`, asks this policy, and
/// turns the answer back into the matching SiriKit resolution result.

// MARK: - People

/// What the extension reads from a person Siri hands it. No Intents types.
struct SiriPersonFacts: Equatable {
    var displayName: String
    /// `INPersonHandle.value`: a phone number or an e-mail address from the system Contacts, or a Q-Audion user id
    /// for a person this app donated itself.
    var handle: String?
    /// `INPerson.customIdentifier`: the Q-Audion user id of a person this app donated itself.
    var customIdentifier: String?

    /// A person can be tied to somebody through a handle or an identifier. A bare name is something Siri heard, not
    /// somebody Siri found; the app matches it by display name.
    var hasIdentity: Bool {
        SiriIntentPolicy.nonBlank(handle) != nil || SiriIntentPolicy.nonBlank(customIdentifier) != nil
    }
}

/// One conversation a request to mark messages as read names: the peer, and the newest message of that peer it covers
/// (whole seconds of its `sentAt`).
struct SiriReadTarget: Equatable {
    var peerUserId: String
    var upToSentAt: Int
}

enum SiriPersonVerdict: Equatable {
    /// Exactly one candidate can be tied to somebody; the value is its index in the candidate list.
    case resolved(Int)
    /// Several candidates can be tied to somebody: Siri has to ask which one.
    case ambiguous([Int])
    /// No candidate can be tied to anybody: all there is, is a name Siri heard.
    case unresolved
}

enum SiriIntentPolicy {

    /// `value` trimmed, or nil when it is nil or only whitespace.
    static func nonBlank(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// `candidates` are the Siri matches of the person when Siri found some, else the person itself.
    static func verdict(candidates: [SiriPersonFacts]) -> SiriPersonVerdict {
        let usable: [Int] = candidates.indices.filter { candidates[$0].hasIdentity }
        switch usable.count {
        case 0: return .unresolved
        case 1: return .resolved(usable[0])
        default: return .ambiguous(usable)
        }
    }

    // MARK: - Conversations

    /// The conversation a CarPlay row (or a donated interaction) names, if any. The app writes the peer's user id as
    /// the conversation identifier.
    static func conversationTarget(_ identifier: String?) -> String? {
        nonBlank(identifier)
    }

    /// The first usable conversation identifier of a search.
    static func conversationTargets(_ identifiers: [String]?) -> [String] {
        (identifiers ?? []).compactMap { nonBlank($0) }
    }

    // MARK: - Message identifiers

    /// Identifier of a message as the search handler gives it to Siri, and as Siri gives it back to
    /// `INSetMessageAttributeIntent`. The peer id comes first; the separator is the last `#`.
    static func messageIdentifier(peerUserId: String, sentAt: Date) -> String {
        "\(peerUserId)#\(Int(sentAt.timeIntervalSince1970))"
    }

    /// A message identifier made by `messageIdentifier`, taken apart; nil for anything else.
    static func parse(messageIdentifier identifier: String) -> (peerUserId: String, sentAt: Int)? {
        guard let cut = identifier.lastIndex(of: "#") else { return nil }
        let peer = String(identifier[identifier.startIndex..<cut])
        let stamp = identifier[identifier.index(after: cut)...]
        guard !peer.isEmpty, !stamp.isEmpty, stamp.allSatisfy({ $0.isASCII && $0.isNumber }),
              let sentAt = Int(stamp) else { return nil }
        return (peer, sentAt)
    }

    /// The peer user id inside a message identifier made by `messageIdentifier`, nil for anything else.
    static func peerUserId(inMessageIdentifier identifier: String) -> String? {
        parse(messageIdentifier: identifier)?.peerUserId
    }

    /// What a list of message identifiers asks to mark as read: each peer once, in first-seen order, with the newest
    /// message of that peer in the list. Identifiers that are not ours are dropped.
    static func readTargets(inMessageIdentifiers identifiers: [String]?) -> [SiriReadTarget] {
        var order: [String] = []
        var newest: [String: Int] = [:]
        for identifier in identifiers ?? [] {
            guard let parsed = parse(messageIdentifier: identifier) else { continue }
            if let known = newest[parsed.peerUserId] {
                newest[parsed.peerUserId] = max(known, parsed.sentAt)
            } else {
                order.append(parsed.peerUserId)
                newest[parsed.peerUserId] = parsed.sentAt
            }
        }
        return order.map { SiriReadTarget(peerUserId: $0, upToSentAt: newest[$0] ?? 0) }
    }

    /// The queued read marks of one peer folded into one, the newest bound winning. First-seen order.
    static func mergedReadMarks(_ marks: [SiriMessageBridgeStore.ReadMark]) -> [SiriMessageBridgeStore.ReadMark] {
        var order: [String] = []
        var newest: [String: Int] = [:]
        for mark in marks {
            if let known = newest[mark.peerUserId] {
                newest[mark.peerUserId] = max(known, mark.upToSentAt)
            } else {
                order.append(mark.peerUserId)
                newest[mark.peerUserId] = mark.upToSentAt
            }
        }
        return order.map { SiriMessageBridgeStore.ReadMark(peerUserId: $0, upToSentAt: newest[$0] ?? 0) }
    }

    // MARK: - Reading the cache

    /// Which of the cached incoming messages are unread: the last `unreadCount` incoming ones of a conversation
    /// (outgoing ones are never unread). `isIncoming` is in the order of the messages, oldest first.
    static func unreadFlags(isIncoming: [Bool], unreadCount: Int) -> [Bool] {
        var remaining = max(0, unreadCount)
        var flags = [Bool](repeating: false, count: isIncoming.count)
        var index = isIncoming.count - 1
        while index >= 0, remaining > 0 {
            if isIncoming[index] {
                flags[index] = true
                remaining -= 1
            }
            index -= 1
        }
        return flags
    }

    /// The unread count a conversation has left after the messages up to `upToSentAt` were read. The messages are
    /// oldest first; the last `unreadCount` incoming ones are the unread ones, and only those sent after the bound stay.
    static func unreadCountAfterRead(isIncoming: [Bool], sentAt: [Int], unreadCount: Int, upToSentAt: Int) -> Int {
        let flags = unreadFlags(isIncoming: isIncoming, unreadCount: unreadCount)
        var left = 0
        for (flag, sent) in zip(flags, sentAt) where flag && sent > upToSentAt { left += 1 }
        return left
    }

    /// The cached messages a search asks for. A conversation identifier or a message identifier names the messages
    /// exactly and wins over a spoken name; the name is a case-insensitive match on the peer's display name.
    static func matchMessages(
        _ cached: [SiriMessageBridgeStore.CachedMessage],
        conversationIdentifiers: [String]?,
        messageIdentifiers: [String]?,
        spokenName: String?,
        unreadOnly: Bool
    ) -> [SiriMessageBridgeStore.CachedMessage] {
        let conversations = Set(conversationTargets(conversationIdentifiers))
        let messageIds = Set((messageIdentifiers ?? []).compactMap { nonBlank($0) })
        var out = cached
        if !messageIds.isEmpty {
            out = out.filter { messageIds.contains(messageIdentifier(peerUserId: $0.peerUserId, sentAt: $0.sentAt)) }
        } else if !conversations.isEmpty {
            out = out.filter { conversations.contains($0.peerUserId) }
        } else if let name = nonBlank(spokenName) {
            out = out.filter { $0.peerDisplayName.localizedCaseInsensitiveCompare(name) == .orderedSame }
        }
        if unreadOnly {
            out = out.filter { $0.isUnread == true }
        }
        return out
    }
}
