import Foundation

/// The byte transport under `JanusClient`. `URLSessionJanusSocket` is the real
/// one (URLSessionWebSocketTask, subprotocol `janus-protocol`); tests use a
/// scripted fake.
public protocol JanusSocket: AnyObject {
    /// Connects; returns once the WebSocket handshake is done.
    func open() async throws
    /// Queues one text frame. Calls made in order are sent in order.
    func send(_ text: String, completion: @escaping (Error?) -> Void)
    func close()
    var onText: ((String) -> Void)? { get set }
    /// Called at most once, when the connection ends for any reason but `close()`.
    var onClosed: ((Error?) -> Void)? { get set }
}

public enum JanusClientError: Error, Equatable, Sendable {
    /// No reply within the request timeout (8 s by default, spec §8).
    case timeout
    case closed
    case notConnected
    case malformed
    /// A Janus core error (`janus:"error"`).
    case janus(code: Int, reason: String)
    /// A VideoRoom plugin error (`error_code` inside an event).
    case plugin(code: Int, reason: String)

    public var code: Int? {
        switch self {
        case .janus(let code, _), .plugin(let code, _): return code
        default: return nil
        }
    }
}

/// Janus session client (spec §4.1): one WebSocket, one session, plugin
/// handles, transaction matching, 25 s keepalive. Everything the VideoRoom
/// layer needs and nothing else.
///
/// Request kinds, by what completes them:
///  * `keepalive`            -> `ack`
///  * `create/attach/claim`  -> `success`
///  * plugin `message`       -> the final `event` (an `ack` only means "queued",
///                              a synchronous plugin answer arrives as `success`)
/// Anything else that arrives without a pending transaction (handle events,
/// `webrtcup`, `slowlink`, `hangup`, `detached`, `timeout`, `media`, `trickle`)
/// is handed to `onEvent`.
public final class JanusClient: @unchecked Sendable {

    public struct Config: Sendable {
        public var requestTimeoutSeconds: Double = 8
        public var keepaliveIntervalSeconds: Double = 25

        public init() {}
    }

    private enum Completion {
        case ack
        case success
        case event
    }

    private struct Pending {
        let continuation: CheckedContinuation<JanusMessage, Error>
        let completion: Completion
        let timeoutTask: Task<Void, Never>
    }

    /// Unsolicited messages (see the type comment).
    public var onEvent: ((JanusMessage) -> Void)?
    /// The WebSocket ended without a `close()` from us.
    public var onTransportClosed: ((Error?) -> Void)?

    public let config: Config

    private let lock = NSLock()
    private var socket: JanusSocket?
    private let makeSocket: () -> JanusSocket
    private let tokenProvider: () -> String
    private let newTransaction: () -> String
    private var pending: [String: Pending] = [:]
    private var session: Int64?
    private var keepaliveTask: Task<Void, Never>?
    private var socketGeneration = 0
    private var closing = false

    public init(config: Config = Config(),
                makeSocket: @escaping () -> JanusSocket,
                token: @escaping () -> String,
                newTransaction: @escaping () -> String = JanusWire.newTransaction) {
        self.config = config
        self.makeSocket = makeSocket
        self.tokenProvider = token
        self.newTransaction = newTransaction
    }

    public var sessionId: Int64? {
        lock.lock(); defer { lock.unlock() }
        return session
    }

    // MARK: - Session lifecycle

    /// Opens the WebSocket, creates the session and starts the keepalive.
    @discardableResult
    public func connect() async throws -> Int64 {
        try await openSocket()
        let reply = try await request(JanusWire.create(token: tokenProvider()), completion: .success)
        guard let id = reply.dataId else { throw JanusClientError.malformed }
        lock.lock()
        session = id
        lock.unlock()
        startKeepalive()
        return id
    }

    /// Re-attaches the existing session to a NEW WebSocket (Janus
    /// `reclaim_session_timeout`, 20 s on qjanus). Throws `.janus(458, ..)`
    /// when the session is gone: the caller then rejoins from scratch.
    public func reclaim() async throws {
        guard let id = sessionId else { throw JanusClientError.notConnected }
        try await openSocket()
        _ = try await request(JanusWire.claim(sessionId: id, token: tokenProvider()), completion: .success)
        startKeepalive()
    }

    public func attach(plugin: String = JanusWire.pluginVideoRoom) async throws -> Int64 {
        guard let id = sessionId else { throw JanusClientError.notConnected }
        let reply = try await request(JanusWire.attach(sessionId: id, plugin: plugin, token: tokenProvider()), completion: .success)
        guard let handle = reply.dataId else { throw JanusClientError.malformed }
        return handle
    }

    /// A plugin request. Returns the final `event` (or synchronous `success`);
    /// throws `.plugin` when the plugin reports an error inside it.
    public func send(handle: Int64, body: [String: Any], jsep: JanusJsep? = nil) async throws -> JanusMessage {
        guard let id = sessionId else { throw JanusClientError.notConnected }
        let reply = try await request(
            JanusWire.message(sessionId: id, handleId: handle, body: body, jsep: jsep, token: tokenProvider()),
            completion: .event)
        if let code = reply.pluginErrorCode {
            throw JanusClientError.plugin(code: code, reason: reply.pluginErrorReason ?? "")
        }
        return reply
    }

