import XCTest
@testable import QAudionEngine

/// 2026-09-19 service-message root fix — pins the structural service detector
/// and the typed inbound router decisions (pure functions, no I/O).
final class ServicePayloadDetectorTests: XCTestCase {

    // MARK: - Detector

    func test_plainText_isNotService() {
        XCTAssertEqual(ServicePayloadDetector.classify("ciao, come stai?"), .notService)
        XCTAssertEqual(ServicePayloadDetector.classify(""), .notService)
        XCTAssertEqual(ServicePayloadDetector.classify("   \n  "), .notService)
    }

    func test_jsonWithoutAServiceKey_isNotService() {
        XCTAssertEqual(ServicePayloadDetector.classify("{\"hello\":\"world\"}"), .notService)
        XCTAssertEqual(ServicePayloadDetector.classify("{}"), .notService)
    }

    func test_everyServiceKey_isService() {
        for key in ServicePayloadDetector.serviceKeys {
            let text = "{\"\(key)\":1,\"x\":2}"
            XCTAssertEqual(ServicePayloadDetector.classify(text), .service(key: key), "key=\(key)")
        }
    }

    func test_serviceKeys_matchTheCrossPlatformList() {
        XCTAssertEqual(Set(ServicePayloadDetector.serviceKeys), [
            "qa_ctl", "qa_grp", "qa_kms", "qa_kms_prebootstrap", "qa_v4_bootstrap",
            "qa_grpcall_ctrl", "sender_key_init", "sender_key_rotate",
        ])
    }

    func test_qaCtl_attachAnnounce_isAttachmentNotService() {
        let text = "{\"qa_ctl\":1,\"t\":\"attach_announce\",\"att\":{\"id\":\"x\"},\"ts\":1}"
        XCTAssertEqual(ServicePayloadDetector.classify(text), .attachmentAnnounce)
        XCTAssertFalse(ServicePayloadDetector.isServiceShaped(text))
    }

    func test_qaCtl_everyOtherType_isService() {
        for t in ["delete", "edit", "reaction", "decrypt_nack", "avatar_announce",
                  "ephemeral_timer", "ss_req", "ss_resp", "ss_lock", "somethingNew"] {
            let text = "{\"qa_ctl\":1,\"t\":\"\(t)\",\"ts\":1}"
            XCTAssertEqual(ServicePayloadDetector.classify(text), .service(key: "qa_ctl"), "t=\(t)")
        }
    }

    func test_qaCtl_withoutT_isService() {
        XCTAssertEqual(ServicePayloadDetector.classify("{\"qa_ctl\":1}"), .service(key: "qa_ctl"))
    }

    func test_attachAnnounce_alongsideAnotherServiceKey_isService() {
        let text = "{\"qa_ctl\":1,\"qa_grp\":1,\"t\":\"attach_announce\"}"
        XCTAssertTrue(ServicePayloadDetector.classify(text).isService)
    }

    func test_leadingWhitespace_isTolerated() {
        XCTAssertEqual(ServicePayloadDetector.classify("  \n {\"qa_grp\": 1, \"t\": \"sender_key_init\"}"),
                       .service(key: "qa_grp"))
    }

    func test_truncatedJson_isJudgedByItsFirstKey() {
        XCTAssertEqual(ServicePayloadDetector.classify("{\"qa_ctl\":1,\"t\":\"reac"), .service(key: "qa_ctl"))
        XCTAssertEqual(ServicePayloadDetector.classify("{ \"qa_grp\" : 1, \"t\":\"sender_key_ini"),
                       .service(key: "qa_grp"))
        XCTAssertEqual(ServicePayloadDetector.classify("{\"sender_key_init\":{\"g\":\"ab"),
                       .service(key: "sender_key_init"))
        // Not a service key, or the key itself is cut off: user text.
        XCTAssertEqual(ServicePayloadDetector.classify("{\"hello\":\"wor"), .notService)
        XCTAssertEqual(ServicePayloadDetector.classify("{\"qa_c"), .notService)
        XCTAssertEqual(ServicePayloadDetector.classify("{"), .notService)
    }

    func test_escapedKey_isNotAServiceKey() {
        XCTAssertNil(ServicePayloadDetector.firstKey(of: "{\"qa\\u005fctl\":1"))
    }

