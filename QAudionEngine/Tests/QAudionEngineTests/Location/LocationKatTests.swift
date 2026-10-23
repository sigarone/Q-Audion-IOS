import XCTest
@testable import QAudionEngine

/// Runs every vector of `location-kat.json` (WIRE_SPEC section 14.11) that is not a state-machine sequence against the Swift library:
/// the constants, recognition and the typed rules, conversion with the IEEE bits of every double, DEC7, the canonical builder with its
/// refusals, the entry-point rule, the frame crypto (positive and negative), the stop control, the end time, the four open outputs and
/// the redaction cases. The sequences of the sender and of the receiver are in `LocationSenderKatTests` and
/// `LocationReceiverKatTests`. The counts are pinned and nothing skips: a vector can never be dropped or filtered out without a
/// failure here.
final class LocationKatTests: XCTestCase {

    func testKatFileIsAByteIdenticalCopyOfTheServerFile() throws {
        let bytes = try LocationKat.bytes()
        XCTAssertEqual(bytes.count, LocationKat.pinnedLength, "length of location-kat.json changed")
        XCTAssertEqual(LocationKat.sha256Hex(bytes), LocationKat.pinnedSHA256,
                       "location-kat.json is not the pinned byte-for-byte copy of the server file")
        XCTAssertFalse(bytes.contains(0x0D), "a CR in the vector file: line endings were rewritten (.gitattributes -text)")
    }

    /// The counts are asserted so a vector can never be dropped or filtered out without a failure here.
    func testKatCoversEverythingTheTestsExercise() throws {
        let kat = try LocationKat.load()
        XCTAssertEqual(kat["format"] as? String, "qaudion-location-kat")
        XCTAssertEqual(LocationKat.int(kat, "version"), 1)
        XCTAssertEqual(LocationKat.section(kat, "recognition").count, 33)
        XCTAssertEqual(LocationKat.section(kat, "rules").count, 130)
        let conversion = LocationKat.object(kat, "conversion_cases")
        XCTAssertEqual((conversion["e7"] as? [Any])?.count, 66)
        XCTAssertEqual((conversion["accuracy"] as? [Any])?.count, 16)
        XCTAssertEqual((conversion["age"] as? [Any])?.count, 11)
        XCTAssertEqual((conversion["frame_age"] as? [Any])?.count, 10)
        XCTAssertEqual(LocationKat.section(kat, "decimal_cases").count, 14)
        XCTAssertEqual(LocationKat.section(kat, "builder_cases").count, 30)
        XCTAssertEqual(LocationKat.section(kat, "entry_point_cases").count, 17)
        let frames = LocationKat.object(kat, "frame_cases")
        XCTAssertEqual((frames["positive"] as? [Any])?.count, 16)
        XCTAssertEqual((frames["negative"] as? [Any])?.count, 37)
        let stops = LocationKat.object(kat, "stop_cases")
        XCTAssertEqual((stops["builder_cases"] as? [Any])?.count, 7)
        XCTAssertEqual((stops["receiver_cases"] as? [Any])?.count, 28)
        XCTAssertEqual(LocationKat.section(kat, "receiver_sequences").count, 36)
        XCTAssertEqual(LocationKat.section(kat, "sender_sequences").count, 15)
        XCTAssertEqual(LocationKat.section(kat, "end_time_cases").count, 17)
        XCTAssertEqual(LocationKat.section(kat, "open_cases").count, 11)
        XCTAssertEqual(LocationKat.section(kat, "redaction_cases").count, 20)
        XCTAssertEqual(LocationKat.strings(kat, "rejection_codes"), ["bad_location", "unsupported_version", "unsupported_context"])
        XCTAssertEqual(LocationKat.strings(kat, "receiver_drops"),
                       ["frame_format", "frame_unmatched", "frame_old", "frame_bad", "stop_spoof", "stop_unknown", "start_duplicate"])
    }

    // MARK: constants

