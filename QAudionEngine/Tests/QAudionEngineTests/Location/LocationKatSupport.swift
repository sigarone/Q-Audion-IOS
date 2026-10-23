import XCTest
import CryptoKit
@testable import QAudionEngine

// The vector file of WIRE_SPEC section 14: `test/kat/location_v1/location-kat.json` of the server repository, a BYTE-FOR-BYTE copy
// (generated there by tools/katgen/location, Go standard library only). Its SHA-256 is pinned here, so the copy in this repository can
// never drift from the server's. The file is read as untyped JSON on purpose: its sections have very different shapes, and a typed
// decoder would hide a renamed member behind a default.
//
// This code was written on a machine that cannot compile Swift for iOS: it was compiled and run with swift-crypto on Linux, and the
// macOS CI job is what runs it for real.

enum LocationKat {

    static let pinnedSHA256 = "72ac8c3f6987c252f2722b9b50c836e9218a3588748bbd9220e67b560b43d600"
    static let pinnedLength = 400_081

    static func bytes() throws -> Data {
        let candidates: [URL?] = [
            Bundle.module.url(forResource: "location-kat", withExtension: "json"),
            Bundle.module.url(forResource: "location-kat", withExtension: "json", subdirectory: "kat"),
            Bundle.module.url(forResource: "location-kat", withExtension: "json", subdirectory: "Resources/kat")
        ]
        guard let url = candidates.compactMap({ $0 }).first else {
            throw NSError(domain: "LocationKat", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "location-kat.json is not in the test bundle"])
        }
        return try Data(contentsOf: url)
    }

    /// A token that stands for a byte order mark while Foundation reads the file. Foundation's JSON reader drops a U+FEFF at the start of a
    /// string value, raw or written as an escape (the entry-point vector `bom_first` holds one, and the vector is about that very
    /// character), so the bytes EF BB BF are swapped for this ASCII token before reading and swapped back, as a Swift string, after. The
    /// file itself is pinned byte for byte above this, and no vector contains the token.
    static let bomToken = "@@BOM@@"

    static func bytesForDecoding() throws -> Data {
        let original = [UInt8](try bytes())
        let token: [UInt8] = Array(bomToken.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(original.count + 64)
        var index = 0
        while index < original.count {
            if index + 2 < original.count, original[index] == 0xEF, original[index + 1] == 0xBB, original[index + 2] == 0xBF {
                out.append(contentsOf: token)
                index += 3
            } else {
                out.append(original[index])
                index += 1
            }
        }
        return Data(out)
    }

    /// The decoded JSON with the byte order marks put back (as the scalar U+FEFF, which Swift strings keep).
    private static func restoreBOM(_ value: Any) -> Any {
        let bom = String(decoding: [0xEF, 0xBB, 0xBF] as [UInt8], as: UTF8.self)
        if let text = value as? String { return text.replacingOccurrences(of: bomToken, with: bom) }
        if let list = value as? [Any] { return list.map { restoreBOM($0) } }
        if let object = value as? [String: Any] { return object.mapValues { restoreBOM($0) } }
        return value
    }

    static func load() throws -> [String: Any] {
        let object = restoreBOM(try JSONSerialization.jsonObject(with: try bytesForDecoding()))
        guard let root = object as? [String: Any] else {
            throw NSError(domain: "LocationKat", code: 2, userInfo: [NSLocalizedDescriptionKey: "location-kat.json is not an object"])
        }
        return root
    }

    static func sha256Hex(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Typed reads of untyped JSON

    static func section(_ root: [String: Any], _ name: String, file: StaticString = #filePath, line: UInt = #line) -> [[String: Any]] {
        guard let list = root[name] as? [[String: Any]] else {
            XCTFail("section \(name) is missing or is not a list of objects", file: file, line: line)
            return []
        }
        return list
    }

    static func object(_ root: [String: Any], _ name: String, file: StaticString = #filePath, line: UInt = #line) -> [String: Any] {
        guard let value = root[name] as? [String: Any] else {
            XCTFail("section \(name) is missing or is not an object", file: file, line: line)
            return [:]
        }
        return value
    }

    static func int(_ dictionary: [String: Any], _ key: String) -> Int64? {
        if let number = dictionary[key] as? NSNumber { return number.int64Value }
        return nil
    }

    static func string(_ dictionary: [String: Any], _ key: String) -> String? { dictionary[key] as? String }

    static func bool(_ dictionary: [String: Any], _ key: String) -> Bool? {
        if let number = dictionary[key] as? NSNumber { return number.boolValue }
        return nil
    }

    static func strings(_ dictionary: [String: Any], _ key: String) -> [String]? { dictionary[key] as? [String] }

    /// The BYTES of a body vector: `serialized` as the UTF-8 of the text, or `serialized_b64` decoded; exactly one is present.
    static func bodyBytes(_ vector: [String: Any]) -> Data {
        switch (vector["serialized"] as? String, vector["serialized_b64"] as? String) {
        case (let text?, nil):
            return Data(text.utf8)
        case (nil, let encoded?):
            return Data(base64Encoded: encoded) ?? Data()
        default:
            XCTFail("exactly one of serialized and serialized_b64 in \(vector["name"] as? String ?? "?")")
            return Data()
        }
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    static func data(fromHex text: String) -> Data {
        var out = Data()
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            out.append(UInt8(text[index..<next], radix: 16) ?? 0)
            index = next
        }
        return out
    }

    /// The Double whose IEEE 754 bits are given as 16 hexadecimal digits (the KAT never relies on a decimal text parsing to the same
    /// double in every library).
    static func double(fromBits text: String) -> Double {
        Double(bitPattern: UInt64(text, radix: 16) ?? 0)
    }

    /// A stable text of a JSON value: object members sorted, so that two values compare as text.
    static func canonical(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "\(value)"
        }
        return text
    }

    static func utf8(_ text: String) -> [UInt8] { Array(text.utf8) }
}
