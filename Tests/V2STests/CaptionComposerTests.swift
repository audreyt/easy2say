import XCTest
@testable import v2s

final class CaptionComposerTests: XCTestCase {
    private func event(
        _ text: String,
        isFinal: Bool,
        rangeStart: Int,
        duration: Int = 0,
        audioFed: Int,
        runs: [AnalyzerRun] = [],
        language: String = "en"
    ) -> AnalyzerResultEvent {
        AnalyzerResultEvent(
            lane: CaptionLaneID(sessionID: 1, languageID: language),
            isFinal: isFinal,
            rangeStartMs: rangeStart,
            rangeDurationMs: duration,
            finalizationMs: nil,
            text: text,
            runs: runs,
            audioFedMs: audioFed,
            speakerIndex: nil
        )
    }

    private func lane(_ events: [AnalyzerResultEvent]) -> CaptionLaneState {
        var lane = CaptionLaneState()
        for event in events { lane.apply(event) }
        return lane
    }

    private func compose(
        _ primary: CaptionLaneState,
        _ secondary: CaptionLaneState? = nil,
        secondaryLanguageID: String = ""
    ) -> [ComposedRow] {
        CaptionComposer.compose(
            primary: primary,
            secondary: secondary,
            config: ComposerConfig(primaryLanguageID: "zh-Hant", secondaryLanguageID: secondaryLanguageID)
        )
    }

    // MARK: - Sentence splitting

    func testSplitsAtSentenceTerminators() {
        let lane = lane([
            event("Hello world. How are you? Fine!", isFinal: false, rangeStart: 0, audioFed: 900)
        ])
        let rows = compose(lane)
        XCTAssertEqual(rows.map(\.text), ["Hello world.", "How are you?", "Fine!"])
        XCTAssertEqual(rows.map(\.isTerminated), [true, true, true])
    }

    func testAbbreviationAndDecimalAndEllipsisDoNotTerminate() {
        let lane = lane([
            event(
                "Dr. Smith is 3.5 miles away... he is late. Mr. Jones too.",
                isFinal: false, rangeStart: 0, audioFed: 900
            )
        ])
        let rows = compose(lane)
        XCTAssertEqual(
            rows.map(\.text),
            ["Dr. Smith is 3.5 miles away... he is late.", "Mr. Jones too."]
        )
    }

    func testCJKTerminatorsSplitImmediately() {
        let lane = lane([
            event("大家早安。謝謝各位！好嗎？", isFinal: false, rangeStart: 0, audioFed: 900, language: "zh-Hant")
        ])
        let rows = compose(lane)
        XCTAssertEqual(rows.map(\.text), ["大家早安。", "謝謝各位！", "好嗎？"])
    }

