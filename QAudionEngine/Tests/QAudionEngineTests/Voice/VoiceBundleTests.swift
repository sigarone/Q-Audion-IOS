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
        XCTAssertEqual(bundle.constants.fbank.embedSamples, 64_240)
        XCTAssertEqual(bundle.constants.fbank.embedFrames, 400)
        XCTAssertEqual(bundle.constants.gates.stats.overdueMs, 5500)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.vadModelURL.path))
    }

    /// What the manifest lists and this repository does not carry: the measurement report and the reading texts of the
    /// vectors (this repository is public), the cohort file and the vectors of the stages that nothing here runs (6 to 13,
    /// their inputs, and the two clips that only stage 13 reads). A name ending in "/" is a folder.
    private static let notShipped: [String] = [
        "report.md",
        "cohort.bin",
        "kat/README.md",
        "kat/README_stages5-7-13.md",
        "kat/README_stages8-10-12.md",
        "kat/README_stages11.md",
        "kat/audio/clip_g_16k.wav",
        "kat/audio/clip_i_16k.wav",
        "kat/inputs/",
        "kat/stage6_scoring/",
        "kat/stage7_evidence/",
        "kat/stage8_codec/",
        "kat/stage9_state/",
        "kat/stage10_vcons/",
        "kat/stage11_engine/",
        "kat/stage12_tier/",
        "kat/stage13_e2e/"
    ]

    private static func isNotShipped(_ path: String) -> Bool {
        notShipped.contains { $0.hasSuffix("/") ? path.hasPrefix($0) : path == $0 }
    }

    /// Every file of the manifest that is present (the runtime bundle and the reference vectors) hashes as listed, and the
    /// files that are not shipped are not here, the reading texts and the report above all.
    func testManifestListsTheShippedBytes() throws {
        let runtime = try runtimeDirectory()
        let kat = try VoiceKat.root()
        let manifestData = try Data(contentsOf: runtime.appendingPathComponent("MANIFEST.sha256"))
        XCTAssertEqual(
            VoiceHash.sha256Hex(manifestData),
            "93593a13cf084beeae5461471a351862bb69b4549f7001969e8bbb6cbb4cc09c")
        let text = String(decoding: manifestData, as: UTF8.self)
        var checked = 0
        var skipped = 0
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.components(separatedBy: "  ")
            XCTAssertEqual(parts.count, 2, "manifest line: \(line)")
            guard parts.count == 2 else { continue }
            let path = parts[1]
            let url: URL
            if path.hasPrefix("kat/") {
                url = kat.appendingPathComponent(String(path.dropFirst(4)))
            } else {
                url = runtime.appendingPathComponent(path)
            }
            if Self.isNotShipped(path) {
                XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "\(path) must not be shipped")
                skipped += 1
                continue
            }
            let data = try Data(contentsOf: url)
            XCTAssertEqual(VoiceHash.sha256Hex(data), parts[0], path)
            checked += 1
        }
        XCTAssertEqual(checked, 79)
        XCTAssertEqual(skipped, 122)
        // No reading text of the vectors and no report in the shipped folders, whatever the manifest lists.
        for directory in [runtime, kat] {
            let names = FileManager.default.enumerator(atPath: directory.path)?.compactMap { $0 as? String } ?? []
            XCTAssertFalse(names.isEmpty)
            for name in names {
                let leaf = (name as NSString).lastPathComponent
                XCTAssertFalse(leaf.hasPrefix("README"), "\(name) must not be shipped")
                XCTAssertNotEqual(leaf, "report.md", "\(name) must not be shipped")
            }
        }
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
