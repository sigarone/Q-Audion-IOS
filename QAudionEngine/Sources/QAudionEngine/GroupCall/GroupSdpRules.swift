import Foundation

/// Group calls v2 (spec §4.4) — the SDP rules both PeerConnections obey, as
/// pure string functions so every rule is unit-tested without WebRTC:
///
///  * DTLS pin: the fingerprint in qjanus' SDP (answer for the publisher, offer
///    for the subscriber) MUST equal the `dtls_fingerprint` the server handed
///    out, else both PeerConnections are closed (`dtls_pin_mismatch`).
///  * header extensions: Janus 1.4.2 has no Cryptex (RFC 9335), so RTP header
///    extensions travel in the clear on the client <-> qjanus hop. Only
///    `mid`, `rid`, `repaired-rid` and transport-wide-cc may be negotiated
///    (spec §10). An allow-list is used, not a block-list, so an extension a
///    future WebRTC build starts offering can never leak by default.
///  * audio profile: identical to the 1:1 profile (60 ms / 32 kbps CBR, in-band
///    FEC, no DTX) — `AudioSdpPolicy` is reused verbatim, plus the explicit
///    `usedtx=0;stereo=0` of spec §4.4.
///  * VP8 only (spec §12.8): every other video codec, and their RTX, is removed.
///
/// Both directions are filtered (spec §12.4): the local description we create AND
/// the remote description qjanus sends (answer for the publisher, offer for the
/// subscriber) go through the same header-extension allow-list and codec filter
/// before they are applied, so a node cannot switch an extension or a codec on.
public enum GroupSdpRules {

    // MARK: - DTLS fingerprint pin

    /// "sha-256 AB:CD:..." with upper-case hex pairs, or nil when `raw` is not
    /// a SHA-256 fingerprint (32 bytes). Accepts the SDP spelling
    /// (`sha-256 ab:cd..`, any case) and the value of an `a=fingerprint:` line
    /// after the colon.
    public static func normalizeFingerprint(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("a=fingerprint:") { text = String(text.dropFirst("a=fingerprint:".count)) }
        let parts = text.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "sha-256" else { return nil }
        let pairs = parts[1].split(separator: ":", omittingEmptySubsequences: false)
        guard pairs.count == 32 else { return nil }
        var out: [String] = []
        out.reserveCapacity(32)
        for pair in pairs {
            guard pair.utf8.count == 2 else { return nil }
            for byte in pair.utf8 {
                let isDigit = byte >= 0x30 && byte <= 0x39
                let isUpper = byte >= 0x41 && byte <= 0x46
                let isLower = byte >= 0x61 && byte <= 0x66
                if !isDigit && !isUpper && !isLower { return nil }
            }
            out.append(pair.uppercased())
        }
        return "sha-256 " + out.joined(separator: ":")
    }

    /// Every `a=fingerprint:` value of the SDP (session and media level), as
    /// normalised strings; a fingerprint that is not SHA-256 is kept as-is
    /// (lower-cased) so a pin check treats it as a mismatch instead of
    /// silently skipping it.
    public static func fingerprints(in sdp: String) -> [String] {
        var out: [String] = []
        for line in lines(of: sdp) where line.hasPrefix("a=fingerprint:") {
            let value = String(line.dropFirst("a=fingerprint:".count))
            out.append(normalizeFingerprint(value) ?? value.lowercased())
        }
        return out
    }

    public enum PinResult: Equatable, Sendable {
        case match
        case mismatch
        /// The SDP carries no fingerprint at all: refused like a mismatch.
        case missing
    }

    public static func checkPin(sdp: String, expected: String) -> PinResult {
        guard let pinned = normalizeFingerprint(expected) else { return .mismatch }
        let found = fingerprints(in: sdp)
        if found.isEmpty { return .missing }
        return found.allSatisfy { $0 == pinned } ? .match : .mismatch
    }

    // MARK: - RTP header extensions

    public static let allowedExtmapUris: Set<String> = [
        "urn:ietf:params:rtp-hdrext:sdes:mid",
        "urn:ietf:params:rtp-hdrext:sdes:rtp-stream-id",
        "urn:ietf:params:rtp-hdrext:sdes:repaired-rtp-stream-id",
        "http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01",
    ]

    /// The URIs spec §4.4 names explicitly as removed. Kept as its own list so
    /// the tests can pin them by name; the allow-list above removes them too.
    public static let namedRemovedExtmapUris: [String] = [
        "urn:ietf:params:rtp-hdrext:ssrc-audio-level",
        "http://www.webrtc.org/experiments/rtp-hdrext/abs-capture-time",
        "urn:3gpp:video-orientation",
    ]

    public static func isAllowedExtension(uri: String) -> Bool {
        allowedExtmapUris.contains(uri)
    }

    /// `a=extmap:<id>[/direction] <uri> [attrs]` -> uri
    static func extmapUri(of line: String) -> String? {
        guard line.hasPrefix("a=extmap:") else { return nil }
        let body = line.dropFirst("a=extmap:".count)
        let parts = body.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        return String(parts[1])
    }

