import Foundation
import CryptoKit

// NFC pairing v2, reader side (docs/security/NFC_PAIRING_V2.md sections 5, 6 and 9).
//
// `NfcReaderCeremony` is the whole protocol state machine of the reader with no CoreNFC in it: it talks to a
// `NfcIso7816Transport`, so the tests drive it over a fake card and `NfcApduExchange` drives it over a real tag.
//
// Tap 1 (`runFirstTap`) runs the exchange up to REVEAL and returns the SAS; the NFC session is then closed by the
// caller. Nothing is stored. After the user confirmed (`userDidConfirm`), tap 2 (`runConfirmTap`) is a new session:
// it polls CONFIRM until the card has stored the key and proved it with `confirm_C`, stores the key through the
// `store` closure only then, and sends FINALIZE. A local reject sends nothing at all.

/// What the first tap produced.
struct NfcReaderFirstTap: Equatable {
    let peer: NfcPairingV2Identity
    let sas: String
    /// 8 hex characters that line up the logs of both phones.
    let logTag: String
    /// False when the REVEAL transceive failed after the card may have accepted it (section 6).
    let revealDelivered: Bool
}

/// What a confirmation tap ended with.
enum NfcReaderConfirmResult: Equatable {
    /// The card proved it stored the key, the reader stored and finalized it. `finalizeAcknowledged` is false when
    /// the card never confirmed FINALIZE (a lost final message: the card finalizes at the first call, row 4).
    case stored(finalizeAcknowledged: Bool)
    /// The card's user rejected, proven by `reject_C`. Nothing is stored.
    case peerRejected
    /// The poll budget ended with the card still waiting for its user. The staged state is kept.
    case stillPending
    /// The field was lost (or the session ended). The staged state is kept until its own timeout.
    case fieldLost
    /// The ceremony is over, nothing stored.
    case failed(NfcPairingV2Token)
}

/// What the caller's store step did, for the log.
struct NfcReaderStoreOutcome: Equatable {
    /// The new key took the place of an earlier key of the same device.
    let replaced: Bool
    /// Earlier keys of the device deleted by the finalize.
    let deleted: Int
}

/// The random values of one ceremony. Fresh for every handshake and never reused (section 14).
struct NfcReaderEntropy {
    let x25519Private: Curve25519.KeyAgreement.PrivateKey
    let kemPublicKey: Data
    var kemSecretKey: Data
    let nonce: Data

    static func fresh() throws -> NfcReaderEntropy {
        let kem = try ProximityPairingCrypto.kemGenerateKeyPair()
        let nonce = try ProximityPairingCrypto.randomBytes(NfcPairingV2.nonceBytes)
        return NfcReaderEntropy(x25519Private: Curve25519.KeyAgreement.PrivateKey(), kemPublicKey: kem.publicKey,
                                kemSecretKey: kem.secretKey, nonce: nonce)
    }
}

/// This phone's identity for a ceremony.
struct NfcPairingV2LocalIdentity {
    let identity: NfcPairingV2Identity
    let signingPrivateKey: Data
}

/// The clock and the waiting of a ceremony, replaceable in tests.
struct NfcReaderEnvironment {
    /// Milliseconds on a clock that keeps counting during sleep.
    var nowMs: () -> UInt64
    /// Waits for the given milliseconds.
    var sleepMs: (UInt64) async -> Void
    var entropy: () throws -> NfcReaderEntropy

    static var live: NfcReaderEnvironment {
        NfcReaderEnvironment(
            nowMs: { NfcMonotonicClock.nowMs() },
            sleepMs: { ms in try? await Task.sleep(nanoseconds: ms * 1_000_000) },
            entropy: { try NfcReaderEntropy.fresh() })
    }
}

/// A clock that counts while the phone sleeps (Darwin's `CLOCK_MONOTONIC`, as `ProximityPairing`'s clock).
enum NfcMonotonicClock {
    static func nowMs() -> UInt64 {
        #if canImport(Darwin)
        return clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1_000_000
        #else
        return DispatchTime.now().uptimeNanoseconds / 1_000_000
        #endif
    }
}

