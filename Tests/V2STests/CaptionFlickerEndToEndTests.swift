import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI
import XCTest
@testable import v2s

/// End-to-end caption stability gate.
///
/// Speech is synthesized to files with `say -o` (never played, nothing audible),
/// then streamed at real-time pace through the production pipeline:
/// injected capture buffers → `LiveTranscriptionSession` (gain, Silero VAD,
/// on-device `SpeechTranscriber`) → `CaptionPipeline` → the real `OverlayView`
/// and `AudienceDisplayView` hosted in off-screen windows.
///
/// Every `CaptionScreen` the surface controllers emit is evaluated by
/// `CaptionScreenOracle`; a run-loop observer ordered after Core Animation's
/// commit also checks the painted ink never collapses and recovers while the
/// emitted screen text did not shrink.
///
/// Skips when this Mac lacks the voice or the on-device speech assets, so CI
/// without them stays green; set `EASY2SAY_FLICKER_ARTIFACTS=<dir>` to keep the
/// screen trace around every run.
final class CaptionFlickerEndToEndTests: XCTestCase {
    @MainActor
    func testEnglishSpeechCaptionsStayStable() async throws {
        let report = try await CaptionE2EHarness(scenario: .english).run()
        assertStable(report)
    }

    @MainActor
    func testMandarinSpeechCaptionsStayStable() async throws {
        let report = try await CaptionE2EHarness(scenario: .mandarin).run()
        assertStable(report)
    }

    @MainActor
    func testCodeswitchCaptionsStayStable() async throws {
        let report = try await CaptionE2EHarness(scenario: .codeswitch).run()
        assertStable(report)
    }

    func testCoverageFlagsADroppedSentenceButToleratesRecognitionVariants() {
        let script = "Good morning, everyone. [[slnc 450]] Thank you for coming to our first session today. Let us begin."
        let recognized = CaptionCoverage.sentenceRecall(
            script: script,
            transcript: ["Good morning everyone.", "Thank you for coming to our 1st", "session today.", "Let us begin."]
        )
        XCTAssertEqual(recognized.count, 3)
        XCTAssertTrue(recognized.allSatisfy { $0.recall >= CaptionCoverage.minimumSentenceRecall }, "\(recognized)")

        let dropped = CaptionCoverage.sentenceRecall(
            script: script,
            transcript: ["Good morning everyone.", "Let us begin."]
        )
        XCTAssertLessThan(dropped[1].recall, CaptionCoverage.minimumSentenceRecall)

        let mandarin = CaptionCoverage.sentenceRecall(
            script: "大家早安。[[slnc 450]]謝謝各位今天來參加我們的第一場會議。我們開始吧。",
            transcript: ["大家早安，謝謝各位今天來參加我們的第一場會議。"]
        )
        XCTAssertGreaterThanOrEqual(mandarin[1].recall, CaptionCoverage.minimumSentenceRecall)
        XCTAssertLessThan(mandarin[2].recall, CaptionCoverage.minimumSentenceRecall)

        // A dropped CJK sentence must not score on characters its neighbours share.
        let droppedMandarin = CaptionCoverage.sentenceRecall(
            script: "任何東西都不應該閃爍。文字也不應該消失之後又出現。現在開始吧。",
            transcript: ["任何東西都不應該閃爍。", "現在開始吧。"]
        )
        XCTAssertLessThan(droppedMandarin[1].recall, CaptionCoverage.minimumSentenceRecall, "\(droppedMandarin)")
    }

    private func assertStable(
        _ report: CaptionE2EReport,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        print(report.summary)
        // The run must have exercised the pipeline, or every check below is vacuous.
        XCTAssertGreaterThanOrEqual(report.sealedRowCount, 3, "too few sealed rows reached the pipeline", file: file, line: line)
        XCTAssertGreaterThan(report.emittedScreenCount, 10, "too few screens emitted", file: file, line: line)
        for entry in report.sentenceCoverage {
            XCTAssertGreaterThanOrEqual(
                entry.recall,
                CaptionCoverage.minimumSentenceRecall,
                "spoken sentence missing from the captions: \(entry.sentence)",
                file: file,
                line: line
            )
        }
        XCTAssertEqual(
            report.violations, [],
            "oracle violations:\n\(report.violations.map(\.description).joined(separator: "\n"))",
            file: file,
            line: line
        )
        XCTAssertEqual(
            report.inkBlinks, [],
            "ink blinks:\n\(report.inkBlinks.joined(separator: "\n"))",
            file: file,
            line: line
        )
    }
}

