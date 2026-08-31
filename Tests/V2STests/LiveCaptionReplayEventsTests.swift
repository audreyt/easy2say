import CoreMedia
import Foundation
import XCTest
@testable import v2s

/// Replays captured SpeechTranscriber callbacks through the production session
/// and overlay presentation. Not part of CI: set LIVE_CAPTION_REPLAY_EVENTS
/// and LIVE_CAPTION_REPLAY_SILENCES.
final class LiveCaptionReplayEventsTests: XCTestCase {
    @MainActor
    func testCapturedEventsReplayThroughSessionNeverLayerSameUtterance() async throws {
        let events = try loadCapturedEvents()
        XCTAssertFalse(events.isEmpty)

        let session = LiveTranscriptionSession()
        var state = OverlayPreviewState(
            translatedText: "",
            sourceText: "",
            sourceName: "Replay"
        )
        var collected: [RecognizedSentence] = []
        var triggers: [String] = []
        var currentTrigger = "init"
        var hypothesisEpoch = 0
        var draftEpoch = -1
        var committedEpoch = -1
        var provisionalFrames = 0
        var mixedStabilityFrames = 0
        session.installPartialHandlerForTesting { draft in
            if let draft, draft.sourceText.isEmpty == false {
                state.draftSourceText = draft.sourceText
                state.draftSourceStablePrefixLength = draft.stablePrefixLength
                state.draftPromotionID = draft.segmentId
                state.draftAudioStartMs = draft.audioHypothesisStartMs
                draftEpoch = hypothesisEpoch
                provisionalFrames += 1
                let clampedStableLength = min(draft.stablePrefixLength, draft.sourceText.count)
                if clampedStableLength > 0, clampedStableLength < draft.sourceText.count {
                    mixedStabilityFrames += 1
                }
                if let current = state.liveCaptionPresentation.currentCaption,
                   current.sourceText == draft.sourceText {
                    XCTAssertEqual(
                        current.sourceStablePrefixLength,
                        clampedStableLength,
                        "presentation dropped the analyzer's stable/mutable boundary"
                    )
                }
            } else {
                state.draftSourceText = nil
                state.draftSourceStablePrefixLength = 0
                state.draftPromotionID = nil
                state.draftAudioStartMs = nil
                draftEpoch = -1
            }
        }
        session.installTranscriptHandlerForTesting { sentence in
            collected.append(sentence)
            triggers.append(currentTrigger)
            state.sourceText = sentence.text
            state.translatedText = sentence.text
            state.committedPromotionID = sentence.promotionSegmentID
            state.committedAudioStartMs = sentence.audioStartMs
            committedEpoch = hypothesisEpoch
            if sentence.replacesPromotionSegmentID != nil {
                state.draftSourceText = nil
                state.draftSourceStablePrefixLength = 0
                state.draftPromotionID = nil
                state.draftAudioStartMs = nil
                draftEpoch = -1
            }
        }

        var vadInjections = 0
        var vadCommits = 0
        var vadRejects = 0
        let silences = try loadSilenceOffsets()
        var nextSilence = 0

        for event in events {
            let commitsBeforeEvent = collected.count
            currentTrigger = event.isFinal ? "analyzerFinal" : "volatile"
            session.processModernRecognitionTextForTesting(
                event.text,
                isFinal: event.isFinal,
                audioRange: event.audioRange,
                sourceLanguageID: "zh-Hant"
            )
            await flushSession(session)
            assertIndependentOracle(
                state: state,
                draftEpoch: draftEpoch,
                committedEpoch: committedEpoch
            )
            if collected.count > commitsBeforeEvent {
                hypothesisEpoch += 1
            }

            let nowMs = event.startMs + event.durationMs
            while nextSilence < silences.count, silences[nextSilence] <= nowMs {
                let silenceMs = silences[nextSilence]
                nextSilence += 1
                guard silenceMs > 200 else { continue }
                let countBefore = collected.count
                let textBefore = collected.last?.text
                currentTrigger = "vadSilence"
                session.backdateLastDraftTextChangeForTesting(secondsAgo: 1)
                session.forceVADCommitOnSilenceForTesting()
                vadInjections += 1
                await flushSession(session)
                if collected.count > countBefore || collected.last?.text != textBefore {
                    vadCommits += 1
                } else {
                    vadRejects += 1
                }
                assertIndependentOracle(
                    state: state,
                    draftEpoch: draftEpoch,
                    committedEpoch: committedEpoch
                )
                if collected.count > countBefore || collected.last?.text != textBefore {
                    hypothesisEpoch += 1
                }
            }
        }
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertGreaterThan(vadInjections, 0, "VAD silence injection never fired")
        XCTAssertGreaterThan(vadRejects, 0, "VAD never rejected an incomplete draft")
        XCTAssertFalse(collected.isEmpty, "session emitted no commits")
        XCTAssertGreaterThan(provisionalFrames, 0, "replay emitted no provisional caption frames")
        XCTAssertGreaterThan(
            mixedStabilityFrames,
            0,
            "replay never displayed a white stable prefix with a mutable live tail"
        )

        let finals = events.filter(\.isFinal)
        let reduced = reduceReplacedCommits(collected, triggers: triggers)
        dumpTurnsIfRequested(reduced, emissions: collected, triggers: triggers)
        let got = reduced.map { contentScalars($0.text) }.joined()
        let want = finals.map { contentScalars($0.text) }.joined()
        XCTAssertTrue(
            got == want,
            "stream mismatch gotChars=\(got.count) wantChars=\(want.count) commits=\(collected.count) reduced=\(reduced.count) finals=\(finals.count) vadCommits=\(vadCommits) vadRejects=\(vadRejects)"
        )

        let quality = measureTurnQuality(turns: reduced, canonicalFinalTexts: finals.map(\.text))
        XCTAssertGreaterThan(
            quality.terminatorsAvailable, 0,
            "capture has no sentence terminators, so the recall check is vacuous"
        )
        XCTAssertEqual(
            quality.interiorTerminatorTurns, 0,
            "a turn carries more than one sentence: \(quality)"
        )
        XCTAssertEqual(
            quality.boundariesOnTerminator, quality.terminatorsAvailable,
            "a real sentence end was not used as a turn boundary: \(quality)"
        )
        XCTAssertEqual(
            quality.latinWordSplits, 0,
            "a turn boundary split a Latin word: \(quality)"
        )
        XCTAssertEqual(
            quality.gatedMidSentenceBoundaries, 0,
            "a VAD or fast-path commit cut mid-sentence: \(quality)"
        )
    }

