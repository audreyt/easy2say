import AVFoundation
import CoreML
import FluidAudio
import Foundation

/// Streaming speaker diarization for live captions, built on FluidAudio's
/// Sortformer v2.1 (Apache-2.0, https://github.com/FluidInference/FluidAudio).
///
/// Design notes:
/// - The Sortformer model ships inside the app bundle (`ios/Resources/Diarization`,
///   fetched by `scripts/fetch-diarization-model.sh`). No runtime download, no
///   network dependency — consistent with the app's on-device privacy posture.
/// - Audio is fed from the capture queue as 16 kHz mono Float buffers (the same
///   tap that feeds the speech analyzer). All diarizer work runs on a serial
///   `diarizerQueue`; `SortformerDiarizer` also serializes internally, so the
///   queue mainly keeps CoreML inference off the capture path.
/// - Every fed buffer MUST reach `addAudio`: the diarizer's timeline is indexed
///   by samples fed, so dropping audio would shift all later attributions.
/// - Speaker attribution maps Sortformer's fixed output slots to stable display
///   indices in order of first appearance ("Speaker A" is whoever spoke first),
///   so labels don't reshuffle when the model reorders its slots.
final class LiveDiarizationEngine: @unchecked Sendable {
    /// One speaker's speech interval on the capture-time axis (seconds since
    /// the first audio buffer of this session).
    struct SpeakerSegment: Equatable, Sendable {
        /// Sortformer output slot (0..<4), not the display index.
        let slot: Int
        let startSeconds: Double
        let endSeconds: Double
        let isTentative: Bool
    }

    /// Minimum overlap (seconds) between a caption's audio range and a speaker
    /// segment before that speaker is considered for attribution.
    static let minimumAttributionOverlapSeconds: Double = 0.1

    /// Internal (not private) so tests can inject timeline segments without a model.
    let diarizer = SortformerDiarizer(config: .fastV2_1)
    private let diarizerQueue = DispatchQueue(label: "v2s.diarization", qos: .userInitiated)
    private let stateLock = NSLock()

    /// Seconds of capture audio fed so far. Written synchronously in `append`
    /// (capture queue) and read for emission timestamps — always under `stateLock`.
    private var fedSeconds: Double = 0

    /// Sortformer slot → display index, assigned in order of first appearance.
    private var slotDisplayOrder: [Int: Int] = [:]
    private var nextDisplayIndex = 0

    /// Bundled `Sortformer_v2.1.mlmodelc` URL, or nil when the resource was not
    /// shipped (e.g. `swift test` runs, which have no resource bundle).
    static func bundledModelURL(in bundle: Bundle = .main) -> URL? {
        for ext in ["mlmodelc", "mlpackage"] {
            if let url = bundle.url(
                forResource: "Sortformer_v2.1",
                withExtension: ext,
                subdirectory: "Diarization"
            ) {
                return url
            }
        }
        for ext in ["mlmodelc", "mlpackage"] {
            if let url = bundle.url(forResource: "Sortformer_v2.1", withExtension: ext) {
                return url
            }
        }
        return nil
    }

    /// True when the diarization model ships in this build.
    static var isModelBundled: Bool {
        bundledModelURL() != nil
    }

    /// Loads the bundled CoreML model off the main thread. Safe to call once per
    /// session start; audio fed before the model is ready is buffered by the
    /// diarizer and processed once initialization completes.
    func start() {
        diarizerQueue.async { [diarizer] in
            guard diarizer.isAvailable == false else { return }
            guard let modelURL = Self.bundledModelURL() else {
                fputs("LiveDiarizationEngine: Sortformer_v2.1 model not in bundle; speaker labels disabled\n", stderr)
                return
            }
            // Hop off the serial queue for the async load; queued addAudio calls
            // keep buffering meanwhile and process() stays gated on isAvailable.
            Task {
                do {
                    if modelURL.pathExtension == "mlmodelc" {
                        // Already compiled: load directly — compileModel() expects
                        // a .mlpackage source bundle.
                        let config = MLModelConfiguration()
                        config.computeUnits = .cpuAndNeuralEngine
                        let model = try await MLModel.load(contentsOf: modelURL, configuration: config)
                        diarizer.initialize(models: try SortformerModels(
                            config: diarizer.config,
                            main: model
                        ))
                    } else {
                        try await diarizer.initialize(
                            mainModelPath: modelURL,
                            computeUnits: .cpuAndNeuralEngine
                        )
                    }
                } catch {
                    fputs("LiveDiarizationEngine: model load failed: \(error)\n", stderr)
                }
            }
        }
    }

