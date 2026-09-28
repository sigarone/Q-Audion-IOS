import Foundation

/// W-NATIVEAUDIOQUALITY (this task, spec section D) — additive Opus/SDP
/// tuning for the native-SRTP audio path ONLY (``CallCapabilities/
/// isNativeSrtpEnabledLocally``), layered on top of ``AudioSdpPolicy`` (never
/// instead of it — that file's ptime/maxptime/minptime/cbr/FEC/32 kbps
/// policy is unconditional and unowned by this file, see its own header
/// for why it must stay that way).
///
/// `apply(_:nativeSrtpEnabled:)` is a no-op — returns `sdp` byte-for-byte —
/// when `nativeSrtpEnabled` is `false`, which is every ordinary call today:
/// this file changes NOTHING about the sealed-DataChannel path's SDP.
///
/// When native SRTP IS locally enabled for this call, every Opus `m=audio`
/// section gets:
///  - `stereo=0;sprop-stereo=0` — mono. This app's mic/opus pipeline is
///    mono already; forcing the fmtp keys stops a peer's decoder/encoder
///    negotiation from assuming stereo capability that neither side uses.
///  - `maxplaybackrate=48000;sprop-maxcapturerate=48000` — explicit
///    fullband, matching the `opus/48000/2` clock rate already in the
///    `rtpmap` line (making the fmtp say what the rtpmap already commits
///    to, rather than leaving it to the decoder's own default).
///  - `a=rtcp-fb:<pt> nack` — generic NACK for the Opus payload type
///    (existing `a=rtcp-fb:<pt> transport-cc` lines, if any, are left
///    alone). Loss on a 60 ms-packetized stream is otherwise concealed by
///    in-band FEC and NetEQ PLC alone; NACK gives libwebrtc's own
///    retransmission machinery a shot at the frame first when the round
///    trip is short enough, at zero steady-state bitrate cost (RFC 4585 —
///    NACK is a control-channel feedback message, not media).
///  - N3 (network-resilience-max, this task) — every OTHER payload type is
///    stripped from the `m=audio` section entirely: the `m=audio` line's own
///    payload-type list is rewritten to carry only the Opus pt(s), and every
///    `a=rtpmap:`/`a=fmtp:`/`a=rtcp-fb:` line for a non-Opus pt in that
///    section is dropped. In practice this is RED, CN (comfort noise) and
///    telephone-event (DTMF) — parity with Android's own
///    `NativeAudioSdpPolicy.kt:35-39` (verified against that file, this
///    exact commit's sibling), which already does this for the SAME reason
///    given there: RED specifically DOUBLES the wire bitrate (current frame +
///    previous frame in every packet), which would blow the 32 kbps ceiling
///    `AudioSdpPolicy` exists to hold; CN/DTMF have no place on a CBR,
///    no-DTX, frame-encrypted profile. Today's iOS-iOS calls never actually
///    negotiate RED (only payload 111/Opus shows up in the field per the
///    resilience assessment's own log read), so this is a protection against
///    a FUTURE peer/offer advertising it, not a fix for an observed bug —
///    exactly like Android's own doc frames it ("today RED is not negotiated
///    ... but this protects the 32 kbps rule even so").
///
/// Deliberately NOT done here (spec section D lists this too, but see this
/// task's own report for why it lives elsewhere): any
/// `RTCRtpEncodingParameters.networkPriority` / DSCP-marking change — that
/// is applied where this app's 32 kbps encoder clamp itself is applied
/// (`QAudionPeerConnection.swift`), not in SDP text, since `networkPriority`
/// is a sender-parameter API, not an SDP attribute.
///
/// Pure string transformation, same discipline as ``AudioSdpPolicy`` — no
/// WebRTC/Foundation UI types beyond `String` — so it is unit-testable
/// without the WebRTC binary target.
enum NativeAudioSdpPolicy {

    private static let rtpmapOpusPattern = "^a=rtpmap:([0-9]+)\\s+opus/48000/2\\s*$"

