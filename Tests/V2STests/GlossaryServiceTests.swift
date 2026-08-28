import Foundation
import XCTest
@testable import v2s

private final class RecordingGlossaryTranslator {
    private(set) var inputs: [String] = []
    private let response: (String) -> String

    init(response: @escaping (String) -> String) {
        self.response = response
    }

    func translate(_ input: String) async throws -> String {
        inputs.append(input)
        return response(input)
    }
}

final class GlossaryServiceTests: XCTestCase {
    private let service = GlossaryService()

    func testEmptyGlossaryReturnsTextUnchanged() {
        XCTAssertEqual(service.apply(to: "He said AI wins", glossary: [:]), "He said AI wins")
    }

    func testReplacesStandaloneLatinTerm() {
        let result = service.apply(to: "He said AI wins", glossary: ["AI": "人工智能"])
        XCTAssertEqual(result, "He said 人工智能 wins")
    }

    func testDoesNotReplaceLatinTermInsideAnotherWord() {
        let result = service.apply(to: "They repaired the airfield", glossary: ["AI": "人工智能"])
        XCTAssertEqual(result, "They repaired the airfield")
    }

    func testDoesNotReplaceLatinTermSuffixInsideAnotherWord() {
        let result = service.apply(to: "OpenAI released a model", glossary: ["AI": "人工智能"])
        XCTAssertEqual(result, "OpenAI released a model")
    }

    func testReplacesLatinTermAdjacentToCJKCharacters() {
        let result = service.apply(to: "使用AI模型", glossary: ["AI": "人工智能"])
        XCTAssertEqual(result, "使用人工智能模型")
    }

    func testReplacesLatinTermAtStringBoundariesAndBeforePunctuation() {
        let result = service.apply(to: "AI is the future. I love AI.", glossary: ["AI": "人工智能"])
        XCTAssertEqual(result, "人工智能 is the future. I love 人工智能.")
    }

    func testMatchesCaseInsensitively() {
        let result = service.apply(to: "ai everywhere", glossary: ["AI": "人工智能"])
        XCTAssertEqual(result, "人工智能 everywhere")
    }

    func testLongestEntryWinsOverShorterOverlap() {
        let result = service.apply(
            to: "I love New York",
            glossary: ["New York": "纽约", "York": "约克"]
        )
        XCTAssertEqual(result, "I love 纽约")
    }

    func testReplacesCJKTermWithoutWordBoundaries() {
        let result = service.apply(to: "这个模型很好", glossary: ["模型": "model"])
        XCTAssertEqual(result, "这个model很好")
    }

    func testDigitEdgedTermRespectsBoundaries() {
        let glossary = ["5G": "五代网络"]
        XCTAssertEqual(service.apply(to: "The 25G link", glossary: glossary), "The 25G link")
        XCTAssertEqual(service.apply(to: "用5G上网", glossary: glossary), "用五代网络上网")
    }

    func testAccentedLatinTermRespectsBoundaries() {
        let glossary = ["café": "咖啡馆"]
        XCTAssertEqual(service.apply(to: "meet at the café now", glossary: glossary), "meet at the 咖啡馆 now")
        XCTAssertEqual(service.apply(to: "cafés stay open", glossary: glossary), "cafés stay open")
    }

    func testNonLatinTermsRespectBoundaries() {
        XCTAssertEqual(
            service.apply(to: "протестирование продолжается", glossary: ["тест": "test"]),
            "протестирование продолжается"
        )
        XCTAssertEqual(
            service.apply(to: "καφές είναι έτοιμος", glossary: ["καφ": "coffee"]),
            "καφές είναι έτοιμος"
        )
        XCTAssertEqual(
            service.apply(to: "وسلامة الجميع", glossary: ["سلام": "peace"]),
            "وسلامة الجميع"
        )
    }

    func testForwardAndReverseGlossariesDoNotCorruptEachOther() {
        let forward = ["資料": "data", "人工智慧": "AI"]
        let inverse = GlossaryService.buildInverseGlossary(forward)

        XCTAssertEqual(service.apply(to: "資料與人工智慧", glossary: forward), "data與AI")
        XCTAssertEqual(service.apply(to: "data and AI", glossary: inverse), "資料 and 人工智慧")
        XCTAssertEqual(service.apply(to: "資料與人工智慧", glossary: inverse), "資料與人工智慧")
    }

    func testInverseGlossaryOmitsIdentityAndNormalizedDuplicateValues() {
        let inverse = GlossaryService.buildInverseGlossary([
            "API": "API",
            "甲": "Shared",
            "乙": "shared",
            "資料": "data",
        ])

        XCTAssertNil(inverse["API"])
        XCTAssertNil(inverse["Shared"])
        XCTAssertNil(inverse["shared"])
        XCTAssertEqual(inverse["data"], "資料")
    }

    func testInverseGlossaryDedupesIdenticalNormalizedSourceTargetPairs() {
        let inverse = GlossaryService.buildInverseGlossary([
            "AI": "人工智慧",
            "ai": "人工智慧",
            "ML": "機器學習",
        ])
        XCTAssertNotNil(inverse["人工智慧"])
        XCTAssertTrue(["AI", "ai"].contains(inverse["人工智慧"]!))
        XCTAssertEqual(inverse["機器學習"], "ML")
    }

    func testForwardTranslationPreparesLongestNonOverlappingInputAndPreservesSourceText() async throws {
        let forward = ["資料": "data", "資料庫": "database"]
        let translator = RecordingGlossaryTranslator { _ in "Review 資料庫 and 資料" }
        let original = "資料庫與資料"

        let result = try await service.translating(
            sourceText: original,
            glossary: forward,
            with: translator.translate
        )

        XCTAssertEqual(translator.inputs, ["database與data"])
        XCTAssertEqual(result.sourceText, original)
        XCTAssertEqual(result.translatedText, "Review database and data")
    }

    func testReverseTranslationUsesOnlyInverseMapAndPreservesSourceText() async throws {
        let forward = ["資料": "data", "資料庫": "database"]
        let inverse = GlossaryService.buildInverseGlossary(forward)
        let translator = RecordingGlossaryTranslator { $0 }
        let original = "database and data with 資料"

        let result = try await service.translating(
            sourceText: original,
            glossary: inverse,
            with: translator.translate
        )

        XCTAssertEqual(translator.inputs, ["資料庫 and 資料 with 資料"])
        XCTAssertEqual(result.sourceText, original)
        XCTAssertEqual(result.translatedText, "資料庫 and 資料 with 資料")
    }

    func testTranslationWithNoGlossaryMatchIsIdentityForInputAndSourceText() async throws {
        let translator = RecordingGlossaryTranslator { $0 }
        let original = "An ordinary sentence."

        let result = try await service.translating(
            sourceText: original,
            glossary: ["資料": "data"],
            with: translator.translate
        )

        XCTAssertEqual(translator.inputs, [original])
        XCTAssertEqual(result.sourceText, original)
        XCTAssertEqual(result.translatedText, original)
    }
}
