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
///
/// Deliberately NOT done here (spec section D lists these too, but see
/// this task's own report for why they are out of scope for this pass):
/// removing RED/CN/telephone-event from the `m=audio` line (payload-type
/// bookkeeping the rest of `QAudionPeerConnection` was not audited for
/// interaction with here), and any `RTCRtpEncodingParameters.networkPriority`
/// / DSCP-marking change (this vendored WebRTC.xcframework build's public
/// surface for that is unverified — see `VideoBandwidthCap.swift`'s own
/// "unverified" note for the sibling case, same discipline followed here:
/// no local toolchain to unzip/grep the framework's real headers, and no
/// compiler in this environment to catch a wrong guess before it ships).
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

        // Pass 1 — which Opus payload types exist IN EACH m=audio section
        // (by ordinal). Scoped per section, unlike a single SDP-wide set:
        // two DIFFERENT m=audio sections can carry two DIFFERENT Opus
        // payload-type numbers (this app negotiates more than one audio
        // profile on some calls), and a pt from section 0 must never be
        // treated as present in section 1 — that would synthesize a
        // phantom `a=fmtp`/`a=rtcp-fb` line for a payload type the section
        // never declared.
        var ptsBySection: [Int: Set<String>] = [:]
        var inAudio = false
        var section = -1
        for line in lines {
            if line.hasPrefix("m=audio") {
                inAudio = true; section += 1
            } else if line.hasPrefix("m=") {
                inAudio = false; section += 1
            } else if inAudio, let pt = matchOpusPayloadType(line) {
                ptsBySection[section, default: []].insert(pt)
            }
        }
        if ptsBySection.isEmpty { return sdp }

        var out: [String] = []
        out.reserveCapacity(lines.count + ptsBySection.count * 2)
        inAudio = false
        section = -1
        var inOpusAudio = false
        // Per-section: which of THIS section's Opus payload types already
        // have an explicit NACK line, so `closeSection` adds one only when
        // genuinely missing (idempotency).
        var nackSeenForPt = Set<String>()
        var sectionOpusPts: Set<String> = []
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
                sectionOpusPts = ptsBySection[section] ?? []
                inOpusAudio = !sectionOpusPts.isEmpty
                nackSeenForPt.removeAll()
                sawFmtpForPt.removeAll()
            } else if line.hasPrefix("m=") {
                closeSection()
                inAudio = false; section += 1
                inOpusAudio = false
                sectionOpusPts = []
            }

            if inAudio, inOpusAudio {
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
