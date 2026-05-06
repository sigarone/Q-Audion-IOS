import XCTest
@testable import QAudionEngine

/// Wire-format parity tests for ``AttachAnnounceEnvelope``.
///
/// The expected JSON shape MUST match Desktop TS (commit `d28686c`)
/// and Android Kotlin (commit `fddd6a18`) — when adding fields here,
/// add them in BOTH other implementations + WIRE_SPEC §3.6.3.
final class AttachAnnounceEnvelopeTests: XCTestCase {

    func test_parse_voiceNoteWithDuration() throws {
        let json = """
        {
          "qa_ctl": 1,
          "t": "attach_announce",
          "att": {
            "id": "AAECAwQFBgcICQoLDA0ODw==",
            "mime": "audio/opus",
            "byte_length": 12345,
            "sha256_b64": "aGVsbG8gd29ybGQK",
            "file_id": "01940000-0000-7000-8000-aaaabbbbcccc",
            "duration_ms": 5234
          },
          "ts": 1700000000
        }
        """
        let env = try AttachAnnounceEnvelope.parse(json)
        XCTAssertNotNil(env)
        XCTAssertEqual(env!.att.id, "AAECAwQFBgcICQoLDA0ODw==")
        XCTAssertEqual(env!.att.mime, "audio/opus")
        XCTAssertEqual(env!.att.byteLength, 12345)
        XCTAssertEqual(env!.att.sha256B64, "aGVsbG8gd29ybGQK")
        XCTAssertEqual(env!.att.fileId, "01940000-0000-7000-8000-aaaabbbbcccc")
        XCTAssertEqual(env!.att.durationMs, 5234)
        XCTAssertEqual(env!.ts, 1700000000)
    }

    func test_parse_nonVoiceWithoutDuration() throws {
        let json = """
        {
          "qa_ctl": 1, "t": "attach_announce",
          "att": {
            "id": "X", "mime": "image/jpeg", "byte_length": 99,
            "sha256_b64": "Y", "file_id": "f1"
          }
        }
        """
        let env = try AttachAnnounceEnvelope.parse(json)
        XCTAssertNotNil(env)
        XCTAssertNil(env!.att.durationMs)
    }

    func test_parse_returnsNilForNonQaCtl() throws {
        let json = "{\"random\":\"object\"}"
        XCTAssertNil(try AttachAnnounceEnvelope.parse(json))
    }

    func test_parse_returnsNilForOtherQaCtlVariants() throws {
        let json = """
        {"qa_ctl":1,"t":"reaction","target":"cmid-1","emoji":"👍"}
        """
        XCTAssertNil(try AttachAnnounceEnvelope.parse(json))
    }

    func test_parse_throwsOnMissingId() throws {
        let json = """
        {"qa_ctl":1,"t":"attach_announce","att":{
          "mime":"audio/opus","byte_length":1,"sha256_b64":"x","file_id":"y"}}
        """
        XCTAssertThrowsError(try AttachAnnounceEnvelope.parse(json))
    }

    func test_parse_throwsOnNegativeByteLength() throws {
        let json = """
        {"qa_ctl":1,"t":"attach_announce","att":{
          "id":"a","mime":"m","byte_length":-1,"sha256_b64":"x","file_id":"y"}}
        """
        XCTAssertThrowsError(try AttachAnnounceEnvelope.parse(json))
    }

    func test_encode_buildsCanonicalWire() throws {
        let env = AttachAnnounceEnvelope(
            att: AttachAnnounceMeta(
                id: "AAECAwQFBgcICQoLDA0ODw==",
                mime: "audio/opus",
                byteLength: 999,
                sha256B64: "YWJjZA==",
                fileId: "01940000-0000-7000-8000-aaaabbbbcccc",
                durationMs: 3000
            ),
            ts: 1700000000
        )
        let wire = try env.toJsonString()
        XCTAssertTrue(wire.contains("\"qa_ctl\":1"))
        XCTAssertTrue(wire.contains("\"t\":\"attach_announce\""))
        XCTAssertTrue(wire.contains("\"id\":\"AAECAwQFBgcICQoLDA0ODw==\""))
        XCTAssertTrue(wire.contains("\"byte_length\":999"))
        XCTAssertTrue(wire.contains("\"sha256_b64\":\"YWJjZA==\""))
        XCTAssertTrue(wire.contains("\"file_id\":\"01940000-0000-7000-8000-aaaabbbbcccc\""))
        XCTAssertTrue(wire.contains("\"duration_ms\":3000"))
        XCTAssertTrue(wire.contains("\"ts\":1700000000"))
    }

    func test_roundTrip_encodeThenParse_preservesFields() throws {
        let original = AttachAnnounceEnvelope(
            att: AttachAnnounceMeta(
                id: "AAECAwQFBgcICQoLDA0ODw==",
                mime: "audio/opus",
                byteLength: 12345,
                sha256B64: "aGVsbG8K",
                fileId: "01940000-0000-7000-8000-aaaabbbbcccc",
                durationMs: 5234
            ),
            ts: 1700000000
        )
        let wire = try original.toJsonString()
        let parsed = try AttachAnnounceEnvelope.parse(wire)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed!.att, original.att)
        XCTAssertEqual(parsed!.ts, original.ts)
    }

    func test_validate_rejectsEmptyId() {
        let meta = AttachAnnounceMeta(id: "", mime: "m", byteLength: 1, sha256B64: "x", fileId: "y")
        XCTAssertThrowsError(try meta.validate())
    }

    func test_validate_rejectsNegativeDuration() {
        let meta = AttachAnnounceMeta(
            id: "a", mime: "m", byteLength: 1,
            sha256B64: "x", fileId: "y", durationMs: -1
        )
        XCTAssertThrowsError(try meta.validate())
    }
}
