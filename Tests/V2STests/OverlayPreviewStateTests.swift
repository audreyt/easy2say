import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import v2s

final class OverlayPreviewStateTests: XCTestCase {
    func testDraftTranslationIsOnlyReturnedForMatchingDraft() {
        let firstPromotionID = UUID()
        let secondPromotionID = UUID()
        var state = OverlayPreviewState(
            translatedText: "",
            sourceText: "",
            sourceName: "Test"
        )

        state.draftSourceText = "Change type is not at all."
        state.draftPromotionID = firstPromotionID
        state.setDraftTranslation(
            "Old translation",
            sourceText: "Change type is not at all.",
            promotionID: firstPromotionID
        )

        XCTAssertEqual(
            state.currentDraftTranslatedText(
                for: "Change type is not at all.",
                promotionID: firstPromotionID
            ),
            "Old translation"
        )
        XCTAssertNil(
            state.currentDraftTranslatedText(
                for: "Okay.",
                promotionID: secondPromotionID
            )
        )
    }

    func testMismatchedDraftTranslationIsCleared() {
        let firstPromotionID = UUID()
        let secondPromotionID = UUID()
        var state = OverlayPreviewState(
            translatedText: "",
            sourceText: "",
            sourceName: "Test"
        )

        state.setDraftTranslation(
            "Old translation",
            sourceText: "Change type is not at all.",
            promotionID: firstPromotionID
        )
        state.clearDraftTranslationIfMismatched(
            sourceText: "Okay.",
            promotionID: secondPromotionID
        )

        XCTAssertNil(state.draftTranslatedText)
        XCTAssertNil(state.draftTranslationSourceText)
        XCTAssertNil(state.draftTranslationPromotionID)
    }

    func testSamePromotionDraftTranslationStaysVisibleDuringSourceUpdate() {
        let promotionID = UUID()
        var state = OverlayPreviewState(
            translatedText: "",
            sourceText: "",
            sourceName: "Test"
        )

        state.setDraftTranslation(
            "Old translation",
            sourceText: "Change type",
            promotionID: promotionID
        )
        state.clearDraftTranslationIfMismatched(
            sourceText: "Change type is not at all.",
            promotionID: promotionID
        )

        XCTAssertEqual(
            state.visibleDraftTranslatedText(
                for: "Change type is not at all.",
                promotionID: promotionID
            ),
            "Old translation"
        )
        XCTAssertNil(
            state.currentDraftTranslatedText(
                for: "Change type is not at all.",
                promotionID: promotionID
            )
        )
    }

    func testNilPromotionDraftTranslationStillRequiresExactSourceMatch() {
        var state = OverlayPreviewState(
            translatedText: "",
            sourceText: "",
            sourceName: "Test"
        )

        state.setDraftTranslation(
            "Old translation",
            sourceText: "Change type",
            promotionID: nil
        )

        XCTAssertNil(
            state.visibleDraftTranslatedText(
                for: "Change type is not at all.",
                promotionID: nil
            )
        )
    }

    func testDraftPromotionOnlyChangesCurrentCaptionPhase() throws {
        let promotionID = UUID()
        let sourceText = "Live tentative caption"
        let translatedText = "即時暫定字幕"
        var draftState = OverlayPreviewState(
            translatedText: "",
            sourceText: "",
            sourceName: "Test"
        )
        draftState.draftSourceText = sourceText
        draftState.draftPromotionID = promotionID
        draftState.setDraftTranslation(
            translatedText,
            sourceText: sourceText,
            promotionID: promotionID
        )

        var committedState = OverlayPreviewState(
            translatedText: translatedText,
            sourceText: sourceText,
            sourceName: "Test"
        )
        committedState.captionEpoch = 1
        committedState.committedPromotionID = promotionID

        let tentative = try XCTUnwrap(
            draftState.liveCaptionPresentation.currentCaption
        )
        let committed = try XCTUnwrap(
            committedState.liveCaptionPresentation.currentCaption
        )

        XCTAssertEqual(tentative.id, committed.id)
        XCTAssertEqual(tentative.sourceText, committed.sourceText)
        XCTAssertEqual(tentative.translatedText, committed.translatedText)
        XCTAssertEqual(tentative.phase, .tentative)
        XCTAssertEqual(committed.phase, .committed)
    }

    func testPromotionOverlapCollapsesToCommittedCaption() throws {
        let promotionID = UUID()
        var state = OverlayPreviewState(
            translatedText: "已修正字幕。",
            sourceText: "Corrected caption.",
            sourceName: "Test"
        )
        state.captionEpoch = 1
        state.committedPromotionID = promotionID
        state.draftSourceText = "Tentative caption"
        state.draftPromotionID = promotionID
        state.setDraftTranslation(
            "暫定字幕",
            sourceText: "Tentative caption",
            promotionID: promotionID
        )

        let presentation = state.liveCaptionPresentation
        let current = try XCTUnwrap(presentation.currentCaption)

        XCTAssertNil(presentation.precedingCommittedCaption)
        XCTAssertEqual(current.id, .promotion(promotionID))
        XCTAssertEqual(current.phase, .committed)
        XCTAssertEqual(current.sourceText, "Corrected caption.")
        XCTAssertEqual(current.translatedText, "已修正字幕。")
        XCTAssertEqual(current.sourceAgedPrefixLength, 0)
        XCTAssertEqual(current.translatedAgedPrefixLength, 0)
    }

    func testDraftKeepsPreviousCommitOutsideCurrentCaptionSlot() throws {
        let committedPromotionID = UUID()
        let draftPromotionID = UUID()
        var state = OverlayPreviewState(
            translatedText: "Previous translation",
            sourceText: "Previous caption",
            sourceName: "Test"
        )
        state.committedPromotionID = committedPromotionID
        state.draftSourceText = "Current tentative caption"
        state.draftPromotionID = draftPromotionID

        let presentation = state.liveCaptionPresentation
        let preceding = try XCTUnwrap(presentation.precedingCommittedCaption)
        let current = try XCTUnwrap(presentation.currentCaption)

        XCTAssertEqual(preceding.id, .promotion(committedPromotionID))
        XCTAssertEqual(preceding.phase, .committed)
        XCTAssertEqual(preceding.sourceText, "Previous caption")
        XCTAssertEqual(current.id, .promotion(draftPromotionID))
        XCTAssertEqual(current.phase, .tentative)
        XCTAssertEqual(current.sourceText, "Current tentative caption")
    }

    func testSameAudioStartKeepsIndependentCommittedVisible() throws {
        let committedPromotionID = UUID()
        let draftPromotionID = UUID()
        var state = OverlayPreviewState(
            translatedText: "Committed fragment",
            sourceText: "Committed fragment",
            sourceName: "Test"
        )
        state.committedPromotionID = committedPromotionID
        state.committedAudioStartMs = 1_000
        state.draftSourceText = "Unrelated later hypothesis text"
        state.draftPromotionID = draftPromotionID
        state.draftAudioStartMs = 1_020

        let presentation = state.liveCaptionPresentation
        let preceding = try XCTUnwrap(presentation.precedingCommittedCaption)
        let current = try XCTUnwrap(presentation.currentCaption)

        XCTAssertEqual(preceding.sourceText, "Committed fragment")
        XCTAssertEqual(current.phase, .tentative)
        XCTAssertEqual(current.sourceText, "Unrelated later hypothesis text")
    }

    func testPartialContinuationCollapsesToExclusiveCurrentCaption() throws {
        let committedPromotionID = UUID()
        let draftPromotionID = UUID()
        var state = OverlayPreviewState(
            translatedText: "Hello everyone",
            sourceText: "Hello everyone",
            sourceName: "Test"
        )
        state.committedPromotionID = committedPromotionID
        state.draftSourceText = "Hello everyone, hello."
        state.draftPromotionID = draftPromotionID

        let presentation = state.liveCaptionPresentation
        let current = try XCTUnwrap(presentation.currentCaption)

        XCTAssertNil(presentation.precedingCommittedCaption)
        XCTAssertEqual(current.id, .promotion(draftPromotionID))
        XCTAssertEqual(current.phase, .tentative)
        XCTAssertEqual(current.sourceText, "Hello everyone, hello.")
    }

