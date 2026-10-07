import Foundation

// The wire vocabulary of the in-memory fake of the server's parts protocol: a request as the server's router sees it
// (method, path with its query, headers, body, how the body arrives) and an answer as a client reads it (status, headers,
// JSON or bytes). The fake core (FakeFileV2Core.swift) is a state machine over these; the transcript replay speaks them
// directly, and the typed `FileV2Server` adapter (FakeFileV2Server.swift) builds them from typed calls.

/// Headers, case-insensitive by ASCII, in the order they were set.
struct FakeHeaders {
    private(set) var pairs: [(name: String, value: String)] = []

    init() {}

    init(_ pairs: [(String, String)]) {
        for (name, value) in pairs { add(name, value) }
    }

    private static func fold(_ text: String) -> [UInt8] {
        text.utf8.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 32 : $0 }
    }

    /// Every value of `name`, in order.
    func values(_ name: String) -> [String] {
        let wanted = FakeHeaders.fold(name)
        return pairs.filter { FakeHeaders.fold($0.name) == wanted }.map { $0.value }
    }

    /// The first value of `name`.
    func first(_ name: String) -> String? { values(name).first }

    func has(_ name: String) -> Bool { first(name) != nil }

    /// Adds a value next to the existing ones.
    mutating func add(_ name: String, _ value: String) {
        pairs.append((name: name, value: value))
    }

    /// Replaces every value of `name` with this one.
    mutating func set(_ name: String, _ value: String) {
        remove(name)
        add(name, value)
    }

    mutating func remove(_ name: String) {
        let wanted = FakeHeaders.fold(name)
        pairs.removeAll { FakeHeaders.fold($0.name) == wanted }
    }
}

/// How the body of a part upload reaches the server.
enum FakeUploadMode: Equatable {
    /// Every byte arrives, then the end of the body.
    case complete
    /// `after` bytes arrive and the sender then goes quiet: the server waits (and keeps the slot and the part lock) until
    /// the test finishes or abandons the request.
    case stall(after: Int)
    /// `after` bytes arrive and the connection is dropped: nobody reads an answer.
    case abort(after: Int)
    /// `after` bytes arrive and the sender shuts down its side but keeps reading: the only way a client sees `short_body`.
    case halfClose(after: Int)
}

struct FakeWireRequest {
    var method: String
    /// Absolute path, with its query when it has one (`/api/v1/files/v2?state=unfinished`).
    var path: String
    var headers = FakeHeaders()
    /// The authenticated account; `nil` is no authentication.
    var user: String?
    /// The request body: the JSON of a create or a token request, the bytes of a part (the FULL body, of which `upload`
    /// says how much arrives).
    var body = Data()
    /// The `Content-Length` of a part upload; `nil` is a body sent without a length (chunked).
    var contentLength: Int?
    var upload = FakeUploadMode.complete

    init(method: String, path: String, user: String?) {
        self.method = method
        self.path = path
        self.user = user
    }
}

struct FakeWireResponse {
    var status: Int
    var headers = FakeHeaders()
    /// The JSON body of an answer that has one.
    var json: FakeJSON?
    /// The bytes of a download.
    var body: Data?
    /// The request was not answered: the connection was dropped on purpose.
    var aborted = false
    /// A step awaited a request that cannot finish (a test bug), described here.
    var stuck: String?

    init(status: Int) { self.status = status }

    /// The `error` field of a JSON error body.
    var errorCode: String? { json?.member("error")?.stringValue }
}

/// What the server does with a request: answers it, or keeps it (a stalled upload, a retry that waits for a busy part, a
/// download that waits for parts, a create that waits at the disk gate) and answers later.
enum FakeOutcome {
    case response(FakeWireResponse)
    case pending(Int)
}
