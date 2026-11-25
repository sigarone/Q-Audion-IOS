import XCTest
import Foundation

/// The registry of the statistics calls only works if every call goes through it. This test reads the non-test Swift sources, one
/// line at a time, and fails when a `statistics` CALL appears anywhere but in the gate file.
///
/// The pattern matches the call forms and not the API name: every call site of the app is a trailing closure,
/// `pc.statistics { report in ... }`, with no parenthesis after the name, so a scan for `statistics(` passes on code that
/// bypasses the gate. The pattern also matches the selector forms (`statistics(for:`), the form with the handler named and the
/// argument-less async form `await pc.statistics()`. It skips comments and the lines that start with `for`: `for (_, s) in
/// report.statistics {` is a loop over a property, not a call.
final class PeerConnectionStatsGateScanTests: XCTestCase {
    static let gateFile = "PeerConnectionStatsGate.swift"

    static let pattern = try! NSRegularExpression(
        pattern: #"\.statistics\s*(\(\s*(completionHandler\s*:|for\s*:|\))|\{)"#)

    /// True when the line is a `statistics` call.
    static func isCall(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") { return false }
        if trimmed == "for" || trimmed.hasPrefix("for ") || trimmed.hasPrefix("for(") { return false }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return pattern.firstMatch(in: line, range: range) != nil
    }

    /// The repository root (the folder that holds both the engine package and the app), found from this file.
    private func repositoryRoot(file: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(file)")
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let engine = dir.appendingPathComponent("QAudionEngine/Sources/QAudionEngine", isDirectory: true)
            if FileManager.default.fileExists(atPath: engine.path) { return dir }
        }
        XCTFail("repository root not found from the test sources")
        throw CocoaError(.fileNoSuchFile)
    }

    /// Every non-test Swift file of the repository: no folder named like a test target, no hidden folder, no build output.
    static func sourceFiles(under root: URL) -> [URL] {
        let skipped: Set<String> = ["Tests", "QAudionAppTests", "DerivedData", "tools", "docs", "node_modules"]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var out: [URL] = []
        for case let url as URL in walker {
            let name = url.lastPathComponent
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                if skipped.contains(name) { walker.skipDescendants() }
                continue
            }
            if name.hasSuffix(".swift") { out.append(url) }
        }
        return out
    }

    /// `path:line` of every call outside the gate file.
    static func flagged(in files: [URL]) -> [String] {
        var out: [String] = []
        for url in files where url.lastPathComponent != gateFile {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where isCall(String(line)) {
                out.append("\(url.lastPathComponent):\(i + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        return out
    }

    func testNoStatisticsCallIsMadeOutsideTheGate() throws {
        let root = try repositoryRoot()
        let files = Self.sourceFiles(under: root)
        XCTAssertGreaterThan(files.count, 500, "the scan reads the sources of the engine and of the app")
        XCTAssertTrue(files.contains { $0.lastPathComponent == Self.gateFile }, "the gate file is among the sources")
        XCTAssertTrue(files.contains { $0.lastPathComponent == "AppState.swift" }, "the app sources are scanned too")
        let flagged = Self.flagged(in: files)
        XCTAssertTrue(flagged.isEmpty, "statistics calls outside the gate:\n" + flagged.joined(separator: "\n"))
    }

    /// The pattern sees every form of a call, so a green scan means something.
    func testThePatternMatchesTheCallFormsAndNotTheLoops() {
        let calls = [
            "pc.statistics { report in",
            "            pc.statistics { [weak self] report in",
            "pc.statistics { report in continuation.resume(returning: report) }",
            "pc.statistics(for: receiver) { report in",
            "pc.statistics(for: sender, completionHandler: { _ in })",
            "pc.statistics(completionHandler: { report in",
            "let report = await pc.statistics()",
            "peerConnection?.statistics {",
            "pc.statistics (for: r) {"
        ]
        for line in calls { XCTAssertTrue(Self.isCall(line), line) }
        let notCalls = [
            "for (_, s) in report.statistics {",
            "    for (statId, s) in report.statistics {",
            "for (_, st) in report.statistics where st.type == \"inbound-rtp\" {",
            "let local = report.statistics[localId]",
            "/// `pc.statistics { report in }` is the call",
            "// pc.statistics {",
            "statsGate.statistics(of: pc) { report in",
            "gate.statistics(of: pc, for: receiver, stamped: { report, stamp in"
        ]
        for line in notCalls { XCTAssertFalse(Self.isCall(line), line) }
    }

    /// The gate file itself holds the native calls, so the scan does see them there: the exemption is the only reason it passes.
    func testTheGateFileHoldsTheNativeCalls() throws {
        let root = try repositoryRoot()
        let gate = Self.sourceFiles(under: root).first { $0.lastPathComponent == Self.gateFile }
        let text = try String(contentsOf: try XCTUnwrap(gate), encoding: .utf8)
        let calls = text.split(separator: "\n").filter { Self.isCall(String($0)) }
        XCTAssertEqual(calls.count, 4, "whole connection (twice), one receiver, one sender")
    }
}