    /// Feeds one mono Float buffer. Called on the capture queue; returns the
    /// capture-time offset (seconds) of this buffer's first sample.
    /// `sourceSampleRate` defaults to 16 kHz; pass the buffer's actual rate when
    /// it differs — the diarizer resamples, and the clock counts durations, not
    /// samples, so the timeline stays aligned either way.
    /// Capture-time seconds fed so far — the diarizer's "now" on its own axis.
    var captureSecondsNow: Double {
        stateLock.lock()
        defer { stateLock.unlock() }
        return fedSeconds
    }

    @discardableResult
    func append(audioBuffer: AVAudioPCMBuffer, sourceSampleRate: Double = 16_000) -> Double {
        guard let channelData = audioBuffer.floatChannelData else {
            return captureSecondsNow
        }
        let frames = Int(audioBuffer.frameLength)
        guard frames > 0 else { return captureSecondsNow }
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frames))

        stateLock.lock()
        let startSeconds = fedSeconds
        fedSeconds += Double(frames) / sourceSampleRate
        stateLock.unlock()
        diarizerQueue.async { [diarizer] in
            do {
                try diarizer.addAudio(samples, sourceSampleRate: sourceSampleRate)
                if diarizer.isAvailable {
                    // No-op until a full chunk (6 frames ≈ 0.96 s) is buffered.
                    _ = try diarizer.process()
                }
            } catch {
                fputs("LiveDiarizationEngine: processing failed: \(error)\n", stderr)
            }
        }
        return startSeconds
    }

    /// Locked snapshot of every speaker segment known so far, sorted by start.
    func speakerSegmentsSnapshot() -> [SpeakerSegment] {
        diarizerQueue.sync {
            var segments: [SpeakerSegment] = []
            for (_, speaker) in diarizer.timeline.speakers {
                for segment in speaker.finalizedSegments {
                    segments.append(
                        SpeakerSegment(
                            slot: speaker.index,
                            startSeconds: Double(segment.startTime),
                            endSeconds: Double(segment.endTime),
                            isTentative: false
                        )
                    )
                }
                for segment in speaker.tentativeSegments {
                    segments.append(
                        SpeakerSegment(
                            slot: speaker.index,
                            startSeconds: Double(segment.startTime),
                            endSeconds: Double(segment.endTime),
                            isTentative: true
                        )
                    )
                }
            }
            return segments.sorted { ($0.startSeconds, $0.endSeconds, $0.slot) < ($1.startSeconds, $1.endSeconds, $1.slot) }
        }
    }

    /// Display index (0 = first speaker heard) for a Sortformer slot, assigning
    /// a new index on first sight. Thread-safe.
    func displayIndex(forSlot slot: Int) -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return displayIndexLocked(forSlot: slot)
    }

    private func displayIndexLocked(forSlot slot: Int) -> Int {
        if let existing = slotDisplayOrder[slot] {
            return existing
        }
        let index = nextDisplayIndex
        slotDisplayOrder[slot] = index
        nextDisplayIndex += 1
        return index
    }

    /// Dominant speaker for a capture-time range, as a display index. Prefers
    /// finalized segments; falls back to tentative ones (recent speech that
    /// hasn't been confirmed yet). Returns nil when no segment overlaps the
    /// range by at least `minimumAttributionOverlapSeconds`.
    func dominantSpeakerIndex(startSeconds: Double, endSeconds: Double) -> Int? {
        guard endSeconds > startSeconds else { return nil }
        let segments = speakerSegmentsSnapshot()
        if let slot = dominantSlot(in: segments, startSeconds: startSeconds, endSeconds: endSeconds, tentative: false)
            ?? dominantSlot(in: segments, startSeconds: startSeconds, endSeconds: endSeconds, tentative: true) {
            return displayIndex(forSlot: slot)
        }
        return nil
    }

    private func dominantSlot(
        in segments: [SpeakerSegment],
        startSeconds: Double,
        endSeconds: Double,
        tentative: Bool
    ) -> Int? {
        var overlapBySlot: [Int: Double] = [:]
        for segment in segments where segment.isTentative == tentative {
            let overlap = min(endSeconds, segment.endSeconds) - max(startSeconds, segment.startSeconds)
            if overlap >= Self.minimumAttributionOverlapSeconds {
                overlapBySlot[segment.slot, default: 0] += overlap
            }
        }
        return overlapBySlot.max { lhs, rhs in
            // Deterministic tie-break: earlier-appearing slot wins.
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }?.key
    }

    /// Releases the diarizer's buffers. Call on session stop.
    func stop() {
        diarizerQueue.async { [diarizer] in
            diarizer.cleanup()
        }
    }
}
