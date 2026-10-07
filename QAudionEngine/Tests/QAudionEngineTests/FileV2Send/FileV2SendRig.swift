import XCTest
import CryptoKit
@testable import QAudionEngine
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The doubles and the rig of the send pipeline tests. Everything runs against the transcript-replaying fake server of step 2a
// (FakeFileV2Server) and a store in a temporary directory.

/// A sleeper that returns at once and moves the manual clock by what was asked, recording every wait.
final class InstantSleeper: FileV2Sleeper, @unchecked Sendable {
    private let clock: XferManualClock
    private let lock = NSLock()
    private var recorded: [Int64] = []

    init(clock: XferManualClock) {
        self.clock = clock
    }

    func sleep(milliseconds ms: Int64) async throws {
        try Task.checkCancellation()
        lock.lock()
        recorded.append(ms)
        lock.unlock()
        clock.advance(ms: ms)
        await Task.yield()
    }

    var delays: [Int64] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

/// Collects the telemetry events.
final class RecordingTelemetry: FileV2SendTelemetry, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [FileV2SendTelemetryEvent] = []

    func record(_ event: FileV2SendTelemetryEvent) {
        lock.lock()
        recorded.append(event)
        lock.unlock()
    }

    var events: [FileV2SendTelemetryEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var bytesUploaded: Int {
        events.reduce(0) { total, event in
            if case .partUploaded(let bytes, _) = event { return total + bytes }
            return total
        }
    }

    func count(_ matches: (FileV2SendTelemetryEvent) -> Bool) -> Int { events.filter(matches).count }
}

/// The chat of the tests: it can refuse to carry a descriptor, answer each announce as the test says, run a hook while the state still
/// exists, and hang (a handover whose answer never comes).
final class RecordingChannel: FileV2DescriptorChannel, @unchecked Sendable {
    struct Announced {
        let body: String
        let conversation: FileV2Conversation
        let key: String
    }

    private let lock = NSLock()
    private let log: SendEventLog
    private var canCarry = true
    private var outcomes: [FileV2AnnounceOutcome] = [.sent]
    private var controlOutcome = FileV2AnnounceOutcome.sent
    private var hook: (@Sendable (String) -> Void)?
    private var hangs = false
    private var announcedList: [Announced] = []
    private var controlList: [(body: String, conversation: FileV2Conversation)] = []
    private var asked = 0

    init(log: SendEventLog) {
        self.log = log
    }

    func setCanCarry(_ value: Bool) { locked { canCarry = value } }

    /// The outcomes of the next announces, in order; the last one repeats.
    func setOutcomes(_ values: [FileV2AnnounceOutcome]) { locked { outcomes = values } }

    func setHook(_ value: (@Sendable (String) -> Void)?) { locked { hook = value } }

    /// The next announces record their body and then never answer (until the task is cancelled).
    func setHangs(_ value: Bool) { locked { hangs = value } }

    var announced: [Announced] { locked { announcedList } }
    var controls: [(body: String, conversation: FileV2Conversation)] { locked { controlList } }
    var askedCount: Int { locked { asked } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func canCarryDescriptor(to conversation: FileV2Conversation) async -> Bool {
        locked {
            asked += 1
            return canCarry
        }
    }

    func announce(_ body: String, to conversation: FileV2Conversation, idempotencyKey: String) async -> FileV2AnnounceOutcome {
        let (outcome, runHook, shouldHang) = locked { () -> (FileV2AnnounceOutcome, (@Sendable (String) -> Void)?, Bool) in
            announcedList.append(Announced(body: body, conversation: conversation, key: idempotencyKey))
            let index = min(announcedList.count - 1, outcomes.count - 1)
            return (outcomes[index], hook, hangs)
        }
        log.add("channel.announce")
        runHook?(body)
        if shouldHang {
            // Hand-over made, answer never comes: sleep until the task is cancelled.
            try? await Task.sleep(nanoseconds: 3_600_000_000_000)
            return .unavailable
        }
        return outcome
    }

    func sendControl(_ body: String, to conversation: FileV2Conversation) async -> FileV2AnnounceOutcome {
        locked {
            controlList.append((body, conversation))
            return controlOutcome
        }
    }
}

/// The store the pipeline sees: the real file store, with every append logged before and after it, so the tests can assert what the
/// journal held (durably) when a part was PUT.
final class InstrumentedStore: FileV2SendStore, @unchecked Sendable {
    let inner: FileV2FileSendStore
    let log: SendEventLog
    private let lock = NSLock()
    private var failTagAppends = 0
    private var loads = 0
    private var appended: [(id: String, event: FileV2SendJournalEvent)] = []