// MARK: - Scenario

struct CaptionE2EScenario {
    struct Segment {
        let voice: String
        /// `say` text with embedded `[[slnc ms]]` pauses.
        let text: String
    }

    let name: String
    let speechLocaleIdentifier: String
    let inputLanguageID: String
    let outputLanguageID: String
    let segments: [Segment]

    /// `say` text joined across segments; `CaptionCoverage` parses it back into
    /// the scripted sentences.
    var script: String {
        segments.map(\.text).joined(separator: " [[slnc 500]] ")
    }

    static let english = CaptionE2EScenario(
        name: "english",
        speechLocaleIdentifier: "en-US",
        inputLanguageID: "en",
        outputLanguageID: "zh-Hant",
        segments: [
            Segment(
                voice: "Samantha",
                text: """
                Good morning, everyone. [[slnc 450]] Thank you for coming to our first session today. \
                [[slnc 1600]] We will talk about [[slnc 750]] how captions should appear on the screen \
                while a person is still speaking, because every sentence keeps changing until the speaker \
                finally finishes it. [[slnc 400]] Nothing should blink. [[slnc 1300]] Words must never vanish \
                and then come back. [[slnc 350]] Let us begin.
                """
            )
        ]
    )

    static let mandarin = CaptionE2EScenario(
        name: "mandarin",
        speechLocaleIdentifier: "zh-TW",
        inputLanguageID: "zh-Hant",
        outputLanguageID: "en",
        segments: [
            Segment(
                voice: "Meijia",
                text: """
                大家早安。[[slnc 450]]謝謝各位今天來參加我們的第一場會議。[[slnc 1600]]我們要談談\
                [[slnc 750]]字幕在講者還在說話的時候應該如何出現在螢幕上，因為每一句話在講者說完之前都會一直改變。\
                [[slnc 400]]任何東西都不應該閃爍。[[slnc 1300]]文字也不應該消失之後又出現。[[slnc 350]]現在開始吧。
                """
            )
        ]
    )

    /// zh↔en code switching, the dual-lane path: the segment list mirrors the
    /// probe fixture's spoken turns.
    static let codeswitch = CaptionE2EScenario(
        name: "codeswitch",
        speechLocaleIdentifier: "zh-TW",
        inputLanguageID: "zh-Hant",
        outputLanguageID: "en",
        segments: [
            Segment(voice: "Meijia", text: "今天我們要示範即時字幕。[[slnc 700]]"),
            Segment(
                voice: "Samantha",
                text: "Good morning, everyone. Thank you for joining us today. [[slnc 700]]"
            ),
            Segment(
                voice: "Meijia",
                text: "接下來請大家看一下這個展示，[[slnc 300]]它完全在裝置上執行。[[slnc 900]]"
            ),
            Segment(
                voice: "Samantha",
                text: "Any questions so far? [[slnc 500]] Great, let us continue."
            )
        ]
    )
}

// MARK: - Report

struct CaptionE2EReport {
    let scenario: String
    let sealedRowCount: Int
    let emittedScreenCount: Int
    /// Share of each scripted sentence's words found, in order, in the transcript.
    let sentenceCoverage: [(sentence: String, recall: Double)]
    let violations: [CaptionViolation]
    let inkBlinks: [String]
    let oracleSummaries: [String]

