import Foundation

/// `constants.cohort`: the file, its pin, its shape and the top-N of the AS-norm.
struct CohortConstants: Decodable, Equatable {
    var file: String
    var sha256: String
    var count: Int
    var dim: Int
    var topN: Int
}

/// `constants.qmf` and `constants.call_local`: the coefficients in the order of `QmfFeatures.order` and the clip of the LLR.
struct QmfConstants: Decodable, Equatable {
    var q: [Double]
    var lClip: Double

    func validate() throws {
        guard q.count == QmfFeatures.order.count else { throw VoiceBundleError.malformed("qmf needs \(QmfFeatures.order.count) coefficients") }
        guard q.allSatisfy({ $0.isFinite }), lClip > 0, lClip.isFinite else { throw VoiceBundleError.malformed("qmf values") }
    }
}

/// The back-end part of `constants.json`: embedder pin, cohort, QMF, evidence, call-local and the display flags. The front-end
/// part is `VoiceConstants`. The values of `cohort`, `qmf` and `call_local` are placeholders in bundle v0; the code never
/// depends on a value, only on the shapes checked in `validate()`.
struct VoiceScoringConstants: Decodable, Equatable {
    struct Model: Decodable, Equatable {
        var embedderFile: String
        var embedderSha256: String
    }

    struct Fbank: Decodable, Equatable {
        var embedFrames: Int
    }

    struct Qmf: Decodable, Equatable {
        var features: [String]
        var q: [Double]
        var lClip: Double

        var constants: QmfConstants { QmfConstants(q: q, lClip: lClip) }
    }

    struct Evidence: Decodable, Equatable {
        var blockWindows: Int
        var tDiffers: Double
        var tailSlope: Double
        var negMin: Int
        var mMin: Double
        var maxBlock: Int
        var deltaNew: Double
        var tMatch: Double
        var recentWindows: Int
        var matchMinWindows: Int
        var matchPartialFloor: Double
        var weakFrac: Double
        var dwellMs: Int64
        var differsHoldMs: Int64
        var noverLookbackMs: Int64
        var noverMinVadMs: Int64
    }

    struct CallLocal: Decodable, Equatable {
        var refWindows: Int
        var refSpeechS: Double
        var q: [Double]
        var lClip: Double
        var tChange: Double
        var tailSlope: Double
        var negMin: Int
        var mMin: Double
        var maxBlock: Int

        var qmf: QmfConstants { QmfConstants(q: q, lClip: lClip) }
    }

    /// `constants.display`: the two feature flags. False in bundle v0: the card shows Checking or Learning and the candidate is shadow.
    struct Display: Decodable, Equatable {
        var differs: Bool
        var change: Bool
    }

    var schema: String
    var model: Model
    var fbank: Fbank
    var cohort: CohortConstants
    var qmf: Qmf
    var evidence: Evidence
    var callLocal: CallLocal
    var display: Display

    static func decode(_ data: Data) throws -> VoiceScoringConstants {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let constants: VoiceScoringConstants
        do {
            constants = try decoder.decode(VoiceScoringConstants.self, from: data)
        } catch {
            throw VoiceBundleError.malformed("constants.json: \(error)")
        }
        try constants.validate()
        return constants
    }

    func validate() throws {
        guard schema == "voice.constants" else { throw VoiceBundleError.malformed("not a voice constants file") }
        guard qmf.features == QmfFeatures.order else { throw VoiceBundleError.malformed("qmf.features is not the order this code computes") }
        try qmf.constants.validate()
        try callLocal.qmf.validate()
        guard cohort.count > 0, cohort.dim == VoiceEmbedderShape.dim, cohort.topN > 0 else {
            throw VoiceBundleError.malformed("bad cohort entry")
        }
        guard fbank.embedFrames == VoiceEmbedderShape.frames else { throw VoiceBundleError.malformed("embed frames") }
        guard evidence.blockWindows >= 2, evidence.blockWindows % 2 == 0, evidence.recentWindows >= 1,
              callLocal.refWindows >= 1, evidence.tailSlope > 0, callLocal.tailSlope > 0 else {
            throw VoiceBundleError.malformed("bad evidence entry")
        }
    }
}

/// An input that is not usable: a non-finite number, a non-positive norm, a vector of the wrong size. Always a bug of the caller
/// (the values are measured upstream), so it is thrown and never hidden.
enum VoiceScoringError: Error, Equatable {
    case invalidInput(String)
}

/// The QMF features of the scoring rule, in the order of `constants.qmf.features`.
enum QmfFeatures {
    static let order = ["bias", "s_as", "snr10", "ln_norm", "plc", "nb", "ln_enroll", "xcond"]

