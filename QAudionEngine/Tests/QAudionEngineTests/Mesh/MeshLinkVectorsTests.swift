import XCTest
import CryptoKit
@testable import QAudionEngine

/// Runs every section of `mesh-vectors.json` (docs/mesh/MESH_LINK_SPEC.md section 14)
/// against the engine: the same bytes the Android client is tested with, produced by
/// docs/mesh/gen_mesh_vectors.py. The file is a byte-for-byte copy; its SHA-256 is
/// pinned here so an edit (or a line-ending rewrite) cannot go unnoticed.
final class MeshLinkVectorsTests: XCTestCase {

    static let pinnedSha256 = "2bbeb51ff983aabacf5848b0d33b6e94501e6f0a05b34986ae339906d3bf4a95"

    // MARK: - Loading

    private func vectorBytes() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "mesh-vectors", withExtension: "json"),
                                "mesh-vectors.json missing from Bundle.module")
        return try Data(contentsOf: url)
    }

    private func vectors() throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: try vectorBytes())
        return try XCTUnwrap(object as? [String: Any])
    }

    private func section(_ name: String) throws -> [[String: Any]] {
        try XCTUnwrap(try vectors()[name] as? [[String: Any]], "section \(name)")
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func bytes(_ hexString: String) throws -> Data {
        XCTAssertEqual(hexString.count % 2, 0)
        var out = Data()
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            out.append(try XCTUnwrap(UInt8(hexString[index..<next], radix: 16)))
            index = next
        }
        return out
    }

    private func string(_ dict: [String: Any], _ key: String) -> String {
        guard let value = dict[key] as? String else {
            XCTFail("missing string member \(key)")
            return ""
        }
        return value
    }

    private func int(_ dict: [String: Any], _ key: String) -> Int {
        guard let value = (dict[key] as? NSNumber)?.intValue else {
            XCTFail("missing number member \(key)")
            return 0
        }
        return value
    }

    // MARK: - File

    func testVectorFileIsPinned() throws {
        let digest = SHA256.hash(data: try vectorBytes()).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, Self.pinnedSha256)
        XCTAssertEqual(try vectors()["spec"] as? String, "mesh-link-spec/1")
    }

    // MARK: - constants

    func testConstants() throws {
        let c = try XCTUnwrap(try vectors()["constants"] as? [String: Any])
        XCTAssertEqual(string(c, "serviceUuid"), "b7c1a5e0-9d3a-4f6b-8a21-0d1e2f3a4b01")
        XCTAssertEqual(string(c, "characteristicUuid"), "b7c1a5e0-9d3a-4f6b-8a21-0d1e2f3a4b02")
        XCTAssertEqual(int(c, "wireVersion"), MeshPacket.wireVersion)
        XCTAssertEqual(int(c, "nodeIdBytes"), MeshNodeId.sizeBytes)
        XCTAssertEqual(string(c, "broadcastNodeId"), MeshNodeId.broadcast.hex)
        XCTAssertEqual(int(c, "maxPayloadBytes"), MeshPacket.maxPayloadBytes)
        XCTAssertEqual(int(c, "maxPacketBytes"), MeshPacket.maxEncodedBytes)
        XCTAssertEqual(int(c, "maxPacketBytes"), MeshLinkFraming.maxPacketBytes)
        XCTAssertEqual(int(c, "frameHeaderBytes"), MeshLinkFraming.headerBytes)
        XCTAssertEqual(int(c, "maxFramesPerSet"), MeshLinkFraming.maxFramesPerSet)
        XCTAssertEqual(int(c, "defaultTtl"), MeshPacket.defaultTTL)
        let types = try XCTUnwrap(c["packetTypes"] as? [String: Any])
        XCTAssertEqual(int(types, "DATA"), Int(MeshPacketType.data.rawValue))
        XCTAssertEqual(int(types, "FRAGMENT"), Int(MeshPacketType.fragment.rawValue))
        XCTAssertEqual(int(types, "ANNOUNCE"), Int(MeshPacketType.announce.rawValue))
        XCTAssertEqual(int(types, "ACK"), Int(MeshPacketType.ack.rawValue))
        XCTAssertEqual(int(types, "RECEIPT"), Int(MeshPacketType.receipt.rawValue))
        XCTAssertEqual(int(types, "ANNOUNCE_PROOF"), Int(MeshPacketType.announceProof.rawValue))
    }

    func testSpecConstantsOfTheLinkLayer() {
        XCTAssertEqual(MeshFrameSetSender.frameTimeoutMs, 2_000)
        XCTAssertEqual(MeshLinkReassembler.idleTimeoutMs, 10_000)
        XCTAssertEqual(MeshLinkReassembler.absoluteTimeoutMs, 30_000)
        XCTAssertEqual(MeshLinkReassembler.maxIncompleteSets, 4)
        XCTAssertEqual(MeshMalformedGuard.maxStreak, 10)
        XCTAssertEqual(MeshMalformedGuard.blockMs, 60_000)
        XCTAssertEqual(MeshRelayGate.rememberedIdentities, 256)
        XCTAssertEqual(MeshRelayGate.maxPerWindow, 20)
        XCTAssertEqual(MeshRelayGate.windowMs, 10_000)
        XCTAssertEqual(MeshAnnounce.maxNeighbors, 10)
        XCTAssertEqual(MeshOutboxPolicy.retryMs, 20_000)
        XCTAssertEqual(MeshOutboxPolicy.giveUpMs, 3_600_000)
        XCTAssertEqual(MeshRefreshGate.intervalMs, 60_000)
        // Section 3.5 and section 2.1 rows of the constants table.
        XCTAssertEqual(MeshConnectBackoff.firstMs, 15_000)
        XCTAssertEqual(MeshConnectBackoff.maxMs, 300_000)
        XCTAssertEqual(MeshConnectBackoff.jitterRangePermille, 200)
        XCTAssertEqual(MeshConnectBackoff.capacity, 64)
        XCTAssertEqual(MeshBtCallPause.resumeWithinMs, 2_000)
        XCTAssertEqual(MeshBtCallPause.restartMinIntervalMs, 5_000)
    }

    // MARK: - nodeIds

    func testNodeIds() throws {
        let rows = try section("nodeIds")
        XCTAssertFalse(rows.isEmpty)
        for row in rows {
            let key = try bytes(string(row, "identityKeyHex"))
            let derived = try XCTUnwrap(MeshNodeId.from(identityKeyRaw: key))
            XCTAssertEqual(derived.hex, string(row, "nodeIdHex"), string(row, "name"))
        }
    }

    // MARK: - packetHeaders

    func testPacketHeadersEncodeExactlyAndRoundTrip() throws {
        for row in try section("packetHeaders") {
            let name = string(row, "name")
            let f = try XCTUnwrap(row["fields"] as? [String: Any])
            let type = try XCTUnwrap(MeshPacketType(rawValue: UInt8(int(f, "type"))), name)
            let ttl: Int? = (f["ttl"] as? NSNumber)?.intValue
            let route = try (f["sourceRoute"] as? [String] ?? []).map { try MeshNodeId(hex: $0) }
            let timestamp = try XCTUnwrap((f["timestampMs"] as? NSNumber)?.int64Value, name)
            let packet = try MeshPacket(
                version: int(f, "version"), type: type,
                senderId: try MeshNodeId(hex: string(f, "senderId")),
                recipientId: try MeshNodeId(hex: string(f, "recipientId")),
                ttl: ttl, sourceRoute: route, timestampMs: timestamp,
                payload: try bytes(string(f, "payloadHex"))
            )
            let encoded = packet.encode()
            XCTAssertEqual(hex(encoded), string(row, "encodedHex"), name)
            XCTAssertEqual(encoded.count, int(row, "encodedLength"), name)
            XCTAssertEqual(MeshPacket.decode(encoded), packet, name)
        }
    }

    func testPacketDecodeNegativeRejectsWithTheDocumentedReason() throws {
        let rows = try section("packetDecodeNegative")
        XCTAssertGreaterThanOrEqual(rows.count, 10)
        for row in rows {
            let name = string(row, "name")
            let input = try bytes(string(row, "hex"))
            XCTAssertEqual(string(row, "expect"), "reject", name)
            switch MeshPacket.decodeStrict(input) {
            case .success:
                XCTFail("\(name) was accepted")
            case .failure(let error):
                XCTAssertEqual(error.rawValue, string(row, "reason"), name)
            }
            XCTAssertNil(MeshPacket.decode(input), name)
        }
    }

    // MARK: - discoveryCipher / announce

    func testDiscoveryCipherOpensTheFixedNonceVectors() throws {
        let cipher = try XCTUnwrap(try vectors()["discoveryCipher"] as? [String: Any])
        XCTAssertEqual(string(cipher, "aead"), "AES-256-GCM")
        XCTAssertEqual(int(cipher, "nonceBytes"), 12)
        XCTAssertEqual(int(cipher, "tagBytes"), 16)
        for row in try section("announce") {
            let name = string(row, "name")
            let wire = try bytes(string(row, "wireHex"))
            XCTAssertEqual(wire.count, int(row, "wireLength"), name)
            let opened = try XCTUnwrap(MeshDiscoveryCipher.decrypt(wire), name)
            XCTAssertEqual(String(decoding: opened, as: UTF8.self), string(row, "canonicalJson"), name)
            // And what this device seals opens with the same key.
            let resealed = try XCTUnwrap(MeshDiscoveryCipher.encrypt(opened))
            XCTAssertEqual(resealed.count, wire.count)
            XCTAssertEqual(MeshDiscoveryCipher.decrypt(resealed), opened)
        }
    }

    func testAnnounceEncodesTheCanonicalJsonAndPacketDecodes() throws {
        for row in try section("announce") {
            let name = string(row, "name")
            let fields = try XCTUnwrap(row["fields"] as? [String: Any])
            let announce = MeshAnnounce(
                nodeIdHex: string(fields, "node"), identityFingerprintHex: string(fields, "fp"),
                neighborNodeIdsHex: try XCTUnwrap(fields["nbrs"] as? [String])
            )
            XCTAssertEqual(String(decoding: announce.encode(), as: UTF8.self), string(row, "canonicalJson"), name)
            XCTAssertEqual(hex(announce.encode()), string(row, "canonicalJsonHex"), name)

            let packet = try XCTUnwrap(MeshPacket.decode(try bytes(string(row, "packetHex"))), name)
            XCTAssertEqual(packet.type, .announce)
            XCTAssertEqual(packet.recipientId, .broadcast)
            XCTAssertNil(packet.ttl)
            XCTAssertEqual(packet.senderId.hex, announce.nodeIdHex)
            XCTAssertEqual(packet.timestampMs, try XCTUnwrap((row["packetTimestampMs"] as? NSNumber)?.int64Value))
            let opened = try XCTUnwrap(MeshDiscoveryCipher.decrypt(packet.payload), name)
            XCTAssertEqual(MeshAnnounce.decode(opened), announce, name)
            XCTAssertEqual(packet.encode().count, int(row, "packetLength"), name)
        }
    }

    func testAnnounceWithAChallengeEncodesAndDecodesAsTheVectorsSay() throws {
        for row in try section("announceChallenge") {
            let name = string(row, "name")
            let announce = MeshAnnounce(
                nodeIdHex: string(row, "nodeIdHex"), identityFingerprintHex: string(row, "nodeIdHex"),
                neighborNodeIdsHex: try XCTUnwrap(row["neighborNodeIdsHex"] as? [String]),
                challengeHex: string(row, "challengeHex"), peerVerified: (row["peerVerified"] as? Bool) ?? false
            )
            XCTAssertEqual(hex(announce.encode()), string(row, "canonicalJsonHex"), name)
            let decoded = try XCTUnwrap(MeshAnnounce.decode(try bytes(string(row, "canonicalJsonHex"))), name)
            XCTAssertEqual(decoded.challengeHex, string(row, "challengeHex"), name)
            XCTAssertEqual(decoded.peerVerified, (row["peerVerified"] as? Bool) ?? false, name)
        }
        // A challenge that is not 32 lowercase hex characters reads as absent; the ANNOUNCE stays valid.
        let bad = Data(#"{"v":1,"node":"21fe31dfa154a261","fp":"21fe31dfa154a261","nbrs":[],"ch":"zz"}"#.utf8)
        XCTAssertNil(try XCTUnwrap(MeshAnnounce.decode(bad)).challengeHex)
    }

    func testTheProofVectorsMatchByteForByteAndVerify() throws {
        let proof = try XCTUnwrap(try vectors()["announceProof"] as? [String: Any])
        XCTAssertEqual(string(proof, "domainHex"), hex(MeshAnnounceProof.domain))
        XCTAssertEqual(int(proof, "payloadLength"), MeshAnnounceProof.payloadLength)
        XCTAssertEqual(int(proof, "signedBytesLength"), MeshAnnounceProof.messageLength)
        for row in try XCTUnwrap(proof["cases"] as? [[String: Any]]) {
            let name = string(row, "name")
            let prover = try MeshNodeId(hex: string(row, "proverNodeIdHex"))
            let verifier = try MeshNodeId(hex: string(row, "verifierNodeIdHex"))
            let central = (row["proverIsCentral"] as? Bool) ?? false
            let proverNonce = try bytes(string(row, "proverNonceHex"))
            let verifierNonce = try bytes(string(row, "verifierNonceHex"))
            let message = try XCTUnwrap(MeshAnnounceProof.message(prover: prover, verifier: verifier, proverNonce: proverNonce,
                                                                  verifierNonce: verifierNonce, proverIsCentral: central), name)
            XCTAssertEqual(hex(message), string(row, "signedBytesHex"), name)
            // CryptoKit hedges its Ed25519 signatures with fresh randomness, so its bytes differ from run to run (the Android
            // library and the generator give the exact bytes of the vector). What must hold here: the vector's signature
            // verifies, and a signature made now verifies too.
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: try bytes(string(row, "proverSeedHex")))
            let vectorSignature = try bytes(string(row, "signatureHex"))
            XCTAssertTrue(key.publicKey.isValidSignature(vectorSignature, for: message), name)
            XCTAssertTrue(key.publicKey.isValidSignature(try key.signature(for: message), for: message), name)
            XCTAssertEqual(hex(key.publicKey.rawRepresentation), string(row, "proverPublicKeyHex"), name)
            let payload = try XCTUnwrap(MeshAnnounceProof.payload(publicKey: key.publicKey.rawRepresentation, signature: vectorSignature), name)
            XCTAssertEqual(hex(payload), string(row, "payloadHex"), name)
            XCTAssertEqual(MeshNodeId.from(identityKeyRaw: key.publicKey.rawRepresentation), prover, name)
            let packet = try MeshPacket(type: .announceProof, senderId: prover, recipientId: verifier,
                                        timestampMs: try XCTUnwrap((row["packetTimestampMs"] as? NSNumber)?.int64Value), payload: payload)
            XCTAssertEqual(hex(packet.encode()), string(row, "packetHex"), name)
            XCTAssertEqual(MeshPacket.decode(packet.encode()), packet, name)
            XCTAssertEqual(MeshAnnounceProof.verify(payload: payload, prover: prover, verifier: verifier, proverNonce: proverNonce,
                                                    verifierNonce: verifierNonce, proverIsCentral: central), .ok, name)
        }
        // A signature made by CryptoKit on iOS (hedged, so not the deterministic bytes of the cases) is one of the vectors: it must
        // verify on every platform.
        let cases = try XCTUnwrap(proof["cases"] as? [[String: Any]])
        for external in try XCTUnwrap(proof["externalSignatures"] as? [[String: Any]]) {
            let name = string(external, "name")
            let row = try XCTUnwrap(cases.first { string($0, "name") == string(external, "caseName") }, name)
            XCTAssertNotEqual(string(external, "signatureHex"), string(row, "signatureHex"), name)
            let payload = try XCTUnwrap(MeshAnnounceProof.payload(publicKey: try bytes(string(row, "proverPublicKeyHex")),
                                                                  signature: try bytes(string(external, "signatureHex"))), name)
            XCTAssertEqual(MeshAnnounceProof.verify(
                payload: payload, prover: try MeshNodeId(hex: string(row, "proverNodeIdHex")),
                verifier: try MeshNodeId(hex: string(row, "verifierNodeIdHex")), proverNonce: try bytes(string(row, "proverNonceHex")),
                verifierNonce: try bytes(string(row, "verifierNonceHex")), proverIsCentral: (row["proverIsCentral"] as? Bool) ?? false
            ), .ok, name)
        }
        for row in try XCTUnwrap(proof["negatives"] as? [[String: Any]]) {
            let name = string(row, "name")
            let result = MeshAnnounceProof.verify(
                payload: try bytes(string(row, "payloadHex")), prover: try MeshNodeId(hex: string(row, "proverNodeIdHex")),
                verifier: try MeshNodeId(hex: string(row, "verifierNodeIdHex")), proverNonce: try bytes(string(row, "proverNonceHex")),
                verifierNonce: try bytes(string(row, "verifierNonceHex")), proverIsCentral: (row["proverIsCentral"] as? Bool) ?? false
            )
            XCTAssertNotEqual(result, .ok, name)
        }
    }

    func testAnnounceDecryptNegativeIsRejected() throws {
        for row in try section("announceDecryptNegative") {
            let name = string(row, "name")
            XCTAssertNil(MeshDiscoveryCipher.decrypt(try bytes(string(row, "wireHex"))), name)
        }
    }

    func testAnnounceJsonAcceptTolerance() throws {
        for row in try section("announceJsonAccept") {
            let name = string(row, "name")
            let expect = try XCTUnwrap(row["expect"] as? [String: Any])
            let announce = try XCTUnwrap(MeshAnnounce.decode(Data(string(row, "json").utf8)), name)
            XCTAssertEqual(announce.version, int(expect, "v"), name)
            XCTAssertEqual(announce.nodeIdHex, string(expect, "node"), name)
            XCTAssertEqual(announce.identityFingerprintHex, string(expect, "fp"), name)
            XCTAssertEqual(announce.displayHint, expect["hint"] as? String, name)
            XCTAssertEqual(announce.neighborNodeIdsHex, try XCTUnwrap(expect["nbrs"] as? [String]), name)
        }
    }

    func testAnnounceJsonRejects() throws {
        for row in try section("announceJsonReject") {
            let name = string(row, "name")
            XCTAssertNil(MeshAnnounce.decode(Data(string(row, "json").utf8)), name)
        }
    }

    func testAnnounceJsonEdges() {
        let a = "21fe31dfa154a261"
        func decode(_ json: String) -> MeshAnnounce? { MeshAnnounce.decode(Data(json.utf8)) }
        func decode(_ data: Data) -> MeshAnnounce? { MeshAnnounce.decode(data) }
        // Broadcast is never a node.
        XCTAssertNil(decode(#"{"v":1,"node":"ffffffffffffffff","fp":"\#(a)","nbrs":[]}"#))
        // v must be the number 1.
        XCTAssertNil(decode(#"{"v":"1","node":"\#(a)","fp":"\#(a)"}"#))
        XCTAssertNil(decode(#"{"v":true,"node":"\#(a)","fp":"\#(a)"}"#))
        // v is the integer 1 exactly as written.
        XCTAssertNil(decode(#"{"v":1.0,"node":"\#(a)","fp":"\#(a)"}"#))
        XCTAssertNil(decode(#"{"v":1e0,"node":"\#(a)","fp":"\#(a)"}"#))
        XCTAssertNotNil(decode(#"{ "v" : 1 , "node":"\#(a)","fp":"\#(a)"}"#))
        // nbrs, when present, must be an array.
        XCTAssertNil(decode(#"{"v":1,"node":"\#(a)","fp":"\#(a)","nbrs":null}"#))
        XCTAssertNil(decode(#"{"v":1,"node":"\#(a)","fp":"\#(a)","nbrs":"x"}"#))
        XCTAssertNil(decode(#"{"v":1,"node":"\#(a)","fp":"\#(a)","nbrs":{}}"#))
        XCTAssertNil(decode(#"{"v":1,"node":"\#(a)","fp":"\#(a)","nbrs":7}"#))
        // A nested member named v or nbrs, or a string that looks like one, is not the top-level member.
        XCTAssertNotNil(decode(#"{"x":{"v":2,"nbrs":3},"v":1,"hint":"\"v\":2","node":"\#(a)","fp":"\#(a)"}"#))
        XCTAssertNil(decode(Data()))
        // Bad neighbour entries are ignored, the rest kept; only the first ten entries are looked at.
        let good = "39f713d0a644253f"
        XCTAssertEqual(decode(#"{"v":1,"node":"\#(a)","fp":"\#(a)","nbrs":["zz",5,"\#(good)",null]}"#)?.neighborNodeIdsHex, [good])
        let twelve = (0..<12).map { String(format: "%016x", $0 + 1) }
        let list = twelve.map { "\"\($0)\"" }.joined(separator: ",")
        XCTAssertEqual(decode(#"{"v":1,"node":"\#(a)","fp":"\#(a)","nbrs":[\#(list)]}"#)?.neighborNodeIdsHex.count, 10)
        // Invalid entries are dropped first, then the first ten valid ones are kept.
        let junk = (0..<5).map { _ in "\"zz\"" }.joined(separator: ",")
        let mixed = decode(#"{"v":1,"node":"\#(a)","fp":"\#(a)","nbrs":[\#(junk),\#(list)]}"#)
        XCTAssertEqual(mixed?.neighborNodeIdsHex, Array(twelve.prefix(10)))
        // A hint of another type reads as absent, not as a failure.
        XCTAssertNil(decode(#"{"v":1,"node":"\#(a)","fp":"\#(a)","hint":7}"#)?.displayHint)
        XCTAssertNotNil(decode(#"{"v":1,"node":"\#(a)","fp":"\#(a)","hint":7}"#))
        // The sender never writes more than ten neighbours.
        let many = MeshAnnounce(nodeIdHex: a, identityFingerprintHex: a, neighborNodeIdsHex: twelve)
        XCTAssertEqual(MeshAnnounce.decode(many.encode())?.neighborNodeIdsHex.count, 10)
    }

    // MARK: - envelope / receipt / shell

    func testEnvelopeCanonicalJsonAndVariants() throws {
        let env = try XCTUnwrap(try vectors()["envelope"] as? [String: Any])
        let f = try XCTUnwrap(env["fields"] as? [String: Any])
        let message = MeshChatMessage(
            senderUserId: string(f, "s"), recipientUserId: string(f, "r"), clientMsgId: string(f, "c"),
            conversationId: string(f, "conv"), body: string(f, "b"),
            sentAtMs: try XCTUnwrap((f["ts"] as? NSNumber)?.int64Value),
            senderNodeHex: string(f, "sn"), recipientNodeHex: string(f, "rn")
        )
        XCTAssertEqual(String(decoding: message.encode(), as: UTF8.self), string(env, "canonicalJson"))
        XCTAssertEqual(hex(message.encode()), string(env, "canonicalJsonHex"))
        XCTAssertEqual(MeshChatMessage.decode(message.encode()), message)
        for variant in try XCTUnwrap(env["acceptedVariants"] as? [[String: Any]]) {
            let name = string(variant, "name")
            XCTAssertEqual(MeshChatMessage.decode(Data(string(variant, "json").utf8)), message, name)
        }
        for reject in try XCTUnwrap(env["reject"] as? [[String: Any]]) {
            let name = string(reject, "name")
            XCTAssertNil(MeshChatMessage.decode(Data(string(reject, "json").utf8)), name)
        }
    }

    func testReceiptCanonicalJsonAndRejects() throws {
        let rec = try XCTUnwrap(try vectors()["receipt"] as? [String: Any])
        let f = try XCTUnwrap(rec["fields"] as? [String: Any])
        let kinds = try XCTUnwrap(rec["kinds"] as? [String: String])
        XCTAssertEqual(kinds["delivered"], MeshReceipt.kindDelivered)
        XCTAssertEqual(kinds["read"], MeshReceipt.kindRead)
        let receipt = MeshReceipt(
            senderUserId: string(f, "s"), recipientUserId: string(f, "r"), receiptId: string(f, "c"),
            messageClientMsgId: string(f, "m"), kind: string(f, "k"),
            atMs: try XCTUnwrap((f["ts"] as? NSNumber)?.int64Value),
            senderNodeHex: string(f, "sn"), recipientNodeHex: string(f, "rn")
        )
        XCTAssertEqual(String(decoding: receipt.encode(), as: UTF8.self), string(rec, "canonicalJson"))
        XCTAssertEqual(hex(receipt.encode()), string(rec, "canonicalJsonHex"))
        XCTAssertEqual(MeshReceipt.decode(receipt.encode()), receipt)
        for reject in try XCTUnwrap(rec["reject"] as? [[String: Any]]) {
            let name = string(reject, "name")
            XCTAssertNil(MeshReceipt.decode(Data(string(reject, "json").utf8)), name)
        }
    }

    func testShellCanonicalJson() throws {
        for row in try section("shell") {
            let name = string(row, "name")
            let f = try XCTUnwrap(row["fields"] as? [String: Any])
            let shell = MeshSealedShell(clientMsgId: string(f, "c"), sealedB64: string(f, "e"))
            XCTAssertEqual(String(decoding: shell.encode(), as: UTF8.self), string(row, "canonicalJson"), name)
            XCTAssertEqual(hex(shell.encode()), string(row, "canonicalJsonHex"), name)
            XCTAssertEqual(MeshSealedShell.decode(shell.encode()), shell, name)
        }
    }

    // MARK: - aad

    func testAssociatedDataStrings() throws {
        for row in try section("aad") {
            let name = string(row, "name")
            let aad = meshPacketAad(
                version: int(row, "version"), typeWireCode: UInt8(int(row, "type")),
                senderId: try MeshNodeId(hex: string(row, "senderId")),
                recipientId: try MeshNodeId(hex: string(row, "recipientId"))
            )
            XCTAssertEqual(String(decoding: aad, as: UTF8.self), string(row, "aadUtf8"), name)
            XCTAssertEqual(hex(aad), string(row, "aadHex"), name)
        }
    }

    // MARK: - frames / frameLimits

    func testFrameSplittingMatchesTheVectors() throws {
        for row in try section("frames") {
            let name = "\(string(row, "packet")) @\(int(row, "attValueMax"))"
            let packet = try bytes(string(row, "packetHex"))
            XCTAssertEqual(packet.count, int(row, "packetLength"), name)
            let limit = int(row, "attValueMax")
            XCTAssertEqual(MeshLinkFraming.chunkBytes(valueLimit: limit), int(row, "chunkBytes"), name)
            let expected = try XCTUnwrap(row["framesHex"] as? [String], name)
            let frames = try MeshLinkFraming.split(packet, valueLimit: limit, setId: UInt16(int(row, "setId"))).get()
            XCTAssertEqual(frames.map(hex), expected, name)
            XCTAssertEqual(frames.count, int(row, "frameCount"), name)
            XCTAssertEqual(MeshLinkFraming.frameCount(packetLength: packet.count, valueLimit: limit), frames.count, name)
            for frame in frames { XCTAssertLessThanOrEqual(frame.count, limit, name) }
            // Reassembles to the same packet.
            var reassembler = MeshLinkReassembler()
            var done: Data?
            for frame in frames {
                if case .complete(let whole) = reassembler.offer(frame, nowMs: 0).status { done = whole }
            }
            XCTAssertEqual(done, packet, name)
        }
    }

    func testFrameLimits() throws {
        for row in try section("frameLimits") {
            let name = string(row, "name")
            let limit = int(row, "attValueMax")
            switch (row["expect"] as? String) ?? "largest_packet" {
            case "frame_count_overflow":
                let packet = Data(count: int(row, "packetLength"))
                if case .failure(let error) = MeshLinkFraming.split(packet, valueLimit: limit, setId: 1) {
                    XCTAssertEqual(error, .tooManyFrames, name)
                } else {
                    XCTFail(name)
                }
                XCTAssertNil(MeshLinkFraming.frameCount(packetLength: packet.count, valueLimit: limit), name)
                let needed = (packet.count + limit - 5) / (limit - 4)
                XCTAssertEqual(needed, int(row, "framesNeeded"), name)
            case "ok":
                let packet = Data(count: int(row, "packetLength"))
                let frames = try MeshLinkFraming.split(packet, valueLimit: limit, setId: 1).get()
                XCTAssertEqual(frames.count, int(row, "framesNeeded"), name)
            case "link_too_small":
                if case .failure(let error) = MeshLinkFraming.split(Data("x".utf8), valueLimit: limit, setId: 1) {
                    XCTAssertEqual(error, .linkTooSmall, name)
                } else {
                    XCTFail(name)
                }
            default:
                // "largest_packet_at_att_20": 255 frames of 16 bytes fit, one byte more does not.
                let largest = int(row, "maxPacketLength")
                XCTAssertEqual(largest, 255 * 16, name)
                XCTAssertNotNil(MeshLinkFraming.frameCount(packetLength: largest, valueLimit: limit), name)
                XCTAssertNil(MeshLinkFraming.frameCount(packetLength: largest + 1, valueLimit: limit), name)
            }
        }
    }

    // MARK: - reassembly

    func testReassemblyScenarios() throws {
        let rows = try section("reassembly")
        XCTAssertEqual(rows.count, 9)
        for row in rows {
            let name = string(row, "name")
            let frames = try XCTUnwrap(row["framesHex"] as? [String]).map { try bytes($0) }
            let expectedStatuses = try XCTUnwrap(row["statuses"] as? [String])
            let expectedDone = try XCTUnwrap(row["completedPacketsHex"] as? [String])
            var reassembler = MeshLinkReassembler()
            var statuses: [String] = []
            var done: [String] = []
            for frame in frames {
                let status = reassembler.offer(frame, nowMs: 0).status
                statuses.append(status.vectorToken)
                if case .complete(let packet) = status { done.append(hex(packet)) }
            }
            XCTAssertEqual(statuses, expectedStatuses, name)
            XCTAssertEqual(done, expectedDone, name)
            XCTAssertEqual(reassembler.pendingSetCount, int(row, "pendingSetsAtEnd"), name)
        }
    }

    // MARK: - relayProbability

    func testRelayProbabilityTable() throws {
        let rows = try section("relayProbability")
        XCTAssertEqual(rows.count, 24)
        for row in rows {
            let peers = int(row, "visiblePeers")
            let ttl = int(row, "ttl")
            let expected = try XCTUnwrap((row["probability"] as? NSNumber)?.doubleValue)
            XCTAssertEqual(MeshRelayPolicy.relayProbability(visiblePeerCount: peers, ttl: ttl), expected, accuracy: 1e-9,
                           "peers \(peers) ttl \(ttl)")
        }
    }
}