final class NfcReaderCeremony {

    private struct Staged {
        let peer: NfcPairingV2Identity
        var stage2: NfcPairingV2Crypto.Stage2
        let logTag: String
        let revealedAtMs: UInt64
    }

    private let local: NfcPairingV2LocalIdentity
    private let pinnedPeerKey: Data?
    private let environment: NfcReaderEnvironment
    private var staged: Staged?
    private var userConfirmed: Bool = false

    /// - Parameter pinnedPeerKey: the identity key stored for the contact a contact-targeted re-pairing is for;
    ///   `nil` for a blind pairing.
    init(local: NfcPairingV2LocalIdentity, pinnedPeerKey: Data? = nil, environment: NfcReaderEnvironment = .live) {
        self.local = local
        self.pinnedPeerKey = pinnedPeerKey
        self.environment = environment
    }

    // MARK: - State for the caller

    /// True while a ceremony waits for the user's decision or for tap 2.
    var hasStagedCeremony: Bool { staged != nil }

    /// The peer of the staged ceremony.
    var stagedPeer: NfcPairingV2Identity? { staged?.peer }

    var stagedLogTag: String? { staged?.logTag }

    /// Milliseconds left of the 120 s the user has, 0 when expired or nothing is staged.
    func remainingConfirmationMs() -> UInt64 {
        guard let staged else { return 0 }
        let deadline = staged.revealedAtMs &+ NfcPairingV2.userConfirmationTimeoutMs
        let now = environment.nowMs()
        return now >= deadline ? 0 : deadline - now
    }

    /// The user confirmed on this phone: tap 2 may start. Does not store anything.
    func userDidConfirm() {
        guard staged != nil, remainingConfirmationMs() > 0 else { return }
        userConfirmed = true
        if let tag = staged?.logTag { NfcPairingLog.user(role: .reader, .confirm, logTag: tag) }
    }

    /// The user rejected, or cancelled, or the 120 s ran out: everything is discarded and nothing is sent. The card
    /// notices through its own timeout.
    func rejectLocally() {
        if let tag = staged?.logTag { NfcPairingLog.user(role: .reader, .reject, logTag: tag) }
        discard()
    }

    func expire() {
        if let tag = staged?.logTag { NfcPairingLog.user(role: .reader, .timeout, logTag: tag) }
        discard()
    }

    /// Zeroizes and forgets the staged ceremony.
    func discard() {
        if var s = staged {
            s.stage2.zeroize()
        }
        staged = nil
        userConfirmed = false
    }

    // MARK: - Tap 1

    private enum Step {
        case select, ek, hello, ct, auth, reveal, confirm, finalize

        var logStep: NfcPairingLog.Step {
            switch self {
            case .select: return .select
            case .ek: return .ek
            case .hello: return .hello
            case .ct: return .ct
            case .auth: return .auth
            case .reveal: return .reveal
            case .confirm: return .confirm
            case .finalize: return .finalize
            }
        }
    }

    /// Runs tap 1 over `transport` up to REVEAL. Throws `NfcPairingV2Failure`; a ceremony that fails here leaves
    /// nothing staged and nothing stored.
    func runFirstTap(over transport: NfcIso7816Transport) async throws -> NfcReaderFirstTap {
        discard()
        NfcPairingLog.start(role: .reader)
        let startedAt = environment.nowMs()
        var logTag: String?
        do {
            let result = try await firstTap(over: transport, startedAt: startedAt, logTag: &logTag)
            return result
        } catch let failure as NfcPairingV2Failure {
            discard()
            NfcPairingLog.fail(role: .reader, failure, logTag: logTag)
            throw failure
        } catch {
            discard()
            let failure = NfcPairingV2Failure(.cardError)
            NfcPairingLog.fail(role: .reader, failure, logTag: logTag)
            throw failure
        }
    }

