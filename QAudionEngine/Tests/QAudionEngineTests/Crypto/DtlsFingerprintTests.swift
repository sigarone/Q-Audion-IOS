import XCTest
import CryptoKit
@testable import QAudionEngine

/// DTLS fingerprint canonical forms, check (a) (SDP) and check (b) (stats), WIRE_SPEC §3.8.
/// All values are synthetic: fingerprints are SHA-256 of fixed ASCII labels.
final class DtlsFingerprintTests: XCTestCase {

    private typealias F = V5TestFixtures

    private let fpSelf = F.fingerprint("self-cert")
    private let fpPeer = F.fingerprint("peer-cert")
    private let fpOther = F.fingerprint("intruder-cert")

    // MARK: - Canonical forms

    func testBinaryFormShape() {
        XCTAssertEqual(fpSelf.count, DtlsFingerprint.binaryLength)
        XCTAssertEqual(fpSelf.first, DtlsFingerprint.algSha256)
        XCTAssertTrue(DtlsFingerprint.isWellFormedBinary(fpSelf))
        XCTAssertFalse(DtlsFingerprint.isWellFormedBinary(Data(repeating: 1, count: 32)))
        XCTAssertFalse(DtlsFingerprint.isWellFormedBinary(Data([0x02]) + Data(repeating: 1, count: 32)))
        XCTAssertFalse(DtlsFingerprint.isWellFormedBinary(Data()))
    }

    func testCanonicalTextRoundTrip() throws {
        let text = try XCTUnwrap(DtlsFingerprint.canonicalText(fpPeer))
        XCTAssertTrue(text.hasPrefix("sha-256 "))
        XCTAssertEqual(text.count, 8 + 95)
        // Upper-case hex only (the prefix stays lower-case).
        XCTAssertEqual(String(text.dropFirst(8)), String(text.dropFirst(8)).uppercased())
        XCTAssertEqual(DtlsFingerprint.parseCanonical(text), fpPeer)
    }

    /// The text form is `sha-256 ` followed by the digest of SHA-256(der).
    func testFromDerMatchesSha256() throws {
        let der = Data("synthetic-der".utf8)
        let fp = DtlsFingerprint.fromDer(der)
        XCTAssertEqual(fp.dropFirst(), Data(SHA256.hash(data: der)))
        let hex = try XCTUnwrap(DtlsFingerprint.hexColon(fp))
        let plain = Data(SHA256.hash(data: der)).map { String(format: "%02X", $0) }.joined(separator: ":")
        XCTAssertEqual(hex, plain)
    }

    func testParseRejectsEveryNonCanonicalSpelling() throws {
        let good = try XCTUnwrap(DtlsFingerprint.canonicalText(fpPeer))
        let bad: [String] = [
            good.lowercased(),                                         // lower-case hex and prefix
            good.replacingOccurrences(of: "sha-256 ", with: "SHA-256 "),   // upper-case algorithm
            good.replacingOccurrences(of: "sha-256 ", with: "sha-1 "),     // other algorithm
            good.replacingOccurrences(of: ":", with: ""),              // no colons
            good + " ",                                                // trailing whitespace
            " " + good,                                                // leading whitespace
            good.replacingOccurrences(of: "sha-256 ", with: "sha-256  "),  // double space
            String(good.dropLast()),                                   // truncated
            good + "00",                                               // too long
            "",
            "sha-256 ",
        ]
        for text in bad {
            XCTAssertNil(DtlsFingerprint.parseCanonical(text), "must reject: \(text.prefix(30))")
        }
        var chars = Array(good)
        chars[chars.count - 1] = "G"
        XCTAssertNil(DtlsFingerprint.parseCanonical(String(chars)))
    }

    func testFromPem() throws {
        let der = Data((0..<200).map { UInt8($0 & 0xFF) })
        let b64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        let pem = "-----BEGIN CERTIFICATE-----\n" + b64 + "\n-----END CERTIFICATE-----\n"
        XCTAssertEqual(DtlsFingerprint.fromPem(pem), DtlsFingerprint.fromDer(der))
        let crlf = pem.replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertEqual(DtlsFingerprint.fromPem(crlf), DtlsFingerprint.fromDer(der))
        XCTAssertNil(DtlsFingerprint.fromPem("-----BEGIN CERTIFICATE-----\n-----END CERTIFICATE-----"))
        XCTAssertNil(DtlsFingerprint.fromPem(""))
    }

    // MARK: - Check (a): SDP

    private func sdp(_ lines: [String], eol: String = "\r\n") -> String {
        return (["v=0", "o=- 1 2 IN IP4 0.0.0.0", "s=-"] + lines).joined(separator: eol) + eol
    }

    private func fpLine(_ fp: Data, alg: String = "sha-256", lower: Bool = false) -> String {
        let hex = DtlsFingerprint.hexColon(fp)!
        return "a=fingerprint:\(alg) \(lower ? hex.lowercased() : hex)"
    }

    func testSdpAcceptsMatchingFingerprintCrlfAndLf() {
        let lines = [fpLine(fpPeer), "a=setup:actpass"]
        XCTAssertTrue(DtlsFingerprint.checkSdp(sdp(lines), expected: fpPeer))
        XCTAssertTrue(DtlsFingerprint.checkSdp(sdp(lines, eol: "\n"), expected: fpPeer))
    }

