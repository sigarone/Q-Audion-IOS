import Foundation
import QAudionEngine

/// Downloads, verifies and decrypts the file of a received v2 message (a document, an image, a voice note, a video), in a 1:1 chat
/// or in a group, and keeps what the bubble shows meanwhile (progress, or the failure). In memory only: a download that the app
/// does not finish is started again by the next tap (or, for what is fetched on arrival, the next time the bubble appears), from
/// the descriptor that is still in the row.
///
/// What starts without a tap is the owner's rule (`FileV2AutoDownloadPolicy`): the thumbnail of every row that has one, and the
/// file itself for an image or a voice note up to 25 MiB. A video, a document and anything above 25 MiB wait for the user.
///
/// A finished download is recorded on the row (`onFinished`: the 1:1 message row's `mediaLocalPath`, or the group row's), and from
/// then on the bubble shows the file. The file lives in the caches directory (`files_v2/<row key>/`), where the system may reclaim
/// it: the row then shows the download button again (and the descriptor's token may by then have expired, which the user is told).
/// The thumbnail is a file of its own, fetched with its own key, and its failure is never shown: the card simply has no picture.
@MainActor
final class FileV2DownloadCenter: ObservableObject {

    static let shared = FileV2DownloadCenter()

    enum State: Equatable {
        /// `progress` is `0...1`.
        case downloading(progress: Double)
        /// The sentence the user reads.
        case failed(String)
    }

    /// What a row hands over to have its file downloaded. `key` is the id of the row (`FileV2LocalFiles` makes a directory name of
    /// it); `onFinished` runs on the main actor with the decrypted file and records its path on the row.
    struct Job {
        let key: String
        let descriptor: FileV2Descriptor
        let onFinished: @MainActor (URL) -> Void
    }

    @Published private(set) var states: [String: State] = [:]
    /// The rows whose thumbnail has landed on disk since the launch. A bubble that shows a thumbnail watches it, to load the file when
    /// it appears.
    @Published private(set) var thumbnailReady: Set<String> = []
    private var tasks: [String: Task<Void, Never>] = [:]
    private var thumbnailTasks: Set<String> = []

    func state(for key: String) -> State? { states[key] }

    func cancel(_ key: String) {
        tasks[key]?.cancel()
    }

    /// The sender made the thumbnail of a row of its own (an image or a video being sent): the bubble may load it.
    func markThumbnailReady(_ key: String) {
        thumbnailReady.insert(key)
    }

    // MARK: A 1:1 message row

    /// The download of the file of `message` (an incoming row that carries a valid descriptor), asked by the user.
    func start(message: Message, appState: AppState) {
        guard let job = Self.job(for: message) else {
            states[message.id.uuidString] = .failed(FileV2FailureText.message(for: FileV2Failure(.format("bad_descriptor"))))
            return
        }
        start(job, appState: appState)
    }

    /// What starts on arrival, or when the bubble appears: the thumbnail, and the file if the policy says so. Does nothing for a
    /// row that already has its file, is being downloaded, or has failed (a failure waits for the tap on "Riprova").
    func autoStart(message: Message, appState: AppState) {
        guard message.direction == .incoming, let job = Self.job(for: message) else { return }
        autoStart(job, appState: appState, hasFile: Self.fileExists(atPath: message.mediaLocalPath))
    }

    private static func job(for message: Message) -> Job? {
        guard let descriptor = FileV2ChatBody.descriptor(ofBody: message.plaintext) else { return nil }
        let messageId = message.id
        let conversationId = message.conversationId
        let peerUserId = message.senderUserId
        return Job(key: messageId.uuidString, descriptor: descriptor, onFinished: { url in
            ConversationStore().setMediaInfo(
                localId: messageId, conversationId: conversationId, plaintext: nil,
                mediaLocalPath: url.path, mediaDurationMs: nil, mediaMimeType: nil)
            var info: [String: Any] = ["conversationId": conversationId]
            if let peerUserId { info["peerUserId"] = peerUserId }
            NotificationCenter.default.post(name: AppState.chatRefreshNotification, object: nil, userInfo: info)
        })
    }

    // MARK: A group row

    func start(groupRow row: GroupMessageStore.Stored, groupHex: String, appState: AppState) {
        guard let job = Self.job(for: row, groupHex: groupHex) else {
            states[row.id] = .failed(FileV2FailureText.message(for: FileV2Failure(.format("bad_descriptor"))))
            return
        }
        start(job, appState: appState)
    }

    func autoStart(groupRow row: GroupMessageStore.Stored, groupHex: String, appState: AppState) {
        guard !row.mine, let job = Self.job(for: row, groupHex: groupHex) else { return }
        autoStart(job, appState: appState, hasFile: Self.fileExists(atPath: row.mediaLocalPath))
    }

    private static func job(for row: GroupMessageStore.Stored, groupHex: String) -> Job? {
        guard let body = row.descriptorJson, let descriptor = FileV2ChatBody.descriptor(ofBody: body) else { return nil }
        let rowId = row.id
        return Job(key: rowId, descriptor: descriptor, onFinished: { url in
            GroupMessageStore.shared.setMediaPath(groupHex: groupHex, id: rowId, path: url.path)
        })
    }

