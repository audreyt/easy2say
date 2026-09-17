import AVFoundation
import FluidAudio
import XCTest
@testable import v2s

/// Covers the attribution contract of `LiveDiarizationEngine` without loading
/// the Sortformer model: segments are injected straight into the diarizer's
/// timeline, which is the same store `speakerSegmentsSnapshot()` reads.
final class LiveDiarizationEngineTests: XCTestCase {
    private static let frameDuration: Float = 0.08

    private func makeEngine() -> LiveDiarizationEngine {
        LiveDiarizationEngine()
    }

    @discardableResult
    private func addSegment(
        to engine: LiveDiarizationEngine,
        slot: Int,
        start: Float,
        end: Float,
        tentative: Bool = false
    ) -> DiarizerSegment {
        let speaker = engine.diarizer.timeline.upsertSpeaker(atIndex: slot)
        let segment = DiarizerSegment(
            speakerIndex: slot,
            startTime: start,
            endTime: end,
            finalized: !tentative,
            frameDurationSeconds: Self.frameDuration
        )
        if tentative {
            speaker?.appendTentative(segment)
        } else {
            speaker?.appendFinalized(segment)
        }
        return segment
    }

    // MARK: - Display index ordering

    func testDisplayIndexAssignsInOrderOfFirstAppearance() {
        let engine = makeEngine()
        XCTAssertEqual(engine.displayIndex(forSlot: 2), 0)
        XCTAssertEqual(engine.displayIndex(forSlot: 0), 1)
        XCTAssertEqual(engine.displayIndex(forSlot: 2), 0)
        XCTAssertEqual(engine.displayIndex(forSlot: 3), 2)
    }

    // MARK: - Attribution

    func testDominantSpeakerPrefersFinalizedOverTentative() {
        let engine = makeEngine()
        addSegment(to: engine, slot: 0, start: 0, end: 5)
        // Tentative segment for a different slot overlapping the same range.
        addSegment(to: engine, slot: 1, start: 1, end: 4, tentative: true)

        XCTAssertEqual(engine.dominantSpeakerIndex(startSeconds: 1, endSeconds: 4), 0)
    }

    func testDominantSpeakerFallsBackToTentative() {
        let engine = makeEngine()
        addSegment(to: engine, slot: 1, start: 2, end: 6, tentative: true)

        // Slot 1 is the first speaker attributed → display index 0.
        XCTAssertEqual(engine.dominantSpeakerIndex(startSeconds: 2.5, endSeconds: 5), 0)
    }

    func testDominantSpeakerPicksLargestOverlap() {
        let engine = makeEngine()
        // Pin slot 0's display index first so the winner's index is meaningful.
        XCTAssertEqual(engine.displayIndex(forSlot: 0), 0)
        addSegment(to: engine, slot: 0, start: 0, end: 1.2)
        addSegment(to: engine, slot: 1, start: 1.0, end: 4.0)

        // Slot 1 overlaps 3.0s of the query; slot 0 only 0.2s.
        XCTAssertEqual(engine.dominantSpeakerIndex(startSeconds: 1.0, endSeconds: 4.0), 1)
    }

    func testDominantSpeakerIgnoresSubThresholdOverlap() {
        let engine = makeEngine()
        addSegment(to: engine, slot: 0, start: 0, end: 1.0)

        // 0.05s overlap is below the 0.1s attribution floor.
        XCTAssertNil(engine.dominantSpeakerIndex(startSeconds: 0.95, endSeconds: 2.0))
    }

    func testDominantSpeakerReturnsNilWithNoSegments() {
        let engine = makeEngine()
        XCTAssertNil(engine.dominantSpeakerIndex(startSeconds: 0, endSeconds: 10))
    }

    func testDominantSpeakerReturnsNilForEmptyRange() {
        let engine = makeEngine()
        addSegment(to: engine, slot: 0, start: 0, end: 5)
        XCTAssertNil(engine.dominantSpeakerIndex(startSeconds: 2, endSeconds: 2))
        XCTAssertNil(engine.dominantSpeakerIndex(startSeconds: 3, endSeconds: 2))
    }

    func testDominantSpeakerMapsSlotToStableDisplayIndex() {
        let engine = makeEngine()
        addSegment(to: engine, slot: 3, start: 0, end: 2)
        addSegment(to: engine, slot: 1, start: 3, end: 5)

        // Slot 3 spoke first → display index 0; slot 1 → 1.
        XCTAssertEqual(engine.dominantSpeakerIndex(startSeconds: 0, endSeconds: 2), 0)
        XCTAssertEqual(engine.dominantSpeakerIndex(startSeconds: 3, endSeconds: 5), 1)
        // Re-querying slot 3 keeps index 0 — labels don't reshuffle.
        XCTAssertEqual(engine.dominantSpeakerIndex(startSeconds: 0.5, endSeconds: 1.5), 0)
    }

    // MARK: - Snapshot

    func testSnapshotSortsSegmentsByStart() {
        let engine = makeEngine()
        // Times are frame-aligned (80ms frames) so no quantization drift.
        addSegment(to: engine, slot: 0, start: 8.0, end: 10.0)
        addSegment(to: engine, slot: 1, start: 0.96, end: 3.04)
        addSegment(to: engine, slot: 0, start: 4.0, end: 6.0, tentative: true)

        let snapshot = engine.speakerSegmentsSnapshot()
        XCTAssertEqual(snapshot.map(\.startSeconds).map { round($0 * 100) / 100 }, [0.96, 4.0, 8.0])
        XCTAssertEqual(snapshot.map(\.slot), [1, 0, 0])
        XCTAssertEqual(snapshot.map(\.isTentative), [false, true, false])
    }

    // MARK: - Capture clock

    func testAppendAdvancesCaptureClockByBufferDuration() {
        let engine = makeEngine()
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600)!
        buffer.frameLength = 1_600

        let start = engine.append(audioBuffer: buffer)
        XCTAssertEqual(start, 0, accuracy: 0.001)
        XCTAssertEqual(engine.captureSecondsNow, 0.1, accuracy: 0.001)

        let second = engine.append(audioBuffer: buffer)
        XCTAssertEqual(second, 0.1, accuracy: 0.001)
        XCTAssertEqual(engine.captureSecondsNow, 0.2, accuracy: 0.001)
    }
}