    /// Returns `sdp` unchanged when `nativeSrtpEnabled` is `false`. Otherwise
    /// applies the mono/fullband fmtp keys + NACK to every Opus `m=audio`
    /// section, exactly as this file's header describes. Byte-for-byte
    /// idempotent: applying twice equals applying once.
    static func apply(_ sdp: String, nativeSrtpEnabled: Bool) -> String {
        guard nativeSrtpEnabled else { return sdp }

        var lines = sdp.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let hadTrailingNewline = !lines.isEmpty && lines.last!.isEmpty
        if hadTrailingNewline { lines.removeLast() }

        // Pass 1 — per m=audio section (by ordinal): every payload type
        // listed on the m= line itself (`allPtsBySection`), and which of
        // those are Opus (`opusPtsBySection`, by rtpmap). Scoped per
        // section, unlike SDP-wide sets: two DIFFERENT m=audio sections can
        // carry two DIFFERENT Opus payload-type numbers (this app
        // negotiates more than one audio profile on some calls), and a pt
        // from section 0 must never be treated as present in section 1 —
        // that would synthesize a phantom line, or strip the wrong pt, for
        // a payload type the section never declared.
        var allPtsBySection: [Int: [String]] = [:]
        var opusPtsBySection: [Int: Set<String>] = [:]
        var inAudio = false
        var section = -1
        for line in lines {
            if line.hasPrefix("m=audio") {
                inAudio = true; section += 1
                allPtsBySection[section] = matchAudioMlinePayloadTypes(line)
            } else if line.hasPrefix("m=") {
                inAudio = false; section += 1
            } else if inAudio, let pt = matchOpusPayloadType(line) {
                opusPtsBySection[section, default: []].insert(pt)
            }
        }
        if opusPtsBySection.values.allSatisfy({ $0.isEmpty }) { return sdp }

        var out: [String] = []
        out.reserveCapacity(lines.count + opusPtsBySection.count * 2)
        inAudio = false
        section = -1
        var inOpusAudio = false
        // Per-section: which of THIS section's Opus payload types already
        // have an explicit NACK line, so `closeSection` adds one only when
        // genuinely missing (idempotency).
        var nackSeenForPt = Set<String>()
        var sectionOpusPts: Set<String> = []
        // N3 — every OTHER payload type declared on this section's m=audio
        // line (RED/CN/telephone-event/etc.): their rtpmap/fmtp/rtcp-fb
        // lines are dropped below.
        var sectionNonOpusPts: Set<String> = []
        var sawFmtpForPt = Set<String>()

        func closeSection() {
            guard inOpusAudio else { return }
            for pt in sectionOpusPts.sorted() where !nackSeenForPt.contains(pt) {
                out.append("a=rtcp-fb:\(pt) nack")
            }
            // Defensive: an Opus rtpmap with no fmtp anywhere in the section
            // (should not happen once `AudioSdpPolicy.apply` has already run
            // first — it always synthesizes one — but this file must not
            // assume that ordering to stay independently testable/correct).
            for pt in sectionOpusPts.sorted() where !sawFmtpForPt.contains(pt) {
                out.append("a=fmtp:\(pt) \(monoFullbandParams)")
            }
        }

        for line in lines {
            if line.hasPrefix("m=audio") {
                closeSection()
                inAudio = true; section += 1
                sectionOpusPts = opusPtsBySection[section] ?? []
                let mlinePts = allPtsBySection[section] ?? []
                sectionNonOpusPts = Set(mlinePts).subtracting(sectionOpusPts)
                inOpusAudio = !sectionOpusPts.isEmpty
                nackSeenForPt.removeAll()
                sawFmtpForPt.removeAll()
                // Review hardening — strip only when the m= line itself lists
                // at least one of the section's Opus pts. A non-conformant
                // section whose Opus rtpmap is not on its m= line is left
                // exactly as it came (never "repaired" into an m= line that
                // names a pt the offerer did not): stripping there could
                // leave an m=audio with no usable codec at all.
                if inOpusAudio, !mlinePts.contains(where: { sectionOpusPts.contains($0) }) {
                    sectionNonOpusPts = []
                    out.append(line)
                    continue
                }
                if inOpusAudio {
                    // N3 — rewrite the m=audio line itself to list ONLY the
                    // Opus payload type(s), same as Android's own
                    // `NativeAudioSdpPolicy.apply` (`MLINE_AUDIO` rewrite).
                    // A section with no Opus at all (`inOpusAudio == false`)
                    // falls through to the plain `out.append(line)` below,
                    // untouched — nothing here applies to it.
                    out.append(rewriteAudioMline(line, keepingOnlyPts: sectionOpusPts))
                    continue
                }
            } else if line.hasPrefix("m=") {
                closeSection()
                inAudio = false; section += 1
                inOpusAudio = false
                sectionOpusPts = []
                sectionNonOpusPts = []
            }

            if inAudio, inOpusAudio {
                // N3 — drop every line that belongs EXCLUSIVELY to a
                // non-Opus payload type in this section (RED/CN/
                // telephone-event/legacy codecs). Checked before the
                // Opus-specific fmtp/rtcp-fb rewrites below so a non-Opus
                // pt can never accidentally match one of those (payload
                // type numbers are disjoint by construction — a pt is
                // either in `sectionOpusPts` or `sectionNonOpusPts`, never
                // both — but this ordering keeps the two concerns
                // independent regardless).
                if let pt = payloadTypeReferencedBy(line), sectionNonOpusPts.contains(pt) {
                    continue
                }
                if let pt = sectionOpusPts.first(where: { line.hasPrefix("a=fmtp:\($0) ") }) {
                    sawFmtpForPt.insert(pt)
                    out.append(rewriteFmtp(line, payloadType: pt))
                    continue
                }
                if let pt = sectionOpusPts.first(where: { line.hasPrefix("a=rtcp-fb:\($0) ") }) {
                    if line.hasSuffix(" nack") || line.contains(" nack ") {
                        nackSeenForPt.insert(pt)
                    }
                    out.append(line)
                    continue
                }
            }
            out.append(line)
        }
        closeSection()
        let joined = out.joined(separator: "\r\n")
        return hadTrailingNewline ? joined + "\r\n" : joined
    }

