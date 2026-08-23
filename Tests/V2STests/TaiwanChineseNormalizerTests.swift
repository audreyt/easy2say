import XCTest
@testable import v2s

final class TaiwanChineseNormalizerTests: XCTestCase {
    private let normalizer = TaiwanChineseNormalizer()

    func testConvertsSimplifiedCharactersAndTaiwanTerms() {
        XCTAssertEqual(
            normalizer.normalize("软件保存到内存和硬盘"),
            "軟體儲存到記憶體和硬碟"
        )
    }

    func testLongestPhraseWinsOverPrefix() {
        XCTAssertEqual(
            normalizer.normalize("以太网络路由器"),
            "乙太網路路由器"
        )
    }

    func testDoesNotCascadeReplacementOutput() {
        XCTAssertEqual(normalizer.normalize("创建文件"), "建立檔案")
    }

    func testTraditionalTextWithoutDictionaryMatchStaysUnchanged() {
        XCTAssertEqual(normalizer.normalize("乾杯，裡面請坐。"), "乾杯，裡面請坐。")
    }
}
