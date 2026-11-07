import Foundation

/// Formats the thread list of an `MXCrashDiagnostic.callStackTree` (already decoded from its JSON) into short
/// log lines, so a crash can be triaged even when the thread MetricKit attributed is not the one that crashed.
///
/// Every line is plain ASCII and built to survive the on-device log redactor (`LogRedactor.redact` and
/// `redactStructured`): no run of 24 or more characters from `[A-Za-z0-9+/=_-]` (the binary UUID is written with
/// dots between its groups, 8.4.4.4.12, never as one dashed run), no comma-separated number lists, one number per
/// token, binary names cut to 18 characters. To read a `uuid=` value back, replace the dots with dashes.
///
/// Frame numbering: `f0` is the innermost frame (where the thread was when it crashed or was sampled), `f1` its
/// caller, and so on. MetricKit lists a stack outermost first; this walks the chain to its leaf and prints the last
/// `maxFramesPerThread` frames in reverse.
public enum MetricKitCrashStackFormatter {

    public static let maxThreads = 6
    public static let maxFramesPerThread = 12
    public static let maxBinaryNameLength = 18
    public static let prefix = "[MetricKit] "

    public static func lines(from root: [String: Any],
                             maxThreads: Int = MetricKitCrashStackFormatter.maxThreads,
                             maxFrames: Int = MetricKitCrashStackFormatter.maxFramesPerThread) -> [String] {
        guard let stacks = root["callStacks"] as? [[String: Any]], !stacks.isEmpty else { return [] }
        var attributed: [Int] = []
        for (i, s) in stacks.enumerated() where (s["threadAttributed"] as? Bool) == true {
            attributed.append(i)
        }
        let chosen: Int = attributed.first ?? 0
        let pick: String = attributed.isEmpty ? "first" : "attributed"

        // The chosen thread first, then the rest by index, capped.
        var order: [Int] = [chosen]
        for i in stacks.indices where i != chosen { order.append(i) }
        let shown: [Int] = Array(order.prefix(max(maxThreads, 1)))

        var perThread: [ThreadFrames] = []
        for i in shown {
            let roots = (stacks[i]["callStackRootFrames"] as? [[String: Any]]) ?? []
            let chain = flatten(roots)
            let top: [[String: Any]] = Array(chain.suffix(max(maxFrames, 0)).reversed())
            let isAttributed = (stacks[i]["threadAttributed"] as? Bool) == true
            let frames: [Frame] = top.map { frame(from: $0) }
            perThread.append(ThreadFrames(index: i, attributed: isAttributed, total: chain.count, frames: frames))
        }

        var out: [String] = []
        var head: String = prefix
        head += "crash threads total=" + String(stacks.count)
        head += " attributed=" + (attributed.first.map { String($0) } ?? "none")
        head += " attributed_count=" + String(attributed.count)
        head += " chosen=" + String(chosen)
        head += " pick=" + pick
        head += " shown=" + String(shown.count)
        out.append(head)

        // One line per binary (name + UUID), in order of first use.
        var seen = Set<String>()
        for t in perThread {
            for f in t.frames {
                let key = f.name + "|" + f.uuid
                if seen.contains(key) { continue }
                seen.insert(key)
                var line: String = prefix
                line += "bin " + f.name + " uuid=" + f.uuid
                out.append(line)
            }
        }

        for t in perThread {
            var line: String = prefix
            line += "thread " + String(t.index)
            line += " attr=" + (t.attributed ? "1" : "0")
            line += " frames=" + String(t.total)
            line += " shown=" + String(t.frames.count)
            out.append(line)
            for (j, f) in t.frames.enumerated() {
                var fl: String = prefix
                fl += "t" + String(t.index) + " f" + String(j) + " " + f.name
                fl += " + " + String(f.offset)
                out.append(fl)
            }
        }
        return out
    }

    struct Frame: Equatable {
        let name: String
        let offset: Int
        let uuid: String
    }

    struct ThreadFrames {
        let index: Int
        let attributed: Bool
        let total: Int
        let frames: [Frame]
    }

    /// The path from the first root frame to the first leaf, following the first child at every level. A crash
    /// diagnostic carries one linear chain per thread; a branching tree (not expected) is read along its first branch.
    static func flatten(_ roots: [[String: Any]]) -> [[String: Any]] {
        var chain: [[String: Any]] = []
        var level = roots
        while let first = level.first, chain.count < 4096 {
            chain.append(first)
            level = (first["subFrames"] as? [[String: Any]]) ?? []
        }
        return chain
    }

    static func frame(from f: [String: Any]) -> Frame {
        let name: String = (f["binaryName"] as? String).map { cleanBinaryName($0) } ?? "?"
        let offset = (f["offsetIntoBinaryTextSegment"] as? Int) ?? -1
        let uuid = dottedUUID((f["binaryUUID"] as? String) ?? "")
        return Frame(name: name, offset: offset, uuid: uuid)
    }

    /// Letters, digits, `_` and `-` only, `.dylib` / `.framework` dropped, cut to `maxBinaryNameLength`;
    /// `?` when nothing is left.
    static func cleanBinaryName(_ raw: String) -> String {
        var s = raw
        for suffix in [".dylib", ".framework"] where s.hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count))
        }
        var out = ""
        for ch in s.unicodeScalars {
            let v = ch.value
            let ok = (v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) || v == 0x5F || v == 0x2D
            out.append(ok ? Character(ch) : "_")
            if out.count >= maxBinaryNameLength { break }
        }
        return out.isEmpty ? "?" : out
    }

    /// `8.4.4.4.12` hex groups from a UUID string in any common spelling; `?` when it does not hold 32 hex digits.
    static func dottedUUID(_ raw: String) -> String {
        var hex: [Character] = []
        for ch in raw where ch.isHexDigit { hex.append(ch) }
        guard hex.count == 32 else { return "?" }
        let groups = [8, 4, 4, 4, 12]
        var parts: [String] = []
        var at = 0
        for g in groups {
            parts.append(String(hex[at..<(at + g)]).uppercased())
            at += g
        }
        return parts.joined(separator: ".")
    }
}
