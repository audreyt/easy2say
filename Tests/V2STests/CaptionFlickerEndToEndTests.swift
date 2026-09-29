import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI
import XCTest
@testable import v2s

/// End-to-end caption flicker gate.
///
/// Speech is synthesized to a file with `say -o` (never played, nothing audible),
/// then streamed at real-time pace through the production pipeline:
/// injected capture buffers → `LiveTranscriptionSession` (gain, Silero VAD,
/// on-device `SpeechTranscriber`) → `AppModel` caption queue and translation →
/// the real `OverlayView` and `AudienceDisplayView` hosted in off-screen windows.
///
/// A run-loop observer ordered after Core Animation's commit samples every state
/// the window server could have put on screen. The flicker oracle below is owned
/// by this test and deliberately shares no classifier with production.
///
/// Skips when this Mac lacks the voice or the on-device speech assets, so CI
/// without them stays green; set `EASY2SAY_FLICKER_ARTIFACTS=<dir>` to keep the
/// frame trace and PNG frames around every flagged flicker.
final class CaptionFlickerEndToEndTests: XCTestCase {
    @MainActor
    func testEnglishSpeechCaptionsNeverFlicker() async throws {
        let report = try await CaptionFlickerHarness(scenario: .english).run()
        assertNoFlicker(report)
    }

    @MainActor
    func testMandarinSpeechCaptionsNeverFlicker() async throws {
        let report = try await CaptionFlickerHarness(scenario: .mandarin).run()
        assertNoFlicker(report)
    }

    /// Proves the oracle is not vacuous: each flicker shape it claims to catch is
    /// caught, and ordinary caption evolution is not. Runs without audio.
    func testOracleFlagsEachFlickerShapeAndPassesOrdinaryCaptionEvolution() {
        func frames(_ steps: [(TimeInterval, [String], Int)]) -> [CaptionFrame] {
            steps.enumerated().map { index, step in
                CaptionFrame(
                    index: index,
                    time: step.0,
                    lanes: ["overlay.source": step.1],
                    ink: ["overlay": InkProfile(bands: [.init(rows: 0...10, ink: step.2)])]
                )
            }
        }
        let kinds = { (frames: [CaptionFrame]) in CaptionFlickerOracle.flickers(in: frames).map(\.kind) }

        // Growth, finalization, a new sentence below it, a long pause, archive.
        XCTAssertEqual(kinds(frames([
            (0.0, ["Good"], 100),
            (0.1, ["Good morning"], 300),
            (0.2, ["Good morning, everyone."], 500),
            (0.3, ["Good morning, everyone.", "Thank"], 600),
            (0.4, ["Good morning, everyone.", "Thank you for coming."], 900),
            (1.5, [], 0),
            (3.0, ["We will"], 200)
        ])), [])

        XCTAssertEqual(kinds(frames([
            (0.0, ["Good morning"], 500),
            (0.1, [], 500),
            (0.2, ["Good morning, everyone"], 500)
        ])), [.vanish])

        // A row that disappears and returns merged behind its preceding fragment
        // is still the same caption blinking.
        XCTAssertEqual(kinds(frames([
            (0.0, ["大家早安。", "要談談字幕在講者"], 500),
            (0.1, ["大家早安。"], 500),
            (0.3, ["大家早安。", "我們要談談字幕在講者"], 500)
        ])), [.vanish])

        // A row whose whole text comes back is a blink however long it was gone:
        // nothing on either surface legitimately brings an evicted row back.
        XCTAssertEqual(kinds(frames([
            (0.0, ["Good morning, everyone."], 500),
            (0.1, ["Thank you"], 500),
            (4.1, ["Good morning, everyone.", "Thank you"], 500)
        ])), [.vanish])

        // After the blink window, a later sentence that merely shares an opening
        // fragment does not resurrect the evicted row.
        XCTAssertEqual(kinds(frames([
            (0.0, ["Nothing should blink."], 500),
            (0.1, [], 500),
            (2.1, ["Nothing should"], 500)
        ])), [])

        XCTAssertEqual(kinds(frames([
            (0.0, ["Good morning, every"], 500),
            (0.1, ["Good morning"], 500),
            (0.2, ["Good morning, everyone"], 500)
        ])), [.retract])

        // A revised tail is a correction, not a blink.
        XCTAssertEqual(kinds(frames([
            (0.0, ["We will talk a boat"], 500),
            (0.1, ["We will talk"], 500),
            (0.2, ["We will talk about"], 500)
        ])), [])

        XCTAssertEqual(kinds(frames([
            (0.0, ["Good"], 100),
            (0.1, ["Good", "Good morning, everyone"], 400),
            (0.2, ["Good morning, everyone"], 400)
        ])), [.duplicateRow])

        XCTAssertEqual(kinds(frames([
            (0.0, ["Good morning"], 1_000),
            (0.1, ["Good morning"], 100),
            (0.2, ["Good morning"], 1_000)
        ])), [.inkBlink])

        let script = "Good morning, everyone. Thank you for coming today. Let us begin now."
        let ordered = { (steps: [(TimeInterval, [String], Int)]) in
            CaptionFlickerOracle.flickers(in: frames(steps), script: script).map(\.kind)
        }
        XCTAssertEqual(ordered([
            (0.0, ["Good morning, everyone."], 500),
            (0.1, ["Good morning, everyone.", "Thank you for coming"], 800),
            (0.2, ["Thank you for coming today.", "Let us begin"], 800)
        ]), [])
        // Rows swap places.
        XCTAssertEqual(ordered([
            (0.0, ["Good morning, everyone.", "Thank you for coming today."], 800),
            (0.1, ["Thank you for coming today.", "Good morning, everyone."], 800)
        ]), [.outOfOrder])
        // The newest row falls back to an older sentence and stays there.
        XCTAssertEqual(ordered([
            (0.0, ["Let us begin now."], 500),
            (0.1, ["Thank you for coming today."], 500),
            (5.0, ["Thank you for coming today."], 500)
        ]), [.outOfOrder])

        let audience = { (pairs: [[CaptionFrame.AudiencePair]]) in
            CaptionFlickerOracle.flickers(
                in: pairs.enumerated().map { index, rows in
                    CaptionFrame(index: index, time: Double(index) * 0.1, lanes: [:], audiencePairs: rows)
                }
            ).map(\.kind)
        }
        XCTAssertEqual(audience([
            [.init(source: "Good morning", translated: "")],
            [.init(source: "Good morning", translated: "Tbbq zbeavat")]
        ]), [])
        XCTAssertEqual(audience([
            [.init(source: "\u{00A0}", translated: "Tbbq zbeavat"), .init(source: "Thank", translated: "Gunax")]
        ]), [.orphanTranslation])

        // Ink dropping because the content changed is not a paint blink.
        XCTAssertEqual(kinds(frames([
            (0.0, ["Good morning"], 1_000),
            (0.1, ["Thank"], 100),
            (0.2, ["Thank you for coming"], 1_000)
        ])), [])
    }