    func testSuffixFragmentJoinsIntoExclusiveCurrentCaption() throws {
        let committedPromotionID = UUID()
        let draftPromotionID = UUID()
        var state = OverlayPreviewState(
            translatedText: "Welcome to our first",
            sourceText: "Welcome to our first",
            sourceName: "Test"
        )
        state.committedPromotionID = committedPromotionID
        state.draftSourceText = "session."
        state.draftPromotionID = draftPromotionID

        let presentation = state.liveCaptionPresentation
        let current = try XCTUnwrap(presentation.currentCaption)

        XCTAssertNil(presentation.precedingCommittedCaption)
        XCTAssertEqual(current.sourceText, "Welcome to our first session.")
        XCTAssertEqual(current.phase, .tentative)
    }

    func testSameUtteranceEnglishContinuationRetainsChineseCommittedTranslationPrefix() throws {
        let committedPromotionID = UUID()
        let draftPromotionID = UUID()
        var state = OverlayPreviewState(
            translatedText: "歡迎來到",
            sourceText: "Welcome to our first",
            sourceName: "Test"
        )
        state.committedPromotionID = committedPromotionID
        state.draftSourceText = "session."
        state.draftPromotionID = draftPromotionID
        state.setDraftTranslation(
            "第一場會議。",
            sourceText: "session.",
            promotionID: draftPromotionID
        )

        let presentation = state.liveCaptionPresentation
        XCTAssertNil(presentation.precedingCommittedCaption)
        let display = try XCTUnwrap(presentation.displayCaption)
        XCTAssertEqual(display.sourceText, "Welcome to our first session.")
        XCTAssertEqual(display.translatedText, "歡迎來到第一場會議。")
        XCTAssertEqual(display.sourceAgedPrefixLength, 0)
        XCTAssertEqual(display.translatedAgedPrefixLength, 0)
        XCTAssertEqual(display.phase, .tentative)
    }

    func testSameUtteranceCumulativeSourceKeepsLatestIndependentTarget() throws {
        let committedPromotionID = UUID()
        let draftPromotionID = UUID()
        var state = OverlayPreviewState(
            translatedText: "歡迎來到",
            sourceText: "Welcome to our first",
            sourceName: "Test"
        )
        state.committedPromotionID = committedPromotionID
        state.draftSourceText = "Welcome to our first session."
        state.draftPromotionID = draftPromotionID
        state.setDraftTranslation(
            "第一場會議。",
            sourceText: "Welcome to our first session.",
            promotionID: draftPromotionID
        )

        let presentation = state.liveCaptionPresentation
        XCTAssertNil(presentation.precedingCommittedCaption)
        let display = try XCTUnwrap(presentation.displayCaption)
        XCTAssertEqual(display.sourceText, "Welcome to our first session.")
        XCTAssertEqual(display.translatedText, "第一場會議。")
        XCTAssertNotEqual(display.translatedText, "歡迎來到第一場會議。")
        XCTAssertEqual(display.sourceAgedPrefixLength, 0)
        XCTAssertEqual(display.translatedAgedPrefixLength, 0)
        XCTAssertEqual(display.phase, .tentative)
    }

    func testReplaySequenceNeverLayersOverlappingPartials() throws {
        var state = OverlayPreviewState(
            translatedText: "",
            sourceText: "",
            sourceName: "Test"
        )
        let steps: [(committed: String, draft: String)] = [
            ("", "Hello"),
            ("", "Hello everyone"),
            ("Hello everyone", "Hello everyone, hello."),
            ("Hello everyone, hello.", "Welcome to our first session."),
            ("Welcome to our first", "session."),
        ]

        for (committed, draft) in steps {
            state.sourceText = committed
            state.translatedText = committed
            state.committedPromotionID = committed.isEmpty ? nil : UUID()
            state.draftSourceText = draft.isEmpty ? nil : draft
            state.draftPromotionID = draft.isEmpty ? nil : UUID()

            let presentation = state.liveCaptionPresentation
            if let preceding = presentation.precedingCommittedCaption,
               let current = presentation.currentCaption {
                let relation = LiveCaptionReplay.relation(
                    committedSourceText: preceding.sourceText,
                    draftSourceText: current.sourceText
                )
                if case .sameUtterance = relation {
                    XCTFail("layered same utterance '\(preceding.sourceText)' + '\(current.sourceText)'")
                }
            }
        }
    }

    func testDraftTextRevisionKeepsPromotionIdentity() throws {
        let promotionID = UUID()
        var state = OverlayPreviewState(
            translatedText: "",
            sourceText: "",
            sourceName: "Test"
        )
        state.draftPromotionID = promotionID
        state.draftSourceText = "Tentative"
        let first = try XCTUnwrap(state.liveCaptionPresentation.currentCaption)

        state.draftSourceText = "Tentative text grew"
        let revised = try XCTUnwrap(state.liveCaptionPresentation.currentCaption)

        XCTAssertEqual(first.id, revised.id)
        XCTAssertEqual(revised.id, .promotion(promotionID))
        XCTAssertNotEqual(first.sourceText, revised.sourceText)
        XCTAssertEqual(first.phase, .tentative)
        XCTAssertEqual(revised.phase, .tentative)
    }

    func testDraftTranslationPromotesOnlyThePrefixThatSurvivesRevision() throws {
        let promotionID = UUID()
        var state = OverlayPreviewState(
            translatedText: "",
            sourceText: "",
            sourceName: "Test"
        )
        state.draftSourceText = "它可能有時候"
        state.draftPromotionID = promotionID

        state.setDraftTranslation(
            "sometimes on day zero",
            sourceText: "它可能有時候",
            promotionID: promotionID
        )
        let first = try XCTUnwrap(state.liveCaptionPresentation.currentCaption)
        XCTAssertEqual(first.translatedStableText, "")
        XCTAssertEqual(first.translatedMutableText, "sometimes on day zero")

        state.setDraftTranslation(
            "sometimes on day zero, as soon as",
            sourceText: "它可能有時候，day zero",
            promotionID: promotionID
        )
        let extended = try XCTUnwrap(state.liveCaptionPresentation.currentCaption)
        XCTAssertEqual(extended.translatedStableText, "sometimes on day zero")
        XCTAssertEqual(extended.translatedMutableText, ", as soon as")

        state.setDraftTranslation(
            "sometimes on day zero, once the model",
            sourceText: "它可能有時候，day zero，就是模型",
            promotionID: promotionID
        )
        let revised = try XCTUnwrap(state.liveCaptionPresentation.currentCaption)
        XCTAssertEqual(revised.translatedStableText, "sometimes on day zero, ")
        XCTAssertEqual(revised.translatedMutableText, "once the model")
    }

    func testCommonStablePrefixKeepsCJKAndRetreatsLatinWord() {
        XCTAssertEqual(
            LiveCaptionTextStability.commonStablePrefixLength(
                previous: "sometimes on day zero",
                current: "sometimes on day zero"
            ),
            "sometimes on day zero".count
        )
        XCTAssertEqual(
            LiveCaptionTextStability.commonStablePrefixLength(
                previous: "hello wor",
                current: "hello world extra"
            ),
            "hello ".count
        )
        XCTAssertEqual(
            LiveCaptionTextStability.commonStablePrefixLength(
                previous: "保留最近",
                current: "保留最近的字幕"
            ),
            "保留最近".count
        )
    }

