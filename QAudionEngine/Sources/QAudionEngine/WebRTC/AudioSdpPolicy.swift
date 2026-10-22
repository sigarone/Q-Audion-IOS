import Foundation

/// IOS-C4b / W-SRTPPTIME (2026-08-26) — Opus policy for the native SRTP audio
/// path (``CallCapabilities/audioSrtpV1``), applied by rewriting the Opus
/// `a=fmtp` line of every SDP this client produces AND every SDP it
/// receives. The fmtp / packet-time rules are a byte-for-byte port of
/// Android's `AudioSdpPolicy.kt` (values copied verbatim, not approximated —
/// see that file for the full rationale); the audio header-extension rule at
/// the end of the list is the same audio wire policy, applied here:
///
///  - `cbr=1`                   — constant bitrate: uniform packet sizes.
///  - `useinbandfec=1`          — in-band FEC: each packet carries a
///                                low-rate redundant copy of the previous
///                                frame, so a single loss is concealed.
///  - `maxaveragebitrate=32000` — this codec's OWN literal, independent of
///                                `AudioConstants.opusBitrate` (raised to 40
///                                kbps by W-OPUSHEADROOM, 2026-08-27): the
///                                sealed-DataChannel path's fleet-default
///                                profile still clamps that base down to
///                                exactly this same 32 kbps (zero headroom),
///                                so the two paths stay aligned in practice,
///                                but nothing here derives from that constant
///                                and a future DataChannel-side change would
///                                not automatically follow here.
///  - `usedtx` REMOVED          — discontinuous transmission both leaks
///                                speech-activity timing (breaks the CBR
///                                posture) and adds resume-lag artifacts.
///  - `a=ptime:60` + `a=maxptime:60` + `minptime=60` — pin packetization
///                                time to the 60 ms long-audio profile
///                                instead of libwebrtc's 20 ms default
///                                (3x the packet rate / per-packet overhead
///                                of the DataChannel path otherwise).
///  - audio header extensions   — an Opus `m=audio` section negotiates none
///                                of the RTP header extensions below, so the
///                                audio stream is a constant-size,
///                                constant-rate packet train and the clear
///                                RTP header carries no per-packet speech
///                                indicator:
///                                * `ssrc-audio-level` / `csrc-audio-level`
///                                  (RFC 6464 / 6465) in their plain form,
///                                  whatever `a=cryptex` says: a cryptex
///                                  line in one description proves nothing
///                                  about the other side's stream. Only the
///                                  RFC 6904 wrapped form (`a=extmap:<id>
///                                  urn:ietf:params:rtp-hdrext:encrypt <uri>`)
///                                  may stay.
///                                * the send-side bandwidth-estimation
///                                  extensions (`transport-wide-cc` in both
///                                  spellings, `abs-send-time`, `toffset`) and
///                                  the `a=rtcp-fb ... transport-cc` of the
///                                  Opus payload type. libwebrtc sends
///                                  padding-only packets (padding and
///                                  bandwidth probes) on a stream only when
///                                  that stream negotiated one of them, so the
///                                  audio stream stays at its media packet
///                                  rate. The video `m=` section keeps its own
///                                  `transport-cc`: a video upgrade still gets
///                                  its bandwidth feedback.
///                                * `abs-capture-time`: it rides on some audio
///                                  packets only, which makes them larger and
///                                  breaks the constant packet size.
///                                Session-level `a=extmap:` lines (before the
///                                first `m=` line) are dropped outright: RFC
///                                8285 would apply them to every section,
///                                libwebrtc never writes them.
///                                Removal is unilateral (an extension absent
///                                from one side's SDP is simply not
///                                negotiated) and, like the fmtp rewrite,
///                                runs on both directions. The video section
///                                is not touched.
///
/// Applying the rewrite in BOTH directions makes the policy unilateral: the
/// munged outbound SDP constrains the PEER's encoder (an SDP receiver
/// configures its Opus sender from the fmtp it was given), and munging the
/// inbound SDP before `setRemoteDescription` constrains OUR OWN encoder even
/// against a peer that sends unmunged defaults.
///
/// Pure string transformation — no WebRTC/Foundation UI types beyond `Data`-
/// free `String` handling — so it is unit-testable without the WebRTC
/// binary target, same discipline as `RestartIceDecisions` / `GlareDecisions`
/// in this directory.
///
/// Safe to `apply()` unconditionally on every SDP, even on a build/call that
/// never negotiates ``CallCapabilities/audioSrtpV1``: `ptime`/`maxptime` are
/// advisory receiver preferences with no effect on an m=audio section
/// carrying no RTP audio (today's default — voice rides the sealed
/// DataChannel), and all emitted attributes are standard-formed values
/// libwebrtc's own SDP parser round-trips. Mirrors Android's own reasoning
/// (`AudioSdpPolicy.kt` "Today this lands on the m=audio section of LIVE
/// calls... safe by construction").
///
/// 2026-09-26 correction (W-NATIVESRTPGATE-2) — an earlier revision of this
/// task's own native-SRTP-diagnostics work gated the call to `apply()` at
/// all three `QAudionPeerConnection` call sites
/// (createOffer/createAnswer/applyRemoteSdp) on
/// ``CallCapabilities/isNativeSrtpEnabledLocally``. That was wrong: it made
/// an ORDINARY call's SDP differ from Android's, which polices every SDP
/// the same way with no such switch — the opposite of the cross-platform
/// parity this file exists for. Reverted; the three call sites are
/// unconditional again, exactly as before that gating was added.
enum AudioSdpPolicy {