    var summary: String {
        var lines = [
            "[caption-e2e] \(scenario): sealedRows=\(sealedRowCount) emittedScreens=\(emittedScreenCount) "
                + "violations=\(violations.count) inkBlinks=\(inkBlinks.count)"
        ]
        lines.append(contentsOf: oracleSummaries)
        for entry in sentenceCoverage where entry.recall < CaptionCoverage.minimumSentenceRecall {
            lines.append(String(format: "  missing %.0f%%: %@", (1 - entry.recall) * 100, entry.sentence))
        }
        for violation in violations {
            lines.append("  \(violation)")
        }
        for blink in inkBlinks {
            lines.append("  \(blink)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Harness

@MainActor
final class CaptionE2EHarness {
    private let scenario: CaptionE2EScenario
    private let translationLatencyNanoseconds: UInt64 = 180_000_000
    private let interSegmentSilenceSeconds: Double = 0.5
    private let trailingSilenceSeconds: Double = 4.0
    static let shotsDirectory = "/tmp/e2s-v2/shots"

    init(scenario: CaptionE2EScenario) {
        self.scenario = scenario
    }

    func run() async throws -> CaptionE2EReport {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("SpeechTranscriber requires macOS 26")
        }
        try await requireInstalledSpeechAssets()
        let workDirectory = try makeWorkDirectory()
        let buffers = try synthesizeBuffers(into: workDirectory)

        let settingsURL = workDirectory.appendingPathComponent("settings.json")
        var settings = AppSettings.default
        settings.selectedSourceID = SingleMicrophoneCatalog.source.id
        settings.selectedSourceIDs = [SingleMicrophoneCatalog.source.id]
        settings.inputLanguageID = scenario.inputLanguageID
        settings.outputLanguageID = scenario.outputLanguageID
        SettingsStore(fileURL: settingsURL).save(settings)

        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: SingleMicrophoneCatalog()
        )
        var sessions: [LiveTranscriptionSession] = []
        model.makeTranscriptionSessionForTesting = {
            let session = LiveTranscriptionSession()
            session.injectsAudioForTesting = true
            sessions.append(session)
            return session
        }
        let latency = translationLatencyNanoseconds
        model.installTranslationForTesting { text, _, target in
            try await Task.sleep(nanoseconds: latency)
            return Self.fakeTranslation(text, target: target)
        }
        model.refreshSources()

        let audienceState = AudienceDisplayState()
        let overlayHost = OffscreenHost(
            rootView: AnyView(OverlayView(model: model, interactionState: OverlayInteractionState())),
            size: NSSize(width: 1_100, height: 240)
        )
        let audienceHost = OffscreenHost(
            rootView: AnyView(AudienceDisplayView(model: model, displayState: audienceState) {}),
            size: NSSize(width: 1_280, height: 720)
        )
        defer {
            overlayHost.close()
            audienceHost.close()
        }

        // The screen stream is the honest record of what the views drew.
        let screenRecorder = ScreenEmitRecorder(model: model)
        let inkRecorder = CommittedInkRecorder(
            model: model,
            surfaces: ["overlay": overlayHost.view, "audience": audienceHost.view]
        )

        await model.startSession()
        guard sessions.count == 1, let session = sessions.first else {
            XCTFail("startSession did not open the injected session (status: \(model.statusMessage))")
            throw XCTSkip("session did not start")
        }
        XCTAssertEqual(model.sessionState, .running, "session failed to start: \(model.statusMessage)")

        screenRecorder.start()
        inkRecorder.start()
        try await streamInRealTime(buffers, into: session)
        try await Task.sleep(nanoseconds: UInt64(trailingSilenceSeconds * 1_000_000_000))
        inkRecorder.stop()
        screenRecorder.stop()

        // Snapshot the last live frame — after stop the document seals and the
        // hosts go idle.
        saveShot(overlayHost.bitmap(), name: "e2e-\(scenario.name)-overlay")
        saveShot(audienceHost.bitmap(), name: "e2e-\(scenario.name)-audience")

        if ProcessInfo.processInfo.environment["EASY2SAY_E2E_DUMP_EVENTS"] != nil {
            dumpEvents(of: session, scenario: scenario.name)
        }
        model.stopSession()

        // `.sessionStopped` crosses an async hop (stopAndWait -> pipeline); wait
        // for it to seal the document before coverage reads the transcript.
        let sealDeadline = Date().addingTimeInterval(4)
        while model.captionDocument.rows.contains(where: { $0.isSealed == false }),
              Date() < sealDeadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let overlayObserved = screenRecorder.screens(for: model.overlayCaptionSurface, prefix: "overlay")
        let audienceObserved = screenRecorder.screens(for: model.audienceCaptionSurface, prefix: "audience")
        let overlayOracle = CaptionScreenOracle.evaluate(overlayObserved)
        let audienceOracle = CaptionScreenOracle.evaluate(audienceObserved)
        let violations = overlayOracle.violations + audienceOracle.violations
        let inkBlinks = inkRecorder.blinks()

        if violations.isEmpty == false || inkBlinks.isEmpty == false {
            try writeViolationReport(
                violations: violations,
                inkBlinks: inkBlinks,
                screens: overlayObserved + audienceObserved
            )
        }
        return CaptionE2EReport(
            scenario: scenario.name,
            sealedRowCount: model.captionDocument.rows.filter(\.isSealed).count,
            emittedScreenCount: overlayObserved.count + audienceObserved.count,
            sentenceCoverage: CaptionCoverage.sentenceRecall(
                script: scenario.script,
                transcript: model.transcriptEntries.map(\.sourceText)
            ),
            violations: violations,
            inkBlinks: inkBlinks,
            oracleSummaries: [
                "[caption-e2e] \(scenario.name)/overlay:\n\(overlayOracle.summary)",
                "[caption-e2e] \(scenario.name)/audience:\n\(audienceOracle.summary)",
            ]
        )
    }

    // MARK: Audio

    @available(macOS 26.0, *)
    private func requireInstalledSpeechAssets() async throws {
        let requested = Locale(identifier: scenario.speechLocaleIdentifier)
        guard SpeechTranscriber.isAvailable,
              let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw XCTSkip("SpeechTranscriber does not support \(scenario.speechLocaleIdentifier) here")
        }
        let installed = await SpeechTranscriber.installedLocales
        guard installed.contains(where: { $0.identifier(.bcp47) == resolved.identifier(.bcp47) }) else {
            throw XCTSkip("on-device speech assets for \(resolved.identifier) are not installed")
        }
    }

    private func makeWorkDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("easy2say-e2e-\(scenario.name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Renders every segment with `say -o` (file only, never played), then joins
    /// the 1024-frame buffers with 500 ms of room silence between segments —
    /// the size a 48 kHz capture tap hands the session.
    private func synthesizeBuffers(into directory: URL) throws -> [AVAudioPCMBuffer] {
        var buffers: [AVAudioPCMBuffer] = []
        var format: AVAudioFormat?
        for (index, segment) in scenario.segments.enumerated() {
            let url = directory.appendingPathComponent("segment-\(index).wav")
            try renderSpeech(segment.text, voice: segment.voice, to: url)
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            format = format ?? file.processingFormat
            let chunk: AVAudioFrameCount = 1_024
            var segmentBuffers: [AVAudioPCMBuffer] = []
            while file.framePosition < file.length {
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk))
                try file.read(into: buffer, frameCount: chunk)
                guard buffer.frameLength > 0 else { break }
                segmentBuffers.append(buffer)
            }
            if index > 0, let format {
                buffers.append(contentsOf: silenceBuffers(interSegmentSilenceSeconds, format: format))
            }
            buffers.append(contentsOf: segmentBuffers)
        }
        if let format {
            buffers.append(contentsOf: silenceBuffers(trailingSilenceSeconds, format: format))
        }
        guard buffers.isEmpty == false else {
            throw XCTSkip("no audio synthesized for \(scenario.name)")
        }
        return buffers
    }

