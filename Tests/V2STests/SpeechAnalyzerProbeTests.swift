import AVFoundation
import CoreMedia
import Speech
import XCTest
@testable import v2s

/// SpeechAnalyzer measurement probe.
///
/// Records what Apple's SpeechAnalyzer/SpeechTranscriber actually emits for
/// realistic synthesized speech, with and without app-driven
/// `finalize(through:)`. Output is one JSONL trace per scenario×mode in
/// `EASY2SAY_PROBE_OUT`, later copied into `Fixtures/AnalyzerTraces/` for the
/// replay tests. Nothing is played through an output device: `say -o` renders
/// each segment to a WAV that is streamed at real-time pace.
///
/// Skips unless `EASY2SAY_PROBE_OUT=<dir>` is set, so a normal `swift test`
/// never records.
final class SpeechAnalyzerProbeTests: XCTestCase {
    func testEnglishNatural() async throws { try await run(scenario: .english, mode: .natural) }
    func testEnglishVadcut() async throws { try await run(scenario: .english, mode: .vadcut) }
    func testMandarinNatural() async throws { try await run(scenario: .mandarin, mode: .natural) }
    func testMandarinVadcut() async throws { try await run(scenario: .mandarin, mode: .vadcut) }
    func testCodeswitchNatural() async throws { try await run(scenario: .codeswitch, mode: .natural) }
    func testCodeswitchVadcut() async throws { try await run(scenario: .codeswitch, mode: .vadcut) }
    func testMonologueNatural() async throws { try await run(scenario: .monologue, mode: .natural) }
    func testMonologueVadcut() async throws { try await run(scenario: .monologue, mode: .vadcut) }

    private func run(scenario: SpeechAnalyzerProbeScenario, mode: SpeechAnalyzerProbeMode) async throws {
        guard let outputPath = ProcessInfo.processInfo.environment["EASY2SAY_PROBE_OUT"],
              outputPath.isEmpty == false else {
            throw XCTSkip("set EASY2SAY_PROBE_OUT=<dir> to record SpeechAnalyzer traces")
        }
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("SpeechTranscriber requires macOS 26")
        }
        try await SpeechAnalyzerProbe(
            scenario: scenario,
            mode: mode,
            outputDirectory: URL(fileURLWithPath: outputPath, isDirectory: true)
        ).run()
    }
}

// MARK: - Scenario

enum SpeechAnalyzerProbeMode: String {
    /// Never call `finalize(through:)` before the end of input.
    case natural
    /// Call `finalize(through:)` 300 ms after each VAD speech offset.
    case vadcut
}

struct SpeechAnalyzerProbeSegment {
    let voice: String
    let text: String
}

struct SpeechAnalyzerProbeScenario {
    let name: String
    /// Module locale identifiers in analyzer order (dual-lane: zh-TW first).
    let modules: [String]
    let segments: [SpeechAnalyzerProbeSegment]

    static let english = SpeechAnalyzerProbeScenario(
        name: "english",
        modules: ["en-US"],
        segments: [
            SpeechAnalyzerProbeSegment(
                voice: "Samantha",
                text: "Good morning, everyone. [[slnc 450]] Thank you for coming to our first session today. [[slnc 1600]] We will talk about [[slnc 750]] how captions should appear on the screen while a person is still speaking, because every sentence keeps changing until the speaker finally finishes it. [[slnc 400]] Nothing should blink. [[slnc 1300]] Words must never vanish and then come back. [[slnc 350]] Let us begin."
            )
        ]
    )

    static let mandarin = SpeechAnalyzerProbeScenario(
        name: "mandarin",
        modules: ["zh-TW", "en-US"],
        segments: [
            SpeechAnalyzerProbeSegment(
                voice: "Meijia",
                text: "大家早安。[[slnc 450]]謝謝各位今天來參加我們的第一場會議。[[slnc 1600]]我們要談談[[slnc 750]]字幕在講者還在說話的時候應該如何出現在螢幕上，因為每一句話在講者說完之前都會一直改變。[[slnc 400]]任何東西都不應該閃爍。[[slnc 1300]]文字也不應該消失之後又出現。[[slnc 350]]現在開始吧。"
            )
        ]
    )