    /// f = [1, s_as, min(snr_db, 40) / 10, ln(raw norm), plc, nb ? 1 : 0, ln(enroll_speech_s / 120), xcond ? 1 : 0]. `rawNorm` and
    /// `enrollSpeechS` must be above zero and the others finite; anything else throws `VoiceScoringError.invalidInput`.
    static func compute(
        sAs: Double, snrDb: Double, rawNorm: Double, plc: Double, nb: Bool, enrollSpeechS: Double, xcond: Bool
    ) throws -> [Double] {
        guard sAs.isFinite, snrDb.isFinite, plc.isFinite else { throw VoiceScoringError.invalidInput("non finite QMF input") }
        guard rawNorm > 0, rawNorm.isFinite, enrollSpeechS > 0, enrollSpeechS.isFinite else {
            throw VoiceScoringError.invalidInput("QMF logarithm of a non positive value")
        }
        return [1.0, sAs, min(snrDb, 40.0) / 10.0, log(rawNorm), plc, nb ? 1.0 : 0.0, log(enrollSpeechS / 120.0), xcond ? 1.0 : 0.0]
    }

    /// l = sum q_i f_i, float64, in feature order.
    static func llr(q: [Double], f: [Double]) -> Double {
        var acc = 0.0
        for i in 0..<q.count { acc += q[i] * f[i] }
        return acc
    }

    /// The clip of the LLR.
    static func clip(_ l: Double, lClip: Double) -> Double {
        min(max(l, -lClip), lClip)
    }
}

/// The AS-norm cohort: K unit float32 vectors of 512 (`cohort.bin`, little endian, row major), pinned by SHA-256.
struct VoiceCohort {
    let rows: [Float]
    let count: Int

    init(rows: [Float], count: Int) throws {
        guard count > 0, rows.count == count * VoiceEmbedderShape.dim else { throw VoiceBundleError.malformed("bad cohort shape") }
        self.rows = rows
        self.count = count
    }

    /// Checks the bytes against the pin and the shape of `constants.cohort`; throws `VoiceBundleError` otherwise.
    static func parse(_ data: Data, constants: CohortConstants) throws -> VoiceCohort {
        guard VoiceHash.sha256Hex(data) == constants.sha256.lowercased() else { throw VoiceBundleError.hashMismatch(constants.file) }
        guard constants.count > 0, constants.dim == VoiceEmbedderShape.dim, data.count == 4 * constants.count * constants.dim else {
            throw VoiceBundleError.malformed("\(constants.file): wrong size")
        }
        let total = constants.count * constants.dim
        let rows: [Float] = data.withUnsafeBytes { raw in
            (0..<total).map {
                Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 4 * $0, as: UInt32.self)))
            }
        }
        guard rows.allSatisfy({ $0.isFinite }) else { throw VoiceBundleError.malformed("\(constants.file): non finite value") }
        return try VoiceCohort(rows: rows, count: constants.count)
    }
}

/// A template or call reference ready for scoring: its unit vector and the AS-norm side statistics, computed once per call.
struct PreparedTemplate {
    let unit: [Float]
    let mu: Double
    let sd: Double
}

/// The values of one scored window and the diagnostics of the KAT.
struct WindowScore {
    let s: Double
    let muE: Double
    let sdE: Double
    let muT: Double
    let sdT: Double
    let sAs: Double
    let l: Double
    let lClipped: Double
}

/// The raw score, the AS-norm against the cohort, the QMF and the clip. Pure: the inputs are unit float32 vectors and
/// numbers, no model, no clock. Arithmetic: a dot product accumulates float32 products in ascending index order, no FMA; the
/// top-N mean and POPULATION standard deviation are taken over the float32 scores in float64; the QMF sum and everything after
/// it are float64.
///
/// `topN` is capped at the cohort size K and the standard deviation of each side is floored at `sdFloor` (a cohort whose top
/// scores are all equal would divide by zero; real values are above 0.01).
final class VoiceScorer {
    static let sdFloor = 1e-3

    private let cohort: VoiceCohort
    private let n: Int
    private let qmf: QmfConstants

    init(cohort: VoiceCohort, topN: Int, qmf: QmfConstants) throws {
        guard topN >= 1 else { throw VoiceBundleError.malformed("top_n") }
        try qmf.validate()
        self.cohort = cohort
        self.n = min(topN, cohort.count)
        self.qmf = qmf
    }

    /// mu and sd of the top-N of {v . c_k}; v is a unit float32 vector of 512.
    func topNStats(_ v: [Float]) throws -> (mu: Double, sd: Double) {
        guard v.count == VoiceEmbedderShape.dim else { throw VoiceScoringError.invalidInput("vector size") }
        var scores = [Float](repeating: 0, count: cohort.count)
        for k in 0..<cohort.count {
            scores[k] = Self.dot32(v, 0, cohort.rows, k * VoiceEmbedderShape.dim)
        }
        scores.sort()
        var sum = 0.0
        for i in (cohort.count - n)..<cohort.count { sum += Double(scores[i]) }
        let mu = sum / Double(n)
        var sq = 0.0
        for i in (cohort.count - n)..<cohort.count {
            let d = Double(scores[i]) - mu
            sq += d * d
        }
        return (mu, max((sq / Double(n)).squareRoot(), Self.sdFloor))
    }

