import XCTest
@testable import v2s

final class CaptionPaneProjectionTests: XCTestCase {
    private func row(
        _ text: String,
        language: String = "zh-Hant",
        target: String = "en",
        stable: Int? = nil,
        translation: String = "",
        translationIsDraft: Bool = false
    ) -> CaptionRow {
        CaptionRow(
            id: CaptionRowID(sessionID: 1, ordinal: 0),
            languageID: language,
            targetLanguageID: target,
            text: text,
            stableLength: stable ?? text.count,
            isSealed: true,
            isFinal: true,
            translation: translation,
            translationIsDraft: translationIsDraft,
            speakerIndex: nil,
            createdMs: 0
        )
    }

    private let dual = CaptionPaneConfig(
        originalLanguageID: "zh-Hant", showsOriginal: true, showsTranslated: true
    )

    func testOriginalLanguageRowProjectsNormally() {
        let row = row("大家早安", language: "zh-Hant", target: "en",
                      translation: "Good morning", translationIsDraft: false)
        let texts = CaptionPaneProjection.paneTexts(for: row, config: dual)
        XCTAssertEqual(texts[.original]?.text, "大家早安")
        XCTAssertEqual(texts[.original]?.stableLength, 4)
        XCTAssertEqual(texts[.translated]?.text, "Good morning")
        XCTAssertEqual(texts[.translated]?.stableLength, 12)
        XCTAssertEqual(texts[.translated]?.isDraft, false)
    }

    func testDraftTranslationIsZeroStableAndFlagged() {
        let row = row("大家早安", translation: "Good", translationIsDraft: true)
        let texts = CaptionPaneProjection.paneTexts(for: row, config: dual)
        XCTAssertEqual(texts[.translated]?.stableLength, 0)
        XCTAssertEqual(texts[.translated]?.isDraft, true)
    }

    func testDualLaneEnglishRowSwapsPanes() {
        let row = row("Good morning.", language: "en", target: "zh-Hant",
                      translation: "大家早安", translationIsDraft: false)
        let texts = CaptionPaneProjection.paneTexts(for: row, config: dual)
        // Heard English sits in the translated pane; its zh translation in the
        // original pane.
        XCTAssertEqual(texts[.translated]?.text, "Good morning.")
        XCTAssertEqual(texts[.translated]?.isDraft, false)
        XCTAssertEqual(texts[.original]?.text, "大家早安")
    }

    func testNoTranslationMirrorsRowText() {
        let untranslated = row("大家早安", target: "")
        let texts = CaptionPaneProjection.paneTexts(for: untranslated, config: dual)
        XCTAssertEqual(texts[.translated]?.text, "大家早安")
        // And with target equal to its language.
        let selfTargeted = row("大家早安", target: "zh-Hant")
        XCTAssertEqual(
            CaptionPaneProjection.paneTexts(for: selfTargeted, config: dual)[.translated]?.text,
            "大家早安"
        )
    }

    func testTranslatedOnlyPaneFallsBackToRowText() {
        let row = row("大家早安", translation: "", translationIsDraft: true)
        let onlyTranslated = CaptionPaneConfig(
            originalLanguageID: "zh-Hant", showsOriginal: false, showsTranslated: true
        )
        let texts = CaptionPaneProjection.paneTexts(for: row, config: onlyTranslated)
        XCTAssertNil(texts[.original])
        XCTAssertEqual(texts[.translated]?.text, "大家早安")
        XCTAssertEqual(texts[.translated]?.stableLength, row.stableLength)
    }

    func testOnlyOriginalPaneEmitsNothingTranslated() {
        let row = row("大家早安", translation: "Good morning")
        let onlyOriginal = CaptionPaneConfig(
            originalLanguageID: "zh-Hant", showsOriginal: true, showsTranslated: false
        )
        let texts = CaptionPaneProjection.paneTexts(for: row, config: onlyOriginal)
        XCTAssertNil(texts[.translated])
        XCTAssertEqual(texts[.original]?.text, "大家早安")
    }

    func testLexicallyEqualPanesCollapseToLeading() {
        let texts: [CaptionPane: CaptionPaneText] = [
            .original: .init(text: "Good Morning.", stableLength: 13, isDraft: false),
            .translated: .init(text: "good morning", stableLength: 12, isDraft: false),
        ]
        let suppressed = CaptionPaneProjection.suppressingDuplicatePanes(
            texts, leadingPane: .translated
        )
        XCTAssertEqual(suppressed.count, 1)
        XCTAssertEqual(suppressed[.translated]?.text, "good morning")
        // Distinct panes are untouched.
        let distinct = CaptionPaneProjection.suppressingDuplicatePanes(
            [.original: .init(text: "大家早安", stableLength: 4, isDraft: false),
             .translated: .init(text: "Good morning", stableLength: 12, isDraft: false)],
            leadingPane: .original
        )
        XCTAssertEqual(distinct.count, 2)
    }
}
