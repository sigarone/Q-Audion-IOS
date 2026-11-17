import Foundation

/// The person's side of the FE-5 pairing confirmation gate (CL-2.2): one open question at a time,
/// answered by an explicit confirm or reject, and never left hanging.
///
/// `EarbudPairingRelay.pairWithPeer` takes an `isConfirmed` closure and waits for it before it writes
/// PAIR_FIN. The closure of a screen is `{ await prompter.ask(pairId:) }`: `ask` publishes a `Prompt`
/// (the six words and the fingerprint of the pair_id) through `onChange`, the screen shows it, and the
/// two buttons call `confirm()` / `reject()`. There is no default answer: a dialog that is closed
/// some other way, a cancelled task (the relay's 120 s timeout, the screen going away, the link
/// dropping) and a second question while one is open all answer `false`.
///
/// Pure Foundation, so the gate is unit-tested without a screen (EarbudSasPrompterTests).
@MainActor
public final class EarbudSasPrompter {

    /// What the confirmation dialog shows. `Identifiable` by the pair_id, so a sheet can bind to it.
    public struct Prompt: Equatable, Identifiable, Sendable {
        /// The full 32-byte pair_id.
        public let pairId: Data
        /// `EarbudPairTranscript.sasWords`: six words.
        public let words: [String]
        /// `EarbudPairTranscript.sasFingerprintDisplay`: 16 hex characters in groups of four.
        public let fingerprint: String
        public var id: Data { pairId }
    }

    /// The open question, nil when there is none.
    public private(set) var current: Prompt?

    /// Called with the new `current` every time it changes (a question opens, an answer closes it).
    public var onChange: ((Prompt?) -> Void)?

    private var continuation: CheckedContinuation<Bool, Never>?

    public init() {}

    /// Opens the question for `pairId` and suspends until it is answered.
    ///
    /// - Returns: true only when `confirm()` was called while this question was open. false for
    ///   `reject()`, a cancelled task, a pair_id that is not 32 bytes, and a question asked while
    ///   another is still open (it is refused, never confirmed blind).
    public func ask(pairId: Data) async -> Bool {
        guard continuation == nil,
              let words = EarbudPairTranscript.sasWords(pairId: pairId),
              let fingerprint = EarbudPairTranscript.sasFingerprintDisplay(pairId: pairId) else {
            return false
        }
        let prompt = Prompt(pairId: pairId, words: words, fingerprint: fingerprint)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled {
                    cont.resume(returning: false)
                    return
                }
                self.continuation = cont
                self.current = prompt
                self.onChange?(prompt)
            }
        } onCancel: {
            Task { @MainActor in self.finish(false) }
        }
    }

    /// The person confirms that the words match the other phone: PAIR_FIN may be written.
    public func confirm() { finish(true) }

    /// The person declines, or backs out: the pairing stops and PAIR_FIN is never written.
    public func reject() { finish(false) }

    private func finish(_ answer: Bool) {
        guard let cont = continuation else { return }
        continuation = nil
        current = nil
        onChange?(nil)
        cont.resume(returning: answer)
    }
}
