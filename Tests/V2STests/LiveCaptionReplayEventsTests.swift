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
        var hypothesisEpoch = 0
        var draftEpoch = -1
        var committedEpoch = -1
        session.installPartialHandlerForTesting { draft in
            if let draft, draft.sourceText.isEmpty == false {
                state.draftSourceText = draft.sourceText
                state.draftPromotionID = draft.segmentId
                state.draftAudioStartMs = draft.audioHypothesisStartMs
                draftEpoch = hypothesisEpoch
            } else {
                state.draftSourceText = nil
                state.draftPromotionID = nil
                state.draftAudioStartMs = nil
                draftEpoch = -1
            }
        }
        session.installTranscriptHandlerForTesting { sentence in
            collected.append(sentence)
            state.sourceText = sentence.text
            state.translatedText = sentence.text
            state.committedPromotionID = sentence.promotionSegmentID
            state.committedAudioStartMs = sentence.audioStartMs
            committedEpoch = hypothesisEpoch
            if sentence.replacesPromotionSegmentID != nil {
                state.draftSourceText = nil
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

        let finals = events.filter(\.isFinal)
        let reduced = reduceReplacedCommits(collected)
        let got = reduced.map { contentScalars($0) }.joined()
        let want = finals.map { contentScalars($0.text) }.joined()
        XCTAssertTrue(
            got == want,
            "stream mismatch gotChars=\(got.count) wantChars=\(want.count) commits=\(collected.count) reduced=\(reduced.count) finals=\(finals.count) vadCommits=\(vadCommits) vadRejects=\(vadRejects)"
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
                state.draftPromotionID = nil
                committedTurns += 1
            } else {
                state.draftSourceText = event.text
                state.draftPromotionID = UUID()
            }
            assertIndependentOracle(state: state)
        }

        XCTAssertGreaterThan(committedTurns, 0)
    }

    /// Independent of `LiveCaptionReplay.relation`. Prefix continuation occupies
    /// one live slot. Same commit-boundary epoch with two live rows is the
    /// original same-hypothesis layering class; analyzer start-ms is not identity.
    private func assertIndependentOracle(
        state: OverlayPreviewState,
        draftEpoch: Int = -1,
        committedEpoch: Int = -1
    ) {
        let presentation = state.liveCaptionPresentation
        guard let preceding = presentation.precedingCommittedCaption,
              let current = presentation.currentCaption else {
            return
        }

        let committed = contentScalars(preceding.sourceText)
        let draft = contentScalars(current.sourceText)
        if committed.isEmpty == false, draft.isEmpty == false {
            let prefixContinuation = draft.hasPrefix(committed) && draft.count > committed.count
            let shrinkingHypothesis = committed.hasPrefix(draft) && committed.count > draft.count
            XCTAssertFalse(
                prefixContinuation || shrinkingHypothesis,
                "prefix continuation layered (\(preceding.sourceText.count)+\(current.sourceText.count) chars)"
            )
        }

        if draftEpoch >= 0, committedEpoch >= 0, draftEpoch == committedEpoch {
            XCTFail("same-hypothesis epoch \(draftEpoch) layered")
        }
    }

    private func contentScalars(_ text: String) -> String {
        String(text.unicodeScalars.compactMap { scalar -> Character? in
            if CharacterSet.alphanumerics.contains(scalar) || LanguageIdentity.isHanScalar(scalar) {
                return Character(scalar)
            }
            return nil
        })
    }


    private func reduceReplacedCommits(_ sentences: [RecognizedSentence]) -> [String] {
        struct Row {
            var ids: Set<UUID>
            var text: String
        }
        var rows: [Row] = []
        for sentence in sentences {
            var ids = Set<UUID>()
            if let promotionID = sentence.promotionSegmentID {
                ids.insert(promotionID)
            }
            if let replacesID = sentence.replacesPromotionSegmentID,
               let index = rows.firstIndex(where: { $0.ids.contains(replacesID) }) {
                rows[index].text = sentence.text
                rows[index].ids.formUnion(ids)
                continue
            }
            rows.append(Row(ids: ids, text: sentence.text))
        }
        return rows.map(\.text)
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
