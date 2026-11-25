import XCTest
import Foundation
@testable import QAudionEngine

/// A wipe that lands while a call's engine is starting: the session passed its checks and loads the models, the wipe discards it
/// and moves the generation on, then the start goes on. The account can still be readable at that moment (the account deletion
/// paths run `LocalCryptoWipe.wipeAll()` before `clearToken()`). The real store is used, with a key vault in memory.
final class VoiceWipeDuringStartProofTests: XCTestCase {
    override func setUp() {
        super.setUp()
        VoiceFeature.setProvider { true }
    }

    override func tearDown() {
        VoiceFeature.reset()
        super.tearDown()
    }

    private final class StubVad: TimedVadModel {
        var lastCostNs: Int64 { 1_000 }
        func reset() {}
        func step(_ chunk: [Float]) throws -> Float { 0 }
    }

    private final class MemoryDaily: VoiceDailyStorage {
        var data: Data?
        func load() -> Data? { data }
        func save(_ newData: Data) { data = newData }
        func clear() { data = nil }
    }

    /// The wipe generation, shared by the services and the probe of the store.
    private final class Generation: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var current: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        func bump() {
            lock.lock()
            value += 1
            lock.unlock()
        }
    }

    /// The services of the process over a real store (temporary folder, key vault in memory), with the same generation rule as
    /// `VoiceSystemServices`: an operation that carries the current generation goes to the store. `prepare` waits until the test
    /// lets it go, the way the first call of a run waits for its models.
    private final class StoreServices: VoiceServices {
        let config: VoiceEngineConfig
        let vault: VoiceMemoryVault
        let store: VoiceTemplateStore
        let inPrepare = DispatchSemaphore(value: 0)
        let goOn = DispatchSemaphore(value: 0)
        private let gen: Generation
        private let lock = NSLock()
        private var budgetValue: VoiceCpuBudget?

        init(config: VoiceEngineConfig, dir: URL) {
            let v = VoiceMemoryVault()
            let g = Generation()
            self.config = config
            self.vault = v
            self.gen = g
            self.store = VoiceTemplateStore(
                dir: dir, aead: VoiceKeychainAead(dataExists: { try VoiceTemplateStore.dataExists(in: dir) }, vault: v, sleep: { _ in }),
                accountId: "acct", dirSync: VoiceDirectorySyncs.none, generationProbe: { g.current })
        }

        var budget: VoiceCpuBudget? {
            lock.lock()
            defer { lock.unlock() }
            return budgetValue
        }

        var generation: Int { gen.current }

        func prepare() -> VoicePrepared? {
            inPrepare.signal()
            _ = goOn.wait(timeout: .now() + 20)
            lock.lock()
            if budgetValue == nil { budgetValue = VoiceCpuBudget(cpu: config.engine.cpu) }
            lock.unlock()
            return VoicePrepared(config: config, vad: StubVad(), embedder: nil, model: .fail)
        }

        func currentAccount() -> String? { "acct" }

        func loadRecord(contactId: String, cfg: VoiceStateConstants, generation: Int) throws -> TemplateRecord? {
            guard generation == gen.current else { throw VoiceStaleCall() }
            return try store.loadCompatible(contactId, cfg, generation: generation)
        }

        func deviceTag(deviceId: String, generation: Int) throws -> Int {
            guard generation == gen.current else { throw VoiceStaleCall() }
            return VoiceTags.deviceTag(nameSalt: try store.nameSalt(generation: generation), deviceId: deviceId)
        }

        func update(contactId: String, cfg: VoiceStateConstants, generation: Int, account: String,
                    _ body: (TemplateRecord?) throws -> TemplateRecord?) throws {
            guard generation == gen.current else { throw VoiceStaleCall() }
            try store.update(contactId: contactId, compatibleWith: cfg, generation: generation, body)
        }

        func deleteRecord(contactId: String, generation: Int) throws {
            guard generation == gen.current else { throw VoiceStaleCall() }
            _ = try store.delete(contactId, generation: generation)
        }

        func wipeAll() throws {
            gen.bump()
            try store.wipeAll()
        }

        func callFinished() {}
    }

    func testASessionThatAWipeDiscardedWhileItsModelsLoadCreatesNoMetaAndNoKey() throws {
        let dir = try VoiceStoreFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let services = StoreServices(config: VoiceEngineConfig(bundle: try VoiceKat.bundle(), cohort: try VoiceScoringKat.cohort()), dir: dir)
        let process = VoiceProcess(services: services, daily: VoiceDailyCounters(storage: MemoryDaily(), random: { 0 }))
        let session = try XCTUnwrap(process.beginCall(VoiceCallBinding(
            callId: "5a000000-0000-4000-8000-000000000000", contactId: "contact-1", peerDeviceId: "dev-1",
            tStartS: 1_800_000_000, utcOffsetS: 0)))
        session.mediaStart()
        XCTAssertEqual(services.inPrepare.wait(timeout: .now() + 20), .success, "precondition: the start passed its checks")
        // LocalCryptoWipe meanwhile, on another thread.
        XCTAssertTrue(process.wipeAll(), "precondition: the wipe reports that nothing is left")
        XCTAssertFalse(try VoiceTemplateStore.dataExists(in: dir), "precondition: nothing on disk after the wipe")
        services.goOn.signal()
        session.withEngine { _ in } // the start ran to its end
        session.withEngine { _ in } // and the finish that the wipe queued
        XCTAssertFalse(try VoiceTemplateStore.dataExists(in: dir),
                       "a session that the wipe had discarded created meta.bin after the wipe")
        XCTAssertEqual(services.vault.addCount, 0, "a session that the wipe had discarded created a key after the wipe")
    }
}