    func testConstantsMatchTheLibrary() throws {
        let kat = try LocationKat.load()
        let c = LocationKat.object(kat, "constants")
        var checked = Set<String>()
        func integer(_ key: String, _ expected: Int64) {
            checked.insert(key)
            XCTAssertEqual(LocationKat.int(c, key), expected, key)
        }
        integer("VERSION", LocationWire.version)
        integer("LOC_MAX_BYTES", Int64(LocationWire.maxBytes))
        integer("LOC_MAX_DEPTH", Int64(LocationWire.maxDepth))
        integer("LOC_MAX_BYTES", Int64(FileV2.maxDescriptorBytes))
        integer("LOC_MAX_DEPTH", Int64(FileV2.maxDescriptorDepth))
        integer("MAX_JSON_INT", FileV2.maxJSONInteger)
        integer("LAT_E7_MIN", LocationWire.latE7Min)
        integer("LAT_E7_MAX", LocationWire.latE7Max)
        integer("LON_E7_MIN", LocationWire.lonE7Min)
        integer("LON_E7_MAX", LocationWire.lonE7Max)
        integer("ACC_MIN", LocationWire.accMin)
        integer("ACC_MAX", LocationWire.accMax)
        integer("AGE_MAX", LocationWire.ageMax)
        integer("BUILD_MAX_FIX_AGE", LocationWire.buildMaxFixAge)
        integer("DU_MIN", LocationWire.duMin)
        integer("DU_MAX", LocationWire.duMax)
        integer("SKEW", LocationWire.skew)
        integer("TX_INTERVAL", LocationWire.txInterval)
        integer("TX_INTERVAL_LOW_POWER", LocationWire.txIntervalLowPower)
        integer("TX_MIN_GAP", LocationWire.txMinGap)
        integer("IV_MIN", LocationWire.ivMin)
        integer("IV_MAX", LocationWire.ivMax)
        integer("FRAME_VERSION", Int64(LocationWire.frameVersion))
        integer("FRAME_LEN", Int64(LocationWire.frameLength))
        integer("FRAME_PT_LEN", Int64(LocationWire.framePlaintextLength))
        integer("FRAME_AGE_MAX", LocationWire.frameAgeMax)
        integer("FLAG_FINAL", Int64(LocationWire.flagFinal))
        integer("FLAG_APPROX", Int64(LocationWire.flagApprox))
        integer("STALE_FLOOR", LocationWire.staleFloor)
        integer("STALE_FACTOR", LocationWire.staleFactor)
        integer("MAX_CANDIDATES", Int64(LocationWire.maxCandidates))
        integer("TOMBSTONE_KEEP", LocationWire.tombstoneKeep)
        integer("TOMBSTONE_MAX", Int64(LocationWire.tombstoneMax))
        integer("STOP_TARGET_MAX", Int64(LocationWire.stopTargetMax))
        integer("SID_LEN", Int64(LocationWire.sidLength))
        integer("KEY_LEN", Int64(LocationWire.keyLength))
        integer("EPH_MAX_B64", Int64(LocationWire.ephMaxBase64))
        // DU_MAX + SKEW, as the specification says.
        XCTAssertEqual(LocationWire.tombstoneKeep, LocationWire.duMax + LocationWire.skew)

        func text(_ key: String, _ expected: String) {
            checked.insert(key)
            XCTAssertEqual(LocationKat.string(c, key), expected, key)
        }
        text("PREFIX", String(decoding: LocationWire.prefix, as: UTF8.self))
        text("HKDF_INFO", String(decoding: LocationWire.hkdfInfo, as: UTF8.self))
        text("AAD_LABEL", String(decoding: LocationWire.aadLabel, as: UTF8.self))

        func list(_ key: String, _ expected: [String]) {
            checked.insert(key)
            XCTAssertEqual(LocationKat.strings(c, key), expected, key)
        }
        list("MEMBER_ORDER", LocationWire.memberOrder)
        list("STOP_MEMBER_ORDER", LocationWire.stopMemberOrder)
        list("CHANNELS", LocationChannel.allCases.map { $0.rawValue })
        list("RECOGNISED_PREFIXES", LocationWire.recognisedPrefixes)
        list("END_REASONS", LiveShareEndReason.allCases.map { $0.rawValue })
        list("SENDER_REFUSALS", LocationSenderRefusal.allCases.map { $0.rawValue })
        checked.insert("DU_PRESETS")
        XCTAssertEqual((c["DU_PRESETS"] as? [NSNumber])?.map { $0.int64Value }, LocationWire.duPresets)

        // Server-only values (the relay limiter) and a prose note are not part of the client library.
        for serverOnly in ["EPH_PAIR_RATE", "EPH_PAIR_BURST", "USER_ID_FORMAT"] { checked.insert(serverOnly) }
        XCTAssertEqual(Set(c.keys).subtracting(checked), [], "a constant of the vector file that no test compares")
        XCTAssertEqual(LocationWire.recognisedPrefixes.count, 5)
    }

