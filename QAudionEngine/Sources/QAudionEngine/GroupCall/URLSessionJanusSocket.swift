import Foundation

#if !canImport(FoundationNetworking)

/// The real `JanusSocket`: one `URLSessionWebSocketTask` with the
/// `janus-protocol` subprotocol (spec §4.1) over TLS (the node sits behind
/// Caddy on 443, path `/janus`). Only `wss` urls are ever passed in
/// (`GroupCallWire.MediaReady.parse` refuses anything else).
///
/// The url carries no secrets and is never logged. Nothing here reads or
/// writes anything but the Janus text frames.
public final class URLSessionJanusSocket: NSObject, JanusSocket, URLSessionWebSocketDelegate, @unchecked Sendable {

    public var onText: ((String) -> Void)?
    public var onClosed: ((Error?) -> Void)?

    private let url: URL
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var closedNotified = false
    private var closedByUs = false

    public init(url: URL) {
        self.url = url
        super.init()
    }

    public func open() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = false
            configuration.timeoutIntervalForRequest = 10
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            let task = session.webSocketTask(with: url, protocols: [JanusWire.subprotocol])
            lock.lock()
            self.session = session
            self.task = task
            openContinuation = continuation
            lock.unlock()
            task.resume()
        }
        receiveLoop()
    }

    public func send(_ text: String, completion: @escaping (Error?) -> Void) {
        lock.lock()
        let current = task
        lock.unlock()
        guard let current = current else {
            completion(JanusClientError.notConnected)
            return
        }
        current.send(.string(text)) { error in completion(error) }
    }

    public func close() {
        lock.lock()
        closedByUs = true
        let current = task
        let currentSession = session
        task = nil
        session = nil
        let pending = openContinuation
        openContinuation = nil
        lock.unlock()
        current?.cancel(with: .goingAway, reason: nil)
        currentSession?.invalidateAndCancel()
        pending?.resume(throwing: JanusClientError.closed)
    }

    private func receiveLoop() {
        lock.lock()
        let current = task
        lock.unlock()
        current?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.onText?(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) { self.onText?(text) }
                @unknown default:
                    break
                }
                self.receiveLoop()
            case .failure(let error):
                self.notifyClosed(error)
            }
        }
    }

    private func notifyClosed(_ error: Error?) {
        lock.lock()
        if closedNotified || closedByUs {
            lock.unlock()
            return
        }
        closedNotified = true
        let pending = openContinuation
        openContinuation = nil
        lock.unlock()
        if let pending = pending {
            pending.resume(throwing: error ?? JanusClientError.closed)
            return
        }
        onClosed?(error)
    }

    // MARK: URLSessionWebSocketDelegate

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didOpenWithProtocol protocol: String?) {
        lock.lock()
        let pending = openContinuation
        openContinuation = nil
        lock.unlock()
        // Janus' WebSocket transport requires the subprotocol: a server that
        // does not select it is not a Janus node we can talk to.
        if `protocol` == JanusWire.subprotocol {
            pending?.resume()
        } else {
            pending?.resume(throwing: JanusClientError.malformed)
            webSocketTask.cancel(with: .protocolError, reason: nil)
        }
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        notifyClosed(nil)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        notifyClosed(error)
    }
}

#endif
