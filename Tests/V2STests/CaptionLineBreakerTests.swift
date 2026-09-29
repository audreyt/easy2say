import CoreText
import XCTest
@testable import v2s

final class CaptionLineBreakerTests: XCTestCase {
    private let font = CaptionTypography.system(size: 24, weight: .regular).font

    private func lines(_ text: String, width: CGFloat) -> [Range<String.Index>] {
        CaptionLineBreaker.lines(text, font: font, width: width)
    }

    private func measuredWidth(_ text: String) -> CGFloat {
        let attributed = NSAttributedString(
            string: text,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let line = CTLineCreateWithAttributedString(attributed)
        return CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
    }

    func testEmptyAndDegenerateWidth() {
        XCTAssertEqual(lines("", width: 100), [])
        let whole = lines("Hello world", width: 0)
        XCTAssertEqual(whole.count, 1)
        XCTAssertEqual(String("Hello world"[whole[0]]), "Hello world")
        let negative = lines("Hello world", width: -10)
        XCTAssertEqual(negative.count, 1)
    }

    func testLinesJoinBackToText() {
        for text in [
            "Good morning everyone thank you for coming to our session today",
            "我們要談談字幕在講者還在說話的時候應該如何出現在螢幕上",
            "Mixed 中文 and English words interleaved with numbers 12345.",
        ] {
            let pieces = lines(text, width: 180)
            XCTAssertEqual(pieces.map { String(text[$0]) }.joined(), text)
        }
    }

    func testLatinBreaksAtSpaces() {
        let text = "Good morning everyone thank you for coming"
        let pieces = lines(text, width: measuredWidth("Good morning "))
        XCTAssertGreaterThanOrEqual(pieces.count, 2)
        XCTAssertEqual(pieces.map { String(text[$0]) }.joined(), text)
        // Breaks happen at word boundaries: a line ends with the space and the
        // next does not start with one.
        for piece in pieces {
            let segment = String(text[piece])
            XCTAssertFalse(segment.hasPrefix(" "), "line starts with whitespace: \(segment)")
        }
        XCTAssertTrue(String(text[pieces[0]]).hasSuffix(" "))
    }

    func testCJKBreaksBetweenCharacters() {
        let text = "我們要談談字幕應該如何出現在螢幕上"
        // Width of exactly 4 glyphs.
        let fourGlyph = String(text.prefix(4))
        let pieces = lines(text, width: measuredWidth(fourGlyph))
        XCTAssertGreaterThan(pieces.count, 1)
        for piece in pieces {
            let segment = String(text[piece])
            XCTAssertFalse(segment.isEmpty)
        }
        XCTAssertEqual(pieces.map { String(text[$0]) }.joined(), text)
    }

    func testOverlongTokenBreaksSomewhere() {
        let text = "https://example.com/a/very/long/token/that/cannot/fit/on/one/line"
        let pieces = lines(text, width: 120)
        XCTAssertGreaterThan(pieces.count, 1)
        XCTAssertEqual(pieces.map { String(text[$0]) }.joined(), text)
    }

    func testWidthsHonoured() {
        let text = "Every rendered line should respect the column width that the viewport assigns to its pane."
        let width: CGFloat = 220
        for range in lines(text, width: width) {
            let segment = String(text[range])
            let measured = measuredWidth(segment)
            let trimmed = measuredWidth(segment.trimmingCharacters(in: .whitespaces))
            XCTAssertTrue(
                measured <= width + 0.5 || trimmed <= width + 0.5,
                "line \(segment) measured \(measured)pt exceeds \(width)pt"
            )
        }
    }
}