    /// The coverage gate fails when a spoken sentence never became a caption,
    /// and tolerates ASR spelling and segmentation differences.
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

    private func assertNoFlicker(
        _ report: CaptionFlickerReport,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        print(report.summary)
        // The run must have exercised the pipeline, or every check below is vacuous.
        XCTAssertGreaterThan(report.committedCaptionCount, 2, "no committed captions reached the overlay", file: file, line: line)
        XCTAssertGreaterThan(report.draftFrameCount, 10, "no live draft frames reached the overlay", file: file, line: line)
        XCTAssertGreaterThan(report.frames.count, 50, "too few committed frames sampled", file: file, line: line)
        // Dropping a sentence also removes its flickers; a quieter gate must never
        // come from captions that were never shown.
        for entry in report.sentenceCoverage {
            XCTAssertGreaterThanOrEqual(
                entry.recall,
                CaptionCoverage.minimumSentenceRecall,
                "spoken sentence missing from the captions: \(entry.sentence)",
                file: file,
                line: line
            )
        }
        XCTAssertEqual(report.flickers, [], "caption flicker:\n\(report.flickers.map(\.description).joined(separator: "\n"))", file: file, line: line)
    }
}

// MARK: - Scenario

struct CaptionFlickerScenario {
    let name: String
    let voice: String
    let speechLocaleIdentifier: String
    let inputLanguageID: String
    let outputLanguageID: String
    /// `say` text with embedded `[[slnc ms]]` pauses: a quick sentence pair, a
    /// long pause that outlasts the idle archive, a mid-sentence hesitation, and a
    /// run-on sentence long enough to roll the two-line live slot over.
    ///
    /// The oracle recognizes an utterance by its opening, so every sentence must
    /// open with words no other sentence starts with.
    let script: String

    static let english = CaptionFlickerScenario(
        name: "english",
        voice: "Samantha",
        speechLocaleIdentifier: "en-US",
        inputLanguageID: "en",
        outputLanguageID: "zh-Hant",
        script: """
        Good morning, everyone. [[slnc 450]] Thank you for coming to our first session today. \
        [[slnc 1600]] We will talk about [[slnc 750]] how captions should appear on the screen \
        while a person is still speaking, because every sentence keeps changing until the speaker \
        finally finishes it. [[slnc 400]] Nothing should blink. [[slnc 1300]] Words must never vanish \
        and then come back. [[slnc 350]] Let us begin.
        """
    )

    static let mandarin = CaptionFlickerScenario(
        name: "mandarin",
        voice: "Meijia",
        speechLocaleIdentifier: "zh-TW",
        inputLanguageID: "zh-Hant",
        outputLanguageID: "en",
        script: """
        大家早安。[[slnc 450]]謝謝各位今天來參加我們的第一場會議。[[slnc 1600]]我們要談談\
        [[slnc 750]]字幕在講者還在說話的時候應該如何出現在螢幕上，因為每一句話在講者說完之前都會一直改變。\
        [[slnc 400]]任何東西都不應該閃爍。[[slnc 1300]]文字也不應該消失之後又出現。[[slnc 350]]現在開始吧。
        """
    )
}