    // MARK: recognition and rules

    private func run(_ vector: [String: Any]) {
        let name = vector["name"] as? String ?? "?"
        let channel = LocationChannel(rawValue: vector["channel"] as? String ?? "") ?? .chat
        let result = LocationCodec.recognize(utf8: LocationKat.bodyBytes(vector), channel: channel)
        switch vector["expect"] as? String {
        case "not_location":
            XCTAssertEqual(result, .notLocation, name)
        case "pin", "live":
            guard case .location(let body) = result else {
                XCTFail("\(name): expected a location, got \(result)")
                return
            }
            let normalized = vector["normalized"] as? [String: Any] ?? [:]
            XCTAssertEqual(body.isLive, vector["expect"] as? String == "live", name)
            XCTAssertEqual(LocationKat.string(normalized, "m"), body.isLive ? "live" : "pin", name)
            XCTAssertEqual(Int64(body.position.latE7), LocationKat.int(normalized, "lat"), name)
            XCTAssertEqual(Int64(body.position.lonE7), LocationKat.int(normalized, "lon"), name)
            XCTAssertEqual(Int64(body.position.accuracy), LocationKat.int(normalized, "acc"), name)
            XCTAssertEqual(Int64(body.position.age), LocationKat.int(normalized, "age"), name)
            XCTAssertEqual(Int64(body.position.approximate ? 1 : 0), LocationKat.int(normalized, "ap"), name)
            if case .live(let live, _) = body {
                XCTAssertEqual(live.sid.base64EncodedString(), LocationKat.string(normalized, "sid"), name)
                XCTAssertEqual(live.key.base64EncodedString(), LocationKat.string(normalized, "k"), name)
                XCTAssertEqual(live.startedAt, LocationKat.int(normalized, "st"), name)
                XCTAssertEqual(live.duration, LocationKat.int(normalized, "du"), name)
            }
        case "rejected":
            XCTAssertEqual(result, .rejected(LocationRejection(rawValue: vector["code"] as? String ?? "") ?? .badLocation), name)
            XCTAssertNotNil(LocationRejection(rawValue: vector["code"] as? String ?? ""), "\(name): unknown code")
        default:
            XCTFail("\(name): unknown expect")
        }
    }

    func testEveryRecognitionVector() throws {
        let vectors = LocationKat.section(try LocationKat.load(), "recognition")
        XCTAssertEqual(vectors.count, 33)
        for vector in vectors { run(vector) }
    }

    func testEveryRulesVector() throws {
        let vectors = LocationKat.section(try LocationKat.load(), "rules")
        XCTAssertEqual(vectors.count, 130)
        XCTAssertEqual(vectors.filter { $0["expect"] as? String == "pin" }.count, 20)
        XCTAssertEqual(vectors.filter { $0["expect"] as? String == "live" }.count, 7)
        XCTAssertEqual(vectors.filter { $0["expect"] as? String == "rejected" }.count, 103)
        for vector in vectors { run(vector) }
    }