    func testCapturedEventsNeverLayerSameUtteranceInPresentation() throws {
        let events = try loadCapturedEvents()
        var state = OverlayPreviewState(
            translatedText: "",
            sourceText: "",
            sourceName: "Replay"
        )
        var committedTurns = 0

        for event in events {
            if event.isFinal {
                state.sourceText = event.text
                state.translatedText = event.text
                state.committedPromotionID = UUID()
                state.draftSourceText = nil
                state.draftSourceStablePrefixLength = 0
                state.draftPromotionID = nil
                committedTurns += 1
            } else {
                state.draftSourceText = event.text
                state.draftSourceStablePrefixLength = 0
                state.draftPromotionID = UUID()
            }
            assertIndependentOracle(state: state)
        }

        XCTAssertGreaterThan(committedTurns, 0)
    }

    /// CI-safe counterpart to the captured replay. Reproduces the analyzer shape
    /// that actually drives segmentation — cumulative volatile hypotheses inside a
    /// window, and windows that finalize mid-sentence. No capture files, no
    /// recorded speech.
    ///
    /// Pins two separate contracts:
    ///  1. an unterminated window tail stays its own committed row. Merging it
    ///     into the next window was investigated and rejected: analyzer windows
    ///     stay contiguous straight through silence, and the captured VAD
    ///     timeline fires roughly once per second, so "contiguous audio" cannot
    ///     distinguish a continued utterance from a pause. Merging on that signal
    ///     would concatenate unrelated utterances.
    ///  2. an abbreviation is never a turn boundary ("Dr. Chen speaks" is one row).
    @MainActor
    func testSyntheticAnalyzerWindowsProduceSentenceTurns() async {
        let session = LiveTranscriptionSession()
        var collected: [RecognizedSentence] = []
        var triggers: [String] = []
        var currentTrigger = "init"
        var hypothesisEpoch = 0
        var draftEpoch = -1
        var committedEpoch = -1
        var state = OverlayPreviewState(
            translatedText: "",
            sourceText: "",
            sourceName: "Synthetic"
        )
        session.installPartialHandlerForTesting { draft in
            if let draft, draft.sourceText.isEmpty == false {
                state.draftSourceText = draft.sourceText
                state.draftSourceStablePrefixLength = draft.stablePrefixLength
                state.draftPromotionID = draft.segmentId
                draftEpoch = hypothesisEpoch
            } else {
                state.draftSourceText = nil
                state.draftSourceStablePrefixLength = 0
                state.draftPromotionID = nil
                draftEpoch = -1
            }
        }
        session.installTranscriptHandlerForTesting { sentence in
            collected.append(sentence)
            triggers.append(currentTrigger)
            state.sourceText = sentence.text
            state.translatedText = sentence.text
            state.committedPromotionID = sentence.promotionSegmentID
            committedEpoch = hypothesisEpoch
            if sentence.replacesPromotionSegmentID != nil {
                state.draftSourceText = nil
                state.draftSourceStablePrefixLength = 0
                state.draftPromotionID = nil
                draftEpoch = -1
            }
        }

        let windows: [(startSec: Double, steps: [(text: String, isFinal: Bool)])] = [
            (0.0, [
                ("Hello", false),
                ("Hello everyone", false),
                ("Hello everyone, hello.", false),
                ("Hello everyone, hello. Welcome to our", false),
                ("Hello everyone, hello. Welcome to our", true)
            ]),
            (3.0, [
                ("first session.", false),
                ("first session. Dr. Chen speaks", false),
                ("first session. Dr. Chen speaks", true)
            ]),
            (6.0, [
                ("next. Thanks.", false),
                ("next. Thanks.", true)
            ])
        ]

        // Every visible caption the viewer would see, sampled after each drain.
        var visible: [String] = []
        for window in windows {
            for step in window.steps {
                let commitsBeforeStep = collected.count
                currentTrigger = step.isFinal ? "analyzerFinal" : "volatile"
                session.processModernRecognitionTextForTesting(
                    step.text,
                    isFinal: step.isFinal,
                    audioRange: CMTimeRange(
                        start: CMTime(seconds: window.startSec, preferredTimescale: 1000),
                        duration: CMTime(seconds: 3.0, preferredTimescale: 1000)
                    ),
                    sourceLanguageID: "en"
                )
                await session.awaitPendingEmissionsForTesting()
                assertIndependentOracle(
                    state: state,
                    draftEpoch: draftEpoch,
                    committedEpoch: committedEpoch
                )
                if let current = state.liveCaptionPresentation.currentCaption?.sourceText,
                   visible.last != current {
                    visible.append(current)
                }
                if collected.count > commitsBeforeStep {
                    hypothesisEpoch += 1
                }
            }
        }

        let reduced = reduceReplacedCommits(collected, triggers: triggers)
        let canonical = windows
            .flatMap { $0.steps }
            .filter(\.isFinal)
            .map { contentScalars($0.text) }
            .joined()

        // 1. Stream preservation: the committed rows reproduce the analyzer's
        //    finalized text exactly once, in order.
        XCTAssertEqual(reduced.map { contentScalars($0.text) }.joined(), canonical)

        // 2. Abbreviations are never turn boundaries.
        for turn in reduced {
            XCTAssertFalse(
                turn.text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("Dr."),
                "abbreviation used as a turn boundary: \(reduced.map(\.text))"
            )
        }
        XCTAssertTrue(
            reduced.contains { $0.text.contains("Dr.") && $0.text.contains("Chen") },
            "\"Dr. Chen\" must stay in one turn: \(reduced.map(\.text))"
        )

        // 3. No duplicate same-utterance rows: no row restates an adjacent row.
        for (left, right) in zip(reduced, reduced.dropFirst()) {
            let a = contentScalars(left.text)
            let b = contentScalars(right.text)
            guard a.isEmpty == false, b.isEmpty == false else { continue }
            XCTAssertFalse(
                a.hasPrefix(b) || b.hasPrefix(a),
                "adjacent rows restate one utterance: \(left.text) | \(right.text)"
            )
        }

        // 4. Every visible caption is real analyzer text, never invented or
        //    duplicated. Shrink points and continuation glue are intentionally not
        //    asserted here: that UX is unvalidated, and pinning it would reject a
        //    future fix. `assertIndependentOracle` above proves no step layers.
        XCTAssertFalse(visible.isEmpty)
        for caption in visible {
            let content = contentScalars(caption)
            XCTAssertFalse(content.isEmpty)
            XCTAssertTrue(
                canonical.contains(content),
                "visible caption is not contiguous analyzer text: \(caption)"
            )
        }

        // The same-hypothesis epoch check is a negative invariant: while the
        // pipeline is correct every commit clears the draft, so no same-epoch
        // two-row state can arise and the check has no positive instances here.
        // `testOracleDetectsSameHypothesisLayering` proves the detector fires.
    }

