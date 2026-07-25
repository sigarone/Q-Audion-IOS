import XCTest
@testable import QAudionEngine

/// W-PSKBLIND (WIRE_SPEC §3.3.1.1) — source-invariant guard for WHERE the per-contact
/// blinded-advertisement latch is read and written in `QAudionCallIntegration`.
///
/// The pure rule is proven behaviourally in `PskAdvertResolverTests`, which reproduces
/// the attack itself. What that cannot prove is that the latch is wired at the right
/// call sites — and the sites are the whole risk, because `QAudionCallIntegration`
/// resolves an advertisement in THREE places and only two of them qualify:
///
/// 1. RESPONDER leg (`case .offer`) — the peer's OFFER advertisement under the PEER's
///    ephemeral key. Valid, and also THE decisive read: the one resolve that admits a
///    static-dialect PSK into the session key on that leg.
/// 2. INITIATOR leg (`case .accept`) — the responder's own ACCEPT advertisement under
///    the RESPONDER's ephemeral key. Also valid.
/// 3. `pskForEchoedSelection` — OUR OWN advertised value under OUR OWN ephemeral key.
///    NOT valid: its dialect reports what THIS build emitted, so latching there would
///    arm every contact the instant `offerAdvertDialect` flips, including peers that
///    only ever spoke static, which would then be refused forever; and refusing there
///    would reject our own static advertisement back to ourselves.
///
/// A behavioural test is not available for either half here. The handshake entry points
/// need a live `SovereignKeyVault`, a WebSocket sender and CallKit, and the store itself
/// touches the Keychain, which is not dependably available to a plain SPM test target.
/// So this is a SOURCE INVARIANT, the same choice Android's
/// `PqcHandshakeBlindedAdvertLatchTest` makes for the same reasons.
final class PskAdvertLatchWiringTests: XCTestCase {

    private func integrationSource() throws -> String {
        try source(named: "QAudionCallIntegration.swift", under: "Integration")
    }

    private func source(named file: String, under subdir: String) throws -> String {
        // Walk up from this test file to the package root, then into Sources.
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<8 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir
                .appendingPathComponent("Sources/QAudionEngine/\(subdir)/\(file)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
        }
        throw XCTSkip("could not locate \(file) from \(#filePath)")
    }

    /// Isolate one `case` of the bundle-kind switch so an assertion about the responder
    /// leg cannot be satisfied by code that actually lives on the initiator leg.
    private func slice(_ src: String, from: String, to: String) throws -> String {
        guard let a = src.range(of: from) else { throw XCTSkip("missing anchor \(from)") }
        guard let b = src.range(of: to, range: a.upperBound..<src.endIndex) else {
            throw XCTSkip("missing end anchor \(to)")
        }
        return String(src[a.upperBound..<b.lowerBound])
    }

    func testTheLatchLivesInItsOwnKeychainNamespace() throws {
        let store = try source(named: "PskAdvertDialectLatchStore.swift", under: "Persistence")
        // Distinct from the peer-identity pins and from this device's own identity, so
        // the three can never collide. Asserted on the CONSTANT rather than on the file
        // text: the doc comment names the other namespaces precisely to say it is not
        // them, so a whole-file substring check fails on its own explanation.
        XCTAssertTrue(
            store.contains("keychainService = \"com.bcrypto.qaudion.pskdialect\""),
            "the service constant must be the dedicated namespace"
        )
        for foreign in ["com.bcrypto.qaudion.peerpins", "com.bcrypto.qaudion.sovereign"] {
            XCTAssertFalse(
                store.contains("keychainService = \"\(foreign)\""),
                "must not share \(foreign)'s namespace"
            )
        }
        // Per-device, never synced, never in an iCloud or iTunes backup.
        XCTAssertTrue(store.contains("kSecAttrAccessibleWhenUnlockedThisDeviceOnly"))
        // There is no unset path on the handshake side — `forget` exists for contact
        // deletion and support recovery only.
        XCTAssertTrue(store.contains("func rememberSpokeBlindedAdvert"))
        XCTAssertTrue(store.contains("func hasSpokenBlindedAdvert"))
    }