    /// A rejected body is never text: whatever the verdict, the description of the verdict holds no digit of the body.
    func testRejectedAndValidBodiesDescribeThemselvesWithoutContent() throws {
        for vector in LocationKat.section(try LocationKat.load(), "rules") {
            let result = LocationCodec.recognize(utf8: LocationKat.bodyBytes(vector), channel: .chat)
            if case .location = result {
                XCTAssertEqual(String(describing: result), "location(redacted)")
            }
        }
        let pin = LocationPosition(latE7: 454_642_110, lonE7: 91_899_820, accuracy: 12, age: 3, approximate: false)
        for text in [String(describing: pin), String(reflecting: pin),
                     String(describing: LocationBody.pin(pin)),
                     String(describing: LocationLiveStart(sid: Data(count: 16), key: Data(repeating: 0x41, count: 32), startedAt: 1, duration: 60))] {
            XCTAssertFalse(text.contains("4546"), text)
            XCTAssertFalse(text.contains("AAAA"), text)
            XCTAssertTrue(text.contains("redacted"), text)
        }
    }

    // MARK: conversion

    func testEveryE7Vector() throws {
        let cases = try XCTUnwrap(LocationKat.object(try LocationKat.load(), "conversion_cases")["e7"] as? [[String: Any]])
        for vector in cases {
            let name = vector["name"] as? String ?? "?"
            let degrees = LocationKat.double(fromBits: vector["deg_bits"] as? String ?? "")
            let axis: LocationConversion.Axis = vector["axis"] as? String == "lat" ? .latitude : .longitude
            let result = LocationConversion.e7(degrees: degrees, axis: axis)
            if let expected = LocationKat.int(vector, "expected") {
                XCTAssertEqual(result, .success(Int32(expected)), name)
            } else {
                let refusal = LocationBuildRefusal(rawValue: vector["refuse"] as? String ?? "")
                XCTAssertNotNil(refusal, name)
                XCTAssertEqual(result, .failure(refusal ?? .fix), name)
            }
        }
    }

    func testEveryAccuracyVector() throws {
        let cases = try XCTUnwrap(LocationKat.object(try LocationKat.load(), "conversion_cases")["accuracy"] as? [[String: Any]])
        for vector in cases {
            let name = vector["name"] as? String ?? "?"
            let metres = LocationKat.double(fromBits: vector["m_bits"] as? String ?? "")
            let result = LocationConversion.accuracy(metres: metres)
            if let expected = LocationKat.int(vector, "expected") {
                XCTAssertEqual(result, .success(expected), name)
            } else {
                XCTAssertEqual(result, .failure(LocationBuildRefusal(rawValue: vector["refuse"] as? String ?? "") ?? .fix), name)
            }
        }
    }

    func testEveryAgeVector() throws {
        let conversion = LocationKat.object(try LocationKat.load(), "conversion_cases")
        for vector in try XCTUnwrap(conversion["age"] as? [[String: Any]]) {
            let name = vector["name"] as? String ?? "?"
            let elapsed = try XCTUnwrap(LocationKat.int(vector, "elapsed_ms"))
            let age = LocationConversion.age(elapsedMs: elapsed)
            XCTAssertEqual(age, LocationKat.int(vector, "expected"), name)
            // The builder accepts a fix up to BUILD_MAX_FIX_AGE seconds old.
            let accepted = age <= LocationWire.buildMaxFixAge
            XCTAssertEqual(accepted ? "accept" : "refuse", vector["builder"] as? String, name)
        }
        for vector in try XCTUnwrap(conversion["frame_age"] as? [[String: Any]]) {
            let name = vector["name"] as? String ?? "?"
            let elapsed = try XCTUnwrap(LocationKat.int(vector, "elapsed_ms"))
            XCTAssertEqual(Int64(LocationConversion.frameAge(elapsedMs: elapsed)), LocationKat.int(vector, "expected"), name)
        }
    }