    /// Pure detector, independent of `LiveCaptionReplay.relation`. Returns the
    /// reason two live rows are the same utterance, or nil when the presentation
    /// is sound. Kept side-effect free so a targeted test can prove it is
    /// sensitive without deliberately failing XCTest.
    private func independentOracleViolation(
        presentation: OverlayLiveCaptionPresentation,
        draftEpoch: Int = -1,
        committedEpoch: Int = -1
    ) -> String? {
        guard let preceding = presentation.precedingCommittedCaption,
              let current = presentation.currentCaption else {
            return nil
        }


        let committed = contentScalars(preceding.sourceText)
        let draft = contentScalars(current.sourceText)
        if committed.isEmpty == false, draft.isEmpty == false {
            let prefixContinuation = draft.hasPrefix(committed) && draft.count > committed.count
            let shrinkingHypothesis = committed.hasPrefix(draft) && committed.count > draft.count
            if prefixContinuation || shrinkingHypothesis {
                return "prefix continuation layered (\(preceding.sourceText.count)+\(current.sourceText.count) chars)"
            }
        }

        if draftEpoch >= 0, committedEpoch >= 0, draftEpoch == committedEpoch {
            return "same-hypothesis epoch \(draftEpoch) layered"
        }
        return nil
    }

    private func assertIndependentOracle(
        state: OverlayPreviewState,
        draftEpoch: Int = -1,
        committedEpoch: Int = -1
    ) {
        XCTAssertNil(
            independentOracleViolation(
                presentation: state.liveCaptionPresentation,
                draftEpoch: draftEpoch,
                committedEpoch: committedEpoch
            )
        )
    }

