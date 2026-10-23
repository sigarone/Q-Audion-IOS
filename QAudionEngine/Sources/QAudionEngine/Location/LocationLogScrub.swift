import Foundation

// The coordinate rule of every log redactor (WIRE_SPEC section 14.10). No log line, telemetry event, crash report or diagnostic contains a
// position, an accuracy, an `age`, a `sid`, a `k`, a body, a frame, a `geo:` URI, a map link or a GPX path with content: the location code
// never logs them, and this scrub removes positions that reach a redactor through another code path.
//
// The shapes (the same, with the same patterns, in the Python parity port and in the log shipper script):
//  1. a whole location body (`{"qa_loc":` up to the end of the object);
//  2. a `geo:` URI;
//  3. a link to a map service (Apple Maps, Google Maps) with whatever follows it;
//  4. the key-value forms of `lat`, `lon`, `lng`, `latitude`, `longitude`, `acc`, `accuracy` with any number (decimal degrees, E7 integers,
//     a quoted value, a JSON member, an XML attribute); a latency such as `lat=12ms` is not a position and stays;
//  5. `ll=`, `sll=`, `q=`, `daddr=`, `saddr=`, `destination=`, `query=`, `center=` with a numeric pair;
//  6. a pair of decimal numbers with three or more decimals separated by `,`, `;`, `%2C` or a space;
//  7. a share id or a share key written with its member name (`sid=`, `k=`, `share_key=`).
//
// Over-redaction is the safe failure mode here. The `redaction_cases` of the vector file pin the shapes: for each, the listed substrings
// must not survive, whatever placeholder the redactor writes in their place.

public enum LocationLogScrub {

    /// The default placeholder; a redactor passes its own.
    public static let defaultPlaceholder = "[REDACTED:loc]"

    // swiftlint:disable line_length
    private static let patterns: [String] = [
        // 1. a whole body: from the prefix to the closing brace (a body has no nested object), or to the end of the text
        #"\{\s*\\?"qa_loc\\?"\s*:[^}]*\}?"#,
        // 2. a geo: URI
        #"(?i)\bgeo:[^\s"'<>]*"#,
        // 3. a link to a map service
        #"(?i)https?://(?:[a-z0-9-]+\.)*(?:maps\.apple\.com|google\.[a-z.]+/maps|maps\.google\.[a-z.]+|goo\.gl/maps|maps\.app\.goo\.gl)[^\s"'<>]*"#,
        // 4. key-value forms of the position keys (a number that is a latency in milliseconds is left alone)
        #"(?i)["']?\b(?:lat|lon|lng|latitude|longitude|acc|accuracy)\b["']?\s*[:=]\s*["']?[-+]?\d+(?:\.\d+)?(?![\d.])(?!\s?ms\b)["']?"#,
        // 5. map query keys with a numeric pair
        #"(?i)\b(?:ll|sll|q|daddr|saddr|destination|query|center)\s*=\s*[-+]?\d+(?:\.\d+)?\s*(?:,|;|%2[Cc])\s*[-+]?\d+(?:\.\d+)?"#,
        // 6. a pair of decimals
        #"(?<![\d.])[-+]?\d{1,3}\.\d{3,}(?:\s*[,;]\s*|\s*%2[Cc]\s*|\s+)[-+]?\d{1,3}\.\d{3,}(?!\d)"#,
        // 7. a share id or a share key with its member name
        #"(?i)["']?\b(?:sid|k|share[_-]?key|share[_-]?id)\b["']?\s*[:=]\s*["']?[A-Za-z0-9+/_-]{20,}={0,2}["']?"#
    ]
    // swiftlint:enable line_length

    // Patterns are compile-time constants; force-try is safe, and a test pins that every one of them compiles.
    static let expressions: [NSRegularExpression] = patterns.map { try! NSRegularExpression(pattern: $0) }

    /// `text` with every position shape replaced by `placeholder`. Pure, thread-safe, linear in the length of `text`. Every shape but the
    /// last holds a digit (or the prefix of a body, which always carries one), so a text without a digit skips them; the share id and key
    /// rule always runs (a base64 text can have no digit).
    public static func scrub(_ text: String, placeholder: String = defaultPlaceholder) -> String {
        let hasDigit: Bool = text.utf8.contains(where: { $0 >= 0x30 && $0 <= 0x39 })
        let template = NSRegularExpression.escapedTemplate(for: placeholder)
        var working = text
        for (index, expression) in expressions.enumerated() {
            if !hasDigit && index != expressions.count - 1 { continue }
            let range = NSRange(working.startIndex..<working.endIndex, in: working)
            working = expression.stringByReplacingMatches(in: working, options: [], range: range, withTemplate: template)
        }
        return working
    }

    /// The patterns, for the tests that pin them against the Python port and the shipper script.
    static var patternSources: [String] { patterns }
}
