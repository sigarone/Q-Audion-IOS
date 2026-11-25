import XCTest
import Foundation
@testable import QAudionEngine

/// The store of the contact-voice check finds the signed-in account through one process-level provider that the app installs at
/// launch (`VoiceCallWiring.setAccountProvider`). It does not depend on a call: the post-call write of a call and the deletion of a
/// contact outside a call happen when the integration of the call is gone, or before any call of the run. These tests also check
/// that every entry point of the store refuses, before it creates `meta.bin`, the key or a file, once a wipe has moved on.
final class VoiceStoreAccountTests: XCTestCase {
    private static let noAccount = VoiceStoreError(.key, "no account")
    private var planted: [URL] = []
    private var savedProvider: (() -> String?)?

    override func setUp() {
        super.setUp()
        savedProvider = VoiceProcess.shared.accountIdProvider
        // What the app does at launch.
        VoiceCallWiring.setAccountProvider { "acct-proof" }
        wipeTheRealStore()
    }

    override func tearDown() {
        for url in planted { try? FileManager.default.removeItem(at: url) }
        planted = []
        wipeTheRealStore()
        VoiceProcess.shared.accountIdProvider = savedProvider
        super.tearDown()
    }

    /// The folder of the store, found the way `VoiceSystemServices` finds it.
    private func storeDirectory() throws -> URL {
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        return VoiceTemplateStore.directoryFor(applicationSupport: support)
    }

    /// Leaves the folder and the key as they were before any test (a services object made only to wipe).
    private func wipeTheRealStore() {
        try? VoiceSystemServices().wipeAll()
    }

