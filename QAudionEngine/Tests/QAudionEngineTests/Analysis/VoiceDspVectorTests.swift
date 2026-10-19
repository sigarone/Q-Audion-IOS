import XCTest
@testable import QAudionEngine

/// Runs every case of `voicedsp-vectors.json` through the real engine entry point
/// (`VoiceAnalysisEngine.processFrame` / `markDiscontinuity` / the `onResult` and
/// `onDisplay` callbacks) and checks every output of every step against the
/// reference implementation of the specification (docs/voice-analysis-spec.md): 28 cases, 804 steps, each
/// case at 10, 20 and 60 ms chunks (the chunking case also at 1 and 7 ms).
///
/// The vectors file is a byte-for-byte copy of the one that ships with the
/// specification and with the Android tests, and it is not edited here: it comes
/// from the reference implementation, and a mismatch means the engine differs from
/// the specification, not that the vector is wrong. Booleans must match exactly. A
/// number passes when |got - expected| <= abs + rel * |expected|, with the
/// tolerance of its field from the file; those tolerances are 60 to 1000 times the
/// difference that plain summation and float32 storage cause.
final class VoiceDspVectorTests: XCTestCase {

    // MARK: - The vectors

    private struct Tolerance {
        let abs: Double
        let rel: Double
    }

    private struct Document {
        let fields: [String]
        let tolerance: [String: Tolerance]
        let cases: [[String: Any]]
    }

    private static var cachedDocument: Document?

    /// How many values of each field were compared, so that a field the test silently skips (a name that
    /// does not match, a column that is missing) fails the test instead of passing it.
    private var compared: [String: Int] = [:]