    private func firstTap(over transport: NfcIso7816Transport, startedAt: UInt64,
                          logTag: inout String?) async throws -> NfcReaderFirstTap {
        let deadline = startedAt &+ NfcPairingV2.firstTapBudgetMs
        var entropy = try environment.entropy()
        defer { CryptoConstants.zeroize(&entropy.kemSecretKey) }

        let localBlock = local.identity.block
        let commit = NfcPairingV2Crypto.commitment(readerNonce: entropy.nonce, readerIdentityBlock: localBlock)

        // SELECT: the explicit one of the app (iOS sent its own at discovery); its data byte is `selectData`.
        let selectData = try await select(over: transport, deadline: deadline)

        // EK_PUT[0...6]
        let ek = entropy.kemPublicKey
        guard ek.count == NfcPairingV2.encapsulationKeyBytes else { throw NfcPairingV2Failure(.length) }
        for index in 0..<NfcPairingV2.chunkCount {
            let chunk = ek.subdata(in: (index * NfcPairingV2.chunkBytes)..<((index + 1) * NfcPairingV2.chunkBytes))
            _ = try await send(.proprietary(.ekPut, p1: UInt8(index), p2: UInt8(NfcPairingV2.chunkCount), data: chunk),
                               over: transport, step: .ek, chunk: index, deadline: deadline)
        }

        // HELLO
        var helloCommand = Data([NfcPairingV2.version])
        helloCommand.append(entropy.x25519Private.publicKey.rawRepresentation)
        helloCommand.append(commit)
        let helloStart = environment.nowMs()
        let hello = try await send(.proprietary(.hello, data: helloCommand, expectedLength: NfcPairingV2.helloResponseBytes),
                                   over: transport, step: .hello, deadline: deadline, logSuccess: false)
        let roundTrip = environment.nowMs() &- helloStart
        // The round trip is logged always, so the limit can be calibrated (section 4).
        NfcPairingLog.step(role: .reader, .hello, result: "ok", statusWord: hello.statusWord, roundTripMs: roundTrip)
        guard hello.data.count == NfcPairingV2.helloResponseBytes else { throw NfcPairingV2Failure(.length) }
        guard roundTrip <= NfcPairingV2.helloRoundTripLimitMs else { throw NfcPairingV2Failure(.rtt) }
        let cardKey = Data(hello.data.prefix(32))
        let cardNonce = Data(hello.data.suffix(32))

        // CT_GET[0...6]
        var ciphertext = Data()
        for index in 0..<NfcPairingV2.chunkCount {
            let chunk = try await send(
                .proprietary(.ctGet, p1: UInt8(index), p2: UInt8(NfcPairingV2.chunkCount),
                             expectedLength: NfcPairingV2.chunkBytes),
                over: transport, step: .ct, chunk: index, deadline: deadline)
            guard chunk.data.count == NfcPairingV2.chunkBytes else { throw NfcPairingV2Failure(.length) }
            ciphertext.append(chunk.data)
        }
        guard ciphertext.count == NfcPairingV2.ciphertextBytes else { throw NfcPairingV2Failure(.length) }

        // Key agreement. An all-zero X25519 result is refused explicitly.
        var ssX: Data
        do {
            ssX = try ProximityPairingCrypto.x25519SharedSecret(privateKey: entropy.x25519Private, peerPublicKey: cardKey)
        } catch {
            throw NfcPairingV2Failure(.x25519Zero)
        }
        defer { CryptoConstants.zeroize(&ssX) }
        var ssKem: Data
        do {
            ssKem = try ProximityPairingCrypto.kemDecapsulate(ciphertext: ciphertext, secretKey: entropy.kemSecretKey)
        } catch {
            throw NfcPairingV2Failure(.kem)
        }
        defer { CryptoConstants.zeroize(&ssKem) }
        CryptoConstants.zeroize(&entropy.kemSecretKey)

        let th1 = NfcPairingV2Crypto.transcriptHash1(selectData: selectData, encapsulationKey: ek,
                                                     helloCommand: helloCommand, helloResponse: hello.data,
                                                     ciphertext: ciphertext)
        logTag = NfcPairingV2Crypto.logTag(th1: th1)
        var stage1 = try NfcPairingV2Crypto.deriveStage1(th1: th1, kemSharedSecret: ssKem, x25519SharedSecret: ssX)
        defer { stage1.zeroize() }

        // AUTH_C: open and verify before anything about the peer is shown or logged.
        let auth = try await send(.proprietary(.authCard, expectedLength: 256), over: transport, step: .auth,
                                  deadline: deadline)
        let card = try NfcPairingV2Crypto.verifyCardAuth(sealed: auth.data, stage1: stage1, th1: th1,
                                                         ownIdentityKey: local.identity.publicKey,
                                                         pinnedPeerKey: pinnedPeerKey)

        // REVEAL: sealed once. A transceive that fails here leaves us not knowing whether the card accepted it: the
        // code is shown anyway and the confirmation settles it (the card answers 03 if it never did).
        let thReader = NfcPairingV2Crypto.transcriptHashReader(thCard: card.thCard, readerIdentityBlock: localBlock,
                                                               readerNonce: entropy.nonce)
        var revealDelivered = true
        // Out of time before REVEAL is sent: it was never transmitted, so no code is shown.
        guard environment.nowMs() < deadline else { throw NfcPairingV2Failure(.timeout) }
        let sealedReveal = try NfcPairingV2Crypto.sealReaderReveal(
            identity: local.identity, signingPrivateKey: local.signingPrivateKey, readerNonce: entropy.nonce,
            thCard: card.thCard, thReader: thReader, stage1: stage1)
        do {
            _ = try await send(.proprietary(.reveal, data: sealedReveal), over: transport, step: .reveal,
                               deadline: deadline)
        } catch let failure as NfcPairingV2Failure where failure.token == .fieldLost || failure.token == .timeout {
            revealDelivered = false
        }

        // Stage 2, then the ephemeral material goes.
        let stage2 = try NfcPairingV2Crypto.deriveStage2(prk1: stage1.prk1, thReader: thReader,
                                                         readerNonce: entropy.nonce, cardNonce: cardNonce)
        staged = Staged(peer: card.identity, stage2: stage2, logTag: logTag ?? "", revealedAtMs: environment.nowMs())
        userConfirmed = false
        return NfcReaderFirstTap(peer: card.identity, sas: stage2.sas, logTag: logTag ?? "",
                                 revealDelivered: revealDelivered)
    }

