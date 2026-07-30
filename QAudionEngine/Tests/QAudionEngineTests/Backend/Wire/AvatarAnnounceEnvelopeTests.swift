import XCTest
@testable import QAudionEngine

/// Wire-format parity tests for ``AvatarAnnounceEnvelope`` — mirrors
/// ``AttachAnnounceEnvelopeTests`` structure. The expected JSON shape
/// MUST match whatever Android/Desktop implement for parity (task
/// #33/#34) — see `docs/E2EE_AVATAR_TRANSPORT_DESIGN.md`.
final class AvatarAnnounceEnvelopeTests: XCTestCase {

    func test_parse_wellFormed() throws {
        let json = """
        {
          "qa_ctl": 1,
          "t": "avatar_announce",
          "att": {
            "id": "AAECAwQFBgcICQoLDA0ODw==",
            "mime": "image/jpeg",
            "byte_length": 41234,
            "sha256_b64": "aGVsbG8gd29ybGQK",
            "file_id": "01940000-0000-7000-8000-aaaabbbbcccc",
            "version": 3
          },
          "ts": 1785400000
        }
        """
        let env = try AvatarAnnounceEnvelope.parse(json)
        XCTAssertNotNil(env)
        // Safe: nil-checked above; JSON literal is well-formed and matches schema.
        // swiftlint:disable:next force_unwrapping
        XCTAssertEqual(env!.att.id, "AAECAwQFBgcICQoLDA0ODw==")
        // swiftlint:disable:next force_unwrapping
        XCTAssertEqual(env!.att.mime, "image/jpeg")
        // swiftlint:disable:next force_unwrapping
        XCTAssertEqual(env!.att.byteLength, 41234)
        // swiftlint:disable:next force_unwrapping
        XCTAssertEqual(env!.att.sha256B64, "aGVsbG8gd29ybGQK")
        // swiftlint:disable:next force_unwrapping
        XCTAssertEqual(env!.att.fileId, "01940000-0000-7000-8000-aaaabbbbcccc")
        // swiftlint:disable:next force_unwrapping
        XCTAssertEqual(env!.att.version, 3)
        // swiftlint:disable:next force_unwrapping
        XCTAssertEqual(env!.ts, 1785400000)
    }

    func test_roundTrip_encodeThenDecode_preservesAllFields() throws {
        let meta = AvatarAnnounceMeta(
            id: "AAECAwQFBgcICQoLDA0ODw==",
            mime: "image/jpeg",
            byteLength: 41234,
            sha256B64: "aGVsbG8gd29ybGQK",
            fileId: "file-abc",
            version: 7
        )
        let original = AvatarAnnounceEnvelope(att: meta, ts: 1785400000)
        let wire = try original.toJsonString()
        let decoded = try AvatarAnnounceEnvelope.parse(wire)
        XCTAssertEqual(decoded, original)
    }

    func test_parse_returnsNilForNonQaCtl() throws {
        let json = "{\"random\":\"object\"}"
        XCTAssertNil(try AvatarAnnounceEnvelope.parse(json))
    }

    func test_parse_returnsNilForOtherQaCtlVariants() throws {
        // Must not collide with attach_announce or any control envelope.
        let json = """
        {"qa_ctl":1,"t":"attach_announce","att":{
          "id":"x","mime":"audio/opus","byte_length":1,"sha256_b64":"x","file_id":"y"}}
        """
        XCTAssertNil(try AvatarAnnounceEnvelope.parse(json))
    }

    func test_parse_throwsOnMissingId() throws {
        let json = """
        {"qa_ctl":1,"t":"avatar_announce","att":{
          "mime":"image/jpeg","byte_length":1,"sha256_b64":"x","file_id":"y","version":1}}
        """
        XCTAssertThrowsError(try AvatarAnnounceEnvelope.parse(json))
    }

    func test_parse_throwsOnMissingVersion() throws {
        let json = """
        {"qa_ctl":1,"t":"avatar_announce","att":{
          "id":"x","mime":"image/jpeg","byte_length":1,"sha256_b64":"x","file_id":"y"}}
        """
        XCTAssertThrowsError(try AvatarAnnounceEnvelope.parse(json))
    }

    func test_parse_throwsOnNegativeVersion() throws {
        let json = """
        {"qa_ctl":1,"t":"avatar_announce","att":{
          "id":"x","mime":"image/jpeg","byte_length":1,"sha256_b64":"x","file_id":"y","version":-1}}
        """
        XCTAssertThrowsError(try AvatarAnnounceEnvelope.parse(json))
    }

    func test_validate_rejectsEmptyId() {
        let meta = AvatarAnnounceMeta(
            id: "", mime: "image/jpeg", byteLength: 1,
            sha256B64: "x", fileId: "y", version: 0
        )
        XCTAssertThrowsError(try meta.validate())
    }
}