// MARK: - Report

struct CaptionFlickerReport {
    let scenario: String
    let frames: [CaptionFrame]
    let flickers: [CaptionFlicker]
    let committedCaptionCount: Int
    /// Share of each scripted sentence's words found, in order, in the transcript.
    let sentenceCoverage: [(sentence: String, recall: Double)]
    let draftFrameCount: Int
    /// `$overlayState` publishes while recording. Several publishes inside one
    /// run-loop turn reach the screen as one committed frame.
    let overlayPublishCount: Int
    let artifactDirectory: URL?

    var summary: String {
        var lines = [
            "[flicker-e2e] \(scenario): frames=\(frames.count) publishes=\(overlayPublishCount) committed=\(committedCaptionCount) draftFrames=\(draftFrameCount) flickers=\(flickers.count)"
        ]
        for entry in sentenceCoverage where entry.recall < CaptionCoverage.minimumSentenceRecall {
            lines.append(String(format: "  missing %.0f%%: %@", (1 - entry.recall) * 100, entry.sentence))
        }
        let counts = Dictionary(grouping: flickers, by: \.kind).mapValues(\.count)
        for (kind, count) in counts.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            lines.append("  \(kind.rawValue): \(count)")
        }
        if let artifactDirectory {
            lines.append("  artifacts: \(artifactDirectory.path)")
        }
        return lines.joined(separator: "\n")
    }
}

struct CaptionFlicker: Equatable, CustomStringConvertible {
    enum Kind: String {
        /// A row's utterance leaves its lane and comes back.
        case vanish
        /// A row loses its tail and gets the same tail back.
        case retract
        /// The same utterance is visible in two rows at once.
        case duplicateRow
        /// A surface's painted text collapses and comes back.
        case inkBlink
        /// Rows appear out of spoken order, or the newest row regresses to an
        /// utterance older than one already shown.
        case outOfOrder
        /// The audience shows a translation row whose source row is empty.
        case orphanTranslation
    }

    let kind: Kind
    let surface: String
    let startTime: TimeInterval
    let duration: TimeInterval
    let detail: String

    var description: String {
        String(
            format: "%@ %@ t=%.3fs dur=%.0fms %@",
            kind.rawValue, surface, startTime, duration * 1000, detail
        )
    }
}

/// One state the window server could have shown. `time` is seconds since the
/// recorder started; a frame lasts until the next frame's `time`.
struct CaptionFrame {
    let index: Int
    let time: TimeInterval
    /// Text rows each lane shows, top to bottom, keyed `surface.lane`
    /// (`overlay.source`, `overlay.translated`, `audience.source`, ...).
    let lanes: [String: [String]]
    let hasDraft: Bool
    let ink: [String: InkProfile]
    /// Audience rows as painted, empty lanes included, so a translation shown
    /// without its source is visible to the oracle.
    let audiencePairs: [AudiencePair]
    /// The model state behind the frame, for the artifact trace only.
    let modelSummary: String

    struct AudiencePair: Equatable {
        let source: String
        let translated: String
    }

    init(
        index: Int,
        time: TimeInterval,
        lanes: [String: [String]],
        hasDraft: Bool = false,
        ink: [String: InkProfile] = [:],
        audiencePairs: [AudiencePair] = [],
        modelSummary: String = ""
    ) {
        self.index = index
        self.time = time
        self.lanes = lanes
        self.hasDraft = hasDraft
        self.ink = ink
        self.audiencePairs = audiencePairs
        self.modelSummary = modelSummary
    }
}

/// Horizontal text bands painted on a surface.
struct InkProfile: Equatable {
    struct Band: Equatable {
        let rows: ClosedRange<Int>
        let ink: Int
    }

    let bands: [Band]
    var totalInk: Int { bands.reduce(0) { $0 + $1.ink } }
}

// MARK: - Harness

@MainActor
final class CaptionFlickerHarness {
    private let scenario: CaptionFlickerScenario
    private let translationLatencyNanoseconds: UInt64 = 180_000_000
    private let trailingSilenceSeconds: Double = 4.0

    init(scenario: CaptionFlickerScenario) {
        self.scenario = scenario
    }

    func run() async throws -> CaptionFlickerReport {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("SpeechTranscriber requires macOS 26")
        }
        try await requireInstalledSpeechAssets()
        let workDirectory = try makeWorkDirectory()
        let audioURL = try synthesizeSpeech(into: workDirectory)
        let buffers = try loadCaptureBuffers(from: audioURL)

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

