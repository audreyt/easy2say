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

    @MainActor
    func testMacRendererKeepsCurrentCaptionFrameDuringPromotion() throws {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-live-caption-frame-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: SourceCatalogService()
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
