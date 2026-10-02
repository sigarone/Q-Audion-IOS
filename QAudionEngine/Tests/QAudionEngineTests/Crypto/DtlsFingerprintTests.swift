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

    /// The causes `DtlsFingerprint.failureCode` lists for `stats_timeout` stay `.pending` (retry
    /// until the deadline, then the unverified `stats_timeout` stage): none of them may ever be
    /// reported as a `.mismatch`, and none as a `.pass`.
    func testIncompleteCertificateStatsStayPendingNeverMismatchOrPass() {
        let selfCert = DtlsFingerprint.StatsRecord(
            id: "CL", type: "certificate",
            values: ["fingerprintAlgorithm": "sha-256", "fingerprint": DtlsFingerprint.hexColon(fpSelf)!])
        func transport(_ values: [String: String]) -> DtlsFingerprint.StatsRecord {
            return DtlsFingerprint.StatsRecord(id: "T01", type: "transport", values: values)
        }
        let connected = ["dtlsState": "connected", "localCertificateId": "CL"]
        // A stale certificate-stats cache (taken before the DTLS handshake delivered the peer
        // certificate): the connected transport has no remoteCertificateId at all, or an empty one.
        XCTAssertEqual(
            DtlsFingerprint.checkStats([transport(connected), selfCert], fpSelf: fpSelf, fpPeer: fpPeer), .pending)
        XCTAssertEqual(
            DtlsFingerprint.checkStats(
                [transport(connected.merging(["remoteCertificateId": ""]) { $1 }), selfCert],
                fpSelf: fpSelf, fpPeer: fpPeer),
            .pending)
        // A certificate entry that lacks its fingerprint, or its algorithm.
        let withRemote = connected.merging(["remoteCertificateId": "CR"]) { $1 }
        let noFingerprint = DtlsFingerprint.StatsRecord(
            id: "CR", type: "certificate", values: ["fingerprintAlgorithm": "sha-256"])
        let noAlgorithm = DtlsFingerprint.StatsRecord(
            id: "CR", type: "certificate", values: ["fingerprint": DtlsFingerprint.hexColon(fpPeer)!])
        XCTAssertEqual(
            DtlsFingerprint.checkStats(
                [transport(withRemote), selfCert, noFingerprint], fpSelf: fpSelf, fpPeer: fpPeer),
            .pending)
        XCTAssertEqual(
            DtlsFingerprint.checkStats(
                [transport(withRemote), selfCert, noAlgorithm], fpSelf: fpSelf, fpPeer: fpPeer),
            .pending)
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

    /// Code of a Swift source for the wiring pins below: whole-line `//` comments dropped and every
    /// run of whitespace (indentation, line breaks) collapsed to one space. A pin written against
    /// this text survives re-wrapping and comment edits, but not a change of the code itself, and
    /// it pins a statement WITH the code around it (a branch, a `case`), not just its presence
    /// somewhere in the file.
    private func normalisedCode(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }
        return lines.joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func occurrences(_ needle: String, in text: String) -> Int {
        return text.components(separatedBy: needle).count - 1
    }

    /// The PeerConnection, the controller and AppState cannot be driven here (a live libwebrtc
    /// PeerConnection, CallKit, a WebSocket), so the stats-timeout wiring is pinned on the source
    /// text, like the other wiring invariants (RekeyRolePolicyTests). Pinned: a real mismatch (the
    /// `case .mismatch:` branch) reports `stats` and ONLY the deadline branch reports
    /// `stats_timeout` (swapping them must fail here), every end of the check goes through that
    /// deadline branch, the log lines use words the log shipper keeps, and the app keeps ending the
    /// call with the on-the-wire reason `dtls_fp_mismatch` whatever the stage.
    func testStatsTimeoutIsALocalStageAndTheWireReasonIsUnchanged() throws {
        let pc = normalisedCode(try repoSource(
            "QAudionEngine/Sources/QAudionEngine/WebRTC/QAudionPeerConnection.swift"))
        let controller = normalisedCode(try repoSource(
            "QAudionEngine/Sources/QAudionEngine/WebRTC/QAudionWebRtcCallController.swift"))
        let app = normalisedCode(try repoSource("QAudionApp/AppState.swift"))

        // PeerConnection: each stage is reported from exactly one place, in the right branch.
        XCTAssertEqual(occurrences(#"reportDtlsFailure(stage: "stats_timeout")"#, in: pc), 1, "one deadline site")
        XCTAssertEqual(occurrences(#"reportDtlsFailure(stage: "stats")"#, in: pc), 1, "one mismatch site")
        XCTAssertTrue(
            pc.contains(#"case .mismatch: self.reportDtlsFailure(stage: "stats") case .pending:"#),
            "a real certificate mismatch reports `stats`, nothing else")
        XCTAssertTrue(
            pc.contains(#"if deadlineReached { reportDtlsFailure(stage: "stats_timeout") return }"#),
            "the deadline branch of retryOrFailDtlsStats reports `stats_timeout`, nothing else")
        // The missing peer pin and the `.pending` verdict both end in that deadline branch.
        XCTAssertTrue(
            pc.contains("guard let fpPeer = context.peerFingerprint else { "
                + "retryOrFailDtlsStats(generation: generation, startedAt: startedAt, "
                + "deadlineReached: deadlineReached) return }"),
            "no peer pin: retry until the deadline, then stats_timeout")
        XCTAssertTrue(pc.contains("case .pending: self.retryOrFailDtlsStats("), "pending: retry, then stats_timeout")

        // Controller: numeric verdict only, words the shipper keeps, the original stage still goes up.
        XCTAssertTrue(
            controller.contains(
                #"let code = DtlsFingerprint.failureCode(stage: stage) self?.log?("dtls fail s=\(code) ok=0") "#
                + "self?.onDtlsFingerprintFailure?(stage)"),
            "the fail line carries the numeric stage; the callback gets the unchanged stage")
        XCTAssertTrue(
            controller.contains(#"pc.onDtlsMediaGateOpened = { [weak self] in self?.log?("dtls ok=1") }"#),
            "the pass line has no stage")
        XCTAssertFalse(controller.contains("dtlsfp"), "the shipper drops the old vowel-less token")
        XCTAssertFalse(controller.contains(#""dtls ok=1 s="#), "a pass has no stage number")
        XCTAssertFalse(controller.contains(#""dtls pass"#), "no `pass` word: the shipper must not need it")

        // AppState: the wire reason is fixed; the stage only goes to the local log, as `dstage`.
        XCTAssertTrue(
            app.contains(#"self?.handleHandshakeFatal(callId: cid, reason: "dtls_fp_mismatch", dtlsStage: dtlsStage)"#),
            "every DTLS stage ends the call with dtls_fp_mismatch")
        XCTAssertTrue(app.contains("let dtlsStage = DtlsFingerprint.failureCode(stage: stage)"))
        XCTAssertFalse(app.contains(#""stats_timeout""#), "the stage is local: it never selects a reason")
        XCTAssertEqual(occurrences(#"RTLog.error("call", "hsfatal r="#, in: app), 1, "one hsfatal log call")
        XCTAssertTrue(
            app.contains(
                #"let stageSuffix = dtlsStage.map { " dstage=\($0)" } ?? "" "#
                + #"RTLog.error("call", "hsfatal r=\(code)\(stageSuffix)")"#),
            "the stage is appended as ` dstage=<n>` to the single hsfatal line")
        XCTAssertFalse(
            app.contains(#"dtls=\(dtlsStage"#),
            "`dtls=` is the 1:1 heartbeat's state string key (CallService): the stage key is `dstage`")
    }
}
