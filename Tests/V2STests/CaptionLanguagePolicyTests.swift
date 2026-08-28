import XCTest
@testable import v2s

final class CaptionLanguagePolicyTests: XCTestCase {
    func testZhTWAndZhHantAreEquivalent() {
        XCTAssertTrue(LanguageIdentity.areEquivalent("zh-TW", "zh-Hant"))
        XCTAssertTrue(LanguageIdentity.areEquivalent("zh-Hant-TW", "zh-Hant"))
        XCTAssertFalse(LanguageIdentity.areEquivalent("zh-Hans", "zh-Hant"))
        XCTAssertTrue(LanguageIdentity.areEquivalent("en-US", "en"))
    }

    func testGenericLanguageIDsLowercase() {
        XCTAssertEqual(LanguageIdentity.canonicalLanguageID("JA"), "ja")
        XCTAssertEqual(LanguageIdentity.canonicalLanguageID("KO-KR"), "ko")
        XCTAssertEqual(LanguageIdentity.canonicalLanguageID("fr_CA"), "fr")
    }

    func testDualLaneOnlyForConfiguredZhHantToEnglish() {
        XCTAssertTrue(CaptionLanguagePolicy.shouldEnableDualLane(sourceLanguageID: "zh-Hant", targetLanguageID: "en"))
        XCTAssertTrue(CaptionLanguagePolicy.shouldEnableDualLane(sourceLanguageID: "zh-TW", targetLanguageID: "en"))
        XCTAssertFalse(CaptionLanguagePolicy.shouldEnableDualLane(sourceLanguageID: "zh-Hans", targetLanguageID: "en"))
        XCTAssertFalse(CaptionLanguagePolicy.shouldEnableDualLane(sourceLanguageID: "en", targetLanguageID: "zh-Hant"))
        XCTAssertFalse(CaptionLanguagePolicy.shouldEnableDualLane(sourceLanguageID: "zh-Hant", targetLanguageID: "ja"))
    }

    func testClassifierIgnoresPunctuationWhitespaceAndDigits() {
        XCTAssertEqual(CaptionLanguagePolicy.classifyHeardScript("OK"), .entirelyLatin)
        XCTAssertEqual(CaptionLanguagePolicy.classifyHeardScript("Hello!"), .entirelyLatin)
        XCTAssertEqual(CaptionLanguagePolicy.classifyHeardScript("  A1.  "), .entirelyLatin)
        XCTAssertEqual(CaptionLanguagePolicy.classifyHeardScript("123 …"), .empty)
        XCTAssertEqual(CaptionLanguagePolicy.classifyHeardScript("Hello 甲"), .containsHan)
        XCTAssertEqual(CaptionLanguagePolicy.classifyHeardScript("這是甲乙"), .containsHan)
    }

    func testAccentedLatinClassifiesAsEntirelyLatin() {
        XCTAssertEqual(CaptionLanguagePolicy.classifyHeardScript("café"), .entirelyLatin)
        XCTAssertEqual(CaptionLanguagePolicy.classifyHeardScript("naïve"), .entirelyLatin)
        XCTAssertEqual(CaptionLanguagePolicy.classifyHeardScript("Søren"), .entirelyLatin)
    }

    func testNonLatinScriptsClassifyAsOther() {
        XCTAssertEqual(CaptionLanguagePolicy.classifyHeardScript("Привет мир"), .other)
        XCTAssertEqual(CaptionLanguagePolicy.classifyHeardScript("こんにちは"), .other)
        XCTAssertEqual(CaptionLanguagePolicy.classifyHeardScript("བཀྲ་ཤིས་བདེ་ལེགས"), .other)
    }

    func testExactDualLaneAcronymAgreementAcceptsPureEnglish() {
        let (selected, resolution) = CaptionLanguagePolicy.defaultResolveCaptionLane(
            primaryText: "API",
            secondaryText: "api",
            primaryConfidence: nil,
            secondaryConfidence: nil,
            arbiterFloor: .primary
        )
        XCTAssertEqual(selected, .secondary)
        XCTAssertEqual(resolution, .pureEnglish)
    }

    func testSingleTokenNonExactRejectsPureEnglish() {
        let (selected, resolution) = CaptionLanguagePolicy.defaultResolveCaptionLane(
            primaryText: "app",
            secondaryText: "api",
            primaryConfidence: nil,
            secondaryConfidence: nil,
            arbiterFloor: .primary
        )
        XCTAssertEqual(selected, .primary)
        XCTAssertEqual(resolution, .normalMandarinOrMixed)
    }

    func testSimilarityAbove064BoundarySelectsPureEnglish() {
        let primary = "this is a sentence about tehnology"
        let secondary = "this is a sentence about technology"
        let similarity = CaptionLanguagePolicy.normalizedEditSimilarity(primary, secondary)
        XCTAssertGreaterThanOrEqual(similarity, 0.64)

        let (selected, resolution) = CaptionLanguagePolicy.defaultResolveCaptionLane(
            primaryText: primary,
            secondaryText: secondary,
            primaryConfidence: nil,
            secondaryConfidence: nil,
            arbiterFloor: .primary
        )
        XCTAssertEqual(selected, .secondary)
        XCTAssertEqual(resolution, .pureEnglish)
    }