    static let codeswitch = SpeechAnalyzerProbeScenario(
        name: "codeswitch",
        modules: ["zh-TW", "en-US"],
        segments: [
            SpeechAnalyzerProbeSegment(voice: "Meijia", text: "今天我們要示範即時字幕。[[slnc 700]]"),
            SpeechAnalyzerProbeSegment(voice: "Samantha", text: "Good morning, everyone. Thank you for joining us today. [[slnc 700]]"),
            SpeechAnalyzerProbeSegment(voice: "Meijia", text: "接下來請大家看一下這個展示，[[slnc 300]]它完全在裝置上執行。[[slnc 900]]"),
            SpeechAnalyzerProbeSegment(voice: "Samantha", text: "Any questions so far? [[slnc 500]] Great, let us continue.")
        ]
    )

    static let monologue = SpeechAnalyzerProbeScenario(
        name: "monologue",
        modules: ["en-US"],
        segments: [
            SpeechAnalyzerProbeSegment(
                voice: "Samantha",
                text: "So the first thing I want to say is that captions are not just a transcript, they are a performance, and when you watch someone read a caption while the speaker keeps talking, you notice that every little change on the screen pulls the eye away from the face, and that is exactly the cognitive cost we are trying to remove, because the audience should spend their attention on the ideas and not on the machinery, which means the text has to grow smoothly, it has to stay where it was, and it should only move when a new line really begins."
            )
        ]
    )
}

// MARK: - Shared feed state

/// Frames handed to the analyzer and the instant the first chunk was fed,
/// shared between the feeder task and the per-module result consumers.
private final class SpeechAnalyzerProbeFeedState: @unchecked Sendable {
    private let lock = NSLock()
    private let analyzerSampleRate: Double
    private var framesFed = 0
    private var firstFeedInstant: ContinuousClock.Instant?

    init(analyzerSampleRate: Double) {
        self.analyzerSampleRate = analyzerSampleRate
    }

    func markFirstFeed(_ instant: ContinuousClock.Instant) {
        lock.lock()
        if firstFeedInstant == nil { firstFeedInstant = instant }
        lock.unlock()
    }

    func addFrames(_ count: Int) {
        lock.lock()
        framesFed += count
        lock.unlock()
    }

    var audioFedMs: Int {
        lock.lock()
        defer { lock.unlock() }
        return Int((Double(framesFed) * 1000 / analyzerSampleRate).rounded())
    }

    var wallMs: Int {
        lock.lock()
        defer { lock.unlock() }
        guard let firstFeedInstant else { return 0 }
        let elapsed = ContinuousClock.now - firstFeedInstant
        let components = elapsed.components
        return Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
    }
}

// MARK: - Trace sink

/// Serializes every event through one actor so line order == observation order.
private actor SpeechAnalyzerProbeTrace {
    private(set) var lines: [String] = []

    func emit(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
              ) else {
            return
        }
        lines.append(String(decoding: data, as: UTF8.self))
    }

    func write(to url: URL) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Probe

@available(macOS 26.0, *)
private final class SpeechAnalyzerProbe {
    private enum ProbeError: Error {
        case resultsTimedOut
    }

    private let scenario: SpeechAnalyzerProbeScenario
    private let mode: SpeechAnalyzerProbeMode
    private let outputDirectory: URL

    /// Same 16 kHz mono Float32 format production offers the analyzer.
    private let processingFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!
    private let sourceFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!
    private let chunkFrameCount = 1_024
    private let interSegmentSilenceSeconds = 0.5
    private let trailingSilenceSeconds = 4.0
    private let vadFinalizeDelayMs = 300
    private let resultsTimeoutNanoseconds: UInt64 = 15_000_000_000

    init(scenario: SpeechAnalyzerProbeScenario, mode: SpeechAnalyzerProbeMode, outputDirectory: URL) {
        self.scenario = scenario
        self.mode = mode
        self.outputDirectory = outputDirectory
    }

