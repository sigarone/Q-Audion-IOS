import XCTest
@testable import QAudionEngine

final class BackupContainerTests: XCTestCase {

    func test_seal_emitsQaudPrefix() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["FAST_TESTS"] != nil,
                      "Skip scrypt-heavy test in fast mode")
        let container = try BackupContainer.seal(plaintext: Data("hello".utf8), password: "test-pwd")
        XCTAssertEqual(Array(container.prefix(4)), [0x51, 0x41, 0x55, 0x44])
        XCTAssertEqual(container[4], 1)  // version
    }

    func test_seal_thenOpen_roundTrip() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["FAST_TESTS"] != nil,
                      "Skip scrypt-heavy test in fast mode")
        let plaintext = Data((0..<512).map { UInt8($0 & 0xFF) })
        let container = try BackupContainer.seal(plaintext: plaintext, password: "p")
        let recovered = try BackupContainer.open(container, password: "p")
        XCTAssertEqual(recovered, plaintext)
    }

    func test_open_rejectsWrongMagic() {
        var container = Data([0x00, 0x00, 0x00, 0x00, 0x01])  // bad magic + version
        container.append(Data(repeating: 0, count: 16))  // salt
        container.append(Data(repeating: 0, count: 12))  // nonce
        container.append(Data(repeating: 0, count: 16))  // tag
        XCTAssertThrowsError(try BackupContainer.open(container, password: "p")) { err in
            guard case BackupContainer.Error.wrongMagic = err else {
                XCTFail("Expected .wrongMagic, got \(err)"); return
            }
        }
    }

    func test_open_rejectsUnsupportedVersion() {
        var container = Data([0x51, 0x41, 0x55, 0x44, 0xFF])  // QAUD + version=255
        container.append(Data(repeating: 0, count: 16))
        container.append(Data(repeating: 0, count: 12))
        container.append(Data(repeating: 0, count: 16))
        XCTAssertThrowsError(try BackupContainer.open(container, password: "p")) { err in
            guard case BackupContainer.Error.unsupportedVersion(let v) = err else {
                XCTFail("Expected .unsupportedVersion, got \(err)"); return
            }
            XCTAssertEqual(v, 0xFF)
        }
    }

    func test_open_rejectsTruncated() {
        let container = Data([0x51, 0x41, 0x55, 0x44, 0x01])  // just magic + version
        XCTAssertThrowsError(try BackupContainer.open(container, password: "p")) { err in
            guard case BackupContainer.Error.truncated = err else {
                XCTFail("Expected .truncated, got \(err)"); return
            }
        }
    }
}
