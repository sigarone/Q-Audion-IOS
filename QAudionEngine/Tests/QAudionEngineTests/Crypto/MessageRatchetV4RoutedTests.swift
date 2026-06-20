import XCTest
@testable import QAudionEngine

/// Phase 18 (iOS) — tests for the v4 VAULT-ROUTED dispatch surface on
/// ``MessageRatchet`` (`bootstrapV4AndPersist` / `hasV4Session` / `encryptV4Routed`
/// / `decryptV4Routed`) + the `RatchetVault` v4 keyspace + the 0xE5 wire detection.
///
/// Mirrors the Android instrumented tests `MessageRatchetV4RoutedInstrumentedTest`
/// + `MessageCryptoV4DispatchInstrumentedTest`, adapted to the iOS engine-tests CI
/// reality:
///
///   - The Android tests run on a real arm64 DEVICE with the native `.so` linked,
///     so they always exercise the crypto. The iOS `engine-tests.yml` runs `swift
///     test` against the FAIL-CLOSED placeholder stub (``RatchetNative/available``
///     == false), so the round-trip body is gated behind `XCTSkipUnless(available)`
///     — identical to ``RatchetNativeRoundTripTests`` / ``RatchetNativeV4Tests``.
///   - The vault is ``InMemoryRatchetVault`` (Keychain has no entitlement under
///     `swift test`), exercising the SAME v4 routed methods + v4 keyspace the
///     production ``KeychainRatchetVault`` implements, keyed by peerId under
///     ``MessageRatchet/v4RoutingEpoch``.
///
/// What ALWAYS runs (stub CI, flag OFF — the live production state):
///   - The default-OFF tripwire is covered by ``RatchetNativeV4Tests``.
///   - Every routed method FAIL-CLOSES while disabled (no session, no frame, no
///     plaintext) — the live messaging path can never accidentally engage v4.
///   - The 0xE5 wire is detected as `.v4` and is distinct from v3 (`.v3`).
///   - The vault v4 keyspace round-trips opaque blobs and is separate from v3.1.
final class MessageRatchetV4RoutedTests: XCTestCase {

    // idA < idB (unsigned-byte) → A is lex-min. 16-zero per-direction epoch_ids
    // (the cross-platform constant — HandshakeSigner derives all-zero).
    private let idA = Data(repeating: 0x11, count: 32)
    private let idB = Data(repeating: 0x22, count: 32)
    private let th  = Data(repeating: 0x77, count: 32)
    private let zero = Data(repeating: 0, count: 16)
    private let secret = Data((0..<32).map { UInt8(0x90 &+ $0) })

    // MARK: - Wiring contract (ALWAYS runs — stub CI, flag OFF)

    /// Constants match Android byte-for-byte: the vault routing-epoch tag and the
    /// 0xE5 magic must agree cross-platform or send/receive route to a different key.
    func testV4RoutingConstantsMatchAndroid() {
        XCTAssertEqual(MessageRatchet.v4RoutingEpoch, "v4")
        XCTAssertEqual(MessageRatchet.magicV4, 0xE5)
    }

    /// 0xE5 detection is distinct from v3 so the receive dispatcher routes a v4
    /// frame to `decryptV4Routed` (by peer) and NEVER to the v3.1 parser.
    func testWireDetectV4() {
        XCTAssertEqual(MessageWireFormat.detect(Data([0xE5, 0x04, 0x00])), .v4)
        XCTAssertTrue(MessageWireFormat.isV4(Data([0xE5])))
        XCTAssertFalse(MessageWireFormat.isV4(Data([0xE3])))   // v3 not misread as v4
        XCTAssertEqual(MessageWireFormat.detect(Data([0xE3, 0x00])), .v3)
        XCTAssertFalse(MessageWireFormat.isV4(Data()))
    }

