import Foundation

/// The person's side of the FE-5 pairing confirmation gate (CL-2.2): one open question at a time,
/// answered by an explicit confirm or reject, and never left hanging.
///
/// `EarbudPairingRelay.pairWithPeer` takes an `isConfirmed` closure and waits for it before it writes
/// PAIR_FIN. The closure of a screen is `{ await prompter.ask(pairId:) }`: `ask` publishes a `Prompt`
/// (the six words and the fingerprint of the pair_id) through `onChange`, the screen shows it, and the
/// two buttons call `confirm(_:)` / `reject(_:)` with the prompt they show. There is no default answer: a
/// dialog that is closed some other way, a cancelled task (the relay's 120 s timeout, the screen going
/// away, the link dropping) and a second question while one is open all answer `false`.
///
/// An answer belongs to ONE question. Every `Prompt` carries a `token` that is new for each question, and
/// `confirm(_:)` / `reject(_:)` act only while that very question is the open one. A tap that arrives late,
/// after the question it was meant for has closed (the timeout, a cancelled pairing) and another has
/// opened, therefore answers nothing: the person never saw the words of the new question when they tapped.
/// The pair_id alone would not do: the same two earbuds give the same pair_id on every attempt.
///
/// Pure Foundation, so the gate is unit-tested without a screen (EarbudSasPrompterTests).
@MainActor
public final class EarbudSasPrompter {

    /// What the confirmation dialog shows. `Identifiable` by its `token`: each question is its own sheet.
    public struct Prompt: Equatable, Identifiable, Sendable {
        /// The full 32-byte pair_id.
        public let pairId: Data
        /// `EarbudPairTranscript.sasWords`: six words.
        public let words: [String]
        /// `EarbudPairTranscript.sasFingerprintDisplay`: 16 hex characters in groups of four.
        public let fingerprint: String
        /// Different for every question this prompter opens (even for the same pair_id): the answer
        /// buttons hand it back, and an answer that carries the token of a closed question is ignored.
        public let token: UInt64
        public var id: UInt64 { token }
    }

    /// The open question, nil when there is none.
    public private(set) var current: Prompt?

    /// Called with the new `current` every time it changes (a question opens, an answer closes it).
    public var onChange: ((Prompt?) -> Void)?

    private var continuation: CheckedContinuation<Bool, Never>?
    private var lastToken: UInt64 = 0

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
        lastToken &+= 1
        let prompt = Prompt(pairId: pairId, words: words, fingerprint: fingerprint, token: lastToken)
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

    /// The person confirms that the words of `prompt` match the other phone: PAIR_FIN may be written.
    ///
    /// Counts only while `prompt` is the open question; a prompt that has closed (or been replaced by a
    /// newer one) is ignored, so a late tap cannot confirm a question the person has not read.
    ///
    /// - Returns: true when this answered the open question.
    @discardableResult
    public func confirm(_ prompt: Prompt) -> Bool { answer(prompt, true) }

    /// The person declines `prompt`, or backs out of it: the pairing stops and PAIR_FIN is never written.
    /// Same binding as `confirm(_:)`: it never closes a different, newer question.
    ///
    /// - Returns: true when this answered the open question.
    @discardableResult
    public func reject(_ prompt: Prompt) -> Bool { answer(prompt, false) }

    /// Closes whatever question is open as "not confirmed". For the owner tearing the pairing down (the
    /// screen goes away, the link drops), never for a button: a button answers a given question through
    /// `reject(_:)`. A "no" is always safe, so this needs no prompt; a "yes" has no such form on purpose.
    public func reject() { finish(false) }

    private func answer(_ prompt: Prompt, _ value: Bool) -> Bool {
        guard let open = current, open.token == prompt.token else { return false }
        finish(value)
        return true
    }

    private func finish(_ answer: Bool) {
        guard let cont = continuation else { return }
        continuation = nil
        current = nil
        onChange?(nil)
        cont.resume(returning: answer)
    }
}