    private func select(over transport: NfcIso7816Transport, deadline: UInt64) async throws -> Data {
        let response = try await send(.select, over: transport, step: .select, deadline: deadline, statusMapper: { sw in
            // 6985: the other phone's pairing screen is not ready. Anything else: nothing of ours is there.
            NfcPairingV2Failure(sw == 0x6985 ? .notArmed : .version, statusWord: sw)
        })
        guard response.data.count == 1, response.data[response.data.startIndex] == NfcPairingV2.version else {
            throw NfcPairingV2Failure(.version)
        }
        return Data(response.data)
    }

    // MARK: - Tap 2

    /// Runs a confirmation tap over `transport`. `store` is called once, only after `confirm_C` verified, and stores
    /// and finalizes the key (F1); it must throw if the key could not be stored.
    func runConfirmTap(
        over transport: NfcIso7816Transport,
        progress: @MainActor (NfcPairingLog.PeerDecision) -> Void = { _ in },
        store: (_ psk: Data, _ peer: NfcPairingV2Identity) async throws -> NfcReaderStoreOutcome
    ) async -> NfcReaderConfirmResult {
        guard let snapshot = staged, userConfirmed else { return .failed(.order) }
        let tag = snapshot.logTag
        let now = environment.nowMs()
        let stagedDeadline = snapshot.revealedAtMs &+ NfcPairingV2.userConfirmationTimeoutMs
        guard now < stagedDeadline else {
            expire()
            return .failed(.timeout)
        }
        let deadline = min(now &+ NfcPairingV2.confirmPollBudgetMs, stagedDeadline)

        do {
            // The explicit SELECT of this session: a different data byte means the other phone is not on v2.
            _ = try await select(over: transport, deadline: deadline)

            do {
                let confirmCommand = NfcApduCommand.proprietary(
                    .confirm, data: Data([NfcPairingV2.Decision.confirm.rawValue]) + snapshot.stage2.confirmReader,
                    expectedLength: 256)
                while true {
                    let response = try await send(confirmCommand, over: transport, step: .confirm, deadline: deadline,
                                                  allowAnyStatus: true)
                    switch interpretCardAnswer(response, confirmTag: snapshot.stage2.confirmCard,
                                               rejectTag: snapshot.stage2.rejectCard) {
                    case .pending:
                        NfcPairingLog.peer(role: .reader, .pending, logTag: tag)
                        await progress(.pending)
                    case .confirmed:
                        NfcPairingLog.peer(role: .reader, .confirm, logTag: tag)
                        return await storeAndFinalize(over: transport, snapshot: snapshot, deadline: deadline,
                                                      store: store)
                    case .rejected:
                        NfcPairingLog.peer(role: .reader, .reject, logTag: tag)
                        discard()
                        return .peerRejected
                    case .storeFailed:
                        let failure = NfcPairingV2Failure(.storeFailed, statusWord: response.statusWord)
                        NfcPairingLog.fail(role: .reader, failure, step: .confirm, logTag: tag)
                        discard()
                        return .failed(.storeFailed)
                    case .noCeremony:
                        let failure = NfcPairingV2Failure(.noCeremony, statusWord: response.statusWord)
                        NfcPairingLog.fail(role: .reader, failure, step: .confirm, logTag: tag)
                        discard()
                        return .failed(.noCeremony)
                    }
                    guard environment.nowMs() &+ NfcPairingV2.confirmPollIntervalMs < deadline else {
                        return .stillPending
                    }
                    await environment.sleepMs(NfcPairingV2.confirmPollIntervalMs)
                    if Task.isCancelled { return .fieldLost }
                }
            }
        } catch let failure as NfcPairingV2Failure {
            switch failure.token {
            case .fieldLost, .timeout:
                // Keep the staged state: the 120 s of the user are not over.
                NfcPairingLog.fail(role: .reader, NfcPairingV2Failure(.fieldLost), step: .confirm, logTag: tag)
                return .fieldLost
            default:
                NfcPairingLog.fail(role: .reader, failure, step: .confirm, logTag: tag)
                discard()
                return .failed(failure.token)
            }
        } catch {
            return .fieldLost
        }
    }

