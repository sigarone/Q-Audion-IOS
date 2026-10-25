import XCTest
import Contacts
@testable import QAudionApp

/// A refresh of the contact list never asks for the Contacts permission and never uploads hashes unless the permission is
/// already given and the user has completed an import before. Wired into CI like the other app tests.
final class PhonebookImportGateTests: XCTestCase {

    func test_aRefreshNeverScansBeforeAnExplicitImport() {
        for status in [CNAuthorizationStatus.notDetermined, .denied, .restricted, .authorized] {
            XCTAssertFalse(PhonebookImportGate.mayScanOnRefresh(importCompleted: false, status: status), "\(status.rawValue)")
        }
    }

    func test_aRefreshAfterAnImportScansOnlyWithThePermissionAlreadyGiven() {
        XCTAssertTrue(PhonebookImportGate.mayScanOnRefresh(importCompleted: true, status: .authorized))
        if #available(iOS 18.0, *) {
            XCTAssertTrue(PhonebookImportGate.mayScanOnRefresh(importCompleted: true, status: .limited))
        }
        XCTAssertFalse(PhonebookImportGate.mayScanOnRefresh(importCompleted: true, status: .notDetermined), "never asks by itself")
        XCTAssertFalse(PhonebookImportGate.mayScanOnRefresh(importCompleted: true, status: .denied))
        XCTAssertFalse(PhonebookImportGate.mayScanOnRefresh(importCompleted: true, status: .restricted))
    }

    func test_clearForgetsTheImportAndARevokedPermissionClearsIt() throws {
        let name = "PhonebookImportGateTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let gate = PhonebookImportGate(defaults: defaults)

        gate.markImportCompleted()
        gate.clear()
        XCTAssertFalse(gate.importCompleted, "a wipe or logout takes the mark with it")
        XCTAssertFalse(gate.mayScanOnRefresh(status: .authorized), "the next account has not run Importa")

        gate.markImportCompleted()
        XCTAssertFalse(gate.mayScanOnRefresh(status: .denied))
        XCTAssertFalse(gate.importCompleted, "a revoked permission clears the mark")
        XCTAssertFalse(gate.mayScanOnRefresh(status: .authorized), "a regrant needs a new Importa")
    }

    func test_theCompletedImportIsRemembered() throws {
        let name = "PhonebookImportGateTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let gate = PhonebookImportGate(defaults: defaults)
        XCTAssertFalse(gate.importCompleted)
        XCTAssertFalse(gate.mayScanOnRefresh(status: .authorized))
        gate.markImportCompleted()
        XCTAssertTrue(PhonebookImportGate(defaults: defaults).importCompleted)
        XCTAssertTrue(gate.mayScanOnRefresh(status: .authorized))
    }
}