    func testBothLegsGateTheirPeerAdvertResolveOnTheLatch() throws {
        let src = try integrationSource()
        let responder = try slice(src, from: "case .offer:", to: "case .accept:")
        let initiator = try slice(src, from: "case .accept:", to: "// W529: caller's ACCEPT decapsulation succeeded")

        XCTAssertTrue(
            responder.contains("refuseStaticFallback: Self.pskDialectLatch.hasSpokenBlindedAdvert"),
            "the responder leg must pass the latch into the resolve that admits a static PSK"
        )
        XCTAssertTrue(
            initiator.contains("refuseStaticFallback: Self.pskDialectLatch.hasSpokenBlindedAdvert"),
            "the initiator leg must pass it too — its mutual set feeds the §D4 gate and the NFC chip"
        )
    }

    func testBothLegsLatchOnlyOnAV3ResolutionOfThePeersOwnAdvert() throws {
        let src = try integrationSource()
        let responder = try slice(src, from: "case .offer:", to: "case .accept:")
        let initiator = try slice(src, from: "case .accept:", to: "// W529: caller's ACCEPT decapsulation succeeded")

        for (leg, body) in [("responder", responder), ("initiator", initiator)] {
            XCTAssertTrue(
                body.contains(".v3Blinded") && body.contains("rememberSpokeBlindedAdvert"),
                "the \(leg) leg must arm the latch, guarded on .v3Blinded"
            )
        }
    }

    /// The trap. `pskForEchoedSelection` resolves OUR value under OUR key, and it
    /// deliberately takes no contactId — which is what makes both mistakes impossible
    /// rather than merely discouraged.
    func testTheEchoHelperNeitherLatchesNorRefusesAndTakesNoContactId() throws {
        let src = try integrationSource()
        let helper = try slice(
            src,
            from: "static func pskForEchoedSelection(",
            to: "static func pskIfFingerprintMatches("
        )
        XCTAssertFalse(
            helper.contains("contactId:"),
            "the echo helper must not take a contactId — having one is what would let it latch"
        )
        XCTAssertFalse(
            helper.contains("refuseStaticFallback"),
            "refusing here would reject our own static advertisement back to ourselves"
        )
        XCTAssertFalse(
            helper.contains("rememberSpokeBlindedAdvert"),
            "latching here would arm EVERY contact the instant offerAdvertDialect flips"
        )
        // It must still resolve under OUR ephemeral key — that is what makes it correct.
        XCTAssertTrue(helper.contains("senderEphemeralX25519Pub: ownEphemeralX25519Pub"))
    }

    func testARefusalIsLoggedAndNeverAbortsTheCall() throws {
        let src = try integrationSource()
        let responder = try slice(src, from: "case .offer:", to: "case .accept:")
        guard let at = responder.range(of: ".v2StaticRefused") else {
            return XCTFail(
                "the responder leg must react to a refusal at all — an unreported refusal is the "
                    + "same invisible downgrade the latch exists to expose"
            )
        }
        let block = String(responder[at.lowerBound...].prefix(1400))
        XCTAssertTrue(block.contains("print("), "a refusal must reach the log")
        // W-NOBRICK is absolute here: make the downgrade loud, never drop the call.
        XCTAssertFalse(block.contains("throw "), "a refusal must never throw")
        XCTAssertFalse(block.contains("fatalError"), "nor abort")
    }

    /// Phase B is live: the OFFER emits blinded tags. This now guards the opposite
    /// direction — an accidental REVERT to the static dialect, which would silently put
    /// the constant per-relationship correlator back on the wire for every call. It would
    /// be invisible in behaviour: calls keep working, the PSK keeps being mixed, and only
    /// a relay sees the difference.
    func testTheOfferDialectIsTheBlindedOne() throws {
        let src = try integrationSource()
        XCTAssertTrue(
            src.contains("static let offerAdvertDialect: PskAdvertResolver.Dialect = .v3Blinded"),
            "offerAdvertDialect reverted to the static dialect — that re-exposes the constant "
                + "per-relationship correlator on every call. See WIRE_SPEC §3.3.1."
        )
    }

    /// Input validation, the one part of the store that is testable without a Keychain.
    func testTheStoreRejectsAnEmptyContactId() {
        let store = PskAdvertDialectLatchStore()
        XCTAssertFalse(store.hasSpokenBlindedAdvert(contactId: ""))
        XCTAssertFalse(store.rememberSpokeBlindedAdvert(contactId: ""))
        XCTAssertFalse(store.forget(contactId: ""))
    }
}
