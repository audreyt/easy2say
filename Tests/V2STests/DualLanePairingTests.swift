import XCTest
@testable import v2s

final class DualLanePairingTests: XCTestCase {
    func testVolatileFloorRequiresBothLanesToAdvance() {
        var pairing = DualLanePairing()
        let primary = observation(side: .primary, text: "大家好", confidence: 0.7, end: 0.4)
        let first = pairing.ingest(primary)
        XCTAssertNil(first.commitText)
        XCTAssertEqual(first.floor, .primary)

        let staleSecondary = observation(side: .secondary, text: "Hello", confidence: 0.95, end: 0.4)
        _ = pairing.ingest(staleSecondary)

        let secondPrimary = observation(side: .primary, text: "大家好啊", confidence: 0.71, end: 0.8)
        let afterPrimaryOnly = pairing.ingest(secondPrimary)
        XCTAssertEqual(afterPrimaryOnly.floor, .primary)

        let advancedSecondary = observation(side: .secondary, text: "Hello there", confidence: 0.95, end: 0.81)
        let afterBoth = pairing.ingest(advancedSecondary)
        XCTAssertEqual(afterBoth.floor, .primary)
    }

    func testWrongLaneFinalizingFirstDoesNotCommit() {
        var pairing = DualLanePairing()
        _ = pairing.ingest(observation(side: .primary, text: "大家好", confidence: 0.9, end: 0.5))
        _ = pairing.ingest(observation(side: .secondary, text: "Hello", confidence: 0.4, end: 0.5))

        let earlyEnglishFinal = pairing.ingest(
            observation(side: .secondary, text: "Hello", confidence: 0.4, isFinal: true, end: 0.5)
        )
        XCTAssertNil(earlyEnglishFinal.commitText)
        XCTAssertEqual(earlyEnglishFinal.floor, .primary)
    }

    func testAlignedFinalCommitsWinningFloor() {
        var pairing = DualLanePairing()
        _ = pairing.ingest(observation(side: .primary, text: "大家好", confidence: 0.92, end: 0.6))
        _ = pairing.ingest(observation(side: .secondary, text: "Hello", confidence: 0.4, end: 0.6))
        _ = pairing.ingest(observation(side: .secondary, text: "Hello", confidence: 0.4, isFinal: true, end: 0.6))

        let zhFinal = pairing.ingest(
            observation(side: .primary, text: "大家好", confidence: 0.92, isFinal: true, end: 0.6)
        )
        XCTAssertEqual(zhFinal.commitSide, .primary)
        XCTAssertEqual(zhFinal.commitText, "大家好")
    }

    func testAlignedFinalWithNilConfidenceSelectsPrimary() {
        var pairing = DualLanePairing()
        _ = pairing.ingest(observation(side: .primary, text: "大家好", confidence: nil, end: 0.6))
        _ = pairing.ingest(observation(side: .secondary, text: "Hello", confidence: nil, end: 0.6))
        _ = pairing.ingest(observation(side: .secondary, text: "Hello", confidence: nil, isFinal: true, end: 0.6))

        let zhFinal = pairing.ingest(
            observation(side: .primary, text: "大家好", confidence: nil, isFinal: true, end: 0.6)
        )
        XCTAssertEqual(zhFinal.commitSide, .primary)
        XCTAssertEqual(zhFinal.commitText, "大家好")
        XCTAssertEqual(zhFinal.evidence?.resolution, .normalMandarinOrMixed)
    }

    func testEnglishFinalWinsWhenConfidenceClearsMargin() {
        var pairing = DualLanePairing()
        let primaryText = "this is a sentence about tehnology"
        let secondaryText = "this is a sentence about technology"
        _ = pairing.ingest(observation(side: .primary, text: primaryText, confidence: 0.4, end: 0.5))
        _ = pairing.ingest(observation(side: .secondary, text: secondaryText, confidence: 0.93, end: 0.5))

        _ = pairing.ingest(observation(side: .primary, text: primaryText, confidence: 0.4, isFinal: true, end: 0.5))
        let englishFinal = pairing.ingest(
            observation(side: .secondary, text: secondaryText, confidence: 0.93, isFinal: true, end: 0.5)
        )
        XCTAssertEqual(englishFinal.commitSide, .secondary)
        XCTAssertEqual(englishFinal.commitText, secondaryText)
    }

