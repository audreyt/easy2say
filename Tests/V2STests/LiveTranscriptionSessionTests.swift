import CoreMedia
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
        let id = UUID()
        let replacesID = UUID()
        let sentence = RecognizedSentence(
            text: "Hello world",
            promotionSegmentID: id,
            replacesPromotionSegmentID: replacesID,
            heardLanguageID: "en"
        )
        XCTAssertEqual(sentence.text, "Hello world")
        XCTAssertEqual(sentence.heardLanguageID, "en")
        XCTAssertEqual(sentence.promotionSegmentID, id)
        XCTAssertEqual(sentence.replacesPromotionSegmentID, replacesID)
    }

    @MainActor
    func testPartialSentenceEmissionThenFullRevisionPreservesFullTextAndReplacesID() {
        let session = LiveTranscriptionSession()
        let id1 = UUID()
        let id2 = UUID()

        // First sentence committed without sentence terminator (provisional partial)
        session.rememberCommittedSentenceForTesting("This is a provisional", promotionSegmentID: id1)

        // Completed sentence arrives as a prefix continuation
        let fullSentence = "This is a provisional sentence about technology."
        let prepared = session.prepareCommittedSentenceForEmissionForTesting(
            fullSentence,
            pendingPromotionID: id2
        )

        XCTAssertNotNil(prepared)
        XCTAssertEqual(prepared?.text, fullSentence)
        XCTAssertEqual(prepared?.promotionSegmentID, id2)
        XCTAssertEqual(prepared?.replacesPromotionSegmentID, id1)
    }

    @MainActor
    func testConsecutiveExtensionsChainToSameReplacedID() {
        let session = LiveTranscriptionSession()
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()

        session.rememberCommittedSentenceForTesting("Segment one", promotionSegmentID: id1)

        let step2 = session.prepareCommittedSentenceForEmissionForTesting(
            "Segment one segment two",
            pendingPromotionID: id2
        )
        XCTAssertNotNil(step2)
        XCTAssertEqual(step2?.text, "Segment one segment two")
        XCTAssertEqual(step2?.promotionSegmentID, id2)
        XCTAssertEqual(step2?.replacesPromotionSegmentID, id1)

        let step3 = session.prepareCommittedSentenceForEmissionForTesting(
            "Segment one segment two segment three.",
            pendingPromotionID: id3
        )
        XCTAssertNotNil(step3)
        XCTAssertEqual(step3?.text, "Segment one segment two segment three.")
        XCTAssertEqual(step3?.promotionSegmentID, id3)
        XCTAssertEqual(step3?.replacesPromotionSegmentID, id1)
    }

    @MainActor
    func testReplaySuppressionForAnyAcceptedIDInChain() {
        let session = LiveTranscriptionSession()
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()

        session.rememberCommittedSentenceForTesting("Segment one", promotionSegmentID: id1)
        _ = session.prepareCommittedSentenceForEmissionForTesting("Segment one segment two", pendingPromotionID: id2)
        _ = session.prepareCommittedSentenceForEmissionForTesting("Segment one segment two segment three.", pendingPromotionID: id3)

        // Replay of any ID already accepted in the chain must return nil
        XCTAssertNil(session.prepareCommittedSentenceForEmissionForTesting("Segment one", pendingPromotionID: id1))
        XCTAssertNil(session.prepareCommittedSentenceForEmissionForTesting("Segment one segment two", pendingPromotionID: id2))
        XCTAssertNil(session.prepareCommittedSentenceForEmissionForTesting("Segment one segment two segment three.", pendingPromotionID: id3))
    }

    @MainActor
    func testDistinctIDWithIdenticalTextEmitsAsNewUtterance() {
        let session = LiveTranscriptionSession()
        let id1 = UUID()
        let id2 = UUID()

        session.rememberCommittedSentenceForTesting("Thank you very much.", promotionSegmentID: id1)

        // Same text with a brand new distinct ID must emit as a new utterance (not replaced)
        let prepared = session.prepareCommittedSentenceForEmissionForTesting(
            "Thank you very much.",
            pendingPromotionID: id2
        )

        XCTAssertNotNil(prepared)
        XCTAssertEqual(prepared?.text, "Thank you very much.")
        XCTAssertEqual(prepared?.promotionSegmentID, id2)
        XCTAssertNil(prepared?.replacesPromotionSegmentID)
    }

    @MainActor
    func testLegacyNilIDDuplicateSuppression() {
        let session = LiveTranscriptionSession()
        session.rememberCommittedSentenceForTesting("Legacy text without ID", promotionSegmentID: nil)

        let duplicate = session.prepareCommittedSentenceForEmissionForTesting(
            "Legacy text without ID",
            pendingPromotionID: nil
        )
        XCTAssertNil(duplicate)
    }

    @MainActor
    func testTerminatedSentenceDoesNotTreatNextSentenceAsContinuation() {
        let session = LiveTranscriptionSession()
        let id1 = UUID()
        let id2 = UUID()

        session.rememberCommittedSentenceForTesting("First sentence completed.", promotionSegmentID: id1)

        let nextSentence = "Second sentence starts fresh."
        let prepared = session.prepareCommittedSentenceForEmissionForTesting(
            nextSentence,
            pendingPromotionID: id2
        )

        XCTAssertNotNil(prepared)
        XCTAssertEqual(prepared?.text, nextSentence)
        XCTAssertEqual(prepared?.promotionSegmentID, id2)
        XCTAssertNil(prepared?.replacesPromotionSegmentID)
    }

    @MainActor
    func testAppModelProvisionalCaptionReplacedByFullSentenceUpdatesVisibleRowInPlaceWithoutDuplicateHistory() async {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-appmodel-caption-lifecycle-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: SourceCatalogService()
        )

        let id1 = UUID()
        let provisionalSentence = RecognizedSentence(
            text: "This is a provisional",
            promotionSegmentID: id1,
            replacesPromotionSegmentID: nil,
            heardLanguageID: "en"
        )
        model.enqueueRecognizedSentenceForTesting(
            provisionalSentence,
            sourceLanguageID: "en",
            targetLanguageID: "en"
        )
        await model.runCaptionQueueTurnForTesting()

        XCTAssertEqual(model.displayedCaptionForTesting?.sourceText, "This is a provisional")
        XCTAssertEqual(model.overlayHistoryForTesting.count, 0)

        // Completed full sentence arrives replacing id1 while displayed
        let fullSentence = RecognizedSentence(
            text: "This is a provisional sentence about technology.",
            promotionSegmentID: id1,
            replacesPromotionSegmentID: id1,
            heardLanguageID: "en"
        )
        model.enqueueRecognizedSentenceForTesting(
            fullSentence,
            sourceLanguageID: "en",
            targetLanguageID: "en"
        )
        await model.runCaptionQueueTurnForTesting()

        // Same visible row updated in-place, zero duplicate history entries
        XCTAssertEqual(
            model.displayedCaptionForTesting?.sourceText,
            "This is a provisional sentence about technology."
        )
        XCTAssertEqual(model.overlayHistoryForTesting.count, 0)

        // Complete hold and move to next genuine sentence
        model.completeHeldCaptionForTesting()

        let id2 = UUID()
        let nextSentence = RecognizedSentence(
            text: "This is the next sentence.",
            promotionSegmentID: id2,
            replacesPromotionSegmentID: nil,
            heardLanguageID: "en"
        )
        model.enqueueRecognizedSentenceForTesting(
            nextSentence,
            sourceLanguageID: "en",
            targetLanguageID: "en"
        )
        await model.runCaptionQueueTurnForTesting()

        // Now history contains exactly 1 row (the finalized full first sentence), and visible row is the 2nd sentence
        XCTAssertEqual(model.displayedCaptionForTesting?.sourceText, "This is the next sentence.")
        XCTAssertEqual(model.overlayHistoryForTesting.count, 1)
        XCTAssertEqual(
            model.overlayHistoryForTesting.first?.sourceText,
            "This is a provisional sentence about technology."
        )
        XCTAssertEqual(model.transcriptEntriesForTesting.count, 2)
        XCTAssertEqual(
            model.transcriptEntriesForTesting.first?.sourceText,
            "This is a provisional sentence about technology."
        )
        XCTAssertEqual(
            model.transcriptEntriesForTesting.last?.sourceText,
            "This is the next sentence."
        )
    }

    @MainActor
    func testLTSProvisionalEndingWithPeriodReplacedByFullSentenceProducesOneRowInAppModel() async {
        let session = LiveTranscriptionSession()
        let id1 = UUID()
        let id2 = UUID()

        // Provisional silence commit ending with period
        session.rememberCommittedSentenceForTesting("We are going to.", isProvisionalSilence: true, promotionSegmentID: id1)

        // Full final sentence arrives
        let fullSentence = "We are going to build a new system."
        let prepared = session.prepareCommittedSentenceForEmissionForTesting(
            fullSentence,
            pendingPromotionID: id2,
            isProvisionalSilence: false
        )

        XCTAssertNotNil(prepared)
        XCTAssertEqual(prepared?.text, fullSentence)
        XCTAssertEqual(prepared?.promotionSegmentID, id2)
        XCTAssertEqual(prepared?.replacesPromotionSegmentID, id1)

        // End-to-end with AppModel
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-appmodel-provisional-period-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }
        let model = AppModel(settingsStore: SettingsStore(fileURL: settingsURL), sourceCatalogService: SourceCatalogService())

        let s1 = RecognizedSentence(text: "We are going to.", promotionSegmentID: id1, replacesPromotionSegmentID: nil, heardLanguageID: "en")
        model.enqueueRecognizedSentenceForTesting(s1, sourceLanguageID: "en", targetLanguageID: "en")
        await model.runCaptionQueueTurnForTesting()

        let s2 = RecognizedSentence(text: prepared!.text, promotionSegmentID: prepared!.promotionSegmentID, replacesPromotionSegmentID: prepared!.replacesPromotionSegmentID, heardLanguageID: "en")
        model.enqueueRecognizedSentenceForTesting(s2, sourceLanguageID: "en", targetLanguageID: "en")
        await model.runCaptionQueueTurnForTesting()

        XCTAssertEqual(model.displayedCaptionForTesting?.sourceText, fullSentence)
        XCTAssertEqual(model.transcriptEntriesForTesting.count, 1)
        XCTAssertEqual(model.transcriptEntriesForTesting.first?.sourceText, fullSentence)
        XCTAssertEqual(model.overlayHistoryForTesting.count, 0)
    }

    @MainActor
    func testLTSProvisionalEndingWithFullWidthPeriodReplacedByFullChineseSentenceProducesOneRowInAppModel() async {
        let session = LiveTranscriptionSession()
        let id1 = UUID()
        let id2 = UUID()

        // Provisional Chinese sentence ending with full-width period
        session.rememberCommittedSentenceForTesting("我們今天要。", isProvisionalSilence: true, promotionSegmentID: id1)

        let fullSentence = "我們今天要出發前往台北發表演講。"
        let prepared = session.prepareCommittedSentenceForEmissionForTesting(
            fullSentence,
            pendingPromotionID: id2,
            isProvisionalSilence: false
        )

        XCTAssertNotNil(prepared)
        XCTAssertEqual(prepared?.text, fullSentence)
        XCTAssertEqual(prepared?.promotionSegmentID, id2)
        XCTAssertEqual(prepared?.replacesPromotionSegmentID, id1)

        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-appmodel-chinese-provisional-period-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }
        let model = AppModel(settingsStore: SettingsStore(fileURL: settingsURL), sourceCatalogService: SourceCatalogService())

        let s1 = RecognizedSentence(text: "我們今天要。", promotionSegmentID: id1, replacesPromotionSegmentID: nil, heardLanguageID: "zh-Hant")
        model.enqueueRecognizedSentenceForTesting(s1, sourceLanguageID: "zh-Hant", targetLanguageID: "en")
        await model.runCaptionQueueTurnForTesting()

        let s2 = RecognizedSentence(text: prepared!.text, promotionSegmentID: prepared!.promotionSegmentID, replacesPromotionSegmentID: prepared!.replacesPromotionSegmentID, heardLanguageID: "zh-Hant")
        model.enqueueRecognizedSentenceForTesting(s2, sourceLanguageID: "zh-Hant", targetLanguageID: "en")
        await model.runCaptionQueueTurnForTesting()

        XCTAssertEqual(model.displayedCaptionForTesting?.sourceText, fullSentence)
        XCTAssertEqual(model.transcriptEntriesForTesting.count, 1)
        XCTAssertEqual(model.transcriptEntriesForTesting.first?.sourceText, fullSentence)
        XCTAssertEqual(model.overlayHistoryForTesting.count, 0)
    }

    @MainActor
    func testLTSProvisionalPunctuationVariantExtensionProducesOneRowInAppModel() async {
        let session = LiveTranscriptionSession()
        let id1 = UUID()
        let id2 = UUID()

        // Provisional "A B"
        session.rememberCommittedSentenceForTesting("A B", isProvisionalSilence: true, promotionSegmentID: id1)

        // Punctuated and extended "A, B C"
        let fullSentence = "A, B C"
        let prepared = session.prepareCommittedSentenceForEmissionForTesting(
            fullSentence,
            pendingPromotionID: id2,
            isProvisionalSilence: false
        )

        XCTAssertNotNil(prepared)
        XCTAssertEqual(prepared?.text, fullSentence)
        XCTAssertEqual(prepared?.promotionSegmentID, id2)
        XCTAssertEqual(prepared?.replacesPromotionSegmentID, id1)

        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-appmodel-punc-variant-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }
        let model = AppModel(settingsStore: SettingsStore(fileURL: settingsURL), sourceCatalogService: SourceCatalogService())

        let s1 = RecognizedSentence(text: "A B", promotionSegmentID: id1, replacesPromotionSegmentID: nil, heardLanguageID: "en")
        model.enqueueRecognizedSentenceForTesting(s1, sourceLanguageID: "en", targetLanguageID: "en")
        await model.runCaptionQueueTurnForTesting()

        let s2 = RecognizedSentence(text: prepared!.text, promotionSegmentID: prepared!.promotionSegmentID, replacesPromotionSegmentID: prepared!.replacesPromotionSegmentID, heardLanguageID: "en")
        model.enqueueRecognizedSentenceForTesting(s2, sourceLanguageID: "en", targetLanguageID: "en")
        await model.runCaptionQueueTurnForTesting()

        XCTAssertEqual(model.displayedCaptionForTesting?.sourceText, fullSentence)
        XCTAssertEqual(model.transcriptEntriesForTesting.count, 1)
        XCTAssertEqual(model.transcriptEntriesForTesting.first?.sourceText, fullSentence)
        XCTAssertEqual(model.overlayHistoryForTesting.count, 0)
    }

    @MainActor
    func testLTSProvisionalModestASRRewriteProducesOneRowInAppModel() async {
        let session = LiveTranscriptionSession()
        let id1 = UUID()
        let id2 = UUID()

        // Provisional "there is a problem"
        session.rememberCommittedSentenceForTesting("there is a problem", isProvisionalSilence: true, promotionSegmentID: id1)

        // Modest rewrite "There's a problem with the server."
        let fullSentence = "There's a problem with the server."
        let prepared = session.prepareCommittedSentenceForEmissionForTesting(
            fullSentence,
            pendingPromotionID: id2,
            isProvisionalSilence: false
        )

        XCTAssertNotNil(prepared)
        XCTAssertEqual(prepared?.text, fullSentence)
        XCTAssertEqual(prepared?.promotionSegmentID, id2)
        XCTAssertEqual(prepared?.replacesPromotionSegmentID, id1)

        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-appmodel-modest-rewrite-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }
        let model = AppModel(settingsStore: SettingsStore(fileURL: settingsURL), sourceCatalogService: SourceCatalogService())

        let s1 = RecognizedSentence(text: "there is a problem", promotionSegmentID: id1, replacesPromotionSegmentID: nil, heardLanguageID: "en")
        model.enqueueRecognizedSentenceForTesting(s1, sourceLanguageID: "en", targetLanguageID: "en")
        await model.runCaptionQueueTurnForTesting()

        let s2 = RecognizedSentence(text: prepared!.text, promotionSegmentID: prepared!.promotionSegmentID, replacesPromotionSegmentID: prepared!.replacesPromotionSegmentID, heardLanguageID: "en")
        model.enqueueRecognizedSentenceForTesting(s2, sourceLanguageID: "en", targetLanguageID: "en")
        await model.runCaptionQueueTurnForTesting()

        XCTAssertEqual(model.displayedCaptionForTesting?.sourceText, fullSentence)
        XCTAssertEqual(model.transcriptEntriesForTesting.count, 1)
        XCTAssertEqual(model.transcriptEntriesForTesting.first?.sourceText, fullSentence)
        XCTAssertEqual(model.overlayHistoryForTesting.count, 0)
    }

    @MainActor
    func testLTSProvisionalSameTextReplayWithRotatedIDProducesOneRowInAppModel() async {
        let session = LiveTranscriptionSession()
        let id1 = UUID()
        let id2 = UUID()

        // Provisional commit "Thank you very much."
        session.rememberCommittedSentenceForTesting("Thank you very much.", isProvisionalSilence: true, promotionSegmentID: id1)

        // Callback arrives with same text and rotated ID
        let prepared = session.prepareCommittedSentenceForEmissionForTesting(
            "Thank you very much.",
            pendingPromotionID: id2,
            isProvisionalSilence: false
        )

        XCTAssertNotNil(prepared)
        XCTAssertEqual(prepared?.text, "Thank you very much.")
        XCTAssertEqual(prepared?.promotionSegmentID, id2)
        XCTAssertEqual(prepared?.replacesPromotionSegmentID, id1)

        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-appmodel-same-text-replay-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }
        let model = AppModel(settingsStore: SettingsStore(fileURL: settingsURL), sourceCatalogService: SourceCatalogService())

        let s1 = RecognizedSentence(text: "Thank you very much.", promotionSegmentID: id1, replacesPromotionSegmentID: nil, heardLanguageID: "en")
        model.enqueueRecognizedSentenceForTesting(s1, sourceLanguageID: "en", targetLanguageID: "en")
        await model.runCaptionQueueTurnForTesting()

        let s2 = RecognizedSentence(text: prepared!.text, promotionSegmentID: prepared!.promotionSegmentID, replacesPromotionSegmentID: prepared!.replacesPromotionSegmentID, heardLanguageID: "en")
        model.enqueueRecognizedSentenceForTesting(s2, sourceLanguageID: "en", targetLanguageID: "en")
        await model.runCaptionQueueTurnForTesting()

        XCTAssertEqual(model.displayedCaptionForTesting?.sourceText, "Thank you very much.")
        XCTAssertEqual(model.transcriptEntriesForTesting.count, 1)
        XCTAssertEqual(model.transcriptEntriesForTesting.first?.sourceText, "Thank you very much.")
        XCTAssertEqual(model.overlayHistoryForTesting.count, 0)
    }

    @MainActor
    func testLTSGenuineIdenticalUtteranceAcrossDistinctAcousticBoundaryAppendsSecondRowInAppModel() async {
        let session = LiveTranscriptionSession()
        let id1 = UUID()
        let id2 = UUID()

        // Utterance 1 finalized (not provisional silence)
        session.rememberCommittedSentenceForTesting("Thank you very much.", isProvisionalSilence: false, promotionSegmentID: id1)

        // Utterance 2 arrives as a new utterance across distinct acoustic boundary
        let prepared = session.prepareCommittedSentenceForEmissionForTesting(
            "Thank you very much.",
            pendingPromotionID: id2,
            isProvisionalSilence: false
        )

        XCTAssertNotNil(prepared)
        XCTAssertEqual(prepared?.text, "Thank you very much.")
        XCTAssertEqual(prepared?.promotionSegmentID, id2)
        XCTAssertNil(prepared?.replacesPromotionSegmentID)

        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-appmodel-genuine-acoustic-boundary-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }
        let model = AppModel(settingsStore: SettingsStore(fileURL: settingsURL), sourceCatalogService: SourceCatalogService())

        let s1 = RecognizedSentence(text: "Thank you very much.", promotionSegmentID: id1, replacesPromotionSegmentID: nil, heardLanguageID: "en")
        model.enqueueRecognizedSentenceForTesting(s1, sourceLanguageID: "en", targetLanguageID: "en")
        await model.runCaptionQueueTurnForTesting()
        model.completeHeldCaptionForTesting()

        let s2 = RecognizedSentence(text: prepared!.text, promotionSegmentID: prepared!.promotionSegmentID, replacesPromotionSegmentID: prepared!.replacesPromotionSegmentID, heardLanguageID: "en")
        model.enqueueRecognizedSentenceForTesting(s2, sourceLanguageID: "en", targetLanguageID: "en")
        await model.runCaptionQueueTurnForTesting()

        XCTAssertEqual(model.displayedCaptionForTesting?.sourceText, "Thank you very much.")
        XCTAssertEqual(model.overlayHistoryForTesting.count, 1)
        XCTAssertEqual(model.overlayHistoryForTesting.first?.sourceText, "Thank you very much.")
        XCTAssertEqual(model.transcriptEntriesForTesting.count, 2)
        XCTAssertEqual(model.transcriptEntriesForTesting[0].sourceText, "Thank you very much.")
        XCTAssertEqual(model.transcriptEntriesForTesting[1].sourceText, "Thank you very much.")
    }

    @MainActor
    func testModernSpeechTranscriberProvisionalSilenceFollowedByFullUtteranceProducesOneReconstructedRow() async {
        let session = LiveTranscriptionSession()
        let id1 = UUID()
        let id2 = UUID()
        let range = CMTimeRange(start: CMTime(seconds: 1.0, preferredTimescale: 1000), duration: CMTime(seconds: 4.0, preferredTimescale: 1000))

        // Provisional silence commit "We are going to."
        session.rememberCommittedSentenceForTesting("We are going to.", isProvisionalSilence: true, promotionSegmentID: id1, audioRange: range)

        // Full final transcriber result arrives with complete utterance
        let fullSentence = "We are going to build a new system."
        let prepared = session.prepareCommittedSentenceForEmissionForTesting(
            fullSentence,
            pendingPromotionID: id2,
            isProvisionalSilence: false,
            audioRange: range
        )

        XCTAssertNotNil(prepared)
        XCTAssertEqual(prepared?.text, fullSentence)
        XCTAssertEqual(prepared?.promotionSegmentID, id2)
        XCTAssertEqual(prepared?.replacesPromotionSegmentID, id1)

        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-appmodel-modern-reconstruct-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }
        let model = AppModel(settingsStore: SettingsStore(fileURL: settingsURL), sourceCatalogService: SourceCatalogService())

        let s1 = RecognizedSentence(text: "We are going to.", promotionSegmentID: id1, replacesPromotionSegmentID: nil, heardLanguageID: "en")
        model.enqueueRecognizedSentenceForTesting(s1, sourceLanguageID: "en", targetLanguageID: "en")
        await model.runCaptionQueueTurnForTesting()

        let s2 = RecognizedSentence(text: prepared!.text, promotionSegmentID: prepared!.promotionSegmentID, replacesPromotionSegmentID: prepared!.replacesPromotionSegmentID, heardLanguageID: "en")
        model.enqueueRecognizedSentenceForTesting(s2, sourceLanguageID: "en", targetLanguageID: "en")
        await model.runCaptionQueueTurnForTesting()

        // Must be ONE row containing full A+B, not severed suffix
        XCTAssertEqual(model.displayedCaptionForTesting?.sourceText, fullSentence)
        XCTAssertEqual(model.transcriptEntriesForTesting.count, 1)
        XCTAssertEqual(model.transcriptEntriesForTesting.first?.sourceText, fullSentence)
        XCTAssertEqual(model.overlayHistoryForTesting.count, 0)
    }

    @MainActor
    func testModernFastAutoPunctuationProvisionalFollowedByFinalReconstructsFullUtteranceProducesOneRow() async {
        let session = LiveTranscriptionSession()
        let id1 = UUID()
        let id2 = UUID()
        let range = CMTimeRange(start: CMTime(seconds: 0.0, preferredTimescale: 1000), duration: CMTime(seconds: 5.0, preferredTimescale: 1000))

        // Fast auto-punctuation provisional commit "First clause,"
        session.rememberCommittedSentenceForTesting("First clause,", isProvisionalSilence: true, promotionSegmentID: id1, audioRange: range)

        // Full final transcriber result arrives with complete sentence
        let fullSentence = "First clause, second clause completed."
        let prepared = session.prepareCommittedSentenceForEmissionForTesting(
            fullSentence,
            pendingPromotionID: id2,
            isProvisionalSilence: false,
            audioRange: range
        )

        XCTAssertNotNil(prepared)
        XCTAssertEqual(prepared?.text, fullSentence)
        XCTAssertEqual(prepared?.promotionSegmentID, id2)
        XCTAssertEqual(prepared?.replacesPromotionSegmentID, id1)

        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-appmodel-fast-autopunc-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }
        let model = AppModel(settingsStore: SettingsStore(fileURL: settingsURL), sourceCatalogService: SourceCatalogService())

        let s1 = RecognizedSentence(text: "First clause,", promotionSegmentID: id1, replacesPromotionSegmentID: nil, heardLanguageID: "en")
        model.enqueueRecognizedSentenceForTesting(s1, sourceLanguageID: "en", targetLanguageID: "en")
        await model.runCaptionQueueTurnForTesting()

        let s2 = RecognizedSentence(text: prepared!.text, promotionSegmentID: prepared!.promotionSegmentID, replacesPromotionSegmentID: prepared!.replacesPromotionSegmentID, heardLanguageID: "en")
        model.enqueueRecognizedSentenceForTesting(s2, sourceLanguageID: "en", targetLanguageID: "en")
        await model.runCaptionQueueTurnForTesting()

        XCTAssertEqual(model.displayedCaptionForTesting?.sourceText, fullSentence)
        XCTAssertEqual(model.transcriptEntriesForTesting.count, 1)
        XCTAssertEqual(model.transcriptEntriesForTesting.first?.sourceText, fullSentence)
        XCTAssertEqual(model.overlayHistoryForTesting.count, 0)
    }

    @MainActor
    func testModernSilenceCommitThenFinalFullUtteranceProducesOneRowThroughProductionSeam() async {
        let session = LiveTranscriptionSession()
        var collected: [RecognizedSentence] = []
        session.installTranscriptHandlerForTesting { collected.append($0) }

        let range = CMTimeRange(
            start: CMTime(seconds: 1.0, preferredTimescale: 1000),
            duration: CMTime(seconds: 4.0, preferredTimescale: 1000)
        )
        let fullSentence = "We are going to build a new system."

        session.processModernRecognitionTextForTesting("We are going to.", isFinal: false, audioRange: range)
        await flushModernEmissions()
        session.forceCommitOnSilenceForTesting()
        await flushModernEmissions()
        session.processModernRecognitionTextForTesting(fullSentence, isFinal: true, audioRange: range)
        await flushModernEmissions()

        XCTAssertFalse(collected.isEmpty, "production seam must emit at least one recognized sentence")
        let (model, settingsURL) = makeAppModel(prefix: "v2s-modern-silence-seam")
        defer { try? FileManager.default.removeItem(at: settingsURL) }
        await enqueueCollected(collected, into: model)

        XCTAssertEqual(model.displayedCaptionForTesting?.sourceText, fullSentence)
        XCTAssertEqual(model.transcriptEntriesForTesting.count, 1)
        XCTAssertEqual(model.transcriptEntriesForTesting.first?.sourceText, fullSentence)
        XCTAssertEqual(model.overlayHistoryForTesting.count, 0)
        XCTAssertNotEqual(model.displayedCaptionForTesting?.sourceText, "build a new system.")
    }

    @MainActor
    func testModernFastAutoPunctuationThenFinalFullUtteranceProducesOneRowThroughProductionSeam() async {
        let session = LiveTranscriptionSession()
        var collected: [RecognizedSentence] = []
        session.installTranscriptHandlerForTesting { collected.append($0) }

        let range = CMTimeRange(
            start: CMTime(seconds: 0.0, preferredTimescale: 1000),
            duration: CMTime(seconds: 5.0, preferredTimescale: 1000)
        )
        let fullSentence = "First clause, second clause completed."

        session.processModernRecognitionTextForTesting("First clause,", isFinal: false, audioRange: range)
        await flushModernEmissions()
        session.backdateLastDraftTextChangeForTesting(secondsAgo: 1)
        session.processModernRecognitionTextForTesting("First clause,", isFinal: false, audioRange: range)
        await flushModernEmissions()
        session.processModernRecognitionTextForTesting(fullSentence, isFinal: true, audioRange: range)
        await flushModernEmissions()

        XCTAssertFalse(collected.isEmpty, "production seam must emit at least one recognized sentence")
        let (model, settingsURL) = makeAppModel(prefix: "v2s-modern-fast-autopunc-seam")
        defer { try? FileManager.default.removeItem(at: settingsURL) }
        await enqueueCollected(collected, into: model)

        XCTAssertEqual(model.displayedCaptionForTesting?.sourceText, fullSentence)
        XCTAssertEqual(model.transcriptEntriesForTesting.count, 1)
        XCTAssertEqual(model.transcriptEntriesForTesting.first?.sourceText, fullSentence)
        XCTAssertEqual(model.overlayHistoryForTesting.count, 0)
        XCTAssertNotEqual(model.displayedCaptionForTesting?.sourceText, "second clause completed.")
    }


    @MainActor
    func testModernCallbackWithTwoIndependentSentencesProducesTwoRows() async {
        let session = LiveTranscriptionSession()
        let id1 = UUID()
        let id2 = UUID()
        let range = CMTimeRange(start: CMTime(seconds: 0.0, preferredTimescale: 1000), duration: CMTime(seconds: 6.0, preferredTimescale: 1000))

        // Sentence 1 prepared from callback
        let prep1 = session.prepareCommittedSentenceForEmissionForTesting(
            "Hello everyone.",
            pendingPromotionID: id1,
            isProvisionalSilence: false,
            audioRange: range
        )
        XCTAssertNotNil(prep1)
        XCTAssertEqual(prep1?.text, "Hello everyone.")
        XCTAssertNil(prep1?.replacesPromotionSegmentID)

        // Sentence 2 prepared from same callback with same audio range
        let prep2 = session.prepareCommittedSentenceForEmissionForTesting(
            "Welcome to the presentation.",
            pendingPromotionID: id2,
            isProvisionalSilence: false,
            audioRange: range
        )
        XCTAssertNotNil(prep2)
        XCTAssertEqual(prep2?.text, "Welcome to the presentation.")
        // Must NOT replace sentence 1 despite sharing audio range
        XCTAssertNil(prep2?.replacesPromotionSegmentID)

        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-appmodel-two-sentences-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }
        let model = AppModel(settingsStore: SettingsStore(fileURL: settingsURL), sourceCatalogService: SourceCatalogService())

        let s1 = RecognizedSentence(text: prep1!.text, promotionSegmentID: prep1!.promotionSegmentID, replacesPromotionSegmentID: nil, heardLanguageID: "en")
        model.enqueueRecognizedSentenceForTesting(s1, sourceLanguageID: "en", targetLanguageID: "en")
        await model.runCaptionQueueTurnForTesting()
        model.completeHeldCaptionForTesting()

        let s2 = RecognizedSentence(text: prep2!.text, promotionSegmentID: prep2!.promotionSegmentID, replacesPromotionSegmentID: nil, heardLanguageID: "en")
        model.enqueueRecognizedSentenceForTesting(s2, sourceLanguageID: "en", targetLanguageID: "en")
        await model.runCaptionQueueTurnForTesting()

        XCTAssertEqual(model.displayedCaptionForTesting?.sourceText, "Welcome to the presentation.")
        XCTAssertEqual(model.overlayHistoryForTesting.count, 1)
        XCTAssertEqual(model.overlayHistoryForTesting.first?.sourceText, "Hello everyone.")
        XCTAssertEqual(model.transcriptEntriesForTesting.count, 2)
        XCTAssertEqual(model.transcriptEntriesForTesting[0].sourceText, "Hello everyone.")
        XCTAssertEqual(model.transcriptEntriesForTesting[1].sourceText, "Welcome to the presentation.")
    }

    @MainActor
    func testFinalizedPrefixFollowedByGenuineNextPrefixExtensionProducesTwoRows() async {
        let session = LiveTranscriptionSession()
        let id1 = UUID()
        let id2 = UUID()

        // Sentence 1 finalized: "We are going."
        session.rememberCommittedSentenceForTesting("We are going.", isProvisionalSilence: false, promotionSegmentID: id1)

        // Sentence 2 begins with same prefix but is a genuine next sentence: "We are going to Tokyo tomorrow."
        let prep2 = session.prepareCommittedSentenceForEmissionForTesting(
            "We are going to Tokyo tomorrow.",
            pendingPromotionID: id2,
            isProvisionalSilence: false
        )

        XCTAssertNotNil(prep2)
        XCTAssertEqual(prep2?.text, "We are going to Tokyo tomorrow.")
        // Because sentence 1 was finalized (not provisional silence), sentence 2 is a new utterance
        XCTAssertNil(prep2?.replacesPromotionSegmentID)

        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-appmodel-genuine-prefix-extension-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }
        let model = AppModel(settingsStore: SettingsStore(fileURL: settingsURL), sourceCatalogService: SourceCatalogService())

        let s1 = RecognizedSentence(text: "We are going.", promotionSegmentID: id1, replacesPromotionSegmentID: nil, heardLanguageID: "en")
        model.enqueueRecognizedSentenceForTesting(s1, sourceLanguageID: "en", targetLanguageID: "en")
        await model.runCaptionQueueTurnForTesting()
        model.completeHeldCaptionForTesting()

        let s2 = RecognizedSentence(text: prep2!.text, promotionSegmentID: prep2!.promotionSegmentID, replacesPromotionSegmentID: prep2!.replacesPromotionSegmentID, heardLanguageID: "en")
        model.enqueueRecognizedSentenceForTesting(s2, sourceLanguageID: "en", targetLanguageID: "en")
        await model.runCaptionQueueTurnForTesting()

        XCTAssertEqual(model.displayedCaptionForTesting?.sourceText, "We are going to Tokyo tomorrow.")
        XCTAssertEqual(model.overlayHistoryForTesting.count, 1)
        XCTAssertEqual(model.overlayHistoryForTesting.first?.sourceText, "We are going.")
        XCTAssertEqual(model.transcriptEntriesForTesting.count, 2)
        XCTAssertEqual(model.transcriptEntriesForTesting[0].sourceText, "We are going.")
        XCTAssertEqual(model.transcriptEntriesForTesting[1].sourceText, "We are going to Tokyo tomorrow.")
    }

    @MainActor
    func testAppModelReplacementWhilePendingInQueue() async {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-appmodel-pending-replacement-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: SourceCatalogService()
        )

        let id0 = UUID()
        let firstSentence = RecognizedSentence(
            text: "Sentence zero occupying display.",
            promotionSegmentID: id0,
            replacesPromotionSegmentID: nil,
            heardLanguageID: "en"
        )
        model.enqueueRecognizedSentenceForTesting(firstSentence, sourceLanguageID: "en", targetLanguageID: "en")
        await model.runCaptionQueueTurnForTesting()

        // Sentence 1 is enqueued (pending behind sentence 0)
        let id1 = UUID()
        let partialPending = RecognizedSentence(
            text: "Partial in queue",
            promotionSegmentID: id1,
            replacesPromotionSegmentID: nil,
            heardLanguageID: "en"
        )
        model.enqueueRecognizedSentenceForTesting(partialPending, sourceLanguageID: "en", targetLanguageID: "en")

        // Replacement for sentence 1 arrives while it is still pending
        let fullPending = RecognizedSentence(
            text: "Partial in queue now fully completed.",
            promotionSegmentID: id1,
            replacesPromotionSegmentID: id1,
            heardLanguageID: "en"
        )
        model.enqueueRecognizedSentenceForTesting(fullPending, sourceLanguageID: "en", targetLanguageID: "en")

        // Advance queue past sentence 0
        model.completeHeldCaptionForTesting()
        await model.runCaptionQueueTurnForTesting()

        // Sentence 1 displays its fully completed text directly
        XCTAssertEqual(model.displayedCaptionForTesting?.sourceText, "Partial in queue now fully completed.")
        XCTAssertEqual(model.overlayHistoryForTesting.count, 1)
        XCTAssertEqual(model.overlayHistoryForTesting.first?.sourceText, "Sentence zero occupying display.")
    }

    @MainActor
    func testAppModelReplacementAfterArchivedInHistory() async {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-appmodel-archived-replacement-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: SourceCatalogService()
        )

        let id1 = UUID()
        let sentence1 = RecognizedSentence(
            text: "Short prefix",
            promotionSegmentID: id1,
            replacesPromotionSegmentID: nil,
            heardLanguageID: "en"
        )
        model.enqueueRecognizedSentenceForTesting(sentence1, sourceLanguageID: "en", targetLanguageID: "en")
        await model.runCaptionQueueTurnForTesting()

        // Move past sentence 1 so it is archived into history
        model.completeHeldCaptionForTesting()
        let id2 = UUID()
        let sentence2 = RecognizedSentence(
            text: "Another sentence displayed.",
            promotionSegmentID: id2,
            replacesPromotionSegmentID: nil,
            heardLanguageID: "en"
        )
        model.enqueueRecognizedSentenceForTesting(sentence2, sourceLanguageID: "en", targetLanguageID: "en")
        await model.runCaptionQueueTurnForTesting()

        XCTAssertEqual(model.overlayHistoryForTesting.count, 1)
        XCTAssertEqual(model.overlayHistoryForTesting.first?.sourceText, "Short prefix")

        // Late full revision for id1 arrives after it was already archived
        let fullSentence1 = RecognizedSentence(
            text: "Short prefix extended into complete thought.",
            promotionSegmentID: id1,
            replacesPromotionSegmentID: id1,
            heardLanguageID: "en"
        )
        model.enqueueRecognizedSentenceForTesting(fullSentence1, sourceLanguageID: "en", targetLanguageID: "en")
        await model.runCaptionQueueTurnForTesting()

        // History row updated in-place, count remains 1
        XCTAssertEqual(model.overlayHistoryForTesting.count, 1)
        XCTAssertEqual(model.overlayHistoryForTesting.first?.sourceText, "Short prefix extended into complete thought.")
        XCTAssertEqual(model.transcriptEntriesForTesting.first?.sourceText, "Short prefix extended into complete thought.")
        XCTAssertEqual(model.displayedCaptionForTesting?.sourceText, "Another sentence displayed.")
    }
    @MainActor
    func testAppModelTranslationGenerationRaceBothOrders() async {
        // Order 1: New revision completes first, stale older translation arrives later -> stale is rejected
        do {
            let settingsURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("v2s-appmodel-race1-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: settingsURL) }

            let model = AppModel(
                settingsStore: SettingsStore(fileURL: settingsURL),
                sourceCatalogService: SourceCatalogService()
            )

            let id1 = UUID()
            let provisional = RecognizedSentence(
                text: "Initial draft",
                promotionSegmentID: id1,
                replacesPromotionSegmentID: nil,
                heardLanguageID: "en"
            )
            model.enqueueRecognizedSentenceForTesting(provisional, sourceLanguageID: "en", targetLanguageID: "zh-Hant")
            await model.runCaptionQueueTurnForTesting()

            let captionID = model.transcriptEntriesForTesting.first?.id
            XCTAssertNotNil(captionID)
            XCTAssertEqual(model.displayedCaptionForTesting?.sourceText, "Initial draft")
            XCTAssertEqual(model.overlayState?.sourceText, "Initial draft")
            XCTAssertEqual(model.overlayState?.translatedText, "")
            XCTAssertEqual(model.overlayHistoryForTesting.count, 0)
            XCTAssertEqual(model.transcriptEntriesForTesting.count, 1)
            XCTAssertEqual(model.transcriptEntriesForTesting.first?.sourceText, "Initial draft")
            XCTAssertEqual(model.transcriptEntriesForTesting.first?.translatedText, "")

            let gen1 = model.currentTranslationGenerationForTesting(captionID: id1)
            XCTAssertNotNil(gen1)

            let id2 = UUID()
            let replacement = RecognizedSentence(
                text: "Initial draft now fully completed.",
                promotionSegmentID: id2,
                replacesPromotionSegmentID: id1,
                heardLanguageID: "en"
            )
            model.enqueueRecognizedSentenceForTesting(replacement, sourceLanguageID: "en", targetLanguageID: "zh-Hant")
            await model.runCaptionQueueTurnForTesting()

            XCTAssertEqual(model.displayedCaptionForTesting?.sourceText, "Initial draft now fully completed.")
            XCTAssertEqual(model.overlayState?.sourceText, "Initial draft now fully completed.")
            XCTAssertEqual(model.overlayState?.translatedText, "")
            XCTAssertEqual(model.overlayHistoryForTesting.count, 0)
            XCTAssertEqual(model.transcriptEntriesForTesting.count, 1)
            XCTAssertEqual(model.transcriptEntriesForTesting.first?.id, captionID)
            XCTAssertEqual(model.transcriptEntriesForTesting.first?.sourceText, "Initial draft now fully completed.")
            XCTAssertEqual(model.transcriptEntriesForTesting.first?.translatedText, "")

            let gen2 = model.currentTranslationGenerationForTesting(captionID: id1)
            XCTAssertNotNil(gen2)
            XCTAssertGreaterThan(gen2!, gen1!)

            // Complete gen2 with correct revised translation
            let gen2Applied = model.completeCaptionTranslationForTesting(
                captionID: id1,
                generation: gen2!,
                translatedText: "完整翻譯"
            )
            XCTAssertTrue(gen2Applied)

            // Attempt to apply stale gen1 result -> must be rejected
            let staleApplied = model.completeCaptionTranslationForTesting(
                captionID: id1,
                generation: gen1!,
                translatedText: "過期翻譯"
            )
            XCTAssertFalse(staleApplied)

            // Assert displayed overlay translated/source panes and transcript
            XCTAssertEqual(model.displayedCaptionForTesting?.sourceText, "Initial draft now fully completed.")
            XCTAssertEqual(model.overlayState?.sourceText, "Initial draft now fully completed.")
            XCTAssertEqual(model.overlayState?.translatedText, "完整翻譯")
            XCTAssertEqual(model.overlayHistoryForTesting.count, 0)
            XCTAssertEqual(model.transcriptEntriesForTesting.count, 1)
            XCTAssertEqual(model.transcriptEntriesForTesting.first?.id, captionID)
            XCTAssertEqual(model.transcriptEntriesForTesting.first?.sourceText, "Initial draft now fully completed.")
            XCTAssertEqual(model.transcriptEntriesForTesting.first?.translatedText, "完整翻譯")
        }

        // Order 2: Stale older translation attempts completion first, then new revision completes -> stale is rejected
        do {
            let settingsURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("v2s-appmodel-race2-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: settingsURL) }

            let model = AppModel(
                settingsStore: SettingsStore(fileURL: settingsURL),
                sourceCatalogService: SourceCatalogService()
            )

            let id1 = UUID()
            let provisional = RecognizedSentence(
                text: "Starting words",
                promotionSegmentID: id1,
                replacesPromotionSegmentID: nil,
                heardLanguageID: "en"
            )
            model.enqueueRecognizedSentenceForTesting(provisional, sourceLanguageID: "en", targetLanguageID: "zh-Hant")
            await model.runCaptionQueueTurnForTesting()

            let captionID = model.transcriptEntriesForTesting.first?.id
            XCTAssertNotNil(captionID)
            XCTAssertEqual(model.displayedCaptionForTesting?.sourceText, "Starting words")
            XCTAssertEqual(model.overlayState?.sourceText, "Starting words")
            XCTAssertEqual(model.overlayState?.translatedText, "")
            XCTAssertEqual(model.overlayHistoryForTesting.count, 0)
            XCTAssertEqual(model.transcriptEntriesForTesting.count, 1)
            XCTAssertEqual(model.transcriptEntriesForTesting.first?.sourceText, "Starting words")
            XCTAssertEqual(model.transcriptEntriesForTesting.first?.translatedText, "")

            let gen1 = model.currentTranslationGenerationForTesting(captionID: id1)
            XCTAssertNotNil(gen1)

            let id2 = UUID()
            let replacement = RecognizedSentence(
                text: "Starting words completed into sentence.",
                promotionSegmentID: id2,
                replacesPromotionSegmentID: id1,
                heardLanguageID: "en"
            )
            model.enqueueRecognizedSentenceForTesting(replacement, sourceLanguageID: "en", targetLanguageID: "zh-Hant")
            await model.runCaptionQueueTurnForTesting()

            XCTAssertEqual(model.displayedCaptionForTesting?.sourceText, "Starting words completed into sentence.")
            XCTAssertEqual(model.overlayState?.sourceText, "Starting words completed into sentence.")
            XCTAssertEqual(model.overlayState?.translatedText, "")
            XCTAssertEqual(model.overlayHistoryForTesting.count, 0)
            XCTAssertEqual(model.transcriptEntriesForTesting.count, 1)
            XCTAssertEqual(model.transcriptEntriesForTesting.first?.id, captionID)
            XCTAssertEqual(model.transcriptEntriesForTesting.first?.sourceText, "Starting words completed into sentence.")
            XCTAssertEqual(model.transcriptEntriesForTesting.first?.translatedText, "")

            let gen2 = model.currentTranslationGenerationForTesting(captionID: id1)
            XCTAssertNotNil(gen2)
            XCTAssertGreaterThan(gen2!, gen1!)

            // Attempt to apply stale gen1 result -> must be rejected
            let staleApplied = model.completeCaptionTranslationForTesting(
                captionID: id1,
                generation: gen1!,
                translatedText: "舊翻譯"
            )
            XCTAssertFalse(staleApplied)

            // Verify overlay translated pane and transcript entry remain blank (not corrupted by stale)
            XCTAssertEqual(model.displayedCaptionForTesting?.sourceText, "Starting words completed into sentence.")
            XCTAssertEqual(model.overlayState?.sourceText, "Starting words completed into sentence.")
            XCTAssertEqual(model.overlayState?.translatedText, "")
            XCTAssertEqual(model.transcriptEntriesForTesting.first?.translatedText, "")

            // Complete gen2 with correct revised translation
            let gen2Applied = model.completeCaptionTranslationForTesting(
                captionID: id1,
                generation: gen2!,
                translatedText: "新完整翻譯"
            )
            XCTAssertTrue(gen2Applied)

            // Assert final displayed overlay translated/source panes and transcript
            XCTAssertEqual(model.displayedCaptionForTesting?.sourceText, "Starting words completed into sentence.")
            XCTAssertEqual(model.overlayState?.sourceText, "Starting words completed into sentence.")
            XCTAssertEqual(model.overlayState?.translatedText, "新完整翻譯")
            XCTAssertEqual(model.overlayHistoryForTesting.count, 0)
            XCTAssertEqual(model.transcriptEntriesForTesting.count, 1)
            XCTAssertEqual(model.transcriptEntriesForTesting.first?.id, captionID)
            XCTAssertEqual(model.transcriptEntriesForTesting.first?.sourceText, "Starting words completed into sentence.")
            XCTAssertEqual(model.transcriptEntriesForTesting.first?.translatedText, "新完整翻譯")
        }
    }

    @MainActor
    func testAppModelArchivedHistoryReplacementTranslationGenerationRaceNormalLane() async {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-appmodel-archived-race-normal-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: SourceCatalogService()
        )

        let id1 = UUID()
        let sentence1 = RecognizedSentence(
            text: "First sentence preamble",
            promotionSegmentID: id1,
            replacesPromotionSegmentID: nil,
            heardLanguageID: "en"
        )
        model.enqueueRecognizedSentenceForTesting(sentence1, sourceLanguageID: "en", targetLanguageID: "zh-Hant")
        await model.runCaptionQueueTurnForTesting()

        let caption1ID = model.transcriptEntriesForTesting.first?.id
        XCTAssertNotNil(caption1ID)
        let gen1_s1 = model.currentTranslationGenerationForTesting(captionID: id1)
        XCTAssertNotNil(gen1_s1)
        let s1Translated = model.completeCaptionTranslationForTesting(
            captionID: id1,
            generation: gen1_s1!,
            translatedText: "第一句序言"
        )
        XCTAssertTrue(s1Translated)
        await model.runCaptionQueueTurnForTesting()
        XCTAssertEqual(model.overlayState?.sourceText, "First sentence preamble")
        XCTAssertEqual(model.overlayState?.translatedText, "第一句序言")

        // Archive sentence 1 into history and display sentence 2
        model.completeHeldCaptionForTesting()
        let id2 = UUID()
        let sentence2 = RecognizedSentence(
            text: "Second active sentence",
            promotionSegmentID: id2,
            replacesPromotionSegmentID: nil,
            heardLanguageID: "en"
        )
        model.enqueueRecognizedSentenceForTesting(sentence2, sourceLanguageID: "en", targetLanguageID: "zh-Hant")
        let gen_s2 = model.currentTranslationGenerationForTesting(captionID: id2)
        XCTAssertNotNil(gen_s2)
        let s2Translated = model.completeCaptionTranslationForTesting(
            captionID: id2,
            generation: gen_s2!,
            translatedText: "第二句進行中"
        )
        XCTAssertTrue(s2Translated)
        await model.runCaptionQueueTurnForTesting()

        let caption2ID = model.transcriptEntriesForTesting.last?.id
        XCTAssertNotNil(caption2ID)
        XCTAssertNotEqual(caption1ID, caption2ID)
        // Verify archived history state before revision
        XCTAssertEqual(model.overlayHistoryForTesting.count, 1)
        XCTAssertEqual(model.overlayHistoryForTesting[0].id, caption1ID)
        XCTAssertEqual(model.overlayHistoryForTesting[0].sourceText, "First sentence preamble")
        XCTAssertEqual(model.overlayHistoryForTesting[0].translatedText, "第一句序言")
        XCTAssertEqual(model.overlayState?.sourceText, "Second active sentence")
        XCTAssertEqual(model.overlayState?.translatedText, "第二句進行中")
        XCTAssertEqual(model.transcriptEntriesForTesting.count, 2)
        XCTAssertEqual(model.transcriptEntriesForTesting[0].id, caption1ID)
        XCTAssertEqual(model.transcriptEntriesForTesting[0].sourceText, "First sentence preamble")
        XCTAssertEqual(model.transcriptEntriesForTesting[0].translatedText, "第一句序言")
        XCTAssertEqual(model.transcriptEntriesForTesting[1].id, caption2ID)
        XCTAssertEqual(model.transcriptEntriesForTesting[1].sourceText, "Second active sentence")
        XCTAssertEqual(model.transcriptEntriesForTesting[1].translatedText, "第二句進行中")

        // Revision 1 arrives for archived sentence 1:
        // Revised archived row immediately has full source and blank translation
        let id1_rev1 = UUID()
        let rev1 = RecognizedSentence(
            text: "First sentence preamble with extra detail",
            promotionSegmentID: id1_rev1,
            replacesPromotionSegmentID: id1,
            heardLanguageID: "en"
        )
        model.enqueueRecognizedSentenceForTesting(rev1, sourceLanguageID: "en", targetLanguageID: "zh-Hant")
        await model.runCaptionQueueTurnForTesting()

        XCTAssertEqual(model.overlayHistoryForTesting.count, 1)
        XCTAssertEqual(model.overlayHistoryForTesting[0].id, caption1ID)
        XCTAssertEqual(model.overlayHistoryForTesting[0].sourceText, "First sentence preamble with extra detail")
        XCTAssertEqual(model.overlayHistoryForTesting[0].translatedText, "")
        XCTAssertEqual(model.transcriptEntriesForTesting.count, 2)
        XCTAssertEqual(model.transcriptEntriesForTesting[0].id, caption1ID)
        XCTAssertEqual(model.transcriptEntriesForTesting[0].sourceText, "First sentence preamble with extra detail")
        XCTAssertEqual(model.transcriptEntriesForTesting[0].translatedText, "")
        // Active display is undisturbed
        XCTAssertEqual(model.overlayState?.sourceText, "Second active sentence")
        XCTAssertEqual(model.overlayState?.translatedText, "第二句進行中")
        XCTAssertEqual(model.transcriptEntriesForTesting[1].id, caption2ID)

        let gen_rev1 = model.currentTranslationGenerationForTesting(captionID: id1)
        XCTAssertNotNil(gen_rev1)

        // Revision 2 arrives for archived sentence 1 before gen_rev1 completes:
        let id1_rev2 = UUID()
        let rev2 = RecognizedSentence(
            text: "First sentence preamble fully finalized.",
            promotionSegmentID: id1_rev2,
            replacesPromotionSegmentID: id1,
            heardLanguageID: "en"
        )
        model.enqueueRecognizedSentenceForTesting(rev2, sourceLanguageID: "en", targetLanguageID: "zh-Hant")
        await model.runCaptionQueueTurnForTesting()

        XCTAssertEqual(model.overlayHistoryForTesting.count, 1)
        XCTAssertEqual(model.overlayHistoryForTesting[0].id, caption1ID)
        XCTAssertEqual(model.overlayHistoryForTesting[0].sourceText, "First sentence preamble fully finalized.")
        XCTAssertEqual(model.overlayHistoryForTesting[0].translatedText, "")
        XCTAssertEqual(model.transcriptEntriesForTesting.count, 2)
        XCTAssertEqual(model.transcriptEntriesForTesting[0].id, caption1ID)
        XCTAssertEqual(model.transcriptEntriesForTesting[0].sourceText, "First sentence preamble fully finalized.")
        XCTAssertEqual(model.transcriptEntriesForTesting[0].translatedText, "")

        let gen_rev2 = model.currentTranslationGenerationForTesting(captionID: id1)
        XCTAssertNotNil(gen_rev2)
        XCTAssertGreaterThan(gen_rev2!, gen_rev1!)

        // Stale superseded completion cannot overwrite it
        let staleApplied = model.completeCaptionTranslationForTesting(
            captionID: id1,
            generation: gen_rev1!,
            translatedText: "過期的第一句延伸翻譯"
        )
        XCTAssertFalse(staleApplied)
        XCTAssertEqual(model.overlayHistoryForTesting[0].id, caption1ID)
        XCTAssertEqual(model.overlayHistoryForTesting[0].sourceText, "First sentence preamble fully finalized.")
        XCTAssertEqual(model.overlayHistoryForTesting[0].translatedText, "")
        XCTAssertEqual(model.transcriptEntriesForTesting[0].id, caption1ID)
        XCTAssertEqual(model.transcriptEntriesForTesting[0].sourceText, "First sentence preamble fully finalized.")
        XCTAssertEqual(model.transcriptEntriesForTesting[0].translatedText, "")

        // Current-generation completion fills its translation
        let validApplied = model.completeCaptionTranslationForTesting(
            captionID: id1,
            generation: gen_rev2!,
            translatedText: "第一句序言完全定稿。"
        )
        XCTAssertTrue(validApplied)
        XCTAssertEqual(model.overlayHistoryForTesting.count, 1)
        XCTAssertEqual(model.overlayHistoryForTesting[0].id, caption1ID)
        XCTAssertEqual(model.overlayHistoryForTesting[0].sourceText, "First sentence preamble fully finalized.")
        XCTAssertEqual(model.overlayHistoryForTesting[0].translatedText, "第一句序言完全定稿。")
        XCTAssertEqual(model.transcriptEntriesForTesting.count, 2)
        XCTAssertEqual(model.transcriptEntriesForTesting[0].id, caption1ID)
        XCTAssertEqual(model.transcriptEntriesForTesting[0].sourceText, "First sentence preamble fully finalized.")
        XCTAssertEqual(model.transcriptEntriesForTesting[0].translatedText, "第一句序言完全定稿。")
        XCTAssertEqual(model.overlayState?.sourceText, "Second active sentence")
        XCTAssertEqual(model.overlayState?.translatedText, "第二句進行中")
    }

    @MainActor
    func testAppModelArchivedHistoryReplacementTranslationGenerationRaceReverseLane() async {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-appmodel-archived-race-reverse-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: SourceCatalogService()
        )

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

        let id1 = UUID()
        let sentence1 = RecognizedSentence(
            text: "Hello everyone",
            promotionSegmentID: id1,
            replacesPromotionSegmentID: nil,
            heardLanguageID: "en",
            dualLaneEvidence: evidence
        )
        model.enqueueRecognizedSentenceForTesting(
            sentence1,
            sourceLanguageID: "en",
            targetLanguageID: "zh-Hant",
            usesInverseGlossary: true
        )
        await model.runCaptionQueueTurnForTesting()

        let caption1ID = model.transcriptEntriesForTesting.first?.id
        XCTAssertNotNil(caption1ID)
        let gen1_s1 = model.currentTranslationGenerationForTesting(captionID: id1)
        XCTAssertNotNil(gen1_s1)
        let s1Translated = model.completeCaptionTranslationForTesting(
            captionID: id1,
            generation: gen1_s1!,
            translatedText: "大家好"
        )
        XCTAssertTrue(s1Translated)
        await model.runCaptionQueueTurnForTesting()
        // In reverse lane: overlay sourceText is translation (top), translatedText is heard (bottom)
        XCTAssertEqual(model.overlayState?.sourceText, "大家好")
        XCTAssertEqual(model.overlayState?.translatedText, "Hello everyone")
        XCTAssertEqual(model.transcriptEntriesForTesting.first?.sourceText, "Hello everyone")
        XCTAssertEqual(model.transcriptEntriesForTesting.first?.translatedText, "大家好")

        // Archive sentence 1 into history and display sentence 2
        model.completeHeldCaptionForTesting()
        let id2 = UUID()
        let sentence2 = RecognizedSentence(
            text: "Welcome to the talk",
            promotionSegmentID: id2,
            replacesPromotionSegmentID: nil,
            heardLanguageID: "en",
            dualLaneEvidence: evidence
        )
        model.enqueueRecognizedSentenceForTesting(
            sentence2,
            sourceLanguageID: "en",
            targetLanguageID: "zh-Hant",
            usesInverseGlossary: true
        )
        let gen_s2 = model.currentTranslationGenerationForTesting(captionID: id2)
        XCTAssertNotNil(gen_s2)
        let s2Translated = model.completeCaptionTranslationForTesting(
            captionID: id2,
            generation: gen_s2!,
            translatedText: "歡迎參加演講"
        )
        XCTAssertTrue(s2Translated)
        await model.runCaptionQueueTurnForTesting()

        let caption2ID = model.transcriptEntriesForTesting.last?.id
        XCTAssertNotNil(caption2ID)
        XCTAssertNotEqual(caption1ID, caption2ID)
        // Verify archived reverse history before revision
        XCTAssertEqual(model.overlayHistoryForTesting.count, 1)
        XCTAssertEqual(model.overlayHistoryForTesting[0].id, caption1ID)
        XCTAssertEqual(model.overlayHistoryForTesting[0].sourceText, "大家好")
        XCTAssertEqual(model.overlayHistoryForTesting[0].translatedText, "Hello everyone")
        XCTAssertEqual(model.overlayState?.sourceText, "歡迎參加演講")
        XCTAssertEqual(model.overlayState?.translatedText, "Welcome to the talk")
        XCTAssertEqual(model.transcriptEntriesForTesting.count, 2)
        XCTAssertEqual(model.transcriptEntriesForTesting[0].id, caption1ID)
        XCTAssertEqual(model.transcriptEntriesForTesting[0].sourceText, "Hello everyone")
        XCTAssertEqual(model.transcriptEntriesForTesting[0].translatedText, "大家好")
        XCTAssertEqual(model.transcriptEntriesForTesting[1].id, caption2ID)
        XCTAssertEqual(model.transcriptEntriesForTesting[1].sourceText, "Welcome to the talk")
        XCTAssertEqual(model.transcriptEntriesForTesting[1].translatedText, "歡迎參加演講")

        // Revision 1 for archived reverse sentence 1:
        let id1_rev1 = UUID()
        let rev1 = RecognizedSentence(
            text: "Hello everyone in the audience",
            promotionSegmentID: id1_rev1,
            replacesPromotionSegmentID: id1,
            heardLanguageID: "en",
            dualLaneEvidence: evidence
        )
        model.enqueueRecognizedSentenceForTesting(
            rev1,
            sourceLanguageID: "en",
            targetLanguageID: "zh-Hant",
            usesInverseGlossary: true
        )
        await model.runCaptionQueueTurnForTesting()

        // Revised archived row in reverse lane: translation pane (sourceText) is blank, heard pane (translatedText) has heard text
        XCTAssertEqual(model.overlayHistoryForTesting.count, 1)
        XCTAssertEqual(model.overlayHistoryForTesting[0].id, caption1ID)
        XCTAssertEqual(model.overlayHistoryForTesting[0].sourceText, "")
        XCTAssertEqual(model.overlayHistoryForTesting[0].translatedText, "Hello everyone in the audience")
        XCTAssertEqual(model.transcriptEntriesForTesting.count, 2)
        XCTAssertEqual(model.transcriptEntriesForTesting[0].id, caption1ID)
        XCTAssertEqual(model.transcriptEntriesForTesting[0].sourceText, "Hello everyone in the audience")
        XCTAssertEqual(model.transcriptEntriesForTesting[0].translatedText, "")

        let gen_rev1 = model.currentTranslationGenerationForTesting(captionID: id1)
        XCTAssertNotNil(gen_rev1)

        // Revision 2 arrives for archived reverse sentence 1 before gen_rev1 completes:
        let id1_rev2 = UUID()
        let rev2 = RecognizedSentence(
            text: "Hello everyone in the audience and online.",
            promotionSegmentID: id1_rev2,
            replacesPromotionSegmentID: id1,
            heardLanguageID: "en",
            dualLaneEvidence: evidence
        )
        model.enqueueRecognizedSentenceForTesting(
            rev2,
            sourceLanguageID: "en",
            targetLanguageID: "zh-Hant",
            usesInverseGlossary: true
        )
        await model.runCaptionQueueTurnForTesting()

        XCTAssertEqual(model.overlayHistoryForTesting.count, 1)
        XCTAssertEqual(model.overlayHistoryForTesting[0].id, caption1ID)
        XCTAssertEqual(model.overlayHistoryForTesting[0].sourceText, "")
        XCTAssertEqual(model.overlayHistoryForTesting[0].translatedText, "Hello everyone in the audience and online.")
        XCTAssertEqual(model.transcriptEntriesForTesting.count, 2)
        XCTAssertEqual(model.transcriptEntriesForTesting[0].id, caption1ID)
        XCTAssertEqual(model.transcriptEntriesForTesting[0].sourceText, "Hello everyone in the audience and online.")
        XCTAssertEqual(model.transcriptEntriesForTesting[0].translatedText, "")

        let gen_rev2 = model.currentTranslationGenerationForTesting(captionID: id1)
        XCTAssertNotNil(gen_rev2)
        XCTAssertGreaterThan(gen_rev2!, gen_rev1!)

        // Stale completion rejected
        let staleApplied = model.completeCaptionTranslationForTesting(
            captionID: id1,
            generation: gen_rev1!,
            translatedText: "各位現場觀眾好"
        )
        XCTAssertFalse(staleApplied)
        XCTAssertEqual(model.overlayHistoryForTesting[0].id, caption1ID)
        XCTAssertEqual(model.overlayHistoryForTesting[0].sourceText, "")
        XCTAssertEqual(model.overlayHistoryForTesting[0].translatedText, "Hello everyone in the audience and online.")
        XCTAssertEqual(model.transcriptEntriesForTesting[0].id, caption1ID)
        XCTAssertEqual(model.transcriptEntriesForTesting[0].sourceText, "Hello everyone in the audience and online.")
        XCTAssertEqual(model.transcriptEntriesForTesting[0].translatedText, "")

        // Current-generation completion fills reverse orientation correctly
        let validApplied = model.completeCaptionTranslationForTesting(
            captionID: id1,
            generation: gen_rev2!,
            translatedText: "各位現場與線上觀眾大家好。"
        )
        XCTAssertTrue(validApplied)
        XCTAssertEqual(model.overlayHistoryForTesting.count, 1)
        XCTAssertEqual(model.overlayHistoryForTesting[0].id, caption1ID)
        XCTAssertEqual(model.overlayHistoryForTesting[0].sourceText, "各位現場與線上觀眾大家好。")
        XCTAssertEqual(model.overlayHistoryForTesting[0].translatedText, "Hello everyone in the audience and online.")
        XCTAssertEqual(model.transcriptEntriesForTesting.count, 2)
        XCTAssertEqual(model.transcriptEntriesForTesting[0].id, caption1ID)
        XCTAssertEqual(model.transcriptEntriesForTesting[0].sourceText, "Hello everyone in the audience and online.")
        XCTAssertEqual(model.transcriptEntriesForTesting[0].translatedText, "各位現場與線上觀眾大家好。")
        XCTAssertEqual(model.overlayState?.sourceText, "歡迎參加演講")
        XCTAssertEqual(model.overlayState?.translatedText, "Welcome to the talk")
    }

    @MainActor
    func testAppModelGenuineRepeatedUtterancesAppend() async {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-appmodel-repeated-utterance-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: SourceCatalogService()
        )

        let repeatedText = "Thank you very much."
        let id1 = UUID()
        let turn1 = RecognizedSentence(
            text: repeatedText,
            promotionSegmentID: id1,
            replacesPromotionSegmentID: nil,
            heardLanguageID: "en"
        )
        model.enqueueRecognizedSentenceForTesting(turn1, sourceLanguageID: "en", targetLanguageID: "en")
        await model.runCaptionQueueTurnForTesting()
        model.completeHeldCaptionForTesting()

        // Genuine second utterance with same phrase but new promotionID
        let id2 = UUID()
        let turn2 = RecognizedSentence(
            text: repeatedText,
            promotionSegmentID: id2,
            replacesPromotionSegmentID: nil,
            heardLanguageID: "en"
        )
        model.enqueueRecognizedSentenceForTesting(turn2, sourceLanguageID: "en", targetLanguageID: "en")
        await model.runCaptionQueueTurnForTesting()

        // Both distinct utterances are preserved in history and active display
        XCTAssertEqual(model.overlayHistoryForTesting.count, 1)
        XCTAssertEqual(model.overlayHistoryForTesting.first?.sourceText, repeatedText)
        XCTAssertEqual(model.displayedCaptionForTesting?.sourceText, repeatedText)
        XCTAssertEqual(model.transcriptEntriesForTesting.count, 2)
    }

    @MainActor
    func testAppModelReverseRoutingPureEnglishReplacementMaintainsInversionWithoutDuplicateHistory() async {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-appmodel-reverse-lifecycle-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: SourceCatalogService()
        )

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

        let id1 = UUID()
        let provisionalSentence = RecognizedSentence(
            text: "Hello everyone",
            promotionSegmentID: id1,
            replacesPromotionSegmentID: nil,
            heardLanguageID: "en",
            dualLaneEvidence: evidence
        )
        model.enqueueRecognizedSentenceForTesting(
            provisionalSentence,
            sourceLanguageID: "en",
            targetLanguageID: "zh-Hant",
            usesInverseGlossary: true
        )
        await model.runCaptionQueueTurnForTesting()

        XCTAssertEqual(model.displayedCaptionForTesting?.sourceText, "Hello everyone")
        XCTAssertEqual(model.overlayState?.sourceText, "")
        XCTAssertEqual(model.overlayState?.translatedText, "Hello everyone")
        XCTAssertEqual(model.overlayHistoryForTesting.count, 0)
        XCTAssertEqual(model.transcriptEntriesForTesting.count, 1)
        XCTAssertEqual(model.transcriptEntriesForTesting.first?.sourceText, "Hello everyone")
        XCTAssertEqual(model.transcriptEntriesForTesting.first?.translatedText, "")

        let fullSentence = RecognizedSentence(
            text: "Hello everyone welcome to the talk.",
            promotionSegmentID: id1,
            replacesPromotionSegmentID: id1,
            heardLanguageID: "en",
            dualLaneEvidence: evidence
        )
        model.enqueueRecognizedSentenceForTesting(
            fullSentence,
            sourceLanguageID: "en",
            targetLanguageID: "zh-Hant",
            usesInverseGlossary: true
        )
        await model.runCaptionQueueTurnForTesting()

        XCTAssertEqual(
            model.displayedCaptionForTesting?.sourceText,
            "Hello everyone welcome to the talk."
        )
        XCTAssertEqual(model.overlayState?.sourceText, "")
        XCTAssertEqual(model.overlayState?.translatedText, "Hello everyone welcome to the talk.")
        XCTAssertEqual(model.overlayHistoryForTesting.count, 0)
        XCTAssertEqual(model.transcriptEntriesForTesting.count, 1)
        XCTAssertEqual(model.transcriptEntriesForTesting.first?.sourceText, "Hello everyone welcome to the talk.")
        XCTAssertEqual(model.transcriptEntriesForTesting.first?.translatedText, "")

        // Complete translation
        let gen = model.currentTranslationGenerationForTesting(captionID: id1)
        XCTAssertNotNil(gen)
        let translated = model.completeCaptionTranslationForTesting(
            captionID: id1,
            generation: gen!,
            translatedText: "各位好歡迎來到這場演講。"
        )
        XCTAssertTrue(translated)

        // In reverse lane: top source pane is Chinese translation, bottom translated pane is heard English
        XCTAssertEqual(model.overlayState?.sourceText, "各位好歡迎來到這場演講。")
        XCTAssertEqual(model.overlayState?.translatedText, "Hello everyone welcome to the talk.")
        XCTAssertEqual(model.overlayHistoryForTesting.count, 0)
        XCTAssertEqual(model.transcriptEntriesForTesting.count, 1)
        XCTAssertEqual(model.transcriptEntriesForTesting.first?.sourceText, "Hello everyone welcome to the talk.")
        XCTAssertEqual(model.transcriptEntriesForTesting.first?.translatedText, "各位好歡迎來到這場演講。")
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

    @MainActor
    func testVADSilenceDoesNotCommitIncompleteClause() async {
        let session = LiveTranscriptionSession()
        var collected: [RecognizedSentence] = []
        session.installTranscriptHandlerForTesting { collected.append($0) }

        let range = CMTimeRange(
            start: CMTime(seconds: 0.0, preferredTimescale: 1000),
            duration: CMTime(seconds: 3.0, preferredTimescale: 1000)
        )

        session.processModernRecognitionTextForTesting(
            "Welcome to our first",
            isFinal: false,
            audioRange: range
        )
        await flushModernEmissions()
        session.backdateLastDraftTextChangeForTesting(secondsAgo: 1)
        session.forceVADCommitOnSilenceForTesting()
        await flushModernEmissions()

        XCTAssertTrue(collected.isEmpty)
    }

    @MainActor
    func testIncompleteDraftThenFinalEmitsEachTokenOnce() async {
        let session = LiveTranscriptionSession()
        var collected: [RecognizedSentence] = []
        session.installTranscriptHandlerForTesting { collected.append($0) }

        let range = CMTimeRange(
            start: CMTime(seconds: 1.0, preferredTimescale: 1000),
            duration: CMTime(seconds: 4.0, preferredTimescale: 1000)
        )
        let fullSentence = "Welcome to our first session."

        session.processModernRecognitionTextForTesting(
            "Welcome to our first",
            isFinal: false,
            audioRange: range
        )
        await flushModernEmissions()
        session.backdateLastDraftTextChangeForTesting(secondsAgo: 1)
        session.forceVADCommitOnSilenceForTesting()
        await flushModernEmissions()
        session.processModernRecognitionTextForTesting(fullSentence, isFinal: true, audioRange: range)
        await flushModernEmissions()

        XCTAssertEqual(collected.map(\.text), [fullSentence])

        let (model, settingsURL) = makeAppModel(prefix: "v2s-incomplete-then-final-once")
        defer { try? FileManager.default.removeItem(at: settingsURL) }
        await enqueueCollected(collected, into: model)

        XCTAssertEqual(model.displayedCaptionForTesting?.sourceText, fullSentence)
        XCTAssertEqual(model.transcriptEntriesForTesting.count, 1)
        XCTAssertEqual(model.overlayHistoryForTesting.count, 0)
        XCTAssertNotEqual(model.displayedCaptionForTesting?.sourceText, "session.")
    }

    @MainActor
    func testVADSilenceCommitsTerminatedSentence() async {
        let session = LiveTranscriptionSession()
        var collected: [RecognizedSentence] = []
        session.installTranscriptHandlerForTesting { collected.append($0) }

        let range = CMTimeRange(
            start: CMTime(seconds: 0.0, preferredTimescale: 1000),
            duration: CMTime(seconds: 2.0, preferredTimescale: 1000)
        )

        session.processModernRecognitionTextForTesting(
            "Hello everyone.",
            isFinal: false,
            audioRange: range
        )
        await flushModernEmissions()
        session.backdateLastDraftTextChangeForTesting(secondsAgo: 1)
        session.forceVADCommitOnSilenceForTesting()
        await flushModernEmissions()

        XCTAssertEqual(collected.map(\.text), ["Hello everyone."])
    }

    @MainActor
    private func flushModernEmissions() async {
        await Task.yield()
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    @MainActor
    private func makeAppModel(prefix: String) -> (AppModel, URL) {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString).json")
        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: SourceCatalogService()
        )
        return (model, settingsURL)
    }

    @MainActor
    private func enqueueCollected(_ sentences: [RecognizedSentence], into model: AppModel) async {
        for s in sentences {
            model.enqueueRecognizedSentenceForTesting(s, sourceLanguageID: "en", targetLanguageID: "en")
            await model.runCaptionQueueTurnForTesting()
        }
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