    /// The template side of the AS-norm, computed once per call.
    func prepare(_ templateUnit: [Float]) throws -> PreparedTemplate {
        let stats = try topNStats(templateUnit)
        return PreparedTemplate(unit: templateUnit, mu: stats.mu, sd: stats.sd)
    }

    /// Scores one window: `e` is the unit embedding, `rawNorm` the raw norm of the embedder, `snrDb`, `plc` and `nb` the
    /// measurements of the window, `enrollSpeechS` the consensus (or slot, or call-local reference) speech in seconds,
    /// `xcond` true when the call's route group is not covered. Throws `VoiceScoringError.invalidInput` for an unusable input.
    func score(
        e: [Float], rawNorm: Double, snrDb: Double, plc: Double, nb: Bool, enrollSpeechS: Double, xcond: Bool,
        template: PreparedTemplate
    ) throws -> WindowScore {
        guard e.count == VoiceEmbedderShape.dim, template.unit.count == VoiceEmbedderShape.dim else {
            throw VoiceScoringError.invalidInput("vector size")
        }
        let s = Double(Self.dot32(e, 0, template.unit, 0))
        let side = try topNStats(e)
        let sAs = 0.5 * ((s - side.mu) / side.sd + (s - template.mu) / template.sd)
        let f = try QmfFeatures.compute(
            sAs: sAs, snrDb: snrDb, rawNorm: rawNorm, plc: plc, nb: nb, enrollSpeechS: enrollSpeechS, xcond: xcond
        )
        let l = QmfFeatures.llr(q: qmf.q, f: f)
        return WindowScore(
            s: s, muE: side.mu, sdE: side.sd, muT: template.mu, sdT: template.sd, sAs: sAs, l: l,
            lClipped: QmfFeatures.clip(l, lClip: qmf.lClip)
        )
    }

    /// float32 dot product of 512 values of `a` (from `aOff`) and `b` (from `bOff`): the products accumulated in ascending
    /// order in float32, each product rounded to float32 before the addition.
    static func dot32(_ a: [Float], _ aOff: Int, _ b: [Float], _ bOff: Int) -> Float {
        var acc: Float = 0
        for i in 0..<VoiceEmbedderShape.dim {
            let p: Float = a[aOff + i] * b[bOff + i]
            acc += p
        }
        return acc
    }
}

/// The centroid of a set of unit embeddings: c = normalise(mean).
enum VoiceCentroid {
    /// The mean in float64 over `vectors` in order, rounded once to float32, divided by its float64 norm and rounded once.
    /// Throws `VoiceScoringError.invalidInput` for an empty list, a vector of the wrong size or a zero mean.
    static func of(_ vectors: [[Float]]) throws -> [Float] {
        guard !vectors.isEmpty, vectors.allSatisfy({ $0.count == VoiceEmbedderShape.dim }) else {
            throw VoiceScoringError.invalidInput("centroid input")
        }
        var acc = [Double](repeating: 0, count: VoiceEmbedderShape.dim)
        for v in vectors {
            for i in 0..<acc.count { acc[i] += Double(v[i]) }
        }
        let mean = acc.map { Float($0 / Double(vectors.count)) }
        let norm = VoiceMath.norm(mean)
        guard norm > 0, norm.isFinite else { throw VoiceScoringError.invalidInput("zero centroid") }
        return mean.map { Float(Double($0) / norm) }
    }
}

/// The call-local reference of a contact in Learning or Provisional. The first `refWindows` CERTAIN disjoint windows since the
/// last `reset()` form an in-memory centroid; later windows are scored against it (with `call_local.q`, `refSpeechS`
/// seconds of enrollment speech and xcond false: the caller passes them). `reset()` is called at media start, on hold and
/// resume and on a change of the peer's announced route class; the reference never persists.
///
/// Single-thread: drive it from the one thread that drives `VoiceCallMachine` (see its threading note).
final class CallLocalReference {
    private let refWindows: Int
    let refSpeechS: Double
    private let scorer: VoiceScorer
    private var collected: [[Float]] = []
    private var prepared: PreparedTemplate?

    init(refWindows: Int, refSpeechS: Double, scorer: VoiceScorer) throws {
        guard refWindows >= 1 else { throw VoiceBundleError.malformed("ref_windows") }
        self.refWindows = refWindows
        self.refSpeechS = refSpeechS
        self.scorer = scorer
    }

    /// True once the reference is complete.
    var ready: Bool { prepared != nil }

    /// The reference as a template, or nil before it is complete.
    var template: PreparedTemplate? { prepared }

    /// Offers the unit embedding of a disjoint window. Returns true when the window went into the reference (it is then not
    /// scored); an uncertain window never does, and once the reference is complete every window is for scoring.
    @discardableResult
    func offer(_ unit: [Float], certain: Bool) throws -> Bool {
        if prepared != nil || !certain { return false }
        collected.append(unit)
        if collected.count == refWindows {
            defer { collected.removeAll() }
            prepared = try scorer.prepare(try VoiceCentroid.of(collected))
        }
        return true
    }

    func reset() {
        collected.removeAll()
        prepared = nil
    }
}
