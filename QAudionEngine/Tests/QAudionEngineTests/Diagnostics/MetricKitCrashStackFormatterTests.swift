import XCTest
@testable import QAudionEngine

final class MetricKitCrashStackFormatterTests: XCTestCase {

    private let uuidA = "0123ABCD-4567-89AB-CDEF-0123456789AB"
    private let uuidB = "FEDCBA98-7654-3210-FEDC-BA9876543210"

    /// MetricKit lists a stack outermost first: each frame holds its callee in `subFrames`.
    private func stack(attributed: Bool?, binaries: [(String, String, Int)]) -> [String: Any] {
        var node: [String: Any]?
        for (name, uuid, off) in binaries.reversed() {
            var f: [String: Any] = ["binaryName": name, "binaryUUID": uuid, "offsetIntoBinaryTextSegment": off]
            if let child = node { f["subFrames"] = [child] }
            node = f
        }
        var s: [String: Any] = ["callStackRootFrames": node.map { [$0] } ?? []]
        if let a = attributed { s["threadAttributed"] = a }
        return s
    }

    func test_attributedThreadIsChosenAndReported() {
        let root: [String: Any] = ["callStacks": [
            stack(attributed: false, binaries: [("QAudionApp", uuidA, 10)]),
            stack(attributed: true, binaries: [("QAudionApp", uuidA, 20)]),
        ]]
        let lines = MetricKitCrashStackFormatter.lines(from: root)
        XCTAssertEqual(lines.first,
                       "[MetricKit] crash threads total=2 attributed=1 attributed_count=1 chosen=1 pick=attributed shown=2")
        // The chosen thread is listed first.
        let threadLines = lines.filter { $0.contains("] thread ") }
        XCTAssertEqual(threadLines, [
            "[MetricKit] thread 1 attr=1 frames=1 shown=1",
            "[MetricKit] thread 0 attr=0 frames=1 shown=1",
        ])
    }

    func test_noAttributedThreadFallsBackToTheFirstAndSaysSo() {
        let root: [String: Any] = ["callStacks": [
            stack(attributed: nil, binaries: [("QAudionApp", uuidA, 10)]),
            stack(attributed: false, binaries: [("QAudionApp", uuidA, 20)]),
        ]]
        let lines = MetricKitCrashStackFormatter.lines(from: root)
        XCTAssertEqual(lines.first,
                       "[MetricKit] crash threads total=2 attributed=none attributed_count=0 chosen=0 pick=first shown=2")
    }

    func test_innermostFramesComeFirstAndOnlyTheLastTwelveAreKept() {
        // 20 frames, root is frame 0 with offset 0, leaf is frame 19.
        let bins: [(String, String, Int)] = (0..<20).map { ("QAudionApp", uuidA, $0) }
        let root: [String: Any] = ["callStacks": [stack(attributed: true, binaries: bins)]]
        let lines = MetricKitCrashStackFormatter.lines(from: root)
        XCTAssertTrue(lines.contains("[MetricKit] thread 0 attr=1 frames=20 shown=12"))
        let frames = lines.filter { $0.hasPrefix("[MetricKit] t0 f") }
        XCTAssertEqual(frames.count, 12)
        XCTAssertEqual(frames.first, "[MetricKit] t0 f0 QAudionApp + 19")
        XCTAssertEqual(frames.last, "[MetricKit] t0 f11 QAudionApp + 8")
    }

    func test_capsThreadsAtSix() {
        let stacks: [[String: Any]] = (0..<9).map { i in
            stack(attributed: i == 7, binaries: [("QAudionApp", uuidA, i)])
        }
        let lines = MetricKitCrashStackFormatter.lines(from: ["callStacks": stacks])
        XCTAssertEqual(lines.filter { $0.contains("] thread ") }.count, 6)
        XCTAssertTrue(lines.first!.contains("chosen=7"))
        XCTAssertTrue(lines.first!.contains("shown=6"))
        // The chosen thread is among the six even though it is index 7.
        XCTAssertTrue(lines.contains("[MetricKit] thread 7 attr=1 frames=1 shown=1"))
    }

    func test_eachBinaryUUIDIsWrittenOnceAndNeverAsADashedRun() {
        let root: [String: Any] = ["callStacks": [
            stack(attributed: true, binaries: [("QAudionApp", uuidA, 1), ("libsystem_kernel.dylib", uuidB, 2),
                                               ("QAudionApp", uuidA, 3)]),
            stack(attributed: false, binaries: [("QAudionApp", uuidA, 4)]),
        ]]
        let lines = MetricKitCrashStackFormatter.lines(from: root)
        let bins = lines.filter { $0.hasPrefix("[MetricKit] bin ") }
        XCTAssertEqual(bins.count, 2)
        XCTAssertTrue(bins.contains("[MetricKit] bin QAudionApp uuid=0123ABCD.4567.89AB.CDEF.0123456789AB"))
        XCTAssertTrue(bins.contains("[MetricKit] bin libsystem_kernel uuid=FEDCBA98.7654.3210.FEDC.BA9876543210"))
        for l in lines { XCTAssertFalse(l.contains(uuidA), l) }
    }

    func test_binaryNamesAreCleanedAndCut() {
        XCTAssertEqual(MetricKitCrashStackFormatter.cleanBinaryName("libsystem_kernel.dylib"), "libsystem_kernel")
        XCTAssertEqual(MetricKitCrashStackFormatter.cleanBinaryName("libswift_Concurrency.dylib"), "libswift_Concurren")
        XCTAssertEqual(MetricKitCrashStackFormatter.cleanBinaryName("a b/c"), "a_b_c")
        XCTAssertEqual(MetricKitCrashStackFormatter.cleanBinaryName(""), "?")
    }

    func test_missingFieldsDoNotCrashTheFormatter() {
        let leaf: [String: Any] = ["binaryName": "QAudionApp"]
        let top: [String: Any] = ["subFrames": [leaf]]
        let first: [String: Any] = ["callStackRootFrames": [top]]
        let empty: [String: Any] = [:]
        let root: [String: Any] = ["callStacks": [first, empty]]
        let lines = MetricKitCrashStackFormatter.lines(from: root)
        XCTAssertTrue(lines.contains("[MetricKit] t0 f0 QAudionApp + -1"))
        XCTAssertTrue(lines.contains("[MetricKit] t0 f1 ? + -1"))
        XCTAssertTrue(lines.contains("[MetricKit] bin ? uuid=?"))
        XCTAssertTrue(lines.contains("[MetricKit] thread 1 attr=0 frames=0 shown=0"))
        XCTAssertEqual(MetricKitCrashStackFormatter.lines(from: [:]), [])
    }
}
