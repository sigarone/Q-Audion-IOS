import Foundation

/// A text split into user-perceived units. In Swift a `Character` is an extended grapheme cluster, so an emoji with
/// modifiers and joiners, a flag (pair of regional indicators), a base letter with its combining marks and CR LF are one
/// unit each, and right-to-left text is never cut inside a cluster. Only the first `count` units (at most `maxUnits`) are
/// animated; whatever follows is `rest` and is shown unchanged.
///
/// Appending a unit copies a Character into the frame string, so rendering a frame creates no object per character.
public struct EnigmaUnits {
    public static let maxUnits: Int = 240

    public static let empty = EnigmaUnits(units: [], rest: "")

    private let units: [Character]
    /// The text after the animated head, unchanged.
    public let rest: String

    public var count: Int { units.count }

    /// The animated head as one string.
    public var head: String { String(units) }

    private init(units: [Character], rest: String) {
        self.units = units
        self.rest = rest
    }

    public init(text: String, maxUnits: Int = EnigmaUnits.maxUnits) {
        if text.isEmpty {
            self.units = []
            self.rest = ""
            return
        }
        let cap = max(0, maxUnits)
        var collected: [Character] = []
        collected.reserveCapacity(min(cap, 256))
        var index = text.startIndex
        while index < text.endIndex && collected.count < cap {
            collected.append(text[index])
            index = text.index(after: index)
        }
        self.units = collected
        self.rest = index < text.endIndex ? String(text[index...]) : ""
    }

    /// Appends unit `index` to `out`; an index outside the head appends nothing (never traps).
    public func append(to out: inout String, index: Int) {
        if index >= 0 && index < units.count { out.append(units[index]) }
    }
}
