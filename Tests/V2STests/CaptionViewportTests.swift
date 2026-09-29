import XCTest
@testable import v2s

final class CaptionViewportTests: XCTestCase {
    private func row(
        _ ordinal: Int,
        text: String,
        translation: String = "",
        draft: Bool = false,
        speaker: Int? = nil,
        sessionID: Int = 1
    ) -> CaptionRow {
        CaptionRow(
            id: CaptionRowID(sessionID: sessionID, ordinal: ordinal),
            languageID: "en",
            targetLanguageID: "zh-Hant",
            text: text,
            stableLength: text.count,
            isSealed: true,
            isFinal: true,
            translation: translation,
            translationIsDraft: draft,
            speakerIndex: speaker,
            createdMs: Double(ordinal)
        )
    }

    private func document(_ rows: [CaptionRow]) -> CaptionDocument {
        CaptionDocument(rows: rows, revision: 0)
    }

    private func config(
        width: CGFloat = 400,
        height: CGFloat = 120,
        arrangement: CaptionViewportConfig.Arrangement = .stacked(leading: .translated),
        anchoring: CaptionViewportConfig.Anchoring = .bottom,
        badges: Bool = false
    ) -> CaptionViewportConfig {
        CaptionViewportConfig(
            width: width,
            height: height,
            arrangement: arrangement,
            anchoring: anchoring,
            panes: CaptionPaneConfig(
                originalLanguageID: "en", showsOriginal: true, showsTranslated: true
            ),
            typography: [
                .translated: .system(size: 24, weight: .semibold),
                .original: .system(size: 18, weight: .regular),
            ],
            showsSpeakerBadges: badges,
            badgeHeight: 14
        )
    }

    private func line(_ screen: CaptionScreen, rowOrdinal: Int, pane: CaptionPane, index: Int = 0) -> CaptionScreenLine? {
        screen.lines.first {
            $0.id.row.ordinal == rowOrdinal && $0.id.pane == pane && $0.id.index == index
        }
    }

    func testFirstFrameBottomAnchored() {
        var viewport = CaptionViewport()
        let screen = viewport.update(document([row(0, text: "Hi.", translation: "嗨")]), config: config())
        XCTAssertFalse(screen.lines.isEmpty)
        // Bottom anchor: last line's bottom edge sits at the viewport bottom.
        let bottom = screen.lines.map { $0.y + $0.height }.max() ?? 0
        XCTAssertEqual(bottom, 120, accuracy: 0.01)
    }

    /// The fade flag is off while everything fits and on once content
    /// scrolls above the viewport top.
    func testHasContentAboveTracksScrolledContent() {
        var viewport = CaptionViewport()
        let fitting = viewport.update(
            document([row(0, text: "One.", translation: "一")]),
            config: config()
        )
        XCTAssertFalse(fitting.hasContentAbove)

        _ = viewport.update(document([
            row(0, text: "One.", translation: "一"),
            row(1, text: "Two.", translation: "二"),
            row(2, text: "Three.", translation: "三"),
        ]), config: config())
        let overflowing = viewport.update(document([
            row(0, text: "One.", translation: "一"),
            row(1, text: "Two.", translation: "二"),
            row(2, text: "Three.", translation: "三"),
            row(3, text: "Four.", translation: "四"),
            row(4, text: "Five.", translation: "五"),
            row(5, text: "Six.", translation: "六"),
        ]), config: config())
        XCTAssertTrue(overflowing.hasContentAbove, "scrolled content should mark content above")

        // Pinned all the way back to the first row: nothing above again.
        viewport.scrollBack(rows: 6)
        let pinned = viewport.update(document([
            row(0, text: "One.", translation: "一"),
            row(1, text: "Two.", translation: "二"),
            row(2, text: "Three.", translation: "三"),
            row(3, text: "Four.", translation: "四"),
            row(4, text: "Five.", translation: "五"),
            row(5, text: "Six.", translation: "六"),
        ]), config: config())
        XCTAssertFalse(pinned.hasContentAbove, "pinned to the top has nothing above")
    }