    /// Drops every `a=extmap` line whose URI is not on the allow-list.
    /// Idempotent. Line endings are normalised to CRLF (the SDP wire format).
    public static func stripHeaderExtensions(_ sdp: String) -> String {
        rebuild(sdp) { line in
            guard let uri = extmapUri(of: line) else { return true }
            return isAllowedExtension(uri: uri)
        }
    }

    /// The extmap URIs still present in `sdp` that are NOT allowed. Used by the
    /// tests and by the post-condition check in the PeerConnection wrapper.
    public static func disallowedExtensions(in sdp: String) -> [String] {
        lines(of: sdp).compactMap { line -> String? in
            guard let uri = extmapUri(of: line), !isAllowedExtension(uri: uri) else { return nil }
            return uri
        }
    }

    // MARK: - Video codec (spec §12.8)

    /// Keeps VP8 (and the RTX of VP8) as the ONLY video payload types of every
    /// `m=video` section: the other codecs, RED / ULPFEC and every RTX whose
    /// `apt` is not VP8 are removed from the m-line and from their `a=rtpmap`,
    /// `a=fmtp` and `a=rtcp-fb` lines. A section that lists no VP8 at all (Janus
    /// spells a rejected m-line `m=video 0 ... 0`) is left alone: there is nothing
    /// to keep, and an m-line without a single format would not parse. Idempotent.
    public static func keepOnlyVp8Video(_ sdp: String) -> String {
        let all = lines(of: sdp)
        // Pass 1: the payload types to keep, per `m=video` section (by line index).
        var keepBySection: [Int: Set<String>] = [:]
        var sectionStart = -1
        var inVideo = false
        var names: [String: String] = [:]
        var aptOf: [String: String] = [:]
        func closeSection() {
            guard inVideo, sectionStart >= 0 else { return }
            var keep = Set(names.filter { $0.value == "VP8" }.map { $0.key })
            guard !keep.isEmpty else { return }
            for (pt, name) in names where name == "RTX" {
                if let apt = aptOf[pt], keep.contains(apt) { keep.insert(pt) }
            }
            keepBySection[sectionStart] = keep
        }
        for (index, line) in all.enumerated() {
            if line.hasPrefix("m=") {
                closeSection()
                inVideo = line.hasPrefix("m=video")
                sectionStart = index
                names = [:]
                aptOf = [:]
            } else if inVideo {
                if let entry = rtpmapEntry(of: line) { names[entry.pt] = entry.name }
                if let entry = fmtpApt(of: line) { aptOf[entry.pt] = entry.apt }
            }
        }
        closeSection()
        guard !keepBySection.isEmpty else { return rebuild(sdp) { _ in true } }

        // Pass 2: rewrite the m-lines and drop the lines of the removed types.
        var out: [String] = []
        var keep: Set<String>?
        for (index, line) in all.enumerated() {
            if line.hasPrefix("m=") {
                keep = keepBySection[index]
                if let keep = keep {
                    let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                    if parts.count > 3 {
                        let formats = parts[3...].filter { keep.contains($0) }
                        out.append((Array(parts[0..<3]) + formats).joined(separator: " "))
                        continue
                    }
                }
                out.append(line)
            } else if let keep = keep, let pt = payloadType(ofAttributeLine: line), !keep.contains(pt) {
                continue
            } else {
                out.append(line)
            }
        }
        return out.joined(separator: "\r\n") + "\r\n"
    }

    /// `a=rtpmap:<pt> <NAME>/<rate>[/<ch>]` -> (pt, upper-cased NAME)
    private static func rtpmapEntry(of line: String) -> (pt: String, name: String)? {
        guard line.hasPrefix("a=rtpmap:") else { return nil }
        let parts = line.dropFirst("a=rtpmap:".count).split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, let name = parts[1].split(separator: "/").first else { return nil }
        return (pt: String(parts[0]), name: name.uppercased())
    }

    /// `a=fmtp:<pt> ...;apt=<pt>;...` -> (pt, apt)
    private static func fmtpApt(of line: String) -> (pt: String, apt: String)? {
        guard line.hasPrefix("a=fmtp:") else { return nil }
        let parts = line.dropFirst("a=fmtp:".count).split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        for piece in parts[1].split(separator: ";") {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("apt=") { return (pt: String(parts[0]), apt: String(trimmed.dropFirst("apt=".count))) }
        }
        return nil
    }

    /// The payload type an `a=rtpmap:` / `a=fmtp:` / `a=rtcp-fb:` line belongs to
    /// (`a=rtcp-fb:*` applies to every type and has none).
    private static func payloadType(ofAttributeLine line: String) -> String? {
        for prefix in ["a=rtpmap:", "a=fmtp:", "a=rtcp-fb:"] where line.hasPrefix(prefix) {
            guard let token = line.dropFirst(prefix.count).split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first,
                  token != "*" else { return nil }
            return String(token)
        }
        return nil
    }

    // MARK: - Audio profile

