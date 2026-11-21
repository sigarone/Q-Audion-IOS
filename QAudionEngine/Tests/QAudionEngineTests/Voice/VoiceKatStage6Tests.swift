import XCTest
import Foundation
@testable import QAudionEngine

/// Stage 6: s, s_as, l, l_c and the AS-norm diagnostics within abs 1e-3 for every `window` case, and the centroid vectors
/// within abs 1e-5 per component for every `centroid` case; plus the call-local reference selection and the cohort loader.
final class VoiceKatStage6Tests: XCTestCase {

    private var s6: KatJSON = .null
    private var vectors: [Float] = []
    private var cases: [KatJSON] = []

    override func setUpWithError() throws {
        s6 = try VoiceKat.json("stage6_scoring/stage6.json")
        vectors = try VoiceKat.floats("stage6_scoring/vectors.f32")
        cases = s6["cases"].array
    }

    private func row(_ i: Int) -> [Float] {
        Array(vectors[(512 * i)..<(512 * i + 512)])
    }

    private func unitOfRaw(_ path: String) throws -> [Float] {
        let raw = try VoiceKat.floats(path)
        return VoiceMath.unit(raw, norm: VoiceMath.norm(raw))
    }

    private func centroid(of c: KatJSON) throws -> [Float] {
        let inputs = c["inputs"]
        var list: [[Float]] = []
        if !inputs["vectors"].isNull {
            list = inputs["vectors"].ints.map { row($0) }
        } else {
            list = try inputs["raw_files"].array.map { try unitOfRaw($0.string) }
        }
        return try VoiceCentroid.of(list)
    }

    private func cohort(of c: KatJSON) throws -> VoiceCohort {
        let spec = c["cohort"]
        if spec.stringValue == "bundle" { return try VoiceScoringKat.cohort() }
        let range = spec["vectors"].ints
        XCTAssertEqual(range.count, 2, c["name"].string)
        return try VoiceCohort(rows: Array(vectors[(512 * range[0])..<(512 * (range[0] + range[1]))]), count: range[1])
    }

    private func template(of c: KatJSON) throws -> [Float] {
        let t = c["template"]
        if !t["raw_file"].isNull { return try unitOfRaw(t["raw_file"].string) }
        if !t["vec"].isNull { return row(t["vec"].int) }
        let ref = try XCTUnwrap(cases.first { $0["name"].string == t["centroid_case"].string })
        return row(ref["expected_vec"].int)
    }

    private func embedding(of c: KatJSON) throws -> (unit: [Float], norm: Double) {
        let e = c["embedding"]
        let norm = e["norm"].double
        if !e["raw_file"].isNull {
            return (VoiceMath.unit(try VoiceKat.floats(e["raw_file"].string), norm: norm), norm)
        }
        return (row(e["vec"].int), norm)
    }

    func testTheFileIsTheOneThisTestReads() {
        XCTAssertEqual(s6["tolerance"]["abs"].double, 1e-3)
        XCTAssertEqual(s6["tolerance"]["centroid_abs"].double, 1e-5)
        XCTAssertEqual(s6["sd_floor"].double, VoiceScorer.sdFloor)
        XCTAssertEqual(s6["vector_count"].int, 28)
        XCTAssertEqual(vectors.count, 28 * 512)
        XCTAssertEqual(cases.count, 50)
        XCTAssertEqual(Set(cases.map { $0["kind"].string }), ["window", "centroid"])
    }

    func testEveryWindowCaseGivesTheStoredScoresAndDiagnostics() throws {
        var n = 0
        for c in cases where c["kind"].string == "window" {
            n += 1
            let name = c["name"].string
            let qmf = QmfConstants(q: c["qmf"]["q"].doubles, lClip: c["qmf"]["l_clip"].double)
            let scorer = try VoiceScorer(cohort: try cohort(of: c), topN: c["top_n"].int, qmf: qmf)
            let e = try embedding(of: c)
            let prepared = try scorer.prepare(try template(of: c))
            let got = try scorer.score(
                e: e.unit, rawNorm: e.norm, snrDb: c["snr_db"].double, plc: c["plc"].double, nb: c["nb"].flag,
                enrollSpeechS: c["enroll_speech_s"].double, xcond: c["xcond"].flag, template: prepared
            )
            let want = c["expected"]
            let pairs: [(String, Double, Double)] = [
                ("s", got.s, want["s"].double), ("s_as", got.sAs, want["s_as"].double),
                ("l", got.l, want["l"].double), ("l_c", got.lClipped, want["l_c"].double),
                ("mu_e", got.muE, want["mu_e"].double), ("sd_e", got.sdE, want["sd_e"].double),
                ("mu_t", got.muT, want["mu_t"].double), ("sd_t", got.sdT, want["sd_t"].double)
            ]
            for (what, g, w) in pairs {
                XCTAssertLessThanOrEqual(abs(g - w), 1e-3, "\(name) \(what): got \(g) want \(w)")
            }
        }
        XCTAssertEqual(n, 48)
    }