    /// Fire and forget; the `ack` is ignored.
    public func trickle(handle: Int64, candidate: (sdpMid: String?, sdpMLineIndex: Int32, candidate: String)?) {
        guard let id = sessionId else { return }
        var payload = JanusWire.trickle(sessionId: id, handleId: handle, candidate: candidate, token: tokenProvider())
        payload["transaction"] = newTransaction()
        sendRaw(payload)
    }

    public func detach(handle: Int64) {
        guard let id = sessionId else { return }
        var payload = JanusWire.detach(sessionId: id, handleId: handle, token: tokenProvider())
        payload["transaction"] = newTransaction()
        sendRaw(payload)
    }

    /// Best-effort teardown: destroys the session, then closes the socket.
    public func close() {
        lock.lock()
        closing = true
        let id = session
        let task = keepaliveTask
        keepaliveTask = nil
        let sock = socket
        let waiting = pending
        pending = [:]
        lock.unlock()
        task?.cancel()
        if let id = id {
            var payload = JanusWire.destroy(sessionId: id, token: tokenProvider())
            payload["transaction"] = newTransaction()
            if let text = JanusWire.encode(payload) { sock?.send(text) { _ in } }
        }
        sock?.close()
        for (_, entry) in waiting {
            entry.timeoutTask.cancel()
            entry.continuation.resume(throwing: JanusClientError.closed)
        }
    }

    // MARK: - Internals

    private func openSocket() async throws {
        let fresh = makeSocket()
        lock.lock()
        socketGeneration += 1
        let generation = socketGeneration
        let old = socket
        socket = fresh
        closing = false
        lock.unlock()
        old?.onText = nil
        old?.onClosed = nil
        old?.close()
        fresh.onText = { [weak self] text in self?.handle(text) }
        fresh.onClosed = { [weak self] error in self?.socketClosed(generation: generation, error: error) }
        try await fresh.open()
    }

    private func socketClosed(generation: Int, error: Error?) {
        lock.lock()
        guard generation == socketGeneration, !closing else {
            lock.unlock()
            return
        }
        let task = keepaliveTask
        keepaliveTask = nil
        let waiting = pending
        pending = [:]
        lock.unlock()
        task?.cancel()
        for (_, entry) in waiting {
            entry.timeoutTask.cancel()
            entry.continuation.resume(throwing: JanusClientError.closed)
        }
        onTransportClosed?(error)
    }

    private func request(_ base: [String: Any], completion: Completion) async throws -> JanusMessage {
        var payload = base
        let transaction = newTransaction()
        payload["transaction"] = transaction
        guard let text = JanusWire.encode(payload) else { throw JanusClientError.malformed }
        let timeout = config.requestTimeoutSeconds
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JanusMessage, Error>) in
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.finish(transaction, with: .failure(JanusClientError.timeout))
            }
            lock.lock()
            let sock = socket
            let alive = sock != nil && !closing
            if alive {
                pending[transaction] = Pending(continuation: continuation, completion: completion, timeoutTask: timeoutTask)
            }
            lock.unlock()
            guard alive, let sock = sock else {
                timeoutTask.cancel()
                continuation.resume(throwing: JanusClientError.notConnected)
                return
            }
            sock.send(text) { [weak self] error in
                if let error = error { self?.finish(transaction, with: .failure(error)) }
            }
        }
    }

    private func sendRaw(_ payload: [String: Any]) {
        lock.lock()
        let sock = socket
        let alive = !closing
        lock.unlock()
        guard alive, let sock = sock, let text = JanusWire.encode(payload) else { return }
        sock.send(text) { _ in }
    }

    private func finish(_ transaction: String, with result: Result<JanusMessage, Error>) {
        lock.lock()
        let entry = pending.removeValue(forKey: transaction)
        lock.unlock()
        guard let entry = entry else { return }
        entry.timeoutTask.cancel()
        entry.continuation.resume(with: result)
    }

    private func handle(_ text: String) {
        guard let message = JanusMessage.parse(text) else { return }
        if let transaction = message.transaction {
            lock.lock()
            let entry = pending[transaction]
            lock.unlock()
            if let entry = entry {
                switch message.kind {
                case .error:
                    finish(transaction, with: .failure(JanusClientError.janus(
                        code: message.errorCode ?? -1, reason: message.errorReason ?? "")))
                    return
                case .ack:
                    if entry.completion == .ack { finish(transaction, with: .success(message)) }
                    return
                case .success:
                    if entry.completion != .ack { finish(transaction, with: .success(message)) }
                    return
                case .event:
                    if entry.completion == .event { finish(transaction, with: .success(message)) }
                    return
                default:
                    break
                }
            } else if message.kind == .ack {
                return
            }
        }
        switch message.kind {
        case .ack, .success, .error:
            return
        default:
            onEvent?(message)
        }
    }

    private func startKeepalive() {
        let interval = config.keepaliveIntervalSeconds
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                guard let self = self, let id = self.sessionId else { return }
                do {
                    _ = try await self.request(JanusWire.keepalive(sessionId: id, token: self.tokenProvider()), completion: .ack)
                } catch {
                    if Task.isCancelled { return }
                    // No ack: the session is as good as gone. Surface it like a
                    // dropped socket so the owner reclaims or rejoins.
                    self.socketClosed(generation: self.currentGeneration(), error: error)
                    return
                }
            }
        }
        lock.lock()
        keepaliveTask?.cancel()
        keepaliveTask = task
        lock.unlock()
    }

    private func currentGeneration() -> Int {
        lock.lock(); defer { lock.unlock() }
        return socketGeneration
    }
}
