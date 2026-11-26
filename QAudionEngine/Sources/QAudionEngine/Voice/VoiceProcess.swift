import Foundation

/// What a call needs from the process once the engine is built: the loaded constants and models.
struct VoicePrepared {
    var config: VoiceEngineConfig
    var vad: TimedVadModel
    /// Nil when the speaker model did not load (`model` is then `fail` and nothing is embedded).
    var embedder: VoiceWindowEmbedder?
    var model: VoiceModelStatus
    /// Gives back what the call took from the process (its speech model session). Called once, when the call is over.
    var release: () -> Void = {}
}

/// A call whose result must not be written: the voice was wiped, or the contact was deleted, after the call began.
struct VoiceStaleCall: Error {}

/// Everything the voice check reaches in the process, behind one interface so that the call wiring is tested without models,
/// keychain or files. The real implementation is `VoiceSystemServices`.
protocol VoiceServices: AnyObject {
    /// The process-wide budget; nil until the first successful `prepare` (nothing reports to it before).
    var budget: VoiceCpuBudget? { get }
    /// Counts the wipes. A call remembers the value it started with; a write of a later value is refused inside the store's lock.
    var generation: Int { get }
    /// Loads the bundle, the cohort and the models (once per process). Nil when the check cannot run at all.
    func prepare() -> VoicePrepared?
    /// The signed-in account as the store sees it now (trimmed), or nil when nobody is signed in.
    func currentAccount() -> String?
    /// The record of a contact, or nil. Throws when the store cannot be read now (locked keychain, I/O): the call then runs no check.
    /// Throws `VoiceStaleCall`, before anything is created, when `generation` (read by the caller) is no longer the current one.
    func loadRecord(contactId: String, cfg: VoiceStateConstants, generation: Int) throws -> TemplateRecord?
    /// The tag of a peer device, from the salt of the store. Same refusal for a stale `generation`.
    func deviceTag(deviceId: String, generation: Int) throws -> Int
    /// The one locked operation of a contact: load, `body`, write. Throws `VoiceStaleCall` before `body` runs when `generation` is not
    /// the current one, or when the signed-in account is not `account` (the one the call started with); the checks are made inside the
    /// lock of the store.
    func update(contactId: String, cfg: VoiceStateConstants, generation: Int, account: String,
                _ body: (TemplateRecord?) throws -> TemplateRecord?) throws
    /// Deletes the contact's record under the same lock. Nothing happens when the store has no data. Throws `VoiceStaleCall` when
    /// `generation` is stale (a wipe came first: nothing is left to delete).
    func deleteRecord(contactId: String, generation: Int) throws
    /// Deletes every record, `meta.bin` and the key, and moves `generation` on. Throws when something is left.
    func wipeAll() throws
    /// A call that used the models is over: the services may let go of them when no other call uses them.
    func callFinished()
    /// What the owner sees of the learned voices of `contactIds`. Reads only: never creates a store, a file or a key. Throws
    /// `VoiceStaleCall` when `generation` is not the current one.
    func summaries(contactIds: [String], generation: Int) throws -> [String: ContactVoiceSummary]
    /// Deletes the records of contacts that are not in `knownContactIds`. Never creates `meta.bin` or the key; nothing happens
    /// without data, and a stale `generation` throws `VoiceStaleCall`.
    func deleteOrphans(knownContactIds: [String], directorySynced: Bool, generation: Int) throws -> Int
    /// True when at least one learned voice record exists on this device (reads the directory only).
    func hasRecords() -> Bool
}

extension VoiceServices {
    func summaries(contactIds: [String], generation: Int) throws -> [String: ContactVoiceSummary] { [:] }
    func deleteOrphans(knownContactIds: [String], directorySynced: Bool, generation: Int) throws -> Int { 0 }
    func hasRecords() -> Bool { false }
}

/// The background-execution assertion of the post-call work (the app provides the UIKit one).
protocol VoiceBackgroundTasks: AnyObject {
    /// Returns a token to give back to `end`, or nil when the system gave no time.
    func begin(name: String, onExpiration: @escaping () -> Void) -> Int?
    func end(_ token: Int)
}

final class VoiceNoBackgroundTasks: VoiceBackgroundTasks {
    func begin(name: String, onExpiration: @escaping () -> Void) -> Int? { nil }
    func end(_ token: Int) {}
}

