import Foundation
import QAudionEngine

/// The upload progress of the group rows being sent, in memory only (the same role `ChatContainer.uploadProgress` has in a 1:1 chat):
/// the group bubble shows it in the place of the delivery tick while the file uploads.
@MainActor
final class GroupUploadProgress: ObservableObject {
    static let shared = GroupUploadProgress()

    @Published private(set) var values: [String: Double] = [:]

    func set(_ rowId: String, done: Int64, total: Int64) {
        guard total > 0 else { return }
        values[rowId] = min(1, max(0, Double(done) / Double(total)))
    }

    func clear(_ rowId: String) {
        values.removeValue(forKey: rowId)
    }
}

/// Sends a file (a document, an image, a video) into a group in the file transfer v2 format (WIRE_SPEC section 12): the file is
/// uploaded once, with ONE download token that has group scope (the server checks the membership at the moment of the download), and
/// the descriptor travels in the group payload 0xE4 with `msg_type` 1. The same code serves the group chat and the chat panel of a
/// group call.
///
/// The row of the sender appears at once (`GroupMessageStore`, keyed by the client message id, so the server's echo binds to it),
/// shows the upload progress, and carries the descriptor from the moment it exists. A file that cannot be sent leaves the row failed
/// with a retry: a descriptor that was built is sent again as it is (the upload is still on the server), an upload that failed starts
/// again from the copy the row keeps.
@MainActor
enum GroupFileV2Send {

    /// Where the file goes: the group in the forms the app uses (the hex form keys the stores, the dashed form is the server's) and
    /// its current roster.
    struct Target {
        let groupHex: String
        /// The group on the wire: the lowercase dashed UUID.
        let groupId: String
        let memberIds: [String]
        let selfId: String
    }

    // MARK: What the screens call

    /// Starts the send of whatever the user chose in the pre-send dialog. A failure is told with `onFailure` (one sentence, already
    /// localised); the rest of a batch goes on.
    static func perform(
        _ pending: PendingAttachmentSend,
        target: Target,
        overrideSeconds: Int?,
        exportBlocked: Bool,
        appState: AppState,
        onFailure: @escaping @MainActor (String) -> Void
    ) {
        switch pending {
        case .image(let data):
            sendImages([data], target: target, overrideSeconds: overrideSeconds, exportBlocked: exportBlocked,
                       appState: appState, onFailure: onFailure)
        case .multiImage(let items):
            sendImages(items, target: target, overrideSeconds: overrideSeconds, exportBlocked: exportBlocked,
                       appState: appState, onFailure: onFailure)
        case .media(let images, let videos):
            sendImages(images, target: target, overrideSeconds: overrideSeconds, exportBlocked: exportBlocked,
                       appState: appState, onFailure: onFailure)
            if !videos.isEmpty {
                Task {
                    await sendVideos(videos, target: target, overrideSeconds: overrideSeconds, exportBlocked: exportBlocked,
                                     appState: appState, onFailure: onFailure)
                }
            }
        case .file(let url):
            if let failure = sendDocument(url, target: target, overrideSeconds: overrideSeconds, exportBlocked: exportBlocked,
                                          appState: appState) {
                onFailure(FileV2FailureText.message(for: failure))
            }
        case .voiceNote(let recording):
            // A group chat has no voice-note recorder; kept so the shared dialog's choices are all handled.
            if let failure = sendVoice(recording, target: target, overrideSeconds: overrideSeconds, exportBlocked: exportBlocked,
                                       appState: appState) {
                onFailure(FileV2FailureText.message(for: failure))
            }
        }
    }

