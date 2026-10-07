import XCTest
@testable import QAudionEngine

extension SendRig {

    /// WIRE_SPEC 12.8 rule 2, seen from the server: every PUT body the recorder saw, chunk by chunk, carries for a chunk the same tag as the
    /// FIRST time that chunk was transmitted. A differing tag would be two plaintexts under one nonce.
    func assertNoChunkWasEverTransmittedWithADifferentTag(file: StaticString = #filePath, line: UInt = #line) {
        var first: [Int: Data] = [:]
        for put in server.puts {
            for (offset, tag) in put.chunkTags.enumerated() {
                let chunk = put.firstChunk + offset
                if let known = first[chunk] {
                    XCTAssertEqual(known, tag, "chunk \(chunk) was transmitted again with a different tag", file: file, line: line)
                } else {
                    first[chunk] = tag
                }
            }
        }
    }

    /// Every transmission of a part carries the same bytes as the first.
    func assertEveryPartWasAlwaysSentWithTheSameBytes(file: StaticString = #filePath, line: UInt = #line) {
        var first: [Int: Data] = [:]
        for put in server.puts {
            if let known = first[put.part] {
                XCTAssertEqual(known, put.digest, "part \(put.part) was sent again with other bytes", file: file, line: line)
            } else {
                first[put.part] = put.digest
            }
        }
    }
}

extension XCTestCase {

    /// The state is a failure with this reason (and, when given, this server code). The numbers in `details` are compared by the tests that
    /// care about them.
    @discardableResult
    func assertFailure(_ state: FileV2SendState, _ reason: FileV2SendFailure.Reason, code: String? = nil, file: StaticString = #filePath,
                       line: UInt = #line) -> FileV2SendFailure? {
        guard case .failed(let failure) = state else {
            XCTFail("expected a failure (\(reason.rawValue)), got \(state)", file: file, line: line)
            return nil
        }
        XCTAssertEqual(failure.reason, reason, file: file, line: line)
        if let code = code { XCTAssertEqual(failure.code, code, file: file, line: line) }
        return failure
    }
}
