import Combine
import XCTest
@testable import v2s

/// Commit ordering and translation reuse in `AppModel`'s caption pipeline:
///
/// 1. A committed sentence is painted no later than the frame in which its
///    successor draft appears, and the queue never paints a caption twice.
/// 2. Every published `overlayState` is coherent: the audience display folds
///    each one into the rows it keeps.
/// 3. A translation made for the same words (spacing, punctuation and case
///    aside) is kept; one made for the words a caption begins with is shown
///    dimmed and never persisted; one made for different words is dropped.
@MainActor
final class CaptionCommitPaintOrderTests: XCTestCase {

    private func makeModel() -> AppModel {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("caption-paint-order-\(UUID().uuidString).json")
        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: SourceCatalogService()
        )
        model.committedCaptionIdleArchiveDelayForTesting = .infinity
        model.setOverlayStateForTesting(
            OverlayPreviewState(translatedText: "", sourceText: "", sourceName: "")
        )
        return model
    }

    /// Translation that never lands on its own; tests complete it explicitly.
    private func installPendingTranslation(on model: AppModel) {
        model.installTranslationForTesting { _, _, _ in
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return ""
        }
    }

    private func draft(_ id: UUID, _ text: String) -> DraftSegment {
        DraftSegment(
            segmentId: id,
            sourceText: text,
            stablePrefixLength: 0,
            mutableTailText: text,
            avgConfidence: 0.9,
            startMs: 0,
            lastUpdateMs: 0,
            silenceMs: 0,
            stabilityScore: 0.5,
            boundaryScore: 0.5,
            chunkScore: 0.5,
            vadProbability: 0.2,
            words: [],
            heardLanguageID: "en",
            audioHypothesisStartMs: 1_234
        )
    }

    private func sentence(
        _ text: String,
        promotionID: UUID,
        replacesID: UUID? = nil,
        heardLanguageID: String = "en"
    ) -> RecognizedSentence {
        RecognizedSentence(
            text: text,
            promotionSegmentID: promotionID,
            replacesPromotionSegmentID: replacesID,
            heardLanguageID: heardLanguageID
        )
    }

    private func setDraftTranslation(
        _ translation: String,
        madeFor sourceText: String,
        promotionID: UUID,
        on model: AppModel
    ) throws {
        var state = try XCTUnwrap(model.overlayStateForTesting)
        state.setDraftTranslation(translation, sourceText: sourceText, promotionID: promotionID)
        model.setOverlayStateForTesting(state)
    }

    private func liveRows(_ state: OverlayPreviewState?) -> [OverlayLiveCaptionPresentation.Caption] {
        guard let presentation = state?.liveCaptionPresentation else { return [] }
        return [presentation.precedingCommittedCaption, presentation.currentCaption].compactMap { $0 }
    }

    // MARK: - Paint order

    /// The frame that installs a successor draft must already contain the
    /// committed caption.
    func testCommittedCaptionIsPaintedBeforeSuccessorDraftAppears() {
        let model = makeModel()
        let promotionA = UUID()
        let promotionB = UUID()

        model.handlePartialDraftForTesting(draft(promotionA, "Good morning"), sourceLanguageID: "en", targetLanguageID: "en")
        model.enqueueRecognizedSentenceForTesting(
            sentence("Good morning, everyone.", promotionID: promotionA),
            sourceLanguageID: "en",
            targetLanguageID: "en"
        )
        // The successor draft arrives in the same run-loop batch as the
        // commit, before the display task can paint.
        model.handlePartialDraftForTesting(draft(promotionB, "Thank you for"), sourceLanguageID: "en", targetLanguageID: "en")

        let state = model.overlayStateForTesting
        XCTAssertEqual(
            state?.sourceText,
            "Good morning, everyone.",
            "committed caption must be on screen in the same frame as its successor draft"
        )
        XCTAssertEqual(state?.draftSourceText, "Thank you for")
    }

    /// Every state a subscriber sees is one a viewer may: the committed
    /// sentence never drops out, and the successor draft, once shown, is always
    /// shown under its own identity.
    func testOverlayPublishesOnlyCoherentStatesAcrossCommitAndSuccessorDraft() async throws {
        let model = makeModel()
        let promotionA = UUID()
        let promotionB = UUID()
        var published: [[OverlayLiveCaptionPresentation.Caption]] = []
        let subscription = model.$overlayState.sink { published.append(self.liveRows($0)) }
        defer { subscription.cancel() }

        model.handlePartialDraftForTesting(draft(promotionA, "Good morning"), sourceLanguageID: "en", targetLanguageID: "en")
        model.enqueueRecognizedSentenceForTesting(
            sentence("Good morning, everyone.", promotionID: promotionA),
            sourceLanguageID: "en",
            targetLanguageID: "en"
        )
        model.handlePartialDraftForTesting(draft(promotionB, "Thank you for"), sourceLanguageID: "en", targetLanguageID: "en")
        await model.runCaptionQueueTurnForTesting()

        let firstA = try XCTUnwrap(published.firstIndex { $0.contains { $0.sourceText.hasPrefix("Good morning") } })
        let firstB = try XCTUnwrap(published.firstIndex { $0.contains { $0.sourceText == "Thank you for" } })
        for (index, rows) in published.enumerated() {
            let texts = rows.map(\.sourceText)
            if index >= firstA {
                XCTAssertTrue(
                    rows.contains { $0.sourceText.hasPrefix("Good morning") },
                    "published state #\(index) dropped the committed sentence: \(texts)"
                )
            }
            if index >= firstB {
                XCTAssertTrue(
                    rows.contains { $0.sourceText == "Thank you for" },
                    "published state #\(index) dropped the successor draft: \(texts)"
                )
            }
            for row in rows where row.sourceText == "Thank you for" {
                XCTAssertEqual(row.id, .promotion(promotionB), "published state #\(index) shows the draft under another identity")
            }
        }
        XCTAssertEqual(liveRows(model.overlayStateForTesting).map(\.sourceText), ["Good morning, everyone.", "Thank you for"])
    }

    /// A draft that belongs to a different utterance than the commit being
    /// painted must survive the paint.
    func testCommitPaintKeepsIndependentDraft() async {
        let model = makeModel()
        let promotionA = UUID()
        let promotionB = UUID()

        // Draft B is already on screen when the (older) commit A paints.
        model.handlePartialDraftForTesting(draft(promotionB, "Thank you for"), sourceLanguageID: "en", targetLanguageID: "en")
        model.enqueueRecognizedSentenceForTesting(
            sentence("Good morning, everyone.", promotionID: promotionA),
            sourceLanguageID: "en",
            targetLanguageID: "en"
        )
        await model.runCaptionQueueTurnForTesting()

        XCTAssertEqual(model.overlayStateForTesting?.sourceText, "Good morning, everyone.")
        XCTAssertEqual(
            model.overlayStateForTesting?.draftSourceText,
            "Thank you for",
            "an independent draft must not be cleared by another utterance's commit paint"
        )
    }

    /// The queue painted A and waits on its translation; a successor draft
    /// paints B over it. A revision of A then updates A's archived row, and the
    /// queue must never paint A again over the newer B.
    func testQueueNeverRepaintsCaptionReplacedAheadOfItsTurn() async throws {
        let model = makeModel()
        installPendingTranslation(on: model)
        let promotionA = UUID()

        model.enqueueRecognizedSentenceForTesting(sentence("第一句。", promotionID: promotionA, heardLanguageID: "zh-Hant"))
        await model.runCaptionQueueTurnForTesting()
        let captionA = try XCTUnwrap(model.transcriptEntriesForTesting.first?.id)

        model.enqueueRecognizedSentenceForTesting(sentence("第二句。", promotionID: UUID(), heardLanguageID: "zh-Hant"))
        model.handlePartialDraftForTesting(draft(UUID(), "第三"))
        model.enqueueRecognizedSentenceForTesting(
            sentence("第一句話。", promotionID: UUID(), replacesID: promotionA, heardLanguageID: "zh-Hant")
        )
        let generation = try XCTUnwrap(model.currentTranslationGenerationForTesting(captionID: captionA))
        model.completeCaptionTranslationForTesting(captionID: captionA, generation: generation, translatedText: "T:第一句話。")
        await model.runCaptionQueueTurnForTesting()

        let history = model.overlayHistoryForTesting
        XCTAssertEqual(model.overlayStateForTesting?.sourceText, "第二句。", "the newer caption must stay on screen")
        XCTAssertEqual(history.map(\.id), [captionA], "A must be archived exactly once")
        XCTAssertEqual(history.map(\.sourceText), ["第一句話。"])
        XCTAssertEqual(history.map(\.translatedText), ["T:第一句話。"])
    }

    /// The queue overflow may only drop captions that were never painted: a
    /// painted one is already on screen or in history.
    func testOverflowKeepsCaptionsAlreadyOnScreen() async throws {
        let model = makeModel()
        installPendingTranslation(on: model)
        func commit(_ text: String) {
            model.enqueueRecognizedSentenceForTesting(sentence(text, promotionID: UUID(), heardLanguageID: "zh-Hant"))
        }

        commit("甲。")
        await model.runCaptionQueueTurnForTesting()
        commit("乙。")
        model.handlePartialDraftForTesting(draft(UUID(), "丙"))
        commit("丙。")
        commit("丁。")
        commit("戊。")
        model.handlePartialDraftForTesting(draft(UUID(), "己"))

        let history = model.overlayHistoryForTesting
        XCTAssertEqual(history.map(\.sourceText), ["甲。", "乙。", "丁。"], "only the unpainted 丙 may be dropped")
        XCTAssertEqual(Set(history.map(\.id)).count, history.count, "no caption may be archived twice")
        XCTAssertEqual(model.overlayStateForTesting?.sourceText, "戊。")
    }

    /// With "Live draft captions" off, a session's state hides drafts.
    func testLiveDraftCaptionsSettingAppliesToTheLiveSession() async {
        let model = makeModel()
        model.liveDraftCaptions = false
        // A session starts from a fresh state, which shows drafts by default.
        model.setOverlayStateForTesting(OverlayPreviewState(translatedText: "", sourceText: "", sourceName: ""))

        model.enqueueRecognizedSentenceForTesting(
            sentence("Good morning.", promotionID: UUID()),
            sourceLanguageID: "en",
            targetLanguageID: "en"
        )
        await model.runCaptionQueueTurnForTesting()
        model.handlePartialDraftForTesting(draft(UUID(), "Thank you"), sourceLanguageID: "en", targetLanguageID: "en")

        XCTAssertEqual(liveRows(model.overlayStateForTesting).map(\.sourceText), ["Good morning."])
    }

    // MARK: - Translation reuse

    /// A same-utterance commit (revision under a new promotion ID, identical
    /// source) keeps the translation already on screen.
    func testSameUtteranceCommitKeepsDisplayedTranslation() async {
        let model = makeModel()
        model.installTranslationForTesting { text, _, _ in "T:" + text }

        let promotionA = UUID()
        model.enqueueRecognizedSentenceForTesting(
            sentence("大家早安，謝謝各位。", promotionID: promotionA, heardLanguageID: "zh-Hant"),
            sourceLanguageID: "zh-Hant",
            targetLanguageID: "en"
        )
        await model.runCaptionQueueTurnForTesting()
        XCTAssertEqual(model.overlayStateForTesting?.translatedText, "T:大家早安，謝謝各位。")

        model.enqueueRecognizedSentenceForTesting(
            sentence("大家早安，謝謝各位。", promotionID: UUID(), replacesID: promotionA, heardLanguageID: "zh-Hant"),
            sourceLanguageID: "zh-Hant",
            targetLanguageID: "en"
        )

        XCTAssertEqual(
            model.overlayStateForTesting?.translatedText,
            "T:大家早安，謝謝各位。",
            "a same-utterance commit must not blank the translated lane"
        )
    }

    /// A commit whose source differs from the draft's only by punctuation is
    /// the same utterance: the draft translation is promoted.
    func testPunctuationOnlyCommitPromotesDraftTranslation() async throws {
        let model = makeModel()
        model.installTranslationForTesting { text, _, _ in "T:" + text }

        let promotionA = UUID()
        model.handlePartialDraftForTesting(draft(promotionA, "大家早安謝謝各位"))
        try setDraftTranslation("T:大家早安謝謝各位", madeFor: "大家早安謝謝各位", promotionID: promotionA, on: model)

        model.enqueueRecognizedSentenceForTesting(
            sentence("大家早安，謝謝各位。", promotionID: promotionA, heardLanguageID: "zh-Hant")
        )
        model.handlePartialDraftForTesting(draft(UUID(), "我們"))

        let state = model.overlayStateForTesting
        XCTAssertEqual(state?.sourceText, "大家早安，謝謝各位。")
        XCTAssertEqual(
            state?.translatedText,
            "T:大家早安謝謝各位",
            "the draft translation belongs to the same utterance and must be promoted"
        )
    }

    /// A revision that changes the words blanks the lane: the old translation
    /// must not sit beside a revised source.
    func testWordChangeRevisionBlanksStaleTranslation() async {
        let model = makeModel()
        model.installTranslationForTesting { text, _, _ in "T:" + text }

        let promotionA = UUID()
        model.enqueueRecognizedSentenceForTesting(sentence("大家早安。", promotionID: promotionA, heardLanguageID: "zh-Hant"))
        await model.runCaptionQueueTurnForTesting()
        XCTAssertEqual(model.overlayStateForTesting?.translatedText, "T:大家早安。")

        model.enqueueRecognizedSentenceForTesting(
            sentence("各位晚安。", promotionID: UUID(), replacesID: promotionA, heardLanguageID: "zh-Hant")
        )

        XCTAssertEqual(
            liveRows(model.overlayStateForTesting).map(\.translatedText),
            [""],
            "a translation of different words is stale and must not be carried over"
        )
    }

    /// A commit that extends the words its draft translation was made for
    /// shows that translation dimmed on the committed row, under the committed
    /// row's own identity, until its own translation lands. Neither the lane
    /// nor the transcript ever records it, and a new utterance's draft does not
    /// take it away.
    func testPrefixExtensionCommitShowsDimTranslationUntilItsOwnLands() async throws {
        let model = makeModel()
        installPendingTranslation(on: model)

        let promotionA = UUID()
        model.handlePartialDraftForTesting(draft(promotionA, "大家早安"))
        try setDraftTranslation("T:大家早安", madeFor: "大家早安", promotionID: promotionA, on: model)
        model.enqueueRecognizedSentenceForTesting(
            sentence("大家早安，謝謝各位。", promotionID: promotionA, heardLanguageID: "zh-Hant")
        )
        await model.runCaptionQueueTurnForTesting()
        model.handlePartialDraftForTesting(draft(UUID(), "我們"))

        let state = try XCTUnwrap(model.overlayStateForTesting)
        let committed = try XCTUnwrap(state.liveCaptionPresentation.precedingCommittedCaption)
        XCTAssertEqual(committed.id, .promotion(promotionA))
        XCTAssertEqual(committed.sourceText, "大家早安，謝謝各位。")
        XCTAssertEqual(committed.translatedText, "T:大家早安")
        XCTAssertEqual(committed.translatedStablePrefixLength, 0, "a translation of fewer words renders provisional")
        XCTAssertEqual(state.translatedText, "", "the committed lane must not record it")
        let entry = try XCTUnwrap(model.transcriptEntriesForTesting.last)
        XCTAssertEqual(entry.translatedText, "", "the transcript waits for the real translation")

        let generation = try XCTUnwrap(model.currentTranslationGenerationForTesting(captionID: entry.id))
        model.completeCaptionTranslationForTesting(
            captionID: entry.id,
            generation: generation,
            translatedText: "T:大家早安，謝謝各位。"
        )
        let settled = try XCTUnwrap(model.overlayStateForTesting?.liveCaptionPresentation.precedingCommittedCaption)
        XCTAssertEqual(settled.translatedText, "T:大家早安，謝謝各位。")
        XCTAssertEqual(settled.translatedStablePrefixLength, settled.translatedText.count)
    }

    /// The draft translation adopted by a new producer ID stays bound to the
    /// words it translates, so a commit of more words cannot persist it.
    func testAdoptedDraftTranslationStaysBoundToItsOwnWords() async throws {
        let model = makeModel()
        installPendingTranslation(on: model)

        let firstID = UUID()
        let secondID = UUID()
        model.handlePartialDraftForTesting(draft(firstID, "大家早安"))
        try setDraftTranslation("T:大家早安", madeFor: "大家早安", promotionID: firstID, on: model)
        model.handlePartialDraftForTesting(draft(secondID, "大家早安，謝謝各位"))
        XCTAssertEqual(model.overlayStateForTesting?.draftTranslationPromotionID, secondID)
        XCTAssertEqual(model.overlayStateForTesting?.draftTranslationSourceText, "大家早安")

        model.enqueueRecognizedSentenceForTesting(
            sentence("大家早安，謝謝各位。", promotionID: secondID, heardLanguageID: "zh-Hant")
        )
        await model.runCaptionQueueTurnForTesting()

        let state = try XCTUnwrap(model.overlayStateForTesting)
        XCTAssertEqual(state.translatedText, "", "a translation of fewer words must not be persisted")
        XCTAssertEqual(model.transcriptEntriesForTesting.last?.translatedText, "")
        let committed = try XCTUnwrap(state.liveCaptionPresentation.currentCaption)
        XCTAssertEqual(committed.translatedText, "T:大家早安")
        XCTAssertEqual(committed.translatedStablePrefixLength, 0)
    }

    /// The recognizer re-emits the same utterance under a new segment ID with
    /// punctuation drift: the draft translation is adopted, not cleared.
    func testSameUtteranceDraftRebindsTranslationAcrossNewSegmentID() throws {
        let model = makeModel()

        let firstID = UUID()
        model.handlePartialDraftForTesting(draft(firstID, "。任何東西都不應該閃爍。"))
        try setDraftTranslation("仼佖杲覀郾与懊詳閄爎。", madeFor: "。任何東西都不應該閃爍。", promotionID: firstID, on: model)

        let secondID = UUID()
        model.handlePartialDraftForTesting(draft(secondID, "任何東西都不應該閃爍。"))

        let state = model.overlayStateForTesting
        XCTAssertEqual(state?.draftTranslatedText, "仼佖杲覀郾与懊詳閄爎。")
        XCTAssertEqual(state?.draftTranslationPromotionID, secondID)
        XCTAssertEqual(state?.draftTranslationSourceText, "。任何東西都不應該閃爍。")
    }

    /// A draft revision that changes the words drops the old draft translation.
    func testWordChangeDraftClearsDraftTranslation() throws {
        let model = makeModel()

        let firstID = UUID()
        model.handlePartialDraftForTesting(draft(firstID, "大家早安"))
        try setDraftTranslation("T:大家早安", madeFor: "大家早安", promotionID: firstID, on: model)

        model.handlePartialDraftForTesting(draft(UUID(), "各位晚安"))

        XCTAssertNil(model.overlayStateForTesting?.draftTranslatedText)
    }

    /// A draft that grows by words keeps its previous translation, dimmed.
    func testWordGrowthDraftKeepsTranslationDim() throws {
        let model = makeModel()

        let firstID = UUID()
        model.handlePartialDraftForTesting(draft(firstID, "大家早安"))
        try setDraftTranslation("T:大家早安", madeFor: "大家早安", promotionID: firstID, on: model)

        model.handlePartialDraftForTesting(draft(firstID, "大家早安，謝謝各位"))

        let state = model.overlayStateForTesting
        XCTAssertEqual(state?.draftTranslatedText, "T:大家早安")
        XCTAssertEqual(state?.draftTranslatedStablePrefixLength, 0, "a prefix translation renders dim until the new one lands")
    }
}
