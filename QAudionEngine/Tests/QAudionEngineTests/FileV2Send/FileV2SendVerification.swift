import XCTest
import CryptoKit
@testable import QAudionEngine

/// What a test asserts about the events, the blob and the descriptor of a transfer.
enum SendEventAnalysis {

    /// Violations of WIRE_SPEC 12.8's nonce rule as the pipeline keeps it: for every PUT of a part, the tags of ALL its chunks must already
    /// be durable in the journal (an append whose `.done` is logged before the PUT starts). The log may span several runs of one transfer:
    /// the journal outlives a restart.
    static func putsBeforeTheirTagsAreDurable(_ events: [String], totalChunks: Int) -> [String] {
        var durable = Set<Int>()
        var violations: [String] = []
        for (position, event) in events.enumerated() {
            if event.hasPrefix("journal.tags "), event.hasSuffix(".done") {
                durable.formUnion(chunks(in: event))
            } else if event.hasPrefix("server.put.start part="), let part = Int(event.dropFirst("server.put.start part=".count)) {
                let first = part * FileV2Wire.chunksPerPart
                let needed = Set(first..<min(first + FileV2Wire.chunksPerPart, totalChunks))
                if !needed.isSubset(of: durable) {
                    violations.append("event \(position): part \(part) PUT with \(needed.subtracting(durable).count) chunk tags not durable")
                }
            }
        }
        return violations
    }

    /// Every durable tags append is flushed between its `.begin` and its `.done` (sequential runs only: with parallel workers the
    /// log of two appends interleaves, the store's own lock does not).
    static func everyTagAppendIsFlushed(_ events: [String]) -> [String] {
        var violations: [String] = []
        var open: Int?
        var flushed = false
        for (position, event) in events.enumerated() {
            if event.hasPrefix("journal.tags "), event.hasSuffix(".begin") {
                open = position
                flushed = false
            } else if event.hasPrefix("fsync.file"), open != nil {
                flushed = true
            } else if event.hasPrefix("journal.tags "), event.hasSuffix(".done") {
                if open != nil, !flushed { violations.append("event \(position): a tags append returned without a flush") }
                open = nil
            }
        }
        return violations
    }

    static func chunks(in event: String) -> [Int] {
        guard let start = event.range(of: "chunks=")?.upperBound, let end = event.range(of: ".done", options: .backwards)?.lowerBound,
              start <= end else { return [] }
        return event[start..<end].split(separator: ",").compactMap { Int($0) }
    }

    /// `server.put.start` events, in order, as part numbers.
    static func putStarts(_ events: [String]) -> [Int] {
        events.compactMap { event in
            event.hasPrefix("server.put.start part=") ? Int(event.dropFirst("server.put.start part=".count)) : nil
        }
    }
}

extension SendRig {

    /// The descriptor the chat was handed last, parsed by the library.
    func lastDescriptor(file: StaticString = #filePath, line: UInt = #line) throws -> FileV2Descriptor {
        guard let announced = channel.announced.last else {
            XCTFail("nothing was announced", file: file, line: line)
            throw FileV2Error.badDescriptor
        }
        return try FileV2Descriptor.parse(announced.body)
    }

    /// The blob the fake holds for an object: the header, then every part. Fails if a part is missing.
    func storedBlob(obj: String, header: Data, blobLength: Int64, file: StaticString = #filePath, line: UInt = #line) -> Data? {
        var blob = Data(header)
        for part in 0..<FileV2Wire.partCount(blobLength: blobLength) {
            guard let bytes = fake.storedPart(obj: obj, part: part) else {
                XCTFail("part \(part) is not on the server", file: file, line: line)
                return nil
            }
            blob.append(bytes)
        }
        return blob
    }

