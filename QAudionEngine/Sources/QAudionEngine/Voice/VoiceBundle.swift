import Foundation
import CryptoKit

/// Why a voice bundle could not be loaded.
enum VoiceBundleError: Error, Equatable {
    case missingFile(String)
    case hashMismatch(String)
    case malformed(String)
}

/// SHA-256 of the bundle files the code trusts, as lowercase hex.
struct VoiceBundlePins: Equatable {
    let constantsSha256: String
    let fbankTablesSha256: String
    let vadSha256: String

    static let v0 = VoiceBundlePins(
        constantsSha256: "bbb87655388d82f282722d99b1c26aa9b182cd094d8c8604fbf53a583a4f68e2",
        fbankTablesSha256: "5a0751f6fa9f9c6119f8aaa98bb1f108aa4e941febe1bd455c3763d33f948d21",
        vadSha256: "7ed98ddbad84ccac4cd0aeb3099049280713df825c610a8ed34543318f1b2c49"
    )
}

enum VoiceHash {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// The numbers of `constants.json` that the front-end reads (other keys are ignored).
struct VoiceConstants: Decodable {
    struct Model: Decodable {
        let vadFile: String
        let vadSha256: String
    }

    struct Filter: Decodable {
        let L: Int
        let M: Int
        let taps: [Double]
    }

    struct Resampler: Decodable {
        let filters: [String: Filter]
    }

    struct Vad: Decodable {
        let chunk: Int
        let context: Int
        let on: Double
        let off: Double
        let noiseP: Double
        let fillGapChunks: Int
        let minSpeechChunks: Int
        let lookaheadChunks: Int
        let skipStartChunks: Int
    }

    struct Window: Decodable {
        let chunks: Int
        let hopChunks: Int
        let maxSpanMs: Int
    }

    struct Fbank: Decodable {
        let frameLength: Int
        let frameShift: Int
        let fft: Int
        let preemph: Double
        let numMel: Int
        let logFloor: Double
        let tablesSha256: String
        let nbHiBins: [Int]
        let nbLoBins: [Int]
        /// The embedding input is the fbank of the first `embedSamples` samples of a window (`embedFrames` frames).
        let embedSamples: Int
        let embedFrames: Int
    }

    struct Gates: Decodable {
        struct Enroll: Decodable {
            let meanPMin: Double
            let snrDbMin: Double
            let clipFracMax: Double
            let plcEventsMax: Int
            let stretchEventsMax: Int
            let wbOnly: Bool
        }

        struct Score: Decodable {
            let meanPMin: Double
            let snrDbMin: Double
            let clipFracMax: Double
            let plcFracMax: Double
        }

        struct Certain: Decodable {
            let plcFracMax: Double
        }

        struct Snr: Decodable {
            let poolChunks: Int
            let minPool: Int
            let percentile: Double
            let clip: [Double]
        }

        struct Tx: Decodable {
            let riseDbPerS: Double
            let marginDb: Double
            let floorDbfs: Double
            let preMsFloor: Double
            let preMsCap: Double
            let remoteMarginMs: Double
            let postMs: Int
        }

        struct Stats: Decodable {
            let widenMs: Int
            let lateMs: Int
            let cacheMs: Int
            let spanMs: Int
            let txSpanMs: Double
            let rxRateHz: Int
            let tapLagMs: Int
            let tapTolMs: Int
            let overdueMs: Int
        }

        let enroll: Enroll
        let score: Score
        let certain: Certain
        let clipLevel: Int
        let snr: Snr
        let tx: Tx
        let stats: Stats
        let betaNb: Double
    }

    let model: Model
    let resampler: Resampler
    let vad: Vad
    let window: Window
    let fbank: Fbank
    let gates: Gates

    static func decode(_ data: Data) throws -> VoiceConstants {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(VoiceConstants.self, from: data)
        } catch {
            throw VoiceBundleError.malformed("constants.json: \(error)")
        }
    }
}

/// The runtime voice bundle: constants, fbank tables and the Silero model file, each checked against its pinned SHA-256
/// before it is used.
struct VoiceBundle {
    static let constantsFile = "constants.json"
    static let tablesFile = "fbank_tables.bin"
    static let vadFile = "silero_vad_16k_op15.onnx"

    let constants: VoiceConstants
    /// The state part of the same file (enroll, update, refresh, conditions, retention, model id and versions): the template
    /// record and its state machine.
    let state: VoiceStateConstants
    let tables: VoiceFbankTables
    let vadModelURL: URL