/// The state of the voice check that the whole process shares: one budget, one store, the models, the calls that may still be doing
/// post-call work, the log sink and the daily counters. It is created without touching anything; every access happens after the
/// flag was read (a deletion or a wipe reaches the store whatever the flag says, and does nothing when there is no data).
final class VoiceProcess: @unchecked Sendable {
    static let shared = VoiceProcess(services: VoiceSystemServices())

    let services: VoiceServices
    let daily: VoiceDailyCounters
    private let lock = NSLock()
    private var sessions: [ObjectIdentifier: Weak] = [:]
    private var tasks: VoiceBackgroundTasks = VoiceNoBackgroundTasks()
    private var logSink: ((String) -> Void)?
    private var diagLines: () -> Bool = { false }
    private var displayHandler: ((VoiceCheckDisplay?) -> Void)?
    private var ownerOnProvider: () -> Bool = { false }
    private var ownerTemplateProvider: () -> [Float]? = { nil }
    private var entitledProvider: () -> Bool = { false }
    private let maintenance = DispatchQueue(label: "com.bcrypto.qaudion.voice.maintenance", qos: .utility)

    private final class Weak {
        weak var session: VoiceCallSession?
        init(_ session: VoiceCallSession) { self.session = session }
    }

    init(services: VoiceServices, daily: VoiceDailyCounters = VoiceDailyCounters()) {
        self.services = services
        self.daily = daily
    }

    /// The account of the signed-in user (the store belongs to it). Set once by the app at launch, process-wide: it does not depend on
    /// a call or on any object that a call creates. Called from background queues; it must not wait for the main thread.
    var accountIdProvider: (() -> String?)? {
        get { VoiceAccountSource.shared.provider }
        set { VoiceAccountSource.shared.provider = newValue }
    }

    var backgroundTasks: VoiceBackgroundTasks {
        get {
            lock.lock()
            defer { lock.unlock() }
            return tasks
        }
        set {
            lock.lock()
            tasks = newValue
            lock.unlock()
        }
    }

    /// Where the lines of the log go, and whether the per-call lines are written for this account (`voice.diag_lines`).
    func setLogging(sink: @escaping (String) -> Void, diagLinesEnabled: @escaping () -> Bool) {
        lock.lock()
        logSink = sink
        diagLines = diagLinesEnabled
        lock.unlock()
    }

    /// The owner choice together with the entitlement (what a call reads once, at its start), and the enrolled voice template of
    /// the owner for the diagnostic counter only. Until the app installs them the check is off.
    func setOwnerPolicy(ownerOn: @escaping () -> Bool, ownerTemplate: @escaping () -> [Float]?, available: @escaping () -> Bool = { false }) {
        lock.lock()
        entitledProvider = available
        ownerOnProvider = ownerOn
        ownerTemplateProvider = ownerTemplate
        lock.unlock()
    }

    /// True when the check is available to this account (the entitlement): an owner who turned the setting off then sees "Off for this
    /// call"; an account without it sees no card at all.
    var checkAvailable: Bool {
        lock.lock()
        let read = entitledProvider
        lock.unlock()
        return read()
    }

    var ownerOn: Bool {
        lock.lock()
        let read = ownerOnProvider
        lock.unlock()
        return read()
    }

    func ownerTemplate() -> [Float]? {
        lock.lock()
        let read = ownerTemplateProvider
        lock.unlock()
        return read()
    }

    func setDisplayHandler(_ handler: @escaping (VoiceCheckDisplay?) -> Void) {
        lock.lock()
        displayHandler = handler
        lock.unlock()
    }

    /// A per-call line: written only for an account that has the diagnostic flag. The line has a call number and no other id.
    func emitCallLine(_ line: String) {
        lock.lock()
        let sink = logSink
        let allowed = diagLines
        lock.unlock()
        if let sink, allowed() { sink(line) }
    }

    /// A daily counter line: written whenever the engine runs, whatever the flag says. It has no id of any kind.
    func emitDailyLine(_ line: String) {
        lock.lock()
        let sink = logSink
        lock.unlock()
        sink?(line)
    }

    func showDisplay(_ display: VoiceCheckDisplay?) {
        lock.lock()
        let handler = displayHandler
        lock.unlock()
        handler?(display)
    }

