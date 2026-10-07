import XCTest
@testable import QAudionEngine

// The server conformance transcript (docs/FILES_V2_SERVER_TRANSCRIPT.md of the server repository): a golden file generated
// from the REAL server handlers. This file reads it, generates the bytes of its blobs and models its scenarios; the replay
// itself is in FileV2TranscriptReplay.swift.

/// The byte pattern of the transcript's blobs: `byte(i) = fmix32(u32(i) XOR u32(seed * 0x9E3779B9)) AND 0xFF`, where `fmix32`
/// is the MurmurHash3 32-bit finalizer. Every multiplication is a 32-bit one that wraps (`&*`).
enum XferPattern {

    static func byte(seed: Int64, index: Int64) -> UInt8 {
        let key = UInt32(truncatingIfNeeded: seed) &* 0x9E37_79B9
        var h = UInt32(truncatingIfNeeded: index) ^ key
        h ^= h >> 16
        h = h &* 0x85EB_CA6B
        h ^= h >> 13
        h = h &* 0xC2B2_AE35
        h ^= h >> 16
        return UInt8(truncatingIfNeeded: h)
    }

    /// `count` bytes from absolute index `from`.
    static func bytes(seed: Int64, from: Int64, count: Int) -> Data {
        guard count > 0 else { return Data() }
        let key = UInt32(truncatingIfNeeded: seed) &* 0x9E37_79B9
        let out = [UInt8](unsafeUninitializedCapacity: count) { buffer, filled in
            var index = UInt32(truncatingIfNeeded: from)
            for position in 0..<count {
                var h = index ^ key
                h ^= h >> 16
                h = h &* 0x85EB_CA6B
                h ^= h >> 13
                h = h &* 0xC2B2_AE35
                h ^= h >> 16
                buffer[position] = UInt8(truncatingIfNeeded: h)
                index = index &+ 1
            }
            filled = count
        }
        return Data(out)
    }
}

/// One blob of a scenario: only a seed and a length. `declaredOnly` blobs (above 128 MiB) are never generated.
struct XferBlob {
    let name: String
    let seed: Int64
    let length: Int64
    let parts: Int
    let headBase64: String
    /// The SHA-256 of every part, lowercase hex; absent for a declared-only blob.
    let partsSHA256: [String]?
    let declaredOnly: Bool

    /// `count` bytes from absolute index `from`.
    func bytes(from: Int64, count: Int) -> Data { XferPattern.bytes(seed: seed, from: from, count: count) }

    /// Bytes `from`...`to` inclusive.
    func bytes(from: Int64, toInclusive to: Int64) -> Data { bytes(from: from, count: Int(to - from + 1)) }

    var head: Data { bytes(from: 0, count: FileV2.headerLength) }

    /// Part `index` of the blob: the bytes from `64 + index * partSize`, the last one shorter.
    func part(_ index: Int) -> Data {
        guard let offset = FileV2Wire.partOffset(index) else { return Data() }
        return bytes(from: offset, count: FileV2Wire.partLength(blobLength: length, part: index))
    }
}

struct XferStep {
    let index: Int
    let op: String
    /// The authenticated account; `nil` is no authentication (the server answers 401).
    let user: String?
    let args: FakeJSON
    let expect: FakeJSON?
    /// The name under which an asynchronous step's request is awaited or released.
    let asyncName: String?
    let note: String?
}

struct XferScenario {
    let name: String
    let summary: String
    let requires: [String]
    let config: FakeJSON
    let clockStartMs: Int64
    let blobs: [XferBlob]
    let steps: [XferStep]

    func blob(named name: String) -> XferBlob? {
        let wanted = Array(name.utf8)
        return blobs.first { Array($0.name.utf8) == wanted }
    }
}

struct XferTranscript {
    struct PatternVector {
        let seed: Int64
        let index: Int64
        let byte: UInt8
    }

    let version: Int64
    let constants: FakeJSON
    let patternName: String
    let patternVectors: [PatternVector]
    let scenarios: [XferScenario]

    /// The SHA-256 of the transcript, pinned: the file in this repository must stay a byte-for-byte copy of the one in the
    /// server repository (`test/kat/file_v2_server/transcript.json`). The server pins the same value.
    static let pinnedSHA256 = "8dfe92b81a7e8ef2e5a058c2c98f5fb1c265690b8281efaf4569dda9c5cf4a47"
    static let pinnedLength = 343_942

