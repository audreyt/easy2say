import XCTest
@testable import v2s

@available(macOS 26.0, *)
final class ConversationLaneTests: XCTestCase {
    private func update(
        start: Double,
        end: Double,
        spans: [ConversationLane.TimedSpan]
    ) -> ConversationLane.Update {
        ConversationLane.Update(
            side: .secondary,
            text: spans.map(\.text).joined(),
            confidence: 0.8,
            isFinal: true,
            startSeconds: start,
            endSeconds: end,
            spans: spans
        )
    }

    func testTrimPreservesNewSpansFromResultThatCrossesCommittedBoundary() throws {
        let result = update(
            start: 0,
            end: 2,
            spans: [
                .init(text: "old ", confidence: 0.9, startSeconds: 0, endSeconds: 1),
                .init(text: "new", confidence: 0.7, startSeconds: 1.1, endSeconds: 2),
            ]
        )

        let pending = try XCTUnwrap(
            result.trimmingAudio(beforeOrAt: 1, tolerance: 0.05)
        )

        XCTAssertEqual(pending.text, "new")
        XCTAssertEqual(pending.startSeconds, 1.1, accuracy: 0.001)
        XCTAssertEqual(pending.endSeconds, 2, accuracy: 0.001)
        let conf = try XCTUnwrap(pending.confidence)
        XCTAssertEqual(conf, 0.7, accuracy: 0.001)
    }

    func testTrimDropsResultWhoseRunsAreEntirelyCommitted() {
        let result = update(
            start: 0,
            end: 1,
            spans: [
                .init(text: "old", confidence: 0.9, startSeconds: 0, endSeconds: 1),
            ]
        )

        XCTAssertNil(result.trimmingAudio(beforeOrAt: 1, tolerance: 0.05))
    }

    func testTrimDropsUnsplitResultThatOverlapsCommittedAudio() {
        let result = ConversationLane.Update(
            side: .secondary,
            text: "old and new",
            confidence: 0.8,
            isFinal: true,
            startSeconds: 0,
            endSeconds: 2,
            spans: []
        )

        XCTAssertNil(result.trimmingAudio(beforeOrAt: 1, tolerance: 0.05))
    }

    func testTrimKeepsWhollyNewResultWhenRunAttributesAreMissing() throws {
        let result = ConversationLane.Update(
            side: .secondary,
            text: "new",
            confidence: 0.8,
            isFinal: true,
            startSeconds: 1.1,
            endSeconds: 2,
            spans: []
        )

        XCTAssertNotNil(result.trimmingAudio(beforeOrAt: 1, tolerance: 0.05))
    }
}