    func testEveryCentroidCaseGivesTheStoredVector() throws {
        var n = 0
        for c in cases where c["kind"].string == "centroid" {
            n += 1
            VoiceScoringKat.assertFloatsAbs(c["name"].string, try centroid(of: c), row(c["expected_vec"].int), 1e-5)
        }
        XCTAssertEqual(n, 2)
    }

    func testTheClipIsExactAtTheLimitAndTheTopNIsCappedAtTheCohortSize() throws {
        XCTAssertEqual(QmfFeatures.clip(4.0, lClip: 4.0), 4.0)
        XCTAssertEqual(QmfFeatures.clip(4.0000001, lClip: 4.0), 4.0)
        XCTAssertEqual(QmfFeatures.clip(-9.0, lClip: 4.0), -4.0)
        XCTAssertEqual(QmfFeatures.clip(1.5, lClip: 4.0), 1.5)
        let c = try XCTUnwrap(cases.first { $0["name"].string == "topn_15_capped" })
        let k = try cohort(of: c)
        XCTAssertEqual(k.count, 10)
        let q = QmfConstants(q: [Double](repeating: 0, count: 8), lClip: 1.0)
        let capped = try VoiceScorer(cohort: k, topN: 15, qmf: q).topNStats(row(10))
        let ten = try VoiceScorer(cohort: k, topN: 10, qmf: q).topNStats(row(10))
        XCTAssertEqual(capped.mu, ten.mu)
        XCTAssertEqual(capped.sd, ten.sd)
    }

