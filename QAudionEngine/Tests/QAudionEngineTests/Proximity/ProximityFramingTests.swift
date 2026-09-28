import XCTest
@testable import QAudionEngine

/// Proximity pairing v1 — BLE framing (spec §7), pinned against the "framing"
/// vectors of `proximity-pairing-kat.json` plus every receiver rule.
final class ProximityFramingTests: XCTestCase {

    // MARK: - KAT

    private struct FramingKatVector: Decodable {
        let message: String
        let maxValueLength: Int
        let fragments: [String]
    }

    private struct FramingKatRoot: Decodable {
        let framing: [FramingKatVector]
    }

    private struct FramingCase {
        let message: Data
        let maxValueLength: Int
        let fragments: [Data]
    }

    private struct FramingHexDecodingError: Error {}

    private func loadFramingKat() throws -> [FramingCase] {
        let maybeUrl: URL? = Bundle.module.url(forResource: "proximity-pairing-kat", withExtension: "json")
        let url: URL = try XCTUnwrap(maybeUrl, "proximity-pairing-kat.json missing from Bundle.module")
        let json: Data = try Data(contentsOf: url)
        let root: FramingKatRoot = try JSONDecoder().decode(FramingKatRoot.self, from: json)
        var cases: [FramingCase] = []
        for vector in root.framing {
            let message: Data = try ProximityFramingTests.framingHex(vector.message)
            var fragments: [Data] = []
            for fragmentHex in vector.fragments {
                fragments.append(try ProximityFramingTests.framingHex(fragmentHex))
            }
            cases.append(FramingCase(message: message, maxValueLength: vector.maxValueLength, fragments: fragments))
        }
        return cases
    }

    /// The KAT vector with a 3-fragment message (50 bytes, maxValueLength 20).
    private func threeFragmentCase() throws -> FramingCase {
        let cases = try loadFramingKat()
        let found: FramingCase? = cases.first(where: { $0.fragments.count == 3 })
        return try XCTUnwrap(found, "KAT has no 3-fragment framing vector")
    }

    func testConstants() {
        XCTAssertEqual(ProximityFraming.headerBytes, 2)
        XCTAssertEqual(ProximityFraming.flagFirst, 0x01)
        XCTAssertEqual(ProximityFraming.flagLast, 0x02)
    }

    func testKatFragmentsAreByteIdentical() throws {
        let cases = try loadFramingKat()
        XCTAssertEqual(cases.count, 6)
        for vector in cases {
            let produced = try ProximityFraming.fragments(of: vector.message, maxValueLength: vector.maxValueLength)
            XCTAssertEqual(produced, vector.fragments)
        }
    }

    func testKatFragmentsReassemble() throws {
        let cases = try loadFramingKat()
        for vector in cases {
            var reassembler = ProximityReassembler()
            var completed: Data? = nil
            for (index, fragment) in vector.fragments.enumerated() {
                let output: Data? = try reassembler.append(fragment)
                if index < vector.fragments.count - 1 {
                    XCTAssertNil(output)
                } else {
                    completed = output
                }
            }
            XCTAssertEqual(completed, vector.message)
        }
    }

    // MARK: - fragments(of:maxValueLength:)

    func testFragmentsRejectEmptyMessage() {
        assertFragmentsThrow(Data(), 20)
        assertFragmentsThrow(Data(), 512)
    }

    func testFragmentsRejectOversizeMessage() throws {
        let tooBig = Data(repeating: 0x5A, count: ProximityPairing.maxMessageBytes + 1)
        assertFragmentsThrow(tooBig, 512)
        assertFragmentsThrow(tooBig, Int.max)

        let maxSize = Data(repeating: 0x5A, count: ProximityPairing.maxMessageBytes)
        let produced = try ProximityFraming.fragments(of: maxSize, maxValueLength: 20)
        XCTAssertEqual(produced.count, 228)
    }

    func testFragmentsRejectTinyMaxValueLength() throws {
        let message = Data([0x01, 0x02, 0x03])
        let tooSmall: [Int] = [2, 1, 0, -1, Int.min]
        for maxValueLength in tooSmall {
            assertFragmentsThrow(message, maxValueLength)
        }
        let minimal = try ProximityFraming.fragments(of: message, maxValueLength: 3)
        let expected: [Data] = [Data([0x01, 0x00, 0x01]), Data([0x00, 0x01, 0x02]), Data([0x02, 0x02, 0x03])]
        XCTAssertEqual(minimal, expected)
    }