    /// The 1:1 Opus policy (`AudioSdpPolicy`: cbr, in-band FEC, 32 kbps,
    /// minptime/ptime 60, DTX removed; `NativeAudioSdpPolicy`: Opus only, so
    /// no RED, NACK on, mono fullband) plus the explicit `usedtx=0;stereo=0`
    /// of spec §4.4 on every Opus fmtp line.
    static func applyAudioProfile(_ sdp: String) -> String {
        let base = NativeAudioSdpPolicy.apply(AudioSdpPolicy.apply(sdp), nativeSrtpEnabled: true)
        var opusPayloadTypes = Set<String>()
        for line in lines(of: base) {
            if let pt = opusPayloadType(of: line) { opusPayloadTypes.insert(pt) }
        }
        guard !opusPayloadTypes.isEmpty else { return base }
        var out: [String] = []
        for line in lines(of: base) {
            if let pt = opusPayloadTypes.first(where: { line.hasPrefix("a=fmtp:\($0) ") }) {
                out.append(ensureFmtpParams(line, payloadType: pt, params: [("usedtx", "0"), ("stereo", "0")]))
            } else {
                out.append(line)
            }
        }
        return out.joined(separator: "\r\n") + "\r\n"
    }

    private static func opusPayloadType(of line: String) -> String? {
        guard line.hasPrefix("a=rtpmap:") else { return nil }
        let body = line.dropFirst("a=rtpmap:".count)
        let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[1].lowercased().hasPrefix("opus/48000") else { return nil }
        return String(parts[0])
    }

    private static func ensureFmtpParams(_ line: String, payloadType: String, params: [(String, String)]) -> String {
        let prefix = "a=fmtp:\(payloadType) "
        var order: [String] = []
        var values: [String: String] = [:]
        for raw in String(line.dropFirst(prefix.count)).components(separatedBy: ";") {
            let piece = raw.trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty else { continue }
            if let eq = piece.firstIndex(of: "=") {
                let key = String(piece[piece.startIndex..<eq])
                if values[key] == nil { order.append(key) }
                values[key] = String(piece[piece.index(after: eq)...])
            } else {
                if values[piece] == nil { order.append(piece) }
                values[piece] = ""
            }
        }
        for (key, value) in params {
            if values[key] == nil { order.append(key) }
            values[key] = value
        }
        let rebuilt = order.map { key -> String in
            let value = values[key] ?? ""
            return value.isEmpty ? key : "\(key)=\(value)"
        }.joined(separator: ";")
        return prefix + rebuilt
    }

    // MARK: - DTLS role

    /// The subscriber answers Janus' `actpass` offer. libwebrtc would answer
    /// `active`; forcing `passive` keeps Janus the DTLS client on BOTH
    /// PeerConnections (the role verified by the qjanus probe, spec §10).
    public static func forcePassiveSetup(inAnswer sdp: String) -> String {
        var out: [String] = []
        for line in lines(of: sdp) {
            out.append(line == "a=setup:active" ? "a=setup:passive" : line)
        }
        return out.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: - Composition

    public enum Role: Equatable, Sendable {
        /// The publisher's local offer.
        case publisherOffer
        /// The subscriber's local answer to Janus' offer.
        case subscriberAnswer
    }

    /// The SDP handed to `setLocalDescription`.
    public static func mungeLocal(_ sdp: String, role: Role) -> String {
        var out = stripHeaderExtensions(sdp)
        out = keepOnlyVp8Video(out)
        out = applyAudioProfile(out)
        if role == .subscriberAnswer { out = forcePassiveSetup(inAnswer: out) }
        return out
    }

    /// The remote SDP handed to `setRemoteDescription`: Janus' answer or
    /// offer, with the SAME rules as the local side (spec §12.4 / §12.8): the
    /// header-extension allow-list (an extension qjanus offers or echoes, e.g.
    /// `ssrc-audio-level`, is never negotiated), VP8 only, and the audio profile
    /// so OUR Opus decoder/encoder side of the negotiation is constrained even if
    /// the node's SDP carries different defaults (`AudioSdpPolicy` is unilateral
    /// by design). The pin check runs on the RAW sdp before this.
    public static func mungeRemote(_ sdp: String) -> String {
        var out = stripHeaderExtensions(sdp)
        out = keepOnlyVp8Video(out)
        return applyAudioProfile(out)
    }

    // MARK: - m-line inspection

    /// The `a=mid:` of every `m=video` section, in SDP order. Used to build the
    /// `descriptions` of the publisher's `publish` request.
    public static func videoMids(in sdp: String) -> [String] {
        var out: [String] = []
        var inVideo = false
        for line in lines(of: sdp) {
            if line.hasPrefix("m=") {
                inVideo = line.hasPrefix("m=video")
            } else if inVideo, line.hasPrefix("a=mid:") {
                out.append(String(line.dropFirst("a=mid:".count)).trimmingCharacters(in: .whitespaces))
            }
        }
        return out
    }

    // MARK: - Helpers

    static func lines(of sdp: String) -> [String] {
        var parts = sdp.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        while let last = parts.last, last.isEmpty { parts.removeLast() }
        return parts
    }

    private static func rebuild(_ sdp: String, keep: (String) -> Bool) -> String {
        let kept = lines(of: sdp).filter(keep)
        return kept.joined(separator: "\r\n") + "\r\n"
    }
}