    init(inner: FileV2FileSendStore, log: SendEventLog) {
        self.inner = inner
        self.log = log
    }

    /// The next `count` appends of tags fail with an I/O error (a full disk).
    func failNextTagAppends(_ count: Int) {
        lock.lock()
        failTagAppends = count
        lock.unlock()
    }

    func begin(_ record: FileV2SendBeginRecord) throws {
        log.add("journal.begin")
        try inner.begin(record)
    }

    func append(_ event: FileV2SendJournalEvent, to transferID: String) throws {
        let label = InstrumentedStore.label(event)
        if case .tags = event {
            let failing = { () -> Bool in
                lock.lock()
                defer { lock.unlock() }
                if failTagAppends > 0 {
                    failTagAppends -= 1
                    return true
                }
                return false
            }()
            if failing { throw FileV2SendStoreError.io("append") }
        }
        log.add("journal.\(label).begin")
        try inner.append(event, to: transferID)
        lock.lock()
        appended.append((transferID, event))
        lock.unlock()
        log.add("journal.\(label).done")
    }

    /// How many times THIS instance was asked to read a journal.
    var loadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return loads
    }

    func load(_ transferID: String) throws -> FileV2SendRecovered {
        lock.lock()
        loads += 1
        lock.unlock()
        log.add("journal.load")
        return try inner.load(transferID)
    }

    func listTransferIDs() throws -> [String] { try inner.listTransferIDs() }

    /// The lock is logged when it is taken, refused and given up, so a test can read WHEN a transfer was claimed relative to everything else.
    func acquireLock(_ transferID: String) throws -> FileV2SendTransferLock {
        do {
            let lock = try inner.acquireLock(transferID)
            log.add("lock.acquire")
            return InstrumentedLock(inner: lock, log: log)
        } catch {
            if case FileV2SendStoreError.busy = error { log.add("lock.busy") }
            throw error
        }
    }

    func remove(_ transferID: String) throws {
        log.add("journal.remove")
        try inner.remove(transferID)
    }

    /// Every event appended through this instance.
    var events: [FileV2SendJournalEvent] {
        lock.lock()
        defer { lock.unlock() }
        return appended.map { $0.event }
    }

    /// `tags part=3 chunks=24,25`, `object`, `token`, `partDone part=3`, `phase announcing`.
    static func label(_ event: FileV2SendJournalEvent) -> String {
        switch event {
        case .tags(let part, let entries): return "tags part=\(part) chunks=\(entries.map { String($0.index) }.joined(separator: ","))"
        case .object: return "object"
        case .token: return "token"
        case .partDone(let part): return "partDone part=\(part)"
        case .phase(let phase): return "phase \(phase)"
        }
    }
}

/// A lock that logs its release (once, at the first release).
final class InstrumentedLock: FileV2SendTransferLock, @unchecked Sendable {
    private let inner: FileV2SendTransferLock
    private let log: SendEventLog
    private let flag = NSLock()
    private var released = false

    init(inner: FileV2SendTransferLock, log: SendEventLog) {
        self.inner = inner
        self.log = log
    }

    func release() {
        flag.lock()
        let first = !released
        released = true
        flag.unlock()
        if first { log.add("lock.release") }
        inner.release()
    }
}

/// The server of the tests: the fake of step 2a behind a recorder. It logs every call, records the digest and the chunk tags of every PUT
/// body (so a test can assert that no chunk was ever transmitted with a tag that differs from its first transmission), and can KILL
/// the process at a chosen call: from then on every call throws `CancellationError` at once, which is how a dead process looks to the
/// code under test (it does nothing more, and its state is whatever it had made durable).
class RecordingServer: FileV2Server, @unchecked Sendable {

    struct Put: Equatable {
        let part: Int
        let digest: Data
        /// The 16-byte tag at the end of every chunk of the body.
        let chunkTags: [Data]
        /// The index of the first chunk of the part.
        let firstChunk: Int
        let attempt: Int
    }

    struct CrashPlan {
        var op: FileV2Op
        /// The call of `op` (0 based) at which the process dies.
        var call: Int
        /// The request has its effect on the server before the process dies (the answer is lost) or not.
        var applyEffect: Bool
    }