    func testFragmentsRejectMoreThan256Fragments() throws {
        assertFragmentsThrow(Data(repeating: 0x11, count: 257), 3)
        // 4096 / 15 → 274 fragments; 4096 / 16 → exactly 256.
        assertFragmentsThrow(Data(repeating: 0x11, count: ProximityPairing.maxMessageBytes), 17)
        let exact = try ProximityFraming.fragments(of: Data(repeating: 0x11, count: ProximityPairing.maxMessageBytes),
                                                   maxValueLength: 18)
        XCTAssertEqual(exact.count, 256)

        let fragments = try ProximityFraming.fragments(of: Data(repeating: 0x22, count: 256), maxValueLength: 3)
        XCTAssertEqual(fragments.count, 256)
        let last: Data = try XCTUnwrap(fragments.last)
        let expectedLast: Data = Data([ProximityFraming.flagLast, 0xFF, 0x22])
        XCTAssertEqual(last, expectedLast)
    }

    func testFragmentsWithHugeMaxValueLengthProduceOneFragment() throws {
        let message = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let produced = try ProximityFraming.fragments(of: message, maxValueLength: Int.max)
        let expected: [Data] = [Data([0x03, 0x00, 0xDE, 0xAD, 0xBE, 0xEF])]
        XCTAssertEqual(produced, expected)
    }

    func testFragmentsAcceptSliceInput() throws {
        let vector = try threeFragmentCase()
        var padded = Data([0x99, 0x98, 0x97])
        padded.append(vector.message)
        let slice: Data = padded[3..<(3 + vector.message.count)]
        XCTAssertEqual(slice.startIndex, 3)
        let produced = try ProximityFraming.fragments(of: slice, maxValueLength: vector.maxValueLength)
        XCTAssertEqual(produced, vector.fragments)
    }

    // MARK: - ProximityReassembler — every §7 receiver rule

    func testReassemblerRejectsShortFragments() {
        var reassembler = ProximityReassembler()
        expectViolation(&reassembler, Data(), "empty ATT value")
        expectViolation(&reassembler, Data([0x03]), "header-only (1 byte) value")
    }

    func testReassemblerRejectsUnknownFlagBits() {
        let badFlags: [UInt8] = [0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x05, 0x07, 0xFF]
        for flags in badFlags {
            var reassembler = ProximityReassembler()
            expectViolation(&reassembler, Data([flags, 0x00, 0xAA]), "unknown flag bits")
        }
        // Also mid-message.
        var reassembler = ProximityReassembler()
        XCTAssertNil(try reassembler.append(Data([0x01, 0x00, 0xAA])))
        expectViolation(&reassembler, Data([0x42, 0x01, 0xBB]), "unknown flag bits mid-message")
    }

    func testReassemblerRejectsEmptyPayload() throws {
        var reassembler = ProximityReassembler()
        expectViolation(&reassembler, Data([0x03, 0x00]), "empty single-fragment payload")
        XCTAssertNil(try reassembler.append(Data([0x01, 0x00, 0xAA])))
        expectViolation(&reassembler, Data([0x02, 0x01]), "empty LAST payload")
    }

    func testReassemblerRejectsSeqMismatch() throws {
        var reassembler = ProximityReassembler()
        expectViolation(&reassembler, Data([0x03, 0x01, 0xAA]), "FIRST with seq 1")
        expectViolation(&reassembler, Data([0x01, 0xFF, 0xAA]), "FIRST with seq 255")

        XCTAssertNil(try reassembler.append(Data([0x01, 0x00, 0xAA])))
        expectViolation(&reassembler, Data([0x02, 0x02, 0xBB]), "skipped seq")

        XCTAssertNil(try reassembler.append(Data([0x01, 0x00, 0xAA])))
        expectViolation(&reassembler, Data([0x00, 0x00, 0xBB]), "repeated seq 0")

        XCTAssertNil(try reassembler.append(Data([0x01, 0x00, 0xAA])))
        XCTAssertNil(try reassembler.append(Data([0x00, 0x01, 0xBB])))
        expectViolation(&reassembler, Data([0x02, 0x01, 0xCC]), "repeated seq 1")
    }