    /// A call starts: a session for it, or nil while the flag is off (then nothing at all is created).
    func beginCall(_ binding: VoiceCallBinding) -> VoiceCallSession? {
        guard VoiceFeature.isEnabled else { return nil }
        let session = VoiceCallSession(binding: binding, process: self)
        lock.lock()
        sessions[ObjectIdentifier(session)] = Weak(session)
        lock.unlock()
        return session
    }

    func forget(_ session: VoiceCallSession) {
        lock.lock()
        sessions.removeValue(forKey: ObjectIdentifier(session))
        lock.unlock()
    }

    private func liveSessions() -> [VoiceCallSession] {
        lock.lock()
        defer { lock.unlock() }
        return sessions.values.compactMap { $0.session }
    }

    /// True while a call has a session that has not finished (running, or doing its post-call work).
    var hasLiveSession: Bool { !liveSessions().isEmpty }

    /// A call, incoming or outgoing, starts: the post-call work of every earlier call is cancelled, never resumed. It reaches
    /// the work that is running and the work that has not started yet. With the flag off there is nothing to cancel and nothing
    /// is touched.
    func cancelPostCallWork() {
        for s in liveSessions() { s.requestPostCancel() }
    }

    /// The busy time of another voice model of the process (the owner monitor, the call integrity monitor): to the budget that the
    /// engine reads. Nothing is reported while the check is off or the budget does not exist yet.
    func reportBusy(who: String, startNs: Int64, endNs: Int64) {
        guard VoiceFeature.isEnabled, let budget = services.budget else { return }
        budget.add(who: who, startNs: startNs, endNs: endNs)
    }

    // MARK: deletion and wipe

    /// The contact was deleted or blocked: the calls with it write nothing any more, and its record is deleted (on a background
    /// queue: the store blocks on files and the keychain). `done` tells whether the deletion worked.
    func forgetContact(_ contactId: String, done: ((Bool) -> Void)? = nil) {
        for s in liveSessions() where s.binding.contactId.lowercased() == contactId.lowercased() { s.discardResult() }
        // Read now: a wipe that comes before the deletion runs has already removed the record.
        let generation = services.generation
        maintenance.async { [self] in
            var ok = true
            do {
                try services.deleteRecord(contactId: contactId, generation: generation)
            } catch is VoiceStaleCall {
                // a wipe came first: nothing of this contact is left
            } catch {
                ok = false
                emitCallLine("QA-VOICE v=1 ev=store call=- op=delete res=fail why=contact")
            }
            done?(ok)
        }
    }

    /// The wipe of everything of the contact voice on this device: every running or post-call engine is stopped and discarded first,
    /// then the records, `meta.bin` and the key are deleted under the store's lock, and the daily counters are forgotten. False
    /// when something is left: a failure is never swallowed.
    func wipeAll(why: String = "account") -> Bool {
        for s in liveSessions() { s.discardAll() }
        var ok = true
        do {
            try services.wipeAll()
        } catch {
            ok = false
        }
        daily.wipe()
        showDisplay(nil)
        emitCallLine("QA-VOICE v=1 ev=store call=- op=wipe res=\(ok ? "ok" : "fail") why=\(why)")
        return ok
    }

    /// What the owner sees of the learned voices of `contactIds` (blocking: call it from a background queue). Reads only.
    func summaries(contactIds: [String]) -> [String: ContactVoiceSummary] {
        let generation = services.generation
        return (try? services.summaries(contactIds: contactIds, generation: generation)) ?? [:]
    }

    /// The contact list was synced: the records of contacts that are no longer in it are deleted. Does nothing for a list that is
    /// empty or not yet synced, and never creates `meta.bin` or the key.
    func sweepOrphans(knownContactIds: [String], directorySynced: Bool, done: ((Int) -> Void)? = nil) {
        let generation = services.generation
        maintenance.async { [self] in
            let n = (try? services.deleteOrphans(knownContactIds: knownContactIds, directorySynced: directorySynced, generation: generation)) ?? 0
            done?(n)
        }
    }
}

/// The reporting of the other models of the process, from where they run.
enum VoiceBusy {
    /// Runs `work`, and reports its time to the budget when the check is on.
    @discardableResult
    static func measure<T>(_ who: String, _ work: () -> T) -> T {
        guard VoiceFeature.isEnabled else { return work() }
        let started = VoiceClock.nowNs()
        let result = work()
        VoiceProcess.shared.reportBusy(who: who, startNs: started, endNs: VoiceClock.nowNs())
        return result
    }
}

