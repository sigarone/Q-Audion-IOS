import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLError lives here on Linux (the scratch harness); on Apple platforms it is Foundation
#endif

/// Transport-level failure codes of a v2 transfer. They are separate from the format codes of `FileV2Error`
/// (WIRE_SPEC 12.9): the format table and the known-answer vectors are not touched, and no name is shared.
///
/// `code` is the telemetry string; it never contains an identifier, a key or a file name.
public enum FileV2TransferError: String, CaseIterable, Sendable, Equatable {
    /// The account has no `feat.files` (402).
    case entitlement
    /// The account's own storage is full (413 `quota_exceeded`), the object is too large (413 `blob_too_large`), or the
    /// account holds as many unfinished uploads or objects as it may (429): the user frees something.
    case quota
    /// The server has no room: the disk is nearly full, or all accounts together hold as many unfinished uploads as
    /// allowed (507).
    case serverFull
    /// Retries of a 429 are spent.
    case rateLimited
    /// The network or the server failed and the retries are spent: the transfer pauses, it does not fail.
    case network
    /// 403 that is not a spent token: the account may not do this.
    case auth
    /// The device has no room for the file (receiver).
    case noSpace
    /// The source changed under the transfer (409 `part_conflict`): cancel and start a new object.
    case sourceChanged
    /// The request is wrong: a client bug or a server this client does not speak to.
    case badRequest
    /// The sender could not hand the descriptor to the chat.
    case announceNotSent
    /// The serialised descriptor would not stay under 8 KiB.
    case descriptorTooLarge

    public var code: String {
        switch self {
        case .entitlement: return "entitlement"
        case .quota: return "quota"
        case .serverFull: return "server_full"
        case .rateLimited: return "rate_limited"
        case .network: return "network"
        case .auth: return "auth"
        case .noSpace: return "no_space"
        case .sourceChanged: return "source_changed"
        case .badRequest: return "bad_request"
        case .announceNotSent: return "announce_not_sent"
        case .descriptorTooLarge: return "descriptor_too_large"
        }
    }
}

/// What a pipeline does with a failed request.
public enum FileV2Disposition: Sendable, Equatable {
    /// The same request again after a backoff (or `Retry-After`); `onExhausted` is the error when the attempts are spent.
    case retry(onExhausted: FileV2TransferError)
    /// 425: wait `Retry-After` and ask again; not a failure and not counted as an attempt.
    case wait
    /// 404 on a sender operation: the object is gone; create it again with the same header (create is idempotent on it).
    case recreate
    /// 409 `incomplete`: send the parts listed in `missing`.
    case sendMissing
    /// 401: refresh the access token and repeat.
    case refreshAuth
    /// The request achieved its purpose (a delete of an object that is already gone).
    case done
    /// The file cannot be fetched any more (receiver: 404, or 403 `token_rejected`: expired, spent or not a member of
    /// the group). Nothing to recreate or retry.
    case unavailable
    /// Waiting does not help: the user must free something (delete or finish an upload). `error` is what the UI shows.
    case userRemedy(FileV2TransferError)
    /// Final failure.
    case fail(FileV2TransferError)
}

extension FileV2ServerError {

    /// The mapping of the server's error table (docs/FILES_V2_PARTS_PROTOCOL.md, "Errors") for the operation `op` that
    /// failed: the same status means different things for a delete, a receiver's read and a sender's part.
    ///
    /// `quota_exceeded`, `blob_too_large` and `insufficient_storage` are final and user-visible; the numbers the UI shows
    /// (`used`, `limit`, `maxBlobLength`) stay in `details` of this error, which the pipeline keeps with the failure.
    public func disposition(for op: FileV2Op) -> FileV2Disposition {
        let network = FileV2Disposition.retry(onExhausted: .network)
        switch status {
        case 400:
            if code == "digest_mismatch" || code == "short_body" { return network }
            return .fail(.badRequest)
        case 401:
            return .refreshAuth
        case 402:
            return .fail(.entitlement)
        case 403:
            if op == .fetchRange && code == "token_rejected" { return .unavailable }
            return .fail(.auth)
        case 404:
            switch op {
            case .delete: return .done
            case .fetchRange: return .unavailable
            case .putPart, .partsMap, .complete, .issueToken: return .recreate
            // These routes always exist: a 404 here is a server this client does not speak to, and "recreate" would loop.
            case .create, .listUnfinished, .deleteUnfinished: return .fail(.badRequest)
            }
        case 409:
            if code == "part_conflict" { return .fail(.sourceChanged) }
            if code == "incomplete" { return .sendMissing }
            return .fail(.badRequest)
        case 413:
            return .fail(.quota)
        case 425:
            return .wait
        case 429:
            if code == "too_many_uploads" || code == "too_many_objects" { return .userRemedy(.quota) }
            return .retry(onExhausted: .rateLimited)
        case 507:
            return .fail(.serverFull)
        case 500...599:
            return network
        default:
            // 405, 411, 416 and anything unknown below 500
            return .fail(.badRequest)
        }
    }
}

/// `disposition(for:)` for any error of the transport: a typed server answer, or an I/O error (a reset, a timeout) to
/// retry. Cancellation is never a transport failure and is rethrown: a `CancellationError`, and a `URLError` that says
/// `cancelled` while the task is cancelled.
public func fileV2TransportDisposition(_ error: Error, op: FileV2Op) throws -> FileV2Disposition {
    if error is CancellationError { throw error }
    if let server = error as? FileV2ServerError { return server.disposition(for: op) }
    if let url = error as? URLError {
        if url.code == .cancelled && Task.isCancelled { throw CancellationError() }
        return .retry(onExhausted: .network)
    }
    if error is POSIXError { return .retry(onExhausted: .network) }
    let ns = error as NSError
    if ns.domain == NSURLErrorDomain || ns.domain == NSPOSIXErrorDomain {
        return .retry(onExhausted: .network)
    }
    return .fail(.network)
}
