import Foundation

/// W102 — utility to wipe the chat-attachment caches that
/// `ChatVoiceNoteSender` (W79), `ChatVoiceNoteReceiver` (W80), and
/// `ChatContainer.persistOutboundImage` (W82) write to.
///
/// Folders cleaned:
///   - `Library/Caches/voicenotes/` — decrypted M4A voice notes.
///   - `Library/Caches/images/`     — decrypted JPEG images.
///
/// The qfile markers in the chat history stay intact, so the user can
/// still tap a bubble to re-fetch + decrypt from the server. We only
/// reclaim the on-disk plaintext copies.
enum AttachmentCacheCleaner {

    /// Clear both attachment caches. Returns total bytes freed (so the
    /// settings screen can show "Cache liberata: 12.4 MB").
    /// Best-effort — directory enumeration / removal failures are
    /// logged but don't surface as errors.
    @discardableResult
    static func clearAllCaches() -> UInt64 {
        var freed: UInt64 = 0
        for sub in ["voicenotes", "images"] {
            freed &+= clearSubdir(sub)
        }
        return freed
    }

    /// W113: report current cache sizes without deleting. Lets the
    /// settings screen show "Voice notes: 4.2 MB · Immagini: 12.8 MB"
    /// before asking the user whether to clear.
    static func cacheSizes() -> (voiceNotes: UInt64, images: UInt64) {
        return (sizeOfSubdir("voicenotes"), sizeOfSubdir("images"))
    }

    private static func sizeOfSubdir(_ name: String) -> UInt64 {
        let fm = FileManager.default
        guard let cachesBase = try? fm.url(
            for: .cachesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        ) else { return 0 }
        let dir = cachesBase.appendingPathComponent(name, isDirectory: true)
        guard fm.fileExists(atPath: dir.path) else { return 0 }
        var bytes: UInt64 = 0
        if let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in enumerator {
                if let s = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                    bytes &+= UInt64(s)
                }
            }
        }
        return bytes
    }

    private static func clearSubdir(_ name: String) -> UInt64 {
        let fm = FileManager.default
        guard let cachesBase = try? fm.url(
            for: .cachesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        ) else { return 0 }
        let dir = cachesBase.appendingPathComponent(name, isDirectory: true)
        guard fm.fileExists(atPath: dir.path) else { return 0 }
        // Tally before delete so the caller can show a "MB freed" value.
        var bytes: UInt64 = 0
        if let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in enumerator {
                if let s = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                    bytes &+= UInt64(s)
                }
            }
        }
        do {
            // removeItem on the directory + recreate so future writes
            // still find a directory present (avoid first-write failure).
            try fm.removeItem(at: dir)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            print("[AttachmentCacheCleaner] failed to clear \(name): \(error)")
        }
        return bytes
    }
}