    func testIndependentDraftJoinsOldAndNewWithPerLaneAgedPrefixes() throws {
        var state = OverlayPreviewState(
            translatedText: "Previous translation.",
            sourceText: "Hello everyone.",
            sourceName: "Test"
        )
        state.committedPromotionID = UUID()
        state.draftSourceText = "Welcome to our first session"
        state.draftSourceStablePrefixLength = "Welcome to our first ".count
        let draftPromotionID = UUID()
        state.draftPromotionID = draftPromotionID
        state.setDraftTranslation(
            "歡迎來到我們的第一場會議",
            sourceText: "Welcome to our first session",
            promotionID: draftPromotionID
        )
        state.draftTranslatedStablePrefixLength = "歡迎來到我們的".count

        let presentation = state.liveCaptionPresentation
        XCTAssertNotNil(presentation.precedingCommittedCaption)
        let display = try XCTUnwrap(presentation.displayCaption)

        XCTAssertEqual(display.sourceText, "Hello everyone.\nWelcome to our first session")
        XCTAssertEqual(
            display.translatedText,
            "Previous translation.\n歡迎來到我們的第一場會議"
        )
        XCTAssertEqual(display.sourceAgedPrefixLength, "Hello everyone.".count)
        XCTAssertEqual(display.translatedAgedPrefixLength, "Previous translation.".count)
        XCTAssertNotEqual(
            display.sourceAgedPrefixLength,
            display.translatedAgedPrefixLength
        )
        XCTAssertEqual(display.sourceMutableText, "session")
        XCTAssertEqual(display.translatedMutableText, "第一場會議")

        let sourceRuns = OverlayCaptionRuns(
            text: display.sourceText,
            agedPrefixLength: display.sourceAgedPrefixLength,
            stablePrefixLength: display.sourceStablePrefixLength
        )
        XCTAssertEqual(sourceRuns.aged, "Hello everyone.")
        XCTAssertEqual(sourceRuns.stable, "\nWelcome to our first ")
        XCTAssertEqual(sourceRuns.mutable, "session")

        let translatedRuns = OverlayCaptionRuns(
            text: display.translatedText,
            agedPrefixLength: display.translatedAgedPrefixLength,
            stablePrefixLength: display.translatedStablePrefixLength
        )
        XCTAssertEqual(translatedRuns.aged, "Previous translation.")
        XCTAssertEqual(translatedRuns.stable, "\n歡迎來到我們的")
        XCTAssertEqual(translatedRuns.mutable, "第一場會議")
    }

    func testIndependentDraftDoesNotRepeatAnUnchangedLane() throws {
        var state = OverlayPreviewState(
            translatedText: "UNCHANGED TRANSLATION",
            sourceText: "Previous source",
            sourceName: "Test"
        )
        state.committedPromotionID = UUID()
        let promotionID = UUID()
        state.draftPromotionID = promotionID
        state.draftSourceText = "Current unrelated source"
        state.setDraftTranslation(
            "UNCHANGED TRANSLATION",
            sourceText: "Current unrelated source",
            promotionID: promotionID
        )

        let display = try XCTUnwrap(state.liveCaptionPresentation.displayCaption)
        XCTAssertEqual(display.translatedText, "UNCHANGED TRANSLATION")
        XCTAssertEqual(display.translatedAgedPrefixLength, 0)
        XCTAssertEqual(display.sourceText, "Previous source\nCurrent unrelated source")
    }

    func testAudienceProjectionNeverDeduplicatesOnlyOneLanguageLane() throws {
        let firstHistoryID = UUID()
        let secondHistoryID = UUID()
        let sameSource = OverlayLiveCaptionPresentation(
            precedingCommittedCaption: .init(
                id: .promotion(firstHistoryID),
                phase: .committed,
                translatedText: "First translation",
                sourceText: "相同來源",
                representedHistoryEntryIDs: [firstHistoryID]
            ),
            currentCaption: .init(
                id: .promotion(secondHistoryID),
                phase: .committed,
                translatedText: "Second translation",
                sourceText: "相同來源",
                representedHistoryEntryIDs: [secondHistoryID]
            )
        )

        let overlaySameSource = try XCTUnwrap(sameSource.displayCaption)
        XCTAssertEqual(overlaySameSource.sourceText, "相同來源")
        XCTAssertEqual(
            overlaySameSource.translatedText,
            "First translation\nSecond translation"
        )

        let audienceSameSource = try XCTUnwrap(sameSource.audienceDisplayCaption)
        XCTAssertEqual(audienceSameSource.sourceText, "相同來源\n相同來源")
        XCTAssertEqual(
            audienceSameSource.translatedText,
            "First translation\nSecond translation"
        )
        XCTAssertEqual(
            audienceSameSource.representedHistoryEntryIDs,
            Set([firstHistoryID, secondHistoryID])
        )

        let sameTranslation = OverlayLiveCaptionPresentation(
            precedingCommittedCaption: .init(
                id: .promotion(firstHistoryID),
                phase: .committed,
                translatedText: "Same translation",
                sourceText: "First source",
                representedHistoryEntryIDs: [firstHistoryID]
            ),
            currentCaption: .init(
                id: .promotion(secondHistoryID),
                phase: .committed,
                translatedText: "Same translation",
                sourceText: "Second source",
                representedHistoryEntryIDs: [secondHistoryID]
            )
        )

        let overlaySameTranslation = try XCTUnwrap(sameTranslation.displayCaption)
        XCTAssertEqual(overlaySameTranslation.translatedText, "Same translation")
        XCTAssertEqual(
            overlaySameTranslation.sourceText,
            "First source\nSecond source"
        )

        let audienceSameTranslation = try XCTUnwrap(sameTranslation.audienceDisplayCaption)
        XCTAssertEqual(
            audienceSameTranslation.translatedText,
            "Same translation\nSame translation"
        )
        XCTAssertEqual(
            audienceSameTranslation.sourceText,
            "First source\nSecond source"
        )
    }

    func testAudienceProjectionReservesBothRowsWhenEitherSourceIsMissing() throws {
        let emptyRow = "\u{00A0}"
        let firstHistoryID = UUID()
        let secondHistoryID = UUID()
        let missingPrecedingSource = OverlayLiveCaptionPresentation(
            precedingCommittedCaption: .init(
                id: .promotion(firstHistoryID),
                phase: .committed,
                translatedText: "Unpaired older translation",
                sourceText: "",
                representedHistoryEntryIDs: [firstHistoryID]
            ),
            currentCaption: .init(
                id: .promotion(secondHistoryID),
                phase: .committed,
                translatedText: "Current translation",
                sourceText: "Current source",
                representedHistoryEntryIDs: [secondHistoryID]
            )
        )

        let current = try XCTUnwrap(missingPrecedingSource.audienceDisplayCaption)
        XCTAssertEqual(current.sourceText, "\(emptyRow)\nCurrent source")
        XCTAssertEqual(
            current.translatedText,
            "Unpaired older translation\nCurrent translation"
        )
        XCTAssertEqual(
            current.representedHistoryEntryIDs,
            Set([firstHistoryID, secondHistoryID])
        )

        let missingCurrentSource = OverlayLiveCaptionPresentation(
            precedingCommittedCaption: .init(
                id: .promotion(firstHistoryID),
                phase: .committed,
                translatedText: "Older translation",
                sourceText: "Older source",
                representedHistoryEntryIDs: [firstHistoryID]
            ),
            currentCaption: .init(
                id: .promotion(secondHistoryID),
                phase: .tentative,
                translatedText: "Newest translation without source",
                sourceText: "",
                representedHistoryEntryIDs: [secondHistoryID]
            )
        )

        let newest = try XCTUnwrap(missingCurrentSource.audienceDisplayCaption)
        XCTAssertEqual(newest.sourceText, "Older source\n\(emptyRow)")
        XCTAssertEqual(
            newest.translatedText,
            "Older translation\nNewest translation without source"
        )
        XCTAssertEqual(
            newest.representedHistoryEntryIDs,
            Set([firstHistoryID, secondHistoryID])
        )

        let onlyCurrent = OverlayLiveCaptionPresentation(
            precedingCommittedCaption: nil,
            currentCaption: .init(
                id: .promotion(secondHistoryID),
                phase: .tentative,
                translatedText: "",
                sourceText: "Only source",
                representedHistoryEntryIDs: [secondHistoryID]
            )
        )
        let single = try XCTUnwrap(onlyCurrent.audienceDisplayCaption)
        XCTAssertEqual(single.sourceText, "Only source")
        XCTAssertEqual(single.translatedText, "")
        XCTAssertEqual(single.representedHistoryEntryIDs, [secondHistoryID])
    }

