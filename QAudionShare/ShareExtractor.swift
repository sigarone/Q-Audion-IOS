import Foundation
import UniformTypeIdentifiers

/// Copies what another app shares into a queue entry. Runs inside the share extension, which has little memory: files are
/// copied from disk to disk (never loaded into memory) and only text and links are read as values.
final class ShareExtractor: @unchecked Sendable {

    enum Failure: Error {
        case nothingShareable
        case tooLarge
        case copyFailed
    }

    private let store: ShareQueueStore
    private var takenNames = Set<String>()
    private var totalBytes: Int64 = 0

    init(store: ShareQueueStore) { self.store = store }

    /// Copies every shareable attachment of `providers` into `folder` and returns the manifest items.
    func extract(from providers: [NSItemProvider], into folder: URL) async throws -> [ShareItem] {
        var items: [ShareItem] = []
        for provider in providers {
            if items.count >= ShareLimits.maxItems { break }
            if let item = try await extractOne(provider, into: folder) { items.append(item) }
        }
        guard !items.isEmpty else { throw Failure.nothingShareable }
        return items
    }

    private func extractOne(_ provider: NSItemProvider, into folder: URL) async throws -> ShareItem? {
        let identifiers = provider.registeredTypeIdentifiers
        // A picture or a movie is a file, whatever else the provider also offers (a link to it, its name).
        if let kind = ShareRules.fileKind(forTypeIdentifiers: identifiers), kind == .image || kind == .video,
           let identifier = identifiers.first(where: { id in
               guard let t = UTType(id) else { return false }
               return kind == .image ? t.conforms(to: .image) : (t.conforms(to: .movie) || t.conforms(to: .video))
           }) {
            return try await copyFile(provider, identifier: identifier, kind: kind, into: folder)
        }
        // A file of the Files app arrives as a file URL.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return try await copyFileURL(provider, into: folder)
        }
        // A web link.
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = try await loadURL(provider), !url.isFileURL {
                return ShareItem(kind: .url, text: ShareRules.clippedText(url.absoluteString))
            }
        }
        // Text.
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = try await loadText(provider), !text.isEmpty {
                let clipped = ShareRules.clippedText(text)
                return ShareItem(kind: ShareRules.isWebLink(clipped) ? .url : .text, text: clipped)
            }
        }
        // Any other data is a file.
        if let identifier = identifiers.first(where: { id in
            guard let t = UTType(id) else { return false }
            return t.conforms(to: .data) || t.conforms(to: .content)
        }) {
            return try await copyFile(provider, identifier: identifier, kind: .file, into: folder)
        }
        return nil
    }

    // MARK: - Files

    private func copyFile(_ provider: NSItemProvider, identifier: String, kind: ShareItemKind, into folder: URL) async throws -> ShareItem {
        let suggested = provider.suggestedName
        let ext = UTType(identifier)?.preferredFilenameExtension
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? Failure.copyFailed)
                    return
                }
                // The file at `url` is deleted when this closure returns: it is copied here.
                do {
                    let item = try self.copy(from: url, suggestedName: suggested, fallbackExtension: ext, kind: kind, into: folder)
                    continuation.resume(returning: item)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func copyFileURL(_ provider: NSItemProvider, into folder: URL) async throws -> ShareItem? {
        guard let url = try await loadURL(provider), url.isFileURL else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let kind = ShareRules.fileKind(forTypeIdentifiers: [UTType(filenameExtension: url.pathExtension)?.identifier ?? ""]) ?? .file
        return try copy(from: url, suggestedName: nil, fallbackExtension: nil, kind: kind, into: folder)
    }

    private func copy(from source: URL, suggestedName: String?, fallbackExtension: String?, kind: ShareItemKind,
                      into folder: URL) throws -> ShareItem {
        // A size that cannot be read, or a link instead of a file, is refused.
        guard let values = try? source.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]),
              values.isSymbolicLink != true, let fileSize = values.fileSize else { throw Failure.copyFailed }
        let size = Int64(fileSize)
        guard size <= ShareLimits.maxItemBytes, totalBytes + size <= ShareLimits.maxShareBytes else { throw Failure.tooLarge }
        totalBytes += size
        var name = ShareRules.sanitizedFileName(source.lastPathComponent, fallback: "")
        if name.isEmpty, let suggestedName { name = ShareRules.sanitizedFileName(suggestedName, fallback: "") }
        if name.isEmpty { name = "file" }
        if (name as NSString).pathExtension.isEmpty, let fallbackExtension { name += "." + fallbackExtension }
        name = unique(name)
        do {
            try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(name))
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: folder.appendingPathComponent(name).path)
        } catch {
            throw Failure.copyFailed
        }
        return ShareItem(kind: kind, fileName: name, displayName: name, byteCount: size)
    }

    private func unique(_ name: String) -> String {
        var candidate = name
        var n = 2
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        while takenNames.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            n += 1
        }
        takenNames.insert(candidate.lowercased())
        return candidate
    }

    // MARK: - Values

    private func loadURL(_ provider: NSItemProvider) async throws -> URL? {
        let value = try await load(provider, identifier: provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                                    ? UTType.fileURL.identifier : UTType.url.identifier)
        if let url = value as? URL { return url }
        if let data = value as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        if let string = value as? String { return URL(string: string) }
        return nil
    }

    private func loadText(_ provider: NSItemProvider) async throws -> String? {
        let value = try await load(provider, identifier: UTType.plainText.identifier)
        if let string = value as? String { return string }
        if let data = value as? Data { return String(data: data, encoding: .utf8) }
        return nil
    }

    private func load(_ provider: NSItemProvider, identifier: String) async throws -> NSSecureCoding? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: identifier, options: nil) { value, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: value) }
            }
        }
    }
}