    func testGrowthScrollsUp() {
        var viewport = CaptionViewport()
        let screen1 = viewport.update(document([row(0, text: "One.", translation: "一")]), config: config())
        let firstY = line(screen1, rowOrdinal: 0, pane: .translated)?.y ?? 0
        _ = viewport.update(document([
            row(0, text: "One.", translation: "一"),
            row(1, text: "Two.", translation: "二"),
            row(2, text: "Three.", translation: "三"),
        ]), config: config())
        let screen3 = viewport.update(document([
            row(0, text: "One.", translation: "一"),
            row(1, text: "Two.", translation: "二"),
            row(2, text: "Three.", translation: "三"),
            row(3, text: "Four.", translation: "四"),
            row(4, text: "Five.", translation: "五"),
            row(5, text: "Six.", translation: "六"),
        ]), config: config())
        let laterY = line(screen3, rowOrdinal: 0, pane: .translated)?.y
        XCTAssertTrue(laterY == nil || laterY! < firstY, "content did not scroll up")
    }

    func testShrinkingLiveTranslationLeavesBlankSpaceAndNothingMoves() {
        var viewport = CaptionViewport()
        var doc = document([
            row(0, text: "One.", translation: "一個很長很長很長很長很長很長很長很長的譯文句子需要換行"),
            row(1, text: "Two live", translation: "二"),
        ])
        // Tall viewport so every line of row 0 is visible.
        let screen1 = viewport.update(doc, config: config(height: 260))
        let liveY = line(screen1, rowOrdinal: 1, pane: .translated)?.y ?? -1
        XCTAssertGreaterThan(
            screen1.lines.filter { $0.id.row.ordinal == 0 && $0.id.pane == .translated }.count, 1,
            "row 0's translation must wrap to multiple lines before shrinking"
        )

        doc = document([
            row(0, text: "One.", translation: "一"),
            row(1, text: "Two live", translation: "二"),
        ])
        let screen2 = viewport.update(doc, config: config(height: 260))
        // The shrunk translation's reserved space keeps every other line put.
        XCTAssertEqual(line(screen2, rowOrdinal: 1, pane: .translated)?.y, liveY)
        XCTAssertEqual(
            line(screen2, rowOrdinal: 1, pane: .original)?.y,
            line(screen1, rowOrdinal: 1, pane: .original)?.y
        )
        XCTAssertEqual(
            line(screen2, rowOrdinal: 0, pane: .original)?.y,
            line(screen1, rowOrdinal: 0, pane: .original)?.y
        )
    }

    func testGrowingOlderRowMovesOlderLinesUpLiveRowStays() {
        var viewport = CaptionViewport()
        // Four rows at height 200: content overflows; row 1 stays visible.
        let baseRows = (0..<4).map {
            row($0, text: "Sentence \($0).", translation: "譯文 \($0)")
        }
        let before = viewport.update(document(baseRows), config: config(height: 200))
        let olderYBefore = line(before, rowOrdinal: 1, pane: .translated)?.y
        let liveYBefore = line(before, rowOrdinal: 3, pane: .translated)?.y

        // Row 1's translation grows by extra lines while live row 3 stays put.
        var grown = baseRows
        grown[1] = row(
            1, text: "Sentence 1.",
            translation: "這是一句需要換行才可以放下的長譯文內容非常長所以要佔兩行以上"
        )
        let after = viewport.update(document(grown), config: config(height: 200))
        let olderYAfter = line(after, rowOrdinal: 1, pane: .translated)?.y
        let liveYAfter = line(after, rowOrdinal: 3, pane: .translated)?.y

        XCTAssertNotNil(olderYAfter)
        XCTAssertLessThan(olderYAfter ?? .infinity, olderYBefore ?? 0, "older lines did not move up")
        XCTAssertEqual(liveYAfter, liveYBefore, "live row moved")
    }

    func testTopAnchoringFillsFromTopThenScrolls() {
        var viewport = CaptionViewport()
        var cfg = config()
        cfg.anchoring = .top
        let rows = (0..<10).map { row($0, text: "Sentence \($0).", translation: "譯文 \($0)") }
        var screen = viewport.update(document(Array(rows.prefix(3))), config: cfg)
        // First row's first line at the very top while content is short.
        XCTAssertEqual(line(screen, rowOrdinal: 0, pane: .translated)?.y ?? -1, 0, accuracy: 0.01)
        // Grow past the viewport height → first row scrolls off the top.
        screen = viewport.update(document(rows), config: cfg)
        let y = line(screen, rowOrdinal: 0, pane: .translated)?.y
        XCTAssertTrue(y == nil || y! < 0, "row 0 should have scrolled up")
        XCTAssertEqual(screen.lines.last.map { $0.y + $0.height } ?? 0, 120, accuracy: 1.5)
    }