    private enum CardAnswer {
        case pending, confirmed, rejected, storeFailed, noCeremony
    }

    /// Reads a CONFIRM answer. `00`, `03`, `04` and the unauthenticated status words only make the reader report or
    /// wait; `01` counts only with a verified `confirm_C`, `02` only with a verified `reject_C`, and a wrong tag is
    /// handled like `03` (section 5).
    private func interpretCardAnswer(_ response: NfcApduResponse, confirmTag: Data, rejectTag: Data) -> CardAnswer {
        if response.statusWord == 0x6F00 { return .storeFailed }
        guard response.isOk, let first = response.data.first,
              let state = NfcPairingV2.CardState(rawValue: first) else { return .noCeremony }
        let payload = Data(response.data.dropFirst())
        switch state {
        case .pending:
            return payload.isEmpty ? .pending : .noCeremony
        case .confirmed:
            return NfcPairingV2Crypto.tagMatches(payload, confirmTag) ? .confirmed : .noCeremony
        case .rejected:
            return NfcPairingV2Crypto.tagMatches(payload, rejectTag) ? .rejected : .noCeremony
        case .noCeremony, .aborted:
            return .noCeremony
        }
    }

    private func storeAndFinalize(
        over transport: NfcIso7816Transport, snapshot: Staged, deadline: UInt64,
        store: (_ psk: Data, _ peer: NfcPairingV2Identity) async throws -> NfcReaderStoreOutcome
    ) async -> NfcReaderConfirmResult {
        let tag = snapshot.logTag
        // A reject or a cancel that came in while the poll was running discards the ceremony: nothing is stored then.
        guard staged != nil, userConfirmed else {
            return .failed(.userRejected)
        }
        // The key is stored only now: our user confirmed and the card proved it stored its copy.
        do {
            let outcome = try await store(snapshot.stage2.psk, snapshot.peer)
            NfcPairingLog.commit(role: .reader, stored: true, pending: false, replaced: outcome.replaced, logTag: tag)
            NfcPairingLog.finalize(role: .reader, via: .confirm, deleted: outcome.deleted, logTag: tag)
        } catch {
            let failure = NfcPairingV2Failure(.storeFailed)
            NfcPairingLog.fail(role: .reader, failure, step: .confirm, logTag: tag)
            discard()
            return .failed(.storeFailed)
        }
        // FINALIZE, repeated until the card says 01, the budget ends or the field is lost. The key is stored now, so
        // a card whose answer came at the very end of the 20 s still gets one second to hear FINALIZE.
        let finalizeDeadline = max(deadline, environment.nowMs() &+ 1_000)
        let finalizeCommand = NfcApduCommand.proprietary(.finalize, data: snapshot.stage2.finalizeReader,
                                                         expectedLength: 256)
        var acknowledged = false
        loop: while true {
            do {
                let response = try await send(finalizeCommand, over: transport, step: .finalize, deadline: finalizeDeadline,
                                              allowAnyStatus: true)
                // A status word other than 9000 (screen closed, internal error): there is nothing more to send.
                guard response.isOk else { break loop }
                if response.data.count == 1,
                   response.data[response.data.startIndex] == NfcPairingV2.CardState.confirmed.rawValue {
                    acknowledged = true
                    break loop
                }
                if response.data.count == 1,
                   response.data[response.data.startIndex] == NfcPairingV2.CardState.noCeremony.rawValue {
                    // The card ended the ceremony (a call finalized another key of the device): nothing more to send.
                    break loop
                }
            } catch {
                break loop
            }
            guard environment.nowMs() &+ NfcPairingV2.confirmPollIntervalMs < finalizeDeadline else { break loop }
            await environment.sleepMs(NfcPairingV2.confirmPollIntervalMs)
            if Task.isCancelled { break loop }
        }
        discard()
        return .stored(finalizeAcknowledged: acknowledged)
    }

