import XCTest
@testable import v2s

final class ConversationFloorArbiterTests: XCTestCase {
    private func observation(
        _ confidence: Double,
        _ text: String = "hello",
        isFinal: Bool = false
    ) -> ConversationFloorArbiter.Observation {
        ConversationFloorArbiter.Observation(confidence: confidence, text: text, isFinal: isFinal)
    }

    func testFloorStartsOnPrimaryAndHoldsWithoutEvidence() {
        var arbiter = ConversationFloorArbiter()
        XCTAssertEqual(arbiter.floor, .primary)

        XCTAssertFalse(arbiter.observe(primary: .silent, secondary: .silent))
        XCTAssertEqual(arbiter.floor, .primary)
    }

    func testSilentChallengerNeverTakesTheFloor() {
        var arbiter = ConversationFloorArbiter()

        for _ in 0..<10 {
            XCTAssertFalse(arbiter.observe(primary: observation(0.2), secondary: .silent))
        }
        XCTAssertEqual(arbiter.floor, .primary)
    }

    func testWhitespaceOnlyHypothesisCountsAsSilence() {
        var arbiter = ConversationFloorArbiter()

        for _ in 0..<5 {
            XCTAssertFalse(
                arbiter.observe(
                    primary: observation(0.2),
                    secondary: observation(0.99, "   \n ")
                )
            )
        }
        XCTAssertEqual(arbiter.floor, .primary)
    }

    func testChallengerMustClearMarginForRequiredConsecutiveWins() {
        var arbiter = ConversationFloorArbiter(margin: 0.1, requiredWins: 3)

        XCTAssertFalse(arbiter.observe(primary: observation(0.5), secondary: observation(0.7)))
        XCTAssertFalse(arbiter.observe(primary: observation(0.5), secondary: observation(0.7)))
        XCTAssertEqual(arbiter.floor, .primary, "two wins is not enough")

        XCTAssertTrue(arbiter.observe(primary: observation(0.5), secondary: observation(0.7)))
        XCTAssertEqual(arbiter.floor, .secondary)
    }

    func testWinStreakResetsWhenTheIncumbentRecovers() {
        var arbiter = ConversationFloorArbiter(margin: 0.1, requiredWins: 3)

        XCTAssertFalse(arbiter.observe(primary: observation(0.5), secondary: observation(0.7)))
        XCTAssertFalse(arbiter.observe(primary: observation(0.5), secondary: observation(0.7)))
        // Incumbent pulls back inside the margin: the streak must not carry over.
        XCTAssertFalse(arbiter.observe(primary: observation(0.7), secondary: observation(0.7)))
        XCTAssertFalse(arbiter.observe(primary: observation(0.5), secondary: observation(0.7)))
        XCTAssertFalse(arbiter.observe(primary: observation(0.5), secondary: observation(0.7)))
        XCTAssertEqual(arbiter.floor, .primary)

        XCTAssertTrue(arbiter.observe(primary: observation(0.5), secondary: observation(0.7)))
        XCTAssertEqual(arbiter.floor, .secondary)
    }

    func testConfidenceInsideMarginNeverFlipsTheFloor() {
        var arbiter = ConversationFloorArbiter(margin: 0.1, requiredWins: 2)

        for _ in 0..<20 {
            XCTAssertFalse(arbiter.observe(primary: observation(0.60), secondary: observation(0.69)))
        }
        XCTAssertEqual(arbiter.floor, .primary)
    }

    func testSilentIncumbentYieldsImmediately() {
        var arbiter = ConversationFloorArbiter(margin: 0.5, requiredWins: 9)

        // Nothing heard on the floor lane: waiting out the margin would drop the
        // opening words of the utterance.
        XCTAssertTrue(arbiter.observe(primary: .silent, secondary: observation(0.1)))
        XCTAssertEqual(arbiter.floor, .secondary)
    }

