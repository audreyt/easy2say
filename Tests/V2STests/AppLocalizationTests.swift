import XCTest
@testable import v2s

final class AppLocalizationTests: XCTestCase {
    func testEnglishMultipleSourcesUsesSingularAndPluralForms() {
        XCTAssertEqual(
            AppLocalization.multipleSourcesText(count: 1, languageID: "en"),
            "1 Source"
        )
        XCTAssertEqual(
            AppLocalization.multipleSourcesText(count: 3, languageID: "en"),
            "3 Sources"
        )
    }

    func testRussianMultipleSourcesUsesProperPluralCategories() {
        XCTAssertEqual(
            AppLocalization.multipleSourcesText(count: 1, languageID: "ru"),
            "1 источник"
        )
        XCTAssertEqual(
            AppLocalization.multipleSourcesText(count: 2, languageID: "ru"),
            "2 источника"
        )
        XCTAssertEqual(
            AppLocalization.multipleSourcesText(count: 5, languageID: "ru"),
            "5 источников"
        )
        XCTAssertEqual(
            AppLocalization.multipleSourcesText(count: 11, languageID: "ru"),
            "11 источников"
        )
        XCTAssertEqual(
            AppLocalization.multipleSourcesText(count: 21, languageID: "ru"),
            "21 источник"
        )
    }

    func testArabicMultipleSourcesUsesDistinctPluralForms() {
        XCTAssertEqual(
            AppLocalization.multipleSourcesText(count: 1, languageID: "ar"),
            "مصدر واحد"
        )
        XCTAssertEqual(
            AppLocalization.multipleSourcesText(count: 2, languageID: "ar"),
            "مصدران"
        )
        XCTAssertEqual(
            AppLocalization.multipleSourcesText(count: 4, languageID: "ar"),
            "4 مصادر"
        )
        XCTAssertEqual(
            AppLocalization.multipleSourcesText(count: 12, languageID: "ar"),
            "12 مصدرًا"
        )
    }

    func testChineseMultipleSourcesPreservesEachScript() {
        XCTAssertEqual(
            AppLocalization.multipleSourcesText(count: 3, languageID: "zh-Hans"),
            "3 个来源"
        )
        XCTAssertEqual(
            AppLocalization.multipleSourcesText(count: 3, languageID: "zh-Hant"),
            "3 個來源"
        )
    }

    func testEnglishAndChineseTablesHaveExactKeyParity() throws {
        let expectedKeys = Set(AppTextKey.allCases.map(\.rawValue))

        for languageID in ["en", "zh-Hans", "zh-Hant"] {
            let table = try XCTUnwrap(
                AppLocalization.tables[languageID],
                "Missing localization table for \(languageID)"
            )
            XCTAssertEqual(Set(table.keys), expectedKeys, languageID)
        }
    }

    func testIOSCopyUsesBothChineseScripts() {
        XCTAssertEqual(
            AppLocalization.string(.iosCopyAll, languageID: "zh-Hans"),
            "全部复制"
        )
        XCTAssertEqual(
            AppLocalization.string(.iosCopyAll, languageID: "zh-Hant"),
            "全部拷貝"
        )
    }
}
