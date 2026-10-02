import Foundation
import CryptoKit

/// DTLS certificate fingerprints bound into the signed 1:1 handshake (WIRE_SPEC §3.8).
///
/// Pure value logic, no WebRTC types: the canonical forms, the SDP checker (check (a)) and the
/// stats checker (check (b)) live here so they are unit-testable on any host and pinned by the
/// shared KAT (`handshake-sig-v5-kat.json`). The PeerConnection wiring is in
/// `QAudionPeerConnection` (funnel + stats gate) and `CallDtlsCertificate` (per-call certificate).
///
/// **Canonical forms**
/// - Binary (transcript): `DTLSFP = u8(alg) || digest`, `alg = 0x01` meaning SHA-256, `digest`
///   being 32 bytes — 33 bytes in total. SHA-256 over the DER encoding of the X.509 certificate,
///   which is exactly what libwebrtc puts in `a=fingerprint`.
/// - Text (JSON bundle field `dtlsFingerprint`): `"sha-256 " || HEX`, HEX being 32 upper-case hex
///   byte pairs joined by `:`. Receivers MUST reject any other spelling (lower-case, no colons,
///   another algorithm, extra whitespace) so the form stays non-malleable.
public enum DtlsFingerprint {

    /// `alg` byte of the binary form: SHA-256.
    public static let algSha256: UInt8 = 0x01
    /// Length of the binary form (`alg || digest`).
    public static let binaryLength = 33
    private static let textPrefix = "sha-256 "

    // MARK: - Binary <-> text

    /// True when `fp` is a well-formed binary fingerprint (33 bytes, alg 0x01).
    public static func isWellFormedBinary(_ fp: Data) -> Bool {
        return fp.count == binaryLength && fp[fp.startIndex] == algSha256
    }

    /// `AB:CD:...` — the 32 digest bytes as upper-case colon-joined hex. `nil` unless `fp` is a
    /// well-formed binary fingerprint.
    public static func hexColon(_ fp: Data) -> String? {
        guard isWellFormedBinary(fp) else { return nil }
        let digits = Array("0123456789ABCDEF".utf8)
        var out = [UInt8]()
        out.reserveCapacity(95)
        let base = fp.startIndex + 1
        for i in 0..<32 {
            if i > 0 { out.append(0x3A) }  // ':'
            let b = fp[base + i]
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Canonical text form `"sha-256 AB:CD:..."` of a binary fingerprint, `nil` when malformed.
    public static func canonicalText(_ fp: Data) -> String? {
        guard let hex = hexColon(fp) else { return nil }
        return textPrefix + hex
    }

    /// Strictly parse the canonical text form, returning the 33-byte binary form, or `nil` for any
    /// other spelling.
    public static func parseCanonical(_ text: String) -> Data? {
        let bytes = Array(text.utf8)
        let prefix = Array(textPrefix.utf8)
        // 8 (prefix) + 32 pairs + 31 colons.
        guard bytes.count == prefix.count + 95 else { return nil }
        guard Array(bytes[0..<prefix.count]) == prefix else { return nil }
        var digest = Data(capacity: 32)
        var idx = prefix.count
        for pair in 0..<32 {
            if pair > 0 {
                guard bytes[idx] == 0x3A else { return nil }  // ':'
                idx += 1
            }
            guard let hi = upperHexNibble(bytes[idx]), let lo = upperHexNibble(bytes[idx + 1]) else {
                return nil
            }
            digest.append(UInt8((hi << 4) | lo))
            idx += 2
        }
        var out = Data([algSha256])
        out.append(digest)
        return out
    }

    private static func upperHexNibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x41...0x46: return c - 0x41 + 10
        default: return nil
        }
    }

    // MARK: - From a certificate

    /// `alg(1) || SHA-256(der)`.
    public static func fromDer(_ der: Data) -> Data {
        var out = Data([algSha256])
        out.append(Data(SHA256.hash(data: der)))
        return out
    }

