import XCTest
import CryptoKit
@testable import QAudionEngine

// The KAT JSON mirrors the desktop generator's key names verbatim.
// swiftlint:disable force_cast

/// The `sequences` section of the v6 handshake KAT, replayed against this platform's SAS commitment
/// seam (`SasCommitBook`: the callee/caller state machines the call integration drives, plus the same
/// structural bundle rules the integration applies). Every non-null `expect` field of every vector is
/// checked. Events are abstract (see the generator header): `recvOffer`/`recvAccept` name a bundle
/// vector, `recvReveal` a reveal vector, `sendAccept` the device's own round-1 ACCEPT.
///
/// Callee context: the device answers the OFFER bundle `offer-r1-ok` (commitment of `v6-basic-no-psk`);
/// its ACCEPT is the ACCEPT of `v6-basic-no-psk`. Caller context: the OFFER it sent is `offer-r1-ok`
/// (nonce of `v6-basic-no-psk`).
final class SasCommitSequenceTests: XCTestCase {

    private func kat() throws -> [String: Any] {
        guard let url = Bundle.module.url(forResource: "handshake-sig-v6-kat", withExtension: "json") else {
            XCTFail("handshake-sig-v6-kat.json not found in Bundle.module")
            throw NSError(domain: "kat", code: 1)
        }
        return try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as! [String: Any]
    }

    private func vectors(_ kat: [String: Any], _ name: String) -> [[String: Any]] {
        (kat[name] as! [String: Any])["vectors"] as! [[String: Any]]
    }

    private func byId(_ list: [[String: Any]], _ id: String) -> [String: Any] {
        list.first { ($0["id"] as! String) == id }!
    }

