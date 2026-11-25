import Foundation

/// What a call needs from the process once the engine is built: the loaded constants and models.
struct VoicePrepared {
    var config: VoiceEngineConfig
    var vad: TimedVadModel
    /// Nil when the speaker model did not load (`model` is then `fail` and nothing is embedded).
    var embedder: VoiceWindowEmbedder?
    var model: VoiceModelStatus
}

/// Everything the voice check reaches in the process, behind one interface so that the call wiring is tested without models,
/// keychain or files. The real implementation is `VoiceSystemServices`.
protocol VoiceServices: AnyObject {
    /// The process-wide budget; nil until the first successful `prepare` (nothing reports to it before).
    var budget: VoiceCpuBudget? { get }
    /// Loads the bundle, the cohort and the models (once per process). Nil when the check cannot run at all.
    func prepare() -> VoicePrepared?
    /// The record of a contact, or nil. Throws when the store cannot be read now (locked keychain, I/O): the call then runs no check.
    func loadRecord(contactId: String, cfg: VoiceStateConstants) throws -> TemplateRecord?
    /// The tag of a peer device, from the salt of the store.
    func deviceTag(deviceId: String) throws -> Int
    /// The one locked operation of a contact: load, `body`, write.
    func update(contactId: String, cfg: VoiceStateConstants, _ body: (TemplateRecord?) throws -> TemplateRecord?) throws
    /// Deletes the contact's record under the same lock.
    func deleteRecord(contactId: String) throws
    /// A call that used the models is over: the services may let go of them when no other call uses them.
    func callFinished()
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

/// The state of the voice check that the whole process shares: one budget, one store, the models, and the calls that may still be
/// doing post-call work. It is created without touching anything; every access happens after the flag was read.
final class VoiceProcess: @unchecked Sendable {
    static let shared = VoiceProcess(services: VoiceSystemServices())

    let services: VoiceServices
    private let lock = NSLock()
    private var sessions: [ObjectIdentifier: Weak] = [:]
    private var tasks: VoiceBackgroundTasks = VoiceNoBackgroundTasks()

    private final class Weak {
        weak var session: VoiceCallSession?
        init(_ session: VoiceCallSession) { self.session = session }
    }

    init(services: VoiceServices) {
        self.services = services
    }

    /// The account of the signed-in user (the store belongs to it). Set once by the app; read when the store is first used.
    var accountIdProvider: (() -> String?)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return (services as? VoiceSystemServices)?.accountIdProvider
        }
        set {
            lock.lock()
            (services as? VoiceSystemServices)?.accountIdProvider = newValue
            lock.unlock()
        }
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

    /// A call, incoming or outgoing, starts: the post-call work of every earlier call is cancelled, never resumed. It reaches
    /// the work that is running and the work that has not started yet. With the flag off there is nothing to cancel and nothing
    /// is touched.
    func cancelPostCallWork() {
        lock.lock()
        let live = sessions.values.compactMap { $0.session }
        lock.unlock()
        for s in live { s.requestPostCancel() }
    }

    /// The busy time of another voice model of the process (the owner monitor, the call integrity monitor): to the budget that the
    /// engine reads. Nothing is reported while the check is off or the budget does not exist yet.
    func reportBusy(who: String, startNs: Int64, endNs: Int64) {
        guard VoiceFeature.isEnabled, let budget = services.budget else { return }
        budget.add(who: who, startNs: startNs, endNs: endNs)
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

/// The real services: the bundle and the models are loaded on the first call that needs them and let go when the last one ends;
/// the store and its key are created once per account.
final class VoiceSystemServices: VoiceServices, @unchecked Sendable {
    var accountIdProvider: (() -> String?)?

    private let lock = NSLock()
    private var budgetValue: VoiceCpuBudget?
    private var bundle: VoiceBundle?
    private var cohort: VoiceCohort?
    private var vadRunner: SileroVadRunner?
    private var embedder: OrtCamPlusEmbedder?
    private var embedderTried = false
    private var users = 0
    private var store: VoiceTemplateStore?
    private var storeAccount: String?

    var budget: VoiceCpuBudget? {
        lock.lock()
        defer { lock.unlock() }
        return budgetValue
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
            let runner: SileroVadRunner
            if let loaded = vadRunner {
                runner = loaded
            } else {
                runner = try SileroVadRunner(modelURL: b.vadModelURL)
                vadRunner = runner
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
                config: config, vad: TimedSileroVad(runner), embedder: adapter, model: adapter == nil ? .fail : .ok)
        } catch {
            return nil
        }
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
            vadRunner = nil
        }
    }

    private func theStore() throws -> VoiceTemplateStore {
        lock.lock()
        defer { lock.unlock() }
        guard let account = accountIdProvider?(), !account.isEmpty else { throw VoiceStoreError(.key, "no account") }
        if let s = store, storeAccount == account { return s }
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw VoiceStoreError(.io, "no application support directory")
        }
        let dir = VoiceTemplateStore.directoryFor(applicationSupport: support)
        let aead = VoiceKeychainAead(dataExists: { try VoiceTemplateStore.dataExists(in: dir) })
        let fresh = VoiceTemplateStore(dir: dir, aead: aead, accountId: account)
        store = fresh
        storeAccount = account
        return fresh
    }

    func loadRecord(contactId: String, cfg: VoiceStateConstants) throws -> TemplateRecord? {
        try theStore().loadCompatible(contactId, cfg)
    }

    func deviceTag(deviceId: String) throws -> Int {
        VoiceTags.deviceTag(nameSalt: try theStore().nameSalt(), deviceId: deviceId)
    }

    func update(contactId: String, cfg: VoiceStateConstants, _ body: (TemplateRecord?) throws -> TemplateRecord?) throws {
        try theStore().update(contactId: contactId, compatibleWith: cfg, body)
    }

    func deleteRecord(contactId: String) throws {
        _ = try theStore().delete(contactId)
    }
}