    func testColumnsBlockHeightIsMaxOfBoth() {
        var viewport = CaptionViewport()
        var cfg = config(arrangement: .columns(leading: .original), anchoring: .top)
        cfg.width = 400
        // Long original → wraps; short translation → 1 line.
        let rows = [
            row(0, text: "A fairly long sentence that must wrap across a couple of lines now.",
                translation: "短"),
            row(1, text: "Next.", translation: "二"),
        ]
        let screen = viewport.update(document(rows), config: cfg)
        let row0Original = screen.lines.filter { $0.id.row.ordinal == 0 && $0.id.pane == .original }
        let row0Translated = screen.lines.filter { $0.id.row.ordinal == 0 && $0.id.pane == .translated }
        XCTAssertGreaterThan(row0Original.count, 1)
        XCTAssertEqual(row0Translated.count, 1)
        let originalBlock = CGFloat(row0Original.count) * (row0Original.first?.height ?? 0)
        let translatedBlock = CGFloat(row0Translated.count) * (row0Translated.first?.height ?? 0)
        let expectedBlock = max(originalBlock, translatedBlock) + cfg.rowSpacing
        let row1Y = line(screen, rowOrdinal: 1, pane: .original)?.y ?? -1
        XCTAssertEqual(row1Y, expectedBlock, accuracy: 0.5)
        // Columns: original pane in the left column.
        XCTAssertEqual(row0Original.first?.x ?? -1, 0)
        XCTAssertEqual(row0Translated.first?.x ?? -1, (400 - cfg.columnSpacing) / 2 + cfg.columnSpacing)
    }

    func testSpeakerBadges() {
        var viewport = CaptionViewport()
        let cfg = config(badges: true)
        let rows = [
            row(0, text: "Speaker one talks.", speaker: 1),
            row(1, text: "Same speaker continues.", speaker: 1),
            row(2, text: "A different speaker.", speaker: 2),
        ]
        let screen = viewport.update(document(rows), config: cfg)
        XCTAssertEqual(screen.badges.map(\.speakerIndex), [1, 2])
        XCTAssertEqual(screen.badges.map(\.id.ordinal), [0, 2])
    }

    func testScrollBackPinsAndResumes() {
        var viewport = CaptionViewport()
        let rows = (0..<10).map { row($0, text: "Sentence \($0).", translation: "譯文 \($0)") }
        _ = viewport.update(document(rows), config: config())
        viewport.scrollBack(rows: 2)
        let pinned = viewport.update(document(rows), config: config())
        // Row 8 (second most recent) has its block bottom at viewport bottom.
        let row8Lines = pinned.lines.filter { $0.id.row.ordinal == 8 }
        XCTAssertFalse(row8Lines.isEmpty)
        XCTAssertEqual(row8Lines.map { $0.y + $0.height }.max() ?? 0, 120, accuracy: 0.5)
        // Resume.
        viewport.scrollBack(rows: 0)
        let live = viewport.update(document(rows), config: config())
        let lastLines = live.lines.filter { $0.id.row.ordinal == 9 }
        XCTAssertEqual(lastLines.map { $0.y + $0.height }.max() ?? 0, 120, accuracy: 0.5)
    }

    func testWidthChangeRelayouts() {
        var viewport = CaptionViewport()
        let long = row(0, text: "A long sentence that wraps at four hundred points for sure yes it does.", translation: "譯文")
        let wide = viewport.update(document([long]), config: config(width: 400))
        let narrow = viewport.update(document([long]), config: config(width: 200))
        XCTAssertGreaterThan(narrow.lines.filter { $0.id.pane == .original }.count,
                             wide.lines.filter { $0.id.pane == .original }.count)
    }

    func testDroppedFrontRowsDoNotMoveRemaining() {
        var viewport = CaptionViewport()
        let rows = (0..<6).map { row($0, text: "Sentence \($0).", translation: "譯文 \($0)") }
        let before = viewport.update(document(rows), config: config())
        let after = viewport.update(document(Array(rows.dropFirst(2))), config: config())
        for ordinal in 2..<6 {
            XCTAssertEqual(
                line(after, rowOrdinal: ordinal, pane: .translated)?.y,
                line(before, rowOrdinal: ordinal, pane: .translated)?.y,
                "row \(ordinal) moved after the front rows dropped"
            )
        }
    }
}
