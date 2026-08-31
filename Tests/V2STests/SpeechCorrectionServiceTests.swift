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

    func testBoundaryAwareApplyWhollyStableAliasExpandsBoundary() throws {
        let table = try table(language: "en", canonical: "Riverton", aliases: ["Rivertn"])
        let rawText = "Rivertn is ready"
        let rawStablePrefixLength = 7 // exactly covers "Rivertn"

        let result = table.apply(rawText, stablePrefixLength: rawStablePrefixLength, languageID: "en")
        XCTAssertEqual(result.text, "Riverton is ready")
        XCTAssertEqual(result.stablePrefixLength, 8)
        let derivedTail = String(result.text.dropFirst(result.stablePrefixLength))
        XCTAssertEqual(derivedTail, " is ready")
    }

    func testBoundaryAwareApplyWhollyStableAliasContractsBoundary() throws {
        let table = try table(language: "en", canonical: "River", aliases: ["Riverton"])
        let rawText = "Riverton is ready"
        let rawStablePrefixLength = 8 // exactly covers "Riverton"

        let result = table.apply(rawText, stablePrefixLength: rawStablePrefixLength, languageID: "en")
        XCTAssertEqual(result.text, "River is ready")
        XCTAssertEqual(result.stablePrefixLength, 5)
        let derivedTail = String(result.text.dropFirst(result.stablePrefixLength))
        XCTAssertEqual(derivedTail, " is ready")
    }

    func testBoundaryAwareApplyInsideAliasConservativelyMapsBeforeReplacement() throws {
        let table = try table(language: "en", canonical: "Riverton", aliases: ["Rivertn"])

        // Boundary inside alias at index 0..<7 with no preceding prefix
        let rawText1 = "Rivertn is ready"
        let rawStablePrefixLength1 = 4 // bisects "Rivertn"
        let result1 = table.apply(rawText1, stablePrefixLength: rawStablePrefixLength1, languageID: "en")
        XCTAssertEqual(result1.text, "Riverton is ready")
        XCTAssertEqual(result1.stablePrefixLength, 0)
        let derivedTail1 = String(result1.text.dropFirst(result1.stablePrefixLength))
        XCTAssertEqual(derivedTail1, "Riverton is ready")

        // Boundary inside alias at index 6..<13 with preceding stable prefix "Hello " (6 chars)
        let rawText2 = "Hello Rivertn is ready"
        let rawStablePrefixLength2 = 10 // bisects "Rivertn" (6 + 4)
        let result2 = table.apply(rawText2, stablePrefixLength: rawStablePrefixLength2, languageID: "en")
        XCTAssertEqual(result2.text, "Hello Riverton is ready")
        XCTAssertEqual(result2.stablePrefixLength, 6)
        let derivedTail2 = String(result2.text.dropFirst(result2.stablePrefixLength))
        XCTAssertEqual(derivedTail2, "Riverton is ready")
    }

    func testBoundaryAwareApplyEntirelyMutableLeavesPreAliasBoundaryUnchanged() throws {
        let table = try table(language: "en", canonical: "Riverton", aliases: ["Rivertn"])

        // Alias starts after the stable boundary
        let rawText1 = "Hello Rivertn is ready"
        let rawStablePrefixLength1 = 5 // covers "Hello"
        let result1 = table.apply(rawText1, stablePrefixLength: rawStablePrefixLength1, languageID: "en")
        XCTAssertEqual(result1.text, "Hello Riverton is ready")
        XCTAssertEqual(result1.stablePrefixLength, 5)
        let derivedTail1 = String(result1.text.dropFirst(result1.stablePrefixLength))
        XCTAssertEqual(derivedTail1, " Riverton is ready")

        // Alias starts immediately at the stable boundary (index 6 after "Hello ")
        let rawText2 = "Hello Rivertn is ready"
        let rawStablePrefixLength2 = 6 // covers "Hello ", alias starts at index 6
        let result2 = table.apply(rawText2, stablePrefixLength: rawStablePrefixLength2, languageID: "en")
        XCTAssertEqual(result2.text, "Hello Riverton is ready")
        XCTAssertEqual(result2.stablePrefixLength, 6)
        let derivedTail2 = String(result2.text.dropFirst(result2.stablePrefixLength))
        XCTAssertEqual(derivedTail2, "Riverton is ready")
    }

    func testBoundaryAwareApplyNoMatchAndBoundaryClamping() throws {
        let table = try table(language: "en", canonical: "Riverton", aliases: ["Rivertn"])

        // No match in text
        let noMatchText = "The quick brown fox"
        let resultNoMatch = table.apply(noMatchText, stablePrefixLength: 9, languageID: "en")
        XCTAssertEqual(resultNoMatch.text, "The quick brown fox")
        XCTAssertEqual(resultNoMatch.stablePrefixLength, 9)
        XCTAssertEqual(String(resultNoMatch.text.dropFirst(resultNoMatch.stablePrefixLength)), " brown fox")

        // Empty table
        let emptyResult = SpeechCorrectionTable.empty.apply("Hello world", stablePrefixLength: 5, languageID: "en")
        XCTAssertEqual(emptyResult.text, "Hello world")
        XCTAssertEqual(emptyResult.stablePrefixLength, 5)

        // Empty text
        let emptyTextResult = table.apply("", stablePrefixLength: 0, languageID: "en")
        XCTAssertEqual(emptyTextResult.text, "")
        XCTAssertEqual(emptyTextResult.stablePrefixLength, 0)

        // Boundary at 0
        let zeroBoundary = table.apply("Rivertn is ready", stablePrefixLength: 0, languageID: "en")
        XCTAssertEqual(zeroBoundary.text, "Riverton is ready")
        XCTAssertEqual(zeroBoundary.stablePrefixLength, 0)

        // Boundary at text end
        let endBoundary = table.apply("Rivertn is ready", stablePrefixLength: "Rivertn is ready".count, languageID: "en")
        XCTAssertEqual(endBoundary.text, "Riverton is ready")
        XCTAssertEqual(endBoundary.stablePrefixLength, "Riverton is ready".count)

        // Negative boundary clamped to 0
        let negativeBoundary = table.apply("Rivertn is ready", stablePrefixLength: -5, languageID: "en")
        XCTAssertEqual(negativeBoundary.text, "Riverton is ready")
        XCTAssertEqual(negativeBoundary.stablePrefixLength, 0)

        // Overflow boundary clamped to text count
        let overflowBoundary = table.apply("Rivertn is ready", stablePrefixLength: 999, languageID: "en")
        XCTAssertEqual(overflowBoundary.text, "Riverton is ready")
        XCTAssertEqual(overflowBoundary.stablePrefixLength, "Riverton is ready".count)
    }

    func testBoundaryAwareApplyUnicodeAndCJKPrefix() throws {
        // CJK character expansion: "深學" (2 chars) -> "深度學習" (4 chars)
        let cjkTable = try table(language: "zh-Hant", canonical: "深度學習", aliases: ["深學"])

        // Wholly stable CJK alias at index 0..<2
        let rawCJK = "深學模型發布" // 6 Character count
        let whollyStable = cjkTable.apply(rawCJK, stablePrefixLength: 2, languageID: "zh-Hant")
        XCTAssertEqual(whollyStable.text, "深度學習模型發布")
        XCTAssertEqual(whollyStable.stablePrefixLength, 4)
        XCTAssertEqual(String(whollyStable.text.dropFirst(whollyStable.stablePrefixLength)), "模型發布")

        // Boundary inside CJK alias at index 1 (bisecting "深學")
        let insideCJK = cjkTable.apply(rawCJK, stablePrefixLength: 1, languageID: "zh-Hant")
        XCTAssertEqual(insideCJK.text, "深度學習模型發布")
        XCTAssertEqual(insideCJK.stablePrefixLength, 0)
        XCTAssertEqual(String(insideCJK.text.dropFirst(insideCJK.stablePrefixLength)), "深度學習模型發布")

        // CJK alias with prefix: "今天深學模型" (6 chars), alias at 2..<4
        let rawWithPrefix = "今天深學模型"
        let prefixWhollyStable = cjkTable.apply(rawWithPrefix, stablePrefixLength: 4, languageID: "zh-Hant")
        XCTAssertEqual(prefixWhollyStable.text, "今天深度學習模型")
        XCTAssertEqual(prefixWhollyStable.stablePrefixLength, 6)
        XCTAssertEqual(String(prefixWhollyStable.text.dropFirst(prefixWhollyStable.stablePrefixLength)), "模型")

        let prefixInside = cjkTable.apply(rawWithPrefix, stablePrefixLength: 3, languageID: "zh-Hant")
        XCTAssertEqual(prefixInside.text, "今天深度學習模型")
        XCTAssertEqual(prefixInside.stablePrefixLength, 2)
        XCTAssertEqual(String(prefixInside.text.dropFirst(prefixInside.stablePrefixLength)), "深度學習模型")

        // Unicode diacritics / Latin expansion: "café" (4 chars) -> "Caffè" (5 chars)
        let cafeTable = try table(language: "en", canonical: "Caffè", aliases: ["café"])
        let cafeResult = cafeTable.apply("café latte please", stablePrefixLength: 4, languageID: "en")
        XCTAssertEqual(cafeResult.text, "Caffè latte please")
        XCTAssertEqual(cafeResult.stablePrefixLength, 5)
        XCTAssertEqual(String(cafeResult.text.dropFirst(cafeResult.stablePrefixLength)), " latte please")
    }

    func testBoundaryAwareApplyMultipleReplacementsAcrossBoundary() throws {
        let multiTable = try SpeechCorrectionService.compile(Data("""
        {
          "version": 1,
          "languages": {
            "en": {
              "corrections": [
                {"canonical": "ACME", "aliases": ["ACM"]},
                {"canonical": "Riverton", "aliases": ["Rivertn"]}
              ]
            }
          }
        }
        """.utf8))

        // Raw: "ACM is better than Rivertn" (count: 26)
        // Alias 1 "ACM" at 0..<3 (length 3 -> 4)
        // Alias 2 "Rivertn" at 19..<26 (length 7 -> 8)

        // Case 1: stablePrefixLength = 3 ("ACM" wholly stable, "Rivertn" wholly mutable)
        let result1 = multiTable.apply("ACM is better than Rivertn", stablePrefixLength: 3, languageID: "en")
        XCTAssertEqual(result1.text, "ACME is better than Riverton")
        XCTAssertEqual(result1.stablePrefixLength, 4)
        XCTAssertEqual(String(result1.text.dropFirst(result1.stablePrefixLength)), " is better than Riverton")

        // Case 2: stablePrefixLength = 22 (inside "Rivertn", 19 < 22 < 26)
        // Replacement 1 is wholly stable -> 4 chars ("ACME")
        // Middle text " is better than " -> 16 chars
        // Boundary inside Replacement 2 -> conservatively maps before Replacement 2 (output index 4 + 16 = 20)
        let result2 = multiTable.apply("ACM is better than Rivertn", stablePrefixLength: 22, languageID: "en")
        XCTAssertEqual(result2.text, "ACME is better than Riverton")
        XCTAssertEqual(result2.stablePrefixLength, 20)
        XCTAssertEqual(String(result2.text.dropFirst(result2.stablePrefixLength)), "Riverton")

        // Case 3: stablePrefixLength = 26 (both replacements wholly stable)
        let result3 = multiTable.apply("ACM is better than Rivertn", stablePrefixLength: 26, languageID: "en")
        XCTAssertEqual(result3.text, "ACME is better than Riverton")
        XCTAssertEqual(result3.stablePrefixLength, 28) // 4 + 16 + 8 = 28
        XCTAssertEqual(String(result3.text.dropFirst(result3.stablePrefixLength)), "")
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