    func testReassemblerRejectsFirstInsideMessage() throws {
        var reassembler = ProximityReassembler()
        XCTAssertNil(try reassembler.append(Data([0x01, 0x00, 0xAA])))
        expectViolation(&reassembler, Data([0x01, 0x00, 0xBB]), "second FIRST")

        XCTAssertNil(try reassembler.append(Data([0x01, 0x00, 0xAA])))
        expectViolation(&reassembler, Data([0x03, 0x00, 0xBB]), "FIRST|LAST inside a message")

        XCTAssertNil(try reassembler.append(Data([0x01, 0x00, 0xAA])))
        expectViolation(&reassembler, Data([0x01, 0x01, 0xBB]), "FIRST carrying the expected seq")
    }

    func testReassemblerRejectsNonFirstStart() {
        var reassembler = ProximityReassembler()
        expectViolation(&reassembler, Data([0x00, 0x00, 0xAA]), "middle fragment first")
        expectViolation(&reassembler, Data([0x02, 0x00, 0xAA]), "LAST-only fragment first")
        expectViolation(&reassembler, Data([0x00, 0x01, 0xAA]), "continuation fragment first")
    }

    func testReassemblerRejectsOversizeWithCustomLimit() throws {
        let first6: Data = ProximityFramingTests.makeFragment(0x01, 0x00, fill: 0x01, count: 6)
        let last5: Data = ProximityFramingTests.makeFragment(0x02, 0x01, fill: 0x02, count: 5)
        let last4: Data = ProximityFramingTests.makeFragment(0x02, 0x01, fill: 0x02, count: 4)
        let single11: Data = ProximityFramingTests.makeFragment(0x03, 0x00, fill: 0x03, count: 11)

        var reassembler = ProximityReassembler(maxMessageBytes: 10)
        XCTAssertNil(try reassembler.append(first6))
        expectViolation(&reassembler, last5, "11 > 10")

        XCTAssertNil(try reassembler.append(first6))
        let exact: Data? = try reassembler.append(last4)
        XCTAssertEqual(exact?.count, 10)

        expectViolation(&reassembler, single11, "single fragment 11 > 10")
    }

    func testReassemblerRejectsOversizeWithDefaultLimit() throws {
        let half: Int = ProximityPairing.maxMessageBytes / 2
        let firstHalf: Data = ProximityFramingTests.makeFragment(0x01, 0x00, fill: 0xA1, count: half)
        let lastHalf: Data = ProximityFramingTests.makeFragment(0x02, 0x01, fill: 0xA2, count: half)
        let lastHalfPlusOne: Data = ProximityFramingTests.makeFragment(0x02, 0x01, fill: 0xA2, count: half + 1)

        var reassembler = ProximityReassembler()
        XCTAssertNil(try reassembler.append(firstHalf))
        expectViolation(&reassembler, lastHalfPlusOne, "4097 > 4096")

        XCTAssertNil(try reassembler.append(firstHalf))
        let full: Data? = try reassembler.append(lastHalf)
        XCTAssertEqual(full?.count, ProximityPairing.maxMessageBytes)
    }

    func testReassemblerRejectsMoreThan256Fragments() throws {
        var middles: [Data] = []
        for seq in 1...254 {
            let seqByte: UInt8 = UInt8(truncatingIfNeeded: seq)
            middles.append(ProximityFramingTests.makeFragment(0x00, seqByte, fill: 0x00, count: 1))
        }
        let first: Data = ProximityFramingTests.makeFragment(0x01, 0x00, fill: 0x00, count: 1)
        let middle255: Data = ProximityFramingTests.makeFragment(0x00, 0xFF, fill: 0x00, count: 1)
        let last255: Data = ProximityFramingTests.makeFragment(0x02, 0xFF, fill: 0x00, count: 1)

        var reassembler = ProximityReassembler(maxMessageBytes: 100_000)
        XCTAssertNil(try reassembler.append(first))
        for fragment in middles {
            XCTAssertNil(try reassembler.append(fragment))
        }
        expectViolation(&reassembler, middle255, "non-LAST seq 255 needs a 257th fragment")

        XCTAssertNil(try reassembler.append(first))
        for fragment in middles {
            XCTAssertNil(try reassembler.append(fragment))
        }
        let message: Data? = try reassembler.append(last255)
        XCTAssertEqual(message?.count, 256)
    }

