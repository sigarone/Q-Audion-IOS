import Foundation

/// "What's new" data. The list is built at release time by scripts/gen_ios_changelog.py from the
/// release tags and the curated notes (Resources/ReleaseNotes/release-notes.json) and embedded as
/// Resources/changelog.json. Commit and pull request titles are never shown.
enum ChangelogStore {
    private struct Entry: Decodable {
        let version: String
        let date: String
        let notes: [String: [String]]
    }

    /// Shown for a release that has no curated entry.
    static let generic: [String: [String]] = [
        "it": ["Miglioramenti di qualità e affidabilità"],
        "en": ["Quality and reliability improvements"],
        "de": ["Verbesserungen bei Qualität und Zuverlässigkeit"],
        "es": ["Mejoras de calidad y fiabilidad"],
        "fr": ["Améliorations de la qualité et de la fiabilité"],
        "pt-BR": ["Melhorias de qualidade e confiabilidade"],
    ]

    /// Releases to show, newest first, the running version leading the list.
    static func notes(bundle: Bundle = .main) -> [ReleaseNote] {
        var data: Data?
        if let url = bundle.url(forResource: "changelog", withExtension: "json") {
            data = try? Data(contentsOf: url)
        }
        return notes(from: data, currentVersion: AppVersionInfo.marketing(bundle: bundle),
                     languages: bundle.preferredLocalizations)
    }

    static func notes(from data: Data?, currentVersion: String, languages: [String]) -> [ReleaseNote] {
        var list: [ReleaseNote] = []
        if let data, let entries = try? JSONDecoder().decode([Entry].self, from: data) {
            list = entries.map {
                ReleaseNote(id: "v" + $0.version, date: $0.date, title: "",
                            bullets: lines($0.notes, languages: languages))
            }
        }
        let current = "v" + currentVersion
        let placeholder = ReleaseNote(id: current, date: "", title: "",
                                      bullets: lines(generic, languages: languages))
        if !list.contains(where: { $0.id == current }), currentVersion != "?" {
            if let top = list.first {
                if compare(currentVersion, String(top.id.dropFirst())) == .orderedDescending {
                    list.insert(placeholder, at: 0)
                }
            } else {
                list = [placeholder]
            }
        }
        return list
    }

    /// The lines in the first matching language, falling back to English.
    static func lines(_ byLanguage: [String: [String]], languages: [String]) -> [String] {
        for code in languages {
            if let hit = byLanguage[code] { return hit }
            if let base = code.split(separator: "-").first, let hit = byLanguage[String(base)] { return hit }
        }
        return byLanguage["en"] ?? []
    }

    /// Numeric dotted-version comparison ("1.0.1279" > "1.0.998").
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
