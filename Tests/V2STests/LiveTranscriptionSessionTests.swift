import XCTest
@testable import v2s

final class LiveTranscriptionSessionTests: XCTestCase {
    func testLegacyRecognitionErrorDispositionIgnoresCancellationErrors() {
        XCTAssertEqual(disposition(code: 216), .ignore)
        XCTAssertEqual(disposition(code: 301), .ignore)
    }

    func testLegacyRecognitionErrorDispositionRestartsAfterSilence() {
        XCTAssertEqual(disposition(code: 1110), .restartImmediately)
    }

    func testLegacyRecognitionErrorDispositionStopsAfterServerQuotaError() {
        XCTAssertEqual(
            disposition(
                code: 203,
                message: "Quota limit reached for resource: speech_api, actor_type: user"
            ),
            .stopAndSurface
        )
    }

    // Code 203 also covers transient faults that a restart clears, so the code alone
    // must not end the session.
    func testLegacyRecognitionErrorDispositionRetriesNonQuotaCode203() {
        XCTAssertEqual(disposition(code: 203, message: "Retry"), .retryWithBackoff)
        XCTAssertEqual(disposition(code: 203, message: "Corrupt"), .retryWithBackoff)
    }

    func testLegacyRecognitionErrorDispositionStopsOnQuotaRegardlessOfCode() {
        XCTAssertEqual(
            disposition(code: 1700, message: "Quota limit reached for resource: speech_api"),
            .stopAndSurface
        )
    }

    func testLegacyRecognitionErrorDispositionBacksOffOtherErrors() {
        XCTAssertEqual(disposition(code: 999), .retryWithBackoff)
        XCTAssertEqual(
            LiveTranscriptionSession.legacyRecognitionErrorDisposition(
                domain: NSURLErrorDomain,
                code: NSURLErrorNotConnectedToInternet
            ),
            .retryWithBackoff
        )
    }

    // A cancellation code from another domain is a real failure, not our own teardown.
    func testLegacyRecognitionErrorDispositionDoesNotIgnoreForeignDomains() {
        XCTAssertEqual(
            LiveTranscriptionSession.legacyRecognitionErrorDisposition(
                domain: NSURLErrorDomain,
                code: 216
            ),
            .retryWithBackoff
        )
    }

    func testRecognizedSentenceRetainsImmutableHeardLanguageID() {
        let sentence = RecognizedSentence(
            text: "Hello world",
            promotionSegmentID: UUID(),
            heardLanguageID: "en"
        )
        XCTAssertEqual(sentence.text, "Hello world")
        XCTAssertEqual(sentence.heardLanguageID, "en")
        XCTAssertNotNil(sentence.promotionSegmentID)
    }

    func testDualLaneDraftPaneInversionSemanticContract() {
        let enDraft = "Hello everyone"
        let isReversed = CaptionLanguagePolicy.shouldReverse(
            configuredSourceLanguageID: "zh-Hant",
            configuredTargetLanguageID: "en",
            heardLanguageID: "en",
            heardText: enDraft,
            evidence: nil
        )
        // With nil evidence, drafts stay false (fail closed):
        XCTAssertFalse(isReversed)

        var state = OverlayPreviewState(
            translatedText: "",
            sourceText: "",
            sourceName: "Mic"
        )
        state.draftTranslatedText = nil
        state.draftSourceText = "大家好"
        XCTAssertTrue(state.hasActiveDraftLayer)
        XCTAssertEqual(state.draftSourceText, "大家好")
        XCTAssertNil(state.draftTranslatedText)
    }

