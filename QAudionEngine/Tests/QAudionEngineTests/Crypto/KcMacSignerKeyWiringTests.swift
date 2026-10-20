import XCTest
@testable import QAudionEngine

/// The identity an in-person key is bound to is compared with the key that signed THIS call's round, not with
/// a stored pin that belongs to whichever device of the peer answered last. The resolver is driven directly;
/// the wiring that needs a live call (the two `KcMacReadyEvent` sites, the telemetry in `AppState`) is pinned
/// on the source text, like the other wiring invariants of this module.
final class KcMacSignerKeyWiringTests: XCTestCase {

    private let peerPhoneKey = Data(repeating: 0x11, count: 32)
    private let peerTabletKey = Data(repeating: 0x22, count: 32)
    private let otherDeviceKey = Data(repeating: 0x33, count: 32)

    private func tapKey(boundTo identity: Data) -> AssuranceState.MutualLocalKey {
        AssuranceState.MutualLocalKey(origin: .nfc, boundPeerIdentityKey: identity)
    }

    // MARK: - The event carries the signer key

    func testTheEventCarriesTheSignerKeyOfTheRound() {
        let verified = QAudionCallIntegration.KcMacReadyEvent(
            peerId: "peer", callId: "call", isInitiator: true, sessionKey: Data(repeating: 1, count: 32),
            kcKey: nil, transcript: nil, n: 0, peerSupportsMix: true, sigOk: true,
            signerIdentityKey: peerPhoneKey, mutualFingerprints: [])
        XCTAssertEqual(verified.signerIdentityKey, peerPhoneKey)
        let unverified = QAudionCallIntegration.KcMacReadyEvent(
            peerId: "peer", callId: "call", isInitiator: false, sessionKey: Data(repeating: 1, count: 32),
            kcKey: nil, transcript: nil, n: 0, peerSupportsMix: true, sigOk: false,
            signerIdentityKey: nil, mutualFingerprints: [])
        XCTAssertNil(unverified.signerIdentityKey)
    }

    // MARK: - Judged against the key that signed the round

    func testAKeyBoundToTheDeviceThatSignedTheRoundConfirms() {
        XCTAssertTrue(AssuranceState.resolveNfcConfirmed(
            sigOk: true, mutualLocalKeys: [tapKey(boundTo: peerPhoneKey)],
            verifiedPeerIdentityKey: peerPhoneKey))
    }

    /// The peer answered from a device other than the one the key was tapped with: whatever pin is stored for
    /// another device of that peer, the round was signed by this key and the tapped identity is a different one.
    func testAKeyBoundToAnotherDeviceOfThePeerDoesNotConfirm() {
        XCTAssertFalse(AssuranceState.resolveNfcConfirmed(
            sigOk: true, mutualLocalKeys: [tapKey(boundTo: peerPhoneKey)],
            verifiedPeerIdentityKey: peerTabletKey))
        XCTAssertFalse(AssuranceState.resolveNfcConfirmed(
            sigOk: true, mutualLocalKeys: [tapKey(boundTo: peerPhoneKey)],
            verifiedPeerIdentityKey: otherDeviceKey))
    }

    func testARoundWithoutAVerifiedSignatureConfirmsNothing() {
        XCTAssertFalse(AssuranceState.resolveNfcConfirmed(
            sigOk: false, mutualLocalKeys: [tapKey(boundTo: peerPhoneKey)],
            verifiedPeerIdentityKey: peerPhoneKey))
        XCTAssertFalse(AssuranceState.resolveNfcConfirmed(
            sigOk: true, mutualLocalKeys: [tapKey(boundTo: peerPhoneKey)],
            verifiedPeerIdentityKey: nil))
    }

    // MARK: - Source helpers

    private func sourceText(_ relativePath: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
        }
        throw XCTSkip("\(relativePath) not found")
    }

    /// Whole-line `//` comments dropped and every run of whitespace collapsed: a pin written against this text
    /// survives re-wrapping and comment edits, but not a change of the code.
    private func code(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func slice(_ text: String, from start: String, to end: String) throws -> String {
        let a = try XCTUnwrap(text.range(of: start), "start marker: \(start)")
        let tail = text[a.upperBound...]
        let b = try XCTUnwrap(tail.range(of: end), "end marker: \(end)")
        return String(tail[..<b.lowerBound])
    }

    private let integrationPath = "QAudionEngine/Sources/QAudionEngine/Integration/QAudionCallIntegration.swift"
    private let appPath = "QAudionApp/AppState.swift"

    // MARK: - Wiring

    /// Both legs hand the app the bundle's own key, and only when the verdict verified the signature under it.
    func testBothLegsCarryTheBundleKeyOnlyWhenTheSignatureVerified() throws {
        let integration = code(try sourceText(integrationPath))
        XCTAssertTrue(integration.contains(
            "sigOk: offerSigOk, signerIdentityKey: offerSigOk ? v4PeerSik : nil, mutualFingerprints: kcMutualFingerprints"),
            "responder leg")
        XCTAssertTrue(integration.contains(
            "sigOk: acceptSigOk, signerIdentityKey: acceptSigOk ? v4InitPeerSik : nil, mutualFingerprints: kcCallerMutualFingerprints"),
            "caller leg")
        XCTAssertTrue(integration.contains("let v4PeerSik = bundle.signerIdentityKey.flatMap { Data(base64Encoded: $0) }"))
        XCTAssertTrue(integration.contains("let v4InitPeerSik = bundle.signerIdentityKey.flatMap { Data(base64Encoded: $0) }"))
    }

    /// The confirmation compares with the round's signer key; the stored pin only stands in for the NFC binding
    /// check of a round whose signature did not verify.
    func testTheConfirmationIsJudgedAgainstTheSignerKeyOfTheRound() throws {
        let app = code(try sourceText(appPath))
        let telemetry = try slice(app, from: "private func emitKeyConfirmationTelemetry(", to: "let assurance = AssuranceState.decide(")
        XCTAssertTrue(telemetry.contains("let signerIdentityKey = state.signerIdentityKey"))
        XCTAssertTrue(telemetry.contains(
            "AssuranceState.resolveNfcConfirmed( sigOk: state.sigOk, mutualLocalKeys: AppState.resolveMutualLocalKeys(fingerprints: state.mutualFingerprints), verifiedPeerIdentityKey: signerIdentityKey )"),
            "the confirmation takes the signer key and nothing else")
        XCTAssertTrue(telemetry.contains("let verifiedPeerIdentityKey = signerIdentityKey ?? PeerIdentityPinStore().pinnedKey("),
                      "the binding check prefers the signer key too")
    }

    /// `expected_but_missing` reads the S7 verdict, as the other platform does.
    func testExpectedButMissingIsTheStrippedVerdict() throws {
        let app = code(try sourceText(appPath))
        XCTAssertTrue(app.contains("let expectedButMissing = assurance == .expectedNfcStripped"))
    }
}