    private func silenceBuffers(_ seconds: Double, format: AVAudioFormat) -> [AVAudioPCMBuffer] {
        let chunk: AVAudioFrameCount = 1_024
        let count = Int((seconds * format.sampleRate / Double(chunk)).rounded(.up))
        return (0..<count).compactMap { _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return nil }
            buffer.frameLength = chunk
            // Fresh buffers are not documented as zero-filled; room silence must be.
            for channel in 0..<Int(format.channelCount) {
                buffer.floatChannelData?[channel].update(repeating: 0, count: Int(chunk))
            }
            return buffer
        }
    }

    private func renderSpeech(_ text: String, voice: String, to url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = [
            "-v", voice,
            "-o", url.path,
            "--file-format=WAVE",
            "--data-format=LEF32@48000",
            text
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

    /// Hands each buffer to the session on an absolute real-time schedule, off the
    /// main actor so the UI runs exactly as it does behind a live microphone.
    private func streamInRealTime(
        _ buffers: [AVAudioPCMBuffer],
        into session: LiveTranscriptionSession
    ) async throws {
        guard let format = buffers.first?.format else { return }
        let chunkSeconds = Double(buffers[0].frameCapacity) / format.sampleRate
        let feeder = Task.detached(priority: .userInitiated) {
            let clock = ContinuousClock()
            let start = clock.now
            for (index, buffer) in buffers.enumerated() {
                try await clock.sleep(
                    until: start + .seconds(Double(index + 1) * chunkSeconds),
                    tolerance: .milliseconds(2)
                )
                session.appendInjectedAudioForTesting(buffer)
            }
        }
        try await feeder.value
    }

    /// Deterministic stand-in for Apple Translation. A per-character cipher (ROT13
    /// for Latin, next code point for Han) never equals its source, and a growing
    /// source yields a growing translation, so the translated lane revises in place
    /// the way a real one does.
    nonisolated static func fakeTranslation(_ text: String, target: String) -> String {
        _ = target
        return String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            switch scalar.value {
            case 0x41...0x5A:
                return Unicode.Scalar((scalar.value - 0x41 + 13) % 26 + 0x41)!
            case 0x61...0x7A:
                return Unicode.Scalar((scalar.value - 0x61 + 13) % 26 + 0x61)!
            case 0x4E00..<0x9FFF:
                return Unicode.Scalar(scalar.value + 1)!
            default:
                return scalar
            }
        }))
    }

    private func dumpEvents(of session: LiveTranscriptionSession, scenario: String) {
        var out = ""
        for event in session.emittedEventsForTesting {
            switch event {
            case .result(let result):
                out += String(
                    format: "RESULT %@ final=%d range=%d..%d fin=%@ fed=%d text=%@\n",
                    result.lane.languageID, result.isFinal ? 1 : 0,
                    result.rangeStartMs, result.rangeStartMs + result.rangeDurationMs,
                    result.finalizationMs.map(String.init) ?? "nil",
                    result.audioFedMs, result.text
                )
                for run in result.runs where result.isFinal {
                    out += String(
                        format: "  run %d..%d conf=%@ text=%@\n",
                        run.startMs ?? -1, (run.startMs ?? -1) + (run.durationMs ?? 0),
                        run.confidence.map { String(format: "%.2f", $0) } ?? "nil",
                        run.text
                    )
                }
            case .vad(let edge, let audioMs):
                out += "VAD \(edge == .onset ? "onset" : "offset") audioMs=\(audioMs)\n"
            }
        }
        let url = URL(fileURLWithPath: "/tmp/e2s-v2/e2e-\(scenario)-events.txt")
        try? out.write(to: url, atomically: true, encoding: .utf8)
    }

    private func saveShot(_ bitmap: NSBitmapImageRep?, name: String) {
        guard let data = bitmap?.representation(using: .png, properties: [:]) else { return }
        try? data.write(
            to: URL(fileURLWithPath: Self.shotsDirectory).appendingPathComponent("\(name).png")
        )
    }

    /// Exact violation lines plus the surrounding screens so a regression can be
    /// diagnosed without rerunning the suite.
    private func writeViolationReport(
        violations: [CaptionViolation],
        inkBlinks: [String],
        screens: [ObservedScreen]
    ) throws {
        var text = "# \(scenario.name) e2e violations\n\n"
        text += "## Violations\n"
        for violation in violations {
            text += "\(violation)\n"
        }
        for blink in inkBlinks {
            text += "\(blink)\n"
        }
        text += "\n## Screens\n"
        for screen in screens {
            text += String(format: "t=%.3fs\n", screen.time)
            for pane in screen.panes.keys.sorted() {
                let lines = screen.panes[pane] ?? []
                text += "  \(pane): " + lines.map { "[\($0.text)]" }.joined(separator: " ") + "\n"
            }
        }
        let path = "/tmp/e2s-v2/e2e-\(scenario.name)-violations.txt"
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

// MARK: - Screen recording

/// Records every screen each controller emits, with wall-clock seconds relative
/// to `start()`. The stream is what the views actually drew — no sampling.
@MainActor
private final class ScreenEmitRecorder {
    private let model: AppModel
    private var startTime: CFTimeInterval = 0
    private var overlay: [(time: TimeInterval, screen: CaptionScreen)] = []
    private var audience: [(time: TimeInterval, screen: CaptionScreen)] = []
    private var subscriptions: Set<AnyCancellable> = []

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        startTime = CACurrentMediaTime()
        model.overlayCaptionSurface.$screen.sink { [weak self] screen in
            self?.overlay.append((CACurrentMediaTime() - (self?.startTime ?? 0), screen))
        }.store(in: &subscriptions)
        model.audienceCaptionSurface.$screen.sink { [weak self] screen in
            self?.audience.append((CACurrentMediaTime() - (self?.startTime ?? 0), screen))
        }.store(in: &subscriptions)
    }

    func stop() {
        subscriptions.removeAll()
    }

    func screens(
        for controller: CaptionSurfaceController,
        prefix: String
    ) -> [ObservedScreen] {
        let series = controller === model.overlayCaptionSurface ? overlay : audience
        return series.map { entry in
            ObservedScreen(
                time: entry.time,
                panes: CaptionSurfaceRenderTests.panes(of: entry.screen, prefix: prefix)
            )
        }
    }
}

