import XCTest
@testable import QAudionEngine

/// W-CALLERBUSY (2026-10-03) — the busy signal mirrors Android's `QAudionSynth.renderBusyTone`: 425 Hz, 0.5 s on /
/// 0.5 s off, repeated to fill the busy hold (W-BUSYHOLD: four bursts in a 4 s one-shot buffer, `CallerBusyFeedback`),
/// each edge ramped so it never clicks. Also its WAV form (`QAudionCueWav.busyTone()`), which is what the app plays as
/// a system sound after CallKit ended the call.
final class BusyToneTests: XCTestCase {

    private let rate = 48_000.0

    private func slice(_ buf: [Float], from: Double, to: Double, rate: Double) -> ArraySlice<Float> {
        buf[Int(from * rate)..<Int(to * rate)]
    }

    private func rms(_ s: ArraySlice<Float>) -> Double {
        guard !s.isEmpty else { return 0 }
        return (s.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(s.count)).squareRoot()
    }

    func testFourSecondsOfFourHalfSecondBursts() {
        let buf = QAudionSynth.renderBusyTone(sampleRate: rate)
        XCTAssertEqual(buf.count, Int(rate * 4.0), "as long as the 4000 ms hold")
        XCTAssertEqual(QAudionSynth.busyToneRepetitions, 4)
        for rep in 0..<QAudionSynth.busyToneRepetitions {
            let t0 = Double(rep)
            XCTAssertGreaterThan(rms(slice(buf, from: t0 + 0.05, to: t0 + 0.45, rate: rate)), 0.10,
                                 "burst \(rep) is on for 0.5 s")
            XCTAssertLessThan(rms(slice(buf, from: t0 + 0.55, to: t0 + 0.95, rate: rate)), 0.001,
                              "silence \(rep) lasts the other 0.5 s")
        }
    }

    func testTheToneIs425HzAtTheSameLevelAsTheRingback() {
        let buf = QAudionSynth.renderBusyTone(sampleRate: rate)
        let burst = slice(buf, from: 0.1, to: 0.4, rate: rate)
        var crossings = 0
        var prev = burst.first ?? 0
        for x in burst.dropFirst() {
            if (prev < 0) != (x < 0) { crossings += 1 }
            prev = x
        }
        // 425 Hz over 0.3 s is 127.5 cycles: about 255 zero crossings.
        XCTAssertEqual(Double(crossings), 255, accuracy: 3)
        XCTAssertEqual(QAudionSynth.busyToneHz, 425.0)
        XCTAssertLessThanOrEqual(buf.map { abs($0) }.max() ?? 1, 0.2201, "amplitude 0.22, as Android")
    }

    func testEveryEdgeIsRampedSoItNeverClicks() {
        let buf = QAudionSynth.renderBusyTone(sampleRate: rate)
        for rep in 0..<QAudionSynth.busyToneRepetitions {
            XCTAssertLessThan(abs(buf[Int(Double(rep) * rate)]), 0.001, "burst \(rep) starts from zero")
            XCTAssertLessThan(abs(buf[Int((Double(rep) + 0.5) * rate) - 1]), 0.02, "burst \(rep) ends near zero")
        }
    }

    func testTheCueExistsOnThePlayerBesideTheOthers() {
        #if canImport(AVFoundation)
        let cues: Set<QAudionRingtonePlayer.Cue> = [
            .outgoingRing, .confirmedRingback, .keyExchange, .callConnected, .callEnded, .busy,
        ]
        XCTAssertEqual(cues.count, 6)
        #endif
    }

    // MARK: - WAV

    func testTheWavIsAWellFormedMono16BitFileOfTheSameTone() {
        let wav = QAudionCueWav.busyTone()
        let rate = QAudionCueWav.busySampleRate
        let samples = rate * 4
        XCTAssertEqual(wav.count, 44 + samples * 2)
        XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: wav[12..<16], as: UTF8.self), "fmt ")
        XCTAssertEqual(String(decoding: wav[36..<40], as: UTF8.self), "data")
        func u16(_ at: Int) -> Int { Int(wav[at]) + 256 * Int(wav[at + 1]) }
        func u32(_ at: Int) -> Int { u16(at) + 65_536 * u16(at + 2) }
        XCTAssertEqual(u32(4), 36 + samples * 2, "RIFF size")
        XCTAssertEqual(u16(20), 1, "PCM")
        XCTAssertEqual(u16(22), 1, "mono")
        XCTAssertEqual(u32(24), rate)
        XCTAssertEqual(u32(28), rate * 2, "byte rate")
        XCTAssertEqual(u16(32), 2, "block align")
        XCTAssertEqual(u16(34), 16, "bits per sample")
        XCTAssertEqual(u32(40), samples * 2, "data size")
        // Burst on in the first half second, silence in the second half.
        func sample(_ i: Int) -> Int { let v = u16(44 + i * 2); return v >= 0x8000 ? v - 0x10000 : v }
        let onPeak = (Int(0.1 * Double(rate))..<Int(0.4 * Double(rate))).map { abs(sample($0)) }.max() ?? 0
        let offPeak = (Int(0.6 * Double(rate))..<Int(0.9 * Double(rate))).map { abs(sample($0)) }.max() ?? 0
        XCTAssertGreaterThan(onPeak, 6_000)
        XCTAssertEqual(offPeak, 0)
    }

    func testEncodeClampsOutOfRangeSamples() {
        let wav = QAudionCueWav.encode([2.0, -2.0, 0.0], sampleRate: 8_000)
        XCTAssertEqual(wav.count, 44 + 6)
        func s(_ i: Int) -> Int { let v = Int(wav[44 + i * 2]) + 256 * Int(wav[45 + i * 2]); return v >= 0x8000 ? v - 0x10000 : v }
        XCTAssertEqual(s(0), Int(Int16.max))
        XCTAssertEqual(s(1), -Int(Int16.max))
        XCTAssertEqual(s(2), 0)
    }
}
