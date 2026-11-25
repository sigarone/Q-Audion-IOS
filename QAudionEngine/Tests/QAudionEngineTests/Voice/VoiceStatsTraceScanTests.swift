import XCTest
import Foundation
@testable import QAudionEngine

/// A release build has no path that writes the local stats trace: the writer exists only inside `#if DEBUG`, and no other file
/// names it. The tests run against the sources, so a release build cannot differ from what is checked here.
final class VoiceStatsTraceScanTests: XCTestCase {
    private func voiceSources(file: StaticString = #filePath) throws -> [URL] {
        var dir = URL(fileURLWithPath: "\(file)")
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let voice = dir.appendingPathComponent("Sources/QAudionEngine", isDirectory: true)
            if FileManager.default.fileExists(atPath: voice.path) {
                return PeerConnectionStatsGateScanTests.sourceFiles(under: voice)
            }
        }
        XCTFail("sources not found")
        throw CocoaError(.fileNoSuchFile)
    }

    func testTheWriterIsInsideADebugConditionAndNoOtherFileNamesIt() throws {
        let files = try voiceSources()
        var holder: URL?
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("VoiceStatsTraceWriter") {
                if url.lastPathComponent == "VoiceStatsTrace.swift" { holder = url } else {
                    XCTFail("\(url.lastPathComponent) names the trace writer")
                }
            }
        }
        let text = try String(contentsOf: try XCTUnwrap(holder), encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        let open = try XCTUnwrap(lines.firstIndex(of: "#if DEBUG"))
        let otherwise = try XCTUnwrap(lines.firstIndex(of: "#else"))
        let close = try XCTUnwrap(lines.lastIndex(of: "#endif"))
        XCTAssertLessThan(open, otherwise)
        XCTAssertLessThan(otherwise, close)
        let writerLine = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("final class VoiceStatsTraceWriter") })
        XCTAssertGreaterThan(writerLine, open)
        XCTAssertLessThan(writerLine, otherwise, "the writer is in the debug branch")
        // Everything that writes a file is in that branch.
        for (i, line) in lines.enumerated() where line.contains("FileHandle") || line.contains("createFile") || line.contains(".write(") {
            XCTAssertTrue(i > open && i < otherwise, "line \(i + 1) writes outside the debug branch")
        }
        let release = lines[(otherwise + 1)..<close].joined(separator: "\n")
        XCTAssertFalse(release.contains("FileHandle"))
        XCTAssertFalse(release.contains("write"))
    }

    func testTheCallWiringReachesTheTraceOnlyThroughTheHook() throws {
        for url in try voiceSources() where url.lastPathComponent != "VoiceStatsTrace.swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.contains("voice-trace"), url.lastPathComponent)
            XCTAssertFalse(text.contains("voice.trace.recording"), url.lastPathComponent)
        }
    }
}
