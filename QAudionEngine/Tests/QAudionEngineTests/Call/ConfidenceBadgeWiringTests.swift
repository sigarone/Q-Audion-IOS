import XCTest
@testable import QAudionEngine

/// W-CONFBADGE1SRC (2026-10-07) — the in-call "C=" badge has ONE source, as on Android.
///
/// The defect: `AppState.confidenceScore` / `confidenceLevel` had two writers. Tier 2's
/// `onContactVoiceScoreBreakdown` closure published the EMA of the 3-signal combine every few seconds
/// (W-GUARDIAN3SIG, the Android-equivalent value), and the 5 Hz confidence-wave sampler overwrote it
/// every 200 ms with Tier 1's `ConfidenceIndex.currentScore`, a different quantity seeded at 0.5. Logs of
/// 2026-10-07: `conf_poll scorex100=50` for whole calls while `guardian3sig ... combined=0.99` on every
/// tick, so the badge read 0.50 in amber. `GuardianDisplayConfidenceTests` pins the value; this pins the
/// wiring, which cannot be driven here (MainActor `AppState`, timers, a live call), as SOURCE INVARIANTS,
/// the same choice `BadgeAndBusyHoldWiringTests` makes. Comments are stripped and whitespace collapsed
/// before matching, so only code counts. A missing file or marker FAILS: it never skips.
final class ConfidenceBadgeWiringTests: XCTestCase {

    private struct SourceProblem: Error, CustomStringConvertible {
        let what: String
        var description: String { what }
    }

