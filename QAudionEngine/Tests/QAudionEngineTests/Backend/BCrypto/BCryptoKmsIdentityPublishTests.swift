import XCTest
@testable import QAudionEngine

/// The identity publish and fetch over the wire, against a stubbed transport: the extra signature fields are sent only
/// on the v2 publish, only when present and never empty; a 400 that says the Ed25519 bundle is stored is a success and
/// is not retried; any other 400, or a 413, falls back once to a publish without the fields; and a fetched bundle keeps
/// a peer's key only when its certificate verifies against that bundle's Ed25519 key, uuid and device id.
final class BCryptoKmsIdentityPublishTests: XCTestCase {

    // MARK: - Fixture: the first xcert vector of the shared file

    private struct Fixture {
        let uuid: Data
        let deviceId: String
        let edSeed: Data
        let edPub: Data
        let createdMs: Int64
    }

    private func hex(_ s: String) -> Data { MldsaIdentityPublicationTests.hex(s) }

    private func fixture() throws -> Fixture {
        let candidates: [URL?] = [
            Bundle.module.url(forResource: "pqc-hardening-v1-kat", withExtension: "json"),
            Bundle.module.url(forResource: "pqc-hardening-v1-kat", withExtension: "json", subdirectory: "kat"),
            Bundle.module.url(forResource: "pqc-hardening-v1-kat", withExtension: "json", subdirectory: "Resources/kat")
        ]
        let url = try XCTUnwrap(candidates.compactMap { $0 }.first)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let seedCases = try XCTUnwrap((root["mldsaSeed"] as? [String: Any])?["cases"] as? [[String: Any]])
        let vectors = try XCTUnwrap((root["xcert"] as? [String: Any])?["vectors"] as? [[String: Any]])
        let v = vectors[0]
        let c = seedCases[try XCTUnwrap(v["seedCase"] as? Int)]
        return Fixture(
            uuid: hex(try XCTUnwrap(v["uuid"] as? String)),
            deviceId: try XCTUnwrap(v["deviceIdUtf8"] as? String),
            edSeed: hex(try XCTUnwrap(c["edSeed"] as? String)),
            edPub: hex(try XCTUnwrap(v["edPub"] as? String)),
            createdMs: try XCTUnwrap(Int64(try XCTUnwrap(v["createdMs"] as? String))))
    }

    private func fields(_ fx: Fixture) throws -> MldsaIdentityPublication.Fields {
        try XCTUnwrap(MldsaIdentityPublication.build(
            edSeed: fx.edSeed, edPub: fx.edPub, uuidRaw: fx.uuid, deviceId: fx.deviceId, createdMs: fx.createdMs))
    }

    private func uuidString(_ raw: Data) -> String {
        let h = raw.map { String(format: "%02x", $0) }.joined()
        let a = Array(h)
        func part(_ r: Range<Int>) -> String { String(a[r]) }
        return [part(0..<8), part(8..<12), part(12..<16), part(16..<20), part(20..<32)].joined(separator: "-")
    }

    // MARK: - Transport

    override func setUp() {
        super.setUp()
        PeerMldsaStore.clear()
        MldsaStubProtocol.reset()
    }

    override func tearDown() {
        MldsaStubProtocol.reset()
        PeerMldsaStore.clear()
        super.tearDown()
    }

    private func makeClient() -> BCryptoKmsClient {
        let config = BackendConfig(serverUrl: "https://kms.test", accessToken: "tok")
        let rest = BCryptoRestClient(config: config, testURLProtocolClasses: [MldsaStubProtocol.self])
        return BCryptoKmsClient(rest: rest)
    }

    private func publish(
        _ client: BCryptoKmsClient, _ fx: Fixture, mldsa: MldsaIdentityPublication.Fields?, deviceId: String? = nil
    ) async throws -> String? {
        try await client.publishUserIdentityBundleV2(
            ed25519Pub: fx.edPub, ikPqPub: Data(repeating: 7, count: 1568), ikX25519Pub: Data(repeating: 9, count: 32),
            selfSig: Data(repeating: 5, count: 64), createdAtMs: 1_762_000_000_000, deviceId: deviceId ?? fx.deviceId,
            mldsa: mldsa)
    }

