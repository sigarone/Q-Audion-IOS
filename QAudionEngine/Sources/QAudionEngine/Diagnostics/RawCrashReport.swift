import Foundation

/// The raw crash record the app's signal handler writes (`CrashReporter`, QAudionApp), and its reader.
///
/// The handler is async-signal-safe: it only copies bytes into a buffer allocated at launch and calls `write(2)`. So
/// the record is a few plain lines, no symbol names, and the next launch turns it into the text the log pipeline and
/// the `app.crash` telemetry already consume. Format, one item per line:
///
///   QACRASH1
///   ver=<app version>
///   img=<main binary name> uuid=<8.4.4.4.12 hex> load=0x<hex> size=0x<hex>
///   sig=<signal number>
///   ts=<unix seconds>
///   main=<1 when the main thread crashed, else 0>
///   bt=<number of addresses>
///   0x<16 hex digits>            (one line per address, innermost first)
///   fatal=<Swift runtime message, optional, ASCII only>
///
/// `load` is the runtime address of the main binary's Mach-O header, `size` the length of its `__TEXT` segment. A
/// frame inside `[load, load + size)` is printed as `<name> + <offset>` with `offset = address - load`, the shape
/// `scripts/symbolicate.py` resolves against the dSYM of that build (the UUID names the build). Any other frame is
/// printed with its raw address only.
public struct RawCrashReport: Equatable {

    public static let magic = "QACRASH1"
    public static let maxAddresses = 64

    public var appVersion: String
    public var imageName: String
    public var imageUUID: String
    public var loadAddress: UInt64
    public var textSize: UInt64
    public var signal: Int32
    public var timestampSec: Int64
    public var mainThread: Bool
    public var addresses: [UInt64]
    public var fatal: String

    public init(appVersion: String, imageName: String, imageUUID: String, loadAddress: UInt64, textSize: UInt64,
                signal: Int32, timestampSec: Int64, mainThread: Bool, addresses: [UInt64], fatal: String) {
        self.appVersion = appVersion
        self.imageName = imageName
        self.imageUUID = imageUUID
        self.loadAddress = loadAddress
        self.textSize = textSize
        self.signal = signal
        self.timestampSec = timestampSec
        self.mainThread = mainThread
        self.addresses = addresses
        self.fatal = fatal
    }

    // MARK: - Writer side (run at launch, not in the handler)

    /// The first three lines, built once at launch and copied into the handler's buffer.
    public static func preamble(appVersion: String, imageName: String, imageUUID: String,
                                loadAddress: UInt64, textSize: UInt64) -> String {
        var s = magic + "\n"
        s += "ver=" + sanitizeToken(appVersion, fallback: "0.0.0") + "\n"
        s += "img=" + sanitizeToken(imageName, fallback: "QAudionApp")
        s += " uuid=" + MetricKitCrashStackFormatter.dottedUUID(imageUUID)
        s += " load=0x" + hex16(loadAddress)
        s += " size=0x" + hex16(textSize) + "\n"
        return s
    }

    static func sanitizeToken(_ raw: String, fallback: String) -> String {
        var out = ""
        for ch in raw.unicodeScalars {
            let v = ch.value
            let ok = (v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A)
                || v == 0x5F || v == 0x2D || v == 0x2E
            if ok { out.append(Character(ch)) }
            if out.count >= 32 { break }
        }
        return out.isEmpty ? fallback : out
    }

