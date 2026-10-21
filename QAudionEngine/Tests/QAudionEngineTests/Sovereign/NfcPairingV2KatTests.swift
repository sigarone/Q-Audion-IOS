import XCTest
import CryptoKit
@testable import QAudionEngine

/// Byte-for-byte check of NFC pairing v2 (docs/security/NFC_PAIRING_V2.md) against the independent reference
/// implementation (scripts/kat/gen_nfc_pairing_kat.py). The vector's Ed25519 signatures are RFC 8032 deterministic and
/// CryptoKit signs with randomness, so signatures are VERIFIED here, never compared, and everything that depends on a
/// signature (the sealed boxes) is opened and checked instead of reproduced. Nothing in a transcript hash, the SAS, the
/// PSK or a tag depends on a signature, so all of those are compared byte for byte.
final class NfcPairingV2KatTests: XCTestCase {

    // MARK: - The file

    func testFileIsTheOneBothAppsPin() throws {
        let kat = try NfcPairingV2Kat.load()
        let digest = SHA256.hash(data: kat.rawFile).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, NfcPairingV2Kat.sha256Hex,
                       "nfc-pairing-kat.json must stay a byte-for-byte copy of scripts/kat/nfc-pairing-kat.json")
        XCTAssertFalse(kat.rawFile.contains(0x0D), "the vectors must keep LF line endings")
    }

    // MARK: - Constants

    func testConstantsAndLabels() throws {
        let kat = try NfcPairingV2Kat.load()
        XCTAssertEqual(try kat.hex(["aid"]), NfcPairingV2.aid)
        XCTAssertEqual(kat.root["cla"] as? Int, Int(NfcPairingV2.proprietaryClass))
        XCTAssertEqual(kat.root["protocolVersion"] as? Int, Int(NfcPairingV2.version))
        XCTAssertEqual(kat.root["userIdMax"] as? Int, NfcPairingV2.maxUserIdBytes)
        let chunk = try XCTUnwrap(kat.root["chunk"] as? [String: Any])
        XCTAssertEqual(chunk["size"] as? Int, NfcPairingV2.chunkBytes)
        XCTAssertEqual(chunk["count"] as? Int, NfcPairingV2.chunkCount)
        let ins = try XCTUnwrap(kat.root["ins"] as? [String: Any])
        XCTAssertEqual(ins["EK_PUT"] as? Int, Int(NfcPairingV2.Instruction.ekPut.rawValue))
        XCTAssertEqual(ins["HELLO"] as? Int, Int(NfcPairingV2.Instruction.hello.rawValue))
        XCTAssertEqual(ins["CT_GET"] as? Int, Int(NfcPairingV2.Instruction.ctGet.rawValue))
        XCTAssertEqual(ins["AUTH_C"] as? Int, Int(NfcPairingV2.Instruction.authCard.rawValue))
        XCTAssertEqual(ins["REVEAL"] as? Int, Int(NfcPairingV2.Instruction.reveal.rawValue))
        XCTAssertEqual(ins["CONFIRM"] as? Int, Int(NfcPairingV2.Instruction.confirm.rawValue))
        XCTAssertEqual(ins["FINALIZE"] as? Int, Int(NfcPairingV2.Instruction.finalize.rawValue))

        let labels = try XCTUnwrap(kat.root["labels"] as? [String: String])
        let expected: [String: Data] = [
            "th1": NfcPairingV2.Label.transcript, "commit": NfcPairingV2.Label.commit,
            "th_c": NfcPairingV2.Label.transcriptCard, "th_r": NfcPairingV2.Label.transcriptReader,
            "enc_c": NfcPairingV2.Label.encCard, "enc_r": NfcPairingV2.Label.encReader,
            "mac_c": NfcPairingV2.Label.macCard, "mac_r": NfcPairingV2.Label.macReader,
            "sig_c": NfcPairingV2.Label.sigCard, "sig_r": NfcPairingV2.Label.sigReader,
            "confirm_c": NfcPairingV2.Label.confirmCard, "confirm_r": NfcPairingV2.Label.confirmReader,
            "sas": NfcPairingV2.Label.sas, "psk": NfcPairingV2.Label.psk,
            "confirmed": NfcPairingV2.Label.userConfirmed, "rejected": NfcPairingV2.Label.userRejected,
            "final": NfcPairingV2.Label.finalize, "log": NfcPairingV2.Label.log,
        ]
        XCTAssertEqual(Set(labels.keys), Set(expected.keys))
        for (name, bytes) in expected {
            XCTAssertEqual(Data(try XCTUnwrap(labels[name]).utf8), bytes, name)
        }
    }

    // MARK: - Keys and the KEM

    func testIdentitiesAreRealKeysAndPassTheStrictCheck() throws {
        let kat = try NfcPairingV2Kat.load()
        for role in ["reader", "card"] {
            let party = try kat.party(role)
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: party.seed)
            XCTAssertEqual(key.publicKey.rawRepresentation, party.publicKey, role)
            let identity = try NfcPairingV2Identity(publicKey: party.publicKey, userId: party.userId)
            XCTAssertEqual(identity.block, party.block, role)
            XCTAssertTrue(Ed25519PrimeOrderCheck.isAcceptableIdentityKey(party.publicKey), role)
        }
    }

    func testReaderKemKeyPairAndDecapsulation() throws {
        let kat = try NfcPairingV2Kat.load()
        let pair = try ProximityPairingCrypto.kemGenerateKeyPair(seed: try kat.input("mlkemSeedReader"))
        XCTAssertEqual(pair.publicKey, try kat.input("mlkemEk"))
        let shared = try ProximityPairingCrypto.kemDecapsulate(ciphertext: try kat.input("mlkemCt"), secretKey: pair.secretKey)
        XCTAssertEqual(shared, try kat.input("mlkemSs"))
    }

    func testX25519SharedSecret() throws {
        let kat = try NfcPairingV2Kat.load()
        let reader = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: try kat.input("x25519PrivReader"))
        let card = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: try kat.input("x25519PrivCard"))
        XCTAssertEqual(reader.publicKey.rawRepresentation, try kat.input("xpkReader"))
        XCTAssertEqual(card.publicKey.rawRepresentation, try kat.input("xpkCard"))
        let fromReader = try ProximityPairingCrypto.x25519SharedSecret(privateKey: reader, peerPublicKey: try kat.input("xpkCard"))
        let fromCard = try ProximityPairingCrypto.x25519SharedSecret(privateKey: card, peerPublicKey: try kat.input("xpkReader"))
        XCTAssertEqual(fromReader, try kat.derived("ssX25519"))
        XCTAssertEqual(fromCard, try kat.derived("ssX25519"))
    }

    // MARK: - Key schedule

    func testCommitmentTranscriptAndStageOne() throws {
        let kat = try NfcPairingV2Kat.load()
        let s = try kat.session1()
        let commit = NfcPairingV2Crypto.commitment(readerNonce: s.nonceReader, readerIdentityBlock: s.reader.block)
        XCTAssertEqual(commit, try kat.derived("commitReader"))
        var hello = Data([NfcPairingV2.version])
        hello.append(try kat.input("xpkReader"))
        hello.append(commit)
        XCTAssertEqual(hello, try kat.derived("helloCommandData"))
        let response = try kat.input("xpkCard") + (try kat.input("nonceCard"))
        XCTAssertEqual(response, try kat.derived("helloResponseData"))
        let th1 = NfcPairingV2Crypto.transcriptHash1(
            selectData: try kat.derived("selectData"), encapsulationKey: s.ek, helloCommand: hello,
            helloResponse: response, ciphertext: s.ct)
        XCTAssertEqual(th1, try kat.derived("th1"))
        XCTAssertEqual(NfcPairingV2Crypto.logTag(th1: th1), try kat.string(["exchange", "derived", "logTag"]))
        XCTAssertEqual(s.stage1.prk1, try kat.derived("prk1"))
        XCTAssertEqual(s.stage1.encCard, try kat.derived("kEncCard"))
        XCTAssertEqual(s.stage1.encReader, try kat.derived("kEncReader"))
        XCTAssertEqual(s.stage1.macCard, try kat.derived("kMacCard"))
        XCTAssertEqual(s.stage1.macReader, try kat.derived("kMacReader"))
    }

    func testCardProofAndSealedBox() throws {
        let kat = try NfcPairingV2Kat.load()
        let s = try kat.session1()
        let thCard = NfcPairingV2Crypto.transcriptHashCard(th1: s.th1, cardIdentityBlock: s.card.block)
        XCTAssertEqual(thCard, try kat.derived("thCard"))
        XCTAssertEqual(NfcPairingV2Crypto.transcriptMac(key: s.stage1.macCard, transcriptHash: thCard), try kat.derived("macCard"))
        XCTAssertTrue(NfcPairingV2Crypto.verifySignature(
            try kat.derived("sigCard"), payload: NfcPairingV2Crypto.cardSignaturePayload(thCard: thCard), publicKey: s.card.publicKey))
        // The sealed box is opened rather than reproduced: its content carries the deterministic signature.
        let plaintext = try ProximityPairingCrypto.aeadOpen(s.sealedCard, key: s.stage1.encCard, transcriptHash: s.th1)
        XCTAssertEqual(plaintext, s.card.block + (try kat.derived("sigCard")) + (try kat.derived("macCard")))
        XCTAssertEqual(s.sealedCard.count, 145 + s.card.userId.utf8.count)
        // And the reader accepts it.
        let verified = try NfcPairingV2Crypto.verifyCardAuth(
            sealed: s.sealedCard, stage1: s.stage1, th1: s.th1, ownIdentityKey: s.reader.publicKey, pinnedPeerKey: nil)
        XCTAssertEqual(verified.identity.publicKey, s.card.publicKey)
        XCTAssertEqual(verified.identity.userId, s.card.userId)
        XCTAssertEqual(verified.thCard, thCard)
    }

    func testReaderProofAndSealedBox() throws {
        let kat = try NfcPairingV2Kat.load()
        let s = try kat.session1()
        let thReader = NfcPairingV2Crypto.transcriptHashReader(thCard: s.thCard, readerIdentityBlock: s.reader.block,
                                                               readerNonce: s.nonceReader)
        XCTAssertEqual(thReader, try kat.derived("thReader"))
        XCTAssertEqual(NfcPairingV2Crypto.transcriptMac(key: s.stage1.macReader, transcriptHash: thReader), try kat.derived("macReader"))
        XCTAssertTrue(NfcPairingV2Crypto.verifySignature(
            try kat.derived("sigReader"), payload: NfcPairingV2Crypto.readerSignaturePayload(thReader: thReader), publicKey: s.reader.publicKey))
        let plaintext = try ProximityPairingCrypto.aeadOpen(s.sealedReader, key: s.stage1.encReader, transcriptHash: s.thCard)
        XCTAssertEqual(plaintext, s.reader.block + s.nonceReader + (try kat.derived("sigReader")) + (try kat.derived("macReader")))
        XCTAssertEqual(s.sealedReader.count, 177 + s.reader.userId.utf8.count)
        // The card's checks accept the vector's REVEAL.
        let opened = try NfcPairingV2Crypto.verifyReveal(
            sealed: s.sealedReader, stage1: s.stage1, thCard: s.thCard, readerCommitment: s.commitReader,
            ownIdentityKey: s.card.publicKey)
        XCTAssertEqual(opened.identity.publicKey, s.reader.publicKey)
        XCTAssertEqual(opened.nonce, s.nonceReader)
        XCTAssertEqual(opened.thReader, thReader)
    }

    func testReaderSealsARevealTheCardAccepts() throws {
        // Our own (randomized) signature must verify under the card's checks: sealed once, opened by verifyReveal.
        let kat = try NfcPairingV2Kat.load()
        let s = try kat.session1()
        let local = try kat.readerIdentity()
        let thReader = NfcPairingV2Crypto.transcriptHashReader(thCard: s.thCard, readerIdentityBlock: s.reader.block,
                                                               readerNonce: s.nonceReader)
        let sealed = try NfcPairingV2Crypto.sealReaderReveal(
            identity: local.identity, signingPrivateKey: local.signingPrivateKey, readerNonce: s.nonceReader,
            thCard: s.thCard, thReader: thReader, stage1: s.stage1)
        XCTAssertEqual(sealed.count, s.sealedReader.count)
        let opened = try NfcPairingV2Crypto.verifyReveal(
            sealed: sealed, stage1: s.stage1, thCard: s.thCard, readerCommitment: s.commitReader,
            ownIdentityKey: s.card.publicKey)
        XCTAssertEqual(opened.thReader, thReader)
    }

    func testStageTwoKeysSasPskAndTags() throws {
        let kat = try NfcPairingV2Kat.load()
        let s = try kat.session1()
        let stage2 = try NfcPairingV2Crypto.deriveStage2(prk1: s.stage1.prk1, thReader: try kat.derived("thReader"),
                                                         readerNonce: s.nonceReader, cardNonce: s.nonceCard)
        XCTAssertEqual(stage2.confirmKeyReader, try kat.derived("kConfirmReader"))
        XCTAssertEqual(stage2.confirmKeyCard, try kat.derived("kConfirmCard"))
        XCTAssertEqual(stage2.sasBytes, try kat.derived("sasBytes"))
        XCTAssertEqual(stage2.sas, try kat.string(["exchange", "derived", "sas"]))
        XCTAssertEqual(stage2.psk, try kat.derived("psk"))
        XCTAssertEqual(NfcPairingV2Crypto.sha256(stage2.psk).map { String(format: "%02x", $0) }.joined(),
                       try kat.string(["exchange", "derived", "pskFingerprint"]))
        XCTAssertEqual(PskAdvertising.canonicalFingerprint(forPsk: stage2.psk),
                       try kat.string(["exchange", "derived", "pskFingerprint"]))
        XCTAssertEqual(stage2.confirmReader, try kat.derived("confirmReader"))
        XCTAssertEqual(stage2.rejectReader, try kat.derived("rejectReader"))
        XCTAssertEqual(stage2.finalizeReader, try kat.derived("finalizeReader"))
        XCTAssertEqual(stage2.confirmCard, try kat.derived("confirmCard"))
        XCTAssertEqual(stage2.rejectCard, try kat.derived("rejectCard"))
        XCTAssertEqual(Set([stage2.confirmReader, stage2.rejectReader, stage2.finalizeReader, stage2.confirmCard, stage2.rejectCard]).count, 5)
    }

    // MARK: - APDUs

    func testEveryApduCommandMatchesTheVector() throws {
        let kat = try NfcPairingV2Kat.load()
        let s = try kat.session1()
        let apdus = try kat.apdus()
        func command(_ name: String) throws -> Data {
            try XCTUnwrap(apdus.first(where: { $0.name == name })?.command, name)
        }
        XCTAssertEqual(NfcApduCommand.select.encoded, try command("SELECT"))
        XCTAssertEqual(NfcApduCommand.select.encoded, try command("SELECT (tap 2)"))
        for index in 0..<NfcPairingV2.chunkCount {
            let chunk = s.ek.subdata(in: (index * NfcPairingV2.chunkBytes)..<((index + 1) * NfcPairingV2.chunkBytes))
            XCTAssertEqual(NfcApduCommand.proprietary(.ekPut, p1: UInt8(index), p2: 7, data: chunk).encoded,
                           try command("EK_PUT[\(index)]"))
            XCTAssertEqual(NfcApduCommand.proprietary(.ctGet, p1: UInt8(index), p2: 7, expectedLength: 224).encoded,
                           try command("CT_GET[\(index)]"))
        }
        XCTAssertEqual(NfcApduCommand.proprietary(.hello, data: try kat.derived("helloCommandData"), expectedLength: 64).encoded,
                       try command("HELLO"))
        XCTAssertEqual(NfcApduCommand.proprietary(.authCard, expectedLength: 256).encoded, try command("AUTH_C"))
        XCTAssertEqual(NfcApduCommand.proprietary(.reveal, data: s.sealedReader).encoded, try command("REVEAL"))
        let confirm = NfcApduCommand.proprietary(
            .confirm, data: Data([NfcPairingV2.Decision.confirm.rawValue]) + (try kat.derived("confirmReader")), expectedLength: 256)
        XCTAssertEqual(confirm.encoded, try command("CONFIRM (card pending)"))
        XCTAssertEqual(confirm.encoded, try command("CONFIRM (card confirmed)"))
        XCTAssertEqual(confirm.encoded, try command("CONFIRM (repeat after FINALIZE)"))
        let finalize = NfcApduCommand.proprietary(.finalize, data: try kat.derived("finalizeReader"), expectedLength: 256)
        XCTAssertEqual(finalize.encoded, try command("FINALIZE"))
        XCTAssertEqual(finalize.encoded, try command("FINALIZE (repeat)"))
        // Every APDU is short: Lc <= 255 and the responses fit Le <= 256.
        for apdu in apdus {
            XCTAssertLessThanOrEqual(apdu.command.count, 5 + 255 + 1, apdu.name)
            XCTAssertLessThanOrEqual(apdu.response.count, 256 + 2, apdu.name)
        }
        // Card responses of the vector.
        func response(_ name: String) throws -> Data {
            try XCTUnwrap(apdus.first(where: { $0.name == name })?.response, name)
        }
        XCTAssertEqual(try response("AUTH_C"), s.sealedCard + Data([0x90, 0x00]))
        XCTAssertEqual(try response("CONFIRM (card pending)"), Data([0x00, 0x90, 0x00]))
        XCTAssertEqual(try response("CONFIRM (card confirmed)"), Data([0x01]) + (try kat.derived("confirmCard")) + Data([0x90, 0x00]))
        XCTAssertEqual(try response("FINALIZE"), Data([0x01, 0x90, 0x00]))
    }

    // MARK: - Negative cases

    func testReaderNegativeCases() throws {
        let kat = try NfcPairingV2Kat.load()
        let s = try kat.session1()
        for entry in kat.negatives where (entry["checkedBy"] as? String) == "reader" {
            let name = try XCTUnwrap(entry["name"] as? String)
            var sealed: Data
            if let hex = entry["sealedCard"] as? String {
                sealed = try NfcPairingV2Kat.data(hex)
            } else if name == "card_auth_valid" {
                sealed = s.sealedCard
            } else if name == "user_id_too_long" {
                let block = s.card.publicKey + Data([65]) + Data(repeating: 0x61, count: 65)
                sealed = try ProximityPairingCrypto.aeadSeal(block + Data(count: 96), key: s.stage1.encCard, transcriptHash: s.th1)
            } else if name == "user_id_bad_char" {
                let block = s.card.publicKey + Data([5]) + Data("ab|cd".utf8)
                sealed = try ProximityPairingCrypto.aeadSeal(block + Data(count: 96), key: s.stage1.encCard, transcriptHash: s.th1)
            } else {
                XCTFail("unhandled reader negative \(name)")
                continue
            }
            var pinned: Data?
            if let hex = entry["expectedIdPub"] as? String { pinned = try NfcPairingV2Kat.data(hex) }
            let expected = entry["reason"] as? String
            do {
                _ = try NfcPairingV2Crypto.verifyCardAuth(sealed: sealed, stage1: s.stage1, th1: s.th1,
                                                          ownIdentityKey: s.reader.publicKey, pinnedPeerKey: pinned)
                XCTAssertNil(expected, "\(name) must be rejected as \(expected ?? "")")
            } catch let failure as NfcPairingV2Failure {
                XCTAssertEqual(failure.token.rawValue, expected, name)
            }
        }
    }

    func testCardNegativeCases() throws {
        let kat = try NfcPairingV2Kat.load()
        let s = try kat.session1()
        for entry in kat.negatives where (entry["checkedBy"] as? String) == "card" && entry["sealedReader"] != nil {
            let name = try XCTUnwrap(entry["name"] as? String)
            var stage1 = s.stage1
            var thCard = s.thCard
            var commit = s.commitReader
            if name == "self_identity_at_reveal" {
                // Own session: the vector gives the reader's encryption key, the transcript hash and the commitment.
                stage1 = NfcPairingV2Crypto.Stage1(prk1: Data(), encCard: Data(), encReader: try NfcPairingV2Kat.data(try XCTUnwrap(entry["kEncReader"] as? String)),
                                                   macCard: Data(), macReader: Data())
                thCard = try NfcPairingV2Kat.data(try XCTUnwrap(entry["thCard"] as? String))
                commit = try NfcPairingV2Kat.data(try XCTUnwrap(entry["commitReader"] as? String))
            }
            let sealed = try NfcPairingV2Kat.data(try XCTUnwrap(entry["sealedReader"] as? String))
            // In the loop-back session the reader presents the card's own key, so the card's key is "own" there too.
            let ownKey = s.card.publicKey
            let expected = entry["reason"] as? String
            do {
                _ = try NfcPairingV2Crypto.verifyReveal(sealed: sealed, stage1: stage1, thCard: thCard,
                                                        readerCommitment: commit, ownIdentityKey: ownKey)
                XCTFail("\(name) must be rejected as \(expected ?? "")")
            } catch let failure as NfcPairingV2Failure {
                XCTAssertEqual(failure.token.rawValue, expected, name)
            }
        }
        // The positive control.
        XCTAssertNoThrow(try NfcPairingV2Crypto.verifyReveal(
            sealed: s.sealedReader, stage1: s.stage1, thCard: s.thCard, readerCommitment: s.commitReader,
            ownIdentityKey: s.card.publicKey))
    }

    func testAllZeroX25519IsRefused() throws {
        let kat = try NfcPairingV2Kat.load()
        let entry = try kat.negative("x25519_all_zero")
        let zero = try NfcPairingV2Kat.data(try XCTUnwrap(entry["xpkCard"] as? String))
        XCTAssertEqual(zero, Data(count: 32))
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: try kat.input("x25519PrivReader"))
        XCTAssertThrowsError(try ProximityPairingCrypto.x25519SharedSecret(privateKey: key, peerPublicKey: zero))
    }

    func testConfirmationTagsDoNotCrossVerify() throws {
        let kat = try NfcPairingV2Kat.load()
        let entry = try kat.negative("confirm_tags_distinct")
        let cases = try XCTUnwrap(entry["cases"] as? [[String: Any]])
        let confirmReader = try kat.derived("confirmReader")
        for item in cases {
            let value = try NfcPairingV2Kat.data(try XCTUnwrap(item["value"] as? String))
            let accept = try XCTUnwrap(item["accept"] as? Bool)
            XCTAssertEqual(NfcPairingV2Crypto.tagMatches(value, confirmReader), accept)
        }
        // The card's matching never exits early and finds the candidate wherever it is.
        let tags = [try kat.derived("rejectReader"), confirmReader, try kat.derived("finalizeReader")]
        XCTAssertEqual(NfcPairingV2Crypto.matchTag(confirmReader, candidates: tags), 1)
        XCTAssertNil(NfcPairingV2Crypto.matchTag(try kat.derived("confirmCard"), candidates: tags))
    }

    func testRejectFlowBytes() throws {
        let kat = try NfcPairingV2Kat.load()
        let entry = try kat.negative("reject_flow")
        let readerRejects = try XCTUnwrap(entry["readerRejects"] as? [String: Any])
        let rejectCommand = NfcApduCommand.proprietary(
            .confirm, data: Data([NfcPairingV2.Decision.reject.rawValue]) + (try kat.derived("rejectReader")), expectedLength: 256)
        XCTAssertEqual(rejectCommand.encoded, try NfcPairingV2Kat.data(try XCTUnwrap(readerRejects["command"] as? String)))
        XCTAssertEqual(try NfcPairingV2Kat.data(try XCTUnwrap(readerRejects["response"] as? String)),
                       Data([NfcPairingV2.CardState.aborted.rawValue, 0x90, 0x00]))
        let cardRejected = try XCTUnwrap(entry["cardRejected"] as? [String: Any])
        XCTAssertEqual(try NfcPairingV2Kat.data(try XCTUnwrap(cardRejected["response"] as? String)),
                       Data([NfcPairingV2.CardState.rejected.rawValue]) + (try kat.derived("rejectCard")) + Data([0x90, 0x00]))
        XCTAssertEqual(try NfcPairingV2Kat.data(try XCTUnwrap(cardRejected["forgedResponse"] as? String)),
                       Data([NfcPairingV2.CardState.rejected.rawValue]) + (try kat.derived("rejectReader")) + Data([0x90, 0x00]))
        // The reject tag is not a confirm tag.
        let asConfirm = try XCTUnwrap(entry["rejectTagAsConfirm"] as? [String: Any])
        XCTAssertEqual(try NfcPairingV2Kat.data(try XCTUnwrap(asConfirm["response"] as? String)),
                       Data([NfcPairingV2.CardState.noCeremony.rawValue, 0x90, 0x00]))
    }

    func testTheCodeIsFreshForEverySession() throws {
        let kat = try NfcPairingV2Kat.load()
        let entry = try kat.negative("sas_per_session")
        let one = try XCTUnwrap(entry["sasSession1"] as? String)
        let two = try XCTUnwrap(entry["sasSession2"] as? String)
        XCTAssertNotEqual(one, two)
        XCTAssertEqual(one, try kat.string(["exchange", "derived", "sas"]))
        XCTAssertEqual(two, try kat.string(["exchangeSession2", "derived", "sas"]))
        XCTAssertNotEqual(try kat.string(["exchange", "derived", "psk"]), try kat.string(["exchangeSession2", "derived", "psk"]))
        let mitm = try kat.negative("mitm_two_sessions")
        XCTAssertNotEqual(mitm["sasOnReader"] as? String, mitm["sasOnCard"] as? String)
    }

    // MARK: - Framing, answered by the card

    func testFramingStatusWords() async throws {
        let kat = try NfcPairingV2Kat.load()
        let entry = try kat.negative("framing")
        let cases = try XCTUnwrap(entry["cases"] as? [[String: Any]])
        var simple = 0
        for item in cases where item["after"] == nil {
            let bytes = try NfcPairingV2Kat.data(try XCTUnwrap(item["command"] as? String))
            let sw = try XCTUnwrap(item["sw"] as? String)
            let card = try NfcCardSimulator(seed: Data(repeating: 1, count: 32),
                                            publicKey: try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32)).publicKey.rawRepresentation,
                                            userId: "card")
            let response = try await card.transceive(try Self.parse(bytes))
            XCTAssertEqual(String(format: "%04x", response.statusWord), sw.lowercased(), "\(item["command"] ?? "")")
            simple += 1
        }
        XCTAssertGreaterThanOrEqual(simple, 6)

        // The ordered cases.
        let s = try kat.session1()
        func makeCard() throws -> NfcCardSimulator {
            try NfcCardSimulator(seed: Data(repeating: 2, count: 32),
                                 publicKey: try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 2, count: 32)).publicKey.rawRepresentation,
                                 userId: "card")
        }
        func put(_ card: NfcCardSimulator, _ index: Int, _ bytes: Data) async throws -> UInt16 {
            try await card.transceive(NfcApduCommand.proprietary(.ekPut, p1: UInt8(index), p2: 7, data: bytes)).statusWord
        }
        let chunk0 = s.ek.subdata(in: 0..<NfcPairingV2.chunkBytes)
        // Out of order.
        var card = try makeCard()
        var status = try await put(card, 0, chunk0)
        XCTAssertEqual(status, 0x9000)
        status = try await put(card, 2, Data(count: NfcPairingV2.chunkBytes))
        XCTAssertEqual(status, 0x6985)
        // Last chunk repeated: identical bytes are fine, different bytes are not.
        card = try makeCard()
        _ = try await put(card, 0, chunk0)
        status = try await put(card, 0, chunk0)
        XCTAssertEqual(status, 0x9000)
        status = try await put(card, 0, Data(count: NfcPairingV2.chunkBytes))
        XCTAssertEqual(status, 0x6A80)
        // An encapsulation key that fails the FIPS 203 modulus check.
        card = try makeCard()
        for index in 0..<NfcPairingV2.chunkCount - 1 {
            status = try await put(card, index, Data(repeating: 0xFF, count: NfcPairingV2.chunkBytes))
            XCTAssertEqual(status, 0x9000)
        }
        status = try await put(card, NfcPairingV2.chunkCount - 1, Data(repeating: 0xFF, count: NfcPairingV2.chunkBytes))
        XCTAssertEqual(status, 0x6A80)
        // FINALIZE with no ceremony.
        card = try makeCard()
        let finalize = try await card.transceive(NfcApduCommand.proprietary(.finalize, data: Data(count: 32), expectedLength: 256))
        XCTAssertEqual(finalize.statusWord, 0x9000)
        XCTAssertEqual(finalize.data, Data([NfcPairingV2.CardState.noCeremony.rawValue]))
    }

    /// Parses `CLA INS P1 P2 [Lc data] [Le]` (the cases of the vector).
    static func parse(_ bytes: Data) throws -> NfcApduCommand {
        let b = [UInt8](bytes)
        guard b.count >= 4 else { throw NfcPairingV2Kat.KatError(description: "short apdu") }
        var data = Data()
        var le: Int?
        if b.count == 5 {
            le = b[4] == 0 ? 256 : Int(b[4])
        } else if b.count > 5 {
            let lc = Int(b[4])
            data = Data(b[5..<(5 + lc)])
            if b.count > 5 + lc { le = b[5 + lc] == 0 ? 256 : Int(b[5 + lc]) }
        }
        return NfcApduCommand(cla: b[0], ins: b[1], p1: b[2], p2: b[3], data: data, expectedLength: le)
    }
}
