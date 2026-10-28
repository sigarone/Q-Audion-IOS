import Foundation
import CryptoKit

/// The small address book the notification extension reads: display names, avatar file names and mute flags for the
/// people and groups the user talks to. It carries no message text and no key material. The app writes it into the
/// notify App Group container (atomically, readable after the first unlock) and keeps it bounded.
///
/// Foundation and CryptoKit only: the notification extension compiles this file directly.
public struct NotifyRubrica: Codable, Equatable, Sendable {

    public struct Person: Codable, Equatable, Sendable {
        public var name: String
        /// File name inside the rubrica folder, or nil.
        public var avatar: String?
        public var muted: Bool

        public init(name: String, avatar: String? = nil, muted: Bool = false) {
            self.name = name
            self.avatar = avatar
            self.muted = muted
        }
    }

    public struct Group: Codable, Equatable, Sendable {
        public var name: String
        public var muted: Bool

        public init(name: String, muted: Bool = false) {
            self.name = name
            self.muted = muted
        }
    }

    public static let maxPeople = 1000
    public static let maxGroups = 300
    public static let maxNameLength = 80
    /// A rubrica file larger than this is ignored.
    public static let maxFileBytes = 512 * 1024

    public var version: Int = 1
    public var people: [String: Person]
    public var groups: [String: Group]

    public init(people: [String: Person] = [:], groups: [String: Group] = [:]) {
        self.people = people
        self.groups = groups
    }

    /// Lookup key of a user id.
    public static func personKey(_ id: String) -> String { id.lowercased() }

    /// Lookup key of a group id: lower case without dashes (the app's group registry uses the bare hex form).
    public static func groupKey(_ id: String) -> String {
        id.lowercased().replacingOccurrences(of: "-", with: "")
    }

    public func person(_ id: String) -> Person? { people[Self.personKey(id)] }
    public func group(_ id: String) -> Group? { groups[Self.groupKey(id)] }

    static func clipped(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(maxNameLength))
    }

    /// Builds a bounded rubrica. The inputs are ordered by importance (most recent first): when there are more than the
    /// limits allow, the tail is dropped. An entry with an empty name is kept only when muted (so the flag still counts).
    public static func build(people: [(id: String, person: Person)], groups: [(id: String, group: Group)]) -> NotifyRubrica {
        var result = NotifyRubrica()
        for entry in people {
            if result.people.count >= maxPeople { break }
            let key = personKey(entry.id)
            guard result.people[key] == nil else { continue }
            var person = entry.person
            person.name = clipped(person.name)
            if person.name.isEmpty && !person.muted { continue }
            result.people[key] = person
        }
        for entry in groups {
            if result.groups.count >= maxGroups { break }
            let key = groupKey(entry.id)
            guard result.groups[key] == nil else { continue }
            var group = entry.group
            group.name = clipped(group.name)
            if group.name.isEmpty && !group.muted { continue }
            result.groups[key] = group
        }
        return result
    }

    /// Avatar file names the rubrica refers to.
    public var avatarFiles: Set<String> {
        Set(people.values.compactMap { $0.avatar })
    }
}

/// Files of the rubrica folder.
public enum NotifyRubricaFiles {

    public static let directoryName = "notify-rubrica"
    public static let fileName = "rubrica.json"
    public static let appGroupID = "group.com.bcrypto.qaudion.notify"
    /// Longest side of a stored avatar, in pixels.
    public static let avatarMaxPixels = 256

    /// The rubrica folder inside the notify App Group container.
    public static func defaultDirectory() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Stable, non-reversible file name for the avatar of a user.
    public static func avatarFileName(for userID: String) -> String {
        let digest = SHA256.hash(data: Data(("avatar|" + NotifyRubrica.personKey(userID)).utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined() + ".jpg"
    }

    private static func isSafeAvatarName(_ name: String) -> Bool {
        name.hasSuffix(".jpg") && !name.contains("/") && !name.contains("..")
    }

    public static func avatarURL(_ name: String, in directory: URL) -> URL? {
        isSafeAvatarName(name) ? directory.appendingPathComponent(name) : nil
    }

    /// Writes the rubrica atomically with the "until first unlock" protection class.
    @discardableResult
    public static func write(_ rubrica: NotifyRubrica, to directory: URL) -> Bool {
        guard FileProtection.prepareDirectory(directory) else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(rubrica), data.count <= NotifyRubrica.maxFileBytes else { return false }
        let target = directory.appendingPathComponent(fileName)
        if let existing = try? Data(contentsOf: target), existing == data { return true }
        return (try? data.write(to: target, options: FileProtection.atomicWriteOptions)) != nil
    }

    public static func read(from directory: URL) -> NotifyRubrica? {
        let url = directory.appendingPathComponent(fileName)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes?[.size] as? Int, size <= NotifyRubrica.maxFileBytes,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(NotifyRubrica.self, from: data)
    }

    @discardableResult
    public static func writeAvatar(_ jpeg: Data, name: String, in directory: URL) -> Bool {
        guard isSafeAvatarName(name), jpeg.count <= 128 * 1024,
              FileProtection.prepareDirectory(directory) else { return false }
        let target = directory.appendingPathComponent(name)
        if let existing = try? Data(contentsOf: target), existing == jpeg { return true }
        return (try? jpeg.write(to: target, options: FileProtection.atomicWriteOptions)) != nil
    }

    /// Removes every avatar file that is not in `keeping`.
    public static func pruneAvatars(keeping: Set<String>, in directory: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasSuffix(".jpg") && !keeping.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Removes the whole folder (logout, wipe).
    public static func clear(in directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }
}
