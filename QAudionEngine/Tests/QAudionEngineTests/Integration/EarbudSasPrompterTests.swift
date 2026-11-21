import XCTest
@testable import QAudionEngine

/// The person's side of the FE-5 confirmation gate: one open question, an explicit answer, never left hanging.
@MainActor
final class EarbudSasPrompterTests: XCTestCase {

    private let pairId = Data((0..<32).map { UInt8($0) })

    /// Lets the asking task run until the prompter has published its question.
    private func waitForPrompt(_ p: EarbudSasPrompter) async {
        for _ in 0..<500 where p.current == nil { await Task.yield() }
    }

    func testConfirmAnswersTrueAndClosesTheQuestion() async {
        let p = EarbudSasPrompter()
        var changes: [Bool] = []   // true = a question opened, false = it closed
        p.onChange = { changes.append($0 != nil) }
        let asking = Task { await p.ask(pairId: self.pairId) }
        await waitForPrompt(p)

        XCTAssertEqual(p.current?.pairId, pairId)
        XCTAssertEqual(p.current?.words, ["accrue", "adult", "aimless", "alone", "apple", "Athens"])
        XCTAssertEqual(p.current?.fingerprint, "0001 0203 0405 0607")
        XCTAssertEqual(p.current?.id, p.current?.token, "each question is its own sheet")
        guard let prompt = p.current else { return XCTFail("no question is open") }

        XCTAssertTrue(p.confirm(prompt), "the answer was for the open question")
        let answer = await asking.value
        XCTAssertTrue(answer)
        XCTAssertNil(p.current)
        XCTAssertEqual(changes, [true, false])
    }

    func testRejectAnswersFalse() async {
        let p = EarbudSasPrompter()
        let asking = Task { await p.ask(pairId: self.pairId) }
        await waitForPrompt(p)
        guard let prompt = p.current else { return XCTFail("no question is open") }
        XCTAssertTrue(p.reject(prompt))
        let answer = await asking.value
        XCTAssertFalse(answer)
        XCTAssertNil(p.current)
    }

    func testTheOwnerTearingDownClosesTheOpenQuestionAsNotConfirmed() async {
        let p = EarbudSasPrompter()
        let asking = Task { await p.ask(pairId: self.pairId) }
        await waitForPrompt(p)
        p.reject()   // the screen goes away, the link drops: no prompt is needed to say "no"
        let answer = await asking.value
        XCTAssertFalse(answer)
        XCTAssertNil(p.current)
    }

    func testACancelledTaskAnswersFalseAndClosesTheQuestion() async {
        let p = EarbudSasPrompter()
        let asking = Task { await p.ask(pairId: self.pairId) }
        await waitForPrompt(p)
        XCTAssertNotNil(p.current)

        asking.cancel()   // the relay's timeout, the screen going away, the link dropping
        let answer = await asking.value
        XCTAssertFalse(answer)
        XCTAssertNil(p.current, "the dialog closes with the question")
    }

    func testATaskCancelledBeforeItAsksIsNotConfirmed() async {
        let p = EarbudSasPrompter()
        let asking = Task { () -> Bool in
            while !Task.isCancelled { await Task.yield() }
            return await p.ask(pairId: self.pairId)
        }
        await Task.yield()
        asking.cancel()
        let answer = await asking.value
        XCTAssertFalse(answer)
        XCTAssertNil(p.current)
    }

    func testASecondQuestionWhileOneIsOpenIsRefusedAndTheFirstStaysOpen() async {
        let p = EarbudSasPrompter()
        let first = Task { await p.ask(pairId: self.pairId) }
        await waitForPrompt(p)

        let other = Data(repeating: 0x42, count: 32)
        let second = await p.ask(pairId: other)
        XCTAssertFalse(second, "refused, never confirmed blind")
        XCTAssertEqual(p.current?.pairId, pairId, "the first question is untouched")

        guard let prompt = p.current else { return XCTFail("no question is open") }
        p.confirm(prompt)
        let firstAnswer = await first.value
        XCTAssertTrue(firstAnswer)
    }

    func testAPairIdThatIsNot32BytesIsRefusedWithoutAQuestion() async {
        let p = EarbudSasPrompter()
        let answer = await p.ask(pairId: Data(count: 31))
        XCTAssertFalse(answer)
        XCTAssertNil(p.current)
    }

    func testAnAnswerWithNoQuestionOpenDoesNothing() async {
        let p = EarbudSasPrompter()
        let never = EarbudSasPrompter.Prompt(pairId: pairId, words: [], fingerprint: "", token: 1)
        XCTAssertFalse(p.confirm(never))
        XCTAssertFalse(p.reject(never))
        p.reject()
        XCTAssertNil(p.current)

        // And a late "confirm" after the answer does not carry over to the next question.
        let first = Task { await p.ask(pairId: self.pairId) }
        await waitForPrompt(p)
        guard let firstPrompt = p.current else { return XCTFail("no question is open") }
        p.reject(firstPrompt)
        let firstAnswer = await first.value
        XCTAssertFalse(firstAnswer)
        XCTAssertFalse(p.confirm(firstPrompt), "the question is closed: nothing to confirm")

        let second = Task { await p.ask(pairId: self.pairId) }
        await waitForPrompt(p)
        XCTAssertNotNil(p.current, "a new question opens and waits for its own answer")
        p.reject()
        let secondAnswer = await second.value
        XCTAssertFalse(secondAnswer)
    }

