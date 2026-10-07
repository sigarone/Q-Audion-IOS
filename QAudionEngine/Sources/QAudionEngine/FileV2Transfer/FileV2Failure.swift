import Foundation

/// How a send or a receive of a v2 file ended badly, as the chat layer sees it. One type for both directions, so the app has
/// ONE place (`FileV2FailureText`, in the app target, where the localised strings live) that turns a failure into a
/// sentence the user can act on.
///
/// `server` keeps the answer of the server when there was one: the numbers a message shows (`used` and `limit` of a 413
/// `quota_exceeded`) stay there. Nothing in this type holds a key, a token, an object id or a file name, and neither the
/// description nor `code` ever prints one.
public struct FileV2Failure: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {

    public enum Reason: Equatable, Sendable {
        /// The file to send has no byte.
        case emptyFile
        /// The file to send is above `FileV2.maxSize`.
        case fileTooLarge
        /// The source could not be read (gone, permission, I/O).
        case unreadable
        /// The chat cannot seal a message for this contact yet (no session, no pairwise key): the descriptor could not be sent,
        /// so nothing is uploaded. The key exchange it starts is the remedy; the user tries again in a moment.
        case noSecureChannel
        /// The server no longer has the object (404, or the token is spent or refused): the receiver cannot fetch it.
        case unavailable
        /// The server dropped the object while it was being uploaded.
        case objectGone
        /// A failure of the transport layer (`FileV2TransferError`: quota, server full, network, ...).
        case transfer(FileV2TransferError)
        /// A failure of the format (WIRE_SPEC 12.9): the code of `FileV2Error` (`chunk_auth`, `bad_padding`, ...).
        case format(String)
    }

    public let reason: Reason
    public let server: FileV2ServerError?

    public init(_ reason: Reason, server: FileV2ServerError? = nil) {
        self.reason = reason
        self.server = server
    }

    public static func transfer(_ error: FileV2TransferError, server: FileV2ServerError? = nil) -> FileV2Failure {
        FileV2Failure(.transfer(error), server: server)
    }

    /// Telemetry string: no identifier, no key, no name.
    public var code: String {
        switch reason {
        case .emptyFile: return "empty_file"
        case .fileTooLarge: return "file_too_large"
        case .unreadable: return "unreadable"
        case .noSecureChannel: return "no_secure_channel"
        case .unavailable: return "unavailable"
        case .objectGone: return "object_gone"
        case .transfer(let error): return error.code
        case .format(let code): return code
        }
    }

    public var description: String {
        if let server { return "FileV2Failure(\(code), \(server))" }
        return "FileV2Failure(\(code))"
    }

    public var errorDescription: String? { description }
}
