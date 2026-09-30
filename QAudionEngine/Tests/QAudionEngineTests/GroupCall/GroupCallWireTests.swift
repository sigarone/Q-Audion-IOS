import XCTest
@testable import QAudionEngine

final class GroupCallWireTests: XCTestCase {

    func testHex128() {
        XCTAssertTrue(GroupCallWire.isHex128(GroupCallFixtures.pseudoA))
        XCTAssertFalse(GroupCallWire.isHex128(String(repeating: "A1", count: 16)), "upper case is not the wire form")
        XCTAssertFalse(GroupCallWire.isHex128(String(repeating: "a1", count: 15)))
        XCTAssertFalse(GroupCallWire.isHex128(String(repeating: "g1", count: 16)))
        XCTAssertFalse(GroupCallWire.isHex128(""))
    }

    func testMediaReadyParsesAllFields() throws {
        let ready = try XCTUnwrap(GroupCallWire.MediaReady.parse(GroupCallFixtures.readyDictionary()))
        XCTAssertEqual(ready.nodeId, "node-a")
        XCTAssertEqual(ready.wsUrl, "wss://media.example.invalid/janus")
        XCTAssertEqual(ready.room, GroupCallFixtures.room)
        XCTAssertEqual(ready.pseudonym, GroupCallFixtures.pseudoA)
        XCTAssertEqual(ready.joinToken, GroupCallFixtures.joinToken)
        XCTAssertEqual(ready.ttlSeconds, 21600)
        XCTAssertEqual(ready.iceServers.count, 1)
        XCTAssertEqual(ready.iceServers[0].urls.count, 2)
        XCTAssertEqual(ready.iceServers[0].username, "user")
        XCTAssertEqual(ready.dtlsFingerprint, GroupCallFixtures.fingerprint())
    }

    func testMediaReadyNormalisesTheFingerprint() throws {
        let lower = "SHA-256 " + Array(repeating: "ab", count: 32).joined(separator: ":")
        let ready = try XCTUnwrap(GroupCallWire.MediaReady.parse(GroupCallFixtures.readyDictionary(fingerprint: lower)))
        XCTAssertEqual(ready.dtlsFingerprint, GroupCallFixtures.fingerprint("AB"))
    }

    func testMediaReadyRefusesAPlainWebSocketUrl() {
        XCTAssertNil(GroupCallWire.MediaReady.parse(GroupCallFixtures.readyDictionary(wsUrl: "ws://media.example.invalid/janus")))
        XCTAssertNil(GroupCallWire.MediaReady.parse(GroupCallFixtures.readyDictionary(wsUrl: "https://media.example.invalid/janus")))
        XCTAssertNil(GroupCallWire.MediaReady.parse(GroupCallFixtures.readyDictionary(wsUrl: "not a url")))
    }

    func testMediaReadyRefusesABadPseudonymOrFingerprint() {
        XCTAssertNil(GroupCallWire.MediaReady.parse(GroupCallFixtures.readyDictionary(pseudonym: "short")))
        XCTAssertNil(GroupCallWire.MediaReady.parse(GroupCallFixtures.readyDictionary(fingerprint: "sha-1 AA:BB")))
        XCTAssertNil(GroupCallWire.MediaReady.parse(GroupCallFixtures.readyDictionary(fingerprint: "")))
    }

    func testMediaReadyRefusesMissingFields() {
        for key in ["call_id", "node_id", "ws_url", "room", "pseudonym", "session_token", "join_token", "dtls_fingerprint"] {
            var dictionary = GroupCallFixtures.readyDictionary()
            dictionary[key] = nil
            XCTAssertNil(GroupCallWire.MediaReady.parse(dictionary), "missing \(key)")
        }
    }

    func testIceServerUrlsMayBeASingleString() throws {
        var dictionary = GroupCallFixtures.readyDictionary()
        dictionary["ice_servers"] = [["urls": "turn:turn.example.invalid:3478", "username": "u", "credential": "c"]]
        let ready = try XCTUnwrap(GroupCallWire.MediaReady.parse(dictionary))
        XCTAssertEqual(ready.iceServers.first?.urls, ["turn:turn.example.invalid:3478"])
    }

