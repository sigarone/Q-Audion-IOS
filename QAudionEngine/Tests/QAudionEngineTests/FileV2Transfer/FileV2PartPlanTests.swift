import XCTest
@testable import QAudionEngine

/// How a blob is cut into the parts of the parts protocol: pure arithmetic, checked against the geometry of the format.
final class FileV2PartPlanTests: XCTestCase {

    private func plan(forFileOf size: UInt64) throws -> FileV2PartPlan {
        let encryptor = try FileV2Encryptor.makeNew(plaintextSize: size)
        defer { encryptor.close() }
        return try XCTUnwrap(FileV2PartPlan.make(blobLength: Int64(encryptor.blobLength), totalChunks: encryptor.totalChunks))
    }

    /// The parts follow one another with no gap and no overlap, from the end of the header to the end of the blob.
    private func assertContiguous(_ plan: FileV2PartPlan, file: StaticString = #filePath, line: UInt = #line) {
        var expectedOffset = Int64(FileV2.headerLength)
        var chunks = 0
        for (index, part) in plan.parts.enumerated() {
            XCTAssertEqual(part.index, index, file: file, line: line)
            XCTAssertEqual(part.blobOffset, expectedOffset, file: file, line: line)
            XCTAssertEqual(part.firstChunk, chunks, file: file, line: line)
            XCTAssertEqual(part.range.toInclusive - part.range.from + 1, Int64(part.byteLength), file: file, line: line)
            expectedOffset += Int64(part.byteLength)
            chunks += part.chunkCount
        }
        XCTAssertEqual(expectedOffset, plan.blobLength, file: file, line: line)
        XCTAssertEqual(chunks, plan.totalChunks, file: file, line: line)
    }

    func test_aTinyFile_isOnePartOfOneChunk() throws {
        let plan = try plan(forFileOf: 1)
        XCTAssertEqual(plan.parts.count, 1)
        XCTAssertEqual(plan.parts[0].chunkCount, 1)
        XCTAssertEqual(plan.parts[0].byteLength, 1 + FileV2.tagSize)
        assertContiguous(plan)
    }

    func test_eightChunksExactly_isOneFullPart() throws {
        let plan = try plan(forFileOf: UInt64(8 * FileV2.chunkSize))
        XCTAssertEqual(plan.parts.count, 1)
        XCTAssertEqual(plan.parts[0].byteLength, FileV2Wire.partSize)
        assertContiguous(plan)
    }

    func test_oneByteOverEightChunks_makesASecondShortPart() throws {
        let plan = try plan(forFileOf: UInt64(8 * FileV2.chunkSize) + 1)
        XCTAssertEqual(plan.parts.count, 2)
        XCTAssertEqual(plan.parts[0].byteLength, FileV2Wire.partSize)
        XCTAssertEqual(plan.parts[0].chunkCount, 8)
        XCTAssertEqual(plan.parts[1].chunkCount, 1)
        XCTAssertLessThan(plan.parts[1].byteLength, FileV2Wire.partSize)
        assertContiguous(plan)
    }

    func test_theLargestFile_is640PartsAndStaysContiguous() throws {
        let plan = try plan(forFileOf: FileV2.maxSize)
        XCTAssertEqual(plan.parts.count, FileV2Wire.maxParts)
        XCTAssertEqual(plan.totalChunks, FileV2.maxChunks)
        XCTAssertEqual(plan.blobLength, Int64(FileV2.maxBlob))
        assertContiguous(plan)
    }

    func test_aPlanThatDisagreesWithTheGeometryIsRefused() throws {
        let encryptor = try FileV2Encryptor.makeNew(plaintextSize: UInt64(3 * FileV2.chunkSize))
        defer { encryptor.close() }
        let blob = Int64(encryptor.blobLength)
        XCTAssertNotNil(FileV2PartPlan.make(blobLength: blob, totalChunks: encryptor.totalChunks))
        XCTAssertNil(FileV2PartPlan.make(blobLength: blob, totalChunks: 0))
        XCTAssertNil(FileV2PartPlan.make(blobLength: blob, totalChunks: FileV2.maxChunks + 1))
        XCTAssertNil(FileV2PartPlan.make(blobLength: blob, totalChunks: 20))          // 20 chunks cannot fit in this blob
        XCTAssertNil(FileV2PartPlan.make(blobLength: Int64(FileV2.headerLength), totalChunks: 1))   // a header and no payload
    }
}