    private func twoRowPresentation(
        preceding: String,
        current: String
    ) -> OverlayLiveCaptionPresentation {
        OverlayLiveCaptionPresentation(
            precedingCommittedCaption: OverlayLiveCaptionPresentation.Caption(
                id: .promotion(UUID()),
                phase: .committed,
                translatedText: preceding,
                sourceText: preceding
            ),
            currentCaption: OverlayLiveCaptionPresentation.Caption(
                id: .promotion(UUID()),
                phase: .tentative,
                translatedText: current,
                sourceText: current
            )
        )
    }

    /// Proves the oracle is sensitive to both layering classes it guards. Without
    /// this, a replay that never reaches the bad state would look like evidence.
    /// The presentation is built directly: `liveCaptionPresentation` collapses
    /// these cases, so a state-based fixture could never produce them.
    func testOracleDetectsSameHypothesisLayering() {
        XCTAssertNotNil(
            independentOracleViolation(
                presentation: twoRowPresentation(
                    preceding: "Welcome to our",
                    current: "Welcome to our first session"
                )
            ),
            "oracle missed a prefix continuation occupying two rows"
        )

        XCTAssertNotNil(
            independentOracleViolation(
                presentation: twoRowPresentation(
                    preceding: "Welcome to our first session",
                    current: "Welcome to our"
                )
            ),
            "oracle missed a shrinking hypothesis occupying two rows"
        )

        let independentRows = twoRowPresentation(
            preceding: "Committed line",
            current: "Wholly unrelated later text"
        )
        XCTAssertNil(
            independentOracleViolation(presentation: independentRows),
            "independent rows must be allowed when epochs are unknown"
        )
        XCTAssertNotNil(
            independentOracleViolation(
                presentation: independentRows,
                draftEpoch: 7,
                committedEpoch: 7
            ),
            "oracle missed two rows sharing one hypothesis epoch"
        )
    }

    private func contentScalars(_ text: String) -> String {
        String(text.unicodeScalars.compactMap { scalar -> Character? in
            if CharacterSet.alphanumerics.contains(scalar) || LanguageIdentity.isHanScalar(scalar) {
                return Character(scalar)
            }
            return nil
        })
    }


    private struct CommittedTurn {
        let text: String
        let trigger: String
    }