    let inner: FakeFileV2Server
    let log: SendEventLog
    let lock = NSLock()
    private var recordedPuts: [Put] = []
    private var counts: [FileV2Op: Int] = [:]
    private var plan: CrashPlan?
    private var dead = false
    private var perPartAttempts: [Int: Int] = [:]
    private var hook: (@Sendable (FileV2Op, Int) -> Void)?
    private var swallow: [Int: Int] = [:]
    private var stripTokens = false

    init(inner: FakeFileV2Server, log: SendEventLog) {
        self.inner = inner
        self.log = log
    }

    func setCrash(_ value: CrashPlan?) {
        lock.lock()
        plan = value
        lock.unlock()
    }

    /// The next `times` PUTs of `part` are answered with a success that never reached the server: a server that acknowledged a part it lost.
    func swallowPut(part: Int, times: Int = 1) {
        lock.lock()
        swallow[part] = times
        lock.unlock()
    }

    /// The answers of create carry no token (a server without a token secret, a client that did not ask).
    func setStripCreateTokens(_ value: Bool) {
        lock.lock()
        stripTokens = value
        lock.unlock()
    }

    private func shouldSwallow(_ part: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let left = swallow[part], left > 0 else { return false }
        swallow[part] = left - 1
        return true
    }

    private var stripsTokens: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stripTokens
    }

    func revive() {
        lock.lock()
        dead = false
        plan = nil
        counts = [:]
        lock.unlock()
    }

    var isDead: Bool {
        lock.lock()
        defer { lock.unlock() }
        return dead
    }

    /// Called at the start of every call with the op and its 0-based call number (the hook of a test that changes the world mid-run).
    func setHook(_ value: (@Sendable (FileV2Op, Int) -> Void)?) {
        lock.lock()
        hook = value
        lock.unlock()
    }

    var puts: [Put] {
        lock.lock()
        defer { lock.unlock() }
        return recordedPuts
    }

    func callCount(_ op: FileV2Op) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[op] ?? 0
    }

    /// Decides what happens to this call: returns its number and whether the process dies BEFORE it (the call must not be made) or AFTER
    /// its effect.
    private func enter(_ op: FileV2Op) throws -> (call: Int, dieAfter: Bool) {
        lock.lock()
        if dead {
            lock.unlock()
            log.add("server.dead \(op.rawValue)")
            throw CancellationError()
        }
        let call = counts[op] ?? 0
        counts[op] = call + 1
        let currentHook = hook
        var dieAfter = false
        if let crash = plan, crash.op == op, crash.call == call {
            if crash.applyEffect {
                dieAfter = true
            } else {
                dead = true
                lock.unlock()
                log.add("server.crash \(op.rawValue) call=\(call) before")
                throw CancellationError()
            }
        }
        lock.unlock()
        currentHook?(op, call)
        return (call, dieAfter)
    }

    private func die(_ op: FileV2Op, _ call: Int) -> CancellationError {
        lock.lock()
        dead = true
        lock.unlock()
        log.add("server.crash \(op.rawValue) call=\(call) after")
        return CancellationError()
    }

    func create(_ request: FileV2CreateRequest) async throws -> FileV2Created {
        let (call, dieAfter) = try enter(.create)
        log.add("server.create")
        var created = try await inner.create(request)
        if dieAfter { throw die(.create, call) }
        if stripsTokens {
            created = FileV2Created(obj: created.obj, blobLength: created.blobLength, partSize: created.partSize, parts: created.parts,
                                    parallelism: created.parallelism, maxParallelism: created.maxParallelism, token: nil,
                                    existing: created.existing, received: created.received, complete: created.complete)
        }
        return created
    }

    func putPart(obj: String, part: Int, body: Data, sha256: Data) async throws -> FileV2PutResult {
        let (call, dieAfter) = try enter(.putPart)
        record(part: part, body: body, digest: sha256)
        log.add("server.put.start part=\(part)")
        if shouldSwallow(part) {
            log.add("server.put.swallowed part=\(part)")
            return FileV2PutResult(part: part, duplicate: false, received: 1, parts: 1)
        }
        let result = try await inner.putPart(obj: obj, part: part, body: body, sha256: sha256)
        log.add("server.put.done part=\(part)")
        if dieAfter { throw die(.putPart, call) }
        return result
    }

    private func record(part: Int, body: Data, digest: Data) {
        var tags: [Data] = []
        var offset = 0
        while offset < body.count {
            let length = min(FileV2.stride, body.count - offset)
            tags.append(body.subdata(in: (offset + length - FileV2.tagSize)..<(offset + length)))
            offset += length
        }
        lock.lock()
        let attempt = perPartAttempts[part] ?? 0
        perPartAttempts[part] = attempt + 1
        recordedPuts.append(Put(part: part, digest: digest, chunkTags: tags, firstChunk: part * FileV2Wire.chunksPerPart, attempt: attempt))
        lock.unlock()
    }

    func partsMap(obj: String) async throws -> FileV2PartsMap {
        let (call, dieAfter) = try enter(.partsMap)
        log.add("server.partsMap")
        let map = try await inner.partsMap(obj: obj)
        if dieAfter { throw die(.partsMap, call) }
        return map
    }

    func complete(obj: String) async throws {
        let (call, dieAfter) = try enter(.complete)
        log.add("server.complete")
        try await inner.complete(obj: obj)
        if dieAfter { throw die(.complete, call) }
    }

    func delete(obj: String) async throws {
        let (call, dieAfter) = try enter(.delete)
        log.add("server.delete")
        try await inner.delete(obj: obj)
        if dieAfter { throw die(.delete, call) }
    }

    func issueToken(obj: String, scope: FileV2TokenRequest) async throws -> FileV2IssuedToken {
        let (call, dieAfter) = try enter(.issueToken)
        log.add("server.issueToken")
        let token = try await inner.issueToken(obj: obj, scope: scope)
        if dieAfter { throw die(.issueToken, call) }
        return token
    }

    func listUnfinished(limit: Int?, after: String?) async throws -> FileV2UnfinishedPage {
        let (call, dieAfter) = try enter(.listUnfinished)
        log.add("server.listUnfinished")
        let page = try await inner.listUnfinished(limit: limit, after: after)
        if dieAfter { throw die(.listUnfinished, call) }
        return page
    }

    func deleteUnfinished() async throws -> FileV2BulkDeleteResult {
        _ = try enter(.deleteUnfinished)
        log.add("server.deleteUnfinished")
        return try await inner.deleteUnfinished()
    }

    func fetchRange(obj: String, from: Int64, toInclusive: Int64, token: FileV2DownloadAuth?, waitSeconds: Int) async throws
        -> FileV2RangeResult {
        try await inner.fetchRange(obj: obj, from: from, toInclusive: toInclusive, token: token, waitSeconds: waitSeconds)
    }
}

