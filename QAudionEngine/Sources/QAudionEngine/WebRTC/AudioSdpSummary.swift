import Foundation

/// W-NATIVESRTPDIAG (this task) — a one-line, privacy-safe summary of a
/// negotiated audio `m=` section: codecs + fmtp, extmap ids/uris, the DTLS
/// `a=setup` role, and the negotiated direction.
///
/// Deliberately reads ONLY those five kinds of attribute lines — it never
/// looks at `a=fingerprint`, `a=ice-ufrag`/`a=ice-pwd`, `a=candidate`, or the
/// IP-bearing `c=`/`o=` lines, so there is nothing to redact after the fact:
/// the fields this line must never carry (DTLS fingerprints, ICE
/// credentials, candidates, IP addresses) are simply never read in the
/// first place, the same "safe by construction" discipline
/// ``AudioSdpPolicy`` already uses for the lines it rewrites.
///
/// Pure string parsing, no WebRTC types — unit-testable without the WebRTC
/// binary target.
enum AudioSdpSummary {

    private static let directionAttributes: Set<String> = ["sendrecv", "recvonly", "sendonly", "inactive"]

    /// Returns a single sanitized line describing `sdp`'s FIRST `m=audio`
    /// section, or `nil` when there is none. Fields are omitted from the
    /// line when absent from the section. Format — a FLAT sequence of
    /// independent `key=value` tokens, one per codec/extmap/fmtp-param
    /// (`c0`/`c1`/... index the codecs in rtpmap order, `e0`/`e1`/... the
    /// extmaps in SDP order):
    /// `"audio c0_type=<name> c0_clk=<clock> [c0_ch=<channels>] [c0_<fmtpkey>=<numeric value>]... e0_type=<uri>... role=<setup role> dir=<direction>"`
    ///
    /// W-NATIVESRTPDIAG (this task) — deliberately flat rather than the
    /// human-shorthand `codecs=111:opus/48000/2;fmtp=...` this file
    /// originally emitted: the remote log shipper's KV-precision protection
    /// (`scripts/ship-ios-logs.py`) only trusts a `key=value` token whose
    /// value is a number/bool, or an open-vocabulary word under a key whose
    /// LAST word is on a closed enum-key list (`type`, `role`, ...) — it has
    /// no shape for "a comma-list of colon/slash/semicolon-nested records",
    /// which the blob sweep treats as an opaque run and either masks or (if
    /// masking enough of the body trips the positive structured-shape gate)
    /// drops the WHOLE line to an attribute-summary fallback. Every value
    /// here is one of exactly those two protected shapes: numbers, or a
    /// word/lowerCamel value under a key ending in `type`/`role`/`dir`.
    /// Only NUMERIC fmtp params are kept (matches this app's own
    /// ``AudioSdpPolicy`` output — cbr/useinbandfec/maxaveragebitrate/
    /// minptime are all numeric); a non-numeric fmtp value from an unusual
    /// peer is dropped rather than risk being unshippable.
    static func summarize(_ sdp: String) -> String? {
        let lines = sdp.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard let audioStart = lines.firstIndex(where: { $0.hasPrefix("m=audio") }) else { return nil }
        var audioEnd = lines.count
        for i in stride(from: audioStart + 1, to: lines.count, by: 1) where lines[i].hasPrefix("m=") {
            audioEnd = i
            break
        }
        let section = lines[audioStart..<audioEnd]

        var codecOrder: [String] = []
        var codecSpec: [String: String] = [:]   // payload type -> "name/clock[/ch]"
        var fmtpParams: [String: String] = [:]  // payload type -> raw param text
        var extmaps: [(id: String, uri: String)] = []
        var setupRole: String?
        var direction: String?

        for line in section {
            if line.hasPrefix("a=rtpmap:") {
                let rest = line.dropFirst("a=rtpmap:".count)
                guard let spaceIdx = rest.firstIndex(of: " ") else { continue }
                let pt = String(rest[rest.startIndex..<spaceIdx])
                let spec = String(rest[rest.index(after: spaceIdx)...]).trimmingCharacters(in: .whitespaces)
                guard !pt.isEmpty, !spec.isEmpty else { continue }
                if codecSpec[pt] == nil { codecOrder.append(pt) }
                codecSpec[pt] = spec
            } else if line.hasPrefix("a=fmtp:") {
                let rest = line.dropFirst("a=fmtp:".count)
                guard let spaceIdx = rest.firstIndex(of: " ") else { continue }
                let pt = String(rest[rest.startIndex..<spaceIdx])
                let params = String(rest[rest.index(after: spaceIdx)...]).trimmingCharacters(in: .whitespaces)
                guard !pt.isEmpty else { continue }
                fmtpParams[pt] = params
            } else if line.hasPrefix("a=extmap:") {
                let rest = line.dropFirst("a=extmap:".count)
                guard let spaceIdx = rest.firstIndex(of: " ") else { continue }
                var idPart = String(rest[rest.startIndex..<spaceIdx])
                // "a=extmap:<id>/<direction> <uri>" — direction is optional;
                // keep only the numeric id, never the per-extension direction
                // (not sensitive, just noise this line doesn't need).
                if let slash = idPart.firstIndex(of: "/") {
                    idPart = String(idPart[idPart.startIndex..<slash])
                }
                let afterId = rest[rest.index(after: spaceIdx)...]
                let fullUri = afterId.split(separator: " ").first.map(String.init) ?? ""
                guard !idPart.isEmpty, !fullUri.isEmpty else { continue }
                // W-NATIVESRTPDIAG (this task) — keep only the LAST ':' or
                // '/'-separated segment of the URI (e.g. "sdes:mid" -> "mid",
                // "ssrc-audio-level" stays whole). The standard extension
                // URIs are namespaced under long, low-information prefixes
                // (`urn:ietf:params:rtp-hdrext:...`,
                // `http://www.webrtc.org/experiments/rtp-hdrext/...`) that
                // carry no diagnostic value beyond identifying "this is a
                // standard RTP header extension" — already implied by this
                // line's own `extmap=` key — but ARE exactly the kind of
                // long, technical, non-dictionary word run the remote log
                // shipper's vocabulary gate (`scripts/ship-ios-logs.py`,
                // `MAX_UNKNOWN_WORDS`) is designed to catch and drop the
                // WHOLE line for. Shortening to the meaningful suffix keeps
                // this line inside that budget without losing anything a
                // reader would actually use.
                let lastSeparator = fullUri.lastIndex(where: { $0 == ":" || $0 == "/" })
                let uri = lastSeparator.map { String(fullUri[fullUri.index(after: $0)...]) } ?? fullUri
                extmaps.append((id: idPart, uri: uri))
            } else if line.hasPrefix("a=setup:") {
                setupRole = String(line.dropFirst("a=setup:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("a=") {
                let attr = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if directionAttributes.contains(attr) {
                    direction = attr
                }
            }
        }

        var parts: [String] = []
        for (index, pt) in codecOrder.enumerated() {
            let spec = codecSpec[pt] ?? ""
            let specParts = spec.split(separator: "/").map(String.init)
            // specParts[0] = codec name (e.g. "opus"), [1] = clock rate,
            // [2] = channels (optional). Key ends in "type" so an
            // open-vocabulary NAME value (opus/red/...) is protected —
            // "type" is on the shipper's closed enum-key list.
            // W-NATIVESRTPDIAG — "c<N>_" with the underscore (not "c<N>"
            // glued straight to the field name): the shipper's identifier
            // grammar only splits a key into separately-judged pieces at a
            // non-alphanumeric separator, and "c0"/"c1"/... are added to
            // APP_VOCAB as their own short literal tokens — gluing them to
            // "type" etc. with no separator would make the whole
            // "c0type" one unrecognized mixed-alnum unit instead.
            if let name = specParts.first { parts.append("c\(index)_type=\(name)") }
            if specParts.count > 1 { parts.append("c\(index)_clk=\(specParts[1])") }
            if specParts.count > 2 { parts.append("c\(index)_ch=\(specParts[2])") }
            if let params = fmtpParams[pt] {
                for rawParam in params.split(separator: ";") {
                    let kv = rawParam.split(separator: "=", maxSplits: 1)
                    guard kv.count == 2 else { continue }
                    let key = String(kv[0]).trimmingCharacters(in: .whitespaces)
                    let value = String(kv[1]).trimmingCharacters(in: .whitespaces)
                    // Numeric-only: a bare number is unconditionally a
                    // protected "num" token regardless of key name, which is
                    // what keeps this loop shippable for an fmtp param key
                    // this file has never seen before. A non-numeric value
                    // (e.g. free-form future params) is dropped rather than
                    // risk the line, matching this app's own
                    // AudioSdpPolicy fmtp params, which are all numeric.
                    guard !key.isEmpty, value.allSatisfy(\.isNumber), !value.isEmpty else { continue }
                    parts.append("c\(index)_\(key)=\(value)")
                }
            }
        }
        for (index, extmap) in extmaps.enumerated() {
            // Key ends in "type" for the same reason as the codec name
            // above, and uses the same "e<N>_" underscore-separated shape
            // as the codec keys (see the c<N>_type comment above for why).
            // lowerCamel-ize a hyphenated uri suffix ("ssrc-audio-level" ->
            // "ssrcAudioLevel") so it matches the shipper's lowerCamel value
            // shape; a single-word suffix ("mid") already matches its plain
            // lower-word shape as-is.
            parts.append("e\(index)_type=\(lowerCamelize(extmap.uri))")
        }
        if let setupRole {
            // Key is "role", not "setup": "role" is on the shipper's
            // closed enum-key list, "setup" is not, for the identical
            // open-vocabulary-word value (actpass/active/passive).
            parts.append("role=\(setupRole)")
        }
        if let direction { parts.append("dir=\(direction)") }
        guard !parts.isEmpty else { return nil }
        return "audio " + parts.joined(separator: " ")
    }

    /// "ssrc-audio-level" -> "ssrcAudioLevel". A uri suffix with no '-'
    /// (e.g. "mid") is returned unchanged.
    private static func lowerCamelize(_ s: String) -> String {
        let segments = s.split(separator: "-").map(String.init)
        guard let first = segments.first else { return s }
        let rest = segments.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return ([first] + rest).joined()
    }
}