    func testAudienceProjectionKeepsSourcePairWhenEitherTranslationIsPending() throws {
        let firstHistoryID = UUID()
        let secondHistoryID = UUID()
        let missingPrecedingTranslation = OverlayLiveCaptionPresentation(
            precedingCommittedCaption: .init(
                id: .promotion(firstHistoryID),
                phase: .committed,
                translatedText: "",
                sourceText: "First source",
                representedHistoryEntryIDs: [firstHistoryID]
            ),
            currentCaption: .init(
                id: .promotion(secondHistoryID),
                phase: .tentative,
                translatedText: "Second translation",
                sourceText: "Second source",
                representedHistoryEntryIDs: [secondHistoryID]
            )
        )

        let secondTranslation = try XCTUnwrap(
            missingPrecedingTranslation.audienceDisplayCaption
        )
        XCTAssertEqual(secondTranslation.sourceText, "First source\nSecond source")
        XCTAssertEqual(secondTranslation.translatedText, "\u{00A0}\nSecond translation")
        XCTAssertEqual(
            secondTranslation.representedHistoryEntryIDs,
            Set([firstHistoryID, secondHistoryID])
        )

        let missingCurrentTranslation = OverlayLiveCaptionPresentation(
            precedingCommittedCaption: .init(
                id: .promotion(firstHistoryID),
                phase: .committed,
                translatedText: "First translation",
                sourceText: "First source",
                representedHistoryEntryIDs: [firstHistoryID]
            ),
            currentCaption: .init(
                id: .promotion(secondHistoryID),
                phase: .tentative,
                translatedText: "",
                sourceText: "Second source",
                representedHistoryEntryIDs: [secondHistoryID]
            )
        )

        let firstTranslation = try XCTUnwrap(
            missingCurrentTranslation.audienceDisplayCaption
        )
        XCTAssertEqual(firstTranslation.sourceText, "First source\nSecond source")
        XCTAssertEqual(firstTranslation.translatedText, "First translation\n\u{00A0}")
        XCTAssertEqual(
            firstTranslation.representedHistoryEntryIDs,
            Set([firstHistoryID, secondHistoryID])
        )
    }