    func testEveryDecimalVector() throws {
        let vectors = LocationKat.section(try LocationKat.load(), "decimal_cases")
        XCTAssertEqual(vectors.count, 14)
        for vector in vectors {
            let value = try XCTUnwrap(LocationKat.int(vector, "e7"))
            XCTAssertEqual(LocationConversion.dec7(value), vector["expected"] as? String, vector["name"] as? String ?? "\(value)")
        }
    }

    // MARK: builder

    func testEveryBuilderVector() throws {
        let vectors = LocationKat.section(try LocationKat.load(), "builder_cases")
        XCTAssertEqual(vectors.count, 30)
        for vector in vectors {
            let name = vector["name"] as? String ?? "?"
            let input = try XCTUnwrap(vector["input"] as? [String: Any], name)
            let fix = LocationFix(latitude: LocationKat.double(fromBits: input["lat_bits"] as? String ?? ""),
                                  longitude: LocationKat.double(fromBits: input["lon_bits"] as? String ?? ""),
                                  horizontalAccuracy: LocationKat.double(fromBits: input["acc_bits"] as? String ?? ""),
                                  elapsedMs: LocationKat.int(input, "fix_elapsed_ms") ?? 0,
                                  approximate: LocationKat.bool(input, "approximate") ?? false)
            let channel = LocationChannel(rawValue: input["channel"] as? String ?? "chat") ?? .chat
            let result: Result<String, LocationBuildRefusal>
            if input["mode"] as? String == "pin" {
                result = LocationCodec.buildPin(fix: fix)
            } else {
                let sid = Data(base64Encoded: input["sid"] as? String ?? "") ?? Data()
                let key = Data(base64Encoded: input["k"] as? String ?? "") ?? Data()
                result = LocationCodec.buildLiveStart(fix: fix, sid: sid, key: key, startedAt: LocationKat.int(input, "st"),
                                                      duration: LocationKat.int(input, "du"), channel: channel)
            }
            switch (vector["expected"] as? String, vector["refuse"] as? String) {
            case (let expected?, nil):
                guard case .success(let text) = result else {
                    XCTFail("\(name): the builder refused")
                    continue
                }
                XCTAssertEqual(LocationKat.utf8(text), LocationKat.utf8(expected), name)
                // What the builder writes is accepted by the receiver (section 14.5), on the channel it was built for.
                let recognised = LocationCodec.recognize(utf8: Data(text.utf8), channel: input["mode"] as? String == "pin" ? channel : .chat)
                guard case .location(let body) = recognised else {
                    XCTFail("\(name): the receiver does not accept the builder's text")
                    continue
                }
                XCTAssertEqual(body.isLive, input["mode"] as? String == "live", name)
            case (nil, let reason?):
                XCTAssertEqual(result, .failure(LocationBuildRefusal(rawValue: reason) ?? .fix), name)
                XCTAssertNotNil(LocationBuildRefusal(rawValue: reason), "\(name): unknown reason")
            default:
                XCTFail("exactly one of expected and refuse in \(name)")
            }
        }
    }

    // MARK: entry points

    func testEveryEntryPointVector() throws {
        let vectors = LocationKat.section(try LocationKat.load(), "entry_point_cases")
        XCTAssertEqual(vectors.count, 17)
        for vector in vectors {
            let text = try XCTUnwrap(vector["text"] as? String)
            if vector["name"] as? String == "bom_first" {
                // The vector is about a byte order mark: it must have reached the test as one.
                XCTAssertEqual(Array(text.utf8.prefix(3)), [0xEF, 0xBB, 0xBF])
            }
            XCTAssertEqual(MessageReplyCodec.hasReservedPrefix(text), vector["refused"] as? Bool, vector["name"] as? String ?? text)
        }
    }

    // MARK: frames

    private func keys(_ vector: [String: Any]) throws -> LocationFrameKeys {
        let sid = try XCTUnwrap(Data(base64Encoded: vector["sid_b64"] as? String ?? ""))
        let key = try XCTUnwrap(Data(base64Encoded: vector["k_b64"] as? String ?? ""))
        return try XCTUnwrap(LocationFrameKeys(sid: sid, shareKey: key))
    }