    /// The blob of a one-shot encryption of the source under the key and the file id of the descriptor: header, then every sealed chunk.
    func oneShotBlob(descriptor: FileV2Descriptor, source: GeneratedSource) throws -> Data {
        let encryptor = try FileV2Encryptor(fileKey: descriptor.fileKey, fileID: descriptor.fileID, plaintextSize: descriptor.size)
        defer { encryptor.close() }
        var blob = Data(encryptor.header.bytes)
        for index in 0..<encryptor.totalChunks {
            let length = encryptor.chunkFileLength(index)
            let plain = length > 0 ? try XCTUnwrap(source.bytes(offset: UInt64(index) * UInt64(FileV2.chunkSize), length: length)) : Data()
            blob.append(try encryptor.sealChunk(index: index, fileBytes: plain))
        }
        return blob
    }

    /// The blob on the server equals a one-shot encryption of the source, byte for byte.
    func assertBlobEqualsOneShot(descriptor: FileV2Descriptor, source: GeneratedSource, file: StaticString = #filePath,
                                 line: UInt = #line) throws {
        let encryptor = try FileV2Encryptor(fileKey: descriptor.fileKey, fileID: descriptor.fileID, plaintextSize: descriptor.size)
        let blobLength = Int64(encryptor.blobLength)
        encryptor.close()
        let obj = try XCTUnwrap(descriptor.source.obj, file: file, line: line)
        guard let stored = storedBlob(obj: obj, header: descriptor.header.bytes, blobLength: blobLength, file: file, line: line) else { return }
        let expected = try oneShotBlob(descriptor: descriptor, source: source)
        XCTAssertEqual(stored.count, expected.count, "blob length", file: file, line: line)
        XCTAssertTrue(stored == expected, "the blob on the server is not a one-shot encryption of the source", file: file, line: line)
    }

    /// The bytes of every file in the store directory, as text and as raw bytes, for the scan for secrets.
    func storeFilesContain(_ needles: [Data]) throws -> [String] {
        var found: [String] = []
        for name in try journalNames() {
            let bytes = try Data(contentsOf: storeDirectory.appendingPathComponent(name))
            for (index, needle) in needles.enumerated() where !needle.isEmpty && bytes.range(of: needle) != nil {
                found.append("\(name) holds needle \(index)")
            }
        }
        return found
    }

    /// A secret in every form it could be written in: raw, base64, hex, and for a token its text.
    static func forms(of secret: Data) -> [Data] {
        [secret, Data(secret.base64EncodedString().utf8), Data(XferSupport.hex(secret).utf8)]
    }
}

extension SendRig {

    /// The byte offsets at which the records of a journal end (the first is the end of the begin record).
    func recordBoundaries(id: String) throws -> [Int] {
        let bytes = [UInt8](try Data(contentsOf: storeDirectory.appendingPathComponent(id).appendingPathExtension("qsj")))
        var boundaries: [Int] = []
        var position = FileV2JournalFormat.magic.count
        while position + FileV2JournalFormat.frameOverhead <= bytes.count {
            let length = Int(bytes[position]) << 24 | Int(bytes[position + 1]) << 16 | Int(bytes[position + 2]) << 8 | Int(bytes[position + 3])
            position += FileV2JournalFormat.frameOverhead + length
            guard position <= bytes.count else { break }
            boundaries.append(position)
        }
        return boundaries
    }

    /// Cuts the journal of `id` so that its last `records` records are gone, leaving `tear` bytes of the first of them (a torn append).
    func cutJournal(id: String, droppingLast records: Int, leaving tear: Int = 0) throws {
        let url = storeDirectory.appendingPathComponent(id).appendingPathExtension("qsj")
        let boundaries = try recordBoundaries(id: id)
        let keepRecords = boundaries.count - records
        precondition(keepRecords >= 1, "the begin record must stay")
        let cut = boundaries[keepRecords - 1] + tear
        let bytes = try Data(contentsOf: url)
        try bytes.prefix(cut).write(to: url)
    }

    /// The events of a journal, decoded, in order (the begin record excluded).
    func journalEvents(id: String) throws -> [FileV2SendJournalEvent] {
        let url = storeDirectory.appendingPathComponent(id).appendingPathExtension("qsj")
        let scan = try FileV2JournalFormat.scan([UInt8](try Data(contentsOf: url)))
        return try scan.records.dropFirst().map { try FileV2JournalFormat.decodeEvent($0) }
    }
}