    private func hex(_ text: String) -> Data {
        var out = Data()
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            out.append(UInt8(text[index..<next], radix: 16) ?? 0)
            index = next
        }
        return out
    }

    /// What one replay observed.
    private struct Observed {
        var outcome = "dropped"
        var reason: String?
        var atMs: Int?
        var revealsSent = 0
        var revealWires: [String] = []
        var revealBeforeKcMac: Bool?
        var peerNotified: Bool?
        var acceptSent = false
        var words: [String]?
    }

    /// The structural rules of a received bundle (decode, commitment field, first-round rule, signing
    /// fields present), exactly the ones `evaluateInbound` / the first-round check apply.
    private func isMalformed(_ json: String, callId: String, firstOfferOfCall: Bool) -> Bool {
        guard let parsed = AndroidHandshakeEnvelope.parse(callId + "|" + json) else {
            return AndroidHandshakeEnvelope.malformedBundleCallId(callId + "|" + json) != nil
        }
        let b = parsed.bundle
        if HandshakeSigningPolicy.sasCommitMalformedCode(
            isOffer: b.kind == .offer, round: b.rekeyRound, sasCommitB64: b.sasCommit) != nil { return true }
        if b.kind == .offer, HandshakeSigningPolicy.firstRoundMalformedCode(
            isFirstOfferOfCall: firstOfferOfCall, round: b.rekeyRound) != nil { return true }
        let verdict = HandshakeSigningPolicy.evaluate(
            signerIdentityKeyB64: b.signerIdentityKey, sigV6B64: b.sigV6, dtlsFingerprintText: b.dtlsFingerprint,
            transcript: nil, pinnedKey: nil, serverFetchedKey: nil, advertisedV4: true)
        if case .malformed(let code) = verdict, code != "transcript_unbuildable" { return true }
        return false
    }

    /// A REVEAL vector names a CLASS of message (valid, wrong nonce, another ACCEPT, another call, ...); its
    /// own context is the one it was built for. A vector built for THIS call is replayed as is; one built
    /// for another context (the design-check inputs) is re-expressed in this call's context by its class,
    /// exactly like the server's reference model: a wrong or different nonce names this device's ACCEPT
    /// with a nonce that does not open the commitment, a sibling names another ACCEPT with the right nonce,
    /// anything else (another call, another tag) is replayed as is and must be dropped.
    private func revealData(_ vector: [String: Any], callId: String, ownAcceptHash: Data, nonce: Data) -> String {
        if (vector["callId"] as? String) == callId { return vector["data"] as! String }
        switch vector["expect"] as! String {
        case "sas_commit_mismatch":
            var wrong = nonce
            wrong[wrong.count - 1] ^= 0x01
            return SasReveal.serialize(callId: callId, acceptBinding: ownAcceptHash, nonce: wrong)!
        case "sibling":
            return SasReveal.serialize(callId: callId, acceptBinding: Data(repeating: 0xEE, count: 32), nonce: nonce)!
        default:
            return vector["data"] as! String
        }
    }

    private func replay(_ seq: [String: Any], kat: [String: Any]) -> Observed {
        let transcripts = vectors(kat, "transcripts")
        let bundles = vectors(kat, "bundle")
        let reveals = vectors(kat, "reveal")
        let tv1 = byId(transcripts, "v6-basic-no-psk")
        let callId = (tv1["inputs"] as! [String: Any])["callId"] as! String
        let offerer = (tv1["inputs"] as! [String: Any])["offerer"] as! [String: Any]
        let ownAcceptHash = hex((tv1["expected"] as! [String: Any])["acceptV6Sha256Hex"] as! String)
        let sessionKey = hex((byId(vectors(kat, "kdf"), "kdf-no-psk")["expected"] as! [String: Any])["sessionKeyHex"] as! String)

        let book = SasCommitBook()
        var obs = Observed()
        let role = seq["role"] as! String
        var haveCall = false
        var offersSeen = 0
        var ended = false
        if role == "caller" {
            _ = book.beginCaller(callId: callId, nonce: hex(offerer["sasNonceHex"] as! String))
            haveCall = true
        }

        for event in seq["events"] as! [[String: Any]] {
            let tMs = (event["tMs"] as! NSNumber).intValue
            let ev = event["ev"] as! String
            let arg = event["arg"] as? String
            if ended { break }
            switch (role, ev) {
            case ("callee", "recvOffer"):
                let bundle = byId(bundles, arg!)
                let malformed = isMalformed(bundle["json"] as! String, callId: callId, firstOfferOfCall: offersSeen == 0)
                if malformed {
                    ended = true
                    obs.outcome = "ended"; obs.reason = "handshake_malformed"; obs.atMs = tMs; obs.peerNotified = true
                    break
                }
                if offersSeen == 0 {
                    let parsed = AndroidHandshakeEnvelope.parse(callId + "|" + (bundle["json"] as! String))!
                    let commit = SasCommit.decodeCanonicalBase64(parsed.bundle.sasCommit!, expectedLength: 32)!
                    XCTAssertTrue(book.beginCallee(callId: callId, commit: commit))
                    book.calleeSetAccept(callId: callId, acceptHash: ownAcceptHash)
                    book.recordRound1(callId: callId, sessionKey: sessionKey, acceptHash: ownAcceptHash)
                    haveCall = true
                }
                offersSeen += 1
            case ("callee", "sendAccept"):
                if book.calleeAcceptSent(callId: callId, nowMs: tMs) { obs.acceptSent = true }
                if haveCall { obs.acceptSent = true }
            case (_, "recvReveal"):
                let data = revealData(
                    byId(reveals, arg!), callId: callId, ownAcceptHash: ownAcceptHash,
                    nonce: hex(offerer["sasNonceHex"] as! String))
                guard haveCall else { break }   // no call context: dropped silently, no state
                switch book.calleeOnReveal(callId: callId, data: data, nowMs: tMs) {
                case .none, .dropped, .sasReady: break
                case .end(let reason):
                    ended = true
                    obs.outcome = "ended"; obs.reason = reason; obs.atMs = tMs; obs.peerNotified = true
                case .leaveLocally:
                    ended = true
                    obs.outcome = "left_locally"; obs.reason = "answered_on_other_device"; obs.atMs = tMs
                    obs.peerNotified = false
                }
            case ("callee", "recvKcMac"):
                // a device that left must not judge the real call's MAC
                XCTAssertFalse(book.calleeAcceptsKeyConfirmation(callId: callId) && obs.outcome == "left_locally")
            case ("callee", "tick"):
                if case .end(let reason) = book.calleeTick(callId: callId, nowMs: tMs) {
                    ended = true
                    obs.outcome = "ended"; obs.reason = reason; obs.atMs = tMs; obs.peerNotified = true
                }
            case ("caller", "recvAccept"):
                let bundle = byId(bundles, arg!)
                if isMalformed(bundle["json"] as! String, callId: callId, firstOfferOfCall: false) {
                    ended = true
                    obs.outcome = "ended"; obs.reason = "handshake_malformed"; obs.atMs = tMs; obs.peerNotified = true
                    break
                }
                let hashHex = (bundle["acceptV6Sha256Hex"] as? String)
                    ?? ((byId(transcripts, bundle["transcriptVector"] as! String)["expected"] as! [String: Any])["acceptV6Sha256Hex"] as! String)
                let (decision, wire) = book.callerOnAccept(callId: callId, acceptHash: hex(hashHex))
                switch decision {
                case .bindAndReveal:
                    obs.revealsSent += 1
                    if let wire { obs.revealWires.append(wire) }
                    // the REVEAL leaves before the round-1 KCMAC: the integration awaits it first
                    obs.revealBeforeKcMac = true
                    book.recordRound1(callId: callId, sessionKey: sessionKey, acceptHash: hex(hashHex))
                case .resendReveal:
                    obs.revealsSent += 1
                    if let wire { obs.revealWires.append(wire) }
                case .drop:
                    break
                }
            case ("caller", "hangup"):
                book.clear(callId: callId)
                ended = true
                obs.outcome = "ended"; obs.atMs = tMs
            default:
                XCTFail("unhandled event \(role)/\(ev)")
            }
        }

        if !ended {
            if let words = book.words(callId: callId) {
                obs.outcome = "sas_ready"
                obs.words = words
            }
        }
        // a caller that sent no REVEAL has nothing to compare
        return obs
    }

    func testEverySequenceVectorOfTheKat() throws {
        let kat = try kat()
        let sequences = vectors(kat, "sequences")
        XCTAssertEqual(sequences.count, 19, "every required sequence id is present")
        let reveals = vectors(kat, "reveal")
        let sasVectors = vectors(kat, "sas")
        for seq in sequences {
            let id = seq["id"] as! String
            let expect = seq["expect"] as! [String: Any]
            let obs = replay(seq, kat: kat)
            if let v = expect["outcome"] as? String { XCTAssertEqual(obs.outcome, v, "[\(id)] outcome") }
            if let v = expect["reason"] as? String { XCTAssertEqual(obs.reason, v, "[\(id)] reason") }
            if let v = expect["atMs"] as? NSNumber { XCTAssertEqual(obs.atMs, v.intValue, "[\(id)] atMs") }
            if let v = expect["revealsSent"] as? NSNumber { XCTAssertEqual(obs.revealsSent, v.intValue, "[\(id)] revealsSent") }
            if let v = expect["revealData"] as? String {
                let want = byId(reveals, v)["data"] as! String
                XCTAssertFalse(obs.revealWires.isEmpty, "[\(id)] a REVEAL was sent")
                for wire in obs.revealWires { XCTAssertEqual(wire, want, "[\(id)] every REVEAL is byte-identical to the vector") }
            }
            if let v = expect["revealBeforeKcMac"] as? Bool { XCTAssertEqual(obs.revealBeforeKcMac, v, "[\(id)] revealBeforeKcMac") }
            if let v = expect["peerNotified"] as? Bool { XCTAssertEqual(obs.peerNotified, v, "[\(id)] peerNotified") }
            if let v = expect["acceptSent"] as? Bool { XCTAssertEqual(obs.acceptSent, v, "[\(id)] acceptSent") }
            if let v = expect["sasVector"] as? String {
                let want = (byId(sasVectors, v)["expected"] as! [String: Any])["sasWords"] as! [String]
                XCTAssertEqual(obs.words, want, "[\(id)] SAS words")
            }
        }
    }

    // MARK: - D1 / R-COMMIT-SIBLING: the loser leaves without ending the real call

    /// Two callee devices of one user answered the same call. The caller bound device A's ACCEPT. Device
    /// B receives the REVEAL (fan-out), sees another binding and leaves locally: it never ends the call
    /// with a security reason, never notifies the peer, and from then on ignores KCMAC.
    func testASiblingThatLostTheRaceLeavesLocallyAndStopsJudgingKcmac() throws {
        let kat = try kat()
        let tv1 = byId(vectors(kat, "transcripts"), "v6-basic-no-psk")
        let callId = (tv1["inputs"] as! [String: Any])["callId"] as! String
        let commit = hex(((tv1["inputs"] as! [String: Any])["offerer"] as! [String: Any])["sasCommitHex"] as! String)
        let accept = hex((tv1["expected"] as! [String: Any])["acceptV6Sha256Hex"] as! String)
        let bundles = vectors(kat, "reveal")

        let loser = SasCommitBook()
        XCTAssertTrue(loser.beginCallee(callId: callId, commit: commit))
        loser.calleeSetAccept(callId: callId, acceptHash: Data(repeating: 0xEE, count: 32))   // its ACCEPT is another one
        XCTAssertTrue(loser.calleeAcceptSent(callId: callId, nowMs: 0))
        XCTAssertTrue(loser.calleeAcceptsKeyConfirmation(callId: callId))

        let revealForA = byId(bundles, "ok-basic")["data"] as! String
        XCTAssertEqual(loser.calleeOnReveal(callId: callId, data: revealForA, nowMs: 80), .leaveLocally)
        XCTAssertFalse(loser.calleeAcceptsKeyConfirmation(callId: callId), "the loser stops judging KCMAC")
        XCTAssertNil(loser.words(callId: callId), "the loser never gets words")
        // the timer of the loser is dead: it must not end the call later
        XCTAssertEqual(loser.calleeTick(callId: callId, nowMs: 60_000), .none)
        XCTAssertEqual(loser.calleeTimerFired(callId: callId), .none)
        // every later message is ignored
        XCTAssertEqual(loser.calleeOnReveal(callId: callId, data: revealForA, nowMs: 90), .dropped)

        // the winner (device A) verifies the very same REVEAL
        let winner = SasCommitBook()
        XCTAssertTrue(winner.beginCallee(callId: callId, commit: commit))
        winner.calleeSetAccept(callId: callId, acceptHash: accept)
        XCTAssertTrue(winner.calleeAcceptSent(callId: callId, nowMs: 0))
        XCTAssertEqual(winner.calleeOnReveal(callId: callId, data: revealForA, nowMs: 80), .sasReady)
    }

    /// Mode 0 (pre-accept ACCEPT, calls.ring_signaling_only = false) is correct under v6: the ACCEPT is
    /// sent at ring and the REVEAL may arrive while the phone still rings; it verifies and the words are
    /// ready at answer. The wait applies to it as well: no REVEAL within 5 s of the ACCEPT ends the call.
    func testModeZeroVerifiesARevealWhileRingingAndTheTimerStillApplies() throws {
        let kat = try kat()
        let tv1 = byId(vectors(kat, "transcripts"), "v6-basic-no-psk")
        let callId = (tv1["inputs"] as! [String: Any])["callId"] as! String
        let commit = hex(((tv1["inputs"] as! [String: Any])["offerer"] as! [String: Any])["sasCommitHex"] as! String)
        let accept = hex((tv1["expected"] as! [String: Any])["acceptV6Sha256Hex"] as! String)
        let key = hex((byId(vectors(kat, "kdf"), "kdf-no-psk")["expected"] as! [String: Any])["sessionKeyHex"] as! String)
        let revealOk = byId(vectors(kat, "reveal"), "ok-basic")["data"] as! String

        let ringing = SasCommitBook()
        _ = ringing.beginCallee(callId: callId, commit: commit)
        ringing.calleeSetAccept(callId: callId, acceptHash: accept)
        ringing.recordRound1(callId: callId, sessionKey: key, acceptHash: accept)
        XCTAssertTrue(ringing.calleeAcceptSent(callId: callId, nowMs: 0), "sent at ring")
        XCTAssertTrue(ringing.isWaitingForReveal(callId: callId))
        XCTAssertEqual(ringing.calleeOnReveal(callId: callId, data: revealOk, nowMs: 150), .sasReady)
        XCTAssertFalse(ringing.isWaitingForReveal(callId: callId))
        XCTAssertNotNil(ringing.words(callId: callId), "the words are ready before the user answers")

        let silent = SasCommitBook()
        _ = silent.beginCallee(callId: callId, commit: commit)
        silent.calleeSetAccept(callId: callId, acceptHash: accept)
        XCTAssertTrue(silent.calleeAcceptSent(callId: callId, nowMs: 0))
        XCTAssertEqual(silent.calleeTimerFired(callId: callId), .end(reason: "sas_reveal_timeout"))
    }
}
// swiftlint:enable force_cast