    static func hex16(_ value: UInt64) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: max(0, 16 - digits.count)) + digits
    }

    // MARK: - Reader side

    /// nil unless `text` starts with the magic line and carries a `sig=` line. A record cut short by a handler that
    /// died halfway still parses with whatever was written before the cut.
    public static func parse(_ text: String) -> RawCrashReport? {
        let lines = text.components(separatedBy: "\n")
        guard lines.first == magic else { return nil }
        var r = RawCrashReport(appVersion: "0.0.0", imageName: "QAudionApp", imageUUID: "?", loadAddress: 0,
                               textSize: 0, signal: 0, timestampSec: 0, mainThread: false, addresses: [], fatal: "")
        var haveSignal = false
        for line in lines.dropFirst() {
            if line.hasPrefix("ver=") {
                r.appVersion = String(line.dropFirst(4))
            } else if line.hasPrefix("img=") {
                for token in line.dropFirst(4).split(separator: " ") {
                    if token.hasPrefix("uuid=") {
                        r.imageUUID = String(token.dropFirst(5))
                    } else if token.hasPrefix("load=0x") {
                        r.loadAddress = UInt64(token.dropFirst(7), radix: 16) ?? 0
                    } else if token.hasPrefix("size=0x") {
                        r.textSize = UInt64(token.dropFirst(7), radix: 16) ?? 0
                    } else if !token.contains("=") {
                        r.imageName = String(token)
                    }
                }
            } else if line.hasPrefix("sig=") {
                if let v = Int32(line.dropFirst(4)) {
                    r.signal = v
                    haveSignal = true
                }
            } else if line.hasPrefix("ts=") {
                r.timestampSec = Int64(line.dropFirst(3)) ?? 0
            } else if line.hasPrefix("main=") {
                r.mainThread = line.dropFirst(5) == "1"
            } else if line.hasPrefix("0x") {
                if r.addresses.count < maxAddresses, let a = UInt64(line.dropFirst(2), radix: 16) {
                    r.addresses.append(a)
                }
            } else if line.hasPrefix("fatal=") {
                r.fatal = String(line.dropFirst(6))
            }
        }
        return haveSignal ? r : nil
    }

    public static func signalName(_ sig: Int32) -> String {
        switch sig {
        case SIGABRT: return "SIGABRT"
        case SIGSEGV: return "SIGSEGV"
        case SIGBUS:  return "SIGBUS"
        case SIGILL:  return "SIGILL"
        case SIGFPE:  return "SIGFPE"
        case SIGTRAP: return "SIGTRAP"
        default:      return "SIG?"
        }
    }

    public func contains(_ address: UInt64) -> Bool {
        return textSize > 0 && address >= loadAddress && address - loadAddress < textSize
    }

    /// `<index>   <name>   0x<address> <name> + <offset>` for a frame inside the main binary (the shape
    /// `scripts/symbolicate.py` keys on), `<index>   ?   0x<address>` for any other.
    public func frameLines() -> [String] {
        var out: [String] = []
        for (i, a) in addresses.enumerated() {
            var line = String(i) + "   "
            if contains(a) {
                line += imageName + "   0x" + RawCrashReport.hex16(a)
                line += " " + imageName + " + " + String(a - loadAddress)
            } else {
                line += "?   0x" + RawCrashReport.hex16(a)
            }
            out.append(line)
        }
        return out
    }

    /// Lines for the log, ahead of the report text: build, when, which thread, and the binary identity. Spaces, not `=`,
    /// before the hex values, and no zero padding: `load=0x` plus 16 digits is a 20-character run the redactor eats.
    public func summaryLines() -> [String] {
        var meta = "app_version=" + appVersion
        meta += " signal=" + String(signal) + " (" + RawCrashReport.signalName(signal) + ")"
        meta += " ts=" + String(timestampSec)
        meta += " thread=" + (mainThread ? "main" : "background")
        meta += " frames=" + String(addresses.count)
        var image = "image: " + imageName + " uuid=" + MetricKitCrashStackFormatter.dottedUUID(imageUUID)
        image += " load 0x" + String(loadAddress, radix: 16)
        image += " size 0x" + String(textSize, radix: 16)
        return [meta, image]
    }

    /// The text `CrashReportTextParser` reads (same shape the handler used to write before the raw record), so the
    /// `app.crash` telemetry event keeps being built from it.
    public func legacyReportText(context: String?, breadcrumbs: [String]) -> String {
        var s = "=== QAUDION CRASH \u{2014} signal " + String(signal)
        s += " (" + RawCrashReport.signalName(signal) + ") ===\n"
        if !fatal.isEmpty { s += "fatal: " + fatal + "\n" }
        s += "stack:\n"
        s += frameLines().joined(separator: "\n")
        if let ctx = context, !ctx.isEmpty { s += "\ncontext: " + ctx }
        if !breadcrumbs.isEmpty { s += "\nbreadcrumbs:\n" + breadcrumbs.joined(separator: "\n") }
        return s
    }
}
