import Foundation

/// An extension number and password read from a photo, a file or a pasted note.
/// Only ever used to fill the two fields of the sign-in screen.
struct ExtractedCredentials: Equatable {
    let extensionNumber: String
    let password: String
}

enum CredentialExtraction: Equatable {
    case found(ExtractedCredentials)
    /// The structured payload named a server that is not the pinned one; nothing is filled.
    case notPinned(server: String)
    case notFound
}

/// Pure parsing of the text (or structured payload) that carries sign-in values.
/// No I/O, no logging: the values never leave the caller.
enum CredentialTextParser {

    // MARK: - Structured payload

    /// Reads the JSON payload some administrator tools produce.
    /// Returns `nil` when `raw` is not that payload, so the caller can go on with plain text.
    static func fromStructuredPayload(_ raw: String,
                                      serverAccepted: (String) -> Bool) -> CredentialExtraction? {
        guard let payload = try? FastSetupPayload.decode(jsonString: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        guard serverAccepted(payload.server) else {
            return .notPinned(server: payload.server)
        }
        guard payload.extensionNumber > 0, !payload.password.isEmpty else { return .notFound }
        return .found(ExtractedCredentials(extensionNumber: String(payload.extensionNumber),
                                           password: payload.password))
    }

    // MARK: - Plain text

    private static let extensionLabels = ["interno", "estensione", "extension", "username", "utente", "user", "ext"]
    private static let passwordLabels = ["password", "passw", "pwd", "pass"]

    private static let labelRegex: NSRegularExpression = {
        let all = (extensionLabels + passwordLabels).sorted { $0.count > $1.count }
        let pattern = "(?<![\\p{L}\\p{N}])(" + all.joined(separator: "|") + ")(?![\\p{L}\\p{N}])[ \\t]*[:=]?"
        // The pattern is a constant; it always compiles.
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private enum Field { case ext, pwd }

    private struct LabelHit {
        let field: Field
        let range: NSRange
    }

    private static func hits(in line: String) -> [LabelHit] {
        let ns = line as NSString
        return labelRegex.matches(in: line, range: NSRange(location: 0, length: ns.length)).map { m in
            let word = ns.substring(with: m.range(at: 1)).lowercased()
            return LabelHit(field: extensionLabels.contains(word) ? .ext : .pwd, range: m.range)
        }
    }

    private static func digits(in value: String) -> String? {
        value.split(whereSeparator: { !$0.isNumber }).first(where: { (1...9).contains($0.count) }).map(String.init)
    }

    private static func isDigitsToken(_ token: String, lengths: ClosedRange<Int>) -> Bool {
        lengths.contains(token.count) && token.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func cleanToken(_ token: String) -> String {
        token.trimmingCharacters(in: CharacterSet(charactersIn: ":=;,\"'`()[]"))
    }

    /// Reads an extension and a password from free text (typed or handwritten, as recognized on a photo).
    /// Labelled values win ("interno", "extension", "ext", "utente", "user", "username" and "password", "pwd",
    /// "pass"; separator ":" or "=" or the next line). Without labels the first 2-6 digit token is the
    /// extension and the next token is the password. Returns `nil` unless both are found.
    static func fromText(_ text: String) -> ExtractedCredentials? {
        let lines = text.replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var ext: String?
        var pwd: String?
        var pending: Field?

        for line in lines {
            let found = hits(in: line)
            if found.isEmpty {
                if let field = pending {
                    assign(field, value: line, ext: &ext, pwd: &pwd)
                    pending = nil
                }
                continue
            }
            // A value waiting from the previous line takes the whole line unless the line starts with a label
            // (a password may itself contain a word like "pass").
            if let field = pending, found[0].range.location > 0 {
                assign(field, value: line, ext: &ext, pwd: &pwd)
                pending = nil
                continue
            }
            let ns = line as NSString
            pending = nil
            for (i, hit) in found.enumerated() {
                let start = hit.range.location + hit.range.length
                let end = i + 1 < found.count ? found[i + 1].range.location : ns.length
                let value = ns.substring(with: NSRange(location: start, length: max(0, end - start)))
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \t:="))
                if value.isEmpty {
                    pending = hit.field
                } else {
                    assign(hit.field, value: value, ext: &ext, pwd: &pwd)
                    pending = nil
                }
            }
        }

        if let e = ext, let p = pwd {
            return ExtractedCredentials(extensionNumber: e, password: p)
        }

        // Fallback on the token stream with the label words removed.
        var tokens: [String] = []
        for line in lines {
            var rest = line
            for hit in hits(in: line).reversed() {
                rest = (rest as NSString).replacingCharacters(in: hit.range, with: " ")
            }
            tokens += rest.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { cleanToken(String($0)) }.filter { !$0.isEmpty }
        }
        let extIndex: Int?
        if let e = ext {
            extIndex = tokens.firstIndex(of: e)
        } else {
            extIndex = tokens.firstIndex(where: { isDigitsToken($0, lengths: 2...6) })
        }
        guard let idx = extIndex else {
            if let e = ext, let p = pwd { return ExtractedCredentials(extensionNumber: e, password: p) }
            return nil
        }
        let e = ext ?? tokens[idx]
        let p: String
        if let known = pwd {
            p = known
        } else if idx + 1 < tokens.count {
            p = tokens[idx + 1]
        } else {
            return nil
        }
        return ExtractedCredentials(extensionNumber: e, password: p)
    }

    private static func assign(_ field: Field, value: String, ext: inout String?, pwd: inout String?) {
        switch field {
        case .ext:
            if ext == nil, let d = digits(in: value) { ext = d }
        case .pwd:
            let v = value.trimmingCharacters(in: .whitespaces)
            if pwd == nil, !v.isEmpty { pwd = v }
        }
    }

    // MARK: - Everything found in one image or file

    /// Tries each structured payload first, then the recognized/plain text.
    static func extract(structuredPayloads: [String],
                        text: String,
                        serverAccepted: (String) -> Bool) -> CredentialExtraction {
        for raw in structuredPayloads {
            if let result = fromStructuredPayload(raw, serverAccepted: serverAccepted) {
                return result
            }
        }
        if let result = fromStructuredPayload(text, serverAccepted: serverAccepted) {
            return result
        }
        if let creds = fromText(text) {
            return .found(creds)
        }
        return .notFound
    }
}