// MARK: - Ink recording

/// Total painted caption ink on one surface for one committed frame.
struct InkSample {
    let time: TimeInterval
    let ink: Int
    /// Characters in the emitted screen at that instant.
    let textChars: Int
}

/// Samples once per main run-loop turn, just before the thread sleeps and after
/// AppKit's display cycle and Core Animation's commit have run. A blink a body
/// pass could never intend — ink collapse while the emitted screen text did not
/// shrink — is caught here, separate from the screen oracle.
@MainActor
private final class CommittedInkRecorder {
    private let model: AppModel
    private let surfaces: [(name: String, view: NSView)]
    private var observer: CFRunLoopObserver?
    private var startTime: CFTimeInterval = 0
    private(set) var samples: [String: [InkSample]] = [:]

    init(model: AppModel, surfaces: [String: NSView]) {
        self.model = model
        self.surfaces = surfaces.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    func start() {
        startTime = CACurrentMediaTime()
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.beforeWaiting.rawValue,
            true,
            // After AppKit's display cycle and CA's commit (order 2,000,000).
            2_100_000
        ) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.sample()
            }
        }
        self.observer = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    func stop() {
        if let observer {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            CFRunLoopObserverInvalidate(observer)
        }
        observer = nil
    }

    private func sample() {
        let time = CACurrentMediaTime() - startTime
        for surface in surfaces {
            guard let bitmap = Self.capture(surface.view) else { continue }
            let textChars = (surface.name == "overlay"
                ? model.overlayCaptionSurface.screen
                : model.audienceCaptionSurface.screen
            ).lines.reduce(0) { $0 + $1.text.count }
            samples[surface.name, default: []].append(
                InkSample(time: time, ink: Self.totalInk(bitmap), textChars: textChars)
            )
        }
    }

    /// Ink dropped below 30% of the previous committed frame, recovered within
    /// 300 ms, and the emitted screen's text did not shrink in between.
    func blinks() -> [String] {
        var found: [String] = []
        for (surface, series) in samples {
            for index in 1..<series.count {
                let previous = series[index - 1]
                let current = series[index]
                guard previous.ink > 0,
                      current.ink < Int((Double(previous.ink) * 0.3).rounded(.down)),
                      current.textChars >= previous.textChars else { continue }
                if let recovered = series[(index + 1)...].first(where: {
                    $0.ink >= Int((Double(previous.ink) * 0.5).rounded(.down))
                }), recovered.time - current.time <= 0.3 {
                    found.append(
                        String(
                            format: "inkBlink %@ t=%.3fs ink=%d→%d→%d textChars=%d→%d",
                            surface, current.time, previous.ink, current.ink,
                            recovered.ink, previous.textChars, current.textChars
                        )
                    )
                }
            }
        }
        return found.sorted()
    }

    /// Draws the committed layer tree at 1x without forcing layout, so a pending
    /// SwiftUI update scheduled for the next turn stays pending.
    static func capture(_ view: NSView) -> NSBitmapImageRep? {
        let size = view.bounds.size
        guard size.width > 0, size.height > 0,
              let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width),
                pixelsHigh: Int(size.height),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 32
              ) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    /// Bright-ink pixel count: max RGB channel above the threshold the caption
    /// text clears and the black host background stays under.
    private static func totalInk(_ bitmap: NSBitmapImageRep) -> Int {
        guard let data = bitmap.bitmapData else { return 0 }
        let threshold: UInt8 = 90
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            let row = data + y * bitmap.bytesPerRow
            for x in 0..<bitmap.pixelsWide {
                let pixel = row + x * 4
                if max(pixel[0], max(pixel[1], pixel[2])) > threshold {
                    count += 1
                }
            }
        }
        return count
    }

}