    func testFinalizedIncumbentKeepsTheFloorForTheRestOfTheUtterance() {
        var arbiter = ConversationFloorArbiter(margin: 0.05, requiredWins: 1)

        XCTAssertFalse(
            arbiter.observe(
                primary: observation(0.6, "done", isFinal: true),
                secondary: observation(0.99)
            )
        )
        XCTAssertEqual(arbiter.floor, .primary)

        for _ in 0..<10 {
            XCTAssertFalse(
                arbiter.observe(primary: observation(0.1), secondary: observation(0.99))
            )
        }
        XCTAssertEqual(arbiter.floor, .primary, "a finalized turn must not be reassigned")
    }

    func testFinalResolutionMovesToClearlyStrongerChallenger() {
        var arbiter = ConversationFloorArbiter(margin: 0.08, requiredWins: 3)

        XCTAssertTrue(
            arbiter.resolveFinal(
                primary: observation(0.54, "wrong"),
                secondary: observation(0.81, "correct", isFinal: true)
            )
        )
        XCTAssertEqual(arbiter.floor, .secondary)
    }

    func testFinalResolutionHoldsWhenScoresAreInsideMargin() {
        var arbiter = ConversationFloorArbiter(margin: 0.08, requiredWins: 3)

        XCTAssertFalse(
            arbiter.resolveFinal(
                primary: observation(0.70, "primary"),
                secondary: observation(0.76, "secondary", isFinal: true)
            )
        )
        XCTAssertEqual(arbiter.floor, .primary)
    }

    func testPinnedFloorOverridesFinalResolution() {
        var arbiter = ConversationFloorArbiter(margin: 0.01, requiredWins: 1)
        arbiter.pin(.primary)

        XCTAssertFalse(
            arbiter.resolveFinal(
                primary: observation(0.01, "primary"),
                secondary: observation(0.99, "secondary", isFinal: true)
            )
        )
        XCTAssertEqual(arbiter.floor, .primary)
    }

    func testCommitUtteranceReleasesStickinessForTheNextUtterance() {
        var arbiter = ConversationFloorArbiter(margin: 0.05, requiredWins: 1)
        _ = arbiter.observe(
            primary: observation(0.6, "done", isFinal: true),
            secondary: observation(0.99)
        )

        arbiter.commitUtterance()

        XCTAssertTrue(arbiter.observe(primary: observation(0.1), secondary: observation(0.99)))
        XCTAssertEqual(arbiter.floor, .secondary)
    }

    func testPinOverridesScoringUntilCommit() {
        var arbiter = ConversationFloorArbiter(margin: 0.05, requiredWins: 1)

        arbiter.pin(.secondary)
        XCTAssertEqual(arbiter.floor, .secondary)

        for _ in 0..<10 {
            XCTAssertFalse(
                arbiter.observe(primary: observation(0.99), secondary: observation(0.01))
            )
            XCTAssertEqual(arbiter.floor, .secondary, "a manual claim outranks confidence")
        }

        arbiter.commitUtterance()
        XCTAssertTrue(arbiter.observe(primary: observation(0.99), secondary: observation(0.01)))
        XCTAssertEqual(arbiter.floor, .primary)
    }

    func testPinIsIdempotentAndSurvivesSilence() {
        var arbiter = ConversationFloorArbiter()
        arbiter.pin(.secondary)
        arbiter.pin(.secondary)

        XCTAssertFalse(arbiter.observe(primary: .silent, secondary: .silent))
        XCTAssertEqual(arbiter.floor, .secondary)
    }

    func testDegenerateConfigurationIsClamped() {
        let arbiter = ConversationFloorArbiter(margin: -1, requiredWins: 0)
        XCTAssertEqual(arbiter.margin, 0)
        XCTAssertEqual(arbiter.requiredWins, 1)
    }

    func testOppositeSide() {
        XCTAssertEqual(ConversationSide.primary.opposite, .secondary)
        XCTAssertEqual(ConversationSide.secondary.opposite, .primary)
    }
}