    func testReassemblerResetsItselfAfterError() throws {
        var reassembler = ProximityReassembler()
        XCTAssertNil(try reassembler.append(Data([0x01, 0x00, 0xAA])))
        expectViolation(&reassembler, Data([0x01, 0x00, 0xBB]), "FIRST inside a message")
        // The partial message is gone: a continuation is now a non-FIRST start…
        expectViolation(&reassembler, Data([0x02, 0x01, 0xCC]), "continuation after reset")
        // …and a fresh single-fragment message is accepted with nothing prepended.
        let fresh: Data? = try reassembler.append(Data([0x03, 0x00, 0xDD]))
        XCTAssertEqual(fresh, Data([0xDD]))
    }

    func testExplicitReset() throws {
        var reassembler = ProximityReassembler()
        XCTAssertNil(try reassembler.append(Data([0x01, 0x00, 0xAA])))
        reassembler.reset()
        expectViolation(&reassembler, Data([0x02, 0x01, 0xBB]), "continuation after reset()")
        let fresh: Data? = try reassembler.append(Data([0x03, 0x00, 0xCC]))
        XCTAssertEqual(fresh, Data([0xCC]))
    }

    func testOutOfOrderFragmentsAreRejected() throws {
        let vector = try threeFragmentCase()
        let f0: Data = vector.fragments[0]
        let f1: Data = vector.fragments[1]
        let f2: Data = vector.fragments[2]

        var swapped = ProximityReassembler()
        XCTAssertNil(try swapped.append(f0))
        expectViolation(&swapped, f2, "fragment 2 before fragment 1")

        var middleFirst = ProximityReassembler()
        expectViolation(&middleFirst, f1, "fragment 1 first")

        var lastFirst = ProximityReassembler()
        expectViolation(&lastFirst, f2, "fragment 2 first")

        var duplicated = ProximityReassembler()
        XCTAssertNil(try duplicated.append(f0))
        XCTAssertNil(try duplicated.append(f1))
        expectViolation(&duplicated, f1, "duplicated fragment 1")

        var restarted = ProximityReassembler()
        XCTAssertNil(try restarted.append(f0))
        expectViolation(&restarted, f0, "fragment 0 twice")

        var dropped = ProximityReassembler()
        XCTAssertNil(try dropped.append(f0))
        XCTAssertNil(try dropped.append(f1))
        expectViolation(&dropped, f0, "next message begins before LAST")
    }

    func testSequentialMessagesOnOneReassembler() throws {
        let cases = try loadFramingKat()
        var reassembler = ProximityReassembler()
        for vector in cases {
            var completed: Data? = nil
            for fragment in vector.fragments {
                completed = try reassembler.append(fragment)
            }
            XCTAssertEqual(completed, vector.message)
        }
    }

    func testReassemblerAcceptsSliceFragments() throws {
        let vector = try threeFragmentCase()
        var reassembler = ProximityReassembler()
        var completed: Data? = nil
        for fragment in vector.fragments {
            var padded = Data([0xEE, 0xEE])
            padded.append(fragment)
            let slice: Data = padded[2..<padded.count]
            completed = try reassembler.append(slice)
        }
        XCTAssertEqual(completed, vector.message)
    }

    // MARK: - Round-trip property

    func testRoundTripAcrossSizesAndValueLengths() throws {
        let base: Data = ProximityFramingTests.deterministicBytes(ProximityPairing.maxMessageBytes)
        let valueLengths: [Int] = [3, 20, 182, 244, 512]
        var failures: [String] = []
        for maxValueLength in valueLengths {
            let capacity: Int = maxValueLength - ProximityFraming.headerBytes
            for size in 1...ProximityPairing.maxMessageBytes {
                let message: Data = Data(base[0..<size])
                let expectedCount: Int = (size + capacity - 1) / capacity
                if expectedCount > 256 {
                    let rejected: Bool = ProximityFramingTests.fragmentsThrowViolation(message, maxValueLength)
                    if !rejected {
                        failures.append("accepted > 256 fragments")
                    }
                    continue
                }
                let fragments = try ProximityFraming.fragments(of: message, maxValueLength: maxValueLength)
                if let problem = ProximityFramingTests.structuralProblem(fragments, maxValueLength, expectedCount) {
                    failures.append(problem)
                    continue
                }
                var reassembler = ProximityReassembler()
                var completed: Data? = nil
                var earlyOutput: Bool = false
                for (index, fragment) in fragments.enumerated() {
                    let output: Data? = try reassembler.append(fragment)
                    if index < fragments.count - 1 {
                        if output != nil { earlyOutput = true }
                    } else {
                        completed = output
                    }
                }
                if earlyOutput { failures.append("message completed before LAST") }
                if completed != message { failures.append("reassembly mismatch") }
            }
        }
        XCTAssertEqual(failures.count, 0)
        if let firstFailure = failures.first {
            XCTFail(firstFailure)
        }
    }

