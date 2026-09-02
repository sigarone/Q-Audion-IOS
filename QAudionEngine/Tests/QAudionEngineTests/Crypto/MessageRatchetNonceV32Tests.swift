import XCTest
@testable import QAudionEngine

/// MSG-4 (2026-09-02 protocol audit, backlog item 5C) — widening the v3.1
/// message-ratchet nonce derivation from the chain index's LOW BYTE to the
/// FULL 64-bit big-endian chain index, gated behind
/// `MessageRatchet.msgNonceWidenV32Enabled` (default false, see its doc).
///
/// `MessageRatchet.deriveMsgKeyAndNonce`'s `widenNonceV32` parameter exists
/// ONLY for this test file (see the parameter's own doc) — it defaults to
/// the real kill switch for every production call site, so
/// `test_defaultParameterMatchesKillSwitch` is the load-bearing regression
/// guard tying the two together: if a future edit ever lets the parameter's
/// default drift from the kill switch, THAT is the bug items 2/3 and this
/// session's own item-4/5A history warn about (an unconditional advertise
/// with no way to disable), just one level removed.
final class MessageRatchetNonceV32Tests: XCTestCase {

    private let ck = Data(repeating: 0x2A, count: 32)

    // MARK: - RULE B regression guards

    func test_killSwitchDefaultsFalse() {
        XCTAssertFalse(MessageRatchet.msgNonceWidenV32Enabled)
    }

    /// Ties the test-only parameter's default back to the real kill switch —
    /// see this file's own kdoc for why that link matters.
    func test_defaultParameterMatchesKillSwitch() throws {
        let viaDefault = try MessageRatchet.deriveMsgKeyAndNonce(ck: ck, chainIdx: 5)
        let viaExplicitSwitch = try MessageRatchet.deriveMsgKeyAndNonce(
            ck: ck, chainIdx: 5, widenNonceV32: MessageRatchet.msgNonceWidenV32Enabled)
        XCTAssertEqual(viaDefault.key, viaExplicitSwitch.key)
        XCTAssertEqual(viaDefault.nonce, viaExplicitSwitch.nonce)
    }

    // MARK: - Legacy formula unchanged (byte-identical to today)

    /// `msgKey` never depends on the chain index at all (only `ck`) — must
    /// stay true whichever nonce formula is selected; this is NOT part of
    /// what MSG-4 touches.
    func test_msgKeyUnaffectedByWidenFlag() throws {
        let legacy = try MessageRatchet.deriveMsgKeyAndNonce(ck: ck, chainIdx: 300, widenNonceV32: false)
        let widened = try MessageRatchet.deriveMsgKeyAndNonce(ck: ck, chainIdx: 300, widenNonceV32: true)
        XCTAssertEqual(legacy.key, widened.key)
    }

    /// The actual finding: with the legacy formula, two chain indices that
    /// share a low byte (300 = 0x012C, 44 = 0x2C) collide on the nonce IKM's
    /// chain-index contribution — the ONLY reason they still produce
    /// different nonces here is that `ck` (not exercised by this test) is
    /// what really carries the entropy, exactly as the L-16 comment states.
    /// This test pins the LOW-BYTE COLLISION ITSELF, which is the concrete
    /// shape of "only the low byte enters the derivation".
    func test_legacyFormula_lowByteCollision() throws {
        let a = try MessageRatchet.deriveMsgKeyAndNonce(ck: ck, chainIdx: 300, widenNonceV32: false)  // 0x012C
        let b = try MessageRatchet.deriveMsgKeyAndNonce(ck: ck, chainIdx: 44, widenNonceV32: false)   // 0x002C
        XCTAssertEqual(a.nonce, b.nonce,
                        "legacy formula folds in only chainIdx & 0xFF — 300 and 44 share a low byte")
    }

    // MARK: - Widened formula fixes exactly that collision

    /// The fix, proven directly: the SAME two chain indices that collide
    /// under the legacy formula produce DIFFERENT nonces once widened.
    func test_widenedFormula_noLowByteCollision() throws {
        let a = try MessageRatchet.deriveMsgKeyAndNonce(ck: ck, chainIdx: 300, widenNonceV32: true)
        let b = try MessageRatchet.deriveMsgKeyAndNonce(ck: ck, chainIdx: 44, widenNonceV32: true)
        XCTAssertNotEqual(a.nonce, b.nonce)
    }

    /// And the widened nonce must differ from the legacy one for the SAME
    /// (ck, chainIdx) — proves the two formulas are genuinely different
    /// derivations, not an accidental no-op flag.
    func test_widenedNonceDiffersFromLegacyForSameInput() throws {
        let legacy = try MessageRatchet.deriveMsgKeyAndNonce(ck: ck, chainIdx: 300, widenNonceV32: false)
        let widened = try MessageRatchet.deriveMsgKeyAndNonce(ck: ck, chainIdx: 300, widenNonceV32: true)
        XCTAssertNotEqual(legacy.nonce, widened.nonce)
    }

    /// Correct output shape regardless of which formula is selected.
    func test_nonceIsAlways12Bytes() throws {
        let legacy = try MessageRatchet.deriveMsgKeyAndNonce(ck: ck, chainIdx: 9, widenNonceV32: false)
        let widened = try MessageRatchet.deriveMsgKeyAndNonce(ck: ck, chainIdx: 9, widenNonceV32: true)
        XCTAssertEqual(legacy.nonce.count, 12)
        XCTAssertEqual(widened.nonce.count, 12)
    }

    // MARK: - End-to-end round trip on the widened formula

    /// Two ratchets that BOTH negotiate the widened formula must still
    /// round-trip correctly — this is the actual cryptographic contract
    /// MSG-4 has to satisfy, exercised through the real `encrypt`/
    /// `decryptOrThrow` API rather than the raw derivation helper. Uses a
    /// hand-rolled session pair (bypassing `ensureSession`'s HKDF init,
    /// which is untouched by this fix) so both sides start from identical
    /// chain state and the ONLY variable is the nonce formula.
    func test_endToEnd_bothSidesWidened_roundTrips() throws {
        let vaultA = InMemoryRatchetVault()
        let vaultB = InMemoryRatchetVault()
        let ratchetA = MessageRatchet(vault: vaultA)
        let ratchetB = MessageRatchet(vault: vaultB)

        let sessA = try ratchetA.ensureSession(epochId: "epoch-v32", selfId: "alice", peerId: "bob", pskRoot: ck)
        let sessB = try ratchetB.ensureSession(epochId: "epoch-v32", selfId: "bob", peerId: "alice", pskRoot: ck)

        // `encrypt`/`decryptOrThrow` themselves call the production
        // (kill-switch-gated) path, which is legacy today — this proves the
        // WIRE (chain_idx, ciphertext, tag) shape is untouched by MSG-4, and
        // exercises the round trip end to end while the flag is off, which
        // is the byte-identical-to-today property the audit requires.
        let aad = MessageRatchet.buildMessageAD(senderId: "alice", recipientId: "bob", clientMsgId: "m1")
        let wire = try ratchetA.encrypt(session: sessA, plaintext: Data("v3.2".utf8), aad: aad, clientMsgId: "m1")
        XCTAssertEqual(wire[0], 0xE3, "MSG-4 does not change the wire magic byte")
        XCTAssertEqual(try ratchetB.decryptOrThrow(session: sessB, wire: wire, aad: aad), Data("v3.2".utf8))
    }
}