    func testRangesAlignRequiresOverlap() {
        let pairing = DualLanePairing()
        let lhs = DualLaneHypothesis(volatileText: "a", startSeconds: 0, endSeconds: 0.4)
        let rhs = DualLaneHypothesis(volatileText: "b", startSeconds: 0.8, endSeconds: 1.2)
        XCTAssertFalse(pairing.rangesAlign(lhs, rhs))

        let overlapping = DualLaneHypothesis(volatileText: "b", startSeconds: 0.2, endSeconds: 0.5)
        XCTAssertTrue(pairing.rangesAlign(lhs, overlapping))
    }

    func testRangesAlignRejectsEmptyHypothesis() {
        let pairing = DualLanePairing()
        let withSpeech = DualLaneHypothesis(volatileText: "a", startSeconds: 0, endSeconds: 0.4)
        let empty = DualLaneHypothesis(volatileText: "", startSeconds: 0, endSeconds: 0.4)
        XCTAssertFalse(pairing.rangesAlign(withSpeech, empty))
        XCTAssertFalse(pairing.rangesAlign(empty, withSpeech))
        XCTAssertFalse(pairing.rangesAlign(empty, empty))
    }

    func testCommitClearsStickinessForNextUtterance() {
        var pairing = DualLanePairing()
        _ = pairing.ingest(observation(side: .primary, text: "甲", confidence: 0.9, end: 0.4))
        _ = pairing.ingest(observation(side: .secondary, text: "A", confidence: 0.3, end: 0.4))
        _ = pairing.ingest(observation(side: .secondary, text: "A", confidence: 0.3, isFinal: true, end: 0.4))
        let commit = pairing.ingest(observation(side: .primary, text: "甲", confidence: 0.9, isFinal: true, end: 0.4))
        XCTAssertEqual(commit.commitSide, .primary)
        XCTAssertEqual(commit.commitText, "甲")

        _ = pairing.ingest(observation(side: .primary, text: "你好", confidence: 0.90, end: 1.0))
        let next = pairing.ingest(observation(side: .secondary, text: "Hello", confidence: 0.92, end: 1.0))
        XCTAssertEqual(next.floor, .primary)
        XCTAssertNil(next.commitText)
    }

    func testWrongLocalePrimaryFinalFirstDelayedEnglishResultWinsAndCommits() {
        var pairing = DualLanePairing()
        let primaryText = "this is a sentence about tehnology"
        let secondaryText = "this is a sentence about technology"
        // Primary final arrives first with all-Latin phonetic text, secondary has not emitted yet.
        let zhEarlyFinal = pairing.ingest(
            observation(side: .primary, text: primaryText, confidence: 0.82, isFinal: true, end: 0.5)
        )
        // Must NOT commit immediately because secondary lane has not aligned.
        XCTAssertNil(zhEarlyFinal.commitText)

        // Secondary English lane arrives delayed with higher confidence clearing margin.
        let englishDelayedFinal = pairing.ingest(
            observation(side: .secondary, text: secondaryText, confidence: 0.95, isFinal: true, end: 0.5)
        )
        // English wins and commits.
        XCTAssertEqual(englishDelayedFinal.commitSide, .secondary)
        XCTAssertEqual(englishDelayedFinal.commitText, secondaryText)
    }

    func testDelayedCounterpartWinsBeforeGraceFires() {
        guard #available(iOS 26.0, macOS 26.0, *) else { return }

        let runtime = DualLaneCaptionRuntime(primaryLanguageID: "zh-Hant", secondaryLanguageID: "en")
        var committedStep: DualLaneStep?

        runtime.onStep = { step, _ in
            if step.commitText != nil {
                committedStep = step
            }
        }

        let gen = runtime.currentGenerationForTesting()
        let primaryUpdate = ConversationLane.Update(
            side: .primary,
            text: "this is a sentence about tehnology",
            confidence: 0.82,
            isFinal: true,
            startSeconds: 0.0,
            endSeconds: 0.5,
            spans: []
        )
        runtime.handleUpdateForTesting(primaryUpdate, generation: gen)
        XCTAssertNil(committedStep)

        // Delayed English counterpart arrives before grace timer fires:
        let secondaryUpdate = ConversationLane.Update(
            side: .secondary,
            text: "this is a sentence about technology",
            confidence: 0.95,
            isFinal: true,
            startSeconds: 0.0,
            endSeconds: 0.5,
            spans: []
        )
        runtime.handleUpdateForTesting(secondaryUpdate, generation: gen)
        XCTAssertNotNil(committedStep)
        XCTAssertEqual(committedStep?.commitSide, .secondary)
        XCTAssertEqual(committedStep?.commitText, "this is a sentence about technology")
    }