// MARK: - Hosting

@MainActor
private final class OffscreenHost {
    let view: NSView
    private let window: NSWindow

    init(rootView: AnyView, size: NSSize) {
        let hostingView = NSHostingView(rootView: rootView.background(Color.black))
        hostingView.frame = NSRect(origin: .zero, size: size)
        window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.setFrameOrigin(NSPoint(x: -4_000, y: -4_000))
        window.orderFront(nil)
        view = hostingView
    }

    func bitmap() -> NSBitmapImageRep? {
        CommittedInkRecorder.capture(view)
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
    }
}

private struct SingleMicrophoneCatalog: SourceCatalogProviding {
    static let source = InputSource(
        id: "easy2say-e2e-microphone",
        name: "Injected microphone",
        detail: "injected",
        category: .microphone
    )

    func loadSnapshot() -> SourceCatalogSnapshot {
        SourceCatalogSnapshot(applications: [], microphones: [Self.source])
    }
}

// MARK: - Coverage

/// Test-owned check that every scripted sentence reached the transcript. ASR
/// may misspell or re-segment, so each sentence is scored by the share of its
/// words (Latin runs, or single Han characters) that an in-order alignment
/// against the whole transcript recovers inside runs of at least two
/// consecutive words; isolated common words (的, 在, the) earn nothing.
enum CaptionCoverage {
    static let minimumSentenceRecall = 0.7

