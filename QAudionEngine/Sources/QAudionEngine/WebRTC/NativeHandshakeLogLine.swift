import Foundation

/// The native DTLS handshake self-report line of the WebRTC build
/// (`OpenSSLStreamAdapter`): `Q-AUDION dtls v=%04x cipher=%04x srtp=%04x group=%04x level=%d pqc_req=%d ok=%d`.
/// On a non-Android build the logging callback delivers it behind a `(file.cc:NNNN): ` source prefix.
///
/// Peer-controlled text reaches other native log lines, so a line is accepted only if it is exactly this shape
/// (every field hex or decimal, nothing after it) and, when a source prefix is present, it names the one file
/// that prints it. The accepted line is returned without the prefix.
enum NativeHandshakeLogLine {

    private static let sourceFile = "openssl_stream_adapter.cc"

    private static let sourcePrefix: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^\(([A-Za-z0-9_./-]+):[0-9]{1,6}\): "#)

    private static let bodyShape: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^Q-AUDION dtls v=[0-9a-f]{4} cipher=[0-9a-f]{4} srtp=[0-9a-f]{4} group=[0-9a-f]{4} "#
            + #"level=-?[0-9]{1,2} pqc_req=[01] ok=[01]$"#)

    static func normalized(_ message: String) -> String? {
        var line = message
        // Dropped on the scalar view: "\r\n" is a single Character, so hasSuffix/removeLast(2) misjudge it.
        var scalars = line.unicodeScalars
        if scalars.last == "\n" {
            scalars.removeLast()
            if scalars.last == "\r" { scalars.removeLast() }
            line = String(scalars)
        }
        guard line.utf16.count <= 160, let sourcePrefix, let bodyShape else { return nil }
        var rest = Substring(line)
        let whole = NSRange(location: 0, length: line.utf16.count)
        if let m = sourcePrefix.firstMatch(in: line, options: [], range: whole),
           let fileRange = Range(m.range(at: 1), in: line),
           let all = Range(m.range, in: line) {
            let file = line[fileRange]
            guard file == sourceFile || file.hasSuffix("/" + sourceFile) else { return nil }
            rest = line[all.upperBound...]
        }
        let restString = String(rest)
        let restRange = NSRange(location: 0, length: restString.utf16.count)
        guard let hit = bodyShape.firstMatch(in: restString, options: [], range: restRange),
              hit.range == restRange else { return nil }
        return restString
    }
}