    func testStaleGraceTimerAfterResetDoesNotCommit() {
        guard #available(iOS 26.0, macOS 26.0, *) else { return }

        let runtime = DualLaneCaptionRuntime(primaryLanguageID: "zh-Hant", secondaryLanguageID: "en")
        var commitCount = 0

        runtime.onStep = { step, _ in
            if step.commitText != nil {
                commitCount += 1
            }
        }

        let gen = runtime.currentGenerationForTesting()
        let primaryUpdate = ConversationLane.Update(
            side: .primary,
            text: "獨自講完",
            confidence: 0.88,
            isFinal: true,
            startSeconds: 0.0,
            endSeconds: 0.6,
            spans: []
        )
        runtime.handleUpdateForTesting(primaryUpdate, generation: gen)
        XCTAssertEqual(commitCount, 0)

        // Session restarts/finishes before timer fires:
        runtime.finish()

        // Firing the now-stale grace timer must not produce a commit:
        runtime.fireGraceTimerForTesting()
        XCTAssertEqual(commitCount, 0)
    }

    func testSilentCounterpartEventualGraceCommit() {
        guard #available(iOS 26.0, macOS 26.0, *) else { return }

        let runtime = DualLaneCaptionRuntime(primaryLanguageID: "zh-Hant", secondaryLanguageID: "en")
        var committedStep: DualLaneStep?

        runtime.onStep = { step, _ in
            if step.commitText != nil {
                committedStep = step
            }
        }

        let gen = runtime.currentGenerationForTesting()
        let primaryUpdate = ConversationLane.Update(
            side: .primary,
            text: "獨自講完",
            confidence: 0.88,
            isFinal: true,
            startSeconds: 0.0,
            endSeconds: 0.6,
            spans: []
        )
        runtime.handleUpdateForTesting(primaryUpdate, generation: gen)
        XCTAssertNil(committedStep)

        // Grace timer fires without counterpart:
        runtime.fireGraceTimerForTesting()
        XCTAssertNotNil(committedStep)
        XCTAssertEqual(committedStep?.commitSide, .primary)
        XCTAssertEqual(committedStep?.commitText, "獨自講完")
    }

    func testRepeatedPendingUpdatesDoNotMoveGraceDeadline() {
        guard #available(iOS 26.0, macOS 26.0, *) else { return }

        let runtime = DualLaneCaptionRuntime(primaryLanguageID: "zh-Hant", secondaryLanguageID: "en")
        let gen = runtime.currentGenerationForTesting()
        let primaryUpdate = ConversationLane.Update(
            side: .primary,
            text: "獨自講完",
            confidence: 0.88,
            isFinal: true,
            startSeconds: 0.0,
            endSeconds: 0.6,
            spans: []
        )
        runtime.handleUpdateForTesting(primaryUpdate, generation: gen)
        XCTAssertTrue(runtime.isGraceTimerScheduledForTesting())
        XCTAssertEqual(runtime.graceTimerScheduleCountForTesting(), 1)

        // Additional pending updates must not reschedule or move the timer deadline:
        let secondaryVolatile = ConversationLane.Update(
            side: .secondary,
            text: "unaligned noise",
            confidence: 0.20,
            isFinal: false,
            startSeconds: 1.5,
            endSeconds: 2.0,
            spans: []
        )
        runtime.handleUpdateForTesting(secondaryVolatile, generation: gen)
        XCTAssertTrue(runtime.isGraceTimerScheduledForTesting())
        XCTAssertEqual(runtime.graceTimerScheduleCountForTesting(), 1)
    }

