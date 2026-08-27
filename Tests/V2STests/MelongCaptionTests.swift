import XCTest
@testable import v2s

final class MelongCaptionTests: XCTestCase {
    func testTibetanLanguageIDs() {
        XCTAssertTrue(MelongCaption.isTibetanLanguageID("bo"))
        XCTAssertTrue(MelongCaption.isTibetanLanguageID("bo-CN"))
        XCTAssertFalse(MelongCaption.isTibetanLanguageID("en"))
        XCTAssertFalse(MelongCaption.isTibetanLanguageID("zh-Hant"))
    }

    func testLineTakesFirstNonEmptyAndStripsDanglers() {
        XCTAssertEqual(
            MelongCaption.line(from: "I am going.\n\n(or more literally: I will go.)"),
            "I am going."
        )
        XCTAssertEqual(
            MelongCaption.line(from: "One of his unique approaches was..."),
            "One of his unique approaches was"
        )
        XCTAssertEqual(
            MelongCaption.line(from: "One of his unique approaches was:"),
            "One of his unique approaches was"
        )
        XCTAssertEqual(MelongCaption.line(from: "Thank you."), "Thank you.")
    }

    func testPromptIsFewShotAndEndsWithEn() {
        let prompt = MelongCaption.prompt(for: "ང་འགྲོ་གི་ཡིན།")
        XCTAssertTrue(prompt.contains("bo: བཀྲ་ཤིས་བདེ་ལེགས།"))
        XCTAssertTrue(prompt.contains("en: Tashi Delek."))
        XCTAssertTrue(prompt.contains("bo: ང་འགྲོ་གི་ཡིན།"))
        XCTAssertTrue(prompt.hasSuffix("en:\n") || prompt.hasSuffix("en:"))
    }
}
