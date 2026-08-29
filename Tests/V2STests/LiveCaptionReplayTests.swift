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
}