    // MARK: - An answer belongs to the question it answers

    /// The same two earbuds give the same pair_id on every attempt, so the pair_id cannot tell two questions apart.
    func testALateConfirmOfAClosedQuestionDoesNotConfirmTheNextQuestionOfTheSamePairId() async {
        let p = EarbudSasPrompter()
        let first = Task { await p.ask(pairId: self.pairId) }
        await waitForPrompt(p)
        guard let firstPrompt = p.current else { return XCTFail("no question is open") }

        // The first question ends without an answer (the relay's timeout cancels it); the person's tap is still on its way.
        first.cancel()
        let firstAnswer = await first.value
        XCTAssertFalse(firstAnswer)
        XCTAssertNil(p.current)

        // The person starts over: the same pair_id is asked again.
        let second = Task { await p.ask(pairId: self.pairId) }
        await waitForPrompt(p)
        guard let secondPrompt = p.current else { return XCTFail("no second question") }
        XCTAssertEqual(secondPrompt.pairId, firstPrompt.pairId)
        XCTAssertNotEqual(secondPrompt.token, firstPrompt.token, "the second question is not the first one")

        // The late tap of the first sheet arrives now.
        XCTAssertFalse(p.confirm(firstPrompt), "a tap for the first question must not confirm the second")
        XCTAssertEqual(p.current, secondPrompt, "the second question is still open and unanswered")

        // Only its own answer counts.
        XCTAssertTrue(p.confirm(secondPrompt))
        let secondAnswer = await second.value
        XCTAssertTrue(secondAnswer)
    }

    func testAConfirmForAnotherPairIdDoesNotConfirmTheOpenQuestion() async {
        let p = EarbudSasPrompter()
        let asking = Task { await p.ask(pairId: self.pairId) }
        await waitForPrompt(p)
        guard let prompt = p.current else { return XCTFail("no question is open") }

        // A prompt of another pairing is not this question, whatever it shows.
        let otherPairId = Data(repeating: 0x42, count: 32)
        let other = EarbudSasPrompter.Prompt(
            pairId: otherPairId, words: prompt.words, fingerprint: prompt.fingerprint, token: prompt.token &+ 1)
        XCTAssertFalse(p.confirm(other))
        XCTAssertEqual(p.current, prompt, "still open, still unanswered")

        XCTAssertTrue(p.confirm(prompt))
        let answer = await asking.value
        XCTAssertTrue(answer)
    }

    func testALateRejectOfAClosedQuestionDoesNotCloseTheNextOne() async {
        let p = EarbudSasPrompter()
        let first = Task { await p.ask(pairId: self.pairId) }
        await waitForPrompt(p)
        guard let firstPrompt = p.current else { return XCTFail("no question is open") }
        p.confirm(firstPrompt)
        let firstAnswer = await first.value
        XCTAssertTrue(firstAnswer)

        let second = Task { await p.ask(pairId: self.pairId) }
        await waitForPrompt(p)
        guard let secondPrompt = p.current else { return XCTFail("no second question") }
        XCTAssertFalse(p.reject(firstPrompt), "the person did not decline the second question")
        XCTAssertEqual(p.current, secondPrompt)

        XCTAssertTrue(p.reject(secondPrompt))
        let secondAnswer = await second.value
        XCTAssertFalse(secondAnswer)
    }

    func testEveryQuestionGetsANewToken() async {
        let p = EarbudSasPrompter()
        var tokens: [UInt64] = []
        for _ in 0..<3 {
            let asking = Task { await p.ask(pairId: self.pairId) }
            await waitForPrompt(p)
            guard let prompt = p.current else { return XCTFail("no question is open") }
            tokens.append(prompt.token)
            p.reject(prompt)
            _ = await asking.value
        }
        XCTAssertEqual(Set(tokens).count, 3, "tokens: \(tokens)")
    }

    func testTheGateWorksWithTheRelayTimeoutShape() async {
        // The shape EarbudPairingRelay uses: the gate races a timer, and the timer's win cancels the gate.
        let p = EarbudSasPrompter()
        let prompterAnswer = Task { await p.ask(pairId: self.pairId) }
        await waitForPrompt(p)
        try? await Task.sleep(nanoseconds: 30_000_000)
        prompterAnswer.cancel()
        let answer = await prompterAnswer.value
        XCTAssertFalse(answer)
        XCTAssertNil(p.current)
    }
}
