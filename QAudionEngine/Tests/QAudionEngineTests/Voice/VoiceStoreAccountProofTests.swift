import XCTest
import Foundation
@testable import QAudionEngine

/// The store of the contact-voice check finds the signed-in account through `VoiceProcess.shared.accountIdProvider`, which only
/// `QAudionCallIntegration.init` sets, with a weak reference to that integration. A call's integration exists only while the call
/// runs (the app releases it when the call ends), so these tests check the two moments at which the store is used without one:
/// the post-call write of a call, and the deletion of a contact before the first call of a run of the app.
final class VoiceStoreAccountProofTests: XCTestCase {
    private static let noAccount = VoiceStoreError(.key, "no account")
    private var planted: [URL] = []

    override func tearDown() {
        for url in planted { try? FileManager.default.removeItem(at: url) }
        planted = []
        super.tearDown()
    }

    /// The folder of the store, found the way `VoiceSystemServices` finds it.
    private func storeDirectory() throws -> URL {
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        return VoiceTemplateStore.directoryFor(applicationSupport: support)
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

    /// Builds a call's integration with an account, checks that the store sees it, then lets the integration go as the end of a
    /// call does. Returns false when the integration did not go away within 10 s (the test then cannot say anything).
    private func runAndEndACall(account: String) -> Bool {
        weak var gone: QAudionCallIntegration?
        do {
            let integration = QAudionCallIntegration()
            integration.resolveVoiceAccountId = { account }
            gone = integration
            XCTAssertEqual(VoiceProcess.shared.accountIdProvider?(), account, "while the call runs the store has the account")
        }
        let deadline = Date().addingTimeInterval(10)
        while gone != nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return gone == nil
    }

    /// The finalizer of `VoiceCallSession` (load, end of call, save) runs on the session's queue after `callEnded`, inside
    /// `VoiceEngine.close`, after the post-call embeddings; the end of the call releases the call's integration on the main thread
    /// meanwhile. At that point the account must still be known, or the record of the call is never written.
    func testThePostCallWriteStillHasTheAccountAfterTheCallsIntegrationIsReleased() throws {
        XCTAssertTrue(runAndEndACall(account: "acct-proof"), "precondition: the integration of the call is released")
        XCTAssertEqual(VoiceProcess.shared.accountIdProvider?(), "acct-proof",
                       "after the call the store of the process has no account any more")
        let services = VoiceProcess.shared.services
        let cfg = try VoiceKat.bundle().state
        do {
            try services.update(contactId: "contact-proof", cfg: cfg, generation: services.generation) { $0 }
        } catch let error as VoiceStoreError {
            XCTAssertNotEqual(error, Self.noAccount, "the post-call write of the record failed for want of an account")
        } catch {}
    }

    /// `VoiceCallWiring.contactRemoved` "works before any call of the process": a contact deleted or blocked right after the app
    /// starts, with a record from a call of an earlier run on the phone. The services of a process that has not built a call's
    /// integration yet have no account provider.
    func testADeletionBeforeTheFirstCallOfTheRunDeletesTheRecord() throws {
        try plantRecordOfAnEarlierRun()
        let services = VoiceSystemServices()
        do {
            try services.deleteRecord(contactId: "contact-proof")
        } catch let error as VoiceStoreError {
            XCTAssertNotEqual(error, Self.noAccount,
                              "the deletion of the contact failed for want of an account: the learned voice of the deleted contact stays")
        } catch {}
    }
}