    /// "Riprova" on a failed row of the sender. Returns `false` when there is nothing to send again (a document whose file the app no
    /// longer holds): the caller tells the user to attach it again.
    @discardableResult
    static func retry(row: GroupMessageStore.Stored, target: Target, appState: AppState,
                      onFailure: @escaping @MainActor (String) -> Void) -> Bool {
        let store = GroupMessageStore.shared
        // The descriptor exists: the upload is on the server, only the message has to go again.
        if let body = row.descriptorJson, FileV2Message.hasFileMessagePrefix(body) {
            store.clearSendFailed(groupHex: target.groupHex, clientMsgId: row.id)
            if !seal(body, target: target, clientMsgId: row.id) {
                store.markSendFailed(groupHex: target.groupHex, clientMsgId: row.id)
                onFailure(FileV2FailureText.message(for: FileV2Failure.transfer(.announceNotSent)))
            }
            return true
        }
        // The upload failed: start it again from the copy the row keeps.
        guard let path = row.mediaLocalPath, FileManager.default.fileExists(atPath: path) else { return false }
        store.clearSendFailed(groupHex: target.groupHex, clientMsgId: row.id)
        let url = URL(fileURLWithPath: path)
        let kind = row.attachmentKind ?? "image"
        let rowId = row.id
        Task {
            let prepared: FileV2MediaPreparer.Prepared
            do {
                if kind == "video" {
                    prepared = try await FileV2MediaPreparer.describeVideo(fileURL: url, key: rowId)
                } else {
                    prepared = try FileV2MediaPreparer.describeImage(fileURL: url, key: rowId)
                }
            } catch {
                store.markSendFailed(groupHex: target.groupHex, clientMsgId: rowId)
                onFailure(FileV2FailureText.message(for: FileV2Failure(.unreadable)))
                return
            }
            upload(prepared, target: target, rowId: rowId, exportBlocked: row.exportBlocked ?? false, ex: nil, appState: appState,
                   scoped: nil, onFailure: onFailure)
        }
        return true
    }

    // MARK: The kinds

    private static func sendImages(_ items: [Data], target: Target, overrideSeconds: Int?, exportBlocked: Bool,
                                   appState: AppState, onFailure: @escaping @MainActor (String) -> Void) {
        for data in items {
            let rowId = UUID().uuidString
            let prepared: FileV2MediaPreparer.Prepared
            do {
                prepared = try FileV2MediaPreparer.prepareImage(rawData: data, key: rowId)
            } catch {
                onFailure(FileV2FailureText.imageMessage)
                continue
            }
            if let failure = start(prepared, target: target, rowId: rowId, overrideSeconds: overrideSeconds,
                                   exportBlocked: exportBlocked, keepsLocalCopy: true, appState: appState, scoped: nil,
                                   onFailure: onFailure) {
                onFailure(FileV2FailureText.message(for: failure))
            }
        }
    }

    private static func sendVideos(_ urls: [URL], target: Target, overrideSeconds: Int?, exportBlocked: Bool,
                                   appState: AppState, onFailure: @escaping @MainActor (String) -> Void) async {
        for url in urls {
            if case .failure(let failure) = FileV2AppServices.sendableSize(of: url) {
                try? FileManager.default.removeItem(at: url)
                onFailure(FileV2FailureText.message(for: failure))
                continue
            }
            // A video is fetched on a tap, so it cannot be "view once" (refused before the file is moved).
            if AttachmentTimerResolver.resolve(overrideSeconds: overrideSeconds, conversationDefault: nil) == -1 {
                try? FileManager.default.removeItem(at: url)
                onFailure(FileV2FailureText.message(for: FileV2Failure(.viewOnceUnsupported)))
                continue
            }
            let rowId = UUID().uuidString
            let prepared: FileV2MediaPreparer.Prepared
            do {
                prepared = try await FileV2MediaPreparer.prepareVideo(sourceURL: url, key: rowId)
            } catch {
                onFailure(FileV2FailureText.message(for: FileV2Failure(.unreadable)))
                continue
            }
            if let failure = start(prepared, target: target, rowId: rowId, overrideSeconds: overrideSeconds,
                                   exportBlocked: exportBlocked, keepsLocalCopy: true, appState: appState, scoped: nil,
                                   onFailure: onFailure) {
                try? FileManager.default.removeItem(
                    at: FileV2LocalFiles.directory(base: FileV2DownloadCenter.cachesBase, rowKey: rowId))
                onFailure(FileV2FailureText.message(for: failure))
            }
        }
    }

