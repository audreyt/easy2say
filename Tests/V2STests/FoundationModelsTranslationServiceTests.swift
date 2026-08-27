import XCTest
@testable import v2s

final class FoundationModelsTranslationServiceTests: XCTestCase {
    func testLooksLikeRefusalDetectsEnglishAndChineseDeclines() {
        XCTAssertTrue(FoundationModelsTranslationRefusal.looksLikeRefusal("Sorry, I can't help with that."))
        XCTAssertTrue(FoundationModelsTranslationRefusal.looksLikeRefusal("I cannot help with that request."))
        XCTAssertTrue(FoundationModelsTranslationRefusal.looksLikeRefusal("抱歉，我無法協助這個請求。"))
        XCTAssertFalse(FoundationModelsTranslationRefusal.looksLikeRefusal("One of his unique characteristics."))
        XCTAssertFalse(FoundationModelsTranslationRefusal.looksLikeRefusal("對不起，我遲到了。"))
    }

    func testAFMTranslationLocalizationKeysExistInRequiredTables() throws {
        let keys: [AppTextKey] = [
            .foundationModelsTranslationUnavailable,
            .foundationModelsTranslationEmpty,
            .foundationModelsTranslationRefused,
        ]
        for languageID in ["en", "zh-Hans", "zh-Hant"] {
            let table = try XCTUnwrap(AppLocalization.tables[languageID])
            for key in keys {
                XCTAssertNotNil(table[key.rawValue], "\(languageID) \(key.rawValue)")
                XCTAssertFalse(table[key.rawValue, default: ""].isEmpty)
            }
        }
    }
}