    // MARK: - Helpers (private to this file)

    private func assertFragmentsThrow(_ message: Data, _ maxValueLength: Int,
                                      file: StaticString = #filePath, line: UInt = #line) {
        let rejected: Bool = ProximityFramingTests.fragmentsThrowViolation(message, maxValueLength)
        XCTAssertTrue(rejected, "fragments(of:maxValueLength:) must throw .protocolViolation", file: file, line: line)
    }

    private func expectViolation(_ reassembler: inout ProximityReassembler, _ fragment: Data, _ label: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        do {
            let output: Data? = try reassembler.append(fragment)
            XCTFail(label, file: file, line: line)
            _ = output
        } catch {
            let isExpected: Bool = ProximityFramingTests.isProtocolViolation(error)
            XCTAssertTrue(isExpected, label, file: file, line: line)
        }
    }

    private static func fragmentsThrowViolation(_ message: Data, _ maxValueLength: Int) -> Bool {
        do {
            _ = try ProximityFraming.fragments(of: message, maxValueLength: maxValueLength)
            return false
        } catch {
            return isProtocolViolation(error)
        }
    }

    private static func isProtocolViolation(_ error: Error) -> Bool {
        guard let pairingError = error as? ProximityPairingError else { return false }
        if case .protocolViolation = pairingError { return true }
        return false
    }

    /// Checks the spec §7 shape of a fragment list; nil when well-formed.
    private static func structuralProblem(_ fragments: [Data], _ maxValueLength: Int, _ expectedCount: Int) -> String? {
        if fragments.count != expectedCount { return "fragment count" }
        for (index, fragment) in fragments.enumerated() {
            let isLastFragment: Bool = index == fragments.count - 1
            if fragment.count > maxValueLength { return "fragment exceeds maxValueLength" }
            if fragment.count <= ProximityFraming.headerBytes { return "empty fragment payload" }
            if !isLastFragment && fragment.count != maxValueLength { return "non-final fragment not full" }
            let flags: UInt8 = fragment[fragment.startIndex]
            let seq: UInt8 = fragment[fragment.startIndex + 1]
            var expectedFlags: UInt8 = 0
            if index == 0 { expectedFlags |= ProximityFraming.flagFirst }
            if isLastFragment { expectedFlags |= ProximityFraming.flagLast }
            if flags != expectedFlags { return "flags" }
            if Int(seq) != index { return "seq" }
        }
        return nil
    }

    /// `u8(flags) ‖ u8(seq) ‖ count × fill`, built without `+` (CLAUDE.md §13).
    private static func makeFragment(_ flags: UInt8, _ seq: UInt8, fill: UInt8, count: Int) -> Data {
        let header: [UInt8] = [flags, seq]
        var out = Data(capacity: 2 + count)
        out.append(contentsOf: header)
        out.append(Data(repeating: fill, count: count))
        return out
    }

    /// Deterministic filler (xorshift32) so failures are reproducible.
    private static func deterministicBytes(_ count: Int) -> Data {
        var state: UInt32 = 0x9E37_79B9
        var out = Data(capacity: count)
        for _ in 0..<count {
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            let byte: UInt8 = UInt8(truncatingIfNeeded: state)
            out.append(contentsOf: [byte])
        }
        return out
    }

    private static func framingHex(_ hex: String) throws -> Data {
        let chars: [UInt8] = Array(hex.utf8)
        guard chars.count % 2 == 0 else { throw FramingHexDecodingError() }
        var out = Data(capacity: chars.count / 2)
        var index: Int = 0
        while index < chars.count {
            guard let high = framingNibble(chars[index]), let low = framingNibble(chars[index + 1]) else {
                throw FramingHexDecodingError()
            }
            let byte: UInt8 = (high << 4) | low
            out.append(contentsOf: [byte])
            index += 2
        }
        return out
    }

    private static func framingNibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x61...0x66: return c - 0x61 + 10
        case 0x41...0x46: return c - 0x41 + 10
        default: return nil
        }
    }
}