    private static func sendDocument(_ url: URL, target: Target, overrideSeconds: Int?, exportBlocked: Bool,
                                     appState: AppState) -> FileV2Failure? {
        // Security-scoped access for files outside the app sandbox, held for the whole send and released when it ends.
        let scoped = url.startAccessingSecurityScopedResource()
        let scopedURL: URL? = scoped ? url : nil
        if case .failure(let failure) = FileV2AppServices.sendableSize(of: url) {
            scopedURL?.stopAccessingSecurityScopedResource()
            return failure
        }
        let prepared = FileV2MediaPreparer.Prepared(
            kind: .file, sourceURL: url, name: url.lastPathComponent, mimeType: FileV2AppServices.mimeType(for: url), media: nil,
            preview: nil, thumbnailURL: nil, durationMs: nil)
        return start(prepared, target: target, rowId: UUID().uuidString, overrideSeconds: overrideSeconds,
                     exportBlocked: exportBlocked, keepsLocalCopy: false, appState: appState, scoped: scopedURL,
                     onFailure: { _ in })
    }

    private static func sendVoice(_ recording: VoiceNoteRecorder.Recording, target: Target, overrideSeconds: Int?,
                                  exportBlocked: Bool, appState: AppState) -> FileV2Failure? {
        let rowId = UUID().uuidString
        let prepared: FileV2MediaPreparer.Prepared
        do {
            prepared = try FileV2MediaPreparer.prepareVoice(recording: recording, key: rowId)
        } catch {
            return FileV2Failure(.unreadable)
        }
        try? FileManager.default.removeItem(at: recording.fileURL)
        return start(prepared, target: target, rowId: rowId, overrideSeconds: overrideSeconds, exportBlocked: exportBlocked,
                     keepsLocalCopy: true, appState: appState, scoped: nil, onFailure: { _ in })
    }

    // MARK: One send

    /// Refuses what cannot be sent, shows the row and runs the upload.
    /// - Returns: `nil` when the send started; the failure that says why it did not otherwise.
    private static func start(
        _ prepared: FileV2MediaPreparer.Prepared,
        target: Target,
        rowId: String,
        overrideSeconds: Int?,
        exportBlocked: Bool,
        keepsLocalCopy: Bool,
        appState: AppState,
        scoped: URL?,
        onFailure: @escaping @MainActor (String) -> Void
    ) -> FileV2Failure? {
        // A group has no per-group default timer: the effective value is the choice of the pre-send dialog.
        let effectiveTimer = AttachmentTimerResolver.resolve(overrideSeconds: overrideSeconds, conversationDefault: nil)
        if effectiveTimer == -1 && (prepared.kind == .file || prepared.kind == .video) {
            scoped?.stopAccessingSecurityScopedResource()
            return FileV2Failure(.viewOnceUnsupported)
        }
        guard FileV2Audience.forGroup(target.groupId) != nil, target.memberIds.contains(target.selfId) else {
            scoped?.stopAccessingSecurityScopedResource()
            return FileV2Failure.transfer(.badRequest)
        }
        let now = Date()
        let ephExpiry: Date? = effectiveTimer.flatMap { (seconds: Int) -> Date? in
            seconds > 0 ? now.addingTimeInterval(Double(seconds)) : nil
        }
        let size = fileSize(prepared.sourceURL)
        GroupMessageStore.shared.append(
            groupHex: target.groupHex,
            GroupMessageStore.Stored(
                id: rowId,
                serverMessageId: nil,
                senderId: target.selfId,
                mine: true,
                text: "",
                ts: now,
                attachmentKind: prepared.kind.rawValue,
                mediaMime: prepared.mimeType,
                fileName: prepared.name,
                byteLength: size,
                mediaLocalPath: keepsLocalCopy ? prepared.sourceURL.path : nil,
                descriptorJson: nil,
                expiresAt: ephExpiry,
                isViewOnce: effectiveTimer == -1 ? true : nil,
                exportBlocked: exportBlocked ? true : nil,
                fileV2: true))
        let timerValue: Int64? = effectiveTimer.flatMap { (seconds: Int) -> Int64? in seconds == 0 ? nil : Int64(seconds) }
        upload(prepared, target: target, rowId: rowId, exportBlocked: exportBlocked, ex: timerValue, appState: appState,
               scoped: scoped, onFailure: onFailure)
        return nil
    }