    func testSdpAcceptsLowerCaseHexAndAlgorithmCase() {
        XCTAssertTrue(DtlsFingerprint.checkSdp(sdp([fpLine(fpPeer, lower: true)]), expected: fpPeer))
        XCTAssertTrue(DtlsFingerprint.checkSdp(sdp([fpLine(fpPeer, alg: "SHA-256")]), expected: fpPeer))
    }

    func testSdpAcceptsSessionAndMediaLevelLinesWhenAllMatch() {
        let lines = [fpLine(fpPeer), "m=audio 9 UDP/TLS/RTP/SAVPF 111", fpLine(fpPeer), "m=video 9 UDP/TLS/RTP/SAVPF 96", fpLine(fpPeer)]
        XCTAssertTrue(DtlsFingerprint.checkSdp(sdp(lines), expected: fpPeer))
    }

    func testSdpRejectsMissingFingerprint() {
        XCTAssertFalse(DtlsFingerprint.checkSdp(sdp(["a=setup:actpass"]), expected: fpPeer))
        XCTAssertFalse(DtlsFingerprint.checkSdp("", expected: fpPeer))
    }

    func testSdpRejectsDifferentFingerprint() {
        XCTAssertFalse(DtlsFingerprint.checkSdp(sdp([fpLine(fpOther)]), expected: fpPeer))
    }

    /// A single differing line among matching ones fails (a media-level line cannot be rewritten).
    func testSdpRejectsOneDifferingLineAmongMatching() {
        let lines = [fpLine(fpPeer), "m=audio 9 UDP/TLS/RTP/SAVPF 111", fpLine(fpOther)]
        XCTAssertFalse(DtlsFingerprint.checkSdp(sdp(lines), expected: fpPeer))
        XCTAssertFalse(DtlsFingerprint.checkSdp(sdp(lines.reversed()), expected: fpPeer))
    }

    func testSdpRejectsOtherHashAlgorithms() {
        XCTAssertFalse(DtlsFingerprint.checkSdp(sdp([fpLine(fpPeer, alg: "sha-1")]), expected: fpPeer))
        XCTAssertFalse(DtlsFingerprint.checkSdp(sdp([fpLine(fpPeer, alg: "sha-512")]), expected: fpPeer))
        // The right value next to a second, foreign-algorithm line is still rejected.
        XCTAssertFalse(DtlsFingerprint.checkSdp(sdp([fpLine(fpPeer), fpLine(fpPeer, alg: "sha-1")]), expected: fpPeer))
    }

    func testSdpRejectsMalformedLine() {
        XCTAssertFalse(DtlsFingerprint.checkSdp(sdp(["a=fingerprint:sha-256"]), expected: fpPeer))
        XCTAssertFalse(DtlsFingerprint.checkSdp(sdp(["a=fingerprint:sha-256  \(DtlsFingerprint.hexColon(fpPeer)!)"]), expected: fpPeer))
    }

    func testSdpRejectsMalformedExpected() {
        XCTAssertFalse(DtlsFingerprint.checkSdp(sdp([fpLine(fpPeer)]), expected: Data(count: 5)))
    }

    // MARK: - Check (b): stats

    private func stats(
        dtlsState: String = "connected",
        localFp: Data? = nil, remoteFp: Data? = nil,
        localAlg: String = "sha-256", remoteAlg: String = "sha-256",
        omitRemoteCert: Bool = false
    ) -> [DtlsFingerprint.StatsRecord] {
        var records = [
            DtlsFingerprint.StatsRecord(
                id: "T01", type: "transport",
                values: ["dtlsState": dtlsState, "localCertificateId": "CL", "remoteCertificateId": "CR"]),
            DtlsFingerprint.StatsRecord(
                id: "CL", type: "certificate",
                values: ["fingerprintAlgorithm": localAlg,
                         "fingerprint": DtlsFingerprint.hexColon(localFp ?? fpSelf)!.lowercased()]),
        ]
        if !omitRemoteCert {
            records.append(DtlsFingerprint.StatsRecord(
                id: "CR", type: "certificate",
                values: ["fingerprintAlgorithm": remoteAlg,
                         "fingerprint": DtlsFingerprint.hexColon(remoteFp ?? fpPeer)!]))
        }
        return records
    }

    func testStatsPassWhenBothCertificatesMatch() {
        XCTAssertEqual(DtlsFingerprint.checkStats(stats(), fpSelf: fpSelf, fpPeer: fpPeer), .pass)
    }

    func testStatsMismatchOnRemoteCertificate() {
        XCTAssertEqual(
            DtlsFingerprint.checkStats(stats(remoteFp: fpOther), fpSelf: fpSelf, fpPeer: fpPeer), .mismatch)
    }

    func testStatsMismatchOnLocalCertificate() {
        XCTAssertEqual(
            DtlsFingerprint.checkStats(stats(localFp: fpOther), fpSelf: fpSelf, fpPeer: fpPeer), .mismatch)
    }