    static let maxAverageBitrateBps: Int = 32_000

    /// W-SRTPPTIME — packetization time for the SRTP audio path, in ms.
    /// Applied as the full standard triple (`a=ptime`, `a=maxptime`,
    /// fmtp `minptime`) so every layer of the peer's stack gets the same
    /// answer — see Android's `AudioSdpPolicy.PTIME_MS` kdoc for why all
    /// three are needed (bare `ptime` is advisory; the fmtp `minptime` is
    /// the strongest against libwebrtc's own encoder).
    static let ptimeMs: Int = 60

    /// Per-packet speech indicators that travel in the clear RTP header
    /// (RFC 6464 `ssrc-audio-level`, RFC 6465 `csrc-audio-level`).
    static let speechIndicatorExtmapUris: Set<String> = [
        "urn:ietf:params:rtp-hdrext:ssrc-audio-level",
        "urn:ietf:params:rtp-hdrext:csrc-audio-level",
    ]

    /// The header extensions that make an RTP stream eligible for padding and
    /// bandwidth probing (libwebrtc: a module supports padding only when one of
    /// these is registered). Removed from every Opus audio section.
    static let bandwidthExtmapUris: Set<String> = [
        "http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01",
        "http://www.webrtc.org/experiments/rtp-hdrext/transport-wide-cc-02",
        "http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time",
        "urn:ietf:params:rtp-hdrext:toffset",
    ]

    /// `abs-capture-time`: carried by some audio packets only, so it changes the packet size. Removed from every Opus
    /// audio section, even in the RFC 6904 wrapped form (the size of a header-encrypted extension is still visible).
    static let captureTimeExtmapUris: Set<String> = [
        "http://www.webrtc.org/experiments/rtp-hdrext/abs-capture-time",
    ]

    /// RFC 6904: `a=extmap:<id> urn:ietf:params:rtp-hdrext:encrypt <uri>` is the
    /// header-encrypted form of the extension `<uri>`.
    private static let encryptedExtmapUri = "urn:ietf:params:rtp-hdrext:encrypt"

    private static let rtpmapOpusPattern = "^a=rtpmap:([0-9]+)\\s+opus/48000/2\\s*$"
    private static let ptimeLinePattern = "^a=(ptime|maxptime):\\s*[0-9]+\\s*$"

    /// Returns `sdp` with the Opus fmtp policy applied to every `m=audio`
    /// section. SDP without an Opus rtpmap (no audio m-line, or an exotic
    /// codec set) is returned unchanged. Line endings are preserved as
    /// CRLF (the SDP wire format); lone-LF input is normalized to CRLF,
    /// which every SDP parser accepts. Byte-for-byte port of Android's
    /// `AudioSdpPolicy.apply(sdp: String): String`.
    static func apply(_ sdp: String) -> String {
        // Normalize CRLF -> LF first, then split on LF alone — equivalent to
        // Android's `sdp.split("\r\n", "\n")` (alternative delimiters) for
        // every real SDP, which uses one line-ending convention throughout
        // rather than a mix, and avoids leaving stray "\r" remnants.
        var lines = sdp.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let hadTrailingNewline = !lines.isEmpty && lines.last!.isEmpty
        if hadTrailingNewline { lines.removeLast() }

        // Find every Opus payload type declared in an audio section, and —
        // W-SRTPPTIME — which audio sections (by ordinal among m= lines)
        // declare one, because only those sections get the ptime triple.
        var opusPts = Set<String>()
        var opusAudioSections = Set<Int>()
        var inAudio = false
        var section = -1
        for line in lines {
            if line.hasPrefix("m=audio") {
                inAudio = true; section += 1
            } else if line.hasPrefix("m=") {
                inAudio = false; section += 1
            } else if inAudio, let pt = matchOpusPayloadType(line) {
                opusPts.insert(pt)
                opusAudioSections.insert(section)
            }
        }
        if opusPts.isEmpty { return sdp }

        var out: [String] = []
        out.reserveCapacity(lines.count + opusPts.count + 2 * opusAudioSections.count)
        inAudio = false
        section = -1
        var inOpusAudio = false

        // W-SRTPPTIME — append the packetization-time pair when LEAVING a
        // policed audio section (attribute order within a media description
        // is not significant, RFC 8866 §5, so end-of-section is both valid
        // and the one position that is stable under re-application).
        func closeSection() {
            if inOpusAudio {
                out.append("a=ptime:\(ptimeMs)")
                out.append("a=maxptime:\(ptimeMs)")
            }
        }

        for line in lines {
            if line.hasPrefix("m=audio") {
                closeSection()
                inAudio = true; section += 1
                inOpusAudio = opusAudioSections.contains(section)
            } else if line.hasPrefix("m=") {
                closeSection()
                inAudio = false; section += 1
                inOpusAudio = false
            }

            // Audio wire shape — a session-level extmap (before the first m= line)
            // would apply to every section, the audio one included: dropped outright.
            if section < 0, line.hasPrefix("a=extmap:") { continue }
            if inAudio {
                // Audio wire shape — no speech indicator in the clear header, no
                // bandwidth-probing or capture-time extension on the audio stream
                // (see the type doc). Policed sections only, like the ptime pair.
                if inOpusAudio, shouldDropAudioHeaderLine(line, opusPts: opusPts) {
                    continue
                }
                // W-SRTPPTIME — drop any pre-existing ptime/maxptime in a
                // policed section; the policy's pair is re-added at the end
                // of the section, so present->replaced and absent->added
                // collapse into one code path and idempotency is structural.
                if inOpusAudio, matchesPtimeLine(line) { continue }
                if let pt = opusPts.first(where: { line.hasPrefix("a=fmtp:\($0) ") }) {
                    out.append(rewriteFmtp(line, payloadType: pt))
                    continue
                }
            }
            out.append(line)
            // An Opus rtpmap with no fmtp line anywhere in this section:
            // synthesize one right after the rtpmap so the policy still
            // lands. (libwebrtc always emits an fmtp for Opus, so this is
            // belt-and-braces for exotic remote stacks.)
            if inAudio, let pt = matchOpusPayloadType(line), opusPts.contains(pt), !sdpHasFmtp(lines, payloadType: pt) {
                out.append("a=fmtp:\(pt) cbr=1;useinbandfec=1;maxaveragebitrate=\(maxAverageBitrateBps);minptime=\(ptimeMs)")
            }
        }
        closeSection()
        let joined = out.joined(separator: "\r\n")
        return hadTrailingNewline ? joined + "\r\n" : joined
    }

