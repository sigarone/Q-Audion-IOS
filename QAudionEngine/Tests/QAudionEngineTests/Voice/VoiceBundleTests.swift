import XCTest
import Foundation
@testable import QAudionEngine

final class VoiceBundleTests: XCTestCase {

    private func runtimeDirectory() throws -> URL {
        try XCTUnwrap(VoiceBundle.moduleDirectory(), "voice bundle not found in the module resources")
    }

    private func temporaryCopy(of directory: URL) throws -> URL {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: directory, to: target)
        return target
    }

    func testBundleLoadsFromModuleResources() throws {
        let bundle = try VoiceBundle.loadFromModule()
        XCTAssertEqual(bundle.constants.vad.chunk, 512)
        XCTAssertEqual(bundle.constants.window.chunks, 128)
        XCTAssertEqual(bundle.constants.resampler.filters["48000"]?.taps.count, 288)
        XCTAssertEqual(bundle.constants.resampler.filters["32000"]?.taps.count, 192)
        XCTAssertEqual(bundle.constants.resampler.filters["24000"]?.taps.count, 288)
        XCTAssertEqual(bundle.tables.melOffset.last, bundle.tables.melWeights.count)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.vadModelURL.path))
    }

    /// Every file of the manifest that is present (the runtime bundle and the reference vectors) hashes as listed.
    func testManifestListsTheShippedBytes() throws {
        let runtime = try runtimeDirectory()
        let kat = try VoiceKat.root()
        let manifestData = try Data(contentsOf: runtime.appendingPathComponent("MANIFEST.sha256"))
        XCTAssertEqual(
            VoiceHash.sha256Hex(manifestData),
            "f605b88b2f74d564e7acf43224a207896a5276717103f096be371104c04c17a1")
        let text = String(decoding: manifestData, as: UTF8.self)
        // Two entries of the bundle manifest have no file here: the measurement report and a text file of the vectors.
        let notShipped: Set<String> = ["report.md", "kat/README.md"]
        var checked = 0
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.components(separatedBy: "  ")
            XCTAssertEqual(parts.count, 2, "manifest line: \(line)")
            guard parts.count == 2 else { continue }
            let path = parts[1]
            if notShipped.contains(path) {
                continue
            }
            let url: URL
            if path.hasPrefix("kat/") {
                url = kat.appendingPathComponent(String(path.dropFirst(4)))
            } else {
                url = runtime.appendingPathComponent(path)
            }
            let data = try Data(contentsOf: url)
            XCTAssertEqual(VoiceHash.sha256Hex(data), parts[0], path)
            checked += 1
        }
        XCTAssertGreaterThan(checked, 60)
    }

    func testAFileWithAWrongHashIsRejected() throws {
        let runtime = try runtimeDirectory()
        for name in [VoiceBundle.constantsFile, VoiceBundle.tablesFile, VoiceBundle.vadFile] {
            let copy = try temporaryCopy(of: runtime)
            defer { try? FileManager.default.removeItem(at: copy) }
            let url = copy.appendingPathComponent(name)
            var bytes = try Data(contentsOf: url)
            bytes[bytes.count / 2] ^= 0x01
            try bytes.write(to: url, options: .atomic)
            XCTAssertThrowsError(try VoiceBundle.load(directory: copy), name) { error in
                XCTAssertEqual(error as? VoiceBundleError, VoiceBundleError.hashMismatch(name))
            }
        }
    }

    func testAMissingFileIsRejected() throws {
        let runtime = try runtimeDirectory()
        let copy = try temporaryCopy(of: runtime)
        defer { try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.removeItem(at: copy.appendingPathComponent(VoiceBundle.tablesFile))
        XCTAssertThrowsError(try VoiceBundle.load(directory: copy)) { error in
            XCTAssertEqual(error as? VoiceBundleError, VoiceBundleError.missingFile(VoiceBundle.tablesFile))
        }
    }
}