    /// N3 — the payload-type list from an `m=audio <port> <proto> <pt>...`
    /// line, in the order it appears. Plain whitespace tokenizing (not a
    /// regex with capture groups — Swift's `NSRegularExpression` groups are
    /// more ceremony than this needs): the first 3 tokens are `m=audio`,
    /// port and proto; everything after is a payload type.
    private static func matchAudioMlinePayloadTypes(_ line: String) -> [String] {
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.count > 3 else { return [] }
        return Array(tokens[3...])
    }

    /// N3 — rewrites an `m=audio` line's payload-type list to contain only
    /// `opusPts`, numerically sorted (matches Android's own
    /// `orderedPts.sortedBy { it.toIntOrNull() ... }` — payload-type numbers
    /// sort numerically, not lexically: "9" < "111"). Port and proto (the
    /// first two tokens after `m=audio`) are preserved byte-for-byte.
    private static func rewriteAudioMline(_ line: String, keepingOnlyPts opusPts: Set<String>) -> String {
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.count > 3 else { return line }
        let head = tokens[0...2].joined(separator: " ")
        // Review hardening — only pts the m= line already lists (never add
        // one), numerically ordered like Android's rewrite.
        let listed = Set(tokens[3...]).intersection(opusPts)
        guard !listed.isEmpty else { return line }
        let ordered = listed.sorted { (Int($0) ?? .max) < (Int($1) ?? .max) }
        return head + " " + ordered.joined(separator: " ")
    }

    /// N3 — the payload type an `a=rtpmap:`/`a=fmtp:`/`a=rtcp-fb:` line
    /// refers to (the digits immediately after the colon), or `nil` for any
    /// other line shape (including a bare `a=ptime:`/`a=maxptime:` line,
    /// which carries no payload type at all and must never be treated as
    /// one just because it also starts with `a=` and contains digits).
    private static func payloadTypeReferencedBy(_ line: String) -> String? {
        for prefix in ["a=rtpmap:", "a=fmtp:", "a=rtcp-fb:"] {
            guard line.hasPrefix(prefix) else { continue }
            let digits = line.dropFirst(prefix.count).prefix { $0.isNumber }
            return digits.isEmpty ? nil : String(digits)
        }
        return nil
    }

    private static let monoFullbandParams =
        "stereo=0;sprop-stereo=0;maxplaybackrate=48000;sprop-maxcapturerate=48000"

    private static func matchOpusPayloadType(_ line: String) -> String? {
        guard let range = line.range(of: rtpmapOpusPattern, options: .regularExpression) else { return nil }
        let matched = String(line[range])
        guard let colon = matched.firstIndex(of: ":"),
              let space = matched.firstIndex(of: " ") else { return nil }
        let ptStart = matched.index(after: colon)
        guard ptStart < space else { return nil }
        return String(matched[ptStart..<space])
    }

    /// Adds/overwrites ONLY the four mono/fullband keys this file owns;
    /// every other key (cbr, useinbandfec, maxaveragebitrate, minptime, and
    /// anything else already on the line) is preserved byte-for-byte and
    /// in its existing order — this file must never re-decide anything
    /// ``AudioSdpPolicy`` already set.
    private static func rewriteFmtp(_ line: String, payloadType pt: String) -> String {
        let prefix = "a=fmtp:\(pt) "
        guard line.hasPrefix(prefix) else { return line }
        let paramsString = String(line.dropFirst(prefix.count))
        var order: [String] = []
        var values: [String: String] = [:]
        for rawParam in paramsString.components(separatedBy: ";") {
            let p = rawParam.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty else { continue }
            if let eq = p.firstIndex(of: "=") {
                let key = String(p[p.startIndex..<eq])
                let value = String(p[p.index(after: eq)...])
                if values[key] == nil { order.append(key) }
                values[key] = value
            } else {
                if values[p] == nil { order.append(p) }
                values[p] = ""
            }
        }
        func set(_ key: String, _ value: String) {
            if values[key] == nil { order.append(key) }
            values[key] = value
        }
        set("stereo", "0")
        set("sprop-stereo", "0")
        set("maxplaybackrate", "48000")
        set("sprop-maxcapturerate", "48000")
        let rebuilt = order.map { key -> String in
            let v = values[key] ?? ""
            return v.isEmpty ? key : "\(key)=\(v)"
        }.joined(separator: ";")
        return prefix + rebuilt
    }
}