    func testDualLaneSilenceCommitDoesNotDuplicateOrDeadlock() {
        var pairing = DualLanePairing()
        let obs1 = DualLaneObservation(
            side: .primary,
            text: "第一句",
            confidence: 0.9,
            isFinal: false,
            startSeconds: 0.0,
            endSeconds: 0.8
        )
        let secObs = DualLaneObservation(
            side: .secondary,
            text: "First sentence",
            confidence: 0.3,
            isFinal: false,
            startSeconds: 0.0,
            endSeconds: 0.8
        )
        let step1 = pairing.ingest(obs1)
        XCTAssertEqual(step1.draftText, "第一句")
        XCTAssertNil(step1.commitText)

        let step2 = pairing.ingest(secObs)
        XCTAssertNil(step2.commitText)

        let obsFinal = DualLaneObservation(
            side: .primary,
            text: "第一句",
            confidence: 0.92,
            isFinal: true,
            startSeconds: 0.0,
            endSeconds: 0.8
        )
        let secFinal = DualLaneObservation(
            side: .secondary,
            text: "First sentence",
            confidence: 0.3,
            isFinal: true,
            startSeconds: 0.0,
            endSeconds: 0.8
        )
        let step3 = pairing.ingest(secFinal)
        XCTAssertNil(step3.commitText)

        let stepFinal = pairing.ingest(obsFinal)
        XCTAssertEqual(stepFinal.commitText, "第一句")
        XCTAssertEqual(stepFinal.commitSide, .primary)

        // Following commit, no duplicate commit occurs on subsequent call:
        XCTAssertNil(pairing.finalizedFloorReadyToCommit())
    }

    func testLateTranslationDirectionFlipsWithHeardLanguage() {
        let evidence = DualLaneEvidence(
            arbiterFloor: .secondary,
            selectedSide: .secondary,
            resolution: .pureEnglish,
            winnerConfidence: 0.95,
            competingConfidence: nil,
            primaryScript: .entirelyLatin,
            secondaryScript: .entirelyLatin,
            isMixedSpeechSuspected: false
        )
        let zhTarget = CaptionLanguagePolicy.translationTarget(
            heardLanguageID: "zh-Hant",
            configuredSourceLanguageID: "zh-Hant",
            configuredTargetLanguageID: "en"
        )
        XCTAssertEqual(zhTarget, "en")

        let enTarget = CaptionLanguagePolicy.translationTarget(
            heardLanguageID: "en",
            configuredSourceLanguageID: "zh-Hant",
            configuredTargetLanguageID: "en",
            heardText: "Good morning",
            evidence: evidence
        )
        XCTAssertEqual(enTarget, "zh-Hant")

        let latePanes = CaptionLanguagePolicy.overlayPanes(
            heardText: "Good morning",
            translatedText: "早安",
            heardLanguageID: "en",
            configuredSourceLanguageID: "zh-Hant",
            configuredTargetLanguageID: "en",
            evidence: evidence
        )
        XCTAssertEqual(latePanes.sourceText, "早安")
        XCTAssertEqual(latePanes.translatedText, "Good morning")
    }

    func testDualLaneDegradesGracefullyWhenSecondaryFails() {
        // Case 1: Failure occurs before survivor final arrives.
        var pairing = DualLanePairing()
        pairing.markLaneUnavailable(.secondary)

        let primaryObs = DualLaneObservation(
            side: .primary,
            text: "正常中文",
            confidence: 0.88,
            isFinal: true,
            startSeconds: 0.0,
            endSeconds: 0.6
        )
        let step = pairing.ingest(primaryObs)
        XCTAssertEqual(step.commitSide, .primary)
        XCTAssertEqual(step.commitText, "正常中文")
        XCTAssertNil(pairing.finalizedFloorReadyToCommit())

        // Case 2: Survivor final is already pending when secondary fails.
        var pairing2 = DualLanePairing()
        let pendingPrimaryStep = pairing2.ingest(primaryObs)
        XCTAssertNil(pendingPrimaryStep.commitText)

        let flushStep = pairing2.markLaneUnavailable(.secondary)
        XCTAssertNotNil(flushStep)
        XCTAssertEqual(flushStep?.commitSide, .primary)
        XCTAssertEqual(flushStep?.commitText, "正常中文")
        XCTAssertNil(pairing2.finalizedFloorReadyToCommit())
    }

    func testDualLaneDegradesGracefullyWhenPrimaryFails() {
        // Case 1: Primary failure before secondary final -> fail closed, no secondary commit.
        var pairing = DualLanePairing()
        let step1 = pairing.markLaneUnavailable(.primary)
        XCTAssertNil(step1)

        let secondaryObs = DualLaneObservation(
            side: .secondary,
            text: "English speech",
            confidence: 0.91,
            isFinal: true,
            startSeconds: 0.0,
            endSeconds: 0.6
        )
        let step2 = pairing.ingest(secondaryObs)
        XCTAssertNil(step2.commitText)
        XCTAssertNil(pairing.finalizedFloorReadyToCommit())

        // Case 2: Secondary final arrived first, then primary fails -> must not emit secondary commit.
        var pairing2 = DualLanePairing()
        let pendingSecStep = pairing2.ingest(secondaryObs)
        XCTAssertNil(pendingSecStep.commitText)

        let flushStep = pairing2.markLaneUnavailable(.primary)
        XCTAssertNil(flushStep)
        XCTAssertNil(pairing2.finalizedFloorReadyToCommit())
    }