/// The same server, able to report how many bytes of a part body have left: the pipeline then times a part out on IDLENESS.
final class ReportingServer: RecordingServer, FileV2PartProgressReporting, @unchecked Sendable {
    private let lock2 = NSLock()
    private var stallParts: [Int: Int] = [:]
    private var progressChunks = 4

    /// The next `times` uploads of `part` report no bytes and never finish (until cancelled): a stalled connection.
    func stall(part: Int, times: Int) {
        lock2.lock()
        stallParts[part] = times
        lock2.unlock()
    }

    private func shouldStall(_ part: Int) -> Bool {
        lock2.lock()
        defer { lock2.unlock() }
        guard let left = stallParts[part], left > 0 else { return false }
        stallParts[part] = left - 1
        return true
    }

    func putPart(obj: String, part: Int, body: Data, sha256: Data, progress: @escaping @Sendable (Int) -> Void) async throws
        -> FileV2PutResult {
        if shouldStall(part) {
            if isDead { throw CancellationError() }
            log.add("server.put.stall part=\(part)")
            // No byte moves and the clock does: the idle limit passes while this call sleeps for ever.
            inner.clock.advanceIfManual(ms: 10 * 60_000)
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
            throw CancellationError()
        }
        let step = max(1, body.count / progressChunks)
        var sent = 0
        while sent < body.count {
            let piece = min(step, body.count - sent)
            progress(piece)
            sent += piece
        }
        return try await putPart(obj: obj, part: part, body: body, sha256: sha256)
    }
}

extension FileV2Clock {
    /// Moves a manual clock; a system clock cannot be moved.
    func advanceIfManual(ms: Int64) { (self as? XferManualClock)?.advance(ms: ms) }
}

