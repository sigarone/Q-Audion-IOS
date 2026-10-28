import CryptoKit
import Foundation
import XCTest
@testable import QAudionEngine

/// The sealed sender envelope of message alerts: the server's known-answer vectors (byte for byte), the strict parse of
/// the plaintext, and the rejections.
final class NotifyEnvelopeTests: XCTestCase {

    private struct Case: Decodable {
        let name: String
        let kind: String
        let sender_id: String
        let group_id: String?
        let t: Int64
        let device_priv: String
        let device_pub: String
        let eph_priv: String
        let nonce: String
        let plaintext: String
        let blob: String
        let negative: Bool?
    }

    private struct Vectors: Decodable { let cases: [Case] }

    private func vectors() throws -> [Case] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "notify_envelope_v1", withExtension: "json"),
                                "notify_envelope_v1.json is missing from the test bundle")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url)).cases
    }

    private func bytes(_ hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    // MARK: - Known answers

    func testEveryPositiveVectorOpensToThePlaintextByteForByte() throws {
        let all = try vectors()
        let positive = all.filter { $0.negative != true }
        XCTAssertGreaterThanOrEqual(positive.count, 3)
        for c in positive {
            let priv = bytes(c.device_priv)
            let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: priv)
            XCTAssertEqual(key.publicKey.rawRepresentation, bytes(c.device_pub), c.name)
            let opened = try NotifyEnvelope.openToBytes(blobBase64: c.blob, devicePrivateKey: priv)
            XCTAssertEqual(opened, Data(c.plaintext.utf8), c.name)
            let parsed = try NotifyEnvelope.open(blobBase64: c.blob, devicePrivateKey: priv)
            XCTAssertEqual(parsed.senderID, c.sender_id, c.name)
            XCTAssertEqual(parsed.groupID, c.group_id, c.name)
            XCTAssertEqual(parsed.timestamp, c.t, c.name)
            XCTAssertEqual(parsed.kind.rawValue, c.kind, c.name)
        }
    }

    func testTheNegativeVectorIsRefused() throws {
        let negatives = try vectors().filter { $0.negative == true }
        XCTAssertFalse(negatives.isEmpty)
        for c in negatives {
            XCTAssertThrowsError(try NotifyEnvelope.open(blobBase64: c.blob, devicePrivateKey: bytes(c.device_priv))) {
                XCTAssertEqual($0 as? NotifyEnvelope.OpenError, .decryption)
            }
        }
    }

    func testAnotherDeviceKeyCannotOpenTheBlob() throws {
        let c = try XCTUnwrap(try vectors().first { $0.negative != true })
        let other = Curve25519.KeyAgreement.PrivateKey().rawRepresentation
        XCTAssertThrowsError(try NotifyEnvelope.open(blobBase64: c.blob, devicePrivateKey: other)) {
            XCTAssertEqual($0 as? NotifyEnvelope.OpenError, .decryption)
        }
    }

    // MARK: - Blob shape

    func testBlobRejections() throws {
        let c = try XCTUnwrap(try vectors().first { $0.negative != true })
        let priv = bytes(c.device_priv)
        func code(_ blob: String) -> NotifyEnvelope.OpenError? {
            do { _ = try NotifyEnvelope.open(blobBase64: blob, devicePrivateKey: priv); return nil } catch {
                return error as? NotifyEnvelope.OpenError
            }
        }
        XCTAssertEqual(code("not base64 !!"), .malformedBlob)
        XCTAssertEqual(code(""), .malformedBlob)
        XCTAssertEqual(code(Data(repeating: 1, count: 60).base64EncodedString()), .malformedBlob)   // too short
        var wrongVersion = [UInt8](Data(base64Encoded: c.blob)!)
        wrongVersion[0] = 0x02
        XCTAssertEqual(code(Data(wrongVersion).base64EncodedString()), .unsupportedVersion)
        XCTAssertEqual(code(String(repeating: "A", count: NotifyEnvelope.maxBlobText + 4)), .malformedBlob)
    }

    func testAnAllZeroEphemeralKeyIsRefused() throws {
        let c = try XCTUnwrap(try vectors().first { $0.negative != true })
        var raw = [UInt8](Data(base64Encoded: c.blob)!)
        for i in 1...32 { raw[i] = 0 }
        XCTAssertThrowsError(try NotifyEnvelope.open(blobBase64: Data(raw).base64EncodedString(),
                                                     devicePrivateKey: bytes(c.device_priv))) {
            XCTAssertEqual($0 as? NotifyEnvelope.OpenError, .keyAgreement)
        }
    }

    func testAWrongSizePrivateKeyIsRefused() throws {
        let c = try XCTUnwrap(try vectors().first { $0.negative != true })
        XCTAssertThrowsError(try NotifyEnvelope.open(blobBase64: c.blob, devicePrivateKey: Data(count: 31))) {
            XCTAssertEqual($0 as? NotifyEnvelope.OpenError, .invalidKey)
        }
    }

    // MARK: - Plaintext parser

    private func parse(_ json: String) -> Result<NotifyEnvelope.Plaintext, NotifyEnvelope.OpenError> {
        do { return .success(try NotifyEnvelope.parse(Data(json.utf8))) } catch {
            return .failure(error as! NotifyEnvelope.OpenError)
        }
    }

    func testAcceptsBothKindsAndTrailingPadding() {
        let dm = #"{"v":1,"k":"dm","s":"abc","t":1793145600}"# + String(repeating: " ", count: 200)
        XCTAssertEqual(try? parse(dm).get(),
                       NotifyEnvelope.Plaintext(kind: .dm, senderID: "abc", groupID: nil, timestamp: 1793145600))
        let grp = #"{"v":1,"k":"grp","s":"abc","g":"grp-1","t":5}"#
        XCTAssertEqual(try? parse(grp).get(),
                       NotifyEnvelope.Plaintext(kind: .grp, senderID: "abc", groupID: "grp-1", timestamp: 5))
    }

    func testRejectsEverythingElse() {
        let bad = [
            #"{"v":2,"k":"dm","s":"a","t":1}"#,                    // version
            #"{"k":"dm","s":"a","t":1}"#,                           // no version
            #"{"v":"1","k":"dm","s":"a","t":1}"#,                   // version as text
            #"{"v":true,"k":"dm","s":"a","t":1}"#,                  // version as boolean
            #"{"v":1,"k":"xx","s":"a","t":1}"#,                     // kind
            #"{"v":1,"k":"dm","t":1}"#,                             // no sender
            #"{"v":1,"k":"dm","s":"","t":1}"#,                      // empty sender
            #"{"v":1,"k":"dm","s":"a"}"#,                           // no time
            #"{"v":1,"k":"dm","s":"a","t":1.5}"#,                   // fractional time
            #"{"v":1,"k":"dm","s":"a","t":"1"}"#,                   // time as text
            #"{"v":1,"k":"dm","s":"a","g":"x","t":1}"#,             // group on a 1:1
            #"{"v":1,"k":"grp","s":"a","t":1}"#,                    // group message without group
            #"{"v":1,"k":"grp","s":"a","g":"","t":1}"#,             // empty group
            #"{"v":1,"k":"dm","s":"a","t":1,"x":1}"#,               // extra member
            #"{"v":1,"k":"dm","s":"a","t":1} trailing"#,            // garbage after the object
            #"{"v":1,"k":"dm","s":"a","t":1}{"v":1}"#,              // second object
            #"[1,2]"#, "", "null",
        ]
        for json in bad {
            if case .success = parse(json) { XCTFail("accepted: \(json)") }
        }
    }

    func testFreshness() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func p(_ t: Int64) -> NotifyEnvelope.Plaintext {
            NotifyEnvelope.Plaintext(kind: .dm, senderID: "a", groupID: nil, timestamp: t)
        }
        XCTAssertTrue(p(2_000_000_000 - 3600).isFresh(now: now))
        XCTAssertTrue(p(2_000_000_000 - 7 * 86400).isFresh(now: now))
        XCTAssertFalse(p(2_000_000_000 - 7 * 86400 - 1).isFresh(now: now))
    }
}
