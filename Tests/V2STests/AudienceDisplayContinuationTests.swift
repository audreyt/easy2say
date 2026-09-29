import XCTest
@testable import v2s

/// What the audience display shows when captions look alike: rows follow the
/// producer's identities, so a genuine repeat or a lookalike neighbour keeps
/// its own row, and a correction under a caption's own ID revises that row.
final class AudienceDisplayContinuationTests: XCTestCase {

    private func committed(
        _ source: String,
        translated: String = "",
        promotionID: UUID,
        captionID: UUID,
        history: [OverlayHistoryEntry] = []
    ) -> OverlayPreviewState {
        var state = OverlayPreviewState(translatedText: translated, sourceText: source, sourceName: "Test")
        state.committedPromotionID = promotionID
        state.committedCaptionID = captionID
        state.history = history
        return state
    }

    private func withDraft(_ state: OverlayPreviewState, _ source: String, promotionID: UUID) -> OverlayPreviewState {
        var state = state
        state.draftPromotionID = promotionID
        state.draftSourceText = source
        state.draftSourceStablePrefixLength = source.count
        return state
    }

    private var empty: OverlayPreviewState {
        OverlayPreviewState(translatedText: "", sourceText: "", sourceName: "Test")
    }

    /// Saying the same thing twice is two utterances on the overlay, and on the
    /// audience display too.
    @MainActor
    func testRepeatedUtteranceUnderNewIdentityGetsItsOwnRow() {
        let presentationState = AudienceDisplayPresentationState()
        let firstCaptionID = UUID()

        presentationState.consume(committed("No.", translated: "不。", promotionID: UUID(), captionID: firstCaptionID))
        presentationState.consume(committed(
            "No.",
            translated: "不。",
            promotionID: UUID(),
            captionID: UUID(),
            history: [OverlayHistoryEntry(id: firstCaptionID, translatedText: "不。", sourceText: "No.")]
        ))

        assertAudienceSources(
            presentationState,
            preceding: "No.",
            current: "No.",
            message: "a genuine repeat must not fold into the previous row"
        )
    }

    /// A draft whose text merely looks like it could continue the row before it
    /// is still its own utterance.
    @MainActor
    func testLowercaseDraftAfterCommittedRowStaysSeparate() {
        let presentationState = AudienceDisplayPresentationState()
        let captionID = UUID()
        let first = committed("and then we left.", promotionID: UUID(), captionID: captionID)

        presentationState.consume(first)
        var second = withDraft(empty, "We came back", promotionID: UUID())
        second.history = [OverlayHistoryEntry(id: captionID, translatedText: "", sourceText: "and then we left.")]
        presentationState.consume(second)

        assertAudienceSources(presentationState, preceding: "and then we left.", current: "We came back")
    }

    /// A word-level correction of an archived caption, under that caption's
    /// own history ID, reaches its audience row with its new translation.
    @MainActor
    func testWordLevelRevisionOfArchivedCaptionUpdatesItsRow() {
        let presentationState = AudienceDisplayPresentationState()
        let captionID = UUID()

        presentationState.consume(committed(
            "I scream for you.",
            translated: "我為你尖叫。",
            promotionID: UUID(),
            captionID: captionID
        ))
        var revised = empty
        revised.history = [OverlayHistoryEntry(id: captionID, translatedText: "給你冰淇淋。", sourceText: "Ice cream for you.")]
        presentationState.consume(revised)

        assertAudienceSources(presentationState, preceding: nil, current: "Ice cream for you.")
        XCTAssertEqual(presentationState.liveCaptionPresentation.currentCaption?.translatedText, "給你冰淇淋。")
    }

    @MainActor
    func testIndependentUtterancesStillBecomeTwoRows() {
        let presentationState = AudienceDisplayPresentationState()
        let promotionID = UUID()
        var first = OverlayPreviewState(translatedText: "甲", sourceText: "A", sourceName: "Test")
        first.committedPromotionID = promotionID
        presentationState.consume(first)

        var second = withDraft(first, "B", promotionID: UUID())
        second.translatedText = ""
        presentationState.consume(second)

        assertAudienceSources(
            presentationState,
            preceding: "A",
            current: "B",
            message: "an unrelated draft must keep its own row below the committed utterance"
        )
    }

    @MainActor
    private func assertAudienceSources(
        _ presentationState: AudienceDisplayPresentationState,
        preceding: String?,
        current: String?,
        message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            presentationState.liveCaptionPresentation.precedingCommittedCaption?.sourceText,
            preceding,
            message.isEmpty ? "preceding source" : message,
            file: file,
            line: line
        )
        XCTAssertEqual(
            presentationState.liveCaptionPresentation.currentCaption?.sourceText,
            current,
            message.isEmpty ? "current source" : message,
            file: file,
            line: line
        )
    }
}