    func testPrimaryContainingHanSelectsNormalMandarinOrMixed() {
        let (selected, resolution) = CaptionLanguagePolicy.defaultResolveCaptionLane(
            primaryText: "我們來看這個 API 模型",
            secondaryText: "women lai kan zhege API moxing",
            primaryConfidence: nil,
            secondaryConfidence: nil,
            arbiterFloor: .primary
        )
        XCTAssertEqual(selected, .primary)
        XCTAssertEqual(resolution, .normalMandarinOrMixed)
    }

    func testOneWordEnglishReversesWhenEnglishLaneWinsWithAffirmativeEvidence() {
        let evidence = DualLaneEvidence(
            arbiterFloor: .primary,
            selectedSide: .secondary,
            resolution: .pureEnglish,
            winnerConfidence: nil,
            competingConfidence: nil,
            primaryScript: .entirelyLatin,
            secondaryScript: .entirelyLatin
        )
        XCTAssertTrue(
            CaptionLanguagePolicy.shouldReverse(
                configuredSourceLanguageID: "zh-Hant",
                configuredTargetLanguageID: "en",
                heardLanguageID: "en",
                heardText: "Hello",
                evidence: evidence
            )
        )
    }

    func testAffirmativePureEnglishEvidenceDoesNotReverseHanHeardText() {
        let evidence = DualLaneEvidence(
            arbiterFloor: .primary,
            selectedSide: .secondary,
            resolution: .pureEnglish,
            winnerConfidence: nil,
            competingConfidence: nil,
            primaryScript: .entirelyLatin,
            secondaryScript: .entirelyLatin
        )
        XCTAssertFalse(
            CaptionLanguagePolicy.shouldReverse(
                configuredSourceLanguageID: "zh-Hant",
                configuredTargetLanguageID: "en",
                heardLanguageID: "en",
                heardText: "大家好",
                evidence: evidence
            )
        )
    }

    func testLatinTextWithNilEvidenceDoesNotReverseInDualLane() {
        XCTAssertFalse(
            CaptionLanguagePolicy.shouldReverse(
                configuredSourceLanguageID: "zh-Hant",
                configuredTargetLanguageID: "en",
                heardLanguageID: "en",
                heardText: "Hello",
                evidence: nil
            )
        )
    }

    func testPaneMappingKeepsZhAndEnSemantic() {
        let evidence = DualLaneEvidence(
            arbiterFloor: .primary,
            selectedSide: .secondary,
            resolution: .pureEnglish,
            winnerConfidence: nil,
            competingConfidence: nil,
            primaryScript: .entirelyLatin,
            secondaryScript: .entirelyLatin
        )
        let mandarin = CaptionLanguagePolicy.overlayPanes(
            heardText: "大家好",
            translatedText: "Hello everyone",
            heardLanguageID: "zh-Hant",
            configuredSourceLanguageID: "zh-Hant",
            configuredTargetLanguageID: "en"
        )
        XCTAssertEqual(mandarin.sourceText, "大家好")
        XCTAssertEqual(mandarin.translatedText, "Hello everyone")

        let englishReversed = CaptionLanguagePolicy.overlayPanes(
            heardText: "Hello everyone",
            translatedText: "大家好",
            heardLanguageID: "en",
            configuredSourceLanguageID: "zh-Hant",
            configuredTargetLanguageID: "en",
            evidence: evidence
        )
        XCTAssertEqual(englishReversed.sourceText, "大家好")
        XCTAssertEqual(englishReversed.translatedText, "Hello everyone")
    }

    func testTranslationTargetFlipsWithHeardLanguageAndAffirmativeEvidence() {
        let evidence = DualLaneEvidence(
            arbiterFloor: .primary,
            selectedSide: .secondary,
            resolution: .pureEnglish,
            winnerConfidence: nil,
            competingConfidence: nil,
            primaryScript: .entirelyLatin,
            secondaryScript: .entirelyLatin
        )
        XCTAssertEqual(
            CaptionLanguagePolicy.translationTarget(
                heardLanguageID: "zh-Hant",
                configuredSourceLanguageID: "zh-Hant",
                configuredTargetLanguageID: "en"
            ),
            "en"
        )
        XCTAssertEqual(
            CaptionLanguagePolicy.translationTarget(
                heardLanguageID: "en",
                configuredSourceLanguageID: "zh-Hant",
                configuredTargetLanguageID: "en",
                heardText: "Hello",
                evidence: evidence
            ),
            "zh-Hant"
        )
        XCTAssertEqual(
            CaptionLanguagePolicy.translationTarget(
                heardLanguageID: "en",
                configuredSourceLanguageID: "zh-Hant",
                configuredTargetLanguageID: "en",
                heardText: "Hello",
                evidence: nil
            ),
            "en"
        )
    }
}