    func testEveryPositiveFrameVector() throws {
        let frames = LocationKat.object(try LocationKat.load(), "frame_cases")
        let vectors = try XCTUnwrap(frames["positive"] as? [[String: Any]])
        XCTAssertEqual(vectors.count, 16)
        for vector in vectors {
            let name = vector["name"] as? String ?? "?"
            let sid = try XCTUnwrap(Data(base64Encoded: vector["sid_b64"] as? String ?? ""))
            let key = try XCTUnwrap(Data(base64Encoded: vector["k_b64"] as? String ?? ""))
            let sender = try XCTUnwrap(vector["sender_id"] as? String)
            let recipient = try XCTUnwrap(vector["recipient_id"] as? String)
            let counter = UInt32(try XCTUnwrap(LocationKat.int(vector, "ctr")))
            let fields = try XCTUnwrap(vector["plaintext_fields"] as? [String: Any])
            let expected = try XCTUnwrap(vector["expected"] as? [String: Any])

            // The key schedule: okm, K_frame, N_base.
            let okm = LocationFrameCodec.deriveOKM(sid: sid, shareKey: key)
            XCTAssertEqual(LocationKat.hex(okm), expected["okm_hex"] as? String, name)
            XCTAssertEqual(LocationKat.hex(okm.prefix(32)), expected["k_frame_hex"] as? String, name)
            let base = Data(okm.suffix(12))
            XCTAssertEqual(LocationKat.hex(base), expected["n_base_hex"] as? String, name)
            XCTAssertEqual(LocationKat.hex(LocationFrameCodec.nonce(base: base, counter: counter)), expected["nonce_hex"] as? String, name)
            XCTAssertEqual(LocationKat.hex(try XCTUnwrap(LocationFrameCodec.aad(sid: sid, counter: counter, senderId: sender, recipientId: recipient))),
                           expected["aad_hex"] as? String, name)

            // The plaintext and the frame.
            let plaintext = LocationFramePlaintext(
                flags: UInt8(try XCTUnwrap(LocationKat.int(fields, "flags"))), reserved: UInt8(try XCTUnwrap(LocationKat.int(fields, "reserved"))),
                iv: UInt16(try XCTUnwrap(LocationKat.int(fields, "iv"))), lat: Int32(try XCTUnwrap(LocationKat.int(fields, "lat"))),
                lon: Int32(try XCTUnwrap(LocationKat.int(fields, "lon"))), acc: UInt16(try XCTUnwrap(LocationKat.int(fields, "acc"))),
                age: UInt16(try XCTUnwrap(LocationKat.int(fields, "age"))))
            XCTAssertEqual(LocationKat.hex(plaintext.bytes), expected["plaintext_hex"] as? String, name)
            let frameKeys = try XCTUnwrap(LocationFrameKeys(sid: sid, shareKey: key))
            let sealed = try XCTUnwrap(LocationFrameCodec.seal(plaintext, counter: counter, keys: frameKeys, senderId: sender, recipientId: recipient), name)
            XCTAssertEqual(LocationKat.hex(sealed.bytes), expected["frame_hex"] as? String, name)
            XCTAssertEqual(sealed.base64, expected["frame_b64"] as? String, name)
            XCTAssertEqual(sealed.bytes.count, LocationWire.frameLength, name)
            XCTAssertEqual(sealed.counter, counter, name)
            XCTAssertEqual(sealed.isFinal, plaintext.isFinal, name)

            // And the receiver opens it back to the same plaintext.
            switch LocationFrameCodec.openAndJudge(sealed.bytes, keys: frameKeys, senderId: sender, recipientId: recipient) {
            case .failure(let failure):
                XCTFail("\(name): the frame does not open: \(failure)")
            case .success(let opened):
                XCTAssertEqual(opened.counter, counter, name)
                XCTAssertEqual(opened.plaintext, plaintext, name)
            }
        }
    }