    /// With the production default (flag off), EVERY routed v4 method fail-closes
    /// regardless of stored state — the live path can never accidentally engage v4.
    /// (Mirrors Android `routedMethods_areInert_whenFlagOff`.)
    func testRoutedMethodsAreInertWhenFlagOff() {
        // The shipped build has the flag off; if the real core were also linked
        // the routed ops could engage, so additionally require the core to be the
        // stub for this assertion to be meaningful. When the real core IS linked
        // the dedicated round-trip test below covers the live behaviour.
        guard !MessageRatchet(vault: InMemoryRatchetVault()).isV4Enabled() else {
            // v4 actually enabled (real core + flag on) — inert assertions N/A.
            return
        }
        let vault = InMemoryRatchetVault()
        let ratchet = MessageRatchet(vault: vault)

        XCTAssertFalse(
            ratchet.bootstrapV4AndPersist(
                peerId: "B", effectiveSecret: secret, selfEpochId: zero, peerEpochId: zero,
                selfIdentityPub: idA, peerIdentityPub: idB, transcriptHash: th),
            "bootstrapV4AndPersist must fail-close (false) while v4 is disabled")
        XCTAssertFalse(ratchet.hasV4Session("B"))
        XCTAssertNil(ratchet.encryptV4Routed(peerId: "B", plaintext: Data("x".utf8)))
        XCTAssertNil(ratchet.decryptV4Routed(peerId: "A", frame: Data([0xE5, 0x04, 0x00])))
        // Nothing was persisted into the v4 keyspace.
        XCTAssertNil(vault.loadV4(epochId: MessageRatchet.v4RoutingEpoch, peerId: "B"))
    }

    /// The vault's v4 keyspace stores opaque blobs verbatim and is SEPARATE from
    /// the v3.1 snapshot keyspace for the same (epochId, peerId). Independent of
    /// the native core — pure storage contract.
    func testVaultV4KeyspaceIsSeparateAndVerbatim() throws {
        let vault = InMemoryRatchetVault()
        let blob = Data([0xE5, 0x01, 0x02, 0x03, 0xAB, 0xCD])
        XCTAssertNil(vault.loadV4(epochId: "v4", peerId: "B"))
        try vault.saveV4(epochId: "v4", peerId: "B", blob: blob)
        XCTAssertEqual(vault.loadV4(epochId: "v4", peerId: "B"), blob, "v4 blob must round-trip verbatim")
        // Different peer → independent slot.
        XCTAssertNil(vault.loadV4(epochId: "v4", peerId: "A"))
        // v3.1 snapshot load for the same key is unaffected (separate keyspace).
        XCTAssertNil(vault.load(epochId: "v4", peerId: "B"))
        vault.deleteV4(epochId: "v4", peerId: "B")
        XCTAssertNil(vault.loadV4(epochId: "v4", peerId: "B"))
    }

    /// The default `RatchetVault` protocol bodies fail-closed (a non-v4 vault
    /// forces a re-bootstrap): loadV4 → nil, saveV4/deleteV4 → no-op.
    func testProtocolDefaultV4BodiesAreNoOp() throws {
        final class V3OnlyVault: RatchetVault, @unchecked Sendable {
            func load(epochId: String, peerId: String) -> RatchetSnapshot? { nil }
            func save(epochId: String, peerId: String, snapshot: RatchetSnapshot) throws {}
            func delete(epochId: String, peerId: String) {}
            // Intentionally does NOT override loadV4/saveV4/deleteV4 — exercises the
            // protocol-extension defaults.
        }
        let v = V3OnlyVault()
        XCTAssertNil(v.loadV4(epochId: "v4", peerId: "B"))
        XCTAssertNoThrow(try v.saveV4(epochId: "v4", peerId: "B", blob: Data([0x01])))
        XCTAssertNil(v.loadV4(epochId: "v4", peerId: "B"), "default saveV4 is a no-op")
        v.deleteV4(epochId: "v4", peerId: "B")  // must not crash
    }

    // MARK: - Full routed round-trip (runs ONLY with the real core linked)

