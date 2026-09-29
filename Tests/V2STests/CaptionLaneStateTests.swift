import XCTest
@testable import v2s

final class CaptionLaneStateTests: XCTestCase {
    private func event(
        _ text: String,
        isFinal: Bool,
        rangeStart: Int,
        duration: Int,
        audioFed: Int,
        finalization: Int? = nil,
        runs: [AnalyzerRun] = [],
        language: String = "en"
    ) -> AnalyzerResultEvent {
        AnalyzerResultEvent(
            lane: CaptionLaneID(sessionID: 1, languageID: language),
            isFinal: isFinal,
            rangeStartMs: rangeStart,
            rangeDurationMs: duration,
            finalizationMs: finalization,
            text: text,
            runs: runs,
            audioFedMs: audioFed,
            speakerIndex: nil
        )
    }

    func testFinalAppendsAndReplacesVolatile() {
        var lane = CaptionLaneState()
        lane.apply(event("Hello wo", isFinal: false, rangeStart: 0, duration: 0, audioFed: 500))
        lane.apply(event("Hello world", isFinal: false, rangeStart: 0, duration: 0, audioFed: 900))
        lane.apply(event("Hello world.", isFinal: true, rangeStart: 0, duration: 900, audioFed: 1100))
        XCTAssertEqual(lane.text, "Hello world.")
        XCTAssertEqual(lane.volatileText, "")
        XCTAssertEqual(lane.finalCharacterCount, 12)
        XCTAssertEqual(lane.finals.count, 1)

        lane.apply(event(" Next", isFinal: false, rangeStart: 900, duration: 0, audioFed: 1500))
        XCTAssertEqual(lane.text, "Hello world. Next")
        XCTAssertEqual(lane.finalCharacterCount, 12)
    }

    func testFinalWithSameRangeStartReplaces() {
        var lane = CaptionLaneState()
        lane.apply(event("Hello.", isFinal: true, rangeStart: 0, duration: 900, audioFed: 1000))
        lane.apply(event("Hello!", isFinal: true, rangeStart: 0, duration: 900, audioFed: 1200))
        XCTAssertEqual(lane.text, "Hello!")
        XCTAssertEqual(lane.finals.count, 1)
    }

    func testVolatileWhoseRangeStartsBeforeFinalEndIsDropped() {
        var lane = CaptionLaneState()
        lane.apply(event(" tail", isFinal: false, rangeStart: 800, duration: 0, audioFed: 1000))
        lane.apply(event("Hello.", isFinal: true, rangeStart: 0, duration: 900, audioFed: 1100))
        // volatile rangeStart 800 < final end 900 → replaced
        XCTAssertEqual(lane.text, "Hello.")
        XCTAssertEqual(lane.volatileText, "")

        // Volatile at/after the final end survives.
        lane.apply(event(" again", isFinal: false, rangeStart: 900, duration: 0, audioFed: 1500))
        XCTAssertEqual(lane.text, "Hello. again")
    }

    func testStaleVolatileBehindFinalizationFrontierIsIgnored() {
        var lane = CaptionLaneState()
        lane.apply(event("First.", isFinal: true, rangeStart: 0, duration: 2000, audioFed: 2000))
        lane.apply(event("Second.", isFinal: true, rangeStart: 2000, duration: 1500, audioFed: 3600))
        // finalizedThrough = 3500; stale bound = 3450
        lane.apply(event("ghost text", isFinal: false, rangeStart: 3000, duration: 0, audioFed: 3800))
        XCTAssertEqual(lane.text, "First.Second.")
        lane.apply(event(" live", isFinal: false, rangeStart: 3500, duration: 0, audioFed: 3900))
        XCTAssertEqual(lane.text, "First.Second. live")
    }

    func testFinalizationTimeDrivesFrontier() {
        var lane = CaptionLaneState()
        lane.apply(
            event("Done.", isFinal: true, rangeStart: 0, duration: 900, audioFed: 2000, finalization: 5000)
        )
        lane.apply(event("old", isFinal: false, rangeStart: 4900, duration: 0, audioFed: 5100))
        XCTAssertEqual(lane.text, "Done.")   // 4900 < 5000-50 → stale
        lane.apply(event("new", isFinal: false, rangeStart: 4960, duration: 0, audioFed: 5200))
        XCTAssertEqual(lane.text, "Done.new")   // 4960 ≥ 4950 → accepted
    }

    func testArrivalStampsSurviveAppendAndRebaseOnChange() {
        var lane = CaptionLaneState()
        lane.apply(event("abc", isFinal: false, rangeStart: 0, duration: 0, audioFed: 100))
        XCTAssertEqual(lane.arrivalMs, [100, 100, 100])
        lane.apply(event("abcd", isFinal: false, rangeStart: 0, duration: 0, audioFed: 200))
        XCTAssertEqual(lane.arrivalMs, [100, 100, 100, 200])
        // A final covering the same characters keeps their stamps.
        lane.apply(event("abcd.", isFinal: true, rangeStart: 0, duration: 400, audioFed: 900))
        XCTAssertEqual(lane.arrivalMs, [100, 100, 100, 200, 900])

        // A final that re-cases text restamps the changed characters.
        var recased = CaptionLaneState()
        recased.apply(event("abcd", isFinal: false, rangeStart: 0, duration: 0, audioFed: 200))
        recased.apply(event("Abcd.", isFinal: true, rangeStart: 0, duration: 400, audioFed: 900))
        XCTAssertEqual(recased.arrivalMs, [900, 900, 900, 900, 900])
    }

    func testDropLeadingFinalsCompactsLeadingTextOnly() {
        var lane = CaptionLaneState()
        lane.apply(
            event("ab", isFinal: true, rangeStart: 0, duration: 100, audioFed: 100)
        )
        lane.apply(
            event("cd", isFinal: true, rangeStart: 100, duration: 100, audioFed: 200)
        )
        lane.apply(
            event("ef", isFinal: false, rangeStart: 200, duration: 0, audioFed: 300)
        )
        XCTAssertEqual(lane.text, "abcdef")
        lane.dropLeadingFinals(1)
        XCTAssertEqual(lane.finals.map(\.text), ["cd"])
        XCTAssertEqual(lane.text, "cdef")
        XCTAssertEqual(lane.arrivalMs.count, 4)
        // The finalization frontier is audio-time state; compaction does not rewind it.
        XCTAssertEqual(lane.finalizedThroughMs, 200)
        lane.dropLeadingFinals(9)  // over-drop removes all remaining finals
        XCTAssertEqual(lane.text, "ef")
        XCTAssertEqual(lane.arrivalMs.count, 2)
        XCTAssertEqual(lane.finalizedThroughMs, 200)
    }

    func testFinalsKeepRunsAndSpeaker() throws {
        let runs = [
            AnalyzerRun(text: "Hello", startMs: 0, durationMs: 400, confidence: 0.9),
            AnalyzerRun(text: " world", startMs: 400, durationMs: 500, confidence: 0.7),
        ]
        var lane = CaptionLaneState()
        var finalEvent = event("Hello world", isFinal: true, rangeStart: 0, duration: 900, audioFed: 1000, runs: runs)
        finalEvent.speakerIndex = 2
        lane.apply(finalEvent)
        XCTAssertEqual(lane.finals[0].speakerIndex, 2)
        XCTAssertEqual(try XCTUnwrap(lane.meanConfidence(ofFinalAt: 0)), 0.8, accuracy: 0.0001)
    }
}