    /// Fingerprint of an X.509 certificate given as PEM (`-----BEGIN CERTIFICATE-----` ...): the
    /// base64 body is decoded to DER and hashed. `nil` when the PEM has no decodable body.
    public static func fromPem(_ pem: String) -> Data? {
        var body = ""
        for rawLine in pem.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("-----") { continue }
            body += line
        }
        guard !body.isEmpty, let der = Data(base64Encoded: body), !der.isEmpty else { return nil }
        return fromDer(der)
    }

    // MARK: - Check (a): SDP

    /// `checkSdp(sdp, expectedFp)` passes iff all of the following hold:
    /// - there is at least one `a=fingerprint:` line (session or media level, CRLF or LF);
    /// - every such line is `a=fingerprint:<alg> <hex>` with `<alg>` equal to `sha-256` (ASCII
    ///   case-insensitive, RFC 8122);
    /// - for every line, `<hex>` upper-cased equals the canonical HEX of `expectedFp`;
    /// - there are no other hash algorithms and no differing values.
    public static func checkSdp(_ sdp: String, expected: Data) -> Bool {
        guard let expectedHex = hexColon(expected) else { return false }
        var seen = 0
        // components(separatedBy:) works on UTF-16 units: a CRLF pair (one Swift Character) still
        // splits at the LF, leaving the CR for the trim below.
        for rawLine in sdp.components(separatedBy: "\n") {
            var line = rawLine
            if line.hasSuffix("\r") { line.removeLast() }
            guard line.hasPrefix("a=fingerprint:") else { continue }
            let value = String(line.dropFirst("a=fingerprint:".count))
            let parts = value.split(separator: " ", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return false }
            guard parts[0].lowercased() == "sha-256" else { return false }
            guard parts[1].uppercased() == expectedHex else { return false }
            seen += 1
        }
        return seen > 0
    }

    // MARK: - Check (b): negotiated certificate (stats)

    /// One entry of a `RTCStatisticsReport`, reduced to string values (the only ones check (b)
    /// reads: `dtlsState`, `localCertificateId`, `remoteCertificateId`, `fingerprint`,
    /// `fingerprintAlgorithm`).
    public struct StatsRecord: Equatable {
        public let id: String
        public let type: String
        public let values: [String: String]

        public init(id: String, type: String, values: [String: String]) {
            self.id = id
            self.type = type
            self.values = values
        }
    }

    public enum StatsVerdict: Equatable {
        /// Every `transport` entry with `dtlsState == connected` negotiated exactly the pinned
        /// certificates, and at least one such entry exists.
        case pass
        /// Stats missing or incomplete (no connected transport yet, a certificate entry not yet
        /// reported): retry.
        case pending
        /// A negotiated certificate differs from the pinned one (or uses another algorithm).
        case mismatch
    }

    /// For each `transport` entry with `dtlsState == "connected"`: the `remoteCertificateId`
    /// certificate must have `fingerprintAlgorithm == sha-256` (case-insensitive) and
    /// upper-cased `fingerprint == HEX(fpPeer)`; the `localCertificateId` one the same against
    /// `fpSelf`.
    public static func checkStats(_ records: [StatsRecord], fpSelf: Data, fpPeer: Data) -> StatsVerdict {
        guard let selfHex = hexColon(fpSelf), let peerHex = hexColon(fpPeer) else { return .mismatch }
        var certs: [String: StatsRecord] = [:]
        for r in records where r.type == "certificate" {
            certs[r.id] = r
        }
        var connectedTransports = 0
        var pending = false
        for r in records where r.type == "transport" {
            guard r.values["dtlsState"] == "connected" else { continue }
            connectedTransports += 1
            let pairs: [(String, String)] = [
                (r.values["remoteCertificateId"] ?? "", peerHex),
                (r.values["localCertificateId"] ?? "", selfHex),
            ]
            for (certId, wantedHex) in pairs {
                guard !certId.isEmpty, let cert = certs[certId],
                      let alg = cert.values["fingerprintAlgorithm"],
                      let fp = cert.values["fingerprint"] else {
                    pending = true
                    continue
                }
                if alg.lowercased() != "sha-256" || fp.uppercased() != wantedHex {
                    return .mismatch
                }
            }
        }
        if connectedTransports == 0 || pending { return .pending }
        return .pass
    }

    // MARK: - Failure stage -> numeric verdict (local logs only)

    /// Numeric verdict of the stage a failed DTLS check reports
    /// (`QAudionPeerConnection.onDtlsFingerprintFailure`). The redacted remote logs carry numbers
    /// only, never a fingerprint:
    /// - 1 `sdp_remote`, 2 `sdp_local`, 4 `pin_timeout`;
    /// - 3 `stats`: check (b) saw a REAL certificate mismatch in the transport stats;
    /// - 5 `stats_timeout`: check (b) reached its 5 s deadline with NO VERDICT: the peer
    ///   certificate was neither confirmed nor shown to differ, so the call is unverified, NOT
    ///   proven benign (and not proven hostile either), and it still ends fail-closed. The
    ///   pending causes, every one of them an incomplete report and not a mismatch:
    ///   1. the peer pin (`CallDtlsContext.peerFingerprint`) was still missing, so no stats were
    ///      requested at all;
    ///   2. no `transport` stats entry with `dtlsState == connected` in any report;
    ///   3. a connected transport without a `localCertificateId` or a `remoteCertificateId` (or
    ///      an empty one). A certificate-stats cache taken before the DTLS handshake delivered the
    ///      peer certificate and never refreshed looks exactly like this: the WebRTC builds
    ///      without patch P9 (up to `webrtc-ios-m150-a256-dplc-9`) did that;
    ///   4. a certificate id that no `certificate` entry of the report carries;
    ///   5. a `certificate` entry without `fingerprint` or `fingerprintAlgorithm`.
    ///
    /// LOCAL ONLY: every stage ends the call with the same on-the-wire hangup reason
    /// `dtls_fp_mismatch` (WIRE_SPEC §3.8.4), which this function must never influence. An unknown
    /// stage maps to 3, the value every unlisted stage had before `stats_timeout` existed.
    public static func failureCode(stage: String) -> Int {
        switch stage {
        case "sdp_remote": return 1
        case "sdp_local": return 2
        case "stats": return 3
        case "pin_timeout": return 4
        case "stats_timeout": return 5
        default: return 3
        }
    }
}
