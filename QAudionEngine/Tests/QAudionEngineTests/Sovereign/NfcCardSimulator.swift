import Foundation
import CryptoKit
@testable import QAudionEngine

/// A manual clock for the ceremony tests: `sleep` advances it, nothing waits in real time.
final class NfcTestClock {
    var now: UInt64 = 1_000_000
}

/// A card for the reader tests, written from docs/security/NFC_PAIRING_V2.md sections 5, 6 and 9 with the same
/// primitives the reader uses. It plays the Android side of the exchange: the checks of the card, the ceremony
/// screen of the card (armed, decision), the pending store and FINALIZE. The tests switch behaviours on and off
/// to reproduce the loss rows of section 9.
final class NfcCardSimulator: NfcIso7816Transport {

    /// Values the card takes as given: with these, the exchange is the one of the shared vectors.
    struct Fixed {
        let xPrivate: Data
        let nonce: Data
        let ciphertext: Data
        let kemSharedSecret: Data
        /// The AUTH_C response of the vector (its signature is deterministic RFC 8032).
        let sealedAuth: Data?
    }

    enum UserDecision {
        case undecided
        case confirmed
        case rejected
    }

    // MARK: Configuration

    var armed = true
    var selectData: Data? = Data([NfcPairingV2.version])
    var fixed: Fixed?
    var authOverride: Data?
    var user: UserDecision = .confirmed
    /// CONFIRM answers `00` this many times before the card's user decision applies (the store takes time).
    var pendingAnswers = 0
    var storeFails = false
    /// FINALIZE answers `00` this many times before the card acknowledges it.
    var finalizePendingAnswers = 0
    var clock: NfcTestClock?
    /// Milliseconds the clock moves forward for a command of the step (the card's processing time).
    var latencyMs: [String: UInt64] = [:]
    /// The command executes, the response never reaches the reader.
    var dropResponse: Set<String> = []
    /// The field is lost before the command reaches the card.
    var failBefore: Set<String> = []
    /// Answer with this status word instead of running the command.
    var statusOverride: [String: UInt16] = [:]
    /// Replace the data of the response of the step (status stays 9000).
    var dataOverride: [String: Data] = [:]
    /// Called with the step name when a command reaches the card, before it is handled.
    var beforeCommand: ((String) -> Void)?

    private let seed: Data
    let identity: NfcPairingV2Identity

    init(seed: Data, publicKey: Data, userId: String) throws {
        self.seed = seed
        self.identity = try NfcPairingV2Identity(publicKey: publicKey, userId: userId)
    }

    // MARK: Observation

    private(set) var log: [(name: String, command: Data, response: Data)] = []
    private(set) var storedPsk: Data?
    private(set) var finalized = false
    private(set) var lastFailure: NfcPairingV2Token?
    private(set) var peerShownToUser: NfcPairingV2Identity?
    private(set) var sasShownToUser: String?
    var commandNames: [String] { log.map { $0.name } }

    func count(_ name: String) -> Int { log.filter { $0.name == name }.count }

    /// Simulates the card finalizing another key of the device by a call (section 9): from then on CONFIRM and
    /// FINALIZE get `03`, the pending key stays.
    func endCeremony() { ceremonyEnded = true }

    // MARK: State

    private var ceremonyEnded = false
    private var nextChunk = 0
    private var ek = Data()
    private var lastChunk: (index: Int, bytes: Data)?
    private var ciphertext = Data()
    private var kemSecret = Data()
    private var helloCommand = Data()
    private var helloResponse = Data()
    private var cardKey: Curve25519.KeyAgreement.PrivateKey?
    private var cardNonce = Data()
    private var stage1: NfcPairingV2Crypto.Stage1?
    private var th1 = Data()
    private var thCard = Data()
    private var commitment = Data()
    private var stage2: NfcPairingV2Crypto.Stage2?
    private var helloDone = false
    private var authSent = false
    private var revealed = false

    // MARK: Transport

    func transceive(_ command: NfcApduCommand) async throws -> NfcApduResponse {
        let name = Self.stepName(command)
        beforeCommand?(name)
        if failBefore.contains(name) { throw NfcTransportError.fieldLost }
        if let clock, let ms = latencyMs[name] { clock.now += ms }
        var response: NfcApduResponse
        if let sw = statusOverride[name] {
            response = NfcApduResponse(data: Data(), statusWord: sw)
        } else {
            response = handle(command, name: name)
        }
        if let data = dataOverride[name], response.isOk {
            response = NfcApduResponse(data: data, statusWord: response.statusWord)
        }
        log.append((name, command.encoded, response.data + Data([UInt8(response.statusWord >> 8), UInt8(response.statusWord & 0xFF)])))
        if dropResponse.contains(name) { throw NfcTransportError.fieldLost }
        return response
    }