    /// End-to-end v4 routed flow through the vault, mirroring Android
    /// `MessageRatchetV4RoutedInstrumentedTest.v4RoutedFlow_*`: two peers in ONE
    /// vault keyed by distinct peerIds (A's view of B under peer="B", B's view of
    /// A under peer="A"), bootstrap+persist, 5 in-order A→B round-trips with on-disk
    /// chain advance each step, reverse direction, and a tampered-frame fail-close.
    ///
    /// Skipped under the fail-closed stub (engine-tests CI today); runs when the
    /// real `QaudionCryptoCore.xcframework` is linked AND the flag is flipped on.
    func testV4RoutedRoundTripWithRealCore() throws {
        try XCTSkipUnless(
            RatchetNative.available && MessageRatchet.v4NativeRatchetEnabled,
            "v4 routed round-trip needs the real native core linked AND the flag ON")

        let vault = InMemoryRatchetVault()
        let ratchet = MessageRatchet(vault: vault)

        // A bootstraps toward peer "B" (A = lex-min from idA<idB); B toward "A".
        XCTAssertTrue(ratchet.bootstrapV4AndPersist(
            peerId: "B", effectiveSecret: secret, selfEpochId: zero, peerEpochId: zero,
            selfIdentityPub: idA, peerIdentityPub: idB, transcriptHash: th),
            "A bootstrapV4AndPersist failed")
        XCTAssertTrue(ratchet.bootstrapV4AndPersist(
            peerId: "A", effectiveSecret: secret, selfEpochId: zero, peerEpochId: zero,
            selfIdentityPub: idB, peerIdentityPub: idA, transcriptHash: th),
            "B bootstrapV4AndPersist failed")

        XCTAssertTrue(ratchet.hasV4Session("B"))
        XCTAssertTrue(ratchet.hasV4Session("A"))
        XCTAssertNotNil(vault.loadV4(epochId: MessageRatchet.v4RoutingEpoch, peerId: "B"))

        // 5 in-order A→B messages: each call re-loads → native op → re-serializes,
        // so the chain advances on disk every message (write-ahead + crash-resume).
        for i in 0..<5 {
            let pt = Data("routed v4 msg \(i)".utf8)
            let frame = ratchet.encryptV4Routed(peerId: "B", plaintext: pt)  // A's send chain
            XCTAssertNotNil(frame, "encryptV4Routed(\(i)) returned nil")
            XCTAssertEqual(frame?.first, MessageRatchet.magicV4, "frame must carry 0xE5")
            let got = ratchet.decryptV4Routed(peerId: "A", frame: frame!)     // B's recv chain
            XCTAssertEqual(got, pt, "round-trip \(i) mismatch")
        }

        // Reverse direction B→A on the same persisted sessions.
        let rpt = Data("reverse direction".utf8)
        let rframe = ratchet.encryptV4Routed(peerId: "A", plaintext: rpt)     // B's send chain
        XCTAssertEqual(rframe?.first, MessageRatchet.magicV4)
        XCTAssertEqual(ratchet.decryptV4Routed(peerId: "B", frame: rframe!), rpt)

        // Fail-closed: a tampered frame yields nil and does NOT clobber state.
        var bad = ratchet.encryptV4Routed(peerId: "B", plaintext: Data("tamper-target".utf8))!
        bad[bad.count - 1] ^= 0xFF
        XCTAssertNil(ratchet.decryptV4Routed(peerId: "A", frame: bad),
                     "tampered frame must fail closed")
    }

    /// Dispatch-level check mirroring Android `MessageCryptoV4DispatchInstrumentedTest`:
    /// a 0xE5 frame produced by the SEND-side routed method must be detected as `.v4`
    /// by `MessageWireFormat.detect` and recovered by the RECEIVE-side routed method —
    /// the exact two seams the live send (`ChatMessageSendService`) and receive
    /// (`AppState`) dispatchers use. Skipped under the stub.
    func testV4DispatchSeamWithRealCore() throws {
        try XCTSkipUnless(
            RatchetNative.available && MessageRatchet.v4NativeRatchetEnabled,
            "v4 dispatch seam needs the real native core linked AND the flag ON")

        let vault = InMemoryRatchetVault()
        let ratchet = MessageRatchet(vault: vault)
        XCTAssertTrue(ratchet.bootstrapV4AndPersist(
            peerId: "B", effectiveSecret: secret, selfEpochId: zero, peerEpochId: zero,
            selfIdentityPub: idA, peerIdentityPub: idB, transcriptHash: th))
        XCTAssertTrue(ratchet.bootstrapV4AndPersist(
            peerId: "A", effectiveSecret: secret, selfEpochId: zero, peerEpochId: zero,
            selfIdentityPub: idB, peerIdentityPub: idA, transcriptHash: th))

        let plaintext = Data("live v4 dispatch message".utf8)
        let frame = ratchet.encryptV4Routed(peerId: "B", plaintext: plaintext)
        XCTAssertNotNil(frame)
        // The receive dispatcher routes on this:
        XCTAssertEqual(MessageWireFormat.detect(frame!), .v4)
        let recovered = ratchet.decryptV4Routed(peerId: "A", frame: frame!)
        XCTAssertEqual(recovered, plaintext, "dispatch-seam round-trip mismatch")
    }
}
