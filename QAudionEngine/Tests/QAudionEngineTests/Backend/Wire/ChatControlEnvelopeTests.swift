import XCTest
@testable import QAudionEngine

/// Wire-format parity tests for the ``ChatControlEnvelope`` screenshot-lock
/// family (`ss_req` / `ss_resp` / `ss_lock`).
///
/// These variants are CONVERSATION-level (no `target` field) and must parse
/// even though every message-targeted variant (delete/edit/reaction) requires
/// `target`. Field shapes mirror Android
/// (`feature-chat/.../attachments/ChatControlEnvelope.kt`):
///   - `ss_req`  → no payload
///   - `ss_resp` → `approved: Bool`
///   - `ss_lock` → no payload
///
/// When adding fields here, mirror them in Android + Desktop + WIRE_SPEC.
final class ChatControlEnvelopeScreenshotTests: XCTestCase {

    // MARK: - ss_req

    func test_parse_ssReq_noPayload() throws {
        let json = #"{"qa_ctl":1,"t":"ss_req","ts":1700000000}"#
        let env = try ChatControlEnvelope.parse(json)
        XCTAssertEqual(env, .screenshotRequest(ts: 1_700_000_000))
    }

    func test_parse_ssReq_missingTsIsOptional() throws {
        let json = #"{"qa_ctl":1,"t":"ss_req"}"#
        let env = try ChatControlEnvelope.parse(json)
        XCTAssertEqual(env, .screenshotRequest(ts: nil))
    }

    // MARK: - ss_resp

    func test_parse_ssResp_approvedTrue() throws {
        let json = #"{"qa_ctl":1,"t":"ss_resp","approved":true,"ts":1700000001}"#
        let env = try ChatControlEnvelope.parse(json)
        XCTAssertEqual(env, .screenshotResponse(approved: true, ts: 1_700_000_001))
    }

    func test_parse_ssResp_approvedFalse() throws {
        let json = #"{"qa_ctl":1,"t":"ss_resp","approved":false,"ts":1700000002}"#
        let env = try ChatControlEnvelope.parse(json)
        XCTAssertEqual(env, .screenshotResponse(approved: false, ts: 1_700_000_002))
    }

    /// Security: a malformed / missing `approved` field MUST default to `false`
    /// (deny). Fail-closed for a security-sensitive unlock response — parity
    /// with Android's `env.approved ?: false`.
    func test_parse_ssResp_missingApproved_deniesByDefault() throws {
        let json = #"{"qa_ctl":1,"t":"ss_resp","ts":1700000003}"#
        let env = try ChatControlEnvelope.parse(json)
        XCTAssertEqual(env, .screenshotResponse(approved: false, ts: 1_700_000_003))
    }

    func test_parse_ssResp_nonBoolApproved_deniesByDefault() throws {
        // `approved` present but not a bool → must NOT be treated as granted.
        let json = #"{"qa_ctl":1,"t":"ss_resp","approved":"yes"}"#
        let env = try ChatControlEnvelope.parse(json)
        XCTAssertEqual(env, .screenshotResponse(approved: false, ts: nil))
    }

    /// Security regression guard: a crafted numeric `approved:1` must NOT be
    /// coerced into a grant (a plain JSON number is not a JSON boolean).
    /// Parity with Android/Desktop where `1` deserializes to null → deny.
    func test_parse_ssResp_numericApproved_deniesByDefault() throws {
        let jsonOne = #"{"qa_ctl":1,"t":"ss_resp","approved":1}"#
        XCTAssertEqual(
            try ChatControlEnvelope.parse(jsonOne),
            .screenshotResponse(approved: false, ts: nil)
        )
        let jsonZero = #"{"qa_ctl":1,"t":"ss_resp","approved":0}"#
        XCTAssertEqual(
            try ChatControlEnvelope.parse(jsonZero),
            .screenshotResponse(approved: false, ts: nil)
        )
    }

    // MARK: - ss_lock

    func test_parse_ssLock_noPayload() throws {
        let json = #"{"qa_ctl":1,"t":"ss_lock","ts":1700000004}"#
        let env = try ChatControlEnvelope.parse(json)
        XCTAssertEqual(env, .screenshotLock(ts: 1_700_000_004))
    }

    // MARK: - Screenshot family requires NO target

    /// Regression guard: the screenshot family must be handled BEFORE the
    /// target-extraction guard, so a payload-less `ss_*` envelope must NOT
    /// throw `missingField("target")`.
    func test_parse_screenshotFamily_doesNotRequireTarget() throws {
        for t in ["ss_req", "ss_resp", "ss_lock"] {
            let json = #"{"qa_ctl":1,"t":"\#(t)"}"#
            XCTAssertNoThrow(
                try ChatControlEnvelope.parse(json),
                "\(t) must parse without a target field"
            )
        }
    }

    // MARK: - Round-trip (encode → decode)

    func test_roundTrip_ssReq() throws {
        let original = ChatControlEnvelope.screenshotRequest(ts: 1_700_000_010)
        let json = try original.toJsonString()
        XCTAssertTrue(json.contains(#""t":"ss_req""#))
        let decoded = try ChatControlEnvelope.parse(json)
        XCTAssertEqual(decoded, original)
    }

    func test_roundTrip_ssResp() throws {
        let original = ChatControlEnvelope.screenshotResponse(approved: true, ts: 1_700_000_011)
        let json = try original.toJsonString()
        XCTAssertTrue(json.contains(#""t":"ss_resp""#))
        XCTAssertTrue(json.contains(#""approved":true"#))
        let decoded = try ChatControlEnvelope.parse(json)
        XCTAssertEqual(decoded, original)
    }

    func test_roundTrip_ssLock() throws {
        let original = ChatControlEnvelope.screenshotLock(ts: 1_700_000_012)
        let json = try original.toJsonString()
        XCTAssertTrue(json.contains(#""t":"ss_lock""#))
        let decoded = try ChatControlEnvelope.parse(json)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Silent-drop fallback intact for still-unknown types

    /// Signal-not-kill: a qa_ctl:1 envelope with a type we still don't know
    /// (e.g. a future variant) must throw `unknownVariant` — the AppState
    /// caller uses `try?`, so this surfaces as a silent drop, never a crash
    /// and never blocking the message stream.
    func test_parse_unknownVariant_stillThrows() {
        let json = #"{"qa_ctl":1,"t":"totally_new_variant","target":"x"}"#
        XCTAssertThrowsError(try ChatControlEnvelope.parse(json)) { err in
            guard case ChatControlEnvelope.Error.unknownVariant(let t) = err else {
                XCTFail("Expected .unknownVariant, got \(err)"); return
            }
            XCTAssertEqual(t, "totally_new_variant")
        }
    }

    /// Existing variants must remain unaffected by the screenshot additions.
    func test_parse_existingDeleteVariant_unaffected() throws {
        let json = #"{"qa_ctl":1,"t":"delete","target":"cmid-1","ts":1700000020}"#
        let env = try ChatControlEnvelope.parse(json)
        XCTAssertEqual(env, .delete(target: "cmid-1", ts: 1_700_000_020))
    }
}
