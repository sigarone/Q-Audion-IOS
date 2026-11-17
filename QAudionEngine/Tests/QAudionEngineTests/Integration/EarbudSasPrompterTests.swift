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
        XCTAssertEqual(p.current?.id, pairId)

        p.confirm()
        let answer = await asking.value
        XCTAssertTrue(answer)
        XCTAssertNil(p.current)
        XCTAssertEqual(changes, [true, false])
    }

    func testRejectAnswersFalse() async {
        let p = EarbudSasPrompter()
        let asking = Task { await p.ask(pairId: self.pairId) }
        await waitForPrompt(p)
        p.reject()
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

        p.confirm()
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
        p.confirm()
        p.reject()
        XCTAssertNil(p.current)

        // And a late "confirm" after the answer does not carry over to the next question.
        let first = Task { await p.ask(pairId: self.pairId) }
        await waitForPrompt(p)
        p.reject()
        let firstAnswer = await first.value
        XCTAssertFalse(firstAnswer)
        p.confirm()

        let second = Task { await p.ask(pairId: self.pairId) }
        await waitForPrompt(p)
        XCTAssertNotNil(p.current, "a new question opens and waits for its own answer")
        p.reject()
        let secondAnswer = await second.value
        XCTAssertFalse(secondAnswer)
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