    // MARK: - Sending

    private func send(_ command: NfcApduCommand, over transport: NfcIso7816Transport, step: Step, chunk: Int? = nil,
                      deadline: UInt64, allowAnyStatus: Bool = false, logSuccess: Bool = true,
                      statusMapper: ((UInt16) -> NfcPairingV2Failure)? = nil) async throws -> NfcApduResponse {
        guard environment.nowMs() < deadline else { throw NfcPairingV2Failure(.timeout) }
        let started = environment.nowMs()
        let response: NfcApduResponse
        do {
            response = try await transport.transceive(command)
        } catch let error as NfcTransportError {
            throw NfcPairingV2Failure(error == .timeout ? .timeout : .fieldLost)
        } catch {
            throw NfcPairingV2Failure(.fieldLost)
        }
        let duration = environment.nowMs() &- started
        if response.isOk || allowAnyStatus {
            if response.isOk && logSuccess {
                NfcPairingLog.step(role: .reader, step.logStep, result: "ok", statusWord: response.statusWord,
                                   chunk: chunk, durationMs: duration)
            }
            return response
        }
        if let statusMapper {
            throw statusMapper(response.statusWord)
        }
        throw Self.failure(forStatus: response.statusWord, step: step, chunk: chunk)
    }

    /// The token for a status word the card answered during tap 1 (section 5): any status other than `9000` ends the
    /// ceremony on both sides.
    private static func failure(forStatus sw: UInt16, step: Step, chunk: Int?) -> NfcPairingV2Failure {
        let token: NfcPairingV2Token
        switch sw {
        case 0x6D00:
            token = .version
        case 0x6985:
            token = (step == .ek && (chunk ?? 0) == 0) ? .notArmed : .order
        case 0x6A80:
            if step == .ek && chunk == NfcPairingV2.chunkCount - 1 {
                token = .kem
            } else if step == .hello {
                token = .version
            } else {
                token = .length
            }
        case 0x6700, 0x6A86:
            token = .length
        default:
            token = .cardError
        }
        return NfcPairingV2Failure(token, statusWord: sw)
    }
}
