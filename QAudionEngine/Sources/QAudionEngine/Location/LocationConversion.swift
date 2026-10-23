import Foundation

// Conversion from platform values (WIRE_SPEC section 14.4) and the four ways a position is handed to another application
// (section 14.9): a `geo:` URI, an Apple Maps link, a Google Maps universal link and a GPX 1.1 file. Pure functions: nothing is
// uploaded and no map tile is fetched to draw a message.

public enum LocationConversion {

    public enum Axis: Sendable {
        case latitude, longitude

        var range: ClosedRange<Int64> {
            switch self {
            case .latitude: return LocationWire.latE7Min...LocationWire.latE7Max
            case .longitude: return LocationWire.lonE7Min...LocationWire.lonE7Max
            }
        }
    }

    /// `RHAZ(degrees x 10^7)`: one IEEE 754 double multiplication, rounded to the nearest integer with ties away from zero
    /// (`(x * 1e7).rounded(.toNearestOrAwayFromZero)`); a negative zero is 0 (there is no negative zero on the wire).
    ///
    /// A degrees value that is NaN or infinite is no valid fix (`fix`). A finite value whose integer falls outside the range of its
    /// axis, a product that overflows to infinity included, is `range`.
    public static func e7(degrees: Double, axis: Axis) -> Result<Int32, LocationBuildRefusal> {
        guard degrees.isFinite else { return .failure(.fix) }
        let product: Double = degrees * 1e7
        guard product.isFinite else { return .failure(.range) }
        let rounded: Double = product.rounded(.toNearestOrAwayFromZero)
        // Both axes are far below 2^53: anything beyond is out of range, and the check keeps the conversion below from trapping.
        guard abs(rounded) <= 4e9 else { return .failure(.range) }
        let value: Int64 = Int64(rounded)
        guard axis.range.contains(value) else { return .failure(.range) }
        return .success(Int32(value))
    }

    /// `ceil(horizontal accuracy in metres)`, then 0 becomes 1 and a value above `ACC_MAX` becomes `ACC_MAX`. A negative, NaN or infinite
    /// accuracy is no valid fix (`fix`).
    public static func accuracy(metres: Double) -> Result<Int64, LocationBuildRefusal> {
        guard metres.isFinite, metres >= 0 else { return .failure(.fix) }
        let ceiled: Double = metres.rounded(.up)
        if ceiled >= Double(LocationWire.accMax) { return .success(LocationWire.accMax) }
        let value: Int64 = Int64(ceiled)
        return .success(max(value, LocationWire.accMin))
    }

    /// `floor(now - fix_time)` in seconds, from the milliseconds between them on a monotonic clock; a negative interval is 0.
    public static func age(elapsedMs: Int64) -> Int64 {
        elapsedMs < 0 ? 0 : elapsedMs / 1000
    }

    /// The `age` of a frame: as `age`, clamped to `FRAME_AGE_MAX` (a 16-bit field), never wrapped.
    public static func frameAge(elapsedMs: Int64) -> UInt16 {
        UInt16(min(age(elapsedMs: elapsedMs), LocationWire.frameAgeMax))
    }

    // MARK: DEC7 and PCT (section 14.9)

    /// `DEC7(v)`: the decimal text of an E7 integer without floating point: a minus sign if `v < 0`, then `|v| / 10^7`, a point, then
    /// `|v| mod 10^7` as exactly 7 digits. `0` gives `0.0000000`; there is never `-0.0000000`.
    public static func dec7(_ value: Int64) -> String {
        let magnitude: UInt64 = value.magnitude
        let whole: UInt64 = magnitude / 10_000_000
        let fraction: UInt64 = magnitude % 10_000_000
        var digits: String = String(fraction)
        if digits.count < 7 { digits = String(repeating: "0", count: 7 - digits.count) + digits }
        return (value < 0 ? "-" : "") + String(whole) + "." + digits
    }

    /// `PCT(s)`: percent-encodes the UTF-8 bytes of `s`. `A-Z a-z 0-9 - . _ ~` are written as they are and every other byte as `%` and two
    /// upper-case hexadecimal digits (a space is `%20`, never `+`).
    public static func percentEncoded(_ text: String) -> String {
        let hex: [Character] = Array("0123456789ABCDEF")
        var out: String = ""
        for byte in text.utf8 {
            let isUnreserved: Bool = (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39)
                || byte == 0x2D || byte == 0x2E || byte == 0x5F || byte == 0x7E
            if isUnreserved {
                out.append(Character(Unicode.Scalar(byte)))
            } else {
                out.append("%")
                out.append(hex[Int(byte >> 4)])
                out.append(hex[Int(byte & 0x0F)])
            }
        }
        return out
    }
}

/// The four outputs of section 14.9. `label` is the fixed text of the application's string catalogue for a shared position, localised:
/// never a name, an address or the name of the contact.
public enum LocationOpenLinks {

    /// `geo:<DEC7(lat)>,<DEC7(lon)>?q=<DEC7(lat)>,<DEC7(lon)>`: no label, no uncertainty parameter.
    public static func geoURI(latE7: Int32, lonE7: Int32) -> String {
        let lat: String = LocationConversion.dec7(Int64(latE7))
        let lon: String = LocationConversion.dec7(Int64(lonE7))
        return "geo:\(lat),\(lon)?q=\(lat),\(lon)"
    }

    /// `https://maps.apple.com/?ll=<DEC7(lat)>,<DEC7(lon)>&q=<PCT(label)>`
    public static func appleMapsURL(latE7: Int32, lonE7: Int32, label: String) -> String {
        let lat: String = LocationConversion.dec7(Int64(latE7))
        let lon: String = LocationConversion.dec7(Int64(lonE7))
        let encoded: String = LocationConversion.percentEncoded(label)
        return "https://maps.apple.com/?ll=\(lat),\(lon)&q=\(encoded)"
    }

    /// `https://www.google.com/maps/search/?api=1&query=<DEC7(lat)>%2C<DEC7(lon)>`: a universal link, it opens the application when it is
    /// installed and a web page otherwise.
    public static func googleMapsURL(latE7: Int32, lonE7: Int32) -> String {
        let lat: String = LocationConversion.dec7(Int64(latE7))
        let lon: String = LocationConversion.dec7(Int64(lonE7))
        return "https://www.google.com/maps/search/?api=1&query=\(lat)%2C\(lon)"
    }

    /// The GPX 1.1 file: UTF-8, LF line endings, no byte order mark, one waypoint, no time, no accuracy, no sender name, one LF after the
    /// last line. `label` is XML-escaped (`&`, `<`, `>`, `"`, `'`).
    public static func gpx(latE7: Int32, lonE7: Int32, label: String) -> String {
        let lat: String = LocationConversion.dec7(Int64(latE7))
        let lon: String = LocationConversion.dec7(Int64(lonE7))
        var lines: [String] = []
        lines.append(#"<?xml version="1.0" encoding="UTF-8"?>"#)
        lines.append(#"<gpx version="1.1" creator="QAudion" xmlns="http://www.topografix.com/GPX/1/1">"#)
        lines.append("<wpt lat=\"\(lat)\" lon=\"\(lon)\">")
        lines.append("<name>\(xmlEscaped(label))</name>")
        lines.append("</wpt>")
        lines.append("</gpx>")
        return lines.joined(separator: "\n") + "\n"
    }

    static func xmlEscaped(_ text: String) -> String {
        var out: String = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out.append("&amp;")
            case "<": out.append("&lt;")
            case ">": out.append("&gt;")
            case "\"": out.append("&quot;")
            case "'": out.append("&apos;")
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
