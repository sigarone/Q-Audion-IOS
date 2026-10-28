import Foundation

/// Data Protection classes for the files the app writes.
///
/// The app target declares `NSFileProtectionComplete` as its default class, so a file created without an explicit class
/// cannot be opened while the device is locked. Everything the app (or the system on its behalf) has to read or write
/// while the phone is locked after the first unlock -- an incoming call, a push, a background task, a notification
/// sound -- therefore names its class here, on the file and on the folder that receives new files.
///
/// `lockedAccess` is `completeUntilFirstUserAuthentication`: protected until the first unlock after boot, readable and
/// writable afterwards even while the screen is locked.
public enum FileProtection {

    /// The class for anything needed while the device is locked (after the first unlock).
    public static let lockedAccess: FileProtectionType = .completeUntilFirstUserAuthentication

    /// `Data.write` options that create the (temporary and final) file with `lockedAccess`.
    public static var atomicWriteOptions: Data.WritingOptions {
        [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
    }

    /// Same, for a plain (non-atomic) write.
    public static var plainWriteOptions: Data.WritingOptions {
        [.completeFileProtectionUntilFirstUserAuthentication]
    }

    /// Attributes for `FileManager.createFile` / `createDirectory`.
    public static var lockedAccessAttributes: [FileAttributeKey: Any] {
        [.protectionKey: lockedAccess]
    }

    /// Sets the class of an existing file or folder. False when it does not exist or the platform refuses.
    @discardableResult
    public static func apply(to url: URL, type: FileProtectionType = lockedAccess) -> Bool {
        // Checked explicitly: some hosts (the simulator) accept the attribute on a path that does not exist.
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return (try? FileManager.default.setAttributes([.protectionKey: type], ofItemAtPath: url.path)) != nil
    }

    /// Creates the folder if needed and sets its class (best effort: a platform without Data Protection, such as the
    /// macOS test host, ignores it), so files created inside it later start with that class.
    /// Returns whether the folder exists afterwards.
    @discardableResult
    public static func prepareDirectory(_ url: URL, type: FileProtectionType = lockedAccess) -> Bool {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.protectionKey: type])
            } catch {
                do { try fm.createDirectory(at: url, withIntermediateDirectories: true) } catch { return false }
            }
        }
        apply(to: url, type: type)
        return true
    }

    /// A SQLite database and the sidecar files it may create next to it.
    public static func applyToDatabaseFiles(atPath path: String, type: FileProtectionType = lockedAccess) {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let candidate = URL(fileURLWithPath: path + suffix)
            if FileManager.default.fileExists(atPath: candidate.path) { apply(to: candidate, type: type) }
        }
    }

    /// Folders (under `Caches`) that receive files while the phone may be locked: received attachments, voice notes,
    /// file transfer v2 downloads and prepared copies, contact photos.
    public static let lockedCachesSubfolders = ["files_v2", "file_attachments", "voicenotes", "images", "qaudion-contact-photos"]
    /// Folders (under `Application Support`) that receive files while the phone may be locked: avatars.
    public static let lockedApplicationSupportSubfolders = ["qaudion/avatars"]

    /// Names the class of exactly the folders that receive files while the phone is locked (after the first unlock):
    /// `Library/Preferences` (UserDefaults is read during a VoIP wake with the phone locked; the class is also set on the plist files already there),
    /// `Library/Sounds` (the system reads notification sounds and ringtones there), the listed subfolders of `Caches` and
    /// `Application Support`, and the given App Group containers. Every other folder (`Documents`, `tmp`, the
    /// roots of `Caches` and `Application Support`, the other App Group containers) keeps the app's default class.
    /// Call once, as early as possible at launch.
    public static func prepareAppContainer(groupIdentifiers: [String] = []) {
        let fm = FileManager.default
        var folders: [URL] = []
        if let library = fm.urls(for: .libraryDirectory, in: .userDomainMask).first {
            folders.append(library.appendingPathComponent("Sounds", isDirectory: true))
            let preferences = library.appendingPathComponent("Preferences", isDirectory: true)
            folders.append(preferences)
            // Plist files that already exist keep their class until rewritten: set it on them too.
            let existing = (try? fm.contentsOfDirectory(at: preferences, includingPropertiesForKeys: nil)) ?? []
            for file in existing where file.pathExtension == "plist" { apply(to: file) }
        }
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            folders += lockedCachesSubfolders.map { caches.appendingPathComponent($0, isDirectory: true) }
        }
        if let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            folders += lockedApplicationSupportSubfolders.map { support.appendingPathComponent($0, isDirectory: true) }
        }
        for group in groupIdentifiers {
            if let url = fm.containerURL(forSecurityApplicationGroupIdentifier: group) { folders.append(url) }
        }
        for folder in folders { prepareDirectory(folder) }
    }
}
