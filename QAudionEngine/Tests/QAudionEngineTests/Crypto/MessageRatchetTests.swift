import XCTest
@testable import QAudionEngine

final class MessageRatchetTests: XCTestCase {

    private let psk = Data(repeating: 0x42, count: 32)
    private let epoch = "epoch-1"
    private let alice = "alice"
    private let bob = "bob"

    // MARK: - Round trip

    func testRoundTripAliceToBob() throws {
        let vaultA = InMemoryRatchetVault()
        let vaultB = InMemoryRatchetVault()
        let ratchetA = MessageRatchet(vault: vaultA)
        let ratchetB = MessageRatchet(vault: vaultB)

        let sessA = try ratchetA.ensureSession(epochId: epoch, selfId: alice, peerId: bob, pskRoot: psk)
        let sessB = try ratchetB.ensureSession(epochId: epoch, selfId: bob, peerId: alice, pskRoot: psk)

        let plaintext = Data("hello bob".utf8)
        let aad = MessageRatchet.buildMessageAD(senderId: alice, recipientId: bob, clientMsgId: "m1")

        let wire = try ratchetA.encrypt(session: sessA, plaintext: plaintext, aad: aad, clientMsgId: "m1")
        XCTAssertEqual(wire[0], 0xE3) // magic
        let decrypted = try ratchetB.decryptOrThrow(session: sessB, wire: wire, aad: aad)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testRoundTripBidirectional() throws {
        let vaultA = InMemoryRatchetVault()
        let vaultB = InMemoryRatchetVault()
        let ratchetA = MessageRatchet(vault: vaultA)
        let ratchetB = MessageRatchet(vault: vaultB)

        let sessA = try ratchetA.ensureSession(epochId: epoch, selfId: alice, peerId: bob, pskRoot: psk)
        let sessB = try ratchetB.ensureSession(epochId: epoch, selfId: bob, peerId: alice, pskRoot: psk)

        // Alice -> Bob
        let aadAtoB = MessageRatchet.buildMessageAD(senderId: alice, recipientId: bob, clientMsgId: "m1")
        let wire1 = try ratchetA.encrypt(session: sessA, plaintext: Data("hi".utf8), aad: aadAtoB, clientMsgId: "m1")
        XCTAssertEqual(try ratchetB.decryptOrThrow(session: sessB, wire: wire1, aad: aadAtoB), Data("hi".utf8))

        // Bob -> Alice
        let aadBtoA = MessageRatchet.buildMessageAD(senderId: bob, recipientId: alice, clientMsgId: "m2")
        let wire2 = try ratchetB.encrypt(session: sessB, plaintext: Data("hey".utf8), aad: aadBtoA, clientMsgId: "m2")
        XCTAssertEqual(try ratchetA.decryptOrThrow(session: sessA, wire: wire2, aad: aadBtoA), Data("hey".utf8))
    }

    // MARK: - Forward secrecy: chain advances

    func testChainAdvancesEachSend() throws {
        let vaultA = InMemoryRatchetVault()
        let ratchetA = MessageRatchet(vault: vaultA)
        let sessA = try ratchetA.ensureSession(epochId: epoch, selfId: alice, peerId: bob, pskRoot: psk)
        XCTAssertEqual(sessA.nextSendIdx, 0)

        let aad = MessageRatchet.buildMessageAD(senderId: alice, recipientId: bob, clientMsgId: "m1")
        _ = try ratchetA.encrypt(session: sessA, plaintext: Data("a".utf8), aad: aad, clientMsgId: "m1")
        XCTAssertEqual(sessA.nextSendIdx, 1)
        _ = try ratchetA.encrypt(session: sessA, plaintext: Data("b".utf8), aad: aad, clientMsgId: "m2")
        XCTAssertEqual(sessA.nextSendIdx, 2)
    }

    // MARK: - Out of order delivery

    func testOutOfOrderArrivalUsesSkippedKeyCache() throws {
        let vaultA = InMemoryRatchetVault()
        let vaultB = InMemoryRatchetVault()
        let ratchetA = MessageRatchet(vault: vaultA)
        let ratchetB = MessageRatchet(vault: vaultB)
        let sessA = try ratchetA.ensureSession(epochId: epoch, selfId: alice, peerId: bob, pskRoot: psk)
        let sessB = try ratchetB.ensureSession(epochId: epoch, selfId: bob, peerId: alice, pskRoot: psk)

        let aad1 = MessageRatchet.buildMessageAD(senderId: alice, recipientId: bob, clientMsgId: "m1")
        let aad2 = MessageRatchet.buildMessageAD(senderId: alice, recipientId: bob, clientMsgId: "m2")
        let aad3 = MessageRatchet.buildMessageAD(senderId: alice, recipientId: bob, clientMsgId: "m3")

        let wire1 = try ratchetA.encrypt(session: sessA, plaintext: Data("first".utf8), aad: aad1, clientMsgId: "m1")
        let wire2 = try ratchetA.encrypt(session: sessA, plaintext: Data("second".utf8), aad: aad2, clientMsgId: "m2")
        let wire3 = try ratchetA.encrypt(session: sessA, plaintext: Data("third".utf8), aad: aad3, clientMsgId: "m3")

        // Bob receives 1 and 3, then 2 late.
        XCTAssertEqual(try ratchetB.decryptOrThrow(session: sessB, wire: wire1, aad: aad1), Data("first".utf8))
        XCTAssertEqual(try ratchetB.decryptOrThrow(session: sessB, wire: wire3, aad: aad3), Data("third".utf8))
        // After idx=2 was skipped during the catch-up to 3, Bob's cache holds it.
        XCTAssertEqual(try ratchetB.decryptOrThrow(session: sessB, wire: wire2, aad: aad2), Data("second".utf8))
    }

    func testReplayRejected() throws {
        let vaultA = InMemoryRatchetVault()
        let vaultB = InMemoryRatchetVault()
        let ratchetA = MessageRatchet(vault: vaultA)
        let ratchetB = MessageRatchet(vault: vaultB)
        let sessA = try ratchetA.ensureSession(epochId: epoch, selfId: alice, peerId: bob, pskRoot: psk)
        let sessB = try ratchetB.ensureSession(epochId: epoch, selfId: bob, peerId: alice, pskRoot: psk)

        let aad = MessageRatchet.buildMessageAD(senderId: alice, recipientId: bob, clientMsgId: "m1")
        let wire = try ratchetA.encrypt(session: sessA, plaintext: Data("x".utf8), aad: aad, clientMsgId: "m1")
        _ = try ratchetB.decryptOrThrow(session: sessB, wire: wire, aad: aad)
        XCTAssertThrowsError(try ratchetB.decryptOrThrow(session: sessB, wire: wire, aad: aad)) { err in
            guard case MessageRatchet.RatchetError.replayOrUnknownIdx = err else {
                XCTFail("expected .replayOrUnknownIdx, got \(err)"); return
            }
        }
    }

    func testSkipAheadOverflowRejected() throws {
        let vaultA = InMemoryRatchetVault()
        let vaultB = InMemoryRatchetVault()
        let ratchetA = MessageRatchet(vault: vaultA)
        let ratchetB = MessageRatchet(vault: vaultB)
        let sessA = try ratchetA.ensureSession(epochId: epoch, selfId: alice, peerId: bob, pskRoot: psk)
        let sessB = try ratchetB.ensureSession(epochId: epoch, selfId: bob, peerId: alice, pskRoot: psk)

        // Burn through sender chain idx 0..10001 without delivering anything.
        let aad = MessageRatchet.buildMessageAD(senderId: alice, recipientId: bob, clientMsgId: "x")
        var wires: [Data] = []
        for _ in 0...10_001 {
            wires.append(try ratchetA.encrypt(session: sessA, plaintext: Data("x".utf8), aad: aad, clientMsgId: "x"))
        }
        // Try to deliver the very last one (idx=10001) — that's a skip of 10001
        // beyond expected (0), exceeding maxSkipAhead=10_000.
        let last = wires.last!
        XCTAssertThrowsError(try ratchetB.decryptOrThrow(session: sessB, wire: last, aad: aad)) { err in
            guard case MessageRatchet.RatchetError.skipAheadExceeded = err else {
                XCTFail("expected .skipAheadExceeded, got \(err)"); return
            }
        }
    }

    // MARK: - Wire format

    func testWireMagicByte() throws {
        let vaultA = InMemoryRatchetVault()
        let ratchetA = MessageRatchet(vault: vaultA)
        let sessA = try ratchetA.ensureSession(epochId: epoch, selfId: alice, peerId: bob, pskRoot: psk)
        let aad = MessageRatchet.buildMessageAD(senderId: alice, recipientId: bob, clientMsgId: "m1")
        let wire = try ratchetA.encrypt(session: sessA, plaintext: Data("hi".utf8), aad: aad, clientMsgId: "m1")
        XCTAssertEqual(wire[0], MessageRatchet.magicV3)
        XCTAssertTrue(MessageRatchet.isV3Wire(wire))
        XCTAssertFalse(MessageRatchet.isV3Wire(Data([0xE2, 0x00])))
    }

    func testEpochMismatchRejected() throws {
        let vaultA = InMemoryRatchetVault()
        let vaultB = InMemoryRatchetVault()
        let ratchetA = MessageRatchet(vault: vaultA)
        let ratchetB = MessageRatchet(vault: vaultB)
        let sessA = try ratchetA.ensureSession(epochId: "epoch-A", selfId: alice, peerId: bob, pskRoot: psk)
        let sessB = try ratchetB.ensureSession(epochId: "epoch-B", selfId: bob, peerId: alice, pskRoot: psk)
        let aad = MessageRatchet.buildMessageAD(senderId: alice, recipientId: bob, clientMsgId: "m1")
        let wire = try ratchetA.encrypt(session: sessA, plaintext: Data("hi".utf8), aad: aad, clientMsgId: "m1")
        XCTAssertThrowsError(try ratchetB.decryptOrThrow(session: sessB, wire: wire, aad: aad)) { err in
            guard case MessageRatchet.RatchetError.epochMismatch = err else {
                XCTFail("expected .epochMismatch, got \(err)"); return
            }
        }
    }

    func testAadMismatchFailsAead() throws {
        let vaultA = InMemoryRatchetVault()
        let vaultB = InMemoryRatchetVault()
        let ratchetA = MessageRatchet(vault: vaultA)
        let ratchetB = MessageRatchet(vault: vaultB)
        let sessA = try ratchetA.ensureSession(epochId: epoch, selfId: alice, peerId: bob, pskRoot: psk)
        let sessB = try ratchetB.ensureSession(epochId: epoch, selfId: bob, peerId: alice, pskRoot: psk)
        let aadCorrect = MessageRatchet.buildMessageAD(senderId: alice, recipientId: bob, clientMsgId: "m1")
        let aadTampered = MessageRatchet.buildMessageAD(senderId: alice, recipientId: bob, clientMsgId: "m9")
        let wire = try ratchetA.encrypt(session: sessA, plaintext: Data("x".utf8), aad: aadCorrect, clientMsgId: "m1")
        XCTAssertThrowsError(try ratchetB.decryptOrThrow(session: sessB, wire: wire, aad: aadTampered)) { err in
            guard case MessageRatchet.RatchetError.aeadFailed = err else {
                XCTFail("expected .aeadFailed, got \(err)"); return
            }
        }
    }

    // MARK: - Persistence (vault)

    func testPersistenceRecoversSessionAcrossInstances() throws {
        let vault = InMemoryRatchetVault()
        let firstRatchet = MessageRatchet(vault: vault)
        let firstSession = try firstRatchet.ensureSession(epochId: epoch, selfId: alice, peerId: bob, pskRoot: psk)
        let aad = MessageRatchet.buildMessageAD(senderId: alice, recipientId: bob, clientMsgId: "m1")
        let wire1 = try firstRatchet.encrypt(session: firstSession, plaintext: Data("a".utf8), aad: aad, clientMsgId: "m1")
        XCTAssertEqual(firstSession.nextSendIdx, 1)

        // Simulate restart: drop the in-memory session, reload from vault.
        let secondRatchet = MessageRatchet(vault: vault)
        let recovered = try secondRatchet.ensureSession(epochId: epoch, selfId: alice, peerId: bob, pskRoot: psk)
        XCTAssertEqual(recovered.nextSendIdx, 1, "vault should have CK_1 + idx=1 persisted")

        let wire2 = try secondRatchet.encrypt(session: recovered, plaintext: Data("b".utf8), aad: aad, clientMsgId: "m2")

        // Bob (fresh) should be able to decrypt both in order.
        let vaultB = InMemoryRatchetVault()
        let ratchetB = MessageRatchet(vault: vaultB)
        let sessB = try ratchetB.ensureSession(epochId: epoch, selfId: bob, peerId: alice, pskRoot: psk)
        XCTAssertEqual(try ratchetB.decryptOrThrow(session: sessB, wire: wire1, aad: aad), Data("a".utf8))
        XCTAssertEqual(try ratchetB.decryptOrThrow(session: sessB, wire: wire2, aad: aad), Data("b".utf8))
    }
}