    func testTheQmfFeaturesComeInTheDocumentedOrderAndTheSnrIsCappedAt40Db() throws {
        let f = try QmfFeatures.compute(sAs: 2.0, snrDb: 55.0, rawNorm: M_E, plc: 0.03, nb: true, enrollSpeechS: 240.0, xcond: true)
        let wantF = [1.0, 2.0, 4.0, 1.0, 0.03, 1.0, log(2.0), 1.0]
        for i in 0..<8 { XCTAssertEqual(f[i], wantF[i], accuracy: 1e-15, "feature \(i)") }
        let g = try QmfFeatures.compute(sAs: -1.0, snrDb: -3.0, rawNorm: 1.0, plc: 0.0, nb: false, enrollSpeechS: 120.0, xcond: false)
        XCTAssertEqual(g, [1.0, -1.0, -0.3, 0.0, 0.0, 0.0, 0.0, 0.0])
        for bad in [0.0, -1.0, Double.nan] {
            XCTAssertThrowsError(try QmfFeatures.compute(sAs: 0, snrDb: 10, rawNorm: bad, plc: 0, nb: false, enrollSpeechS: 120, xcond: false), "raw norm \(bad)")
        }
        XCTAssertThrowsError(try QmfFeatures.compute(sAs: 0, snrDb: 10, rawNorm: 1, plc: 0, nb: false, enrollSpeechS: 0, xcond: false))
        for bad in [Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try QmfFeatures.compute(sAs: bad, snrDb: 10, rawNorm: 1, plc: 0, nb: false, enrollSpeechS: 120, xcond: false), "s_as \(bad)")
            XCTAssertThrowsError(try QmfFeatures.compute(sAs: 0, snrDb: bad, rawNorm: 1, plc: 0, nb: false, enrollSpeechS: 120, xcond: false), "snr \(bad)")
            XCTAssertThrowsError(try QmfFeatures.compute(sAs: 0, snrDb: 10, rawNorm: 1, plc: bad, nb: false, enrollSpeechS: 120, xcond: false), "plc \(bad)")
            XCTAssertThrowsError(try QmfFeatures.compute(sAs: 0, snrDb: 10, rawNorm: bad, plc: 0, nb: false, enrollSpeechS: 120, xcond: false), "norm \(bad)")
            XCTAssertThrowsError(try QmfFeatures.compute(sAs: 0, snrDb: 10, rawNorm: 1, plc: 0, nb: false, enrollSpeechS: bad, xcond: false), "enroll \(bad)")
        }
    }

    func testTheCallLocalReferenceTakesTheFirstFiveCertainWindowsAndIsThenComplete() throws {
        let c = try XCTUnwrap(cases.first { $0["name"].string == "call_local_reference" })
        let k = try cohort(of: try XCTUnwrap(cases.first { $0["name"].string == "call_local_window_0" }))
        let scorer = try VoiceScorer(cohort: k, topN: 4, qmf: QmfConstants(q: [Double](repeating: 0, count: 8), lClip: 4.5))
        let ref = try CallLocalReference(refWindows: 5, refSpeechS: 20.48, scorer: scorer)
        XCTAssertFalse(ref.ready)
        XCTAssertNil(ref.template)
        let ids = c["inputs"]["vectors"].ints
        XCTAssertEqual(ids.count, 5)
        // an uncertain window does not enter the reference and is not consumed by it
        XCTAssertFalse(try ref.offer(row(26), certain: false))
        for (k, i) in ids.enumerated() {
            XCTAssertFalse(ref.ready)
            XCTAssertTrue(try ref.offer(row(i), certain: true), "window \(k)")
            if k == 1 { XCTAssertFalse(try ref.offer(row(26), certain: false)) }
        }
        XCTAssertTrue(ref.ready)
        VoiceScoringKat.assertFloatsAbs("reference", try XCTUnwrap(ref.template).unit, row(c["expected_vec"].int), 1e-5)
        // later windows are for scoring, certain or not
        XCTAssertFalse(try ref.offer(row(24), certain: true))
        ref.reset()
        XCTAssertFalse(ref.ready)
        XCTAssertTrue(try ref.offer(row(ids[0]), certain: true))
    }

    func testTheCohortLoaderChecksThePinTheSizeAndTheValues() throws {
        let constants = try VoiceScoringKat.constants().cohort
        let bytes = try VoiceKat.data("cohort.bin")
        XCTAssertEqual(try VoiceCohort.parse(bytes, constants: constants).count, 80)

        var flipped = bytes
        flipped[100] ^= 0x01
        XCTAssertThrowsError(try VoiceCohort.parse(flipped, constants: constants)) { error in
            XCTAssertEqual(error as? VoiceBundleError, VoiceBundleError.hashMismatch(constants.file))
        }

        let short = bytes.prefix(bytes.count - 4)
        var shortPin = constants
        shortPin.sha256 = VoiceHash.sha256Hex(Data(short))
        XCTAssertThrowsError(try VoiceCohort.parse(Data(short), constants: shortPin)) { error in
            XCTAssertEqual(error as? VoiceBundleError, VoiceBundleError.malformed("\(constants.file): wrong size"))
        }

        var nan = bytes
        nan.replaceSubrange(0..<4, with: [0x00, 0x00, 0xC0, 0x7F])
        var nanPin = constants
        nanPin.sha256 = VoiceHash.sha256Hex(nan)
        XCTAssertThrowsError(try VoiceCohort.parse(nan, constants: nanPin)) { error in
            XCTAssertEqual(error as? VoiceBundleError, VoiceBundleError.malformed("\(constants.file): non finite value"))
        }
    }

    func testNonFiniteAndUnusableInputsThrow() throws {
        let k = try VoiceScoringKat.cohort()
        let scorer = try VoiceScorer(cohort: k, topN: 4, qmf: QmfConstants(q: [Double](repeating: 0, count: 8), lClip: 4.0))
        let t = try scorer.prepare(row(23))
        for bad in [Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try scorer.score(e: row(24), rawNorm: bad, snrDb: 10, plc: 0, nb: false, enrollSpeechS: 120, xcond: false, template: t), "norm \(bad)")
            XCTAssertThrowsError(try scorer.score(e: row(24), rawNorm: 5, snrDb: bad, plc: 0, nb: false, enrollSpeechS: 120, xcond: false, template: t), "snr \(bad)")
        }
        XCTAssertThrowsError(try scorer.score(e: [1, 2], rawNorm: 5, snrDb: 10, plc: 0, nb: false, enrollSpeechS: 120, xcond: false, template: t))
        XCTAssertThrowsError(try scorer.topNStats([1, 2]))
        XCTAssertThrowsError(try VoiceCentroid.of([]))
        XCTAssertThrowsError(try VoiceCentroid.of([[Float](repeating: 0, count: 512)]))
        XCTAssertThrowsError(try VoiceCentroid.of([[1, 2]]))
    }

    func testTheBackEndConstantsAreChecked() throws {
        let directory = try XCTUnwrap(VoiceBundle.moduleDirectory())
        let data = try Data(contentsOf: directory.appendingPathComponent(VoiceBundle.constantsFile))
        let c = try VoiceScoringConstants.decode(data)
        XCTAssertEqual(c.cohort.count, 80)
        XCTAssertEqual(c.cohort.topN, 40)
        XCTAssertEqual(c.qmf.q.count, 8)
        XCTAssertEqual(c.callLocal.refWindows, 5)
        XCTAssertEqual(c.evidence.blockWindows, 6)
        XCTAssertEqual(c.evidence.dwellMs, 10_000)
        XCTAssertFalse(c.display.differs)
        XCTAssertFalse(c.display.change)
        var bad = c
        bad.qmf.features.swapAt(0, 1)
        XCTAssertThrowsError(try bad.validate())
        bad = c
        bad.qmf.q.removeLast()
        XCTAssertThrowsError(try bad.validate())
        bad = c
        bad.callLocal.lClip = 0
        XCTAssertThrowsError(try bad.validate())
    }
}