    // MARK: The downloads

    /// The file of `job`, asked by the user: its thumbnail too when it is not there yet.
    func start(_ job: Job, appState: AppState) {
        let key = job.key
        guard tasks[key] == nil else { return }
        let destination = Self.destination(for: job)
        let server = FileV2AppServices.makeServer(appState: appState)
        states[key] = .downloading(progress: 0)
        tasks[key] = Task { [weak self] in
            await BackgroundUploadTask.run(name: "file-v2-download") {
                guard let self else { return }
                await self.run(job, destination: destination, server: server)
            }
        }
        fetchThumbnail(job, appState: appState)
    }

    private func autoStart(_ job: Job, appState: AppState, hasFile: Bool) {
        fetchThumbnail(job, appState: appState)
        guard !hasFile, tasks[job.key] == nil, states[job.key] == nil else { return }
        let descriptor = job.descriptor
        guard FileV2AutoDownloadPolicy.isAutomatic(kind: descriptor.kind, size: descriptor.size) else { return }
        start(job, appState: appState)
    }

    private func run(_ job: Job, destination: URL, server: FileV2Server) async {
        let key = job.key
        let receiver = FileV2Receiver(server: server)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await receiver.download(job.descriptor, to: destination) { done, total in
                Task { @MainActor in
                    FileV2DownloadCenter.shared.setProgress(key, done: done, total: total)
                }
            }
            job.onFinished(destination)
            finish(key)
            RTLog.info("chat", "filev2 download ok=1")
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: destination)
            finish(key)
        } catch let failure as FileV2Failure {
            RTLog.warn("chat", "filev2 download failed code=\(failure.code)")
            fail(key, FileV2FailureText.message(for: failure), file: destination)
        } catch {
            RTLog.warn("chat", "filev2 download failed code=io")
            fail(key, FileV2FailureText.message(for: FileV2Failure(.unreadable)), file: destination)
        }
    }

    /// The thumbnail of `job`'s file, when the descriptor has a valid one and it is not on disk yet. A failure is not shown: the
    /// card has no picture, which is what it had before.
    func fetchThumbnail(_ job: Job, appState: AppState) {
        let key = job.key
        guard let thumbnail = job.descriptor.thumbnail,
              FileV2AutoDownloadPolicy.fetchesThumbnail(of: job.descriptor.kind),
              !thumbnailTasks.contains(key), !thumbnailReady.contains(key) else { return }
        let destination = FileV2LocalFiles.thumbnailURL(base: Self.cachesBase, rowKey: key)
        if FileManager.default.fileExists(atPath: destination.path) {
            thumbnailReady.insert(key)
            return
        }
        let server = FileV2AppServices.makeServer(appState: appState)
        thumbnailTasks.insert(key)
        Task { [weak self] in
            await BackgroundUploadTask.run(name: "file-v2-thumbnail") {
                guard let self else { return }
                await self.runThumbnail(thumbnail, key: key, destination: destination, server: server)
            }
        }
    }

    private func runThumbnail(_ thumbnail: FileV2Descriptor, key: String, destination: URL, server: FileV2Server) async {
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await FileV2Receiver(server: server).download(thumbnail, to: destination)
            thumbnailReady.insert(key)
        } catch let failure as FileV2Failure {
            RTLog.info("chat", "filev2 thumbnail failed code=\(failure.code)")
        } catch {
            RTLog.info("chat", "filev2 thumbnail failed code=io")
        }
        thumbnailTasks.remove(key)
    }

    private func setProgress(_ key: String, done: Int64, total: Int64) {
        guard total > 0, tasks[key] != nil else { return }
        states[key] = .downloading(progress: min(1, max(0, Double(done) / Double(total))))
    }

    private func finish(_ key: String) {
        states.removeValue(forKey: key)
        tasks.removeValue(forKey: key)
    }

    private func fail(_ key: String, _ text: String, file: URL) {
        try? FileManager.default.removeItem(at: file)
        tasks.removeValue(forKey: key)
        states[key] = .failed(text)
    }

    // MARK: Places

    /// The directory the downloads live under: the caches directory, or the temporary one when the system gives none.
    nonisolated static var cachesBase: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
    }

    /// `Caches/files_v2/<row key>/<safe name>`: the name is the peer's, cut to one safe path component (with an extension).
    private static func destination(for job: Job) -> URL {
        let descriptor = job.descriptor
        let name = FileV2LocalFiles.fileName(name: descriptor.name, mimeType: descriptor.mimeType, kind: descriptor.kind.rawValue)
        return FileV2LocalFiles.fileURL(base: cachesBase, rowKey: job.key, fileName: name)
    }

    /// The thumbnail of the row `key`, when it is on this device.
    nonisolated static func thumbnailPath(forKey key: String) -> String? {
        let url = FileV2LocalFiles.thumbnailURL(base: cachesBase, rowKey: key)
        return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }

    /// A path that is set and still there (the system may reclaim the caches directory).
    nonisolated static func fileExists(atPath path: String?) -> Bool {
        guard let path, !path.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: path)
    }
}