    @MainActor
    func testNativeAudienceProjectionMaintainsRowPairingAcrossDuplicateAndPendingLanes() throws {
        struct RenderCase {
            let name: String
            let presentation: OverlayLiveCaptionPresentation
            let sourceRows: [String]
            let translatedRows: [String]
        }

        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-audience-paired-projection-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }
        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: NullSourceCatalog()
        )
        model.subtitleDisplayMode = .both
        model.setOverlayStateForTesting(
            OverlayPreviewState(
                translatedText: "",
                sourceText: "",
                sourceName: "Test"
            )
        )

        let emptyRow = "\u{00A0}"
        let firstHistoryID = UUID()
        let secondHistoryID = UUID()
        let cases = [
            RenderCase(
                name: "same source, different translations",
                presentation: OverlayLiveCaptionPresentation(
                    precedingCommittedCaption: .init(
                        id: .promotion(firstHistoryID),
                        phase: .committed,
                        translatedText: "First translation",
                        sourceText: "相同來源",
                        representedHistoryEntryIDs: [firstHistoryID]
                    ),
                    currentCaption: .init(
                        id: .promotion(secondHistoryID),
                        phase: .committed,
                        translatedText: "Second translation",
                        sourceText: "相同來源",
                        representedHistoryEntryIDs: [secondHistoryID]
                    )
                ),
                sourceRows: ["相同來源", "相同來源"],
                translatedRows: ["First translation", "Second translation"]
            ),
            RenderCase(
                name: "first translation pending",
                presentation: OverlayLiveCaptionPresentation(
                    precedingCommittedCaption: .init(
                        id: .promotion(firstHistoryID),
                        phase: .committed,
                        translatedText: "",
                        sourceText: "First source",
                        representedHistoryEntryIDs: [firstHistoryID]
                    ),
                    currentCaption: .init(
                        id: .promotion(secondHistoryID),
                        phase: .tentative,
                        translatedText: "Second translation",
                        sourceText: "Second source",
                        representedHistoryEntryIDs: [secondHistoryID]
                    )
                ),
                sourceRows: ["First source", "Second source"],
                translatedRows: [emptyRow, "Second translation"]
            ),
            RenderCase(
                name: "second source pending",
                presentation: OverlayLiveCaptionPresentation(
                    precedingCommittedCaption: .init(
                        id: .promotion(firstHistoryID),
                        phase: .committed,
                        translatedText: "First translation",
                        sourceText: "First source",
                        representedHistoryEntryIDs: [firstHistoryID]
                    ),
                    currentCaption: .init(
                        id: .promotion(secondHistoryID),
                        phase: .tentative,
                        translatedText: "Second translation",
                        sourceText: "",
                        representedHistoryEntryIDs: [secondHistoryID]
                    )
                ),
                sourceRows: ["First source", emptyRow],
                translatedRows: ["First translation", "Second translation"]
            ),
        ]

        for testCase in cases {
            model.resetRenderedCaptionStatesForTesting()
            let hostingView = NSHostingView(
                rootView: CaptionFlowContentView(
                    model: model,
                    liveCaptionPresentationOverride: testCase.presentation,
                    liveCaptionProjection: .audienceUtterancePairs,
                    reservesColumnHeaderSpace: false,
                    showsHistory: false,
                    alignsTopDownCaptionsLeading: true,
                    animatesLiveCaptionLineEntrance: false,
                    stabilizesLiveCaptionLinePositions: true
                )
            )
            hostingView.frame = NSRect(x: 0, y: 0, width: 960, height: 540)
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.35))
            hostingView.layoutSubtreeIfNeeded()

            let rendered = try XCTUnwrap(
                model.renderedCaptionStatesForTesting.last,
                testCase.name
            )
            let sourceText = testCase.sourceRows.joined(separator: "\n")
            let translatedText = testCase.translatedRows.joined(separator: "\n")
            XCTAssertEqual(
                rendered.liveTexts,
                Set([sourceText, translatedText]),
                "\(testCase.name): native renderer lane text"
            )
            let renderedSourceRows = sourceText
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            let renderedTranslatedRows = translatedText
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            XCTAssertEqual(
                renderedSourceRows.count,
                renderedTranslatedRows.count,
                "\(testCase.name): source/translation row counts"
            )
            XCTAssertEqual(renderedSourceRows, testCase.sourceRows, testCase.name)
            XCTAssertEqual(renderedTranslatedRows, testCase.translatedRows, testCase.name)
            XCTAssertEqual(
                rendered.liveHistoryEntryIDs,
                Set([firstHistoryID, secondHistoryID]),
                "\(testCase.name): both row identities"
            )
        }
    }

    func testIndependentEmptyCurrentLaneKeepsRetainedTextUnaged() throws {
        var state = OverlayPreviewState(
            translatedText: "Previous translation.",
            sourceText: "Hello everyone.",
            sourceName: "Test"
        )
        state.committedPromotionID = UUID()
        state.draftSourceText = "Welcome to our first session"
        state.draftSourceStablePrefixLength = "Welcome to our first ".count
        state.draftPromotionID = UUID()

        let display = try XCTUnwrap(state.liveCaptionPresentation.displayCaption)
        XCTAssertEqual(display.sourceText, "Hello everyone.\nWelcome to our first session")
        XCTAssertEqual(display.sourceAgedPrefixLength, "Hello everyone.".count)
        XCTAssertEqual(display.translatedText, "Previous translation.")
        XCTAssertEqual(display.translatedAgedPrefixLength, 0)
        XCTAssertEqual(display.translatedStablePrefixLength, "Previous translation.".count)
        XCTAssertEqual(display.translatedMutableText, "")
    }

    func testSameUtteranceKeepsCommittedPrefixWhiteWhileTailRevises() throws {
        var state = OverlayPreviewState(
            translatedText: "Welcome to our first",
            sourceText: "Welcome to our first",
            sourceName: "Test"
        )
        state.committedPromotionID = UUID()
        state.draftSourceText = "first session is starting"
        state.draftSourceStablePrefixLength = "first ".count
        let draftPromotionID = UUID()
        state.draftPromotionID = draftPromotionID
        state.setDraftTranslation(
            "Welcome to our first session is starting",
            sourceText: "first session is starting",
            promotionID: draftPromotionID
        )
        state.draftTranslatedStablePrefixLength = "Welcome to our first ".count

        let presentation = state.liveCaptionPresentation
        XCTAssertNil(presentation.precedingCommittedCaption)
        let display = try XCTUnwrap(presentation.displayCaption)
        XCTAssertEqual(display.sourceText, "Welcome to our first session is starting")
        XCTAssertEqual(display.sourceStableText, "Welcome to our first ")
        XCTAssertEqual(display.sourceMutableText, "session is starting")
        XCTAssertEqual(display.translatedStableText, "Welcome to our first ")
        XCTAssertEqual(display.translatedMutableText, "session is starting")
        XCTAssertEqual(display.sourceAgedPrefixLength, 0)
        XCTAssertEqual(display.translatedAgedPrefixLength, 0)

        state.draftSourceText = "first session has started"
        let revised = try XCTUnwrap(state.liveCaptionPresentation.displayCaption)
        XCTAssertEqual(revised.sourceStableText, "Welcome to our first ")
        XCTAssertEqual(revised.sourceMutableText, "session has started")
        XCTAssertEqual(revised.sourceAgedPrefixLength, 0)
    }

    @MainActor
    func testMacRendererKeepsLiveWindowHeightAtTwoLinesDuringOverflow() throws {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-live-caption-window-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }
        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: NullSourceCatalog()
        )
        let hostingView = NSHostingView(
            rootView: CaptionFlowContentView(
                model: model,
                reservesColumnHeaderSpace: false
            )
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 520, height: 420)

        var shortState = OverlayPreviewState(
            translatedText: "",
            sourceText: "",
            sourceName: "Test"
        )
        shortState.draftSourceText = "Short live tail"
        shortState.draftPromotionID = UUID()
        model.setOverlayStateForTesting(shortState)
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        hostingView.layoutSubtreeIfNeeded()
        let shortFrame = try XCTUnwrap(model.liveCaptionFrameForTesting)

        model.resetLiveCaptionFramesForTesting()
        var overflowingState = shortState
        overflowingState.draftSourceText = Array(
            repeating: "the newest words keep replacing the oldest wrapped line",
            count: 8
        ).joined(separator: " ")
        model.setOverlayStateForTesting(overflowingState)
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        hostingView.layoutSubtreeIfNeeded()
        let overflowingFrame = try XCTUnwrap(model.liveCaptionFrameForTesting)
        let sourceFont = NSFont.systemFont(
            ofSize: CGFloat(model.overlayStyle.scaledSourceFontSize),
            weight: .regular
        )
        let translatedFont = NSFont.systemFont(
            ofSize: CGFloat(model.overlayStyle.scaledTranslatedFontSize),
            weight: .semibold
        )
        let sourceLineHeight = ceil(
            sourceFont.ascender - sourceFont.descender + sourceFont.leading
        )
        let translatedLineHeight = ceil(
            translatedFont.ascender - translatedFont.descender + translatedFont.leading
        )

        XCTAssertEqual(overflowingFrame.height, shortFrame.height, accuracy: 0.5)
        XCTAssertEqual(
            overflowingFrame.height,
            2.0 * sourceLineHeight
                + 2.0 * translatedLineHeight
                + CaptionFlowContentView.captionPairSpacing
                + CaptionFlowContentView.currentCaptionBottomInset,
            accuracy: 1.0
        )
    }

    @MainActor
    func testAudienceRendererAppliesIndependentTailUpdatesWithoutACommitDelay() throws {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-live-caption-cadence-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }
        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: NullSourceCatalog()
        )
        model.subtitleDisplayMode = .both

        let promotionID = UUID()
        let stableSource = "穩定來源："
        let stableTranslation = "stable translation: "
        var state = OverlayPreviewState(
            translatedText: "",
            sourceText: "",
            sourceName: "Reference replay"
        )
        state.draftPromotionID = promotionID
        state.draftSourceText = stableSource + "甲"
        state.draftSourceStablePrefixLength = stableSource.count
        state.setDraftTranslation(
            stableTranslation + "one",
            sourceText: state.draftSourceText ?? "",
            promotionID: promotionID
        )
        state.draftTranslatedStablePrefixLength = stableTranslation.count

        let presentationState = AudienceDisplayPresentationState()
        let hostingView = NSHostingView(
            rootView: AudienceDisplayView(
                model: model,
                presentationState: presentationState,
                onExit: {}
            )
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 960, height: 540)

        var renderedFrames: [Data] = []
        for (index, update) in [
            (sourceTail: "甲", translatedTail: "one"),
            (sourceTail: "甲乙丙", translatedTail: "one"),
            (sourceTail: "甲乙丙", translatedTail: "one two three"),
        ].enumerated() {
            state.draftSourceText = stableSource + update.sourceTail
            state.draftSourceStablePrefixLength = stableSource.count
            if index == 2 {
                state.setDraftTranslation(
                    stableTranslation + update.translatedTail,
                    sourceText: state.draftSourceText ?? "",
                    promotionID: promotionID
                )
                state.draftTranslatedStablePrefixLength = stableTranslation.count
            }
            model.setOverlayStateForTesting(state)
            presentationState.consume(state)
            RunLoop.main.run(until: Date().addingTimeInterval(0.08))
            hostingView.layoutSubtreeIfNeeded()
            let bitmap = try renderBitmap(
                hostingView,
                snapshotName: "easy2say-native-update-\(index).png"
            )
            renderedFrames.append(
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            )
        }

        XCTAssertNotEqual(renderedFrames[0], renderedFrames[1], "source append was not painted")
        XCTAssertNotEqual(renderedFrames[1], renderedFrames[2], "translation append was not painted")
    }

    func testCaptionRunsPaintAchromaticBaseRGBWithActiveAlphaOneAndMutableAlpha() {
        let base = OverlayColor(red: 0.91, green: 0.40, blue: 0.18, alpha: 1)
        let runs = OverlayCaptionRuns(
            text: "STABLEtail",
            agedPrefixLength: 0,
            stablePrefixLength: 6
        )
        XCTAssertEqual(runs.aged, "")
        XCTAssertEqual(runs.stable, "STABLE")
        XCTAssertEqual(runs.mutable, "tail")

        let colors = captionRunColors(runs.attributedString(baseColor: base.color))
        XCTAssertEqual(colors.count, 2)
        XCTAssertEqual(colors[0].text, "STABLE")
        assertCaptionColor(colors[0].color, matchesBase: base, alpha: 1)
        XCTAssertEqual(colors[1].text, "tail")
        assertCaptionColor(colors[1].color, matchesBase: base, alpha: 0.45)
    }

    func testCaptionRunsPaintAgedPrefixAtAgedOpacity() {
        let base = OverlayColor(red: 0.91, green: 0.40, blue: 0.18, alpha: 1)
        let runs = OverlayCaptionRuns(
            text: "OLD\nNEWtail",
            agedPrefixLength: 3,
            stablePrefixLength: 7
        )
        XCTAssertEqual(runs.aged, "OLD")
        XCTAssertEqual(runs.stable, "\nNEW")
        XCTAssertEqual(runs.mutable, "tail")

        let colors = captionRunColors(runs.attributedString(baseColor: base.color))
        XCTAssertEqual(colors.count, 3)
        XCTAssertEqual(colors[0].text, "OLD")
        assertCaptionColor(colors[0].color, matchesBase: base, alpha: 0.52)
        XCTAssertEqual(colors[1].text, "\nNEW")
        assertCaptionColor(colors[1].color, matchesBase: base, alpha: 1)
        XCTAssertEqual(colors[2].text, "tail")
        assertCaptionColor(colors[2].color, matchesBase: base, alpha: 0.45)
    }

    func testCaptionRunsPaintTranslationMutableTailAtMutableOpacity() throws {
        let base = OverlayColor.defaultSubtitle
        let text = "sometimes, uh, on day zero, as soon as"
        let runs = OverlayCaptionRuns(
            text: text,
            agedPrefixLength: 0,
            stablePrefixLength: "sometimes, uh, on day zero, ".count
        )
        XCTAssertEqual(runs.mutable, "as soon as")

        let colors = captionRunColors(runs.attributedString(baseColor: base.color))
        XCTAssertEqual(colors.last?.text, "as soon as")
        let mutableColor = try XCTUnwrap(colors.last?.color)
        assertCaptionColor(
            mutableColor,
            matchesBase: base,
            alpha: OverlayCaptionRuns.mutableOpacity
        )
    }

    @MainActor
    func testMacRendererKeepsCurrentCaptionFrameDuringPromotion() throws {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-live-caption-frame-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: NullSourceCatalog()
        )
        model.subtitleDisplayMode = .both

        let promotionID = UUID()
        let precedingPromotionID = UUID()
        let precedingHistoryID = UUID()
        var draftState = OverlayPreviewState(
            translatedText: "先前字幕",
            sourceText: "Previous caption",
            sourceName: "Test"
        )
        draftState.captionEpoch = 1
        draftState.committedPromotionID = precedingPromotionID
        draftState.draftSourceText = "Stable live caption"
        draftState.draftPromotionID = promotionID
        draftState.setDraftTranslation(
            "穩定即時字幕",
            sourceText: "Stable live caption",
            promotionID: promotionID
        )

        var committedState = OverlayPreviewState(
            translatedText: "穩定即時字幕。",
            sourceText: "Stable live caption.",
            sourceName: "Test"
        )
        committedState.captionEpoch = 2
        committedState.committedPromotionID = promotionID
        committedState.history = [
            OverlayHistoryEntry(
                id: precedingHistoryID,
                translatedText: "先前字幕",
                sourceText: "Previous caption"
            )
        ]

        let hostingView = NSHostingView(
            rootView: CaptionFlowContentView(
                model: model,
                reservesColumnHeaderSpace: false
            )
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 900, height: 420)

        model.setOverlayStateForTesting(draftState)
        RunLoop.main.run(until: Date().addingTimeInterval(0.45))
        hostingView.layoutSubtreeIfNeeded()
        let tentativeFrame = try XCTUnwrap(model.liveCaptionFrameForTesting)
        XCTAssertFalse(tentativeFrame.isEmpty)

        model.resetLiveCaptionFramesForTesting()
        model.setOverlayStateForTesting(committedState)
        RunLoop.main.run(until: Date().addingTimeInterval(0.65))
        hostingView.layoutSubtreeIfNeeded()

        let committedFrame = try XCTUnwrap(model.liveCaptionFrameForTesting)
        assertFrame(committedFrame, equals: tentativeFrame)
        for observedFrame in model.liveCaptionFramesForTesting {
            assertFrame(observedFrame, equals: tentativeFrame)
        }
    }

    @MainActor
    func testMacRendererPaintsCaptionRolloverAtomically() throws {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-caption-rollover-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: NullSourceCatalog()
        )
        model.subtitleDisplayMode = .both

        let previousPromotionID = UUID()
        var previousState = OverlayPreviewState(
            translatedText: "PREVIOUS TRANSLATION",
            sourceText: "PREVIOUS SOURCE",
            sourceName: "Test"
        )
        previousState.captionEpoch = 1
        previousState.committedPromotionID = previousPromotionID
        model.setOverlayStateForTesting(previousState)

        let hostingView = NSHostingView(
            rootView: CaptionFlowContentView(
                model: model,
                reservesColumnHeaderSpace: false
            )
            .background(Color.black)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 900, height: 420)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.setFrameOrigin(NSPoint(x: -2_000, y: -2_000))
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        RunLoop.main.run(until: Date().addingTimeInterval(0.45))
        let previousBitmap = try renderBitmap(
            hostingView,
            snapshotName: "easy2say-native-rollover-previous.png"
        )
        let previousPixels = try XCTUnwrap(
            previousBitmap.representation(using: .png, properties: [:])
        )

        let currentPromotionID = UUID()
        var currentState = OverlayPreviewState(
            translatedText: "",
            sourceText: "",
            sourceName: "Test"
        )
        currentState.captionEpoch = 2
        currentState.history = [
            OverlayHistoryEntry(
                translatedText: "PREVIOUS TRANSLATION",
                sourceText: "PREVIOUS SOURCE"
            )
        ]
        currentState.draftPromotionID = currentPromotionID
        currentState.draftSourceText = "CURRENT SOURCE"
        currentState.setDraftTranslation(
            "CURRENT TRANSLATION",
            sourceText: "CURRENT SOURCE",
            promotionID: currentPromotionID
        )

        model.setOverlayStateForTesting(currentState)
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        let earlyBitmap = try renderBitmap(
            hostingView,
            snapshotName: "easy2say-native-rollover-early.png"
        )
        let earlyPixels = try XCTUnwrap(
            earlyBitmap.representation(using: .png, properties: [:])
        )
        let rowBands = brightPixelRowBands(in: earlyBitmap)
        XCTAssertEqual(rowBands.count, 4)
        if rowBands.count == 4 {
            let historyLaneGap = rowBands[1].lowerBound - rowBands[0].upperBound - 1
            let liveLaneGap = rowBands[3].lowerBound - rowBands[2].upperBound - 1
            XCTAssertLessThanOrEqual(
                liveLaneGap,
                historyLaneGap + 4,
                "single-line live translation and source lanes must not reserve an empty text row"
            )
        }

        RunLoop.main.run(until: Date().addingTimeInterval(0.45))
        let settledBitmap = try renderBitmap(
            hostingView,
            snapshotName: "easy2say-native-rollover-settled.png"
        )
        let settledPixels = try XCTUnwrap(
            settledBitmap.representation(using: .png, properties: [:])
        )

        XCTAssertNotEqual(earlyPixels, previousPixels, "rollover update was not painted")
        XCTAssertEqual(
            earlyPixels,
            settledPixels,
            "caption rollover painted an intermediate crossfade frame"
        )
    }

    @MainActor
    func testMacRendererNeverShowsArchivedCaptionBesideItsStaleLiveCopy() throws {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-caption-exclusive-rollover-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: NullSourceCatalog()
        )
        model.subtitleDisplayMode = .both

        let previousPromotionID = UUID()
        let currentPromotionID = UUID()
        let previousHistoryID = UUID()
        let previousTranslation = "ARCHIVED TRANSLATION"
        let previousSource = "ARCHIVED SOURCE"
        let currentTranslation = "CURRENT TRANSLATION"
        let currentSource = "CURRENT SOURCE"

        var previousState = OverlayPreviewState(
            translatedText: previousTranslation,
            sourceText: previousSource,
            sourceName: "Test"
        )
        previousState.captionEpoch = 1
        previousState.committedPromotionID = previousPromotionID
        previousState.committedCaptionID = previousHistoryID
        previousState.draftPromotionID = currentPromotionID
        previousState.draftSourceText = currentSource
        previousState.setDraftTranslation(
            currentTranslation,
            sourceText: currentSource,
            promotionID: currentPromotionID
        )

        var currentState = OverlayPreviewState(
            translatedText: currentTranslation,
            sourceText: currentSource,
            sourceName: "Test"
        )
        currentState.captionEpoch = 2
        currentState.committedPromotionID = currentPromotionID
        currentState.history = [
            OverlayHistoryEntry(
                id: previousHistoryID,
                translatedText: previousTranslation,
                sourceText: previousSource
            )
        ]

        let hostingView = NSHostingView(
            rootView: CaptionFlowContentView(
                model: model,
                reservesColumnHeaderSpace: false
            )
            .background(Color.black)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 900, height: 420)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.setFrameOrigin(NSPoint(x: -2_000, y: -2_000))
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        model.setOverlayStateForTesting(previousState)
        RunLoop.main.run(until: Date().addingTimeInterval(0.45))
        model.resetRenderedCaptionStatesForTesting()

        model.setOverlayStateForTesting(currentState)
        RunLoop.main.run(until: Date().addingTimeInterval(0.65))

        let states = model.renderedCaptionStatesForTesting
        XCTAssertFalse(states.isEmpty)
        XCTAssertTrue(states.last?.historyEntryIDs.contains(previousHistoryID) == true)
        XCTAssertFalse(
            states.contains { state in
                state.historyEntryIDs.contains(previousHistoryID)
                    && state.liveHistoryEntryIDs.contains(previousHistoryID)
            },
            "one caption identity must never occupy the live and history layers together"
        )
        XCTAssertFalse(
            states.contains { state in
                guard state.historyEntryIDs.contains(previousHistoryID) else { return false }
                return state.liveTexts.contains { liveText in
                    liveText
                        .split(separator: "\n")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .contains(previousTranslation)
                        || liveText
                            .split(separator: "\n")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .contains(previousSource)
                }
            },
            "an archived caption must wait until its stale live copy has left the visible lane"
        )
    }

    @MainActor
    func testMacRendererPaintsIdenticalTranslationAndSourceOnlyOnce() throws {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-caption-identical-lanes-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: NullSourceCatalog()
        )
        model.subtitleDisplayMode = .both
        model.setOverlayStateForTesting(
            OverlayPreviewState(
                translatedText: "IDENTICAL CAPTION",
                sourceText: "IDENTICAL CAPTION",
                sourceName: "Test"
            )
        )

        let hostingView = NSHostingView(
            rootView: CaptionFlowContentView(
                model: model,
                reservesColumnHeaderSpace: false
            )
            .background(Color.black)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 900, height: 420)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.setFrameOrigin(NSPoint(x: -2_000, y: -2_000))
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        RunLoop.main.run(until: Date().addingTimeInterval(0.45))
        let bitmap = try renderBitmap(
            hostingView,
            snapshotName: "easy2say-native-identical-lanes.png"
        )
        XCTAssertEqual(
            brightPixelRowBands(in: bitmap).count,
            1,
            "identical translation and source lanes must share one visual row"
        )
    }

    @MainActor
    func testMacRendererRetainsDistinctRepeatedHistoryEntries() throws {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-caption-identical-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: NullSourceCatalog()
        )
        model.subtitleDisplayMode = .both

        let olderID = UUID()
        let newerID = UUID()
        var state = OverlayPreviewState(
            translatedText: "CURRENT TRANSLATION",
            sourceText: "CURRENT SOURCE",
            sourceName: "Test"
        )
        state.history = [
            OverlayHistoryEntry(
                id: olderID,
                translatedText: "REPEATED TRANSLATION",
                sourceText: "REPEATED SOURCE"
            ),
            OverlayHistoryEntry(
                id: newerID,
                translatedText: "REPEATED TRANSLATION",
                sourceText: "REPEATED SOURCE"
            )
        ]
        model.setOverlayStateForTesting(state)

        let hostingView = NSHostingView(
            rootView: CaptionFlowContentView(
                model: model,
                reservesColumnHeaderSpace: false
            )
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 900, height: 420)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.setFrameOrigin(NSPoint(x: -2_000, y: -2_000))
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        RunLoop.main.run(until: Date().addingTimeInterval(0.45))

        let renderedIDs = try XCTUnwrap(model.renderedCaptionStatesForTesting.last).historyEntryIDs
        XCTAssertTrue(renderedIDs.contains(olderID))
        XCTAssertTrue(renderedIDs.contains(newerID))
        XCTAssertEqual(model.overlayHistoryForTesting.map(\.id), [olderID, newerID])
    }

    @MainActor
    func testAudienceTopDownCaptionStartsAtLeadingEdge() throws {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-audience-leading-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: NullSourceCatalog()
        )
        model.subtitleDisplayMode = .originalOnly
        model.overlayStyle.captionLayout = .topDown
        model.setOverlayStateForTesting(
            OverlayPreviewState(
                translatedText: "",
                sourceText: "FULL SCREEN LEADING EDGE",
                sourceName: "Test"
            )
        )

        let hostingView = NSHostingView(
            rootView: AudienceDisplayView(
                model: model,
                presentationState: AudienceDisplayPresentationState(
                    initialOverlayState: model.overlayState
                ),
                onExit: {}
            )
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 960, height: 540)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.setFrameOrigin(NSPoint(x: -2_000, y: -2_000))
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        let bitmap = try renderBitmap(
            hostingView,
            snapshotName: "easy2say-audience-leading.png"
        )
        let glyphBounds = try XCTUnwrap(brightPixelBounds(in: bitmap))

        XCTAssertLessThan(
            glyphBounds.minX,
            hostingView.bounds.width * 0.2,
            "top-down audience captions must start at the content's leading edge"
        )
    }

    @MainActor
    func testAudienceLineAppendHasNoAnimatedIntermediatePosition() throws {
        let presentationState = AudienceDisplayPresentationState()
        try assertLineAppendHasNoAnimatedIntermediatePosition(
            snapshotPrefix: "easy2say-audience",
            consumeOverlayState: { presentationState.consume($0) }
        ) { model in
            AnyView(
                AudienceDisplayView(
                    model: model,
                    presentationState: presentationState,
                    onExit: {}
                )
                    .background(Color.black)
            )
        }
    }

    @MainActor
    func testPresenterOverlayLineAppendKeepsExistingGlyphsFixed() throws {
        try assertLineAppendHasNoAnimatedIntermediatePosition(
            snapshotPrefix: "easy2say-overlay",
            history: [
                OverlayHistoryEntry(
                    translatedText: "",
                    sourceText: "Past"
                ),
                OverlayHistoryEntry(
                    translatedText: "",
                    sourceText: "Done"
                )
            ]
        ) { model in
            model.updateOverlayStyle { style in
                style.backgroundOpacity = 0
            }
            return AnyView(
                OverlayView(
                    model: model,
                    interactionState: OverlayInteractionState()
                )
                .background(Color.black)
            )
        }
    }

    @MainActor
    private func assertLineAppendHasNoAnimatedIntermediatePosition(
        snapshotPrefix: String,
        history: [OverlayHistoryEntry] = [],
        consumeOverlayState: (OverlayPreviewState?) -> Void = { _ in },
        makeRootView: (AppModel) -> AnyView
    ) throws {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-line-stability-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: NullSourceCatalog()
        )
        model.subtitleDisplayMode = .originalOnly
        model.overlayStyle.captionLayout = .topDown

        let promotionID = UUID()
        let initialText = "Stable caption anchor"
        var state = OverlayPreviewState(
            translatedText: "",
            sourceText: "",
            sourceName: "Test"
        )
        state.history = history
        state.draftPromotionID = promotionID
        state.draftSourceText = initialText
        state.draftSourceStablePrefixLength = initialText.count
        model.setOverlayStateForTesting(state)
        consumeOverlayState(state)

        let hostingView = NSHostingView(rootView: makeRootView(model))
        hostingView.frame = NSRect(x: 0, y: 0, width: 960, height: 540)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.setFrameOrigin(NSPoint(x: -2_000, y: -2_000))
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        let initialBitmap = try renderBitmap(
            hostingView,
            snapshotName: "\(snapshotPrefix)-stable-initial.png"
        )
        let initialBounds = try XCTUnwrap(brightPixelBounds(in: initialBitmap))
        let initialPrefixPixels = brightPixelCoordinates(
            in: initialBitmap,
            within: initialBounds
        )
        XCTAssertFalse(initialPrefixPixels.isEmpty)

        func assertStableIncrement(
            _ updatedText: String,
            snapshotStem: String,
            preservesPrefixGlyphs: Bool = true
        ) throws -> CGRect {
            state.draftSourceText = updatedText
            model.setOverlayStateForTesting(state)
            consumeOverlayState(state)

            RunLoop.main.run(until: Date().addingTimeInterval(0.08))
            let earlyBitmap = try renderBitmap(
                hostingView,
                snapshotName: "\(snapshotStem)-early.png"
            )
            let earlyPixels = try XCTUnwrap(
                earlyBitmap.representation(using: .png, properties: [:])
            )
            let earlyBounds = try XCTUnwrap(brightPixelBounds(in: earlyBitmap))
            if preservesPrefixGlyphs {
                XCTAssertEqual(
                    brightPixelCoordinates(in: earlyBitmap, within: initialBounds),
                    initialPrefixPixels,
                    "unchanged prefix glyphs moved during \(snapshotStem)"
                )
            }

            RunLoop.main.run(until: Date().addingTimeInterval(0.35))
            let settledBitmap = try renderBitmap(
                hostingView,
                snapshotName: "\(snapshotStem)-settled.png"
            )
            let settledPixels = try XCTUnwrap(
                settledBitmap.representation(using: .png, properties: [:])
            )
            XCTAssertEqual(
                earlyPixels,
                settledPixels,
                "captions moved after \(snapshotStem) was painted"
            )
            return earlyBounds
        }

        let sameLineBounds = try assertStableIncrement(
            initialText + " stays",
            snapshotStem: "\(snapshotPrefix)-stable-same-line"
        )
        XCTAssertLessThan(
            sameLineBounds.height,
            initialBounds.height * 1.5,
            "the first increment must remain on the existing visual line"
        )

        let wrappedText = initialText
            + String(repeating: " keeps every existing line fixed", count: 2)
        let wrappedBounds = try assertStableIncrement(
            wrappedText,
            snapshotStem: "\(snapshotPrefix)-stable-wrap"
        )
        XCTAssertGreaterThan(
            wrappedBounds.height - sameLineBounds.height,
            20,
            "the second increment must exercise a real one-line to two-line wrap"
        )

        let extendedBounds = try assertStableIncrement(
            wrappedText + " now",
            snapshotStem: "\(snapshotPrefix)-stable-second-line"
        )
        XCTAssertGreaterThan(
            extendedBounds.height - sameLineBounds.height,
            20,
            "the third increment must continue revising the second visual line"
        )
        XCTAssertEqual(
            extendedBounds.height,
            wrappedBounds.height,
            accuracy: 1.0,
            "extending the second line must not create a new vertical layout"
        )

        let overflowBounds = try assertStableIncrement(
            wrappedText + String(repeating: " while rollover stays atomic", count: 6),
            snapshotStem: "\(snapshotPrefix)-stable-rollover",
            preservesPrefixGlyphs: false
        )
        XCTAssertGreaterThan(
            overflowBounds.height - sameLineBounds.height,
            20,
            "overflow must leave the newest two visual lines visible"
        )
        XCTAssertLessThanOrEqual(
            overflowBounds.height,
            max(wrappedBounds.height, extendedBounds.height) + 8,
            "overflow must remain clipped to the same two-line viewport"
        )
    }

    private func brightPixelBounds(in bitmap: NSBitmapImageRep) -> CGRect? {
        var minX = bitmap.pixelsWide
        var minY = bitmap.pixelsHigh
        var maxX = -1
        var maxY = -1

        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                let brightness = max(
                    color.redComponent,
                    max(color.greenComponent, color.blueComponent)
                )
                guard brightness > 0.12 else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX + 1,
            height: maxY - minY + 1
        )
    }

    private func brightPixelRowBands(in bitmap: NSBitmapImageRep) -> [ClosedRange<Int>] {
        var brightRows: [Int] = []
        for y in 0..<bitmap.pixelsHigh {
            let isBright = (0..<bitmap.pixelsWide).contains { x in
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    return false
                }
                return max(
                    color.redComponent,
                    max(color.greenComponent, color.blueComponent)
                ) > 0.12
            }
            if isBright {
                brightRows.append(y)
            }
        }

        guard let first = brightRows.first else { return [] }
        var result: [ClosedRange<Int>] = []
        var lowerBound = first
        var previous = first
        for row in brightRows.dropFirst() {
            if row > previous + 1 {
                result.append(lowerBound...previous)
                lowerBound = row
            }
            previous = row
        }
        result.append(lowerBound...previous)
        return result
    }

    private func brightPixelCoordinates(
        in bitmap: NSBitmapImageRep,
        within bounds: CGRect
    ) -> Set<Int> {
        let minX = max(0, Int(bounds.minX.rounded(.down)))
        let minY = max(0, Int(bounds.minY.rounded(.down)))
        let maxX = min(bitmap.pixelsWide - 1, Int(bounds.maxX.rounded(.up)) - 1)
        let maxY = min(bitmap.pixelsHigh - 1, Int(bounds.maxY.rounded(.up)) - 1)
        guard minX <= maxX, minY <= maxY else { return [] }

        var coordinates: Set<Int> = []
        for y in minY...maxY {
            for x in minX...maxX {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                let brightness = max(
                    color.redComponent,
                    max(color.greenComponent, color.blueComponent)
                )
                if brightness > 0.12 {
                    coordinates.insert(y * bitmap.pixelsWide + x)
                }
            }
        }
        return coordinates
    }

    @MainActor
    private func renderBitmap(
        _ view: NSView,
        snapshotName: String
    ) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)

        if let directory = ProcessInfo.processInfo.environment["EASY2SAY_NATIVE_SNAPSHOT_DIR"],
           directory.isEmpty == false {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(snapshotName)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: url)
        }
        return bitmap
    }

    private func captionRunColors(
        _ attributed: AttributedString
    ) -> [(text: String, color: OverlayColor)] {
        var result: [(text: String, color: OverlayColor)] = []
        for run in attributed.runs {
            let text = String(attributed[run.range].characters)
            guard text.isEmpty == false else { continue }
            guard let color = attributed[run.range].foregroundColor else { continue }
            result.append((text, OverlayColor(color: color)))
        }
        return result
    }

    private func assertCaptionColor(
        _ actual: OverlayColor,
        matchesBase base: OverlayColor,
        alpha: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.red, base.red, accuracy: 0.03, file: file, line: line)
        XCTAssertEqual(actual.green, base.green, accuracy: 0.03, file: file, line: line)
        XCTAssertEqual(actual.blue, base.blue, accuracy: 0.03, file: file, line: line)
        XCTAssertEqual(actual.alpha, alpha, accuracy: 0.03, file: file, line: line)
    }

    private func assertFrame(
        _ actual: CGRect,
        equals expected: CGRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.5, file: file, line: line)
    }
}

private struct NullSourceCatalog: SourceCatalogProviding {
    func loadSnapshot() -> SourceCatalogSnapshot {
        SourceCatalogSnapshot(applications: [], microphones: [])
    }
}