    /// An app source file (default `QAudionApp/AppState.swift`) from the repository root, comments stripped,
    /// whitespace collapsed.
    private func appCode(
        _ relativePath: String = "QAudionApp/AppState.swift", file: StaticString = #filePath, line: UInt = #line
    ) throws -> String {
        var dir = URL(fileURLWithPath: "\(file)")
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                let raw = try String(contentsOf: candidate, encoding: .utf8)
                let withoutComments = raw
                    .split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
                    .map { line -> Substring in
                        if let r = line.range(of: "//") { return line[line.startIndex..<r.lowerBound] }
                        return line
                    }
                    .joined(separator: "\n")
                return withoutComments.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            }
        }
        XCTFail("\(relativePath) not found from \(file): the wiring invariants cannot run", file: file, line: line)
        throw SourceProblem(what: "source file not found: \(relativePath)")
    }

    /// The text between the braces of the function declared as `declaration` (which ends with its opening brace).
    private func body(
        of declaration: String, in code: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> String {
        let start = try XCTUnwrap(code.range(of: declaration), "declaration not found: \(declaration)", file: file, line: line)
        var depth = 1
        var index = start.upperBound
        while index < code.endIndex {
            let ch = code[index]
            if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 { return String(code[start.upperBound..<index]) }
            }
            index = code.index(after: index)
        }
        XCTFail("unbalanced braces after: \(declaration)", file: file, line: line)
        throw SourceProblem(what: "unbalanced braces after \(declaration)")
    }

    /// The text from the first `start` to the next `end` after it. Both must exist.
    private func slice(
        _ code: String, from start: String, to end: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> String {
        let s = try XCTUnwrap(code.range(of: start), "marker not found: \(start)", file: file, line: line)
        let e = try XCTUnwrap(
            code.range(of: end, range: s.upperBound..<code.endIndex),
            "end marker not found after \(start): \(end)", file: file, line: line)
        return String(code[s.lowerBound..<e.lowerBound])
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    /// The 5 Hz wave sampler reads Tier 1 for the wave and the `conf_poll` log line only; it never writes
    /// the badge.
    func testWaveSamplerDoesNotWriteTheBadge() throws {
        let sampler = try body(of: "private func startVoiceConfidenceWaveSampler() {", in: try appCode())
        XCTAssertTrue(sampler.contains("scoreHistory"), "the sampler still feeds the wave from Tier 1")
        XCTAssertFalse(sampler.contains("confidenceScore ="), "Tier 1 must not write the C= badge value")
        XCTAssertFalse(sampler.contains("confidenceLevel ="), "Tier 1 must not write the C= badge level")
    }

    /// Exactly one non-reset writer of the badge value, inside the Tier 2 breakdown closure, through
    /// `GuardianDisplayConfidence`. The other two writes are the "no score yet" resets (-1).
    func testTier2BreakdownIsTheOnlyLiveWriter() throws {
        let code = try appCode()
        XCTAssertEqual(occurrences(of: "confidenceScore = ", in: code), 3,
                       "confidenceScore: one live writer + the two -1 resets, nothing else")
        XCTAssertEqual(occurrences(of: "confidenceScore = -1", in: code), 2)
        XCTAssertEqual(occurrences(of: "self.confidenceScore = self.contactVoiceConfidenceEma", in: code), 1)
        XCTAssertEqual(occurrences(of: "confidenceLevel = ", in: code), 3,
                       "confidenceLevel: one live writer + the two resets, nothing else")
        XCTAssertEqual(occurrences(of: "confidenceLevel = \"green\"", in: code), 2)

        let breakdown = try slice(code, from: "callService.onContactVoiceScoreBreakdown = {",
                                  to: "callService.onLocalInboundLossReport")
        // Spaces removed: the wiring, not the line wrapping, is what is pinned.
        let compact = breakdown.replacingOccurrences(of: " ", with: "")
        XCTAssertTrue(compact.contains(
            "self.contactVoiceConfidenceEma=GuardianDisplayConfidence.next(ema:self.contactVoiceConfidenceEma,combined:combined)"))
        XCTAssertTrue(compact.contains("self.confidenceScore=self.contactVoiceConfidenceEma"))
        XCTAssertTrue(compact.contains(
            "self.confidenceLevel=GuardianDisplayConfidence.level(of:self.contactVoiceConfidenceEma)"))
    }

    /// The per-call reset puts the EMA back to Android's per-call seed and the badge to "no score yet".
    func testEndOfCallResetsTheEmaToTheSeed() throws {
        let code = try appCode()
        XCTAssertTrue(code.contains("contactVoiceConfidenceEma = 1 confidenceScore = -1 confidenceLevel = \"green\""))
        XCTAssertEqual(GuardianDisplayConfidence.seed, 1)
    }

    /// W-CONFNEUTRAL (2026-10-07) — every view that colours the C= value goes through
    /// `ConfidenceThresholds.tone(of:)`, whose `.noReading` (the -1 sentinel) is neutral. None uses the clamping
    /// `category(of:)`, which turns -1 into 0 and paints red: on the previous main the avatar halo did exactly
    /// that for the 10-16 s before Tier 2's first reading.
    func testNoReadingIsNeutralWhereverTheConfidenceIsPainted() throws {
        let screen = try appCode("QAudionApp/Views/Call/InCallScreen.swift")
        XCTAssertFalse(screen.contains("ConfidenceThresholds.category(of:"), "InCallScreen must not clamp the sentinel")
        XCTAssertTrue(screen.contains("AvatarHalo(color: confidenceColor"))
        let halo = try body(of: "private var confidenceColor: Color {", in: screen)
        XCTAssertTrue(halo.contains("ConfidenceThresholds.tone(of: confidence)"))
        XCTAssertTrue(halo.contains("case .noReading: return scheme.onSurfaceVariant"))

        let strip = try appCode("QAudionApp/Views/Chat/Components/SessionStatusStrip.swift")
        XCTAssertFalse(strip.contains("ConfidenceThresholds.category(of:"))
        XCTAssertTrue(strip.contains("case .noReading: return scheme.onSurfaceVariant"))

        let badge = try appCode("QAudionApp/Views/CallSecurityBadge.swift")
        let dot = try body(of: "private var dotColor: Color {", in: badge)
        XCTAssertTrue(dot.contains(
            "guard ConfidenceThresholds.tone(of: Double(appState.confidenceScore)) != .noReading else { return .gray }"))
    }
}
