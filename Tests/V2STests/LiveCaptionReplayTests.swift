import CoreGraphics
import XCTest
@testable import v2s

final class LiveCaptionReplayTests: XCTestCase {
    func testPrefixExtensionIsSameUtteranceUsingDraftText() {
        let relation = LiveCaptionReplay.relation(
            committedSourceText: "Hello everyone",
            draftSourceText: "Hello everyone, hello."
        )

        XCTAssertEqual(relation, .sameUtterance(displaySourceText: "Hello everyone, hello."))
    }

    func testSuffixOverlapJoinsIntoOneTurn() {
        let relation = LiveCaptionReplay.relation(
            committedSourceText: "Welcome to our first",
            draftSourceText: "first session."
        )

        XCTAssertEqual(relation, .sameUtterance(displaySourceText: "Welcome to our first session."))
    }

    func testLowercaseContinuationJoinsWithoutOverlap() {
        let relation = LiveCaptionReplay.relation(
            committedSourceText: "Welcome to our first",
            draftSourceText: "session."
        )

        XCTAssertEqual(relation, .sameUtterance(displaySourceText: "Welcome to our first session."))
    }

    func testCompletedSentenceStaysIndependentOfNextUtterance() {
        let relation = LiveCaptionReplay.relation(
            committedSourceText: "Hello everyone, hello.",
            draftSourceText: "Welcome to our first session."
        )

        XCTAssertEqual(relation, .independent)
    }

    func testCJKOverlapJoinsIntoOneTurn() {
        let relation = LiveCaptionReplay.relation(
            committedSourceText: "歡迎來到這裡",
            draftSourceText: "這裡變成聚落"
        )

        XCTAssertEqual(relation, .sameUtterance(displaySourceText: "歡迎來到這裡變成聚落"))
    }

    func testCJKCompletedSentenceStaysIndependent() {
        let relation = LiveCaptionReplay.relation(
            committedSourceText: "歡迎來到這裡。",
            draftSourceText: "我們期待把這裡變成聚落。"
        )

        XCTAssertEqual(relation, .independent)
    }

    func testShrinkingHypothesisStaysSameUtterance() {
        let relation = LiveCaptionReplay.relation(
            committedSourceText: "Hello everyone, hello.",
            draftSourceText: "Hello everyone"
        )

        XCTAssertEqual(relation, .sameUtterance(displaySourceText: "Hello everyone"))
    }

    func testEllipsisClauseJoinsLowercaseContinuation() {
        let relation = LiveCaptionReplay.relation(
            committedSourceText: "And on our side...",
            draftSourceText: "we also have some other spaces."
        )

        XCTAssertEqual(
            relation,
            .sameUtterance(displaySourceText: "And on our side... we also have some other spaces.")
        )
    }

    func testCaptionLineRisePlanTriggersOnlyForPrefixAddedVisualLines() {
        let width: CGFloat = 320
        func snap(_ text: String, lines: Int, width w: CGFloat = width) -> CaptionLineRiseLayoutSnapshot {
            CaptionLineRiseLayoutSnapshot(text: text, lineCount: lines, width: w)
        }

        let cases: [(
            String,
            CaptionLineRiseLayoutSnapshot?,
            CaptionLineRiseLayoutSnapshot,
            Set<Int>
        )] = [
            ("empty→first line", .empty(width: width), snap("Hello", lines: 1), [0]),
            ("one→two", snap("Hello", lines: 1), snap("Hello everyone", lines: 2), [1]),
            ("two→three", snap("Hello everyone", lines: 2), snap("Hello everyone today", lines: 3), [2]),
            ("multi-line append only added indices", snap("Hello", lines: 1), snap("Hello everyone today", lines: 3), [1, 2]),
            ("strict-prefix same-line", snap("Hello", lines: 1), snap("Hello everyone", lines: 1), []),
            ("identical text layout-count change", snap("Hello", lines: 1), snap("Hello", lines: 2), []),
            ("identical text width reflow", snap("Hello everyone", lines: 1), snap("Hello everyone", lines: 2, width: 160), []),
            ("rewrite/correction", snap("Hello world", lines: 1), snap("Hallo world", lines: 2), []),
            ("line decrease", snap("Hello everyone today", lines: 2), snap("Hello everyone today!", lines: 1), []),
            ("text removal", snap("Hello everyone", lines: 2), snap("Hello", lines: 1), []),
            ("promotion/same text", snap("Hello everyone.", lines: 1), snap("Hello everyone.", lines: 1), []),
        ]

        for (name, previous, candidate, expected) in cases {
            let plan = CaptionLineRise.plan(previous: previous, candidate: candidate)
            XCTAssertEqual(plan.enteringLineIndices, expected, name)
            XCTAssertEqual(plan.isEmpty, expected.isEmpty, name)
            if expected.isEmpty {
                XCTAssertEqual(plan, .settled, name)
            }
        }
    }

    func testCaptionLineRiseMotionIsLineLocal() {
        XCTAssertEqual(CaptionLineRise.duration, 0.24, accuracy: 0.0001)
        XCTAssertEqual(CaptionLineRise.translationRatio, 0.007, accuracy: 0.0001)
        XCTAssertEqual(CaptionLineRise.translation(forWidth: 1000), 7, accuracy: 0.0001)
    }
}
