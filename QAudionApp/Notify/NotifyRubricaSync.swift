import Foundation
import ImageIO
import UniformTypeIdentifiers
import QAudionEngine

/// Keeps the notification extension's list of names, avatars and mute flags (`NotifyRubrica`) in step with the app.
///
/// The list is rebuilt from the contacts, the conversations and the group registry a moment after any of them
/// changes (contacts and avatars: `.contactsDidChange`; mute flags and group names: explicit calls), written
/// atomically into the notify App Group container, bounded in size, and removed on logout or wipe. Avatars are
/// JPEGs of at most 256 pixels next to it.
@MainActor
final class NotifyRubricaSync {

    static let shared = NotifyRubricaSync()

    private var pending: Task<Void, Never>?
    private let debounce: UInt64 = 1_500_000_000

    private init() {}

    /// Schedules a rebuild; several calls in a row make one.
    func schedule() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.debounce ?? 0)
            guard !Task.isCancelled else { return }
            await self?.rebuild()
        }
    }

    /// Removes the list and the avatars (logout, wipe, account change).
    func clear() {
        pending?.cancel()
        pending = nil
        if let directory = NotifyRubricaFiles.defaultDirectory() { NotifyRubricaFiles.clear(in: directory) }
    }

    private func rebuild() async {
        guard let directory = NotifyRubricaFiles.defaultDirectory() else { return }
        let groupNames: [String: String] = Dictionary(
            GroupRegistry.shared.entries.map { (NotifyRubrica.groupKey($0.id), $0.name) },
            uniquingKeysWith: { first, _ in first })
        await Task.detached(priority: .utility) {
            Self.write(directory: directory, groupNames: groupNames)
        }.value
    }

    // MARK: - Building

    nonisolated private static func write(directory: URL, groupNames: [String: String]) {
        let contacts = ContactsStore().load()
        let conversations = ConversationStore().loadConversations()   // most recent first
        let contactsByKey = Dictionary(
            contacts.map { (NotifyRubrica.personKey($0.userId), $0) }, uniquingKeysWith: { first, _ in first })

        var people: [(id: String, person: NotifyRubrica.Person)] = []
        var seen = Set<String>()
        func add(userId: String, name: String, avatarSource: URL?, muted: Bool) {
            let key = NotifyRubrica.personKey(userId)
            guard seen.insert(key).inserted else { return }
            let usable = DisplayName.isPlaceholderName(name) ? "" : name
            var avatarName: String?
            if !usable.isEmpty, let source = avatarSource {
                let candidate = NotifyRubricaFiles.avatarFileName(for: userId)
                if prepareAvatar(from: source, name: candidate, in: directory) { avatarName = candidate }
            }
            people.append((userId, NotifyRubrica.Person(name: usable, avatar: avatarName, muted: muted)))
        }
        var groups: [(id: String, group: NotifyRubrica.Group)] = []
        for conversation in conversations {
            if conversation.kind == .group {
                let key = NotifyRubrica.groupKey(conversation.peerUserId)
                let name = groupNames[key] ?? conversation.peerDisplayName
                groups.append((conversation.peerUserId,
                               NotifyRubrica.Group(name: DisplayName.looksLikeUUID(name) ? "" : name,
                                                   muted: conversation.muted)))
            } else {
                let contact = contactsByKey[NotifyRubrica.personKey(conversation.peerUserId)]
                add(userId: conversation.peerUserId,
                    name: contact?.displayName ?? conversation.peerDisplayName,
                    avatarSource: contact?.avatarUrl, muted: conversation.muted)
            }
        }
        for contact in contacts {
            add(userId: contact.userId, name: contact.displayName, avatarSource: contact.avatarUrl, muted: false)
        }
        // Groups known to the registry but without a conversation yet.
        let known = Set(groups.map { NotifyRubrica.groupKey($0.id) })
        for (key, name) in groupNames.sorted(by: { $0.key < $1.key }) where !known.contains(key) {
            groups.append((key, NotifyRubrica.Group(name: DisplayName.looksLikeUUID(name) ? "" : name, muted: false)))
        }

        let rubrica = NotifyRubrica.build(people: people, groups: groups)
        guard NotifyRubricaFiles.write(rubrica, to: directory) else { return }
        NotifyRubricaFiles.pruneAvatars(keeping: rubrica.avatarFiles, in: directory)
    }

    // MARK: - Avatars

    /// Writes a JPEG of at most 256 pixels for the contact avatar at `source`, unless the stored one is newer.
    nonisolated private static func prepareAvatar(from source: URL, name: String, in directory: URL) -> Bool {
        guard source.isFileURL, let target = NotifyRubricaFiles.avatarURL(name, in: directory) else { return false }
        let fm = FileManager.default
        let sourceDate = (try? fm.attributesOfItem(atPath: source.path)[.modificationDate]) as? Date
        let targetDate = (try? fm.attributesOfItem(atPath: target.path)[.modificationDate]) as? Date
        if let sourceDate, let targetDate, targetDate >= sourceDate { return true }
        guard let jpeg = scaledJPEG(from: source, maxPixels: NotifyRubricaFiles.avatarMaxPixels) else { return false }
        return NotifyRubricaFiles.writeAvatar(jpeg, name: name, in: directory)
    }

    nonisolated static func scaledJPEG(from source: URL, maxPixels: Int, quality: Double = 0.7) -> Data? {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