        let audienceState = AudienceDisplayPresentationState(
            initialOverlayState: model.overlayStateForTesting
        )
        var publishCount = 0
        var countsPublishes = false
        let audienceSubscription = model.$overlayState.sink { state in
            if countsPublishes { publishCount += 1 }
            audienceState.consume(state)
        }
        defer { audienceSubscription.cancel() }

        let overlayHost = OffscreenHost(
            rootView: AnyView(OverlayView(model: model, interactionState: OverlayInteractionState())),
            size: NSSize(width: 1_100, height: 240)
        )
        let audienceHost = OffscreenHost(
            rootView: AnyView(AudienceDisplayView(model: model, presentationState: audienceState) {}),
            size: NSSize(width: 1_280, height: 720)
        )
        defer {
            overlayHost.close()
            audienceHost.close()
        }

        let recorder = CommittedFrameRecorder(
            model: model,
            audienceState: audienceState,
            surfaces: ["overlay": overlayHost.view, "audience": audienceHost.view],
            artifactDirectory: artifactDirectory()
        )

        await model.startSession()
        guard sessions.count == 1, let session = sessions.first else {
            XCTFail("startSession did not open the injected session (status: \(model.statusMessage))")
            throw XCTSkip("session did not start")
        }
        XCTAssertEqual(model.sessionState, .running, "session failed to start: \(model.statusMessage)")

        recorder.start()
        countsPublishes = true
        try await streamInRealTime(buffers, into: session)
        try await Task.sleep(nanoseconds: UInt64(trailingSilenceSeconds * 1_000_000_000))
        countsPublishes = false
        recorder.stop()
        model.stopSession()

        let frames = recorder.frames
        let flickers = CaptionFlickerOracle.flickers(in: frames, script: scenario.script)
        try recorder.writeArtifacts(flickers: flickers)
        return CaptionFlickerReport(
            scenario: scenario.name,
            frames: frames,
            flickers: flickers,
            committedCaptionCount: model.transcriptEntriesForTesting.count,
            sentenceCoverage: CaptionCoverage.sentenceRecall(
                script: scenario.script,
                transcript: model.transcriptEntriesForTesting.map(\.sourceText)
            ),
            draftFrameCount: frames.filter(\.hasDraft).count,
            overlayPublishCount: publishCount,
            artifactDirectory: recorder.artifactDirectory
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
            .appendingPathComponent("easy2say-flicker-\(scenario.name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Renders the script to a 48 kHz float WAV. `say -o` writes the file and
    /// never touches an output device.
    private func synthesizeSpeech(into directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("\(scenario.name).wav")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = [
            "-v", scenario.voice,
            "-o", url.path,
            "--file-format=WAVE",
            "--data-format=LEF32@48000",
            scenario.script
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
            throw XCTSkip("voice \(scenario.voice) could not synthesize the script")
        }
        return url
    }

    /// Splits the file into 1024-frame buffers, the size a 48 kHz capture tap hands
    /// the session, followed by trailing room silence.
    private func loadCaptureBuffers(from url: URL) throws -> [AVAudioPCMBuffer] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let chunk: AVAudioFrameCount = 1_024
        var buffers: [AVAudioPCMBuffer] = []
        while file.framePosition < file.length {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk))
            try file.read(into: buffer, frameCount: chunk)
            guard buffer.frameLength > 0 else { break }
            buffers.append(buffer)
        }
        let silenceChunks = Int((trailingSilenceSeconds * format.sampleRate / Double(chunk)).rounded(.up))
        for _ in 0..<silenceChunks {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk))
            buffer.frameLength = chunk
            // Fresh buffers are not documented as zero-filled; room silence must be.
            for channel in 0..<Int(format.channelCount) {
                buffer.floatChannelData?[channel].update(repeating: 0, count: Int(chunk))
            }
            buffers.append(buffer)
        }
        return buffers
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

    private func artifactDirectory() -> URL? {
        guard let path = ProcessInfo.processInfo.environment["EASY2SAY_FLICKER_ARTIFACTS"],
              path.isEmpty == false else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
            .appendingPathComponent(scenario.name, isDirectory: true)
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

    func close() {
        window.orderOut(nil)
        window.contentView = nil
    }
}

private struct SingleMicrophoneCatalog: SourceCatalogProviding {
    static let source = InputSource(
        id: "easy2say-flicker-e2e-microphone",
        name: "Injected microphone",
        detail: "injected",
        category: .microphone
    )

    func loadSnapshot() -> SourceCatalogSnapshot {
        SourceCatalogSnapshot(applications: [], microphones: [Self.source])
    }
}

// MARK: - Recorder

/// Samples once per main run-loop turn, just before the thread sleeps and after
/// AppKit's display cycle and Core Animation's commit have run. Every sample is a
/// state that reached the render server, so an intermediate state recorded here
/// can be on screen even if the next turn replaces it.
@MainActor
private final class CommittedFrameRecorder {
    let artifactDirectory: URL?
    private(set) var frames: [CaptionFrame] = []

