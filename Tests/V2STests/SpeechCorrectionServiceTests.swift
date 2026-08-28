import Foundation
import XCTest
@testable import v2s

final class SpeechCorrectionServiceTests: XCTestCase {
    func testMissingFileYieldsEmptyTable() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-corrections-missing-\(UUID().uuidString).json")
        let table = try SpeechCorrectionService.load(from: url)
        XCTAssertTrue(table.isEmpty)
        XCTAssertEqual(table.apply("甲已丙", languageID: "zh-Hant"), "甲已丙")
    }

    func testUnsupportedVersionIsRejected() throws {
        let data = Data("""
        {"version": 2, "languages": {}}
        """.utf8)
        XCTAssertThrowsError(try SpeechCorrectionService.compile(data)) { error in
            XCTAssertEqual(
                error as? SpeechCorrectionLoadError,
                .unsupportedVersion(2)
            )
        }
    }

    func testMalformedJSONIsRejected() {
        XCTAssertThrowsError(try SpeechCorrectionService.compile(Data("not-json".utf8))) { error in
            guard case SpeechCorrectionLoadError.malformed = error else {
                return XCTFail("expected malformed, got \(error)")
            }
        }
    }

    func testConflictingAliasIsRejectedWithoutPartialApply() {
        let data = Data("""
        {
          "version": 1,
          "languages": {
            "zh-Hant": {
              "corrections": [
                {"canonical": "甲乙", "aliases": ["甲已"]},
                {"canonical": "甲丙", "aliases": ["甲已"]}
              ]
            }
          }
        }
        """.utf8)
        XCTAssertThrowsError(try SpeechCorrectionService.compile(data)) { error in
            guard case SpeechCorrectionLoadError.conflictingAlias = error else {
                return XCTFail("expected conflict, got \(error)")
            }
        }
    }

    func testCanonicalEqualAliasIsNoOp() throws {
        let table = try SpeechCorrectionService.compile(Data("""
        {
          "version": 1,
          "languages": {
            "zh-Hant": {
              "corrections": [
                {"canonical": "甲乙", "aliases": ["甲乙", "甲已"]}
              ]
            }
          }
        }
        """.utf8))
        XCTAssertEqual(table.apply("甲乙很好", languageID: "zh-Hant"), "甲乙很好")
        XCTAssertEqual(table.apply("甲已很好", languageID: "zh-Hant"), "甲乙很好")
    }

    func testMandarinCJKAliasReplacesWithoutWordBoundaries() throws {
        let table = try table(language: "zh-Hant", canonical: "甲乙", aliases: ["甲已"])
        XCTAssertEqual(table.apply("這是甲已丙", languageID: "zh-Hant"), "這是甲乙丙")
        XCTAssertEqual(table.apply("這是甲已丙", languageID: "zh-TW"), "這是甲乙丙")
    }

    func testLatinAliasRespectsLetterBoundaries() throws {
        let table = try table(language: "en", canonical: "ACME", aliases: ["ACM"])
        XCTAssertEqual(table.apply("see ACM now", languageID: "en"), "see ACME now")
        XCTAssertEqual(table.apply("see ACME now", languageID: "en"), "see ACME now")
        XCTAssertEqual(table.apply("see VACME now", languageID: "en"), "see VACME now")
        XCTAssertEqual(table.apply("用ACM模型", languageID: "en"), "用ACME模型")
    }

    func testLatinAliasRespectsUnderscoreAndPunctuationBoundaries() throws {
        let table = try table(language: "en", canonical: "Riverton", aliases: ["rivertin"])
        XCTAssertEqual(table.apply("see _rivertin_ now", languageID: "en"), "see _Riverton_ now")
        XCTAssertEqual(table.apply("see (rivertin) now", languageID: "en"), "see (Riverton) now")
        XCTAssertEqual(table.apply("rivertin!", languageID: "en"), "Riverton!")
    }

    func testLatinAliasMatchesAdjacentToKanaAndHangul() throws {
        let table = try table(language: "en", canonical: "ACME", aliases: ["ACM"])
        XCTAssertEqual(table.apply("使うACMです", languageID: "en"), "使うACMEです")
        XCTAssertEqual(table.apply("한글ACM시험", languageID: "en"), "한글ACME시험")
        XCTAssertEqual(table.apply("xACM", languageID: "en"), "xACM")
    }

    func testNonASCIILatinAliasesAndCanonicalsWork() throws {
        let cafeTable = try table(language: "en", canonical: "café", aliases: ["cafe"])
        XCTAssertEqual(cafeTable.apply("meet at the cafe today", languageID: "en"), "meet at the café today")
        XCTAssertEqual(cafeTable.apply("meet at the CAFE today", languageID: "en"), "meet at the café today")

        let naiveTable = try table(language: "en", canonical: "naïve", aliases: ["naive"])
        XCTAssertEqual(naiveTable.apply("not naive at all", languageID: "en"), "not naïve at all")
    }

    func testUnicodeLatinAliasMatchesCaseInsensitively() throws {
        let coffeeTable = try table(language: "en", canonical: "Coffee", aliases: ["café"])
        XCTAssertEqual(coffeeTable.apply("meet at the café today", languageID: "en"), "meet at the Coffee today")
        XCTAssertEqual(coffeeTable.apply("meet at the CAFÉ today", languageID: "en"), "meet at the Coffee today")
    }

    func testLongestAliasWins() throws {
        let table = try SpeechCorrectionService.compile(Data("""
        {
          "version": 1,
          "languages": {
            "zh-Hant": {
              "corrections": [
                {"canonical": "甲", "aliases": ["甲已"]},
                {"canonical": "甲乙丙", "aliases": ["甲已丙"]}
              ]
            }
          }
        }
        """.utf8))
        XCTAssertEqual(table.apply("甲已丙末", languageID: "zh-Hant"), "甲乙丙末")
    }

    func testOnePassDoesNotCascadeThroughCanonical() throws {
        let table = try SpeechCorrectionService.compile(Data("""
        {
          "version": 1,
          "languages": {
            "zh-Hant": {
              "corrections": [
                {"canonical": "甲已", "aliases": ["甲乙"]},
                {"canonical": "丁", "aliases": ["甲已"]}
              ]
            }
          }
        }
        """.utf8))
        XCTAssertEqual(table.apply("甲乙末", languageID: "zh-Hant"), "甲已末")
        XCTAssertEqual(table.apply(table.apply("甲乙末", languageID: "zh-Hant"), languageID: "zh-Hant"), "丁末")
    }

    func testLanguageScopingDoesNotLeak() throws {
        let table = try SpeechCorrectionService.compile(Data("""
        {
          "version": 1,
          "languages": {
            "zh-Hant": {
              "corrections": [
                {"canonical": "甲乙", "aliases": ["甲已"]}
              ]
            },
            "en": {
              "corrections": [
                {"canonical": "ACME", "aliases": ["ACM"]}
              ]
            }
          }
        }
        """.utf8))
        XCTAssertEqual(table.apply("甲已 ACM", languageID: "zh-Hant"), "甲乙 ACM")
        XCTAssertEqual(table.apply("甲已 ACM", languageID: "en"), "甲已 ACME")
        XCTAssertEqual(table.apply("甲已 ACM", languageID: "ja"), "甲已 ACM")
    }

    func testRecognitionHintsPrecedenceAnd100Cap() throws {
        var entries: [SpeechCorrectionEntry] = []
        for i in 1...150 {
            entries.append(SpeechCorrectionEntry(canonical: "term\(i)", aliases: ["alias\(i)"]))
        }
        let longHint = String(repeating: "H", count: 40)
        let document = SpeechCorrectionDocument(
            version: 1,
            languages: [
                "en": SpeechCorrectionLanguageSection(hints: [longHint], corrections: entries),
            ]
        )
        let table = try SpeechCorrectionService.compile(document)
        let hints = SpeechCorrectionService.recognitionPhrases(
            corrections: table,
            languageIDs: ["en"],
            glossaryKeys: ["glossaryLongerKey", "z"]
        )
        XCTAssertEqual(hints.count, 100)
        XCTAssertTrue(hints.contains("glossaryLongerKey"))
        XCTAssertTrue(hints.contains(longHint))
        XCTAssertFalse(hints.contains("z"))
        XCTAssertEqual(hints.first, longHint)
    }
    func testExplicitHintsAndHintOnlyEntriesCompileWithoutAliases() throws {
        let data = Data("""
        {
          "version": 1,
          "languages": {
            "zh-Hant": {
              "hints": ["僅提示詞"],
              "corrections": [
                {"canonical": "無錯詞項目"},
                {"canonical": "正常詞", "aliases": ["錯字"]}
              ]
            }
          }
        }
        """.utf8)
        let table = try SpeechCorrectionService.compile(data)
        let hints = SpeechCorrectionService.recognitionPhrases(
            corrections: table,
            languageIDs: ["zh-Hant"],
            glossaryKeys: []
        )
        XCTAssertTrue(hints.contains("僅提示詞"))
        XCTAssertTrue(hints.contains("無錯詞項目"))
        XCTAssertTrue(hints.contains("正常詞"))
        XCTAssertEqual(table.apply("錯字", languageID: "zh-Hant"), "正常詞")
        XCTAssertEqual(table.apply("僅提示詞", languageID: "zh-Hant"), "僅提示詞")
    }

    func testNeutralRecognitionPhrasesFiltersOutPureAndMixedCJK() throws {
        let table = try SpeechCorrectionService.compile(Data("""
        {
          "version": 1,
          "languages": {
            "zh-Hant": {
              "corrections": [
                {"canonical": "純中文", "aliases": ["錯字"]},
                {"canonical": "AI模型", "aliases": ["愛模型"]},
                {"canonical": "Riverton", "aliases": ["rivertin"]}
              ]
            }
          }
        }
        """.utf8))
        let neutral = SpeechCorrectionService.neutralRecognitionPhrases(
            corrections: table,
            languageIDs: ["zh-Hant"],
            glossaryKeys: ["純字詞", "API"]
        )
        XCTAssertTrue(neutral.contains("Riverton"))
        XCTAssertTrue(neutral.contains("API"))
        XCTAssertFalse(neutral.contains("AI模型"))
        XCTAssertFalse(neutral.contains("純中文"))
        XCTAssertFalse(neutral.contains("純字詞"))
    }

    func testDualLaneHintsUseGlossaryKeysForPrimaryAndValuesForEnglish() throws {
        let table = try SpeechCorrectionService.compile(Data("""
        {
          "version": 1,
          "languages": {
            "zh-Hant": {"hints": ["華文提示"]},
            "en": {"hints": ["EnglishHint"]}
          }
        }
        """.utf8))
        let glossary = ["資料": "data", "API": "API"]

        let primary = SpeechCorrectionService.recognitionPhrases(
            corrections: table,
            languageIDs: ["zh-Hant"],
            glossaryKeys: Array(glossary.keys)
        )
        let secondary = SpeechCorrectionService.recognitionPhrases(
            corrections: table,
            languageIDs: ["en"],
            glossaryKeys: Array(glossary.values)
        )
        let neutral = SpeechCorrectionService.neutralRecognitionPhrases(
            corrections: table,
            languageIDs: ["zh-Hant", "en"],
            glossaryKeys: primary + secondary
        )

        XCTAssertTrue(primary.contains("資料"))
        XCTAssertFalse(primary.contains("data"))
        XCTAssertTrue(secondary.contains("data"))
        XCTAssertFalse(secondary.contains("資料"))
        XCTAssertTrue(neutral.contains("API"))
        XCTAssertTrue(neutral.contains("data"))
        XCTAssertTrue(neutral.contains("EnglishHint"))
        XCTAssertFalse(neutral.contains("資料"))
        XCTAssertFalse(neutral.contains("華文提示"))
    }

    func testUnmatchedCharactersArePreserved() throws {
        let table = try table(language: "zh-Hant", canonical: "甲乙", aliases: ["甲已"])
        let input = "  甲已！OK 123 "
        XCTAssertEqual(table.apply(input, languageID: "zh-Hant"), "  甲乙！OK 123 ")
    }

    func testLatinAliasMatchesCaseInsensitivelyAsWholeToken() throws {
        let table = try table(language: "en", canonical: "Riverton", aliases: ["rivertin"])
        XCTAssertEqual(table.apply("see Rivertin now", languageID: "en"), "see Riverton now")
        XCTAssertEqual(table.apply("see RIVERTIN now", languageID: "en"), "see Riverton now")
        XCTAssertEqual(table.apply("see rivertino now", languageID: "en"), "see rivertino now")
    }

    func testPhraseAliasMatchesInsideUtteranceWithoutCascade() throws {
        let table = try SpeechCorrectionService.compile(Data("""
        {
          "version": 1,
          "languages": {
            "en": {
              "corrections": [
                {"canonical": "north star", "aliases": ["norths star", "north-star"]},
                {"canonical": "star", "aliases": ["starr"]}
              ]
            }
          }
        }
        """.utf8))
        XCTAssertEqual(
            table.apply("see the norths star tonight", languageID: "en"),
            "see the north star tonight"
        )
    }

    func testReviewAndUnsafeEntriesAreSkipped() throws {
        let table = try SpeechCorrectionService.compile(Data("""
        {
          "version": 1,
          "languages": {
            "en": {
              "corrections": [
                {"canonical": "Riverton", "aliases": ["rivertin"], "status": "safe"},
                {"canonical": "secret", "aliases": ["sekret"], "status": "review"},
                {"canonical": "blocked", "aliases": ["blokked"], "status": "unsafe"}
              ]
            }
          }
        }
        """.utf8))
        XCTAssertEqual(table.apply("rivertin sekret blokked", languageID: "en"), "Riverton sekret blokked")
        XCTAssertEqual(
            SpeechCorrectionService.recognitionPhrases(
                corrections: table,
                languageIDs: ["en"],
                glossaryKeys: []
            ),
            ["Riverton"]
        )
    }

    func testUnknownStatusIsRejected() {
        let data = Data("""
        {
          "version": 1,
          "languages": {
            "en": {
              "corrections": [
                {"canonical": "Riverton", "aliases": ["rivertin"], "status": "unknown"}
              ]
            }
          }
        }
        """.utf8)
        XCTAssertThrowsError(try SpeechCorrectionService.compile(data)) { error in
            guard case SpeechCorrectionLoadError.malformed = error else {
                return XCTFail("expected malformed, got \(error)")
            }
        }
    }

    func testEntryExceeding80CharsIsRejected() {
        let longTerm = String(repeating: "a", count: 85)
        let data = Data("""
        {
          "version": 1,
          "languages": {
            "en": {
              "corrections": [
                {"canonical": "\(longTerm)", "aliases": ["short"]}
              ]
            }
          }
        }
        """.utf8)
        XCTAssertThrowsError(try SpeechCorrectionService.compile(data)) { error in
            guard case SpeechCorrectionLoadError.malformed = error else {
                return XCTFail("expected malformed, got \(error)")
            }
        }
    }

    func testCaseInsensitiveDuplicateAliasesConflict() {
        let data = Data("""
        {
          "version": 1,
          "languages": {
            "en": {
              "corrections": [
                {"canonical": "Riverton", "aliases": ["Rivertin"]},
                {"canonical": "Other", "aliases": ["rivertin"]}
              ]
            }
          }
        }
        """.utf8)
        XCTAssertThrowsError(try SpeechCorrectionService.compile(data)) { error in
            guard case SpeechCorrectionLoadError.conflictingAlias = error else {
                return XCTFail("expected conflict, got \(error)")
            }
        }
    }

    func testHintExact40CharsIsAccepted() throws {
        let hint40 = String(repeating: "a", count: 40)
        let data = Data("""
        {
          "version": 1,
          "languages": {
            "en": {
              "hints": ["\(hint40)"]
            }
          }
        }
        """.utf8)
        let table = try SpeechCorrectionService.compile(data)
        let hints = SpeechCorrectionService.recognitionPhrases(
            corrections: table,
            languageIDs: ["en"],
            glossaryKeys: []
        )
        XCTAssertTrue(hints.contains(hint40))
    }

    func testHintExceeding40CharsIsRejected() {
        let hint41 = String(repeating: "a", count: 41)
        let data = Data("""
        {
          "version": 1,
          "languages": {
            "en": {
              "hints": ["\(hint41)"]
            }
          }
        }
        """.utf8)
        XCTAssertThrowsError(try SpeechCorrectionService.compile(data)) { error in
            guard case SpeechCorrectionLoadError.malformed = error else {
                return XCTFail("expected malformed, got \(error)")
            }
        }
    }

    func testDuplicateCanonicalLanguageSectionsAreRejected() {
        let data = Data("""
        {
          "version": 1,
          "languages": {
            "zh-Hant": {
              "corrections": [{"canonical": "詞一"}]
            },
            "zh-TW": {
              "corrections": [{"canonical": "詞二"}]
            }
          }
        }
        """.utf8)
        XCTAssertThrowsError(try SpeechCorrectionService.compile(data)) { error in
            guard case SpeechCorrectionLoadError.malformed = error else {
                return XCTFail("expected malformed, got \(error)")
            }
        }
    }

    func testLegacyLanguageArrayFormatIsRejected() {
        let data = Data("""
        {
          "version": 1,
          "languages": {
            "zh-Hant": [
              {"canonical": "詞一"}
            ]
          }
        }
        """.utf8)
        XCTAssertThrowsError(try SpeechCorrectionService.compile(data)) { error in
            guard case SpeechCorrectionLoadError.malformed = error else {
                return XCTFail("expected malformed, got \(error)")
            }
        }
    }

    func testDraftAndCommittedEmissionApplyOnceAndAgreeOnChainAlias() throws {
        let table = try SpeechCorrectionService.compile(Data("""
        {
          "version": 1,
          "languages": {
            "zh-Hant": {
              "corrections": [
                {"canonical": "甲已", "aliases": ["甲乙"]},
                {"canonical": "丁", "aliases": ["甲已"]}
              ]
            }
          }
        }
        """.utf8))
        let raw = "甲乙末"
        let draft = table.apply(raw, languageID: "zh-Hant")
        let committed = table.apply(raw, languageID: "zh-Hant")
        XCTAssertEqual(draft, committed)
        XCTAssertEqual(draft, "甲已末")
        XCTAssertNotEqual(table.apply(draft, languageID: "zh-Hant"), draft)
    }

    func testDigitEdgedAliasRespectsBoundaries() throws {
        let table = try table(language: "en", canonical: "五代", aliases: ["5G"])
        XCTAssertEqual(table.apply("The 25G link", languageID: "en"), "The 25G link")
        XCTAssertEqual(table.apply("用5G上网", languageID: "en"), "用五代上网")
        XCTAssertEqual(table.apply("5G.", languageID: "en"), "五代.")
    }

    func testCafeAndCafeWithoutAcuteAreDistinct() throws {
        let table = try table(language: "en", canonical: "café", aliases: ["cafe"])
        XCTAssertEqual(table.apply("cafe", languageID: "en"), "café")
        XCTAssertEqual(table.apply("café", languageID: "en"), "café")
    }

    func testFoldLatinEqualAliasIsNoOpNotConflict() throws {
        let table = try SpeechCorrectionService.compile(Data("""
        {
          "version": 1,
          "languages": {
            "en": {
              "corrections": [
                {"canonical": "Cafe", "aliases": ["cafe"]},
                {"canonical": "Other", "aliases": ["cafe"]}
              ]
            }
          }
        }
        """.utf8))
        XCTAssertEqual(table.apply("cafe", languageID: "en"), "Other")
    }

    func testSharpSAliasIsNotCasefoldNoOp() throws {
        let table = try table(language: "en", canonical: "ss", aliases: ["ß"])
        XCTAssertEqual(table.apply("ß", languageID: "en"), "ss")
    }

    func testUnknownDocumentSectionAndEntryKeysAreRejected() {
        let document = Data("""
        {"version": 1, "languages": {}, "extra": true}
        """.utf8)
        XCTAssertThrowsError(try SpeechCorrectionService.compile(document)) { error in
            guard case SpeechCorrectionLoadError.malformed = error else {
                return XCTFail("expected malformed, got \(error)")
            }
        }

        let section = Data("""
        {"version": 1, "languages": {"en": {"hints": ["OK"], "note": "no"}}}
        """.utf8)
        XCTAssertThrowsError(try SpeechCorrectionService.compile(section)) { error in
            guard case SpeechCorrectionLoadError.malformed = error else {
                return XCTFail("expected malformed, got \(error)")
            }
        }

        let entry = Data("""
        {"version": 1, "languages": {"en": {"corrections": [{"canonical": "A", "aliases": ["B"], "locale": "en"}]}}}
        """.utf8)
        XCTAssertThrowsError(try SpeechCorrectionService.compile(entry)) { error in
            guard case SpeechCorrectionLoadError.malformed = error else {
                return XCTFail("expected malformed, got \(error)")
            }
        }
    }

    func testUnsafeOverlengthEntryIsSkippedNotRejected() throws {
        let longTerm = String(repeating: "x", count: 90)
        let data = Data("""
        {
          "version": 1,
          "languages": {
            "en": {
              "corrections": [
                {"canonical": "\(longTerm)", "aliases": ["short"], "status": "unsafe"}
              ]
            }
          }
        }
        """.utf8)
        let table = try SpeechCorrectionService.compile(data)
        XCTAssertEqual(table.apply("short", languageID: "en"), "short")
    }

    func testConversationEngineSharedContextDropsCJKCanonicalsAndGlossaryKeys() throws {
        let table = try SpeechCorrectionService.compile(Data("""
        {
          "version": 1,
          "languages": {
            "zh-Hant": {
              "hints": ["純中文提示", "Riverton"],
              "corrections": [
                {"canonical": "甲乙", "aliases": ["甲已"]}
              ]
            },
            "en": {
              "hints": ["Acme"]
            }
          }
        }
        """.utf8))
        let shared = SpeechCorrectionService.neutralRecognitionPhrases(
            corrections: table,
            languageIDs: ["zh-Hant", "en"],
            glossaryKeys: ["資料庫", "API"]
        )
        XCTAssertTrue(shared.contains("Riverton"))
        XCTAssertTrue(shared.contains("Acme"))
        XCTAssertTrue(shared.contains("API"))
        XCTAssertFalse(shared.contains("純中文提示"))
        XCTAssertFalse(shared.contains("甲乙"))
        XCTAssertFalse(shared.contains("資料庫"))
    }

    private func table(
        language: String,
        canonical: String,
        aliases: [String]
    ) throws -> SpeechCorrectionTable {
        let document = SpeechCorrectionDocument(
            version: 1,
            languages: [
                language: SpeechCorrectionLanguageSection(corrections: [SpeechCorrectionEntry(canonical: canonical, aliases: aliases)]),
            ]
        )
        return try SpeechCorrectionService.compile(document)
    }
}