    private func document() throws -> Document {
        if let cached = Self.cachedDocument { return cached }
        guard let url = Bundle.module.url(forResource: "voicedsp-vectors", withExtension: "json") else {
            throw NSError(domain: "VoiceDspVectorTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "voicedsp-vectors.json not found in Bundle.module"])
        }
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fields = root["fields"] as? [String],
              let tolerances = root["tolerance"] as? [String: [String: Any]],
              let cases = root["cases"] as? [[String: Any]] else {
            throw NSError(domain: "VoiceDspVectorTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "voicedsp-vectors.json has an unexpected shape"])
        }
        var tolerance: [String: Tolerance] = [:]
        for (field, t) in tolerances {
            tolerance[field] = Tolerance(abs: Self.number(t["abs"]), rel: Self.number(t["rel"]))
        }
        let doc = Document(fields: fields, tolerance: tolerance, cases: cases)
        Self.cachedDocument = doc
        return doc
    }

    private static func number(_ any: Any?) -> Double {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        return 0
    }

    private static func numbers(_ any: Any?) -> [Double] {
        ((any as? [Any]) ?? []).map { number($0) }
    }

    private func spec(of testCase: [String: Any]) -> [String: Any] { testCase["case"] as! [String: Any] }
    private func name(of testCase: [String: Any]) -> String { testCase["name"] as! String }

    // MARK: - Running the engine

    private struct Run {
        var raw: [VoiceAnalysisResult] = []
        var display: [VoiceAnalysisResult] = []
    }

    /// Feeds `pcm` to a fresh engine in chunks of `chunkSamples`, splitting at every
    /// event and calling `markDiscontinuity` there, exactly as the vectors describe.
    private func run(pcm: [Int16], events: [(at: Int, gap: Int)], chunkSamples: Int) -> Run {
        let engine = VoiceAnalysisEngine()
        var out = Run()
        engine.onResult = { out.raw.append($0) }
        engine.onDisplay = { out.display.append($0) }
        let cuts = Array(Set([0, pcm.count] + events.map { $0.at })).sorted()
        for index in 0..<(cuts.count - 1) {
            let a = cuts[index]
            let b = cuts[index + 1]
            for event in events where event.at == a { engine.markDiscontinuity(missingSamples: event.gap) }
            var i = a
            while i < b {
                let j = min(b, i + chunkSamples)
                engine.processFrame(VoiceDspVectorGenerator.data(pcm[i..<j]))
                i = j
            }
        }
        return out
    }

    /// The values of a result under the names of the vectors file.
    private func values(of r: VoiceAnalysisResult) -> (numbers: [String: Double], flags: [String: Bool]) {
        let numbers: [String: Double] = [
            "f0": Double(r.pitch.f0Hz),
            "periodicity": Double(r.pitch.periodicity),
            "F1": Double(r.formants.f1),
            "F2": Double(r.formants.f2),
            "HNR": Double(r.voiceHealth.hnr),
            "breathiness": Double(r.voiceHealth.breathiness),
            "rate": Double(r.speechRate.syllablesPerSec),
            "pauseRatio": Double(r.speechRate.pauseRatio),
            "rms": Double(r.pitch.rms),
        ]
        let flags: [String: Bool] = [
            "f0Valid": r.pitch.f0Valid,
            "voiced": r.pitch.voiced,
            "F1Found": r.formants.f1Found,
            "F2Found": r.formants.f2Found,
            "hnrValid": r.voiceHealth.hnrValid,
            "rateValid": r.speechRate.valid,
            "isSpeaking": r.speechRate.isSpeaking,
        ]
        return (numbers, flags)
    }

    /// Mismatches between `results` and the expected series `expected` (a dictionary of
    /// per-field columns: a string of 0/1 for a flag, an array of numbers otherwise).
    private func mismatches(_ label: String, steps: Int, expected: [String: Any],
                            results: [VoiceAnalysisResult], doc: Document) -> [String] {
        var out: [String] = []
        if results.count != steps {
            out.append("\(label): \(results.count) results, expected \(steps)")
        }
        for field in doc.fields {
            guard let column = expected[field] else { continue }
            for i in 0..<min(results.count, steps) {
                let got = values(of: results[i])
                if let flags = column as? String {
                    let want = Array(flags)[i] == "1"
                    if let have = got.flags[field] {
                        compared[field, default: 0] += 1
                        if have != want {
                            out.append("\(label) step \(i + 1) \(field): expected \(want ? 1 : 0), got \(have ? 1 : 0)")
                        }
                    }
                } else if let have = got.numbers[field], let tol = doc.tolerance[field] {
                    let want = Self.numbers(column)[i]
                    compared[field, default: 0] += 1
                    if !(abs(have - want) <= tol.abs + tol.rel * abs(want)) {
                        out.append("\(label) step \(i + 1) \(field): expected \(want), got \(have)")
                    }
                }
            }
        }
        return out
    }

    // MARK: - Tests

    /// The generator port reproduces the reference's int16 input bit for bit, for every
    /// case. This comes first so that a wrong port is not mistaken for a wrong engine.
    func testTheGeneratorPortReproducesTheReferenceInputs() throws {
        let doc = try document()
        XCTAssertEqual(doc.cases.count, 28)
        for testCase in doc.cases {
            let label = name(of: testCase)
            let (pcm, events) = VoiceDspVectorGenerator.build(spec(of: testCase))
            XCTAssertEqual(pcm.count, testCase["n_samples"] as? Int, "\(label): sample count")
            let hash = String(format: "0x%08x", VoiceDspVectorGenerator.fnv1a32(pcm))
            var sum = 0
            for s in pcm { sum += Int(s) }
            if hash != testCase["pcm_fnv1a32"] as? String {
                // Say which sample can differ: the generator uses the platform's libm (sin, cos, exp, pow),
                // which may differ from the reference's by one ulp, and that flips an int16 only at a rounding
                // boundary. A failure here is a generator-port failure, not an engine failure.
                let want = testCase["pcm_fnv1a32"] as? String ?? ""
                let expected = UInt32(want.dropFirst(2), radix: 16) ?? 0
                let why = VoiceDspVectorGenerator.explainHashMismatch(
                    quantiserInput: VoiceDspVectorGenerator.quantiserInput(spec(of: testCase)),
                    expectedHash: expected)
                XCTFail("\(label): FNV-1a of the PCM is \(hash), expected \(want); the sum of the PCM is \(sum), "
                        + "expected \(testCase["pcm_sum"] as? Int ?? 0). \(why)")
            }
            XCTAssertEqual(sum, testCase["pcm_sum"] as? Int, "\(label): sum of the PCM")
            let wanted = (testCase["events_samples"] as? [[Int]]) ?? []
            XCTAssertEqual(events.map { [$0.at, $0.gap] }, wanted, "\(label): events")
        }
    }

    /// The message of a failing hash check names the sample that came out differently, when a one-ulp libm
    /// difference at a rounding boundary can explain it. The inputs here are made up: the real cases have no
    /// sample that close to a boundary, which is what makes the port bit-exact.
    func testTheHashDiagnosisNamesTheSampleThatFlippedAtARoundingBoundary() {
        var input: [Double] = (0..<400).map { Double($0) * 7.31 + 0.2137 }
        input[17] = 1234.0 + 3e-12                 // floors to 1234; one ulp lower it would floor to 1233
        input[203] = -88.0 - 3e-12                 // floors to -89; one ulp higher it would floor to -88
        var other = input
        other[17] = 1234.0 - 3e-12
        let oneFlip = VoiceDspVectorGenerator.fnv1a32(VoiceDspVectorGenerator.quantise(other))
        XCTAssertNotEqual(oneFlip, VoiceDspVectorGenerator.fnv1a32(VoiceDspVectorGenerator.quantise(input)))
        let single = VoiceDspVectorGenerator.explainHashMismatch(quantiserInput: input, expectedHash: oneFlip)
        XCTAssertTrue(single.contains("rounding sample 17 the other way"), single)
        XCTAssertTrue(single.contains("2 sample(s) lie within"), single)

        other[203] = -88.0 + 3e-12
        let twoFlips = VoiceDspVectorGenerator.fnv1a32(VoiceDspVectorGenerator.quantise(other))
        let pair = VoiceDspVectorGenerator.explainHashMismatch(quantiserInput: input, expectedHash: twoFlips)
        XCTAssertTrue(pair.contains("samples 17 and 203 the other"), pair)

        let unrelated = VoiceDspVectorGenerator.explainHashMismatch(quantiserInput: input, expectedHash: 0x1234_5678)
        XCTAssertTrue(unrelated.contains("does not reproduce the expected hash"), unrelated)

        let away = (0..<100).map { Double($0) * 3.7 + 0.31 }
        let none = VoiceDspVectorGenerator.explainHashMismatch(quantiserInput: away, expectedHash: 1)
        XCTAssertTrue(none.contains("not libm noise"), none)
    }

    /// Every output of every step of every case, at every chunk size, and the display
    /// series of the cases that have one.
    func testEveryVectorMatchesTheEngine() throws {
        compared = [:]
        let doc = try document()
        var failures: [String] = []
        var checked = 0
        for testCase in doc.cases {
            let label = name(of: testCase)
            let (pcm, events) = VoiceDspVectorGenerator.build(spec(of: testCase))
            let steps = testCase["steps"] as! Int
            let expected = testCase["expected"] as! [String: Any]
            let chunks = Self.numbers(testCase["chunk_ms"]).map { Int($0) }
            XCTAssertFalse(chunks.isEmpty, label)
            for ms in chunks {
                let run = self.run(pcm: pcm, events: events, chunkSamples: ms * 48)
                failures += mismatches("\(label)@\(ms)ms", steps: steps, expected: expected,
                                       results: run.raw, doc: doc)
                if let display = testCase["display"] as? [String: Any] {
                    failures += mismatches("\(label)@\(ms)ms display", steps: steps, expected: display,
                                           results: run.display, doc: doc)
                }
                checked += steps
            }
        }
        XCTAssertGreaterThan(checked, 2_000, "the vectors file was not read in full")
        for field in doc.fields {
            XCTAssertGreaterThan(compared[field] ?? 0, 2_000, "\(field) was not compared")
        }
        XCTAssertTrue(failures.isEmpty,
                      "\(failures.count) mismatches against the vectors, first ones:\n"
                        + failures.prefix(25).joined(separator: "\n"))
    }

    /// Whatever the chunking, the result list is identical, not just close: the engine
    /// processes sample by sample, and a step falls at its exact sample.
    func testTheResultsDoNotDependOnTheChunkSize() throws {
        let doc = try document()
        guard let testCase = doc.cases.first(where: { name(of: $0) == "chunking" }) else {
            return XCTFail("no chunking case")
        }
        let (pcm, events) = VoiceDspVectorGenerator.build(spec(of: testCase))
        let base = run(pcm: pcm, events: events, chunkSamples: 480)
        XCTAssertGreaterThan(base.raw.count, 50)
        for chunk in [1, 7 * 48, 960, 2_880, 4_800, 24_000] {
            let other = run(pcm: pcm, events: events, chunkSamples: chunk)
            XCTAssertEqual(other.raw.count, base.raw.count, "chunk \(chunk)")
            for i in 0..<min(base.raw.count, other.raw.count) {
                let a = values(of: base.raw[i])
                let b = values(of: other.raw[i])
                XCTAssertEqual(a.numbers, b.numbers, "chunk \(chunk), step \(i + 1)")
                XCTAssertEqual(a.flags, b.flags, "chunk \(chunk), step \(i + 1)")
            }
        }
    }
}