    private let model: AppModel
    private let audienceState: AudienceDisplayPresentationState
    private let surfaces: [(name: String, view: NSView)]
    private var observer: CFRunLoopObserver?
    private var startTime: CFTimeInterval = 0
    private var lastSignature: FrameSignature?
    private var images: [Int: [String: NSBitmapImageRep]] = [:]

    private struct FrameSignature: Equatable {
        let lanes: [String: [String]]
        let ink: [String: InkProfile]
        let audiencePairs: [CaptionFrame.AudiencePair]
    }

    init(
        model: AppModel,
        audienceState: AudienceDisplayPresentationState,
        surfaces: [String: NSView],
        artifactDirectory: URL?
    ) {
        self.model = model
        self.audienceState = audienceState
        self.surfaces = surfaces.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        self.artifactDirectory = artifactDirectory
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
        let state = model.overlayStateForTesting
        var lanes: [String: [String]] = [:]

        // Overlay: history rows the view laid out, then the live caption rows.
        let historyByID = Dictionary(
            (state?.history ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let visibleHistory = (model.renderedCaptionStatesForTesting.last?.historyEntryIDs ?? [])
            .compactMap { historyByID[$0] }
        let overlayLive = state?.liveCaptionPresentation.displayCaption
        lanes["overlay.source"] = visibleHistory.map(\.sourceText)
            + Self.rows(overlayLive?.sourceText)
        lanes["overlay.translated"] = visibleHistory.map(\.translatedText)
            + Self.rows(overlayLive?.translatedText)

        // Audience: exactly the caption its view renders.
        let audienceLive = audienceState.liveCaptionPresentation.audienceDisplayCaption
        lanes["audience.source"] = Self.rows(audienceLive?.sourceText)
        lanes["audience.translated"] = Self.rows(audienceLive?.translatedText)
        let audienceSourceRows = Self.rows(audienceLive?.sourceText)
        let audienceTranslatedRows = Self.rows(audienceLive?.translatedText)
        let audiencePairs = (0..<max(audienceSourceRows.count, audienceTranslatedRows.count)).map { row in
            CaptionFrame.AudiencePair(
                source: row < audienceSourceRows.count ? audienceSourceRows[row] : "",
                translated: row < audienceTranslatedRows.count ? audienceTranslatedRows[row] : ""
            )
        }
        lanes = lanes.mapValues { $0.filter { CaptionFlickerOracle.normalized($0).isEmpty == false } }

        var bitmaps: [String: NSBitmapImageRep] = [:]
        var ink: [String: InkProfile] = [:]
        for surface in surfaces {
            guard let bitmap = Self.capture(surface.view) else { continue }
            bitmaps[surface.name] = bitmap
            ink[surface.name] = Self.inkProfile(bitmap)
        }

        let signature = FrameSignature(lanes: lanes, ink: ink, audiencePairs: audiencePairs)
        guard signature != lastSignature else { return }
        lastSignature = signature

        let index = frames.count
        frames.append(
            CaptionFrame(
                index: index,
                time: time,
                lanes: lanes,
                hasDraft: state?.draftSourceText?.isEmpty == false,
                ink: ink,
                audiencePairs: audiencePairs,
                modelSummary: Self.summary(state)
            )
        )
        if artifactDirectory != nil {
            images[index] = bitmaps
        }
    }

    private static func summary(_ state: OverlayPreviewState?) -> String {
        guard let state else { return "no state" }
        func short(_ id: UUID?) -> String { id.map { String($0.uuidString.prefix(4)) } ?? "-" }
        return "committed=\(short(state.committedPromotionID))[\(state.sourceText)|\(state.translatedText)] "
            + "draft=\(short(state.draftPromotionID))[\(state.draftSourceText ?? "")|\(state.draftTranslatedText ?? "")] "
            + "history=\(state.history.count)"
    }

    private static func rows(_ text: String?) -> [String] {
        (text ?? "").split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// Draws the committed layer tree at 1x without forcing layout, so a pending
    /// SwiftUI update scheduled for the next turn stays pending.
    private static func capture(_ view: NSView) -> NSBitmapImageRep? {
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

    /// Rows containing bright caption ink, merged into bands. Brightness is the
    /// max RGB channel; the black host background and dim chrome stay below it.
    private static func inkProfile(_ bitmap: NSBitmapImageRep) -> InkProfile {
        guard let data = bitmap.bitmapData else { return InkProfile(bands: []) }
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        let bytesPerRow = bitmap.bytesPerRow
        let threshold: UInt8 = 90
        var rowInk = [Int](repeating: 0, count: height)
        for y in 0..<height {
            let row = data + y * bytesPerRow
            var count = 0
            for x in 0..<width {
                let pixel = row + x * 4
                if max(pixel[0], max(pixel[1], pixel[2])) > threshold {
                    count += 1
                }
            }
            rowInk[y] = count
        }
        var bands: [InkProfile.Band] = []
        var bandStart: Int?
        var bandInk = 0
        for y in 0...height {
            let ink = y < height ? rowInk[y] : 0
            if ink > 0 {
                if bandStart == nil { bandStart = y; bandInk = 0 }
                bandInk += ink
            } else if let start = bandStart {
                bands.append(InkProfile.Band(rows: start...(y - 1), ink: bandInk))
                bandStart = nil
            }
        }
        return InkProfile(bands: bands)
    }

    func writeArtifacts(flickers: [CaptionFlicker]) throws {
        guard let artifactDirectory else { return }
        let manager = FileManager.default
        try? manager.removeItem(at: artifactDirectory)
        try manager.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)

        var trace = ""
        for frame in frames {
            let duration = frame.index + 1 < frames.count
                ? frames[frame.index + 1].time - frame.time
                : 0
            let ink = frame.ink.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value.bands.count)b/\($0.value.totalInk)" }
                .joined(separator: " ")
            trace += String(
                format: "#%04d t=%7.3f dur=%5.0fms draft=%@ ink=%@\n",
                frame.index, frame.time, duration * 1000, frame.hasDraft ? "y" : "n", ink
            )
            trace += "    model: \(frame.modelSummary)\n"
            for lane in frame.lanes.keys.sorted() {
                trace += "    \(lane): " + (frame.lanes[lane] ?? []).map { "[\($0)]" }.joined(separator: " ") + "\n"
            }
        }
        try trace.write(to: artifactDirectory.appendingPathComponent("frames.txt"), atomically: true, encoding: .utf8)
        try flickers.map(\.description).joined(separator: "\n")
            .write(to: artifactDirectory.appendingPathComponent("flickers.txt"), atomically: true, encoding: .utf8)

        let framesDirectory = artifactDirectory.appendingPathComponent("frames", isDirectory: true)
        try manager.createDirectory(at: framesDirectory, withIntermediateDirectories: true)
        for (index, bitmaps) in images {
            for (surface, bitmap) in bitmaps {
                guard let png = bitmap.representation(using: .png, properties: [:]) else { continue }
                try png.write(to: framesDirectory.appendingPathComponent(String(format: "%04d-%@.png", index, surface)))
            }
        }
    }
}

// MARK: - Oracle

/// Test-owned definition of caption flicker over committed frames. It shares no
/// classifier with production. A state that reached the render server counts no
/// matter how briefly it lived: the display may latch any of them.
enum CaptionFlickerOracle {
    /// Partial evidence (a fragment of a row coming back) counts as a blink only
    /// inside this window. A row whose whole text comes back is a blink at any gap:
    /// history and the audience never bring an evicted row back.
    static let blinkWindow: TimeInterval = 1.0
    /// Rows shorter than this (after normalization) are too generic to identify
    /// an utterance across a long gap or by suffix.
    static let identityMinimum = 4

    static func flickers(in frames: [CaptionFrame], script: String? = nil) -> [CaptionFlicker] {
        let lanes = Set(frames.flatMap(\.lanes.keys)).sorted()
        var result: [CaptionFlicker] = []
        for lane in lanes {
            result += vanishes(lane: lane, frames: frames)
            result += retractions(lane: lane, frames: frames)
            result += duplicates(lane: lane, frames: frames)
        }
        let surfaces = Set(frames.flatMap(\.ink.keys)).sorted()
        for surface in surfaces {
            result += inkBlinks(surface: surface, frames: frames)
        }
        if let script {
            let index = ScriptIndex(script: script)
            for lane in lanes where lane.hasSuffix(".source") {
                result += outOfOrder(lane: lane, frames: frames, script: index)
            }
        }
        result += orphanTranslations(in: frames)
        return result.sorted { ($0.startTime, $0.surface) < ($1.startTime, $1.surface) }
    }

    /// Letters and digits only, lowercased: punctuation, spacing and case
    /// revisions do not make a different utterance.
    static func normalized(_ text: String) -> String {
        String(
            String.UnicodeScalarView(
                text.lowercased().unicodeScalars.filter {
                    CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
                }
            )
        )
    }

    /// One row continues or revises the other: after normalization one is a
    /// prefix of the other, or (for rows of at least `identityMinimum`
    /// characters) a suffix, as when a fragment row returns merged behind its
    /// predecessor. Arbitrary containment is not identity: short CJK words recur
    /// inside unrelated sentences.
    static func sameUtterance(_ lhs: String, _ rhs: String) -> Bool {
        let a = normalized(lhs)
        let b = normalized(rhs)
        guard min(a.count, b.count) >= 2 else { return a == b && a.isEmpty == false }
        if a.hasPrefix(b) || b.hasPrefix(a) { return true }
        let (shorter, longer) = a.count <= b.count ? (a, b) : (b, a)
        return shorter.count >= identityMinimum && longer.hasSuffix(shorter)
    }

    /// `row` comes back whole inside `candidate`: as its prefix or its suffix.
    static func returnsWhole(_ row: String, in candidate: String) -> Bool {
        let lost = normalized(row)
        let back = normalized(candidate)
        guard lost.count >= identityMinimum else { return false }
        return back.hasPrefix(lost) || back.hasSuffix(lost)
    }

    private static func rows(_ frame: CaptionFrame, _ lane: String) -> [String] {
        frame.lanes[lane] ?? []
    }

    private static func contains(_ rows: [String], utteranceOf row: String) -> Bool {
        rows.contains { sameUtterance($0, row) }
    }

    /// A row's utterance leaves the lane and comes back: its fragment within the
    /// blink window, or its whole text at any later frame.
    private static func vanishes(lane: String, frames: [CaptionFrame]) -> [CaptionFlicker] {
        var result: [CaptionFlicker] = []
        guard frames.count > 2 else { return result }
        for index in 1..<frames.count {
            for row in rows(frames[index - 1], lane)
            where contains(rows(frames[index], lane), utteranceOf: row) == false {
                let back = ((index + 1)..<frames.count).first { later in
                    let laterRows = rows(frames[later], lane)
                    if laterRows.contains(where: { returnsWhole(row, in: $0) }) { return true }
                    return frames[later].time - frames[index].time < blinkWindow
                        && contains(laterRows, utteranceOf: row)
                }
                guard let back else { continue }
                result.append(
                    CaptionFlicker(
                        kind: .vanish,
                        surface: lane,
                        startTime: frames[index].time,
                        duration: frames[back].time - frames[index].time,
                        detail: "frames #\(index)..#\(back - 1) lost [\(row)]; back in #\(back)"
                    )
                )
            }
        }
        return result
    }

    /// A row shrinks to a strict prefix of itself and regrows to at least its
    /// earlier text within the blink window. A genuine revision replaces the tail
    /// with different words and is not flagged.
    private static func retractions(lane: String, frames: [CaptionFrame]) -> [CaptionFlicker] {
        var result: [CaptionFlicker] = []
        guard frames.count > 2 else { return result }
        for index in 1..<frames.count {
            for row in rows(frames[index - 1], lane) {
                let full = normalized(row)
                guard let shrunk = rows(frames[index], lane)
                    .map(normalized)
                    .first(where: { $0.count < full.count && full.hasPrefix($0) && $0.count >= 2 }),
                      rows(frames[index], lane).contains(where: { normalized($0).hasPrefix(full) }) == false else {
                    continue
                }
                var end = index + 1
                while end < frames.count,
                      frames[end].time - frames[index].time < blinkWindow,
                      rows(frames[end], lane).contains(where: { normalized($0).hasPrefix(full) }) == false {
                    end += 1
                }
                guard end < frames.count,
                      frames[end].time - frames[index].time < blinkWindow else { continue }
                result.append(
                    CaptionFlicker(
                        kind: .retract,
                        surface: lane,
                        startTime: frames[index].time,
                        duration: frames[end].time - frames[index].time,
                        detail: "frames #\(index)..#\(end - 1) [\(row)] cut to \(shrunk.count)/\(full.count) chars; restored in #\(end)"
                    )
                )
            }
        }
        return result
    }

    /// Two rows of one lane carry the same utterance. Contiguous frames with the
    /// same pair are one incident.
    private static func duplicates(lane: String, frames: [CaptionFrame]) -> [CaptionFlicker] {
        incidents(kind: .duplicateRow, surface: lane, frames: frames) { frame in
            let laneRows = rows(frame, lane)
            for i in laneRows.indices {
                for j in laneRows.indices where j > i && sameUtterance(laneRows[i], laneRows[j]) {
                    return "[\(laneRows[i])] ~ [\(laneRows[j])]"
                }
            }
            return nil
        }
    }

    /// The audience pairs every translation with its source; a translation row
    /// beside an empty source row belongs to nothing on screen.
    private static func orphanTranslations(in frames: [CaptionFrame]) -> [CaptionFlicker] {
        incidents(kind: .orphanTranslation, surface: "audience", frames: frames) { frame in
            frame.audiencePairs.first {
                normalized($0.source).isEmpty && normalized($0.translated).isEmpty == false
            }.map { "translation [\($0.translated)] has no source row" }
        }
    }

    /// Rows must read in spoken order, and the newest row must never fall back to
    /// an utterance older than one already shown. Rows are placed in the script by
    /// their longest unambiguous run of words; rows too short or too generic to
    /// place are skipped.
    private static func outOfOrder(
        lane: String,
        frames: [CaptionFrame],
        script: ScriptIndex
    ) -> [CaptionFlicker] {
        var newestShown = -1
        return incidents(kind: .outOfOrder, surface: lane, frames: frames) { frame in
            let placed = rows(frame, lane).compactMap { row in
                script.place(row).map { (row: row, span: $0) }
            }
            var violation: String?
            for (earlier, later) in zip(placed, placed.dropFirst())
            where later.span.lowerBound < earlier.span.lowerBound {
                violation = "row [\(later.row)] (sentence \(later.span.lowerBound)) below [\(earlier.row)] (sentence \(earlier.span.lowerBound))"
                break
            }
            if let newest = placed.last {
                if violation == nil, newest.span.upperBound < newestShown {
                    violation = "newest row [\(newest.row)] is sentence \(newest.span.upperBound) after sentence \(newestShown) was shown"
                }
                newestShown = max(newestShown, newest.span.upperBound)
            }
            return violation
        }
    }

    /// Contiguous frames for which `violation` holds, reported once each.
    private static func incidents(
        kind: CaptionFlicker.Kind,
        surface: String,
        frames: [CaptionFrame],
        violation: (CaptionFrame) -> String?
    ) -> [CaptionFlicker] {
        var result: [CaptionFlicker] = []
        var open: (start: Int, detail: String)?
        func close(at end: Int) {
            guard let incident = open else { return }
            let endTime = end < frames.count ? frames[end].time : frames[end - 1].time
            result.append(
                CaptionFlicker(
                    kind: kind,
                    surface: surface,
                    startTime: frames[incident.start].time,
                    duration: endTime - frames[incident.start].time,
                    detail: "frames #\(incident.start)..#\(end - 1) \(incident.detail)"
                )
            )
            open = nil
        }
        for (index, frame) in frames.enumerated() {
            if let detail = violation(frame) {
                if open == nil { open = (index, detail) }
            } else {
                close(at: index)
            }
        }
        close(at: frames.count)
        return result
    }

    /// The painted ink of a surface collapses and recovers within the blink
    /// window while its rows keep the same utterances: a paint-only blank the
    /// model-level lanes cannot see.
    private static func inkBlinks(surface: String, frames: [CaptionFrame]) -> [CaptionFlicker] {
        var result: [CaptionFlicker] = []
        let inks = frames.map { $0.ink[surface]?.totalInk ?? 0 }
        let laneNames = Set(frames.flatMap(\.lanes.keys)).filter { $0.hasPrefix(surface + ".") }
        var index = 1
        while index < frames.count {
            let before = inks[index - 1]
            guard before > 0, Double(inks[index]) < Double(before) * 0.4 else {
                index += 1
                continue
            }
            var end = index
            while end < frames.count, Double(inks[end]) < Double(before) * 0.4 { end += 1 }
            defer { index = max(end, index + 1) }
            guard end < frames.count,
                  Double(inks[end]) >= Double(before) * 0.8,
                  frames[end].time - frames[index].time < blinkWindow else { continue }
            let unchanged = laneNames.allSatisfy { lane in
                rows(frames[end], lane).allSatisfy {
                    contains(rows(frames[index - 1], lane), utteranceOf: $0)
                }
            }
            guard unchanged else { continue }
            result.append(
                CaptionFlicker(
                    kind: .inkBlink,
                    surface: surface,
                    startTime: frames[index].time,
                    duration: frames[end].time - frames[index].time,
                    detail: "frames #\(index)..#\(end - 1) ink \(before)→\(inks[index])→\(inks[end])"
                )
            )
        }
        return result
    }
}

/// Places caption rows in the scripted talk.
struct ScriptIndex {
    /// Script words (Latin words, digits, single Han characters) in spoken order.
    let tokens: [String]
    /// `sentenceOf[i]` is the sentence number of `tokens[i]`.
    let sentenceOf: [Int]
    /// Shortest word run that places a row.
    static let minimumRun = 3

    init(script: String) {
        let sentences = CaptionCoverage.sentences(of: script)
        tokens = sentences.flatMap(CaptionCoverage.tokens)
        sentenceOf = sentences.enumerated().flatMap { index, sentence in
            Array(repeating: index, count: CaptionCoverage.tokens(sentence).count)
        }
    }

    /// The sentences a row's longest common word run spans, or nil when that run
    /// is shorter than `minimumRun` or occurs at more than one place.
    func place(_ row: String) -> ClosedRange<Int>? {
        let words = CaptionCoverage.tokens(row)
        guard words.count >= Self.minimumRun, tokens.isEmpty == false else { return nil }
        var previous = [Int](repeating: 0, count: tokens.count + 1)
        var best = 0
        var ends: [Int] = []
        for word in words {
            var current = [Int](repeating: 0, count: tokens.count + 1)
            for (j, token) in tokens.enumerated() where token == word {
                current[j + 1] = previous[j] + 1
                if current[j + 1] > best {
                    best = current[j + 1]
                    ends = [j]
                } else if current[j + 1] == best {
                    ends.append(j)
                }
            }
            previous = current
        }
        guard best >= Self.minimumRun, Set(ends).count == 1, let end = ends.first else { return nil }
        return sentenceOf[end - best + 1]...sentenceOf[end]
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