    private func jsonKeys(_ body: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    // MARK: - Request shape

    func testWithoutFieldsTheBodyHasNoneOfThem_notEvenEmptyOnes() async throws {
        let fx = try fixture()
        MldsaStubProtocol.replies = [.ok("{}")]
        _ = try await publish(makeClient(), fx, mldsa: nil)
        let obj = try jsonKeys(try XCTUnwrap(MldsaStubProtocol.bodies.first))
        XCTAssertTrue(obj.keys.allSatisfy { !$0.hasPrefix("mldsa") })
        XCTAssertNotNil(obj["device_id"])
        XCTAssertEqual(obj["version"] as? Int, 2)
        XCTAssertNotNil(obj["self_sig_b64"])
    }

    func testWithFieldsTheBodyCarriesExactlyTheSpecNamesAndSizes() async throws {
        let fx = try fixture()
        let f = try fields(fx)
        MldsaStubProtocol.replies = [.ok("{}"), .ok("{}")]
        let client = makeClient()
        _ = try await publish(client, fx, mldsa: nil)
        _ = try await publish(client, fx, mldsa: f)
        let plain = MldsaStubProtocol.bodies[0]
        let withFields = MldsaStubProtocol.bodies[1]
        let obj = try jsonKeys(withFields)
        XCTAssertEqual(
            Set(obj.keys.filter { $0.hasPrefix("mldsa") }),
            ["mldsa_pub_b64", "mldsa_xc_created_ms", "mldsa_xc_ed_sig_b64", "mldsa_xc_pq_sig_b64", "mldsa_key_id_b64"])
        XCTAssertNil(obj["mldsa_gen"], "0 is the default and is not sent")
        XCTAssertEqual(obj["mldsa_pub_b64"] as? String, f.pubB64)
        XCTAssertEqual(obj["mldsa_xc_ed_sig_b64"] as? String, f.edSigB64)
        XCTAssertEqual(obj["mldsa_xc_pq_sig_b64"] as? String, f.pqSigB64)
        XCTAssertEqual(obj["mldsa_key_id_b64"] as? String, f.keyIdB64)
        XCTAssertEqual((obj["mldsa_xc_created_ms"] as? NSNumber)?.int64Value, f.createdMs)
        XCTAssertNotEqual(CFGetTypeID(try XCTUnwrap(obj["mldsa_xc_created_ms"] as? NSNumber)), CFBooleanGetTypeID())
        // payload size: about 9.9 KB of base64 on top of the old body, far below the server limit of 64 KiB
        let added = withFields.count - plain.count
        XCTAssertTrue((9_500...10_400).contains(added), "added \(added) bytes")
        XCTAssertLessThan(withFields.count, 16_000)
        // the base64 sizes are exactly those of 2592, 64, 4627 and 32 bytes
        XCTAssertEqual(f.pubB64.count, 3456)
        XCTAssertEqual(f.edSigB64.count, 88)
        XCTAssertEqual(f.pqSigB64.count, 6172)
        XCTAssertEqual(f.keyIdB64.count, 44)
    }

    func testFieldsAreNeverSentWithoutADeviceId() async throws {
        let fx = try fixture()
        MldsaStubProtocol.replies = [.ok("{}")]
        _ = try await publish(makeClient(), fx, mldsa: try fields(fx), deviceId: "")
        let obj = try jsonKeys(try XCTUnwrap(MldsaStubProtocol.bodies.first))
        XCTAssertTrue(obj.keys.allSatisfy { !$0.hasPrefix("mldsa") })
        XCTAssertNil(obj["device_id"])
    }

    func testTheAckKeyIdIsReturned() async throws {
        let fx = try fixture()
        let f = try fields(fx)
        MldsaStubProtocol.replies = [.ok("{\"mldsa_key_id_b64\":\"\(f.keyIdB64)\"}")]
        let ack = try await publish(makeClient(), fx, mldsa: f)
        XCTAssertEqual(ack, f.keyIdB64)
    }

    // MARK: - Publish policy over the real client

    func testAcceptedWhenTheAckNamesTheKey() async throws {
        let fx = try fixture()
        let f = try fields(fx)
        MldsaStubProtocol.replies = [.ok("{\"mldsa_key_id_b64\":\"\(f.keyIdB64)\"}")]
        let client = makeClient()
        let out = try await MldsaPublishPolicy.publish(f) { m in try await self.publish(client, fx, mldsa: m) }
        XCTAssertEqual(out, .accepted)
        XCTAssertEqual(MldsaStubProtocol.bodies.count, 1)
    }

    func testAnAckWithoutTheKeyIdIsNotAccepted_andNothingIsRetried() async throws {
        let fx = try fixture()
        let f = try fields(fx)
        MldsaStubProtocol.replies = [.ok("{}")]
        let client = makeClient()
        let out = try await MldsaPublishPolicy.publish(f) { m in try await self.publish(client, fx, mldsa: m) }
        XCTAssertEqual(out, .unacknowledged)
        XCTAssertEqual(MldsaStubProtocol.bodies.count, 1)
    }

    func test400WithTheStoredMarkerIsASuccess_oneRequest_noLoop() async throws {
        let fx = try fixture()
        let f = try fields(fx)
        MldsaStubProtocol.replies = [
            .status(400, "{\"error\":\"mldsa fields rejected: cross-certificate invalid\",\"ed25519_bundle_stored\":true}")
        ]
        let client = makeClient()
        let out = try await MldsaPublishPolicy.publish(f) { m in try await self.publish(client, fx, mldsa: m) }
        XCTAssertEqual(out, .refused(reason: "mldsa fields rejected: cross-certificate invalid"))
        XCTAssertEqual(MldsaStubProtocol.bodies.count, 1)
    }

    func test400WithoutTheMarkerFallsBackOnceToAPublishWithoutTheFields() async throws {
        let fx = try fixture()
        let f = try fields(fx)
        let markers = [
            "{\"error\":\"malformed json\"}",
            "{\"error\":\"x\",\"ed25519_bundle_stored\":false}",
            "{\"error\":\"x\",\"ed25519_bundle_stored\":\"true\"}",
            "{\"error\":\"x\",\"ed25519_bundle_stored\":1}",
            "self_sig invalid"
        ]
        for body in markers {
            MldsaStubProtocol.reset()
            MldsaStubProtocol.replies = [.status(400, body), .ok("{}")]
            let client = makeClient()
            let out = try await MldsaPublishPolicy.publish(f) { m in try await self.publish(client, fx, mldsa: m) }
            XCTAssertEqual(out, .refused(reason: "fallback_after_http_400"), body)
            XCTAssertEqual(MldsaStubProtocol.bodies.count, 2, body)
            let second = try jsonKeys(MldsaStubProtocol.bodies[1])
            XCTAssertTrue(second.keys.allSatisfy { !$0.hasPrefix("mldsa") }, body)
            XCTAssertNotNil(second["self_sig_b64"], "the Ed25519 bundle itself is unchanged")
        }
    }

    func test413FallsBackOnce() async throws {
        let fx = try fixture()
        let f = try fields(fx)
        MldsaStubProtocol.replies = [.status(413, ""), .ok("{}")]
        let client = makeClient()
        let out = try await MldsaPublishPolicy.publish(f) { m in try await self.publish(client, fx, mldsa: m) }
        XCTAssertEqual(out, .refused(reason: "fallback_after_http_413"))
        XCTAssertEqual(MldsaStubProtocol.bodies.count, 2)
    }

    func testAServerErrorPropagatesWithoutAFallback() async throws {
        let fx = try fixture()
        let f = try fields(fx)
        MldsaStubProtocol.replies = [.status(500, "{}")]
        let client = makeClient()
        do {
            _ = try await MldsaPublishPolicy.publish(f) { m in try await self.publish(client, fx, mldsa: m) }
            XCTFail("expected the error")
        } catch BCryptoError.httpError(let code) {
            XCTAssertEqual(code, 500)
        }
        XCTAssertEqual(MldsaStubProtocol.bodies.count, 1)
    }

    func testAPlain400OfAnyOtherEndpointKeepsItsShape() async throws {
        MldsaStubProtocol.replies = [.status(400, "{\"error\":\"nope\"}")]
        let client = makeClient()
        do {
            _ = try await client.uploadOneTimePrekeys(body: Data("{}".utf8))
            XCTFail("expected the error")
        } catch BCryptoError.httpError(let code) {
            XCTAssertEqual(code, 400, "no marker, so the usual error")
        }
    }

    // MARK: - Fetch

    private func bundleJSON(
        _ fx: Fixture, _ f: MldsaIdentityPublication.Fields?, deviceId: String? = nil, gen: Int? = 0,
        mutate: (inout [String: Any]) -> Void = { _ in }
    ) -> String {
        var d: [String: Any] = [
            "uuid": uuidString(fx.uuid),
            "ed25519_pub_b64": fx.edPub.base64EncodedString(),
            "ik_pq_pub_b64": Data(repeating: 7, count: 1568).base64EncodedString(),
            "ik_x25519_pub_b64": Data(repeating: 9, count: 32).base64EncodedString(),
            "version": 2,
            "created_at_ms": 1_762_000_000_000,
            "device_id": deviceId ?? fx.deviceId
        ]
        if let f {
            d["mldsa_pub_b64"] = f.pubB64
            d["mldsa_xc_created_ms"] = f.createdMs
            d["mldsa_xc_ed_sig_b64"] = f.edSigB64
            d["mldsa_xc_pq_sig_b64"] = f.pqSigB64
            d["mldsa_key_id_b64"] = f.keyIdB64
            if let gen { d["mldsa_gen"] = gen }
        }
        mutate(&d)
        let data = try? JSONSerialization.data(withJSONObject: d)
        return String(decoding: data ?? Data(), as: UTF8.self)
    }

    private func fetchAndIngest(_ body: String, _ fx: Fixture) async -> (BCryptoKmsClient.IdentityBundleV2?, MldsaIdentityPublication.VerifiedPeer?) {
        MldsaStubProtocol.reset()
        MldsaStubProtocol.replies = [.ok(body)]
        guard let bundle = await makeClient().fetchUserIdentityBundleV2(userId: uuidString(fx.uuid)) else { return (nil, nil) }
        return (bundle, PeerMldsaStore.ingest(bundle))
    }

    func testFetchKeepsAValidKeyInMemoryUnderTheExactIdentity() async throws {
        let fx = try fixture()
        let f = try fields(fx)
        let (bundle, verified) = await fetchAndIngest(bundleJSON(fx, f), fx)
        XCTAssertEqual(bundle?.deviceId, fx.deviceId)
        let key = try XCTUnwrap(verified)
        XCTAssertEqual(key.pub.base64EncodedString(), f.pubB64)
        let stored = try XCTUnwrap(PeerMldsaStore.get(uuidRaw: fx.uuid, deviceId: fx.deviceId, edPub: fx.edPub))
        XCTAssertEqual(stored, key)
        // keyed by (uuid, device id, Ed25519 key): nothing is found under any other part
        XCTAssertNil(PeerMldsaStore.get(uuidRaw: fx.uuid, deviceId: "another-device", edPub: fx.edPub))
        XCTAssertNil(PeerMldsaStore.get(uuidRaw: fx.uuid, deviceId: fx.deviceId, edPub: Data(repeating: 1, count: 32)))
        var otherUuid = fx.uuid
        otherUuid[0] ^= 1
        XCTAssertNil(PeerMldsaStore.get(uuidRaw: otherUuid, deviceId: fx.deviceId, edPub: fx.edPub))
    }

    func testFetchWithoutTheFieldsStoresNothing() async throws {
        let fx = try fixture()
        let (bundle, verified) = await fetchAndIngest(bundleJSON(fx, nil), fx)
        XCTAssertNotNil(bundle, "the bundle itself is unchanged")
        XCTAssertNil(verified)
        XCTAssertEqual(PeerMldsaStore.count, 0)
    }

    func testFetchRejectsAnInvalidCertificateButKeepsTheBundle() async throws {
        let fx = try fixture()
        let f = try fields(fx)
        var bad = try XCTUnwrap(Data(base64Encoded: f.pqSigB64))
        bad[100] ^= 1
        let (bundle, verified) = await fetchAndIngest(bundleJSON(fx, f) { $0["mldsa_xc_pq_sig_b64"] = bad.base64EncodedString() }, fx)
        XCTAssertNotNil(bundle)
        XCTAssertNil(verified)
        XCTAssertEqual(PeerMldsaStore.count, 0)
    }

    func testFetchRejectsACertificateForAnotherDeviceIdOrNone() async throws {
        let fx = try fixture()
        let f = try fields(fx)
        let (_, other) = await fetchAndIngest(bundleJSON(fx, f, deviceId: "other"), fx)
        XCTAssertNil(other)
        let (_, none) = await fetchAndIngest(bundleJSON(fx, f) { _ = $0.removeValue(forKey: "device_id") }, fx)
        XCTAssertNil(none)
        XCTAssertEqual(PeerMldsaStore.count, 0)
    }

    func testFetchRejectsAPartialSetAndAReservedGeneration() async throws {
        let fx = try fixture()
        let f = try fields(fx)
        for name in ["mldsa_pub_b64", "mldsa_xc_created_ms", "mldsa_xc_ed_sig_b64", "mldsa_xc_pq_sig_b64"] {
            let (_, v) = await fetchAndIngest(bundleJSON(fx, f) { _ = $0.removeValue(forKey: name) }, fx)
            XCTAssertNil(v, name)
        }
        let (_, gen1) = await fetchAndIngest(bundleJSON(fx, f, gen: 1), fx)
        XCTAssertNil(gen1)
        XCTAssertEqual(PeerMldsaStore.count, 0)
    }

    func testABundleWithoutAValidCertificateDropsTheEntryStoredEarlier() async throws {
        let fx = try fixture()
        let f = try fields(fx)
        let (_, first) = await fetchAndIngest(bundleJSON(fx, f), fx)
        XCTAssertNotNil(first)
        XCTAssertEqual(PeerMldsaStore.count, 1)
        // the same device now serves a bundle without the fields (or with a broken set): nothing stale is kept
        let (_, absent) = await fetchAndIngest(bundleJSON(fx, nil), fx)
        XCTAssertNil(absent)
        XCTAssertNil(PeerMldsaStore.get(uuidRaw: fx.uuid, deviceId: fx.deviceId, edPub: fx.edPub))
        let (_, again) = await fetchAndIngest(bundleJSON(fx, f), fx)
        XCTAssertNotNil(again)
        let (_, broken) = await fetchAndIngest(bundleJSON(fx, f) { $0["mldsa_xc_created_ms"] = f.createdMs + 1 }, fx)
        XCTAssertNil(broken)
        XCTAssertEqual(PeerMldsaStore.count, 0)
    }

    func testARotatedEd25519KeyNeverReusesTheEarlierEntry() async throws {
        let fx = try fixture()
        let f = try fields(fx)
        let (_, first) = await fetchAndIngest(bundleJSON(fx, f), fx)
        XCTAssertNotNil(first)
        // same user and device, a new Ed25519 identity (a reinstall) with its own certificate
        let kat = try katSeedCase(3)
        let rotated = Fixture(uuid: fx.uuid, deviceId: fx.deviceId, edSeed: kat.edSeed, edPub: kat.edPub, createdMs: fx.createdMs + 5)
        let g = try fields(rotated)
        let (_, second) = await fetchAndIngest(bundleJSON(rotated, g), rotated)
        XCTAssertNotNil(second)
        XCTAssertNil(PeerMldsaStore.get(uuidRaw: fx.uuid, deviceId: fx.deviceId, edPub: fx.edPub), "the old key is gone")
        XCTAssertNotNil(PeerMldsaStore.get(uuidRaw: fx.uuid, deviceId: fx.deviceId, edPub: rotated.edPub))
        XCTAssertEqual(PeerMldsaStore.count, 1)
    }

    func testClearEmptiesTheStoreAtLogout() async throws {
        let fx = try fixture()
        let f = try fields(fx)
        _ = await fetchAndIngest(bundleJSON(fx, f), fx)
        XCTAssertEqual(PeerMldsaStore.count, 1)
        PeerMldsaStore.clear()
        XCTAssertEqual(PeerMldsaStore.count, 0)
        XCTAssertNil(PeerMldsaStore.get(uuidRaw: fx.uuid, deviceId: fx.deviceId, edPub: fx.edPub))
    }

    private func katSeedCase(_ i: Int) throws -> (edSeed: Data, edPub: Data) {
        let candidates: [URL?] = [
            Bundle.module.url(forResource: "pqc-hardening-v1-kat", withExtension: "json"),
            Bundle.module.url(forResource: "pqc-hardening-v1-kat", withExtension: "json", subdirectory: "kat"),
            Bundle.module.url(forResource: "pqc-hardening-v1-kat", withExtension: "json", subdirectory: "Resources/kat")
        ]
        let url = try XCTUnwrap(candidates.compactMap { $0 }.first)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try XCTUnwrap((root["mldsaSeed"] as? [String: Any])?["cases"] as? [[String: Any]])
        return (hex(try XCTUnwrap(cases[i]["edSeed"] as? String)), hex(try XCTUnwrap(cases[i]["edPub"] as? String)))
    }
}

/// URLProtocol stub that records every request body and answers from a queue.
private final class MldsaStubProtocol: URLProtocol {
    enum Reply {
        case ok(String)
        case status(Int, String)
    }

    static var replies: [Reply] = []
    static var bodies: [Data] = []

    static func reset() {
        replies = []
        bodies = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            out.append(buffer, count: n)
        }
        return out
    }

    override func startLoading() {
        Self.bodies.append(Self.readBody(request))
        let reply = Self.replies.isEmpty ? Reply.status(500, "{}") : Self.replies.removeFirst()
        let status: Int
        let text: String
        switch reply {
        case .ok(let t):
            status = 200
            text = t
        case .status(let s, let t):
            status = s
            text = t
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