    /// A record file left by a call of an earlier run of the app. Its bytes do not matter: the deletion only has to see data.
    private func plantRecordOfAnEarlierRun() throws {
        let dir = try storeDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("proof-\(UUID().uuidString)" + VoiceTemplateStore.ext)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data([1, 2, 3])))
        planted.append(url)
        XCTAssertTrue(try VoiceTemplateStore.dataExists(in: dir), "precondition: the store folder has data")
    }

    private func assertNoDataOnDisk(_ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(try VoiceTemplateStore.dataExists(in: try storeDirectory()), message, file: file, line: line)
    }

    /// Builds a call's integration with its own resolver, then lets it go as the end of a call does. Returns false when the
    /// integration did not go away within 10 s (the test then cannot say anything).
    private func runAndEndACall(resolver: @escaping () -> String) -> Bool {
        weak var gone: QAudionCallIntegration?
        do {
            let integration = QAudionCallIntegration()
            integration.resolveVoiceAccountId = resolver
            gone = integration
        }
        let deadline = Date().addingTimeInterval(10)
        while gone != nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return gone == nil
    }

    // MARK: the account

    /// The finalizer of `VoiceCallSession` (load, end of call, save) runs on the session's queue after `callEnded`; the end of the
    /// call releases the call's integration on the main thread meanwhile. The account must still be known, or the record of the
    /// call is never written.
    func testThePostCallWriteStillHasTheAccountAfterTheCallsIntegrationIsReleased() throws {
        XCTAssertTrue(runAndEndACall(resolver: { "another-account" }), "precondition: the integration of the call is released")
        XCTAssertEqual(VoiceProcess.shared.accountIdProvider?(), "acct-proof",
                       "after the call the store of the process has no account any more")
        let services = VoiceProcess.shared.services
        XCTAssertEqual(services.currentAccount(), "acct-proof")
        let cfg = try VoiceKat.bundle().state
        do {
            try services.update(contactId: "contact-proof", cfg: cfg, generation: services.generation, account: "acct-proof") { $0 }
        } catch let error as VoiceStoreError {
            XCTAssertNotEqual(error, Self.noAccount, "the post-call write of the record failed for want of an account")
        } catch {}
    }

    /// A call's integration no longer installs the provider of the store: building one changes nothing.
    func testBuildingACallsIntegrationDoesNotReplaceTheProviderOfTheProcess() {
        VoiceProcess.shared.accountIdProvider = nil
        XCTAssertTrue(runAndEndACall(resolver: { "from-the-integration" }))
        XCTAssertNil(VoiceProcess.shared.accountIdProvider, "the integration must not install a provider")
        VoiceCallWiring.setAccountProvider { "acct-proof" }
        let integration = QAudionCallIntegration()
        integration.resolveVoiceAccountId = { "from-the-integration" }
        XCTAssertEqual(VoiceProcess.shared.accountIdProvider?(), "acct-proof")
    }

    /// `VoiceCallWiring.contactRemoved` "works before any call of the process": a contact deleted or blocked right after the app
    /// starts, with a record from a call of an earlier run on the phone. The services of a process that has not built a call's
    /// integration yet find the account through the provider of the process.
    func testADeletionBeforeTheFirstCallOfTheRunDeletesTheRecord() throws {
        try plantRecordOfAnEarlierRun()
        let services = VoiceSystemServices()
        do {
            try services.deleteRecord(contactId: "contact-proof", generation: services.generation)
        } catch let error as VoiceStoreError {
            // A test host without a usable keychain may fail here; what must not happen is a refusal for want of an account.
            XCTAssertNotEqual(error, Self.noAccount,
                              "the deletion of the contact failed for want of an account: the learned voice of the deleted contact stays")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: planted[0].path),
                       "the planted record of the earlier run is still on disk after the deletion")
    }

    /// Logged out: the provider answers nil, the store refuses and creates nothing.
    func testWithNobodySignedInTheStoreRefusesAndCreatesNothing() throws {
        VoiceCallWiring.setAccountProvider { nil }
        let services = VoiceSystemServices()
        let cfg = try VoiceKat.bundle().state
        XCTAssertNil(services.currentAccount())
        XCTAssertThrowsError(try services.loadRecord(contactId: "c", cfg: cfg, generation: services.generation)) {
            XCTAssertEqual($0 as? VoiceStoreError, Self.noAccount)
        }
        XCTAssertThrowsError(try services.deviceTag(deviceId: "d", generation: services.generation))
        VoiceCallWiring.setAccountProvider { "  " }
        XCTAssertNil(services.currentAccount(), "a blank account is no account")
        try assertNoDataOnDisk("nothing is created for nobody")
    }

    /// The call began under account A; account B is signed in when its post-call write runs: nothing of A is written into B's store.
    func testTheWriteOfACallStartedUnderAnotherAccountIsRefusedAndCreatesNothing() throws {
        VoiceCallWiring.setAccountProvider { "acct-B" }
        let services = VoiceSystemServices()
        let cfg = try VoiceKat.bundle().state
        var bodyRan = false
        XCTAssertThrowsError(
            try services.update(contactId: "c", cfg: cfg, generation: services.generation, account: "acct-A") { loaded in
                bodyRan = true
                return loaded
            }
        ) { XCTAssertTrue($0 is VoiceStaleCall) }
        XCTAssertFalse(bodyRan)
        try assertNoDataOnDisk("no store, no meta.bin and no key were made for the refused write")
    }

    // MARK: the wipe generation

    /// An operation read the generation, a wipe ran, the operation goes on: the store refuses before it creates anything.
    func testEveryEntryPointOfAnEarlierGenerationCreatesNothingAfterAWipe() throws {
        let services = VoiceSystemServices()
        let cfg = try VoiceKat.bundle().state
        let read = services.generation
        _ = try? services.wipeAll() // the wipe moves the generation on whatever the keychain says
        XCTAssertNotEqual(services.generation, read)
        func stale(_ what: String, _ body: @escaping () throws -> Void, line: UInt = #line) {
            XCTAssertThrowsError(try body(), what, line: line) { XCTAssertTrue($0 is VoiceStaleCall, "\(what): \($0)", line: line) }
        }
        stale("loadRecord") { _ = try services.loadRecord(contactId: "c", cfg: cfg, generation: read) }
        stale("deviceTag") { _ = try services.deviceTag(deviceId: "d", generation: read) }
        stale("update") { try services.update(contactId: "c", cfg: cfg, generation: read, account: "acct-proof") { $0 } }
        try plantRecordOfAnEarlierRun()
        stale("deleteRecord") { try services.deleteRecord(contactId: "c", generation: read) }
        XCTAssertEqual(planted.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: planted[0].path), "a refused deletion leaves what is there")
        try FileManager.default.removeItem(at: planted[0])
        planted = []
        try assertNoDataOnDisk("no meta.bin, no record after the refused operations")
    }

    /// The same at the level of the store, with a key vault in memory: no key is added, no file is made.
    func testTheStoreRefusesAnOperationOfAnEarlierGenerationBeforeCreatingMetaKeyOrFiles() throws {
        let dir = try VoiceStoreFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vault = VoiceMemoryVault()
        var generation = 0
        let store = VoiceTemplateStore(
            dir: dir, aead: VoiceKeychainAead(dataExists: { try VoiceTemplateStore.dataExists(in: dir) }, vault: vault, sleep: { _ in }),
            accountId: "acct", dirSync: VoiceDirectorySyncs.none, generationProbe: { generation })
        let cfg = try VoiceKat.bundle().state
        let read = generation
        generation += 1 // the wipe
        XCTAssertThrowsError(try store.loadCompatible("c", cfg, generation: read)) { XCTAssertTrue($0 is VoiceStaleCall) }
        XCTAssertThrowsError(try store.nameSalt(generation: read)) { XCTAssertTrue($0 is VoiceStaleCall) }
        XCTAssertThrowsError(try store.update(contactId: "c", compatibleWith: cfg, generation: read) { $0 }) {
            XCTAssertTrue($0 is VoiceStaleCall)
        }
        XCTAssertThrowsError(try store.delete("c", generation: read)) { XCTAssertTrue($0 is VoiceStaleCall) }
        XCTAssertEqual(vault.addCount, 0, "no key was created")
        XCTAssertNil(vault.current)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [], [], "no meta.bin, no record, no temp file")
        // The current generation works as before.
        XCTAssertNoThrow(try store.nameSalt(generation: generation))
        XCTAssertEqual(vault.addCount, 1)
    }
}