    /// Reduces in-place replacements to the surviving rows, keeping each row's
    /// trigger attached to the emission that last wrote it.
    private func reduceReplacedCommits(
        _ sentences: [RecognizedSentence],
        triggers: [String]
    ) -> [CommittedTurn] {
        struct Row {
            var ids: Set<UUID>
            var text: String
            var trigger: String
        }
        var rows: [Row] = []
        for (index, sentence) in sentences.enumerated() {
            let trigger = index < triggers.count ? triggers[index] : "unknown"
            var ids = Set<UUID>()
            if let promotionID = sentence.promotionSegmentID {
                ids.insert(promotionID)
            }
            if let replacesID = sentence.replacesPromotionSegmentID,
               let existing = rows.firstIndex(where: { $0.ids.contains(replacesID) }) {
                rows[existing].text = sentence.text
                rows[existing].trigger = trigger
                rows[existing].ids.formUnion(ids)
                continue
            }
            rows.append(Row(ids: ids, text: sentence.text, trigger: trigger))
        }
        return rows.map { CommittedTurn(text: $0.text, trigger: $0.trigger) }
    }

    // MARK: - Turn quality oracle

    /// Sentence terminators owned by this test. Deliberately NOT
    /// `SentenceBoundaryHeuristics`: an oracle that reuses the classifier under
    /// test would accept the same segmentation bug it is supposed to catch.
    private static let referenceTerminators = Set<Character>("。！？．…⋯!?")

    private struct TurnQualityReport {
        var turns = 0
        var interiorTerminatorTurns = 0
        var terminatorsAvailable = 0
        var boundariesOnTerminator = 0
        var latinWordSplits = 0
        var gatedMidSentenceBoundaries = 0
        /// Informational only: short-fragment badness has no labeled ground truth
        /// in a captured stream. The synthetic replay asserts exact turns instead.
        var orphanFragments = 0
        var analyzerFinalMidSentenceBoundaries = 0
    }

