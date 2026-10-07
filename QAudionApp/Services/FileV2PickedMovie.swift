import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// A video chosen in the photo picker, as a file the app owns: the picker hands the movie over as a file (never as bytes held in
/// memory, a video can be gigabytes), and this copies it to the temporary directory so that it outlives the picker. The send moves it
/// into the caches directory (`FileV2MediaPreparer.prepareVideo`); a send that never happens leaves a temporary file the system
/// reclaims.
struct FileV2PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("picked-videos", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copy = directory.appendingPathComponent(UUID().uuidString + "." + ext)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return FileV2PickedMovie(url: copy)
        }
    }

    /// Whether the picked item is a video (a movie type among the types it can be loaded as).
    static func isVideo(_ item: PhotosPickerItem) -> Bool {
        item.supportedContentTypes.contains { $0.conforms(to: .movie) }
    }

    /// The temporary files of a pending attachment that is not going to be sent (the recording of a voice note, the copies of the
    /// picked videos): nothing else holds them.
    static func discardTemporaryFiles(of pending: PendingAttachmentSend?) {
        guard let pending else { return }
        switch pending {
        case .voiceNote(let recording):
            try? FileManager.default.removeItem(at: recording.fileURL)
        case .media(_, let videos):
            for url in videos { try? FileManager.default.removeItem(at: url) }
        default:
            break
        }
    }

    /// The file of a picked video, or `nil` when the picker could not hand it over.
    static func load(_ item: PhotosPickerItem) async -> URL? {
        let movie = try? await item.loadTransferable(type: FileV2PickedMovie.self)
        return movie?.url
    }
}
