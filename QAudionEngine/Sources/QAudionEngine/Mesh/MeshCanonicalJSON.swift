import Foundation

/// Writer for the canonical JSON of the mesh payloads (docs/mesh/MESH_LINK_SPEC.md
/// section 14): members in the documented order, UTF-8, no whitespace, `/` not
/// escaped, non-ASCII written as is. Decoders accept any valid JSON with the same
/// members; this is what encoders SHOULD produce, and what the shared vectors pin.
enum MeshCanonicalJSON {

    /// A JSON string literal: `"` and `\` escaped, control characters as `\b \f \n \r \t` or `\u00XX`.
    static func quote(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }

    /// `{"k":v,...}` from members already rendered as JSON values, in the given order.
    static func object(_ members: [(String, String)]) -> Data {
        let body = members.map { quote($0.0) + ":" + $0.1 }.joined(separator: ",")
        return Data(("{" + body + "}").utf8)
    }

    static func string(_ value: String) -> String { quote(value) }

    static func int(_ value: Int) -> String { String(value) }

    static func int64(_ value: Int64) -> String { String(value) }
}
