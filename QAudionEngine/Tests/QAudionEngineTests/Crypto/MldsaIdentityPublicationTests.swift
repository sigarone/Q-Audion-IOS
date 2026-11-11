import XCTest
import CryptoKit
@testable import QAudionEngine

/// The extra signature fields of the identity bundle are built byte for byte as the shared vectors
/// (`pqc-hardening-v1-kat.json`, sections mldsaSeed and xcert) say, a republish carries the same fields, the publish
/// policy never lets them fail the Ed25519 publish, and a peer's fields are kept only when the certificate verifies.
///
/// ML-DSA signing is hedged in production: the ML-DSA half of a built certificate differs on every call, so it is
/// checked by verification, and the key, the key id and the XC encoding by bytes. CryptoKit signs Ed25519
/// non-deterministically, so the Ed25519 half is checked by verification too.
final class MldsaIdentityPublicationTests: XCTestCase {

    // MARK: - Vectors

    struct Vector {
        let name: String
        let uuid: Data
        let deviceId: String
        let edSeed: Data
        let edPub: Data
        let mldsaPub: Data
        let keyId: Data
        let createdMs: Int64
        let xc: Data
        let xcEd: Data
        let xcPq: Data
    }

    static func hex(_ s: String) -> Data {
        var out = Data()
        var index = s.startIndex
        while index < s.endIndex {
            let next = s.index(index, offsetBy: 2)
            out.append(UInt8(s[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    private func katObject() throws -> [String: Any] {
        let candidates: [URL?] = [
            Bundle.module.url(forResource: "pqc-hardening-v1-kat", withExtension: "json"),
            Bundle.module.url(forResource: "pqc-hardening-v1-kat", withExtension: "json", subdirectory: "kat"),
            Bundle.module.url(forResource: "pqc-hardening-v1-kat", withExtension: "json", subdirectory: "Resources/kat")
        ]
        let url = try XCTUnwrap(candidates.compactMap { $0 }.first, "pqc-hardening-v1-kat.json is not in the test bundle")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url), options: [])
        return try XCTUnwrap(object as? [String: Any])
    }

    func vectors() throws -> [Vector] {
        let kat = try katObject()
        let seedCases = try XCTUnwrap((kat["mldsaSeed"] as? [String: Any])?["cases"] as? [[String: Any]])
        let list = try XCTUnwrap((kat["xcert"] as? [String: Any])?["vectors"] as? [[String: Any]])
        return try list.map { (v: [String: Any]) throws -> Vector in
            let seedCase = try XCTUnwrap(v["seedCase"] as? Int)
            let c = seedCases[seedCase]
            let deviceId = try XCTUnwrap(v["deviceIdUtf8"] as? String)
            // the exact bytes of the vector: no normalization on the way through JSON and String
            XCTAssertEqual(Data(deviceId.utf8), Self.hex(try XCTUnwrap(v["deviceIdHex"] as? String)))
            return Vector(
                name: try XCTUnwrap(v["name"] as? String),
                uuid: Self.hex(try XCTUnwrap(v["uuid"] as? String)),
                deviceId: deviceId,
                edSeed: Self.hex(try XCTUnwrap(c["edSeed"] as? String)),
                edPub: Self.hex(try XCTUnwrap(v["edPub"] as? String)),
                mldsaPub: Self.hex(try XCTUnwrap(c["mldsaPub"] as? String)),
                keyId: Self.hex(try XCTUnwrap(v["mldsaKeyId"] as? String)),
                createdMs: try XCTUnwrap(Int64(try XCTUnwrap(v["createdMs"] as? String))),
                xc: Self.hex(try XCTUnwrap(v["xc"] as? String)),
                xcEd: Self.hex(try XCTUnwrap(v["xcEd"] as? String)),
                xcPq: Self.hex(try XCTUnwrap(v["xcPq"] as? String)))
        }
    }

    /// Another identity, for key-rotation cases: seed2-gen0 (case 3) of the shared file.
    func otherIdentity() throws -> (edSeed: Data, edPub: Data) {
        let kat = try katObject()
        let seedCases = try XCTUnwrap((kat["mldsaSeed"] as? [String: Any])?["cases"] as? [[String: Any]])
        let c = seedCases[3]
        return (Self.hex(try XCTUnwrap(c["edSeed"] as? String)), Self.hex(try XCTUnwrap(c["edPub"] as? String)))
    }

    func build(_ v: Vector, createdMs: Int64? = nil) -> MldsaIdentityPublication.Fields? {
        MldsaIdentityPublication.build(
            edSeed: v.edSeed, edPub: v.edPub, uuidRaw: v.uuid, deviceId: v.deviceId, createdMs: createdMs ?? v.createdMs)
    }

    private func xcFields(_ v: Vector) -> Pqsig.XcFields {
        Pqsig.XcFields(
            uuid: v.uuid, deviceId: Data(v.deviceId.utf8), edPub: v.edPub, mldsaPub: v.mldsaPub, gen: 0,
            createdMs: UInt64(v.createdMs))
    }

    // MARK: - Build, byte exact

    func testBuildReproducesTheSharedVectors() throws {
        let all = try vectors()
        XCTAssertEqual(all.count, 3)
        for v in all {
            let f = try XCTUnwrap(build(v), v.name)
            let pub = try XCTUnwrap(Data(base64Encoded: f.pubB64), v.name)
            let ed = try XCTUnwrap(Data(base64Encoded: f.edSigB64), v.name)
            let pq = try XCTUnwrap(Data(base64Encoded: f.pqSigB64), v.name)
            let keyId = try XCTUnwrap(Data(base64Encoded: f.keyIdB64), v.name)
            XCTAssertEqual(pub, v.mldsaPub, v.name)
            XCTAssertEqual(keyId, v.keyId, v.name)
            XCTAssertEqual(f.createdMs, v.createdMs, v.name)
            XCTAssertEqual(pub.count, 2592)
            XCTAssertEqual(ed.count, 64)
            XCTAssertEqual(pq.count, 4627)
            XCTAssertEqual(keyId.count, 32)
            // the statement that is signed is exactly the vector's XC
            XCTAssertEqual(Pqsig.encodeXC(xcFields(v)), v.xc, v.name)
            // our halves verify, and each of ours verifies against the vector's other half
            XCTAssertTrue(Pqsig.verifyXC(xcFields(v), Pqsig.XcSignatures(ed: ed, pq: pq)), v.name)
            XCTAssertTrue(Pqsig.verifyXC(xcFields(v), Pqsig.XcSignatures(ed: v.xcEd, pq: pq)), v.name)
            XCTAssertTrue(Pqsig.verifyXC(xcFields(v), Pqsig.XcSignatures(ed: ed, pq: v.xcPq)), v.name)
        }
    }

    func testRepublishWithTheSameCreatedMsKeepsTheServerComparedFields() throws {
        let v = try XCTUnwrap(try vectors().first)
        let a = try XCTUnwrap(build(v))
        let b = try XCTUnwrap(build(v))
        XCTAssertEqual(a.pubB64, b.pubB64)
        XCTAssertEqual(a.keyIdB64, b.keyIdB64)
        XCTAssertEqual(a.createdMs, b.createdMs)
        XCTAssertNotEqual(a.pqSigB64, b.pqSigB64, "ML-DSA signing is hedged")
    }

    func testBuildRefusesWhatTheServerWouldRefuse() throws {
        let v = try XCTUnwrap(try vectors().first)
        var wrongPub = v.edPub
        wrongPub[0] ^= 1
        XCTAssertNil(MldsaIdentityPublication.build(
            edSeed: v.edSeed, edPub: wrongPub, uuidRaw: v.uuid, deviceId: v.deviceId, createdMs: v.createdMs), "seed of another key")
        XCTAssertNil(build(v, createdMs: 0))
        XCTAssertNil(build(v, createdMs: -1))
        XCTAssertNil(MldsaIdentityPublication.build(
            edSeed: v.edSeed, edPub: v.edPub, uuidRaw: Data(count: 15), deviceId: v.deviceId, createdMs: v.createdMs))
        XCTAssertNil(MldsaIdentityPublication.build(
            edSeed: v.edSeed.prefix(31), edPub: v.edPub, uuidRaw: v.uuid, deviceId: v.deviceId, createdMs: v.createdMs))
        for bad in ["", " dev", "dev ", "dev\n", "dev\u{85}", "dev\u{3000}", String(repeating: "x", count: 256)] {
            XCTAssertNil(MldsaIdentityPublication.build(
                edSeed: v.edSeed, edPub: v.edPub, uuidRaw: v.uuid, deviceId: bad, createdMs: v.createdMs), bad)
        }
    }

    // MARK: - Device id

    func testDeviceIdRules() {
        let ok = MldsaIdentityPublication.isPublishableDeviceId
        XCTAssertFalse(ok(nil))
        XCTAssertFalse(ok(""))
        for bad in [" dev", "dev ", "\tdev", "dev\r", "dev\u{0B}", "\u{A0}dev", "dev\u{A0}", "dev\u{85}", "\u{1680}dev",
                    "dev\u{2000}", "dev\u{200A}", "dev\u{2028}", "dev\u{2029}", "dev\u{202F}", "dev\u{205F}", "dev\u{3000}"] {
            XCTAssertFalse(ok(bad), "device id <\(bad.unicodeScalars.map { $0.value })>")
        }
        XCTAssertTrue(ok("3f2b8c1e-0d4a-4c6e-9b7a-5e1d2c3b4a59"))
        XCTAssertTrue(ok(String(repeating: "x", count: 255)))
        XCTAssertFalse(ok(String(repeating: "x", count: 256)))
        // the limit is in bytes, not characters: 128 two-byte characters are 256 bytes
        XCTAssertFalse(ok(String(repeating: "\u{E9}", count: 128)))
        XCTAssertTrue(ok(String(repeating: "\u{E9}", count: 127)))
        // inner whitespace is fine, and no U+200B / U+FEFF (not spaces in Go) at the edge
        XCTAssertTrue(ok("my phone \u{E9}"))
        XCTAssertTrue(ok("\u{200B}dev"))
        XCTAssertTrue(ok("\u{FEFF}dev"))
    }

    // MARK: - created_ms per binding

    func testCreatedMsIsFixedPerBindingAndFreshForAnotherOne() throws {
        let v = try XCTUnwrap(try vectors().first)
        let first = MldsaIdentityPublication.createdMsFor(
            stored: nil, uuidRaw: v.uuid, edPub: v.edPub, deviceId: v.deviceId, nowMs: 1_000)
        XCTAssertEqual(first.createdMs, 1_000)
        let again = MldsaIdentityPublication.createdMsFor(
            stored: first.record, uuidRaw: v.uuid, edPub: v.edPub, deviceId: v.deviceId, nowMs: 9_999)
        XCTAssertEqual(again.createdMs, 1_000, "the same binding keeps the stored value")
        XCTAssertEqual(again.record, first.record)
        let otherDevice = MldsaIdentityPublication.createdMsFor(
            stored: first.record, uuidRaw: v.uuid, edPub: v.edPub, deviceId: "other-device", nowMs: 9_999)
        XCTAssertEqual(otherDevice.createdMs, 9_999, "another device id is a new binding")
        var otherUuid = v.uuid
        otherUuid[0] ^= 1
        XCTAssertEqual(MldsaIdentityPublication.createdMsFor(
            stored: first.record, uuidRaw: otherUuid, edPub: v.edPub, deviceId: v.deviceId, nowMs: 9_999).createdMs, 9_999)
        let other = try otherIdentity()
        XCTAssertEqual(MldsaIdentityPublication.createdMsFor(
            stored: first.record, uuidRaw: v.uuid, edPub: other.edPub, deviceId: v.deviceId, nowMs: 9_999).createdMs, 9_999,
                       "a new Ed25519 key is a new binding")
        XCTAssertEqual(MldsaIdentityPublication.createdMsFor(
            stored: "garbage", uuidRaw: v.uuid, edPub: v.edPub, deviceId: v.deviceId, nowMs: 7).createdMs, 7)
        let hash = first.record.split(separator: ":")[0]
        XCTAssertEqual(MldsaIdentityPublication.createdMsFor(
            stored: "\(hash):-5", uuidRaw: v.uuid, edPub: v.edPub, deviceId: v.deviceId, nowMs: 7).createdMs, 7)
        XCTAssertEqual(MldsaIdentityPublication.createdMsFor(
            stored: "\(hash):x", uuidRaw: v.uuid, edPub: v.edPub, deviceId: v.deviceId, nowMs: 7).createdMs, 7)
    }

    // MARK: - Fetch side

    private func verify(
        _ v: Vector, _ f: MldsaIdentityPublication.Fields, gen: Int? = nil, deviceId: String?? = nil, uuid: Data? = nil,
        edPub: Data? = nil, pubB64: String?? = nil, edSigB64: String?? = nil, pqSigB64: String?? = nil,
        createdMs: Int64?? = nil, keyIdB64: String?? = nil
    ) -> MldsaIdentityPublication.VerifiedPeer? {
        MldsaIdentityPublication.verifyPeer(
            pubB64: pubB64 ?? f.pubB64, createdMs: createdMs ?? f.createdMs, edSigB64: edSigB64 ?? f.edSigB64,
            pqSigB64: pqSigB64 ?? f.pqSigB64, gen: gen, keyIdB64: keyIdB64 ?? f.keyIdB64,
            uuidRaw: uuid ?? v.uuid, deviceId: deviceId ?? v.deviceId, edPub: edPub ?? v.edPub)
    }

    private func flipped(_ b64: String) -> String {
        var d = Data(base64Encoded: b64)!
        d[d.count / 2] ^= 1
        return d.base64EncodedString()
    }

    func testFetchSideAcceptsAValidSetAndExposesTheKey() throws {
        for v in try vectors() {
            let f = try XCTUnwrap(build(v), v.name)
            let verified = try XCTUnwrap(verify(v, f), v.name)
            XCTAssertEqual(verified.pub, v.mldsaPub)
            XCTAssertEqual(verified.keyId, v.keyId)
            XCTAssertEqual(verified.createdMs, v.createdMs)
            XCTAssertNotNil(verify(v, f, gen: 0, keyIdB64: .some(nil)), "explicit gen 0 and no key id are fine")
            // the vector's own halves are accepted as published fields too
            let kat = MldsaIdentityPublication.verifyPeer(
                pubB64: v.mldsaPub.base64EncodedString(), createdMs: v.createdMs, edSigB64: v.xcEd.base64EncodedString(),
                pqSigB64: v.xcPq.base64EncodedString(), gen: nil, keyIdB64: nil, uuidRaw: v.uuid, deviceId: v.deviceId,
                edPub: v.edPub)
            XCTAssertNotNil(kat, v.name)
        }
    }

    func testFetchSideRejectsEveryTamperedOrPartialSet() throws {
        let v = try XCTUnwrap(try vectors().first)
        let f = try XCTUnwrap(build(v))
        XCTAssertNil(verify(v, f, deviceId: .some("other")), "other device id")
        XCTAssertNil(verify(v, f, deviceId: .some(nil)), "no device id")
        var otherUuid = v.uuid
        otherUuid[15] ^= 1
        XCTAssertNil(verify(v, f, uuid: otherUuid), "other uuid")
        XCTAssertNil(verify(v, f, edPub: try otherIdentity().edPub), "other Ed25519 key")
        XCTAssertNil(verify(v, f, createdMs: .some(f.createdMs + 1)), "changed created_ms")
        XCTAssertNil(verify(v, f, edSigB64: .some(flipped(f.edSigB64))), "flipped Ed25519 half")
        XCTAssertNil(verify(v, f, pqSigB64: .some(flipped(f.pqSigB64))), "flipped ML-DSA half")
        XCTAssertNil(verify(v, f, pubB64: .some(flipped(f.pubB64))), "flipped key")
        XCTAssertNil(verify(v, f, keyIdB64: .some(flipped(f.keyIdB64))), "wrong key id")
        XCTAssertNil(verify(v, f, gen: 1), "gen above 0 is reserved")
        XCTAssertNil(verify(v, f, pubB64: .some(nil)), "missing key")
        XCTAssertNil(verify(v, f, edSigB64: .some(nil)), "missing Ed25519 half")
        XCTAssertNil(verify(v, f, pqSigB64: .some("")), "empty ML-DSA half")
        XCTAssertNil(verify(v, f, createdMs: .some(nil)), "missing created_ms")
        XCTAssertNil(verify(v, f, createdMs: .some(0)), "zero created_ms")
        XCTAssertNil(verify(v, f, pubB64: .some("%%%")), "not base64")
        XCTAssertNil(verify(v, f, pubB64: .some(Data(count: 10).base64EncodedString())), "short key")
        XCTAssertNil(verify(v, f, edPub: Data(count: 32)), "small-order Ed25519 key")
    }

    // MARK: - Fingerprint

    func testFingerprintCoversTheBindingAndTheSchemaVersion() {
        let ed = Data(repeating: 1, count: 32)
        let pq = Data(repeating: 2, count: 1568)
        let x = Data(repeating: 3, count: 32)
        XCTAssertEqual(IdentityPublishFingerprint.mldsaBindingToken(enabled: false, deviceId: "dev-1"), "m0")
        XCTAssertEqual(IdentityPublishFingerprint.mldsaBindingToken(enabled: true, deviceId: nil), "m0")
        XCTAssertEqual(IdentityPublishFingerprint.mldsaBindingToken(enabled: true, deviceId: "dev-1 "), "m0")
        XCTAssertEqual(IdentityPublishFingerprint.mldsaBindingToken(enabled: true, deviceId: "dev-1"), "m1:dev-1")
        let on = IdentityPublishFingerprint.v2(
            deviceId: "dev-1", ed25519Pub: ed, ikPqPub: pq, ikX25519Pub: x,
            mldsaBinding: IdentityPublishFingerprint.mldsaBindingToken(enabled: true, deviceId: "dev-1"))
        let off = IdentityPublishFingerprint.v2(
            deviceId: "dev-1", ed25519Pub: ed, ikPqPub: pq, ikX25519Pub: x,
            mldsaBinding: IdentityPublishFingerprint.mldsaBindingToken(enabled: false, deviceId: "dev-1"))
        XCTAssertNotEqual(on, off, "the switch flipping republishes")
        XCTAssertFalse(IdentityPublishFingerprint.needsPublish(stored: on, current: on))
        // a device that published before the fields existed republishes once
        let previous = "v2|s2|dev-1|\(ed.base64EncodedString())|\(pq.base64EncodedString())|\(x.base64EncodedString())"
        XCTAssertTrue(IdentityPublishFingerprint.needsPublish(stored: previous, current: on))
        XCTAssertTrue(IdentityPublishFingerprint.needsPublish(stored: previous, current: off))
        XCTAssertEqual(IdentityPublishFingerprint.payloadSchemaVersion, 3)
    }

    // MARK: - Publish policy

    private final class Recorder {
        var sent: [MldsaIdentityPublication.Fields?] = []
    }

    private func firstFields() throws -> MldsaIdentityPublication.Fields {
        try XCTUnwrap(build(try XCTUnwrap(try vectors().first)))
    }

    func testPolicyWithoutFieldsIsOnePlainPublish() async throws {
        let r = Recorder()
        let out = try await MldsaPublishPolicy.publish(nil) { m in
            r.sent.append(m)
            return nil
        }
        XCTAssertEqual(out, .plain)
        XCTAssertEqual(r.sent.count, 1)
        XCTAssertNil(r.sent[0])
    }

    func testPolicyAcceptedNeedsTheAckToNameThisKey() async throws {
        let f = try firstFields()
        let r = Recorder()
        let accepted = try await MldsaPublishPolicy.publish(f) { m in
            r.sent.append(m)
            return f.keyIdB64
        }
        XCTAssertEqual(accepted, .accepted)
        XCTAssertEqual(r.sent.count, 1)
        XCTAssertEqual(r.sent[0], f)
        for ack: String? in [nil, "", flipped(f.keyIdB64), "%%%"] {
            let r2 = Recorder()
            let out = try await MldsaPublishPolicy.publish(f) { m in
                r2.sent.append(m)
                return ack
            }
            XCTAssertEqual(out, .unacknowledged, "ack \(ack ?? "nil")")
            XCTAssertEqual(r2.sent.count, 1, "no retry")
        }
    }

    func testPolicyBundleStoredIsASuccessfulEd25519PublishNotRetried() async throws {
        let f = try firstFields()
        let r = Recorder()
        let out = try await MldsaPublishPolicy.publish(f) { m in
            r.sent.append(m)
            throw BCryptoIdentityBundleStored(reason: "mldsa fields rejected: cross-certificate invalid")
        }
        XCTAssertEqual(out, .refused(reason: "mldsa fields rejected: cross-certificate invalid"))
        XCTAssertEqual(r.sent.count, 1, "no second request, no loop")
    }

    func testPolicyOther400AndThe413FallBackOnceToAPublishWithoutTheFields() async throws {
        let f = try firstFields()
        for code in [400, 413] {
            let r = Recorder()
            let out = try await MldsaPublishPolicy.publish(f) { m in
                r.sent.append(m)
                if m != nil { throw BCryptoError.httpError(code) }
                return nil
            }
            XCTAssertEqual(out, .refused(reason: "fallback_after_http_\(code)"))
            XCTAssertEqual(r.sent.count, 2)
            XCTAssertNotNil(r.sent[0])
            XCTAssertNil(r.sent[1])
        }
    }

    func testPolicyAFailingFallbackIsARealFailureAndNotRetriedAgain() async throws {
        let f = try firstFields()
        let r = Recorder()
        do {
            _ = try await MldsaPublishPolicy.publish(f) { m in
                r.sent.append(m)
                throw BCryptoError.httpError(400)
            }
            XCTFail("expected the error")
        } catch BCryptoError.httpError(let code) {
            XCTAssertEqual(code, 400)
        }
        XCTAssertEqual(r.sent.count, 2)
    }

    func testPolicyOtherFailuresPropagateWithNoExtraRequest() async throws {
        let f = try firstFields()
        let errors: [Error] = [
            BCryptoError.unauthorized, BCryptoError.httpError(429), BCryptoError.httpError(500),
            BCryptoError.httpError(401), URLError(.notConnectedToInternet)
        ]
        for error in errors {
            let r = Recorder()
            do {
                _ = try await MldsaPublishPolicy.publish(f) { m in
                    r.sent.append(m)
                    throw error
                }
                XCTFail("expected \(error)")
            } catch {
                // propagated untouched
            }
            XCTAssertEqual(r.sent.count, 1, "\(error)")
        }
    }

    func testStoredMarkerMustBeTheJsonTrueLiteral() {
        func stored(_ s: String?) -> Bool { MldsaPublishPolicy.ed25519BundleStored(s.map { Data($0.utf8) }) }
        XCTAssertTrue(stored("{\"error\":\"x\",\"ed25519_bundle_stored\":true}"))
        XCTAssertFalse(stored("{\"ed25519_bundle_stored\":false}"))
        XCTAssertFalse(stored("{\"ed25519_bundle_stored\":\"true\"}"))
        XCTAssertFalse(stored("{\"ed25519_bundle_stored\":1}"))
        XCTAssertFalse(stored("{\"ed25519_bundle_stored\":null}"))
        XCTAssertFalse(stored("{\"error\":\"x\"}"))
        XCTAssertFalse(stored("self_sig invalid"))
        XCTAssertFalse(stored(nil))
    }

    func testRefusalReasonIsShortPrintableAscii() {
        func reason(_ s: String) -> String { MldsaPublishPolicy.refusalReason(Data(s.utf8)) }
        XCTAssertEqual(reason("{\"error\":\"mldsa fields rejected: x\"}"), "mldsa fields rejected: x")
        XCTAssertEqual(reason("{\"error\":\"a\\u00e9\\nb\"}"), "ab")
        XCTAssertEqual(reason("{\"error\":\"\(String(repeating: "z", count: 500))\"}").count, 120)
        XCTAssertEqual(reason("{}"), "refused")
        XCTAssertEqual(reason("nope"), "refused")
        XCTAssertEqual(MldsaPublishPolicy.refusalReason(nil), "refused")
    }

    func testAckKeyIdIsReadFromTheBody() {
        XCTAssertEqual(MldsaPublishPolicy.ackKeyId(in: Data("{\"mldsa_key_id_b64\":\"abc=\"}".utf8)), "abc=")
        XCTAssertNil(MldsaPublishPolicy.ackKeyId(in: Data("{}".utf8)))
        XCTAssertNil(MldsaPublishPolicy.ackKeyId(in: Data("{\"mldsa_key_id_b64\":5}".utf8)))
        XCTAssertNil(MldsaPublishPolicy.ackKeyId(in: Data("x".utf8)))
    }

    func testTheKillSwitchKeyAndDefault() {
        XCTAssertEqual(MldsaPublishPolicy.flagKey, "pqc.mldsa_publish")
        XCTAssertTrue(MldsaPublishPolicy.compiledDefault)
    }
}