    /// Loads and verifies the bundle files in `directory`. A file that is missing, or whose hash differs from its pin,
    /// stops the load.
    static func load(directory: URL, pins: VoiceBundlePins = .v0) throws -> VoiceBundle {
        let constantsData = try read(directory, constantsFile)
        guard VoiceHash.sha256Hex(constantsData) == pins.constantsSha256 else {
            throw VoiceBundleError.hashMismatch(constantsFile)
        }
        let tablesData = try read(directory, tablesFile)
        let tablesHash = VoiceHash.sha256Hex(tablesData)
        guard tablesHash == pins.fbankTablesSha256 else {
            throw VoiceBundleError.hashMismatch(tablesFile)
        }
        let vadData = try read(directory, vadFile)
        guard VoiceHash.sha256Hex(vadData) == pins.vadSha256 else {
            throw VoiceBundleError.hashMismatch(vadFile)
        }

        let constants = try VoiceConstants.decode(constantsData)
        guard constants.model.vadSha256 == pins.vadSha256, constants.model.vadFile == vadFile else {
            throw VoiceBundleError.malformed("constants.json: model entry does not match the pinned VAD file")
        }
        guard constants.fbank.tablesSha256 == tablesHash else {
            throw VoiceBundleError.malformed("constants.json: fbank tables hash does not match \(tablesFile)")
        }
        try validate(constants)
        let state = try VoiceStateConstants.parse(constantsData)
        let tables = try VoiceFbankTables(data: tablesData)
        return VoiceBundle(
            constants: constants,
            state: state,
            tables: tables,
            vadModelURL: directory.appendingPathComponent(vadFile)
        )
    }

    /// The folder of the bundle inside this module's resources, if it is there.
    static func moduleDirectory() -> URL? {
        let resourceRoot = Bundle.module.resourceURL
        let candidates: [URL?] = [
            resourceRoot?.appendingPathComponent("voice", isDirectory: true),
            resourceRoot?.appendingPathComponent("Resources/voice", isDirectory: true),
            Bundle.module.url(forResource: "voice", withExtension: nil)
        ]
        for candidate in candidates {
            guard let directory = candidate else { continue }
            let marker = directory.appendingPathComponent(constantsFile)
            if FileManager.default.fileExists(atPath: marker.path) {
                return directory
            }
        }
        return nil
    }

    /// Loads the bundle that ships in this module's resources.
    static func loadFromModule(pins: VoiceBundlePins = .v0) throws -> VoiceBundle {
        guard let directory = moduleDirectory() else {
            throw VoiceBundleError.missingFile("voice")
        }
        return try load(directory: directory, pins: pins)
    }

    private static func read(_ directory: URL, _ name: String) throws -> Data {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VoiceBundleError.missingFile(name)
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw VoiceBundleError.missingFile(name)
        }
    }

    private static func validate(_ c: VoiceConstants) throws {
        guard c.vad.chunk == VoiceChunker.chunkLength, c.vad.context == SileroVadContext.length else {
            throw VoiceBundleError.malformed("constants.json: vad chunk or context")
        }
        guard c.fbank.frameLength == VoiceFbankTables.frameLength, c.fbank.fft == VoiceFbankTables.fftSize,
              c.fbank.numMel == VoiceFbankTables.numMel, c.fbank.frameShift == VoiceFbank.frameShift else {
            throw VoiceBundleError.malformed("constants.json: fbank geometry")
        }
        guard c.fbank.nbHiBins.count == 2, c.fbank.nbLoBins.count == 2 else {
            throw VoiceBundleError.malformed("constants.json: bandwidth bins")
        }
        guard c.fbank.embedFrames >= 1, c.fbank.embedFrames <= VoiceFbank.frames,
              c.fbank.embedSamples == VoiceFbankTables.frameLength + (c.fbank.embedFrames - 1) * VoiceFbank.frameShift,
              c.fbank.embedSamples <= VoiceFbank.windowSamples else {
            throw VoiceBundleError.malformed("constants.json: embedding input")
        }
        guard c.window.chunks > 0, c.window.hopChunks > 0, c.gates.snr.clip.count == 2 else {
            throw VoiceBundleError.malformed("constants.json: window or snr entries")
        }
        let rate = c.gates.stats.rxRateHz
        guard rate > 0, VoiceStatsTrack.tickRate % rate == 0 else {
            throw VoiceBundleError.malformed("constants.json: rx rate")
        }
        guard c.gates.stats.overdueMs > 0 else {
            throw VoiceBundleError.malformed("constants.json: overdue")
        }
        for key in ["24000", "32000", "48000"] {
            guard let filter = c.resampler.filters[key], filter.L > 0, filter.M > 0, !filter.taps.isEmpty,
                  filter.taps.count % filter.L == 0 else {
                throw VoiceBundleError.malformed("constants.json: filter \(key)")
            }
        }
    }
}

/// Length of the context that precedes each chunk in the VAD input.
enum SileroVadContext {
    static let length = 64
}
