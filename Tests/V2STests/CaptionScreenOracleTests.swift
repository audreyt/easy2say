import XCTest

/// Proves the screen oracle is not vacuous: each defect shape it claims to catch
/// is caught, and ordinary caption evolution passes clean.
final class CaptionScreenOracleTests: XCTestCase {
    private typealias L = ObservedLine

    private func kinds(_ steps: [(TimeInterval, [L])]) -> [CaptionViolation.Kind] {
        CaptionScreenOracle.evaluate(steps.map { ObservedScreen(time: $0.0, panes: ["p": $0.1]) })
            .violations.map(\.kind)
    }

    func testOrdinaryGrowthScrollAndRevisionPassClean() {
        let report = CaptionScreenOracle.evaluate([
            ([L("Good", stable: 0, startsRow: true)]),
            ([L("Good morning", stable: 4, startsRow: true)]),
            ([L("Good morning, every", stable: 12, startsRow: true)]),
            ([L("Good morning, everyone.", startsRow: true)]),
            ([L("Good morning, everyone.", startsRow: true), L("Thank you for", stable: 5, startsRow: true)]),
            // Mutable tail revised.
            ([L("Good morning, everyone.", startsRow: true), L("Thank you for come", stable: 9, startsRow: true)]),
            ([L("Good morning, everyone.", startsRow: true), L("Thank you for coming to our", stable: 13, startsRow: true)]),
            // New line: the oldest line scrolls off the top.
            ([L("Thank you for coming to our", startsRow: true), L("first session", stable: 0)]),
            ([L("Thank you for coming to our", startsRow: true), L("first session today.")]),
        ].enumerated().map { ObservedScreen(time: Double($0.offset) * 0.1, panes: ["p": $0.element]) })
        XCTAssertEqual(report.violations, [])
        let m = report.metrics["p"]!
        XCTAssertEqual(m.scrollEvents, 1)
        XCTAssertGreaterThan(m.retractedCharacters, 0, "the revised tail is residual motion")
        XCTAssertEqual(m.settledReflows, 0)
    }

    func testFinalizationPunctuationAndCaseDoNotCountAsStableRetraction() {
        XCTAssertEqual(kinds([
            (0.0, [L("good morning everyone thank", startsRow: true)]),
            (0.1, [L("Good morning, everyone.", startsRow: true), L("Thank", startsRow: true)]),
        ]), [])
    }

    func testStableWordsChangingIsFlagged() {
        XCTAssertEqual(kinds([
            (0.0, [L("We will talk a boat", stable: 19, startsRow: true)]),
            (0.1, [L("We will take a vote", stable: 12, startsRow: true)]),
        ]), [.stableRetraction])
    }

    func testInPlaceHomophoneCorrectionIsMeasuredNotFlagged() {
        let steps: [(TimeInterval, [L])] = [
            (0.0, [L("這個展示他完全在裝置上執", stable: 11, startsRow: true)]),
            (0.1, [L("這個展示它完全在裝置上執行", startsRow: true)]),
        ]
        XCTAssertEqual(kinds(steps), [])
        let report = CaptionScreenOracle.evaluate(steps.map { ObservedScreen(time: $0.0, panes: ["p": $0.1]) })
        XCTAssertEqual(report.metrics["p"]?.inPlaceCorrections, 1)
        // An inserted character at finalization is a small correction too.
        XCTAssertEqual(kinds([
            (0.0, [L("在講者說完之前會一直改", stable: 10, startsRow: true)]),
            (0.1, [L("在講者說完之前都會一直改變", startsRow: true)]),
        ]), [])
        // Losing a sentence is not.
        XCTAssertEqual(kinds([
            (0.0, [
                L("今天我們要示範", startsRow: true),
                L("Good morning, everyone.", startsRow: true),
                L("Thank you for joining", stable: 13, startsRow: true),
            ]),
            (0.1, [
                L("今天我們要示範", startsRow: true),
                L("Thank you for joining us", stable: 13, startsRow: true),
            ]),
        ]), [.stableRetraction])
        // Three substitutions are no longer a small in-place correction.
        XCTAssertEqual(kinds([
            (0.0, [L("這個展示他完全在裝置上執", stable: 11, startsRow: true)]),
            (0.1, [L("那個展覽它完全在裝置上執行", startsRow: true)]),
        ]), [.stableRetraction])
    }

    func testRowThatBlinksOutAndBackIsVanish() {
        XCTAssertEqual(kinds([
            (0.0, [L("大家早安。", startsRow: true), L("謝謝各位今天", stable: 0, startsRow: true)]),
            (0.1, [L("大家早安。", startsRow: true)]),
            (0.2, [L("大家早安。", startsRow: true), L("謝謝各位今天來參加", stable: 0, startsRow: true)]),
        ]), [.vanish])
    }

    func testRowReturningAfterWindowIsNotVanish() {
        XCTAssertEqual(kinds([
            (0.0, [L("Nothing should blink.", startsRow: true)]),
            (0.1, [L("Words must", stable: 0, startsRow: true)]),
            (5.0, [L("Words must", startsRow: true), L("Nothing should blink.", startsRow: true)]),
        ]), [])
    }

    func testPaneBlankingBetweenCaptionsIsBlink() {
        XCTAssertEqual(kinds([
            (0.0, [L("Good morning everyone", startsRow: true)]),
            (0.1, []),
            (0.3, [L("Good morning everyone", startsRow: true)]),
        ]), [.blink, .vanish])
    }

    func testLineMovingDownIsFlagged() {
        // Viewport scrolled back down when the live row shrank.
        XCTAssertEqual(kinds([
            (0.0, [L("Thank you for coming to our", startsRow: true), L("first session", stable: 0)]),
            (0.1, [L("Good morning, everyone.", startsRow: true), L("Thank you for coming to our", startsRow: true)]),
        ]), [.movedDown])
    }

    func testDuplicateRowsAreFlagged() {
        XCTAssertEqual(kinds([
            (0.0, [L("Hello world.", startsRow: true), L("Hello world", stable: 0, startsRow: true)]),
        ]), [.duplicateRow])
    }

    func testScrolledOffLineReturningIsResurrect() {
        XCTAssertTrue(kinds([
            (0.0, [L("Good morning, everyone.", startsRow: true), L("Thank you for coming", startsRow: true)]),
            (0.1, [L("Thank you for coming", startsRow: true), L("today", stable: 0)]),
            (0.2, [L("Good morning, everyone.", startsRow: true), L("Thank you for coming today", startsRow: true)]),
        ]).contains(.resurrect))
    }

    func testReflowOfSettledLineIsMeasured() {
        let report = CaptionScreenOracle.evaluate([
            ObservedScreen(time: 0, panes: ["p": [L("alpha beta gamma", startsRow: true), L("delta epsilon"), L("zeta", stable: 0)]]),
            ObservedScreen(time: 0.1, panes: ["p": [L("alpha beta", startsRow: true), L("gamma delta epsilon"), L("zeta eta", stable: 0)]]),
        ])
        XCTAssertGreaterThan(report.metrics["p"]!.settledReflows, 0)
    }
}
