import Foundation

/// One block of the Terms as the screens draw it.
public struct LegalMarkdownBlock: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case heading(level: Int)
        case paragraph
    }

    public let kind: Kind
    public let text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// Splits `body_markdown` into headings and paragraphs. Nothing more is interpreted here: inline markup (emphasis,
/// links) is left to the view, and the words are never changed, so what the person reads is the published text.
public enum LegalMarkdown {
    public static func blocks(from markdown: String) -> [LegalMarkdownBlock] {
        var result: [LegalMarkdownBlock] = []
        var paragraph: [String] = []

        func flush() {
            guard !paragraph.isEmpty else { return }
            result.append(LegalMarkdownBlock(kind: .paragraph, text: paragraph.joined(separator: "\n")))
            paragraph.removeAll()
        }

        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flush()
                continue
            }
            if let heading = heading(in: trimmed) {
                flush()
                result.append(heading)
                continue
            }
            paragraph.append(line)
        }
        flush()
        return result
    }

    private static func heading(in line: String) -> LegalMarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return LegalMarkdownBlock(kind: .heading(level: hashes.count), text: text)
    }
}