    static func stepName(_ c: NfcApduCommand) -> String {
        if c.cla == 0x00 && c.ins == 0xA4 { return "select" }
        switch NfcPairingV2.Instruction(rawValue: c.ins) {
        case .ekPut: return "ek"
        case .hello: return "hello"
        case .ctGet: return "ct"
        case .authCard: return "auth"
        case .reveal: return "reveal"
        case .confirm: return "confirm"
        case .finalize: return "finalize"
        case nil: return "unknown"
        }
    }

    private func ok(_ data: Data = Data()) -> NfcApduResponse { NfcApduResponse(data: data, statusWord: 0x9000) }
    private func sw(_ value: UInt16) -> NfcApduResponse { NfcApduResponse(data: Data(), statusWord: value) }

    /// A handshake that went past HELLO and did not end with a valid REVEAL disarms the card (section 6).
    private func abort(_ token: NfcPairingV2Token, _ status: UInt16) -> NfcApduResponse {
        lastFailure = token
        if helloDone { armed = false }
        return sw(status)
    }

    private func handle(_ c: NfcApduCommand, name: String) -> NfcApduResponse {
        if name == "select" {
            guard c.data == NfcPairingV2.aid else { return sw(0x6A82) }
            guard let selectData else { return ok() }
            return ok(selectData)
        }
        guard c.cla == NfcPairingV2.proprietaryClass, let ins = NfcPairingV2.Instruction(rawValue: c.ins) else {
            return sw(0x6D00)
        }
        guard armed else {
            lastFailure = .notArmed
            return sw(0x6985)
        }
        switch ins {
        case .ekPut: return handleEkPut(c)
        case .hello: return handleHello(c)
        case .ctGet: return handleCtGet(c)
        case .authCard: return handleAuth()
        case .reveal: return handleReveal(c)
        case .confirm: return handleConfirm(c)
        case .finalize: return handleFinalize(c)
        }
    }

    private func handleEkPut(_ c: NfcApduCommand) -> NfcApduResponse {
        guard c.p2 == UInt8(NfcPairingV2.chunkCount), c.p1 < UInt8(NfcPairingV2.chunkCount) else { return sw(0x6A86) }
        guard c.data.count == NfcPairingV2.chunkBytes else { return sw(0x6700) }
        let index = Int(c.p1)
        if helloDone { return abort(.order, 0x6985) }
        if index == nextChunk {
            if index == 0 { ek = Data() }
            ek.append(c.data)
            lastChunk = (index, c.data)
            nextChunk += 1
            if nextChunk == NfcPairingV2.chunkCount { return encapsulate() }
            return ok()
        }
        // The last chunk may be repeated with identical bytes (a reader retrying after a transceive error).
        if let last = lastChunk, last.index == index {
            return last.bytes == c.data ? ok() : abort(.order, 0x6A80)
        }
        return abort(.order, 0x6985)
    }

    private func encapsulate() -> NfcApduResponse {
        if let fixed {
            ciphertext = fixed.ciphertext
            kemSecret = fixed.kemSharedSecret
            return ok()
        }
        do {
            // The library performs the FIPS 203 modulus check of the encapsulation key.
            let result = try ProximityPairingCrypto.kemEncapsulate(publicKey: ek)
            ciphertext = result.ciphertext
            kemSecret = result.sharedSecret
            return ok()
        } catch {
            return abort(.kem, 0x6A80)
        }
    }