    func testEnglishPrefixThenHanNeverEmitsReverseDraft() {
        var pairing = DualLanePairing()
        // Observation 1: English prefix "Hello" emitted as draft in primary lane
        let step1 = pairing.ingest(
            DualLaneObservation(side: .primary, text: "Hello", confidence: 0.8, isFinal: false, startSeconds: 0.0, endSeconds: 0.3)
        )
        // Draft must be on primary side (normal zh->en):
        XCTAssertEqual(step1.draftSide, .primary)
        XCTAssertEqual(step1.draftText, "Hello")

        // Observation 2: Subsequent Han characters arrive "Hello 大家好"
        let step2 = pairing.ingest(
            DualLaneObservation(side: .primary, text: "Hello 大家好", confidence: 0.85, isFinal: false, startSeconds: 0.0, endSeconds: 0.6)
        )
        XCTAssertEqual(step2.draftSide, .primary)
        XCTAssertEqual(step2.draftText, "Hello 大家好")

        // Final commit remains on primary side:
        _ = pairing.ingest(
            DualLaneObservation(side: .secondary, text: "hello everyone", confidence: 0.80, isFinal: true, startSeconds: 0.0, endSeconds: 0.6)
        )
        let finalStep = pairing.ingest(
            DualLaneObservation(side: .primary, text: "Hello 大家好", confidence: 0.85, isFinal: true, startSeconds: 0.0, endSeconds: 0.6)
        )
        XCTAssertEqual(finalStep.commitSide, .primary)
        XCTAssertEqual(finalStep.commitText, "Hello 大家好")
    }

    func testUnalignedAudioDoesNotPrematurelyCommit() {
        var pairing = DualLanePairing()
        _ = pairing.ingest(DualLaneObservation(side: .primary, text: "大家好", confidence: 0.9, isFinal: true, startSeconds: 0, endSeconds: 0.5))
        _ = pairing.ingest(DualLaneObservation(side: .secondary, text: "Hello", confidence: 0.4, isFinal: true, startSeconds: 1.0, endSeconds: 1.5))
        XCTAssertNil(pairing.finalizedFloorReadyToCommit())
    }

    func testDeterministicStaleUpdateAndStaleFailureAfterRestart() {
        guard #available(iOS 26.0, macOS 26.0, *) else { return }

        let runtime = DualLaneCaptionRuntime(primaryLanguageID: "zh-Hant", secondaryLanguageID: "en")
        var stepCount = 0
        var failureCount = 0

        runtime.onStep = { _, _ in
            stepCount += 1
        }
        runtime.onFailure = { _ in
            failureCount += 1
        }

        let gen0 = runtime.currentGenerationForTesting()
        runtime.finish()
        let gen1 = runtime.currentGenerationForTesting()
        XCTAssertNotEqual(gen0, gen1)

        let update = ConversationLane.Update(
            side: .primary,
            text: "測試",
            confidence: 0.9,
            isFinal: false,
            startSeconds: 0,
            endSeconds: 0.5,
            spans: []
        )
        struct TestError: Error {}

        // Stale update and failure from gen0 must be silently ignored.
        runtime.handleUpdateForTesting(update, generation: gen0)
        runtime.handleFailureForTesting(TestError(), side: .secondary, generation: gen0)
        XCTAssertEqual(stepCount, 0)
        XCTAssertEqual(failureCount, 0)

        // Active update and failure from gen1 must be processed.
        runtime.handleUpdateForTesting(update, generation: gen1)
        XCTAssertEqual(stepCount, 1)
        runtime.handleFailureForTesting(TestError(), side: .secondary, generation: gen1)
        XCTAssertEqual(failureCount, 1)

        // After restart (finish), gen1 events become stale.
        runtime.finish()
        let gen2 = runtime.currentGenerationForTesting()
        XCTAssertNotEqual(gen1, gen2)

        runtime.handleUpdateForTesting(update, generation: gen1)
        runtime.handleFailureForTesting(TestError(), side: .secondary, generation: gen1)
        XCTAssertEqual(stepCount, 1)
        XCTAssertEqual(failureCount, 1)
    }

    func testTwoRuntimeInstancesHaveIsolatedQueueIdentity() {
        guard #available(iOS 26.0, macOS 26.0, *) else { return }

        let runtimeA = DualLaneCaptionRuntime(primaryLanguageID: "zh-Hant", secondaryLanguageID: "en")
        let runtimeB = DualLaneCaptionRuntime(primaryLanguageID: "zh-Hant", secondaryLanguageID: "en")

        let genB0 = runtimeB.currentGenerationForTesting()
        runtimeA.runOnQueueForTesting {
            runtimeB.finish()
        }
        let genB1 = runtimeB.currentGenerationForTesting()
        XCTAssertNotEqual(genB0, genB1)
    }

    private func observation(
        side: ConversationSide,
        text: String,
        confidence: Double? = nil,
        isFinal: Bool = false,
        end: Double
    ) -> DualLaneObservation {
        DualLaneObservation(
            side: side,
            text: text,
            confidence: confidence,
            isFinal: isFinal,
            startSeconds: max(0, end - 0.4),
            endSeconds: end
        )
    }
}