    func testUnavailableReasons() {
        XCTAssertEqual(GroupCallWire.UnavailableReason(wire: "no_node"), .noNode)
        XCTAssertEqual(GroupCallWire.UnavailableReason(wire: "room_create_failed"), .roomCreateFailed)
        XCTAssertEqual(GroupCallWire.UnavailableReason(wire: "not_member"), .notMember)
        XCTAssertEqual(GroupCallWire.UnavailableReason(wire: "full"), .full)
        XCTAssertEqual(GroupCallWire.UnavailableReason(wire: "throttled"), .throttled)
        XCTAssertEqual(GroupCallWire.UnavailableReason(wire: "surprise"), .other("surprise"))
        XCTAssertTrue(GroupCallWire.UnavailableReason.throttled.isTransient)
        XCTAssertFalse(GroupCallWire.UnavailableReason.full.isTransient)
    }

    func testMediaTokenParsesAndRefusesMissingFields() throws {
        let token = try XCTUnwrap(GroupCallWire.MediaToken.parse(["call_id": "c1", "session_token": "tok-2", "ttl_s": 600]))
        XCTAssertEqual(token, GroupCallWire.MediaToken(callId: "c1", sessionToken: "tok-2", ttlSeconds: 600))
        XCTAssertEqual(GroupCallWire.MediaToken.parse(["call_id": "c1", "session_token": "tok-2"])?.ttlSeconds, 0)
        XCTAssertNil(GroupCallWire.MediaToken.parse(["session_token": "tok-2", "ttl_s": 600]))
        XCTAssertNil(GroupCallWire.MediaToken.parse(["call_id": "c1", "ttl_s": 600]))
        XCTAssertNil(GroupCallWire.MediaToken.parse(["call_id": "c1", "session_token": "", "ttl_s": 600]))
        XCTAssertNil(GroupCallWire.MediaToken.parse(["call_id": "", "session_token": "tok-2"]))
    }

    func testUpdateParsesEpochNodeAndPseudonyms() throws {
        let update = try XCTUnwrap(GroupCallWire.Update.parse([
            "call_id": "call-1",
            "participants": ["u1", "u2"],
            "sender_key_epoch": 7,
            "media": ["node_id": "node-a", "pseudonyms": ["u1": GroupCallFixtures.pseudoA, "u2": GroupCallFixtures.pseudoB]],
        ]))
        XCTAssertEqual(update.epoch, 7)
        XCTAssertEqual(update.nodeId, "node-a")
        XCTAssertEqual(update.participants, ["u1", "u2"])
        XCTAssertEqual(update.userByPseudonym[GroupCallFixtures.pseudoB], "u2")
    }

    func testUpdateWithoutMediaHasNoPseudonyms() throws {
        let update = try XCTUnwrap(GroupCallWire.Update.parse([
            "call_id": "call-1", "participants": ["u1"], "sender_key_epoch": 1,
        ]))
        XCTAssertNil(update.nodeId)
        XCTAssertTrue(update.pseudonyms.isEmpty)
    }

    func testUpdateDropsMalformedPseudonymsAndRefusesBadEpochs() {
        let update = GroupCallWire.Update.parse([
            "call_id": "call-1", "participants": ["u1", "u2"], "sender_key_epoch": 2,
            "media": ["node_id": "n", "pseudonyms": ["u1": "nothex", "u2": GroupCallFixtures.pseudoB]],
        ])
        XCTAssertEqual(update?.pseudonyms, ["u2": GroupCallFixtures.pseudoB])
        XCTAssertNil(GroupCallWire.Update.parse(["call_id": "c", "participants": ["u"], "sender_key_epoch": -1]))
        XCTAssertNil(GroupCallWire.Update.parse(["call_id": "c", "participants": ["u"], "sender_key_epoch": 4_294_967_296]))
        XCTAssertNil(GroupCallWire.Update.parse(["call_id": "c", "participants": ["u"]]), "v1 updates without an epoch are refused")
    }
}