/// Where the whole process reads the signed-in account from: one provider, installed by the app at launch. A store is never
/// created without an account.
final class VoiceAccountSource: @unchecked Sendable {
    static let shared = VoiceAccountSource()

    private let lock = NSLock()
    private var providerValue: (() -> String?)?

    var provider: (() -> String?)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return providerValue
        }
        set {
            lock.lock()
            providerValue = newValue
            lock.unlock()
        }
    }

    /// The trimmed account, or nil (nobody signed in, or no provider). The provider runs outside the lock.
    func current() -> String? {
        let trimmed = provider?()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The real services: the bundle and the models are loaded on the first call that needs them and let go when the last one ends;
/// the store and its key are created once per account, never for an empty one.
final class VoiceSystemServices: VoiceServices, @unchecked Sendable {
    /// Speech-model sessions kept for the next call (one per overlapping engine; the rest are let go).
    private static let vadPoolLimit = 2

    private let lock = NSLock()
    private var budgetValue: VoiceCpuBudget?
    private var bundle: VoiceBundle?
    private var cohort: VoiceCohort?
    private var vadPool: [SileroVadRunner] = []
    private var embedder: OrtCamPlusEmbedder?
    private var embedderTried = false
    private var users = 0
    private var store: VoiceTemplateStore?
    private var storeAccount: String?
    private var generationValue = 0

    var budget: VoiceCpuBudget? {
        lock.lock()
        defer { lock.unlock() }
        return budgetValue
    }

    var generation: Int {
        lock.lock()
        defer { lock.unlock() }
        return generationValue
    }

    func prepare() -> VoicePrepared? {
        lock.lock()
        defer { lock.unlock() }
        do {
            let b: VoiceBundle
            if let loaded = bundle {
                b = loaded
            } else {
                b = try VoiceBundle.loadFromModule()
                bundle = b
            }
            let c: VoiceCohort
            if let loaded = cohort {
                c = loaded
            } else {
                c = try VoiceCohort.parse(try Data(contentsOf: b.cohortURL), constants: b.scoring.cohort)
                cohort = c
            }
            // One speech-model session for each engine that runs at the same time (a call can start while the post-call work of
            // the one before is still finishing): taken from the pool, or made, and given back when the call is over.
            let runner: SileroVadRunner
            if let pooled = vadPool.popLast() {
                runner = pooled
            } else {
                runner = try SileroVadRunner(modelURL: b.vadModelURL)
            }
            if budgetValue == nil {
                budgetValue = VoiceCpuBudget(cpu: b.engine.cpu)
            }
            if !embedderTried {
                embedderTried = true
                if let url = Bundle.module.url(forResource: "campplus_sv_voxceleb_16k", withExtension: "onnx") {
                    embedder = try? OrtCamPlusEmbedder.load(modelURL: url, expectedSha256: b.scoring.model.embedderSha256)
                }
            }
            users += 1
            let config = VoiceEngineConfig(bundle: b, cohort: c)
            var adapter: VoiceWindowEmbedder?
            if let model = embedder {
                adapter = CamPlusWindowEmbedder(fbank: VoiceFbank(tables: b.tables, constants: b.constants.fbank), model: model)
            }
            return VoicePrepared(
                config: config, vad: TimedSileroVad(runner), embedder: adapter, model: adapter == nil ? .fail : .ok,
                release: { [weak self] in self?.giveBack(runner) })
        } catch {
            return nil
        }
    }

    private func giveBack(_ runner: SileroVadRunner) {
        lock.lock()
        if vadPool.count < Self.vadPoolLimit { vadPool.append(runner) }
        lock.unlock()
    }

    func callFinished() {
        lock.lock()
        defer { lock.unlock() }
        users = max(0, users - 1)
        if users == 0 {
            // No call uses the models: they are not kept in memory between calls.
            embedder?.close()
            embedder = nil
            embedderTried = false
            vadPool.removeAll()
        }
    }

    private static func directory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            .map { VoiceTemplateStore.directoryFor(applicationSupport: $0) }
    }

    /// The store of the signed-in account: one instance (with one key cache) for the process, rebuilt when the account changes and
    /// never made for an account that is empty or unknown. Refuses with `VoiceStaleCall`, under the lock and before anything is
    /// made, when `generation` (read by the caller) is not the current one or the account is not `account`.
    private func theStore(generation expected: Int, account expectedAccount: String? = nil) throws -> VoiceTemplateStore {
        // The provider reads the keychain: outside the lock.
        guard let account = VoiceAccountSource.shared.current() else { throw VoiceStoreError(.key, "no account") }
        lock.lock()
        defer { lock.unlock() }
        guard generationValue == expected else { throw VoiceStaleCall() }
        if let expectedAccount, expectedAccount != account { throw VoiceStaleCall() }
        if let s = store, storeAccount == account { return s }
        guard let dir = Self.directory() else { throw VoiceStoreError(.io, "no application support directory") }
        let aead = VoiceKeychainAead(dataExists: { try VoiceTemplateStore.dataExists(in: dir) })
        let fresh = VoiceTemplateStore(
            dir: dir, aead: aead, accountId: account, generationProbe: { [weak self] in self?.generation ?? -1 })
        store = fresh
        storeAccount = account
        return fresh
    }

    func currentAccount() -> String? {
        VoiceAccountSource.shared.current()
    }

    func loadRecord(contactId: String, cfg: VoiceStateConstants, generation expected: Int) throws -> TemplateRecord? {
        try theStore(generation: expected).loadCompatible(contactId, cfg, generation: expected)
    }

    func deviceTag(deviceId: String, generation expected: Int) throws -> Int {
        VoiceTags.deviceTag(nameSalt: try theStore(generation: expected).nameSalt(generation: expected), deviceId: deviceId)
    }

    func update(contactId: String, cfg: VoiceStateConstants, generation expected: Int, account: String,
                _ body: (TemplateRecord?) throws -> TemplateRecord?) throws {
        // Before the store is touched at all: a call that began before a wipe, or under another account, creates nothing.
        try theStore(generation: expected, account: account).update(
            contactId: contactId, compatibleWith: cfg, generation: expected
        ) { loaded in
            // Inside the lock of the store: a wipe that moved the generation on cannot be followed by this write.
            guard self.generation == expected else { throw VoiceStaleCall() }
            return try body(loaded)
        }
    }

    func deleteRecord(contactId: String, generation expected: Int) throws {
        // Nothing on disk: nothing to delete, and nothing is read from the keychain.
        if let dir = Self.directory(), let exists = try? VoiceTemplateStore.dataExists(in: dir), !exists { return }
        _ = try theStore(generation: expected).delete(contactId, generation: expected)
    }

    func summaries(contactIds: [String], generation expected: Int) throws -> [String: ContactVoiceSummary] {
        // Nothing on disk: nothing to read, and no store is looked at.
        guard let dir = Self.directory(), (try? VoiceTemplateStore.dataExists(in: dir)) == true else { return [:] }
        lock.lock()
        let loaded: VoiceBundle?
        if let b = bundle {
            loaded = b
        } else {
            loaded = try? VoiceBundle.loadFromModule()
            bundle = loaded
        }
        lock.unlock()
        guard let cfg = loaded?.state else { return [:] }
        return try theStore(generation: expected).summaries(contactIds: contactIds, cfg: cfg, generation: expected)
    }

    func hasRecords() -> Bool {
        guard let dir = Self.directory() else { return false }
        return (try? VoiceTemplateStore.recordsExist(in: dir)) ?? false
    }

    func deleteOrphans(knownContactIds: [String], directorySynced: Bool, generation expected: Int) throws -> Int {
        guard directorySynced, !knownContactIds.isEmpty else { return 0 }
        guard let dir = Self.directory(), (try? VoiceTemplateStore.dataExists(in: dir)) == true else { return 0 }
        return try theStore(generation: expected).deleteOrphans(
            knownContactIds: knownContactIds, directorySynced: directorySynced, generation: expected)
    }

    func wipeAll() throws {
        lock.lock()
        generationValue += 1
        let existing = store
        store = nil
        storeAccount = nil
        lock.unlock()
        guard let dir = Self.directory() else { throw VoiceStoreError(.io, "no application support directory") }
        // The process instance when there is one; otherwise a store made only to wipe (it reads and writes nothing, so the account
        // it carries does not matter).
        let target = existing ?? VoiceTemplateStore(
            dir: dir, aead: VoiceKeychainAead(dataExists: { try VoiceTemplateStore.dataExists(in: dir) }), accountId: "")
        try target.wipeAll()
        if target.recordCount() != 0 { throw VoiceStoreError(.io, "records left after the wipe") }
    }
}
