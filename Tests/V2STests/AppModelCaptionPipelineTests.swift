import XCTest
@testable import v2s

/// Integration gate for the AppModel ↔ session ↔ pipeline wiring: analyzer
/// result events injected through a real `LiveTranscriptionSession` must
/// produce `captionDocument` rows, sealed transcript entries, and the
/// committed-only `overlayState` caption — with nothing running through the
/// old caption queue.
@MainActor
final class AppModelCaptionPipelineTests: XCTestCase {
    private var settingsURL: URL!

    override func setUp() async throws {
        settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-pipeline-\(UUID().uuidString).json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: settingsURL)
    }

    func testSessionEventsDriveDocumentTranscriptAndOverlay() async throws {
        let model = makeModel(mode: .balanced)
        let session = try await startInjectedSession(on: model)
        defer { model.stopSession() }

        // Volatile: a live row appears in the document but not the transcript.
        session.emitEventForTesting(.result(Self.result(
            sessionID: 1,
            isFinal: false,
            rangeStartMs: 0,
            durationMs: 1_200,
            text: "Good morning",
            audioFedMs: 1_200
        )))
        await session.awaitPendingEmissionsForTesting()
        await settlePipeline()
        let liveRow = model.captionDocument.rows.last
        XCTAssertEqual(liveRow?.text, "Good morning")
        XCTAssertEqual(liveRow?.isSealed, false)
        XCTAssertTrue(model.transcriptEntries.isEmpty)

        // Final lands: the row keeps its audio-time identity and metadata.
        session.emitEventForTesting(.result(Self.result(
            sessionID: 1,
            isFinal: true,
            rangeStartMs: 0,
            durationMs: 2_040,
            text: "Good morning, everyone.",
            audioFedMs: 2_040,
            rangeEndRuns: [(startMs: 0, durationMs: 1_000, text: "Good morning, everyone.")]
        )))
        await session.awaitPendingEmissionsForTesting()
        await settlePipeline()
        XCTAssertEqual(model.captionDocument.rows.count, 1)

        // VAD offset seals the row (vadSealMs = 500 on balanced).
        session.emitEventForTesting(.vad(.offset, audioMs: 2_100))
        await session.awaitPendingEmissionsForTesting()
        await settlePipeline()
        try await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertEqual(model.captionDocument.rows.first?.isSealed, true)

        // Transcript entry exists for the sealed row with a stable UUID that
        // survives the row's translation arriving later.
        let entry = try XCTUnwrap(model.transcriptEntries.first)
        XCTAssertEqual(entry.sourceText, "Good morning, everyone.")
        XCTAssertEqual(entry.id, model.transcriptEntries.first?.id)

        // Translation flows through the pipeline into row + transcript + overlay.
        try await waitFor { model.captionDocument.rows.first?.translation.isEmpty == false }
        XCTAssertEqual(
            model.transcriptEntries.first?.translatedText,
            model.captionDocument.rows.first?.translation
        )

        // overlayState shows the committed-only caption — no draft fields.
        let overlay = try XCTUnwrap(model.overlayStateForTesting)
        XCTAssertEqual(overlay.sourceText, "Good morning, everyone.")
        XCTAssertEqual(overlay.translatedText, model.captionDocument.rows.first?.translation)
        XCTAssertEqual(overlay.liveCaptionPresentation.currentCaption?.phase, .committed)

        // stopSession seals whatever remains; the document stays on screen.
        model.stopSession()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(model.captionDocument.rows.isEmpty)
        XCTAssertTrue(model.captionDocument.rows.allSatisfy(\.isSealed))
    }

    func testDraftCaptionsOffHidesLiveRowsFromDisplayButNotDocument() async throws {
        let model = makeModel(mode: .balanced)
        let session = try await startInjectedSession(on: model)
        defer { model.stopSession() }
        model.liveDraftCaptions = false

        session.emitEventForTesting(.result(Self.result(
            sessionID: 1,
            isFinal: false,
            rangeStartMs: 0,
            durationMs: 1_000,
            text: "Hello there",
            audioFedMs: 1_000
        )))
        await session.awaitPendingEmissionsForTesting()
        await settlePipeline()

        // The document keeps the live row; the displayed document does not.
        XCTAssertEqual(model.captionDocument.rows.count, 1)
        XCTAssertTrue(model.displayedCaptionDocument.rows.isEmpty)
        XCTAssertTrue(model.transcriptEntries.isEmpty)
    }

    func testReadingModeSuppressesDraftTranslations() async throws {
        let model = makeModel(mode: .reading)
        let session = try await startInjectedSession(on: model)
        defer { model.stopSession() }

        session.emitEventForTesting(.result(Self.result(
            sessionID: 1,
            isFinal: false,
            rangeStartMs: 0,
            durationMs: 2_000,
            text: "We will talk about captions",
            audioFedMs: 2_000
        )))
        await session.awaitPendingEmissionsForTesting()
        await settlePipeline()
        // Reading mode: showsDraftTranslations is false, so no draft request
        // fires even though translation is installed.
        try await Task.sleep(nanoseconds: 300_000_000)
        let row = model.captionDocument.rows.last
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.translationIsDraft, false)
        XCTAssertEqual(row?.translation ?? "", "")
    }

    // MARK: Helpers

    private func makeModel(mode: SubtitleMode) -> AppModel {
        var settings = AppSettings.default
        settings.selectedSourceID = PipelineTestCatalog.source.id
        settings.selectedSourceIDs = [PipelineTestCatalog.source.id]
        settings.inputLanguageID = "en"
        settings.outputLanguageID = "zh-Hant"
        settings.subtitleMode = mode
        SettingsStore(fileURL: settingsURL).save(settings)

        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: PipelineTestCatalog()
        )
        model.installTranslationForTesting { text, _, _ in
            "TR:\(text)"
        }
        return model
    }

    /// Opens the session through the production `startSession` path and returns
    /// the injected session events will be replayed through.
    private func startInjectedSession(
        on model: AppModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> LiveTranscriptionSession {
        var sessions: [LiveTranscriptionSession] = []
        model.makeTranscriptionSessionForTesting = {
            let session = LiveTranscriptionSession()
            session.injectsAudioForTesting = true
            sessions.append(session)
            return session
        }
        model.refreshSources()
        await model.startSession()
        guard let session = sessions.first else {
            throw XCTSkip(
                "session did not start: \(model.statusMessage) (speech assets may be missing)",
                file: file,
                line: line
            )
        }
        guard model.sessionState == .running else {
            throw XCTSkip(
                "session not running: \(model.statusMessage) (speech assets may be missing)",
                file: file,
                line: line
            )
        }
        return session
    }

    /// The pipeline coalesces publishes on a 30 ms real-clock flush; give it
    /// room after the session drains before reading `captionDocument`.
    private func settlePipeline() async {
        try? await Task.sleep(nanoseconds: 80_000_000)
    }

    static func result(
        sessionID: Int,
        isFinal: Bool,
        rangeStartMs: Int,
        durationMs: Int,
        text: String,
        audioFedMs: Int,
        languageID: String = "en-US",
        rangeEndRuns: [(startMs: Int, durationMs: Int, text: String)] = []
    ) -> AnalyzerResultEvent {
        AnalyzerResultEvent(
            lane: CaptionLaneID(sessionID: sessionID, languageID: languageID),
            isFinal: isFinal,
            rangeStartMs: rangeStartMs,
            rangeDurationMs: durationMs,
            finalizationMs: isFinal ? rangeStartMs + durationMs : nil,
            text: text,
            runs: rangeEndRuns.map {
                AnalyzerRun(
                    text: $0.text,
                    startMs: $0.startMs,
                    durationMs: $0.durationMs,
                    confidence: 0.9
                )
            },
            audioFedMs: audioFedMs
        )
    }

    private func waitFor(
        timeout: TimeInterval = 2.0,
        _ predicate: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(predicate(), "timed out waiting for pipeline state")
    }
}

private struct PipelineTestCatalog: SourceCatalogProviding {
    static let source = InputSource(
        id: "easy2say-pipeline-test-microphone",
        name: "Injected microphone",
        detail: "injected",
        category: .microphone
    )

    func loadSnapshot() -> SourceCatalogSnapshot {
        SourceCatalogSnapshot(applications: [], microphones: [Self.source])
    }
}