    func testMixedUtteranceWhereSecondaryWinsConfidenceSelectsPrimaryLaneForNormalZhToEn() {
        var pairing = DualLanePairing()
        _ = pairing.ingest(
            DualLaneObservation(
                side: .primary,
                text: "我們使用 API 模型",
                confidence: 0.82,
                isFinal: false,
                startSeconds: 0.0,
                endSeconds: 0.6
            )
        )
        _ = pairing.ingest(
            DualLaneObservation(
                side: .secondary,
                text: "women shiyong API moxing",
                confidence: 0.95,
                isFinal: false,
                startSeconds: 0.0,
                endSeconds: 0.6
            )
        )
        _ = pairing.ingest(
            DualLaneObservation(
                side: .secondary,
                text: "women shiyong API moxing",
                confidence: 0.95,
                isFinal: true,
                startSeconds: 0.0,
                endSeconds: 0.6
            )
        )
        let finalStep = pairing.ingest(
            DualLaneObservation(
                side: .primary,
                text: "我們使用 API 模型",
                confidence: 0.82,
                isFinal: true,
                startSeconds: 0.0,
                endSeconds: 0.6
            )
        )
        // Primary text must win for mixed speech:
        XCTAssertEqual(finalStep.commitSide, .primary)
        XCTAssertEqual(finalStep.commitText, "我們使用 API 模型")
        XCTAssertEqual(finalStep.evidence?.isMixedSpeechSuspected, true)

        let target = CaptionLanguagePolicy.translationTarget(
            heardLanguageID: "zh-Hant",
            configuredSourceLanguageID: "zh-Hant",
            configuredTargetLanguageID: "en",
            heardText: finalStep.commitText ?? "",
            evidence: finalStep.evidence
        )
        XCTAssertEqual(target, "en")

        let panes = CaptionLanguagePolicy.overlayPanes(
            heardText: finalStep.commitText ?? "",
            translatedText: "We use the API model",
            heardLanguageID: "zh-Hant",
            configuredSourceLanguageID: "zh-Hant",
            configuredTargetLanguageID: "en",
            evidence: finalStep.evidence
        )
        XCTAssertEqual(panes.sourceText, "我們使用 API 模型")
        XCTAssertEqual(panes.translatedText, "We use the API model")
    }

    func testNoLosingLaneTranslationScheduled() {
        var pairing = DualLanePairing()
        _ = pairing.ingest(DualLaneObservation(side: .primary, text: "強勢主語言", confidence: 0.95, isFinal: false, startSeconds: 0.0, endSeconds: 0.5))
        _ = pairing.ingest(DualLaneObservation(side: .secondary, text: "weak", confidence: 0.20, isFinal: false, startSeconds: 0.0, endSeconds: 0.5))

        _ = pairing.ingest(DualLaneObservation(side: .secondary, text: "weak", confidence: 0.20, isFinal: true, startSeconds: 0.0, endSeconds: 0.5))
        let finalStepBoth = pairing.ingest(DualLaneObservation(side: .primary, text: "強勢主語言", confidence: 0.95, isFinal: true, startSeconds: 0.0, endSeconds: 0.5))
        XCTAssertEqual(finalStepBoth.floor, .primary)
        XCTAssertEqual(finalStepBoth.commitSide, .primary)
        XCTAssertEqual(finalStepBoth.commitText, "強勢主語言")
    }

    private func disposition(
        code: Int,
        message: String = ""
    ) -> LiveTranscriptionSession.LegacyRecognitionErrorDisposition {
        LiveTranscriptionSession.legacyRecognitionErrorDisposition(
            domain: "kAFAssistantErrorDomain",
            code: code,
            message: message
        )
    }
}