    func test_userTextThatMerelyMentionsAMarker_isNotService() {
        XCTAssertEqual(ServicePayloadDetector.classify("what does qa_ctl mean?"), .notService)
        XCTAssertEqual(ServicePayloadDetector.classify("look: {\"qa_ctl\":1}"), .notService)
        XCTAssertEqual(ServicePayloadDetector.classify("[{\"qa_ctl\":1}]"), .notService)
    }

    func test_oversizedText_isStillClassifiedByItsFirstKey() {
        let filler = String(repeating: "a", count: ServicePayloadDetector.fullParseCapBytes + 10)
        XCTAssertEqual(ServicePayloadDetector.classify("{\"qa_ctl\":1,\"pad\":\"\(filler)\"}"),
                       .service(key: "qa_ctl"))
        XCTAssertEqual(ServicePayloadDetector.classify("{\"pad\":\"\(filler)\"}"), .notService)
    }

    // MARK: - Wire class

    func test_wireClass_isDecidedByTheFirstByte() {
        XCTAssertEqual(InboundWireClass.of(Data([0xE6, 0x01, 0x02])), .control)
        for magic: UInt8 in [0xE5, 0xE3, 0xE2, 0xE4, 0x00, 0x7F, 0xFF] {
            XCTAssertEqual(InboundWireClass.of(Data([magic, 0x01])), .chat, "magic=\(magic)")
        }
        XCTAssertEqual(InboundWireClass.of(Data()), .chat)
    }

    // MARK: - Router verdicts

    private let service = "{\"qa_ctl\":1,\"t\":\"reaction\",\"target\":\"x\",\"emoji\":\"+\"}"
    private let attach = "{\"qa_ctl\":1,\"t\":\"attach_announce\",\"att\":{}}"

    func test_control_serviceIsDispatched() {
        XCTAssertEqual(InboundRouter.verdict(wireClass: .control, text: service), .dispatchService)
    }

    func test_control_plainTextAndAttachmentAreDropped_neverRendered() {
        XCTAssertEqual(InboundRouter.verdict(wireClass: .control, text: "hello"),
                       .drop(.plainTextOnControl))
        XCTAssertEqual(InboundRouter.verdict(wireClass: .control, text: attach),
                       .drop(.attachmentOnControl))
    }

    func test_chat_serviceShapedIsDropped_notAcceptedAsControl() {
        XCTAssertEqual(InboundRouter.verdict(wireClass: .chat, text: service),
                       .drop(.serviceOnChatWire))
        XCTAssertEqual(InboundRouter.verdict(wireClass: .chat, text: "{\"qa_grp\":1,\"t\":\"sender_key_init\"}"),
                       .drop(.serviceOnChatWire))
        XCTAssertEqual(InboundRouter.verdict(wireClass: .chat, text: "{\"qa_ctl\":1,\"t\":\"unknown_future\"}"),
                       .drop(.serviceOnChatWire))
    }

    func test_chat_userTextAndAttachmentAreUserContent() {
        XCTAssertEqual(InboundRouter.verdict(wireClass: .chat, text: "ciao"), .userContent)
        XCTAssertEqual(InboundRouter.verdict(wireClass: .chat, text: attach), .userContent)
    }

    func test_nonUtf8Plaintext_isDroppedOnBothClasses() {
        let bad = Data([0xFF, 0xFE, 0xFD])
        XCTAssertEqual(InboundRouter.verdict(wireClass: .chat, plaintext: bad), .drop(.nonUtf8))
        XCTAssertEqual(InboundRouter.verdict(wireClass: .control, plaintext: bad), .drop(.nonUtf8))
    }

    func test_dataOverload_matchesTheTextOverload() {
        let data = Data("ciao".utf8)
        XCTAssertEqual(InboundRouter.verdict(wireClass: .chat, plaintext: data), .userContent)
        XCTAssertEqual(InboundRouter.verdict(wireClass: .control, plaintext: Data(service.utf8)),
                       .dispatchService)
    }

    func test_dropReasons_haveStableLogCodes() {
        XCTAssertEqual(InboundDropReason.nonUtf8.rawValue, 1)
        XCTAssertEqual(InboundDropReason.serviceOnChatWire.rawValue, 2)
        XCTAssertEqual(InboundDropReason.plainTextOnControl.rawValue, 3)
        XCTAssertEqual(InboundDropReason.attachmentOnControl.rawValue, 4)
    }
}