    func testEveryNegativeFrameVector() throws {
        let frames = LocationKat.object(try LocationKat.load(), "frame_cases")
        let vectors = try XCTUnwrap(frames["negative"] as? [[String: Any]])
        XCTAssertEqual(vectors.count, 37)
        for vector in vectors {
            let name = vector["name"] as? String ?? "?"
            let frameKeys = try keys(vector)
            let frame = try XCTUnwrap(Data(base64Encoded: vector["frame_b64"] as? String ?? ""), name)
            let sender = try XCTUnwrap(vector["sender_id"] as? String)
            let recipient = try XCTUnwrap(vector["recipient_id"] as? String)
            switch LocationFrameCodec.openAndJudge(frame, keys: frameKeys, senderId: sender, recipientId: recipient) {
            case .success:
                XCTFail("\(name): the frame must be dropped")
            case .failure(let failure):
                XCTAssertEqual(failure.stage, vector["drop"] as? String, name)
                switch failure {
                case .format(let reason), .plaintext(let reason):
                    XCTAssertEqual(reason, vector["reason"] as? String, name)
                case .auth:
                    break
                }
            }
        }
    }

    // MARK: stop

    func testEveryStopBuilderVector() throws {
        let vectors = try XCTUnwrap(LocationKat.object(try LocationKat.load(), "stop_cases")["builder_cases"] as? [[String: Any]])
        for vector in vectors {
            let name = vector["name"] as? String ?? "?"
            let target = try XCTUnwrap(vector["target"] as? String)
            let ts = try XCTUnwrap(LocationKat.int(vector, "ts"))
            let result = LocationStopControl.build(target: target, ts: ts)
            if let expected = vector["expected"] as? String {
                XCTAssertEqual(result, .success(expected), name)
                // The builder's text is a valid stop for the receiver.
                XCTAssertEqual(LocationStopControl.parse(utf8: Data(expected.utf8)), .success(.init(target: target, ts: ts)), name)
            } else {
                XCTAssertEqual(result, .failure(LocationStopControl.BuildRefusal(rawValue: vector["refuse"] as? String ?? "") ?? .target), name)
            }
        }
    }

    func testEveryStopReceiverVector() throws {
        let vectors = try XCTUnwrap(LocationKat.object(try LocationKat.load(), "stop_cases")["receiver_cases"] as? [[String: Any]])
        for vector in vectors {
            let name = vector["name"] as? String ?? "?"
            let result = LocationStopControl.parse(utf8: LocationKat.bodyBytes(vector))
            switch vector["expect"] as? String {
            case "valid":
                XCTAssertEqual(result, .success(.init(target: vector["target"] as? String ?? "", ts: LocationKat.int(vector, "ts") ?? -1)), name)
            case "drop":
                let reason = LocationStopControl.Drop(rawValue: vector["reason"] as? String ?? "")
                XCTAssertNotNil(reason, "\(name): unknown reason")
                XCTAssertEqual(result, .failure(reason ?? .size), name)
            default:
                XCTFail("\(name): unknown expect")
            }
        }
    }

    // MARK: end time