    func testPunctuationOnlyFragmentAttachesToPreviousRow() {
        var lane = CaptionLaneState()
        lane.apply(event("Done.", isFinal: true, rangeStart: 0, duration: 900, audioFed: 900))
        lane.apply(event(" ?", isFinal: false, rangeStart: 900, duration: 0, audioFed: 1000))
        let rows = compose(lane)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].text, "Done. ?")
        XCTAssertTrue(rows[0].isTerminated)
    }

    // MARK: - Stable length, final, arrival, speaker

    func testLastVolatileRowStablePrefixDropsTrailingToken() {
        let lane = lane([
            event("One. Two thr", isFinal: false, rangeStart: 0, audioFed: 900)
        ])
        let rows = compose(lane)
        XCTAssertEqual(rows[0].stableLength, rows[0].text.count)     // not last
        XCTAssertEqual(rows[1].text, "Two thr")
        XCTAssertEqual(rows[1].stableLength, 3)                       // "Two"
    }

    func testLastCJKRowDropsFinalCharacter() {
        let lane = lane([
            event("大家早安。我們開始", isFinal: false, rangeStart: 0, audioFed: 900, language: "zh-Hant")
        ])
        let rows = compose(lane)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1].stableLength, 3)                       // "我們開始" - 1
    }

    func testFinalRowIsFullyStable() {
        let lane = lane([
            event("Done.", isFinal: true, rangeStart: 0, duration: 900, audioFed: 900),
            event(" More", isFinal: false, rangeStart: 900, audioFed: 1000),
        ])
        let rows = compose(lane)
        XCTAssertTrue(rows[0].isFinal)
        XCTAssertFalse(rows[1].isFinal)
        XCTAssertEqual(rows[0].lastArrivalMs, 900)
        XCTAssertEqual(rows[1].lastArrivalMs, 1000)
    }

    func testSpeakerIndexComesFromFinalCoveringFirstCharacter() {
        var lane = CaptionLaneState()
        var first = event("Speaker one.", isFinal: true, rangeStart: 0, duration: 900, audioFed: 900)
        first.speakerIndex = 3
        lane.apply(first)
        var second = event(" Speaker two.", isFinal: true, rangeStart: 900, duration: 900, audioFed: 1800)
        second.speakerIndex = 4
        lane.apply(second)
        let rows = compose(lane)
        XCTAssertEqual(rows[0].speakerIndex, 3)
        XCTAssertEqual(rows[1].speakerIndex, 4)
    }

    // MARK: - Dual lane

    /// zh-TW transcript with embedded English-looking spans, plus an en-US lane.
    private func dualLanes(
        primaryText: [(text: String, final: Bool, start: Int, end: Int)],
        primaryFedMs: Int,
        secondaryFinals: [(text: String, start: Int, end: Int, confidence: Double)],
        secondaryVolatile: (text: String, start: Int)? = nil
    ) -> (CaptionLaneState, CaptionLaneState) {
        var primary = CaptionLaneState()
        for (index, part) in primaryText.enumerated() {
            primary.apply(
                event(
                    part.text,
                    isFinal: part.final,
                    rangeStart: part.start,
                    duration: part.end - part.start,
                    audioFed: primaryFedMs + index,
                    language: "zh-Hant"
                )
            )
        }
        var secondary = CaptionLaneState()
        for (index, part) in secondaryFinals.enumerated() {
            secondary.apply(
                event(
                    part.text,
                    isFinal: true,
                    rangeStart: part.start,
                    duration: part.end - part.start,
                    audioFed: 10_000 + index,
                    runs: [AnalyzerRun(text: part.text, startMs: part.start, durationMs: part.end - part.start, confidence: part.confidence)],
                    language: "en"
                )
            )
        }
        if let volatile = secondaryVolatile {
            secondary.apply(
                event(volatile.text, isFinal: false, rangeStart: volatile.start, audioFed: 20_000, language: "en")
            )
        }
        return (primary, secondary)
    }

    func testShortInlineLatinStaysInHanRow() {
        let (primary, secondary) = dualLanes(
            primaryText: [("字幕有 demo 展示", true, 0, 1000)],
            primaryFedMs: 1000,
            secondaryFinals: []
        )
        let rows = CaptionComposer.compose(
            primary: primary,
            secondary: secondary,
            config: ComposerConfig(primaryLanguageID: "zh-Hant", secondaryLanguageID: "en")
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].languageID, "zh-Hant")
        XCTAssertEqual(rows[0].text, "字幕有 demo 展示")
    }

    func testQualifyingLatinSegmentRoutesToSecondary() {
        let (primary, secondary) = dualLanes(
            primaryText: [("字幕完成。Good morning everyone today。結束", true, 0, 20_000)],
            primaryFedMs: 5_000,
            secondaryFinals: [(" Good morning, everyone today.", 3_000, 5_000, 0.9)],
            secondaryVolatile: nil
        )
        let rows = CaptionComposer.compose(
            primary: primary,
            secondary: secondary,
            config: ComposerConfig(primaryLanguageID: "zh-Hant", secondaryLanguageID: "en")
        )
        XCTAssertEqual(rows.map(\.languageID), ["zh-Hant", "en", "zh-Hant"])
        XCTAssertEqual(rows[1].text, "Good morning, everyone today.")
    }

    func testLowConfidenceSecondaryFallsBackToPrimaryLatin() {
        let (primary, secondary) = dualLanes(
            primaryText: [("中文。God morning everyone", true, 0, 10_000)],
            primaryFedMs: 10_000,
            secondaryFinals: [("gobble dy gook", 0, 9_000, 0.2)]
        )
        let rows = CaptionComposer.compose(
            primary: primary,
            secondary: secondary,
            config: ComposerConfig(primaryLanguageID: "zh-Hant", secondaryLanguageID: "en")
        )
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1].languageID, "en")
        XCTAssertEqual(rows[1].text, "God morning everyone")
    }

    func testSecondaryVolatileOnlyJoinsLastSegment() {
        // Latin segment NOT last → volatile ignored → empty → fallback.
        let (primary, secondary) = dualLanes(
            primaryText: [("God morning everyone。再見", true, 0, 10_000)],
            primaryFedMs: 10_000,
            secondaryFinals: [],
            secondaryVolatile: (text: " Good morning.", start: 0)
        )
        let rows = CaptionComposer.compose(
            primary: primary,
            secondary: secondary,
            config: ComposerConfig(primaryLanguageID: "zh-Hant", secondaryLanguageID: "en")
        )
        XCTAssertEqual(rows[0].languageID, "en")
        XCTAssertEqual(rows[0].text, "God morning everyone。")   // fallback, volatile ignored

        // Latin segment IS last → volatile joins.
        let (primary2, secondary2) = dualLanes(
            primaryText: [("中文。God morning everyo", true, 0, 10_000)],
            primaryFedMs: 10_000,
            secondaryFinals: [],
            secondaryVolatile: (text: " Good morning everyone.", start: 0)
        )
        let rows2 = CaptionComposer.compose(
            primary: primary2,
            secondary: secondary2,
            config: ComposerConfig(primaryLanguageID: "zh-Hant", secondaryLanguageID: "en")
        )
        XCTAssertEqual(rows2.last?.text, "Good morning everyone.")
    }

    func testEnglishRowIsFinalOnlyWhenBothSidesFinal() {
        let (primary, secondary) = dualLanes(
            primaryText: [("中文。Good morning everyone", true, 0, 10_000)],
            primaryFedMs: 10_000,
            secondaryFinals: [(" Good morning everyone.", 0, 9_000, 0.9)],
            secondaryVolatile: nil
        )
        let rows = CaptionComposer.compose(
            primary: primary,
            secondary: secondary,
            config: ComposerConfig(primaryLanguageID: "zh-Hant", secondaryLanguageID: "en")
        )
        XCTAssertTrue(rows[1].isFinal)

        // Same but primary's segment not yet finalized → not final.
        var primary2 = CaptionLaneState()
        primary2.apply(event("中文。", isFinal: true, rangeStart: 0, duration: 3_000, audioFed: 3_000, language: "zh-Hant"))
        primary2.apply(event("Good morning everyone", isFinal: false, rangeStart: 3_000, audioFed: 9_000, language: "zh-Hant"))
        let rows2 = CaptionComposer.compose(
            primary: primary2,
            secondary: secondary,
            config: ComposerConfig(primaryLanguageID: "zh-Hant", secondaryLanguageID: "en")
        )
        XCTAssertFalse(rows2[1].isFinal)
    }

    // MARK: - Island assignment

    /// A mixed pinyin+English final contributes only its English island.
    func testMixedFinalYieldsOnlyEnglishIsland() {
        var primary = CaptionLaneState()
        primary.apply(
            event(
                "中文。Xin tian woman Good morning everyone",
                isFinal: true, rangeStart: 0, duration: 10_000,
                audioFed: 10_000, language: "zh-Hant"
            )
        )
        var secondary = CaptionLaneState()
        secondary.apply(
            event(
                "Xin tian woman. Good morning, everyone.",
                isFinal: true, rangeStart: 1_000, duration: 8_000,
                audioFed: 9_000,
                runs: [
                    AnalyzerRun(text: "Xin ", startMs: 1_000, durationMs: 500, confidence: 0.4),
                    AnalyzerRun(text: "tian ", startMs: 1_500, durationMs: 500, confidence: 0.3),
                    AnalyzerRun(text: "woman. ", startMs: 2_000, durationMs: 500, confidence: 0.2),
                    AnalyzerRun(text: "Good ", startMs: 2_500, durationMs: 500, confidence: 0.9),
                    AnalyzerRun(text: "morning, ", startMs: 3_000, durationMs: 500, confidence: 0.9),
                    AnalyzerRun(text: "everyone.", startMs: 3_500, durationMs: 500, confidence: 0.95),
                ],
                language: "en"
            )
        )
        let rows = CaptionComposer.compose(
            primary: primary,
            secondary: secondary,
            config: ComposerConfig(primaryLanguageID: "zh-Hant", secondaryLanguageID: "en")
        )
        XCTAssertEqual(rows.map(\.languageID), ["zh-Hant", "en"])
        XCTAssertEqual(rows[1].text, "Good morning, everyone.")
    }

    /// An island whose mean confidence stays under the bar is ignored → the
    /// primary lane's Latin text is the fallback.
    func testGarbageIslandIsIgnored() {
        var primary = CaptionLaneState()
        primary.apply(
            event(
                "中文。Gobbledy gook words here",
                isFinal: true, rangeStart: 0, duration: 6_000,
                audioFed: 6_000, language: "zh-Hant"
            )
        )
        var secondary = CaptionLaneState()
        secondary.apply(
            event(
                "gobble dy gook words",
                isFinal: true, rangeStart: 1_000, duration: 4_000,
                audioFed: 5_000,
                runs: [
                    AnalyzerRun(text: "gobble ", startMs: 1_000, durationMs: 1_000, confidence: 0.55),
                    AnalyzerRun(text: "dy ", startMs: 2_000, durationMs: 1_000, confidence: 0.6),
                    AnalyzerRun(text: "gook ", startMs: 3_000, durationMs: 1_000, confidence: 0.5),
                    AnalyzerRun(text: "words", startMs: 4_000, durationMs: 1_000, confidence: 0.6),
                ],
                language: "en"
            )
        )
        let rows = CaptionComposer.compose(
            primary: primary,
            secondary: secondary,
            config: ComposerConfig(primaryLanguageID: "zh-Hant", secondaryLanguageID: "en")
        )
        XCTAssertEqual(rows.last?.languageID, "en")
        XCTAssertEqual(rows.last?.text, "Gobbledy gook words here")
    }

    /// Per-sentence rule: a low-confidence first word inside an otherwise
    /// confident sentence stays in the island (the run's own bar is gone).
    func testLowConfidenceWordInsideConfidentSentenceIsKept() {
        var primary = CaptionLaneState()
        primary.apply(
            event(
                "中文。Xus continue",
                isFinal: true, rangeStart: 0, duration: 6_000,
                audioFed: 6_000, language: "zh-Hant"
            )
        )
        var secondary = CaptionLaneState()
        secondary.apply(
            event(
                " Let us continue.",
                isFinal: true, rangeStart: 1_000, duration: 3_000,
                audioFed: 4_000,
                runs: [
                    AnalyzerRun(text: " Let ", startMs: 1_000, durationMs: 800, confidence: 0.28),
                    AnalyzerRun(text: "us ", startMs: 1_800, durationMs: 500, confidence: 0.99),
                    AnalyzerRun(text: "continue.", startMs: 2_300, durationMs: 1_700, confidence: 0.97),
                ],
                language: "en"
            )
        )
        let rows = CaptionComposer.compose(
            primary: primary,
            secondary: secondary,
            config: ComposerConfig(primaryLanguageID: "zh-Hant", secondaryLanguageID: "en")
        )
        XCTAssertEqual(rows.last?.text, "Let us continue.")
    }

    /// One confident-enough word is an island: "Great." at 0.64 still counts.
    func testSingleWordConfidentSentenceIsKept() {
        var primary = CaptionLaneState()
        primary.apply(
            event(
                "中文。grrreeaat 結束",
                isFinal: true, rangeStart: 0, duration: 6_000,
                audioFed: 6_000, language: "zh-Hant"
            )
        )
        var secondary = CaptionLaneState()
        secondary.apply(
            event(
                " Great.",
                isFinal: true, rangeStart: 1_000, duration: 2_000,
                audioFed: 3_000,
                runs: [
                    AnalyzerRun(text: " Great.", startMs: 1_000, durationMs: 2_000, confidence: 0.64),
                ],
                language: "en"
            )
        )
        let rows = CaptionComposer.compose(
            primary: primary,
            secondary: secondary,
            config: ComposerConfig(primaryLanguageID: "zh-Hant", secondaryLanguageID: "en")
        )
        let enRows = rows.filter { $0.languageID == "en" }
        XCTAssertTrue(enRows.contains { $0.text == "Great." }, "one-word sentence lost")
    }

    /// A4 failure case: the zh lane's garbled Latin arrives 2.5 s after the
    /// en final ended — the island still assigns, never the fallback.
    func testLateArrivingPrimaryLatinStillTakesEnglishIsland() {
        var primary = CaptionLaneState()
        primary.apply(
            event(
                "今天我們要示範及時字幕。",
                isFinal: true, rangeStart: 0, duration: 3_000,
                audioFed: 3_000, language: "zh-Hant"
            )
        )
        primary.apply(
            event(
                "Good morning everyone thankou for joing ustoday",
                isFinal: false, rangeStart: 3_000,
                audioFed: 8_000, language: "zh-Hant"
            )
        )
        var secondary = CaptionLaneState()
        secondary.apply(
            event(
                " Good morning, everyone.",
                isFinal: true, rangeStart: 3_780, duration: 1_720,
                audioFed: 5_500,
                runs: [
                    AnalyzerRun(text: " Good ", startMs: 3_780, durationMs: 500, confidence: 0.9),
                    AnalyzerRun(text: "morning, ", startMs: 4_280, durationMs: 600, confidence: 0.92),
                    AnalyzerRun(text: "everyone.", startMs: 4_880, durationMs: 620, confidence: 0.95),
                ],
                language: "en"
            )
        )
        let rows = CaptionComposer.compose(
            primary: primary,
            secondary: secondary,
            config: ComposerConfig(primaryLanguageID: "zh-Hant", secondaryLanguageID: "en")
        )
        XCTAssertEqual(rows.last?.languageID, "en")
        XCTAssertEqual(rows.last?.text, "Good morning, everyone.")
    }

    /// Two Latin segments split by Han each get their own island — never
    /// each other's.
    func testTwoLatinSegmentsGetTheirOwnIslands() {
        var primary = CaptionLaneState()
        primary.apply(event("開頭。", isFinal: true, rangeStart: 0, duration: 500, audioFed: 500, language: "zh-Hant"))
        primary.apply(event("Alpha bravo charlie", isFinal: true, rangeStart: 1_000, duration: 2_000, audioFed: 3_000, language: "zh-Hant"))
        primary.apply(event("中間。", isFinal: true, rangeStart: 4_000, duration: 500, audioFed: 4_500, language: "zh-Hant"))
        primary.apply(event("Delta echo foxtrot", isFinal: true, rangeStart: 7_000, duration: 2_000, audioFed: 9_000, language: "zh-Hant"))
        var secondary = CaptionLaneState()
        secondary.apply(
            event(
                " Alpha bravo charlie.",
                isFinal: true, rangeStart: 1_000, duration: 2_000,
                audioFed: 3_100,
                runs: [
                    AnalyzerRun(text: " Alpha ", startMs: 1_000, durationMs: 500, confidence: 0.9),
                    AnalyzerRun(text: "bravo ", startMs: 1_500, durationMs: 500, confidence: 0.9),
                    AnalyzerRun(text: "charlie.", startMs: 2_000, durationMs: 1_000, confidence: 0.9),
                ],
                language: "en"
            )
        )
        secondary.apply(
            event(
                " Delta echo foxtrot.",
                isFinal: true, rangeStart: 7_000, duration: 2_000,
                audioFed: 9_100,
                runs: [
                    AnalyzerRun(text: " Delta ", startMs: 7_000, durationMs: 500, confidence: 0.9),
                    AnalyzerRun(text: "echo ", startMs: 7_500, durationMs: 500, confidence: 0.9),
                    AnalyzerRun(text: "foxtrot.", startMs: 8_000, durationMs: 1_000, confidence: 0.9),
                ],
                language: "en"
            )
        )
        let rows = CaptionComposer.compose(
            primary: primary,
            secondary: secondary,
            config: ComposerConfig(primaryLanguageID: "zh-Hant", secondaryLanguageID: "en")
        )
        let enRows = rows.filter { $0.languageID == "en" }
        XCTAssertEqual(enRows.map(\.text), ["Alpha bravo charlie.", "Delta echo foxtrot."])
    }
}