    /// The target of an `a=extmap` line: its URI, and whether it is the
    /// header-encrypted (RFC 6904) form. `nil` for any other line.
    static func extmapTarget(of line: String) -> (uri: String, encrypted: Bool)? {
        guard line.hasPrefix("a=extmap:") else { return nil }
        let parts = line.dropFirst("a=extmap:".count).split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        if parts[1] == encryptedExtmapUri {
            guard parts.count >= 3 else { return nil }
            return (String(parts[2]), true)
        }
        return (String(parts[1]), false)
    }

    /// True for the lines an Opus audio section must not carry: an extmap of a
    /// speech indicator in its plain form, an extmap of a bandwidth estimation or
    /// capture-time extension (wrapped or not), and the `transport-cc` feedback of
    /// the Opus payload type (or of every type, `*`).
    private static func shouldDropAudioHeaderLine(_ line: String, opusPts: Set<String>) -> Bool {
        if let target = extmapTarget(of: line) {
            if bandwidthExtmapUris.contains(target.uri) || captureTimeExtmapUris.contains(target.uri) { return true }
            if speechIndicatorExtmapUris.contains(target.uri) { return !target.encrypted }
            return false
        }
        if line.hasPrefix("a=rtcp-fb:") {
            let parts = line.dropFirst("a=rtcp-fb:".count).split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[1] == "transport-cc" else { return false }
            return parts[0] == "*" || opusPts.contains(String(parts[0]))
        }
        return false
    }

    private static func sdpHasFmtp(_ lines: [String], payloadType pt: String) -> Bool {
        lines.contains { $0.hasPrefix("a=fmtp:\(pt) ") }
    }

    private static func matchOpusPayloadType(_ line: String) -> String? {
        guard let range = line.range(of: rtpmapOpusPattern, options: .regularExpression) else { return nil }
        // The matched substring is "a=rtpmap:<pt> opus/48000/2" (case-
        // insensitive on "opus"); extract the digits between ':' and the
        // first space.
        let matched = String(line[range])
        guard let colon = matched.firstIndex(of: ":"),
              let space = matched.firstIndex(of: " ") else { return nil }
        let ptStart = matched.index(after: colon)
        guard ptStart < space else { return nil }
        return String(matched[ptStart..<space])
    }

    private static func matchesPtimeLine(_ line: String) -> Bool {
        line.range(of: ptimeLinePattern, options: .regularExpression) != nil
    }

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
        set("cbr", "1")
        set("useinbandfec", "1")
        set("maxaveragebitrate", String(maxAverageBitrateBps))
        // W-SRTPPTIME — codec-level packetization floor. Overwrites the
        // libwebrtc default (minptime=10), which would otherwise let the
        // encoder fall back to short packets despite the advisory ptime line.
        set("minptime", String(ptimeMs))
        order.removeAll { $0 == "usedtx" }
        values.removeValue(forKey: "usedtx")
        let rebuilt = order.map { key -> String in
            let v = values[key] ?? ""
            return v.isEmpty ? key : "\(key)=\(v)"
        }.joined(separator: ";")
        return prefix + rebuilt
    }
}