    func testEveryEndTimeVector() throws {
        let vectors = LocationKat.section(try LocationKat.load(), "end_time_cases")
        XCTAssertEqual(vectors.count, 17)
        for vector in vectors {
            let name = vector["name"] as? String ?? "?"
            let received = try XCTUnwrap(LocationKat.int(vector, "r"))
            let live = LocationLiveStart(sid: Data((0..<16).map { UInt8($0) }), key: Data((32..<64).map { UInt8($0) }),
                                         startedAt: try XCTUnwrap(LocationKat.int(vector, "st")),
                                         duration: try XCTUnwrap(LocationKat.int(vector, "du")))
            let position = LocationPosition(latE7: 454_642_110, lonE7: 91_899_820, accuracy: 12, age: 0, approximate: false)
            let receiver = try LocationShareReceiver(selfId: "a353aefc-1716-4516-9ffc-3f8d69ffe0b8",
                                                     peerId: "b9d7540f-ece4-4b58-b03b-e0001e522085",
                                                     store: InMemoryLocationShareStore(), now: received)
            XCTAssertEqual(receiver.receiveStart(clientMsgId: "start-1", live: live, position: position, now: received), .applied, name)
            let share = try XCTUnwrap(receiver.share(id: "start-1", now: received), name)
            XCTAssertEqual(share.endAt, LocationKat.int(vector, "end_at"), name)
            XCTAssertEqual(share.state == .ended, LocationKat.bool(vector, "ended_on_arrival"), name)
            for check in try XCTUnwrap(vector["checks"] as? [[String: Any]]) {
                let now = try XCTUnwrap(LocationKat.int(check, "now"))
                XCTAssertEqual(receiver.share(id: "start-1", now: now)?.state.rawValue, check["state"] as? String, "\(name) at \(now)")
            }
        }
    }

    // MARK: open outputs

    func testEveryOpenVector() throws {
        let vectors = LocationKat.section(try LocationKat.load(), "open_cases")
        XCTAssertEqual(vectors.count, 11)
        for vector in vectors {
            let name = vector["name"] as? String ?? "?"
            let lat = Int32(try XCTUnwrap(LocationKat.int(vector, "lat")))
            let lon = Int32(try XCTUnwrap(LocationKat.int(vector, "lon")))
            let label = try XCTUnwrap(vector["label"] as? String)
            XCTAssertEqual(LocationOpenLinks.geoURI(latE7: lat, lonE7: lon), vector["geo"] as? String, name)
            XCTAssertEqual(LocationOpenLinks.appleMapsURL(latE7: lat, lonE7: lon, label: label), vector["apple_maps"] as? String, name)
            XCTAssertEqual(LocationOpenLinks.googleMapsURL(latE7: lat, lonE7: lon), vector["google_maps"] as? String, name)
            let gpx = LocationOpenLinks.gpx(latE7: lat, lonE7: lon, label: label)
            XCTAssertEqual(Array(gpx.utf8), Array((vector["gpx"] as? String ?? "").utf8), name)
            // UTF-8, LF line endings, no byte order mark, one LF after the last line.
            XCTAssertFalse(gpx.utf8.starts(with: [0xEF, 0xBB, 0xBF]), name)
            XCTAssertFalse(gpx.utf8.contains(0x0D), name)
            XCTAssertTrue(gpx.hasSuffix("</gpx>\n") && !gpx.hasSuffix("\n\n"), name)
        }
    }

    // MARK: redaction

    func testEveryRedactionVector() throws {
        let vectors = LocationKat.section(try LocationKat.load(), "redaction_cases")
        XCTAssertEqual(vectors.count, 20)
        XCTAssertEqual(LocationLogScrub.expressions.count, LocationLogScrub.patternSources.count, "a pattern does not compile")
        for vector in vectors {
            let name = vector["name"] as? String ?? "?"
            let line = try XCTUnwrap(vector["line"] as? String)
            let must = try XCTUnwrap(LocationKat.strings(vector, "must_not_survive"))
            XCTAssertFalse(must.isEmpty, name)
            for placeholder in [LocationLogScrub.defaultPlaceholder, "***REDACTED***"] {
                let out = LocationLogScrub.scrub(line, placeholder: placeholder)
                for needle in must {
                    XCTAssertFalse(out.contains(needle), "\(name): \(needle) survived")
                }
                // Scrubbing twice gives the same text.
                XCTAssertEqual(LocationLogScrub.scrub(out, placeholder: placeholder), out, name)
            }
        }
    }

    func testBenignLinesAreLeftAlone() {
        for line in ["loss=1% lat=12ms jitter=3ms", "version 1.0.1223 build 4821", "latency=12 accept=1", "location accuracy granted",
                     "ice connected role=caller retries=2", "rekey ok ctr=14"] {
            XCTAssertEqual(LocationLogScrub.scrub(line), line, line)
        }
    }
}
