import Foundation

/// An extension number and password read from a photo, a file or a pasted note.
/// Only ever used to fill the two fields of the sign-in screen.
struct ExtractedCredentials: Equatable {
    let extensionNumber: String
    let password: String
    /// 1-based positions in `password` of characters that cannot be in a generated password
    /// (the recognizer may have confused 0/O, 1/I/L). Empty unless a generated-looking password was read.
    var uncertainPositions: [Int] = []
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
            return makeCredentials(extensionNumber: e, password: p)
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
            if let e = ext, let p = pwd { return makeCredentials(extensionNumber: e, password: p) }
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
        return makeCredentials(extensionNumber: e, password: p)
    }

    // MARK: - Generated passwords read by OCR

    /// Alphabet of server-generated passwords (server internal/store/generated_password.go).
    private static let generatedAlphabet = Set("23456789ABCDEFGHJKMNPQRSTUVWXYZ")
    private static let generatedLength = 20
    private static let generatedGroup = 4
    private static let generatedMinInAlphabet = 17

    /// Greek and Cyrillic letters drawn like an ASCII letter. Only unambiguous look-alikes:
    /// Greek nu and upsilon in lowercase are left out (they read as v, not n or y).
    private static let lookAlikes: [Character: Character] = {
        var m: [Character: Character] = [:]
        let pairs: [(String, String)] = [
            ("ΑΒΕΖΗΙΚΜΝΟΡΤΥΧ", "ABEZHIKMNOPTYX"),
            ("αικορχ", "aikopx"),
            ("АВЕКМНОРСТХУ", "ABEKMHOPCTXY"),
            ("аекмнорстху", "aekmhopctxy"),
        ]
        for (from, to) in pairs { for (a, b) in zip(from, to) { m[a] = b } }
        return m
    }()

    /// Full-width forms (U+FF01...U+FF5E) and the look-alikes above, as ASCII; anything else unchanged.
    private static func asciiLookAlike(_ ch: Character) -> Character {
        if let m = lookAlikes[ch] { return m }
        if ch.unicodeScalars.count == 1, let u = ch.unicodeScalars.first, (0xFF01...0xFF5E).contains(u.value),
           let a = Unicode.Scalar(u.value - 0xFEE0) {
            return Character(a)
        }
        return ch
    }

    private static func isAsciiAlnum(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber)
    }

    /// Recognizes a password of the generated shape and cleans up what the text recognizer got wrong.
    /// The text is never upper-cased and no separator is added or removed (the server accepts the generated
    /// password in any case, with or without dashes): only full-width and Greek/Cyrillic look-alikes become ASCII.
    /// Applies only to the generated DISPLAY shape (5 groups of 4 joined by "-"; the server refuses user-chosen
    /// passwords of that shape, so it is a reliable signal) or to a 20-character token that is already all
    /// upper case with at least 17 characters in the generated alphabet. Characters outside the alphabet
    /// (0, O, 1, I, L) are kept as read and reported by 1-based position among the 20 characters (dashes not
    /// counted). Anything else (old hex passwords, free-form passwords of any length) returns `nil`.
    static func normalizeGenerated(_ raw: String) -> (password: String, uncertain: [Int])? {
        let mapped = raw.map(asciiLookAlike)
        let groups = String(mapped).split(separator: "-", omittingEmptySubsequences: false)
        let dashed = groups.count == generatedLength / generatedGroup
            && groups.allSatisfy { $0.count == generatedGroup }
        let chars = mapped.filter { $0 != "-" }
        guard chars.count == generatedLength, chars.allSatisfy(isAsciiAlnum) else { return nil }
        if !dashed {
            guard mapped.count == generatedLength,
                  !chars.contains(where: { $0.isLowercase }),
                  chars.filter({ generatedAlphabet.contains($0) }).count >= generatedMinInAlphabet
            else { return nil }
        }
        let bad = chars.enumerated()
            .filter { !generatedAlphabet.contains(Character($0.element.uppercased())) }
            .map { $0.offset + 1 }
        return (String(mapped), bad)
    }

    private static func makeCredentials(extensionNumber: String, password: String) -> ExtractedCredentials {
        if let g = normalizeGenerated(password) {
            return ExtractedCredentials(extensionNumber: extensionNumber, password: g.password, uncertainPositions: g.uncertain)
        }
        return ExtractedCredentials(extensionNumber: extensionNumber, password: password)
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