    func run() async throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let resolvedLocales = try await requireInstalledSpeechAssets()
        let workDirectory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let samples = try synthesizeProgram(into: workDirectory)
        let totalAudioMs = Int((Double(samples.count) * 1000 / sourceFormat.sampleRate).rounded())
        let chunks = makeChunks(from: samples)

        var transcribers: [SpeechTranscriber] = []
        var moduleLabels: [String] = []
        for locale in resolvedLocales {
            transcribers.append(
                SpeechTranscriber(
                    locale: locale,
                    transcriptionOptions: [],
                    reportingOptions: [.volatileResults, .fastResults],
                    attributeOptions: [.audioTimeRange, .transcriptionConfidence]
                )
            )
            moduleLabels.append(locale.identifier(.bcp47))
        }

        let analyzer = SpeechAnalyzer(
            modules: transcribers,
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .whileInUse)
        )
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: transcribers,
            considering: processingFormat
        ) ?? processingFormat
        try await analyzer.prepareToAnalyze(in: analyzerFormat)

        let trace = SpeechAnalyzerProbeTrace()
        await trace.emit([
            "type": "meta",
            "scenario": scenario.name,
            "mode": mode.rawValue,
            "modules": moduleLabels,
            "analyzerFormat": String(format: "%g/%u", analyzerFormat.sampleRate, analyzerFormat.channelCount),
            "segments": scenario.segments.map { ["voice": $0.voice, "text": $0.text] },
            "totalAudioMs": totalAudioMs,
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
        ])

        let feedState = SpeechAnalyzerProbeFeedState(analyzerSampleRate: analyzerFormat.sampleRate)
        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .unbounded
        )

        var consumers: [Task<Void, Error>] = []
        for (transcriber, label) in zip(transcribers, moduleLabels) {
            consumers.append(
                Task {
                    for try await result in transcriber.results {
                        await trace.emit(
                            Self.resultEvent(
                                result,
                                module: label,
                                wallMs: feedState.wallMs,
                                audioFedMs: feedState.audioFedMs
                            )
                        )
                    }
                }
            )
        }
        let analyzerTask = Task {
            try await analyzer.start(inputSequence: inputStream)
        }
        defer { analyzerTask.cancel() }

        let feeder = makeFeeder(
            chunks: chunks,
            analyzer: analyzer,
            analyzerFormat: analyzerFormat,
            continuation: inputContinuation,
            feedState: feedState,
            trace: trace
        )
        try await feeder.value
        inputContinuation.finish()

        await trace.emit([
            "type": "finalizeCall",
            "throughMs": NSNull(),
            "kind": "end",
            "wallMs": feedState.wallMs,
            "audioFedMs": feedState.audioFedMs,
        ])
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        await trace.emit([
            "type": "finalizeReturn",
            "throughMs": NSNull(),
            "wallMs": feedState.wallMs,
        ])

        try await waitForConsumers(consumers)
        await trace.emit(["type": "end", "wallMs": feedState.wallMs])
        try await trace.write(
            to: outputDirectory.appendingPathComponent("\(scenario.name)-\(mode.rawValue).jsonl")
        )
    }

    // MARK: Speech assets

    /// Same skip-when-missing policy as the flicker harness: record only on a
    /// machine that already has the on-device assets.
    private func requireInstalledSpeechAssets() async throws -> [Locale] {
        guard SpeechTranscriber.isAvailable else {
            throw XCTSkip("SpeechTranscriber is not available here")
        }
        let installed = await SpeechTranscriber.installedLocales
        var resolved: [Locale] = []
        for identifier in scenario.modules {
            let requested = Locale(identifier: identifier)
            guard let resolvedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
                throw XCTSkip("SpeechTranscriber does not support \(identifier) here")
            }
            guard installed.contains(where: { $0.identifier(.bcp47) == resolvedLocale.identifier(.bcp47) }) else {
                throw XCTSkip("on-device speech assets for \(resolvedLocale.identifier) are not installed")
            }
            resolved.append(resolvedLocale)
        }
        return resolved
    }

    // MARK: Audio synthesis

    private func makeWorkDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("easy2say-probe-\(scenario.name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Renders every segment with `say -o` (file only, never played), then
    /// concatenates float samples with 500 ms of zeros between segments and
    /// 4.0 s of zeros at the end.
    private func synthesizeProgram(into directory: URL) throws -> [Float] {
        var samples: [Float] = []
        let gap = [Float](repeating: 0, count: Int(interSegmentSilenceSeconds * sourceFormat.sampleRate))
        for (index, segment) in scenario.segments.enumerated() {
            let wavURL = directory.appendingPathComponent("segment-\(index).wav")
            try renderSpeech(segment.text, voice: segment.voice, to: wavURL)
            if index > 0 { samples.append(contentsOf: gap) }
            samples.append(contentsOf: try loadSamples(from: wavURL))
        }
        samples.append(
            contentsOf: [Float](repeating: 0, count: Int(trailingSilenceSeconds * sourceFormat.sampleRate))
        )
        return samples
    }

    private func renderSpeech(_ text: String, voice: String, to url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = [
            "-v", voice,
            "-o", url.path,
            "--file-format=WAVE",
            "--data-format=LEF32@48000",
            text,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw XCTSkip("/usr/bin/say unavailable: \(error)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
              size > 48_000 else {
            throw XCTSkip("voice \(voice) could not synthesize the script")
        }
    }

    /// Float32 channel-0 samples of the whole file.
    private func loadSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let capacity = AVAudioFrameCount(file.length)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity)
        )
        try file.read(into: buffer, frameCount: capacity)
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else {
            return []
        }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
    }

    private func makeChunks(from samples: [Float]) -> [AVAudioPCMBuffer] {
        var chunks: [AVAudioPCMBuffer] = []
        var index = 0
        while index < samples.count {
            let count = min(chunkFrameCount, samples.count - index)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: AVAudioFrameCount(count)
            ) else { break }
            buffer.frameLength = AVAudioFrameCount(count)
            if let channelData = buffer.floatChannelData {
                samples.withUnsafeBufferPointer { source in
                    channelData[0].update(from: source.baseAddress! + index, count: count)
                }
            }
            chunks.append(buffer)
            index += count
        }
        return chunks
    }

    // MARK: Feeding

    /// Streams 1024-frame chunks on an absolute ContinuousClock schedule from a
    /// detached task, mirroring the flicker harness. Each chunk is converted to
    /// the analyzer format with one persistent AVAudioConverter and to 16 kHz
    /// for the Silero VAD with a second. In `vadcut` mode a speech offset that
    /// stays unmatched for 300 ms fires `analyzer.finalize(through:)` off the
    /// feeding path.
    private func makeFeeder(
        chunks: [AVAudioPCMBuffer],
        analyzer: SpeechAnalyzer,
        analyzerFormat: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        feedState: SpeechAnalyzerProbeFeedState,
        trace: SpeechAnalyzerProbeTrace
    ) -> Task<Void, Error> {
        let mode = self.mode
        let sourceFormat = self.sourceFormat
        let vadFormat = self.processingFormat
        let vadFinalizeDelayMs = self.vadFinalizeDelayMs
        let chunkSeconds = Double(chunkFrameCount) / sourceFormat.sampleRate
        return Task.detached(priority: .userInitiated) {
            let analyzerConverter = try XCTUnwrap(
                AVAudioConverter(from: sourceFormat, to: analyzerFormat)
            )
            let vadConverter = try XCTUnwrap(
                AVAudioConverter(from: sourceFormat, to: vadFormat)
            )
            let vad = try SileroVADEngine()
            let clock = ContinuousClock()
            let start = clock.now
            var pendingOffsetMs: Int?

            for (index, chunk) in chunks.enumerated() {
                try await clock.sleep(
                    until: start + .seconds(Double(index + 1) * chunkSeconds),
                    tolerance: .milliseconds(2)
                )
                if index == 0 { feedState.markFirstFeed(clock.now) }

                if let analyzerBuffer = Self.convert(chunk, using: analyzerConverter, to: analyzerFormat) {
                    continuation.yield(AnalyzerInput(buffer: analyzerBuffer))
                    feedState.addFrames(Int(analyzerBuffer.frameLength))
                }

                guard let vadBuffer = Self.convert(chunk, using: vadConverter, to: vadFormat) else {
                    continue
                }
                let result = vad.process(buffer: vadBuffer)
                let audioMs = feedState.audioFedMs
                let wallMs = feedState.wallMs
                if result.containsSpeechOnset {
                    await trace.emit(["type": "vad", "edge": "onset", "audioMs": audioMs, "wallMs": wallMs])
                }
                if result.containsSpeechOffset {
                    await trace.emit(["type": "vad", "edge": "offset", "audioMs": audioMs, "wallMs": wallMs])
                    pendingOffsetMs = audioMs
                }
                if mode == .vadcut, let pending = pendingOffsetMs {
                    if audioMs >= pending + vadFinalizeDelayMs {
                        await trace.emit([
                            "type": "finalizeCall",
                            "throughMs": pending,
                            "kind": "vad",
                            "wallMs": wallMs,
                            "audioFedMs": audioMs,
                        ])
                        pendingOffsetMs = nil
                        Task.detached {
                            try? await analyzer.finalize(
                                through: CMTime(value: CMTimeValue(pending), timescale: 1_000)
                            )
                            await trace.emit([
                                "type": "finalizeReturn",
                                "throughMs": pending,
                                "wallMs": feedState.wallMs,
                            ])
                        }
                    } else if result.containsSpeechOnset {
                        pendingOffsetMs = nil
                    }
                }
            }
        }
    }

    /// Same one-shot convert shape as production `convertBuffer`.
    private static func convert(
        _ inputBuffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to outputFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let outputFrameCapacity = max(
            AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * outputFormat.sampleRate / inputBuffer.format.sampleRate)),
            1
        )
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) else {
            return nil
        }
        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        guard conversionError == nil else { return nil }
        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            guard outputBuffer.frameLength > 0 else { return nil }
            return outputBuffer
        case .error:
            return nil
        @unknown default:
            return nil
        }
    }

    private func waitForConsumers(_ consumers: [Task<Void, Error>]) async throws {
        var remaining = consumers.count
        try await withThrowingTaskGroup(of: Void.self) { group in
            for consumer in consumers {
                group.addTask { try await consumer.value }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: self.resultsTimeoutNanoseconds)
                throw ProbeError.resultsTimedOut
            }
            while remaining > 0 {
                _ = try await group.next()
                remaining -= 1
            }
            group.cancelAll()
        }
    }

    // MARK: Events

    private static func resultEvent(
        _ result: SpeechTranscriber.Result,
        module: String,
        wallMs: Int,
        audioFedMs: Int
    ) -> [String: Any] {
        var runs: [[String: Any]] = []
        var confidenceSum = 0.0
        var confidenceCount = 0
        for run in result.text.runs {
            var entry: [String: Any] = ["t": String(result.text[run.range].characters)]
            if let range = run.audioTimeRange {
                entry["s"] = millisecondsOrNull(range.start)
                entry["d"] = millisecondsOrNull(range.duration)
            } else {
                entry["s"] = NSNull()
                entry["d"] = NSNull()
            }
            if let confidence = run.transcriptionConfidence {
                entry["c"] = confidence
                confidenceSum += confidence
                confidenceCount += 1
            } else {
                entry["c"] = NSNull()
            }
            runs.append(entry)
        }
        return [
            "type": "result",
            "module": module,
            "wallMs": wallMs,
            "audioFedMs": audioFedMs,
            "isFinal": result.isFinal,
            "rangeStartMs": millisecondsOrNull(result.range.start),
            "rangeDurMs": millisecondsOrNull(result.range.duration),
            "finalizationMs": millisecondsOrNull(result.resultsFinalizationTime),
            "text": String(result.text.characters),
            "confidence": confidenceCount > 0 ? confidenceSum / Double(confidenceCount) : NSNull(),
            "runs": runs,
            "alts": result.alternatives.count,
        ]
    }

    private static func millisecondsOrNull(_ time: CMTime) -> Any {
        guard time.isNumeric else { return NSNull() }
        return Int((CMTimeGetSeconds(time) * 1000.0).rounded())
    }
}
