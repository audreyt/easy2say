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