    /// The commit of the server repository the copy was taken from.
    static let sourceCommit = "f541653b48513bc5ba55bb57712c646f2aef7329"

    enum LoadError: Error, CustomStringConvertible {
        case missing
        case malformed(String)

        var description: String {
            switch self {
            case .missing: return "file-v2-server-transcript.json is missing from the test bundle"
            case .malformed(let why): return "file-v2-server-transcript.json is malformed: \(why)"
            }
        }
    }

    static func bytes() throws -> Data {
        let candidates: [URL?] = [
            Bundle.module.url(forResource: "file-v2-server-transcript", withExtension: "json"),
            Bundle.module.url(forResource: "file-v2-server-transcript", withExtension: "json", subdirectory: "kat"),
            Bundle.module.url(forResource: "file-v2-server-transcript", withExtension: "json", subdirectory: "Resources/kat")
        ]
        guard let url = candidates.compactMap({ $0 }).first else { throw LoadError.missing }
        return try Data(contentsOf: url)
    }

    static func load() throws -> XferTranscript {
        let document: FakeJSON
        do {
            document = try FakeJSON.parse(try bytes())
        } catch let error as FakeJSON.ParseFailure {
            throw LoadError.malformed(String(describing: error))
        }
        guard let version = document.member("version")?.intValue, let constants = document.member("constants"),
              let pattern = document.member("pattern"), let scenarios = document.member("scenarios")?.arrayValue else {
            throw LoadError.malformed("top level")
        }
        var vectors = [PatternVector]()
        for item in pattern.member("vectors")?.arrayValue ?? [] {
            guard let seed = item.member("seed")?.intValue, let index = item.member("index")?.intValue,
                  let byte = item.member("byte")?.intValue, byte >= 0, byte <= 255 else {
                throw LoadError.malformed("pattern vector")
            }
            vectors.append(PatternVector(seed: seed, index: index, byte: UInt8(byte)))
        }
        return XferTranscript(version: version, constants: constants, patternName: pattern.member("name")?.stringValue ?? "",
                              patternVectors: vectors, scenarios: try scenarios.map(parseScenario))
    }

    private static func parseScenario(_ item: FakeJSON) throws -> XferScenario {
        guard let name = item.member("name")?.stringValue, let clock = item.member("clock_start_ms")?.intValue,
              let blobs = item.member("blobs")?.objectMembers, let steps = item.member("steps")?.arrayValue else {
            throw LoadError.malformed("scenario")
        }
        let requires = (item.member("requires")?.arrayValue ?? []).compactMap { $0.stringValue }
        var parsedBlobs = [XferBlob]()
        for member in blobs {
            guard let seed = member.value.member("seed")?.intValue, let length = member.value.member("len")?.intValue,
                  let parts = member.value.member("parts")?.intValue,
                  let head = member.value.member("head_b64")?.stringValue else {
                throw LoadError.malformed("blob \(member.key)")
            }
            let hashes = member.value.member("parts_sha256")?.arrayValue?.compactMap { $0.stringValue }
            parsedBlobs.append(XferBlob(name: member.key, seed: seed, length: length, parts: Int(parts), headBase64: head,
                                        partsSHA256: hashes,
                                        declaredOnly: member.value.member("declared_only")?.boolValue ?? false))
        }
        var parsedSteps = [XferStep]()
        for (index, step) in steps.enumerated() {
            guard let op = step.member("op")?.stringValue else { throw LoadError.malformed("step \(index) of \(name)") }
            parsedSteps.append(XferStep(index: index, op: op, user: step.member("as")?.stringValue,
                                        args: step.member("args") ?? .object([]), expect: step.member("expect"),
                                        asyncName: step.member("async")?.stringValue, note: step.member("note")?.stringValue))
        }
        return XferScenario(name: name, summary: item.member("description")?.stringValue ?? "", requires: requires,
                            config: item.member("config") ?? .object([]), clockStartMs: clock, blobs: parsedBlobs,
                            steps: parsedSteps)
    }

    /// A constant of the transcript as an integer.
    func constant(_ name: String) -> Int64? { constants.member(name)?.intValue }
}