/// A transfer and everything around it: a store directory, the fake server and its recorder, the chat, the secret wrapper, the clock.
/// `makePipeline` builds a NEW pipeline over the same directory, the same server and the same wrapper, which is what a restart of the
/// process is (the Keychain, the files and the server survive; the memory does not).
final class SendRig: @unchecked Sendable {
    let testCase: XCTestCase
    let root: URL
    let storeDirectory: URL
    let clock = XferManualClock()
    let log = SendEventLog()
    let fake: FakeFileV2Server
    let server: RecordingServer
    let wrapper = FileV2InMemorySecretWrapper()
    let channel: RecordingChannel
    let sleeper: InstantSleeper
    let durability: RecordingDurability
    let telemetry = RecordingTelemetry()
    let sources = TestSourceProvider()
    var configuration: FileV2SendConfiguration
    private var lastStore: InstrumentedStore?
    var refreshAuth: (@Sendable () async -> Bool)?
    /// What the pipeline is told about the device's protected data (`nil`: always available).
    var protectedDataAvailable: (@Sendable () async -> Bool)?

    init(_ testCase: XCTestCase, reporting: Bool = false, realFlush: Bool = false, sleepOfFake: @escaping @Sendable (Int64) async -> Void = FakeFileV2Server.defaultSleep) throws {
        self.testCase = testCase
        root = try FileV2TestSupport.makeTempDirectory(for: testCase)
        storeDirectory = root.appendingPathComponent("send", isDirectory: true)
        fake = FakeFileV2Server(clock: clock, account: "alice", sleep: sleepOfFake)
        server = reporting ? ReportingServer(inner: fake, log: log) : RecordingServer(inner: fake, log: log)
        channel = RecordingChannel(log: log)
        sleeper = InstantSleeper(clock: clock)
        // The pipeline tests do not need the platform to flush for real (the store tests do, and the end-to-end test asks for it): the flush is
        // RECORDED in the log, which is what the ordering assertions read.
        durability = RecordingDurability(log: log, inner: realFlush ? FileV2SystemDurability() : NoopDurability())
        var config = FileV2SendConfiguration()
        config.watchdogPollMs = 5
        config.partIdleTimeoutMs = 600_000
        config.partTotalTimeoutMs = 6_000_000
        config.retryPolicy = FileV2RetryPolicy(maxAttempts: 5, jitter: { _ in 0 })
        configuration = config
    }

    /// A new store instance over the directory (a restart reopens the files).
    func makeStore() throws -> InstrumentedStore {
        let store = InstrumentedStore(inner: try FileV2FileSendStore(directory: storeDirectory, durability: durability), log: log)
        lastStore = store
        return store
    }

    /// A new store instance whose durability is `RecordingDurability` over `inner`, and/or whose protection is `protection`.
    func makeStore(over inner: FileV2Durability, protection: FileV2FileProtection = FileV2SystemFileProtection()) throws -> InstrumentedStore {
        let recording = RecordingDurability(log: log, inner: inner)
        let store = InstrumentedStore(inner: try FileV2FileSendStore(directory: storeDirectory, durability: recording, protection: protection),
                                      log: log)
        lastStore = store
        return store
    }

    func makePipeline(store: FileV2SendStore? = nil) throws -> FileV2SendPipeline {
        let chosen: FileV2SendStore = try store ?? makeStore()
        let deps = FileV2SendDependencies(server: server, store: chosen, secrets: wrapper, sources: sources, channel: channel,
                                          clock: clock, sleeper: sleeper, telemetry: telemetry, refreshAuth: refreshAuth,
                                          protectedDataAvailable: protectedDataAvailable)
        return FileV2SendPipeline(dependencies: deps, configuration: configuration)
    }

    var store: InstrumentedStore? { lastStore }

    func makeRequest(_ source: GeneratedSource, id: String = UUID().uuidString.lowercased(),
                     conversation: FileV2Conversation = .direct(userID: "bob"),
                     metadata: FileV2SendMetadata = FileV2SendMetadata(kind: .file, name: "report.pdf", mimeType: "application/pdf"))
        -> FileV2SendRequest {
        sources.register(source)
        return FileV2SendRequest(transferID: id, source: source, conversation: conversation, metadata: metadata)
    }

    /// The names in the store directory.
    func journalNames() throws -> [String] {
        guard FileManager.default.fileExists(atPath: storeDirectory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: storeDirectory.path).sorted()
    }

    func assertNothingIsLeftBehind(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try journalNames(), [], "no journal is left", file: file, line: line)
        XCTAssertEqual(wrapper.count, 0, "no key or token is left in the secure store", file: file, line: line)
    }
}

/// The states of a transfer, collected in order.
final class StateCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [FileV2SendState] = []

    var sink: FileV2SendStateSink {
        { [self] state in
            lock.lock()
            collected.append(state)
            lock.unlock()
        }
    }

    var states: [FileV2SendState] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }
}