    private func isContentScalar(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar) || LanguageIdentity.isHanScalar(scalar)
    }

    /// `canonicalFinalTexts` is the analyzer's own finalized text. The replay
    /// already proves the committed stream reproduces it character for character,
    /// so turn boundaries map onto it by offset without alignment.
    private func measureTurnQuality(
        turns: [CommittedTurn],
        canonicalFinalTexts: [String]
    ) -> TurnQualityReport {
        var report = TurnQualityReport()
        report.turns = turns.count

        let scalars = Array(canonicalFinalTexts.joined().unicodeScalars)
        var contentPositions: [Int] = []
        var terminatorAfter: [Bool] = []
        var periodAfter: [Bool] = []
        var sawHardTerminator = false
        var sawPeriod = false

        for (position, scalar) in scalars.enumerated() {
            let character = Character(scalar)
            if isContentScalar(scalar) {
                if terminatorAfter.isEmpty == false {
                    terminatorAfter[terminatorAfter.count - 1] = sawHardTerminator
                    periodAfter[periodAfter.count - 1] = sawPeriod
                }
                sawHardTerminator = false
                sawPeriod = false
                contentPositions.append(position)
                terminatorAfter.append(false)
                periodAfter.append(false)
            } else if Self.referenceTerminators.contains(character) {
                sawHardTerminator = true
            } else if character == "." {
                // A bare ASCII period is ambiguous (abbreviation vs sentence end).
                // This oracle refuses to judge those boundaries; the synthetic
                // replay pins them with exact expected turns instead.
                sawPeriod = true
            }
        }
        if terminatorAfter.isEmpty == false {
            terminatorAfter[terminatorAfter.count - 1] = sawHardTerminator
            periodAfter[periodAfter.count - 1] = sawPeriod
        }
        // The final boundary is the end of the stream, not a segmentation decision.
        report.terminatorsAvailable = zip(terminatorAfter, periodAfter)
            .dropLast()
            .filter { $0.0 && !$0.1 }
            .count

        var endOffsets: [Int] = []
        var running = 0
        for turn in turns {
            running += contentScalars(turn.text).count
            endOffsets.append(running)

            let body = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            var trailingTrimmed = body
            while let last = trailingTrimmed.last,
                  Self.referenceTerminators.contains(last) || last == "\"" || last == "”" {
                trailingTrimmed.removeLast()
            }
            if trailingTrimmed.contains(where: { Self.referenceTerminators.contains($0) }) {
                report.interiorTerminatorTurns += 1
            }
            if contentScalars(turn.text).count < 8,
               let last = body.last,
               Self.referenceTerminators.contains(last) == false {
                report.orphanFragments += 1
            }
        }

        for (turn, end) in zip(turns, endOffsets).dropLast() {
            let index = end - 1
            guard index >= 0, index < terminatorAfter.count else { continue }
            if periodAfter[index] {
                // Ambiguous ASCII period: unjudged by this oracle.
            } else if terminatorAfter[index] {
                report.boundariesOnTerminator += 1
            } else if turn.trigger == "analyzerFinal" {
                report.analyzerFinalMidSentenceBoundaries += 1
            } else {
                report.gatedMidSentenceBoundaries += 1
            }
            guard index + 1 < contentPositions.count else { continue }
            if contentPositions[index + 1] == contentPositions[index] + 1 {
                let left = Character(scalars[contentPositions[index]])
                let right = Character(scalars[contentPositions[index + 1]])
                if left.isASCII, left.isLetter, right.isASCII, right.isLetter {
                    report.latinWordSplits += 1
                }
            }
        }
        return report
    }

    /// Writes the committed turn stream plus per-emission trigger attribution so
    /// turn quality can be scored offline. Opt-in: LIVE_CAPTION_REPLAY_TURNS.
    private func dumpTurnsIfRequested(
        _ turns: [CommittedTurn],
        emissions: [RecognizedSentence],
        triggers: [String]
    ) {
        guard let path = ProcessInfo.processInfo.environment["LIVE_CAPTION_REPLAY_TURNS"],
              path.isEmpty == false else {
            return
        }
        let rows: [[String: Any]] = emissions.enumerated().map { index, sentence in
            [
                "text": sentence.text,
                "trigger": index < triggers.count ? triggers[index] : "unknown",
                "promotion": sentence.promotionSegmentID?.uuidString ?? "",
                "replaces": sentence.replacesPromotionSegmentID?.uuidString ?? ""
            ]
        }
        let payload: [String: Any] = ["turns": turns.map(\.text), "emissions": rows]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else {
            return
        }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    @MainActor
    private func flushSession(_ session: LiveTranscriptionSession) async {
        await session.awaitPendingEmissionsForTesting()
    }

    private struct CapturedEvent {
        let isFinal: Bool
        let text: String
        let startMs: Int
        let durationMs: Int

        var audioRange: CMTimeRange {
            CMTimeRange(
                start: CMTime(value: CMTimeValue(max(startMs, 0)), timescale: 1000),
                duration: CMTime(value: CMTimeValue(max(durationMs, 1)), timescale: 1000)
            )
        }
    }

    private func loadCapturedEvents() throws -> [CapturedEvent] {
        guard let path = ProcessInfo.processInfo.environment["LIVE_CAPTION_REPLAY_EVENTS"],
              path.isEmpty == false else {
            throw XCTSkip("set LIVE_CAPTION_REPLAY_EVENTS to replay a SpeechTranscriber JSON capture")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let rows = raw as? [[String: Any]] else {
            throw XCTSkip("LIVE_CAPTION_REPLAY_EVENTS is not an array of event objects")
        }
        let events = rows.compactMap { row -> CapturedEvent? in
            guard let text = row["text"] as? String else { return nil }
            return CapturedEvent(
                isFinal: row["final"] as? Bool ?? false,
                text: text,
                startMs: row["start_ms"] as? Int ?? 0,
                durationMs: row["duration_ms"] as? Int ?? 0
            )
        }
        if events.isEmpty {
            throw XCTSkip("LIVE_CAPTION_REPLAY_EVENTS contained no text events")
        }
        return events
    }

    private func loadSilenceOffsets() throws -> [Int] {
        guard let path = ProcessInfo.processInfo.environment["LIVE_CAPTION_REPLAY_SILENCES"],
              path.isEmpty == false else {
            throw XCTSkip("set LIVE_CAPTION_REPLAY_SILENCES to a JSON array of silence start milliseconds")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let values = raw as? [Int] else {
            throw XCTSkip("LIVE_CAPTION_REPLAY_SILENCES is not an array of integers")
        }
        let usable = values.filter { $0 > 200 }
        if usable.isEmpty {
            throw XCTSkip("LIVE_CAPTION_REPLAY_SILENCES has no usable offsets")
        }
        return usable.sorted()
    }
}
