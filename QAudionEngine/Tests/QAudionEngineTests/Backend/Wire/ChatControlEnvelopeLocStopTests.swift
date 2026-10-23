import XCTest
@testable import QAudionEngine

/// The `loc_stop` variant of the control envelope (WIRE_SPEC section 14.7) through `ChatControlEnvelope` itself: the vectors of
/// `stop_cases` of `location-kat.json` (the strict byte profile, not `JSONSerialization`), the canonical text of the builder, and the
/// entry-point rule of section 14.3.6 through `FileV2ChatBody.isUserTextAllowed`.
final class ChatControlEnvelopeLocStopTests: XCTestCase {

    func testEveryStopReceiverVectorThroughTheEnvelope() throws {
        let vectors = try XCTUnwrap(LocationKat.object(try LocationKat.load(), "stop_cases")["receiver_cases"] as? [[String: Any]])
        XCTAssertEqual(vectors.count, 28)
        for vector in vectors {
            let name = vector["name"] as? String ?? "?"
            // The envelope parser takes text; a vector whose bytes are not UTF-8 never reaches it (nothing decodes to text).
            guard let text = String(data: LocationKat.bodyBytes(vector), encoding: .utf8) else {
                XCTAssertEqual(vector["reason"] as? String, "utf8", name)
                continue
            }
            switch vector["expect"] as? String {
            case "valid":
                let envelope = try ChatControlEnvelope.parse(text)
                XCTAssertEqual(envelope, .locStop(target: vector["target"] as? String ?? "", ts: LocationKat.int(vector, "ts")), name)
            case "drop":
                // A stop that breaks the profile is never a typed stop: it throws (the caller drops it) or, when it is not even a JSON
                // object or not the envelope version, it is not a control envelope at all (`nil`). It is never `.locStop`, and a
                // stop whose bytes are valid JSON for a lenient reader (a duplicate member, a depth of 5, 8192 bytes) throws.
                var parsed: ChatControlEnvelope?
                do { parsed = try ChatControlEnvelope.parse(text) } catch { parsed = nil }
                if case .locStop? = parsed { XCTFail("\(name): a stop that breaks the profile was accepted") }
            default:
                XCTFail("\(name): unknown expect")
            }
        }
    }

    func testTheCanonicalTextOfAStop() throws {
        let envelope = ChatControlEnvelope.locStop(target: "f55b8313-840d-4d42-8de0-069a1b8988ee", ts: 1_792_760_400)
        XCTAssertEqual(try envelope.toJsonString(),
                       #"{"qa_ctl":1,"t":"loc_stop","target":"f55b8313-840d-4d42-8de0-069a1b8988ee","ts":1792760400}"#)
        XCTAssertEqual(try ChatControlEnvelope.parse(try envelope.toJsonString()), envelope)
        // A target with a slash is written as it is (no `\/` escape), and a target over 128 bytes cannot be built.
        let slash = ChatControlEnvelope.locStop(target: "a/b", ts: 5)
        XCTAssertEqual(try slash.toJsonString(), #"{"qa_ctl":1,"t":"loc_stop","target":"a/b","ts":5}"#)
        XCTAssertThrowsError(try ChatControlEnvelope.locStop(target: String(repeating: "t", count: 129), ts: 5).toJsonString())
        XCTAssertThrowsError(try ChatControlEnvelope.locStop(target: "", ts: 5).toJsonString())
    }

    /// A duplicate member name, which `JSONSerialization` would accept (the last one wins), is not a stop.
    func testALenientReaderWouldHaveAcceptedWhatTheProfileRejects() {
        let json = #"{"qa_ctl":1,"t":"loc_stop","target":"a","ts":1,"target":"b"}"#
        XCTAssertThrowsError(try ChatControlEnvelope.parse(json)) { error in
            guard case ChatControlEnvelope.Error.invalidLocStop = error else { return XCTFail("\(error)") }
        }
    }

    func testOtherVariantsAreUnaffected() throws {
        XCTAssertEqual(try ChatControlEnvelope.parse(#"{"qa_ctl":1,"t":"delete","target":"x","ts":1}"#), .delete(target: "x", ts: 1))
        XCTAssertThrowsError(try ChatControlEnvelope.parse(#"{"qa_ctl":1,"t":"loc_stop2","target":"x","ts":1}"#))
    }

    func testTheFiveEntryPointsAreRefusedAsUserText() throws {
        let vectors = LocationKat.section(try LocationKat.load(), "entry_point_cases")
        for vector in vectors {
            let text = try XCTUnwrap(vector["text"] as? String)
            XCTAssertEqual(FileV2ChatBody.isUserTextAllowed(text), !(vector["refused"] as? Bool ?? false), vector["name"] as? String ?? text)
        }
        XCTAssertFalse(FileV2ChatBody.isUserTextAllowed(#"{"qa_loc":1,"m":"pin","lat":1,"lon":2,"acc":3,"age":0,"ap":0}"#))
    }
}