    func testStatsMismatchOnOtherAlgorithm() {
        XCTAssertEqual(
            DtlsFingerprint.checkStats(stats(remoteAlg: "sha-1"), fpSelf: fpSelf, fpPeer: fpPeer), .mismatch)
    }

    func testStatsPendingUntilTransportConnected() {
        XCTAssertEqual(
            DtlsFingerprint.checkStats(stats(dtlsState: "connecting"), fpSelf: fpSelf, fpPeer: fpPeer), .pending)
        XCTAssertEqual(DtlsFingerprint.checkStats([], fpSelf: fpSelf, fpPeer: fpPeer), .pending)
    }

    func testStatsPendingWhenCertificateNotYetReported() {
        XCTAssertEqual(
            DtlsFingerprint.checkStats(stats(omitRemoteCert: true), fpSelf: fpSelf, fpPeer: fpPeer), .pending)
    }

    /// One connected transport that is wrong fails the whole check even when another passes.
    func testStatsMismatchWhenAnyConnectedTransportDiffers() {
        let good = stats()
        let bad = [
            DtlsFingerprint.StatsRecord(
                id: "T02", type: "transport",
                values: ["dtlsState": "connected", "localCertificateId": "CL", "remoteCertificateId": "CX"]),
            DtlsFingerprint.StatsRecord(
                id: "CX", type: "certificate",
                values: ["fingerprintAlgorithm": "sha-256", "fingerprint": DtlsFingerprint.hexColon(fpOther)!]),
        ]
        XCTAssertEqual(DtlsFingerprint.checkStats(good + bad, fpSelf: fpSelf, fpPeer: fpPeer), .mismatch)
    }

    func testStatsMalformedPinnedFingerprintIsMismatch() {
        XCTAssertEqual(DtlsFingerprint.checkStats(stats(), fpSelf: Data(count: 3), fpPeer: fpPeer), .mismatch)
    }

    // MARK: - Failure stage -> numeric verdict (local logs only)

    /// Every stage the PeerConnection can report has its own number, so a server log line tells a
    /// real certificate mismatch (3) from a check (b) timeout (5).
    func testEveryFailureStageHasItsOwnCode() {
        let expected: [(String, Int)] = [
            ("sdp_remote", 1), ("sdp_local", 2), ("stats", 3), ("pin_timeout", 4), ("stats_timeout", 5),
        ]
        for (stage, code) in expected {
            XCTAssertEqual(DtlsFingerprint.failureCode(stage: stage), code, stage)
        }
        let distinct = Set(expected.map { DtlsFingerprint.failureCode(stage: $0.0) })
        XCTAssertEqual(distinct.count, expected.count)
    }

    func testAnUnknownFailureStageKeepsTheHistoricalDefault() {
        XCTAssertEqual(DtlsFingerprint.failureCode(stage: "something_new"), 3)
        XCTAssertEqual(DtlsFingerprint.failureCode(stage: ""), 3)
    }

    private func repoSource(_ relativePath: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
        }
        throw XCTSkip("\(relativePath) not found")
    }

    /// The PeerConnection, the controller and AppState cannot be driven here (a live libwebrtc
    /// PeerConnection, CallKit, a WebSocket), so the stats-timeout wiring is pinned on the source
    /// text, like the other wiring invariants (RekeyRolePolicyTests): the 5 s deadline reports the
    /// new LOCAL stage, a real mismatch still reports `stats`, the log lines use words the log
    /// shipper keeps, and the app keeps ending the call with the on-the-wire reason
    /// `dtls_fp_mismatch` whatever the stage.
    func testStatsTimeoutIsALocalStageAndTheWireReasonIsUnchanged() throws {
        let pc = try repoSource("QAudionEngine/Sources/QAudionEngine/WebRTC/QAudionPeerConnection.swift")
        let controller = try repoSource(
            "QAudionEngine/Sources/QAudionEngine/WebRTC/QAudionWebRtcCallController.swift")
        let app = try repoSource("QAudionApp/AppState.swift")

        func occurrences(_ needle: String, in text: String) -> Int {
            return text.components(separatedBy: needle).count - 1
        }
        XCTAssertEqual(occurrences("reportDtlsFailure(stage: \"stats_timeout\")", in: pc), 1, "the 5 s deadline")
        XCTAssertEqual(occurrences("reportDtlsFailure(stage: \"stats\")", in: pc), 1, "a real mismatch only")

        XCTAssertTrue(controller.contains("DtlsFingerprint.failureCode(stage: stage)"))
        XCTAssertTrue(controller.contains("\"dtls fail s=\\(code) ok=0\""))
        XCTAssertTrue(controller.contains("\"dtls pass s=3 ok=1\""))
        XCTAssertFalse(controller.contains("dtlsfp s="), "the shipper drops the old vowel-less token")

        XCTAssertTrue(app.contains("reason: \"dtls_fp_mismatch\", dtlsStage:"))
        XCTAssertFalse(app.contains("\"stats_timeout\""), "the stage is local: it never selects a reason")
        XCTAssertTrue(app.contains("\"hsfatal r=\\(code) dtls=\\(dtlsStage)\""))
    }
}