    private func handleHello(_ c: NfcApduCommand) -> NfcApduResponse {
        guard c.data.count == NfcPairingV2.helloCommandBytes else { return sw(0x6700) }
        guard c.data[c.data.startIndex] == NfcPairingV2.version else { return sw(0x6A80) }
        guard nextChunk == NfcPairingV2.chunkCount, !helloDone else { return abort(.order, 0x6985) }
        helloCommand = c.data
        commitment = Data(c.data.suffix(32))
        let key: Curve25519.KeyAgreement.PrivateKey
        if let fixed, let k = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: fixed.xPrivate) {
            key = k
            cardNonce = fixed.nonce
        } else {
            key = Curve25519.KeyAgreement.PrivateKey()
            cardNonce = (try? ProximityPairingCrypto.randomBytes(32)) ?? Data(repeating: 0x5A, count: 32)
        }
        cardKey = key
        helloResponse = key.publicKey.rawRepresentation + cardNonce
        helloDone = true
        return ok(helloResponse)
    }

    private func handleCtGet(_ c: NfcApduCommand) -> NfcApduResponse {
        guard c.p2 == UInt8(NfcPairingV2.chunkCount), c.p1 < UInt8(NfcPairingV2.chunkCount) else { return sw(0x6A86) }
        guard helloDone else { return abort(.order, 0x6985) }
        let start = Int(c.p1) * NfcPairingV2.chunkBytes
        return ok(ciphertext.subdata(in: start..<(start + NfcPairingV2.chunkBytes)))
    }

    private func handleAuth() -> NfcApduResponse {
        guard helloDone, !authSent, let cardKey else { return abort(.order, 0x6985) }
        let readerKey = Data(helloCommand.dropFirst().prefix(32))
        guard let ssX = try? ProximityPairingCrypto.x25519SharedSecret(privateKey: cardKey, peerPublicKey: readerKey) else {
            return abort(.x25519Zero, 0x6A80)
        }
        th1 = NfcPairingV2Crypto.transcriptHash1(
            selectData: selectData ?? Data(), encapsulationKey: ek, helloCommand: helloCommand,
            helloResponse: helloResponse, ciphertext: ciphertext)
        guard let s1 = try? NfcPairingV2Crypto.deriveStage1(th1: th1, kemSharedSecret: kemSecret, x25519SharedSecret: ssX) else {
            return abort(.length, 0x6F00)
        }
        stage1 = s1
        thCard = NfcPairingV2Crypto.transcriptHashCard(th1: th1, cardIdentityBlock: identity.block)
        authSent = true
        if let authOverride { return ok(authOverride) }
        if let sealed = fixed?.sealedAuth { return ok(sealed) }
        guard let sealed = try? NfcPairingV2Crypto.sealCardAuth(identity: identity, signingPrivateKey: seed, th1: th1, stage1: s1) else {
            return abort(.length, 0x6F00)
        }
        return ok(sealed)
    }

    private func handleReveal(_ c: NfcApduCommand) -> NfcApduResponse {
        guard authSent, !revealed, let stage1 else { return abort(.order, 0x6985) }
        do {
            let opened = try NfcPairingV2Crypto.verifyReveal(
                sealed: c.data, stage1: stage1, thCard: thCard, readerCommitment: commitment,
                ownIdentityKey: identity.publicKey)
            let s2 = try NfcPairingV2Crypto.deriveStage2(prk1: stage1.prk1, thReader: opened.thReader,
                                                         readerNonce: opened.nonce, cardNonce: cardNonce)
            stage2 = s2
            peerShownToUser = opened.identity
            sasShownToUser = s2.sas
            revealed = true
            return ok()
        } catch let failure as NfcPairingV2Failure {
            return abort(failure.token, failure.token == .length || failure.token == .userId ? 0x6A80 : 0x6982)
        } catch {
            return abort(.length, 0x6F00)
        }
    }

    private func handleConfirm(_ c: NfcApduCommand) -> NfcApduResponse {
        guard c.data.count == 33 else { return sw(0x6700) }
        let decisionByte = c.data[c.data.startIndex]
        guard let decision = NfcPairingV2.Decision(rawValue: decisionByte) else { return sw(0x6A80) }
        guard revealed, !ceremonyEnded, let s2 = stage2 else { return ok(Data([NfcPairingV2.CardState.noCeremony.rawValue])) }
        let tag = Data(c.data.dropFirst())
        switch decision {
        case .reject:
            guard NfcPairingV2Crypto.tagMatches(tag, s2.rejectReader) else {
                return ok(Data([NfcPairingV2.CardState.noCeremony.rawValue]))
            }
            ceremonyEnded = true
            return ok(Data([NfcPairingV2.CardState.aborted.rawValue]))
        case .confirm:
            guard NfcPairingV2Crypto.tagMatches(tag, s2.confirmReader) else {
                return ok(Data([NfcPairingV2.CardState.noCeremony.rawValue]))
            }
            switch user {
            case .undecided:
                return ok(Data([NfcPairingV2.CardState.pending.rawValue]))
            case .rejected:
                return ok(Data([NfcPairingV2.CardState.rejected.rawValue]) + s2.rejectCard)
            case .confirmed:
                if storedPsk == nil {
                    if pendingAnswers > 0 {
                        pendingAnswers -= 1
                        return ok(Data([NfcPairingV2.CardState.pending.rawValue]))
                    }
                    if storeFails {
                        ceremonyEnded = true
                        lastFailure = .storeFailed
                        return sw(0x6F00)
                    }
                    storedPsk = s2.psk
                }
                return ok(Data([NfcPairingV2.CardState.confirmed.rawValue]) + s2.confirmCard)
            }
        }
    }

    private func handleFinalize(_ c: NfcApduCommand) -> NfcApduResponse {
        guard c.data.count == 32 else { return sw(0x6700) }
        guard revealed, !ceremonyEnded, let s2 = stage2,
              NfcPairingV2Crypto.tagMatches(c.data, s2.finalizeReader) else {
            return ok(Data([NfcPairingV2.CardState.noCeremony.rawValue]))
        }
        guard storedPsk != nil else { return ok(Data([NfcPairingV2.CardState.pending.rawValue])) }
        if finalizePendingAnswers > 0 {
            finalizePendingAnswers -= 1
            return ok(Data([NfcPairingV2.CardState.pending.rawValue]))
        }
        finalized = true
        return ok(Data([NfcPairingV2.CardState.confirmed.rawValue]))
    }
}