    static func sentences(of script: String) -> [String] {
        script
            .replacingOccurrences(of: #"\[\[[^\]]*\]\]"#, with: " ", options: .regularExpression)
            .components(separatedBy: CharacterSet(charactersIn: ".!?。！？"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { tokens($0).isEmpty == false }
    }

    static func sentenceRecall(script: String, transcript: [String]) -> [(sentence: String, recall: Double)] {
        let parts = Self.sentences(of: script)
        let sentenceTokens = parts.map(tokens)
        let matched = runMatches(sentenceTokens.flatMap { $0 }, tokens(transcript.joined(separator: " ")))

        var offset = 0
        return zip(parts, sentenceTokens).map { sentence, words in
            let range = offset..<(offset + words.count)
            offset += words.count
            let found = range.filter { matched.contains($0) }.count
            return (sentence, Double(found) / Double(words.count))
        }
    }

    /// Lowercased Latin words and digits, and each Han character on its own.
    static func tokens(_ text: String) -> [String] {
        var result: [String] = []
        var word = ""
        for scalar in text.lowercased().unicodeScalars {
            if scalar.properties.isIdeographic {
                if word.isEmpty == false { result.append(word); word = "" }
                result.append(String(scalar))
            } else if CharacterSet.alphanumerics.contains(scalar) {
                word.unicodeScalars.append(scalar)
            } else if word.isEmpty == false {
                result.append(word)
                word = ""
            }
        }
        if word.isEmpty == false { result.append(word) }
        return result
    }

    /// Indices of `lhs` matched by a longest-common-subsequence alignment with
    /// `rhs`, keeping only matches that sit in a run of two or more consecutive
    /// words on both sides.
    private static func runMatches(_ lhs: [String], _ rhs: [String]) -> Set<Int> {
        guard lhs.isEmpty == false, rhs.isEmpty == false else { return [] }
        var table = Array(repeating: Array(repeating: 0, count: rhs.count + 1), count: lhs.count + 1)
        for i in stride(from: lhs.count - 1, through: 0, by: -1) {
            for j in stride(from: rhs.count - 1, through: 0, by: -1) {
                table[i][j] = lhs[i] == rhs[j]
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0
        var j = 0
        while i < lhs.count, j < rhs.count {
            if lhs[i] == rhs[j] {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        var matched: Set<Int> = []
        for (k, pair) in pairs.enumerated() {
            let joinsPrevious = k > 0 && pairs[k - 1] == (pair.0 - 1, pair.1 - 1)
            let joinsNext = k + 1 < pairs.count && pairs[k + 1] == (pair.0 + 1, pair.1 + 1)
            if joinsPrevious || joinsNext { matched.insert(pair.0) }
        }
        return matched
    }
}
