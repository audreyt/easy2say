import XCTest
@testable import v2s

final class CaptionLexicalKeyTests: XCTestCase {
    func testSpacingPunctuationAndCaseDoNotChangeTheKey() {
        XCTAssertEqual(CaptionLexicalKey("大家早安 ，謝謝各位。"), CaptionLexicalKey("大家早安謝謝各位"))
        XCTAssertEqual(CaptionLexicalKey("Hello, World."), CaptionLexicalKey("hello world"))
        XCTAssertEqual(CaptionLexicalKey("Café"), CaptionLexicalKey("cafe"))
        XCTAssertNotEqual(CaptionLexicalKey("Hello world"), CaptionLexicalKey("Hello word"))
    }

    func testRemainderCutsAfterTheMatchedPrefixInTheOriginalText() {
        let committed = CaptionLexicalKey("大家早安 ，謝謝各位。")
        let hypothesis = CaptionLexicalKey("大家早安謝謝各位，我們要談談")
        XCTAssertTrue(hypothesis.hasPrefix(committed))
        XCTAssertEqual(hypothesis.remainder(afterKeyPrefix: committed.count), "我們要談談")

        let latin = CaptionLexicalKey("Good morning everyone thank you")
        XCTAssertEqual(
            latin.remainder(afterKeyPrefix: CaptionLexicalKey("Good morning, everyone.").count),
            "thank you"
        )
        XCTAssertEqual(latin.remainder(afterKeyPrefix: latin.count), "")
    }

    /// Hindi and Thai characters are clusters of several scalars; lengths count
    /// scalars, so a cut must land after the whole matched cluster run.
    func testRemainderCountsScalarsForMultiScalarCharacters() {
        let committedHindi = CaptionLexicalKey("नमस्ते।")
        let hindi = CaptionLexicalKey("नमस्ते दोस्तों")
        XCTAssertTrue(hindi.hasPrefix(committedHindi))
        XCTAssertEqual(hindi.remainder(afterKeyPrefix: committedHindi.count), "दोस्तों")

        let committedThai = CaptionLexicalKey("สวัสดีครับ")
        let thai = CaptionLexicalKey("สวัสดีครับ ยินดีต้อนรับ")
        XCTAssertTrue(thai.hasPrefix(committedThai))
        XCTAssertEqual(thai.remainder(afterKeyPrefix: committedThai.count), "ยินดีต้อนรับ")
    }
}
