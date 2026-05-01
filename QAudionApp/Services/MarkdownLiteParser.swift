import Foundation
import SwiftUI

/// W148/W149/W127/W152 — markdown-lite + URL-detection helper.
///
/// Extracted from `ChatDetailScreen.swift` so the heavy AttributedString
/// + NSDataDetector work doesn't bloat the chat detail file's
/// type-check budget. Unit-of-isolation: a single static function on
/// an enum so callers can use `MarkdownLiteParser.attributedBody(...)`
/// without instantiating anything.
///
/// Recognised tokens:
///   - `` `code` `` → monospaced font
///   - `**bold**`   → strong emphasis
///   - `*italic*`   → italic
///   - `http(s)://…` URLs → tappable link with `linkColor` underline
///
/// The `qaudion.privacy.detect_links` AppStorage key gates URL
/// detection (W152). When off, links pass through as plain text.
enum MarkdownLiteParser {

    /// Build a styled AttributedString from raw plaintext. Returns the
    /// raw text wrapped as AttributedString on any internal failure.
    static func attributedBody(_ raw: String, linkColor: Color) -> AttributedString {
        let parsed = parseMarkdownLite(raw)
        var attr = AttributedString(parsed.cleaned)
        for r in parsed.code {
            guard let attrRange = Range(NSRange(location: r.lowerBound, length: r.count),
                                        in: attr) else { continue }
            attr[attrRange].font = .system(.body, design: .monospaced)
        }
        for r in parsed.bold {
            guard let attrRange = Range(NSRange(location: r.lowerBound, length: r.count),
                                        in: attr) else { continue }
            attr[attrRange].inlinePresentationIntent = .stronglyEmphasized
        }
        for r in parsed.italic {
            guard let attrRange = Range(NSRange(location: r.lowerBound, length: r.count),
                                        in: attr) else { continue }
            attr[attrRange].inlinePresentationIntent = .emphasized
        }
        // W152: privacy gate — skip URL auto-detection when the user
        // has flipped 'Anteprima link' off.
        let detectKey = "qaudion.privacy.detect_links"
        let detectFlagPresent = UserDefaults.standard.object(forKey: detectKey) != nil
        let detectEnabled = !detectFlagPresent || UserDefaults.standard.bool(forKey: detectKey)
        guard detectEnabled else { return attr }
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else { return attr }
        let ns = parsed.cleaned as NSString
        let matches = detector.matches(in: parsed.cleaned, options: [],
                                       range: NSRange(location: 0, length: ns.length))
        for match in matches {
            guard let url = match.url,
                  let attrRange = Range(match.range, in: attr) else { continue }
            attr[attrRange].link = url
            attr[attrRange].foregroundColor = linkColor
            attr[attrRange].underlineStyle = .single
        }
        return attr
    }

    private struct ParsedMarkdownLite {
        let cleaned: String
        let code: [Range<Int>]
        let bold: [Range<Int>]
        let italic: [Range<Int>]
    }

    /// Single-pass parser that strips `code`, **bold**, *italic* markers
    /// and records utf16 offsets in the cleaned text for each style.
    private static func parseMarkdownLite(_ raw: String) -> ParsedMarkdownLite {
        var cleaned = ""
        var code: [Range<Int>] = []
        var bold: [Range<Int>] = []
        var italic: [Range<Int>] = []
        var i = raw.startIndex
        while i < raw.endIndex {
            if raw[i] == "`" {
                let afterOpen = raw.index(after: i)
                if let close = raw[afterOpen...].firstIndex(of: "`"),
                   close != afterOpen {
                    let inner = String(raw[afterOpen..<close])
                    let start = cleaned.utf16.count
                    cleaned += inner
                    let end = cleaned.utf16.count
                    code.append(start..<end)
                    i = raw.index(after: close)
                    continue
                }
            }
            if raw[i] == "*" {
                let nextIdx = raw.index(after: i)
                if nextIdx < raw.endIndex && raw[nextIdx] == "*" {
                    let afterOpen = raw.index(after: nextIdx)
                    if let close = raw.range(of: "**", range: afterOpen..<raw.endIndex)?.lowerBound,
                       close != afterOpen {
                        let inner = String(raw[afterOpen..<close])
                        let start = cleaned.utf16.count
                        cleaned += inner
                        let end = cleaned.utf16.count
                        bold.append(start..<end)
                        i = raw.index(close, offsetBy: 2)
                        continue
                    }
                } else {
                    let afterOpen = nextIdx
                    if let close = raw[afterOpen...].firstIndex(of: "*"),
                       close != afterOpen {
                        let inner = String(raw[afterOpen..<close])
                        let start = cleaned.utf16.count
                        cleaned += inner
                        let end = cleaned.utf16.count
                        italic.append(start..<end)
                        i = raw.index(after: close)
                        continue
                    }
                }
            }
            cleaned.append(raw[i])
            i = raw.index(after: i)
        }
        return ParsedMarkdownLite(cleaned: cleaned, code: code, bold: bold, italic: italic)
    }
}
