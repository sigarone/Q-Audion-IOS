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
    /// line when absent from the section. Format:
    /// `"audio codecs=<pt>:<name>/<clock>[/<ch>][;fmtp=<params>],... extmap=<id>:<uri>,... setup=<role> dir=<direction>"`
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
                let uri = afterId.split(separator: " ").first.map(String.init) ?? ""
                guard !idPart.isEmpty, !uri.isEmpty else { continue }
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
        if !codecOrder.isEmpty {
            let codecsText = codecOrder.map { pt -> String in
                var text = "\(pt):\(codecSpec[pt] ?? "")"
                if let params = fmtpParams[pt], !params.isEmpty {
                    text += ";fmtp=\(params)"
                }
                return text
            }.joined(separator: ",")
            parts.append("codecs=\(codecsText)")
        }
        if !extmaps.isEmpty {
            let extmapText = extmaps.map { "\($0.id):\($0.uri)" }.joined(separator: ",")
            parts.append("extmap=\(extmapText)")
        }
        if let setupRole { parts.append("setup=\(setupRole)") }
        if let direction { parts.append("dir=\(direction)") }
        guard !parts.isEmpty else { return nil }
        return "audio " + parts.joined(separator: " ")
    }
}