    /// The background run: upload, build the descriptor, seal it into the group payload and ship it.
    private static func upload(
        _ prepared: FileV2MediaPreparer.Prepared,
        target: Target,
        rowId: String,
        exportBlocked: Bool,
        ex: Int64?,
        appState: AppState,
        scoped: URL?,
        onFailure: @escaping @MainActor (String) -> Void
    ) {
        guard let audience = FileV2Audience.forGroup(target.groupId) else {
            scoped?.stopAccessingSecurityScopedResource()
            GroupMessageStore.shared.markSendFailed(groupHex: target.groupHex, clientMsgId: rowId)
            return
        }
        if prepared.thumbnailURL != nil { FileV2DownloadCenter.shared.markThumbnailReady(rowId) }
        let request = FileV2Sender.Request(
            sourceURL: prepared.sourceURL, kind: prepared.kind, name: prepared.name, mimeType: prepared.mimeType,
            audience: audience, media: prepared.media, preview: prepared.preview,
            thumbnail: prepared.thumbnailURL.map { FileV2Sender.Thumbnail(sourceURL: $0) }, ex: ex, xp: exportBlocked ? 0 : nil)
        GroupUploadProgress.shared.set(rowId, done: 0, total: 1)
        Task {
            await BackgroundUploadTask.run(name: "file-v2-upload") {
                let failure = await FileV2OutboundRunner.run(
                    key: rowId, request: request, appState: appState,
                    onProgress: { done, total in GroupUploadProgress.shared.set(rowId, done: done, total: total) },
                    deliver: { body in
                        GroupMessageStore.shared.setDescriptor(groupHex: target.groupHex, id: rowId, descriptorJson: body)
                        guard seal(body, target: target, clientMsgId: rowId) else { throw GroupDeliveryRefused() }
                    })
                scoped?.stopAccessingSecurityScopedResource()
                GroupUploadProgress.shared.clear(rowId)
                if let failure {
                    RTLog.warn("group", "filev2 send failed code=\(failure.code)")
                    GroupMessageStore.shared.markSendFailed(groupHex: target.groupHex, clientMsgId: rowId)
                    onFailure(FileV2FailureText.message(for: failure))
                } else {
                    RTLog.info("group", "filev2 send ok=1")
                }
            }
        }
    }

    private struct GroupDeliveryRefused: Error {}

    /// The size of the file to send, for the row (the engine checked it is a sendable size before the row exists, for a document;
    /// an image, a voice note and a video were just written by the app).
    private static func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: The group payload

    /// Seals the descriptor message into the group payload (the sender-key distribution first, so that the receivers' chains exist
    /// before the ciphertext lands, exactly like the text path) and hands it to the app, which holds the socket, with `msg_type` 1.
    /// `false` when the group session cannot seal it.
    private static func seal(_ body: String, target: Target, clientMsgId: String) -> Bool {
        let pendingInits = GroupChatService.shared.pendingInitsAfterBootstrap(
            groupId: target.groupHex, members: target.memberIds, selfId: target.selfId)
        for item in pendingInits {
            NotificationCenter.default.post(
                name: AppState.groupSenderKeyCtlNotification,
                object: nil,
                userInfo: ["recipient": item.recipientId, "envelopeJson": item.envelopeJson])
        }
        guard let sealed = GroupChatService.shared.encryptForWire(
            plaintext: body, groupId: target.groupHex, members: target.memberIds, selfId: target.selfId) else {
            return false
        }
        NotificationCenter.default.post(
            name: AppState.groupMsgSendNotification,
            object: nil,
            userInfo: [
                "groupId": target.groupId,
                "wire": sealed.wire,
                "clientMsgId": clientMsgId,
                "groupEpoch": Int(sealed.groupEpoch),
                "msgType": GroupAttachmentEnvelope.msgTypeAttachment,
            ])
        return true
    }
}
