#if os(macOS)
import AppKit
#endif
import AVFoundation
#if os(macOS)
import CoreAudio
#endif
import CoreMedia
import Foundation
import Speech
#if canImport(WhisperKit)
import WhisperKit
#endif


final class LiveTranscriptionSession: NSObject, @unchecked Sendable {
    enum LegacyRecognitionErrorDisposition: Equatable {
        case ignore
        case restartImmediately
        case retryWithBackoff
        case stopAndSurface
    }

    /// Decides what to do about a legacy recognition-task error.
    ///
    /// `message` is the error's localized description. Code 203 is a bucket Apple uses
    /// for unrelated failures — the transient "Retry"/"Corrupt" faults that a restart
    /// clears, and the server quota rejection that no amount of retrying clears — so
    /// only the quota text earns a hard stop.
    static func legacyRecognitionErrorDisposition(
        domain: String,
        code: Int,
        message: String = ""
    ) -> LegacyRecognitionErrorDisposition {
        guard domain == "kAFAssistantErrorDomain" else {
            return .retryWithBackoff
        }

        if message.range(of: "quota", options: .caseInsensitive) != nil {
            return .stopAndSurface
        }

        switch code {
        case 216, 301:
            return .ignore
        case 1110:
            return .restartImmediately
        default:
            return .retryWithBackoff
        }
    }


#if os(macOS)
    private struct ApplicationCaptureDescriptor: Sendable {
        let appName: String
        let processObjectIDs: [AudioObjectID]
        let readStreamFailureMessage: String
    }
#endif


    private struct AudioLevelStats {
        let peak: Float
        let rms: Float
    }

    private enum RecognitionBackend {
        case legacy
        case speechAnalyzer
#if canImport(WhisperKit)
        case localTaigi
#if os(macOS)
        case localTibetan
#endif
#endif
    }

    enum SessionError: LocalizedError, AppLocalizableError {
        case speechPermissionDenied
        case microphonePermissionDenied
        case audioCapturePermissionDenied
        case unsupportedSpeechLocale(String)
        case unavailableSpeechRecognizer(String)
        case missingMicrophoneDevice
        case missingApplication(String)
        case applicationNotProducingAudio(String)
        case failedToStartCapture(String)

        func localizedDescription(languageID: String) -> String {
            switch self {
            case .speechPermissionDenied:
                return AppLocalization.string(.speechPermissionDenied, languageID: languageID)
            case .microphonePermissionDenied:
                return AppLocalization.string(.microphonePermissionDenied, languageID: languageID)
            case .audioCapturePermissionDenied:
                return AppLocalization.string(.appAudioCapturePermissionDenied, languageID: languageID)
            case .unsupportedSpeechLocale(let localeIdentifier):
                return AppLocalization.string(.unsupportedSpeechLocaleFormat, languageID: languageID, localeIdentifier)
            case .unavailableSpeechRecognizer(let localeIdentifier):
                return AppLocalization.string(.unavailableSpeechRecognizerFormat, languageID: languageID, localeIdentifier)
            case .missingMicrophoneDevice:
                return AppLocalization.string(.missingMicrophoneDevice, languageID: languageID)
            case .missingApplication(let appName):
                return AppLocalization.string(.missingApplicationFormat, languageID: languageID, appName)
            case .applicationNotProducingAudio(let appName):
                return AppLocalization.string(.applicationNotProducingAudioFormat, languageID: languageID, appName)
            case .failedToStartCapture(let reason):
                return AppLocalization.string(.failedToStartCaptureFormat, languageID: languageID, reason)
            }
        }

        var errorDescription: String? {
            localizedDescription(languageID: "en")
        }
    }

    private let captureQueue = DispatchQueue(label: "com.franklioxygen.v2s.capture", qos: .userInitiated)
    private let processingFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    /// Guards async startup (notably multi-minute first-load model specialization)
    /// against a concurrent Stop. Accessed only on captureQueue.
    private var lifecycleGeneration = 0
    private var startupCancelled = false
    /// Incremented on every restart. Handlers capture their generation at creation time
    /// and discard callbacks that arrive after a newer generation has started.
    private var recognitionGeneration: Int = 0
    /// Consecutive recognition-task failures since the last delivered result. Restarting
    /// immediately recovers from a one-off fault, but a persistent one — an evicted
    /// on-device asset, an unreachable backend — would otherwise spin the task in a hot
    /// loop, so retries are spaced out and eventually surfaced instead of hidden.
    private var consecutiveRecognitionFailures = 0
    private var lastRecognitionFailureTime = Date.distantPast
    private var pendingRecognitionRestart: DispatchWorkItem?
    /// Delay before the Nth consecutive retry. The first stays immediate so ordinary
    /// hiccups still recover without a visible gap.
    private let recognitionRestartBackoff: [TimeInterval] = [0, 0.5, 1.5, 3, 5]
    /// Failures spaced further apart than this are unrelated, not a failing recognizer.
    private let recognitionFailureWindow: TimeInterval = 60
    private var preprocessingConverter: AVAudioConverter?
    private var preprocessingConverterInputSignature: AudioFormatSignature?
    private var audioConverter: AVAudioConverter?
    private var audioConverterInputSignature: AudioFormatSignature?
    private var modernAudioConverter: AVAudioConverter?
    private var modernAudioConverterInputSignature: AudioFormatSignature?
    private var primaryRecognitionContextualStrings: [String] = []
    private var secondaryRecognitionContextualStrings: [String] = []
    private var recognitionContextualStrings: [String] = []
    private var recognitionBackend: RecognitionBackend = .legacy
    private var activeLocaleIdentifier: String?
    private var configuredSourceLanguageID = ""
    private var configuredTargetLanguageID = ""
    private var interfaceLanguageID = "en"
    private var modernAnalyzerTask: Task<Void, Never>?
    private var analyzerFinalizeTask: Task<Void, Never>?
    private var analyzerResultTasks: [Task<Void, Never>] = []
    private var speechAnalyzerState: AnyObject?
    private var speechTranscriberState: AnyObject?
    private var analyzerInputContinuationState: Any?
    private var analyzerInputFormat: AVAudioFormat?
    private var secondarySpeechTranscriberState: AnyObject?
    /// Analyzer's first-buffer position on the session audio clock, ms.
    private var analyzerOriginAudioMs: Int?
    /// Session audio clock position of the last buffer yielded to the analyzer.
    private var lastAnalyzerFedAudioMs = 0
    /// Legacy request start on the session audio clock, ms.
    private var legacyRequestOriginAudioMs: Int?
    private let presentationWorkLock = NSLock()
    private var presentationWorkTail: Task<Void, Never>?

    @discardableResult
    private func appendPresentationWork(_ work: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        presentationWorkLock.lock()
        let predecessor = presentationWorkTail
        let task = Task { @MainActor in
            await predecessor?.value
            work()
        }
        presentationWorkTail = task
        presentationWorkLock.unlock()
        return task
    }

    private func enqueuePresentationWork(_ work: @escaping @MainActor () -> Void) {
        _ = appendPresentationWork(work)
    }

    /// Ordered delivery: every event crosses the main actor through this
    /// chain, so the handler sees results and VAD edges in capture order.
    private func emitEvent(_ event: CaptionSessionEvent) {
        enqueuePresentationWork { [weak self] in
#if DEBUG
            self?.emittedEventsForTesting.append(event)
#endif
            self?.eventHandler?(event)
        }
    }



    func awaitPendingEmissionsForTesting() async {
        await appendPresentationWork({}).value
    }
#if canImport(WhisperKit)
    private var taigiEngine: TaigiASREngine?
#if os(macOS)
    private var tibetanEngine: TibetanASREngine?
#endif
    private var usesLocalWhisperRecognizer: Bool {
        switch recognitionBackend {
        case .localTaigi:
            return true
#if os(macOS)
        case .localTibetan:
            return true
#endif
        default:
            return false
        }
    }

    private var localASRPreRoll: [Float] = []
    private var localASRSegment: [Float] = []
    private var localASRSpeechActive = false
    /// Session-clock ms of the first sample in `localASRSegment`.
    private var localASRSegmentStartAudioMs: Double?
    private var localASRPendingSegments: [(audio: [Float], startAudioMs: Double)] = []
    private var localASRTranscriptionTask: Task<Void, Never>?
    private let localASRPreRollSampleCount = 4_800  // 300 ms at 16 kHz
    private let localASRMinimumSegmentSampleCount = 4_000
    private let localASRMaximumSegmentSampleCount = 240_000  // 15 seconds
#endif

    // MARK: - Live speaker diarization

    /// Streaming Sortformer diarizer fed the same 16 kHz mono buffers as the
    /// recognizer. Created in `start()` when the speaker-labels setting is on
    /// and the bundled model exists; never nilled on stop (stale reads are
    /// benign — lookups just return nil).
    private var diarizationEngine: LiveDiarizationEngine?
    /// Session audio clock: ms of processed 16 kHz audio since the session's
    /// first buffer. All event timestamps use this clock.
    private var audioProcessedMs = 0.0
    /// Capture-time seconds of the last buffer handed to the diarizer.
    private var lastBufferStartCaptureSeconds: Double?
    /// Capture-time seconds of the first buffer the SpeechAnalyzer saw. The
    /// analyzer's `audioTimeRange`s are relative to its own stream start; this
    /// origin converts them onto the diarizer's capture-time axis.
    private var analyzerOriginCaptureSeconds: Double?
    /// Capture-time seconds at which the current legacy recognition request
    /// began. Legacy `SFTranscriptionSegment` timestamps are request-relative.
    private var legacyRequestOriginCaptureSeconds: Double?

    private var microphoneCaptureSession: AVCaptureSession?
#if os(macOS)
    private var applicationAudioCapture: ApplicationAudioCapture?
#endif

    private var eventHandler: (@MainActor (CaptionSessionEvent) -> Void)?
#if DEBUG
    /// Every event this session emitted, in order — for e2e diagnosis.
    private(set) var emittedEventsForTesting: [CaptionSessionEvent] = []
#endif
    private var captionSessionID = 0
    private var errorHandler: (@MainActor (String) -> Void)?
    /// Reports an unrecoverable recognition failure after this session has stopped.
    /// The owner uses this separate callback to stop sibling sessions as well.
    private var fatalErrorHandler: (@MainActor (String) -> Void)?

    private func localized(_ key: AppTextKey, _ arguments: CVarArg...) -> String {
        AppLocalization.formattedString(key, languageID: interfaceLanguageID, arguments: arguments)
    }

    private func localizedErrorDescription(_ error: Error) -> String {
        AppLocalization.localizedErrorDescription(error, languageID: interfaceLanguageID)
    }



    // MARK: Silero VAD (captureQueue)
    private var vadEngine: SileroVADEngine?
    private var legacyVADEndAudioTimer: DispatchSourceTimer?
    private var noiseFloorRMS: Float = 0.0012
    private var highPassPreviousInput: Float = 0.0
    private var highPassPreviousOutput: Float = 0.0

    private func runOnCaptureQueue<T>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            captureQueue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }


    func start(
        source: InputSource,
        localeIdentifier: String,
        interfaceLanguageID: String,
        contextualStrings: [String] = [],
        secondaryContextualStrings: [String] = [],
        sourceLanguageID: String = "",
        targetLanguageID: String = "",
        speakerDiarizationEnabled: Bool = false,
        captionSessionID: Int = 0,
        eventHandler: @escaping @MainActor (CaptionSessionEvent) -> Void,
        errorHandler: @escaping @MainActor (String) -> Void,
        fatalErrorHandler: @escaping @MainActor (String) -> Void
    ) async throws {
        self.eventHandler = eventHandler
        self.captionSessionID = captionSessionID
        self.primaryRecognitionContextualStrings = sanitizeContextualStrings(contextualStrings)
        self.secondaryRecognitionContextualStrings = sanitizeContextualStrings(secondaryContextualStrings)
        self.recognitionContextualStrings = self.primaryRecognitionContextualStrings
        self.activeLocaleIdentifier = localeIdentifier
        self.configuredSourceLanguageID = sourceLanguageID
        self.configuredTargetLanguageID = targetLanguageID
        self.interfaceLanguageID = interfaceLanguageID
        self.errorHandler = errorHandler
        self.fatalErrorHandler = fatalErrorHandler
        if speakerDiarizationEnabled, LiveDiarizationEngine.isModelBundled {
            let engine = LiveDiarizationEngine()
            diarizationEngine = engine
            engine.start()
        } else {
            diarizationEngine = nil
        }
        lastBufferStartCaptureSeconds = nil
        analyzerOriginCaptureSeconds = nil
        legacyRequestOriginCaptureSeconds = nil
        audioProcessedMs = 0
        analyzerOriginAudioMs = nil
        lastAnalyzerFedAudioMs = 0
        legacyRequestOriginAudioMs = nil
        let startGeneration: Int = try await runOnCaptureQueue {
            self.lifecycleGeneration &+= 1
            self.startupCancelled = false
            return self.lifecycleGeneration
        }
        try await ensureStartupIsCurrent(startGeneration)

        let usesLocalTaigi = localeIdentifier.lowercased().hasPrefix("nan")
#if os(macOS) && canImport(WhisperKit)
        let usesLocalTibetan = localeIdentifier.lowercased().hasPrefix("bo")
#else
        let usesLocalTibetan = false
#endif
#if DEBUG
        let usesInjectedAudio = injectsAudioForTesting
#else
        let usesInjectedAudio = false
#endif
        if usesInjectedAudio == false {
            try await requestRequiredPermissions(
                for: source,
                requiresSpeechAuthorization:
                    usesLocalTaigi == false && usesLocalTibetan == false
            )
        }
        try await ensureStartupIsCurrent(startGeneration)
#if canImport(WhisperKit)
        if usesLocalTaigi {
            let engine = try await TaigiASREngine.load()
            try await ensureStartupIsCurrent(startGeneration)
            try await runOnCaptureQueue {
                try self.configureLocalTaigiRecognizer(engine)
            }
        }
#if os(macOS)
        if usesLocalTibetan {
            let engine = try await TibetanASREngine.load()
            try await ensureStartupIsCurrent(startGeneration)
            try await runOnCaptureQueue {
                try self.configureLocalTibetanRecognizer(engine)
            }
        }
#endif
        if usesLocalTaigi == false, usesLocalTibetan == false {
            let configuredModern = try await configureModernSpeechRecognizer(
                localeIdentifier: localeIdentifier
            )
            try await ensureStartupIsCurrent(startGeneration)
            if configuredModern == false {
                try await runOnCaptureQueue {
                    try self.configureSpeechRecognizer(localeIdentifier: localeIdentifier)
                }
            }
        }
#else
        let configuredModern = try await configureModernSpeechRecognizer(
            localeIdentifier: localeIdentifier
        )
        try await ensureStartupIsCurrent(startGeneration)
        if configuredModern == false {
            try await runOnCaptureQueue {
                try self.configureSpeechRecognizer(localeIdentifier: localeIdentifier)
            }
        }
#endif

        guard usesInjectedAudio == false else {
            try await ensureStartupIsCurrent(startGeneration)
            return
        }

        switch source.category {
        case .microphone:
            try await runOnCaptureQueue {
                try self.startMicrophoneCapture(deviceUniqueID: source.detail)
            }
        case .application:
#if os(macOS)
            let captureDescriptor = try await MainActor.run {
                try self.makeApplicationCaptureDescriptor(for: source)
            }
            try await ensureStartupIsCurrent(startGeneration)
            try await runOnCaptureQueue {
                try self.startApplicationAudioCapture(descriptor: captureDescriptor)
            }
#else
            throw SessionError.missingApplication(source.name)
#endif
        }
        try await ensureStartupIsCurrent(startGeneration)
    }

    private func ensureStartupIsCurrent(_ generation: Int) async throws {
        try await runOnCaptureQueue {
            guard self.startupCancelled == false,
                  self.lifecycleGeneration == generation else {
                throw CancellationError()
            }
        }
    }

    func stop() {
        // Keep the session alive until every capture resource has been released. The
        // owner drops its references immediately after calling this method.
        captureQueue.async { [self] in
            stopOnCaptureQueue()
        }
    }

    /// Stops the session, waits (at most 2 s) for analyzer result streams to
    /// drain, and returns only after the ordered presentation queue has
    /// delivered every remaining event.
    func stopAndWait() async {
        let resultTasks: [Task<Void, Never>] = (try? await runOnCaptureQueue {
            self.stopOnCaptureQueue()
            return self.analyzerResultTasks
        }) ?? []

        if resultTasks.isEmpty == false {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for task in resultTasks { await task.value }
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
                _ = await group.next()
                group.cancelAll()
            }
        }

        // Every result event the streams produced was enqueued on the capture
        // queue; one final hop then finishes the modern teardown.
        try? await runOnCaptureQueue {
            self.finishModernTeardown()
        }
        // The ordered presentation queue now holds every remaining event.
        await appendPresentationWork({}).value
    }

    private func stopOnCaptureQueue() {
        startupCancelled = true
        lifecycleGeneration &+= 1
        cancelLegacyVADEndAudioTimer()

#if os(iOS)
        let hadMicrophoneCaptureSession = microphoneCaptureSession != nil
#endif
        microphoneCaptureSession?.stopRunning()
        microphoneCaptureSession = nil
#if os(iOS)
        if hadMicrophoneCaptureSession {
            do {
                try AVAudioSession.sharedInstance().setActive(
                    false,
                    options: .notifyOthersOnDeactivation
                )
            } catch {
                let message = localizedErrorDescription(error)
                Task {
                    await emitError(message)
                }
            }
        }
#endif

#if os(macOS)
        applicationAudioCapture?.stop()
        applicationAudioCapture = nil
#endif

        finishModernInputAndFinalize()
        diarizationEngine?.stop()
        lastBufferStartCaptureSeconds = nil
        analyzerOriginCaptureSeconds = nil
        legacyRequestOriginCaptureSeconds = nil
        resetRecognitionFailureState()
        recognitionGeneration &+= 1
#if canImport(WhisperKit)
        localASRTranscriptionTask?.cancel()
        localASRTranscriptionTask = nil
        taigiEngine = nil
#if os(macOS)
        tibetanEngine = nil
#endif
        localASRPreRoll.removeAll(keepingCapacity: false)
        localASRSegment.removeAll(keepingCapacity: false)
        localASRPendingSegments.removeAll()
        localASRSpeechActive = false
#endif
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        speechRecognizer = nil
        activeLocaleIdentifier = nil
        resetAudioProcessingState()

        vadEngine = nil
        audioProcessedMs = 0
        analyzerOriginAudioMs = nil
        lastAnalyzerFedAudioMs = 0
        legacyRequestOriginAudioMs = nil
    }

    private func requestRequiredPermissions(
        for source: InputSource,
        requiresSpeechAuthorization: Bool = true
    ) async throws {
        if requiresSpeechAuthorization {
            let speechStatus = SFSpeechRecognizer.authorizationStatus()

            switch speechStatus {
            case .authorized:
                break
            case .notDetermined:
                let granted = await requestSpeechAuthorization()
                guard granted else {
                    throw SessionError.speechPermissionDenied
                }
            case .denied, .restricted:
                throw SessionError.speechPermissionDenied
            @unknown default:
                throw SessionError.speechPermissionDenied
            }
        }

        switch source.category {
        case .microphone:
            let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)

            switch microphoneStatus {
            case .authorized:
                break
            case .notDetermined:
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                guard granted else {
                    throw SessionError.microphonePermissionDenied
                }
            case .denied, .restricted:
                throw SessionError.microphonePermissionDenied
            @unknown default:
                throw SessionError.microphonePermissionDenied
            }
        case .application:
            break
        }
    }

#if canImport(WhisperKit)
    private func configureLocalTaigiRecognizer(_ engine: TaigiASREngine) throws {
        stopModernSpeechRecognizer()
        speechRecognizer = nil
        recognitionRequest = nil
        recognitionTask = nil
        recognitionBackend = .localTaigi
        taigiEngine = engine
#if os(macOS)
        tibetanEngine = nil
#endif
        localASRPreRoll.removeAll(keepingCapacity: true)
        localASRSegment.removeAll(keepingCapacity: true)
        localASRPendingSegments.removeAll()
        localASRSpeechActive = false
        resetRecognitionFailureState()
        resetAudioProcessingState()
        vadEngine = try SileroVADEngine()
    }
#endif
#if os(macOS) && canImport(WhisperKit)
    private func configureLocalTibetanRecognizer(
        _ engine: TibetanASREngine
    ) throws {
        stopModernSpeechRecognizer()
        speechRecognizer = nil
        recognitionRequest = nil
        recognitionTask = nil
        recognitionBackend = .localTibetan
        tibetanEngine = engine
        taigiEngine = nil
        localASRPreRoll.removeAll(keepingCapacity: true)
        localASRSegment.removeAll(keepingCapacity: true)
        localASRPendingSegments.removeAll()
        localASRSpeechActive = false
        resetRecognitionFailureState()
        resetAudioProcessingState()
        vadEngine = try SileroVADEngine()
    }
#endif

    private func configureSpeechRecognizer(localeIdentifier: String) throws {
        stopModernSpeechRecognizer()
        let locale = Locale(identifier: localeIdentifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw SessionError.unsupportedSpeechLocale(localeIdentifier)
        }

        guard recognizer.isAvailable else {
            throw SessionError.unavailableSpeechRecognizer(localeIdentifier)
        }

        let request = makeRecognitionRequest(
            requiresOnDeviceRecognition: recognizer.supportsOnDeviceRecognition
        )

        let task = recognizer.recognitionTask(with: request, resultHandler: makeRecognitionHandler())

        speechRecognizer = recognizer
        recognitionRequest = request
        recognitionTask = task
        recognitionBackend = .legacy
        // Segment timestamps in this task's results are relative to the first
        // appended buffer; nil marks the origin pending until that append.
        legacyRequestOriginCaptureSeconds = nil
        resetRecognitionFailureState()
        resetAudioProcessingState()

        // Initialize Silero VAD engine.
        do {
            vadEngine = try SileroVADEngine()
        } catch {
            // VAD is optional — fall back to implicit ASR-based silence detection.
            vadEngine = nil
            Task {
                await emitError(
                    localized(
                        .sileroVadUnavailableFallbackFormat,
                        localizedErrorDescription(error)
                    )
                )
            }
        }
    }

    /// Resolves `requestedLocale` to a locale the modern Speech stack actually carries.
    ///
    /// `SpeechTranscriber.supportedLocale(equivalentTo:)` answers with an equivalent
    /// locale even for languages the stack does not support at all — `ru-RU` resolves
    /// to `ru_RU` on a Mac whose supported list holds no Russian — so its answer only
    /// counts when it appears in `supportedLocales`. Without this check the modern path
    /// is entered for languages only the legacy recognizer can serve.
    @available(iOS 26.0, macOS 26.0, *)
    static func modernSpeechLocale(equivalentTo requestedLocale: Locale) async -> Locale? {
        guard SpeechTranscriber.isAvailable,
              let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            return nil
        }

        let supportedIdentifiers = await Set(SpeechTranscriber.supportedLocales.map(\.identifier))
        return supportedIdentifiers.contains(resolved.identifier) ? resolved : nil
    }

    private func configureModernSpeechRecognizer(localeIdentifier: String) async throws -> Bool {
        guard #available(iOS 26.0, macOS 26.0, *), SpeechTranscriber.isAvailable else {
            return false
        }

        do {
            return try await configureSpeechAnalyzerRecognizer(localeIdentifier: localeIdentifier)
        } catch {
            stopModernSpeechRecognizer()
            return false
        }
    }

    @available(iOS 26.0, macOS 26.0, *)
    private func configureSpeechAnalyzerRecognizer(localeIdentifier: String) async throws -> Bool {
        let requestedLocale = Locale(identifier: localeIdentifier)
        guard let resolvedLocale = await Self.modernSpeechLocale(equivalentTo: requestedLocale) else {
            return false
        }

        let primaryTranscriber = SpeechTranscriber(
            locale: resolvedLocale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )

        var transcribers: [SpeechTranscriber] = [primaryTranscriber]
        var secondaryTranscriber: SpeechTranscriber?
        var resolvedEnglishLocale: Locale?
        let wantsDualLane = CaptionLanguagePolicy.shouldEnableDualLane(
            sourceLanguageID: configuredSourceLanguageID,
            targetLanguageID: configuredTargetLanguageID
        )
        if wantsDualLane {
            let englishLocale = Locale(
                identifier: LanguageCatalog.speechLocaleIdentifier(for: "en")
            )
            if let resolvedEnglish = await Self.modernSpeechLocale(equivalentTo: englishLocale) {
                let englishTranscriber = SpeechTranscriber(
                    locale: resolvedEnglish,
                    transcriptionOptions: [],
                    reportingOptions: [.volatileResults, .fastResults],
                    attributeOptions: [.audioTimeRange, .transcriptionConfidence]
                )
                transcribers.append(englishTranscriber)
                secondaryTranscriber = englishTranscriber
                resolvedEnglishLocale = resolvedEnglish
            }
        }

        if let secondaryTranscriber, let resolvedEnglishLocale {
            try await ConversationLane.installAssetsIfNeeded(
                for: [
                    (transcriber: primaryTranscriber, locale: resolvedLocale),
                    (transcriber: secondaryTranscriber, locale: resolvedEnglishLocale),
                ]
            )
        } else {
            try await ensureSpeechAnalyzerAssetsIfNeeded(for: primaryTranscriber, locale: resolvedLocale)
        }

        let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .whileInUse)
        let analyzer = SpeechAnalyzer(modules: transcribers, options: options)
        let context = AnalysisContext()
        if secondaryTranscriber != nil {
            // Shared context in dual-lane mode is restricted to Latin-only
            // phrases so neither transcriber is biased toward one script.
            let sharedNeutral = sanitizeContextualStrings(
                primaryRecognitionContextualStrings + secondaryRecognitionContextualStrings
            ).filter { CaptionLanguagePolicy.classifyHeardScript($0) == .entirelyLatin }
            if sharedNeutral.isEmpty == false {
                context.contextualStrings[.general] = sharedNeutral
            }
        } else if primaryRecognitionContextualStrings.isEmpty == false {
            context.contextualStrings[.general] = primaryRecognitionContextualStrings
        }
        try await analyzer.setContext(context)

        let preferredFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: transcribers,
            considering: processingFormat
        ) ?? processingFormat
        try await analyzer.prepareToAnalyze(in: preferredFormat)

        let inputStream = AsyncStream<AnalyzerInput>(bufferingPolicy: .bufferingNewest(12)) { continuation in
            self.analyzerInputContinuationState = continuation
        }

        analyzerResultTasks.forEach { $0.cancel() }
        var resultTasks: [Task<Void, Never>] = []
        resultTasks.append(Task { [weak self] in
            do {
                for try await result in primaryTranscriber.results {
                    self?.captureQueue.async { [weak self] in
                        self?.processAnalyzerResult(
                            result,
                            languageID: self?.configuredSourceLanguageID ?? "en"
                        )
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                self?.fallbackFromSpeechAnalyzer(error)
            }
        })
        if let secondaryTranscriber {
            resultTasks.append(Task { [weak self] in
                do {
                    for try await result in secondaryTranscriber.results {
                        self?.captureQueue.async { [weak self] in
                            self?.processAnalyzerResult(result, languageID: "en")
                        }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    self?.fallbackFromSpeechAnalyzer(error)
                }
            })
        }
        analyzerResultTasks = resultTasks

        modernAnalyzerTask?.cancel()
        modernAnalyzerTask = Task { [weak self] in
            do {
                try await analyzer.start(inputSequence: inputStream)
            } catch is CancellationError {
                return
            } catch {
                self?.fallbackFromSpeechAnalyzer(error)
            }
        }

        speechAnalyzerState = analyzer
        speechTranscriberState = primaryTranscriber
        secondarySpeechTranscriberState = secondaryTranscriber
        analyzerInputFormat = preferredFormat
        analyzerOriginAudioMs = nil
        recognitionBackend = .speechAnalyzer
        recognitionRequest = nil
        recognitionTask = nil
        speechRecognizer = nil
        audioConverter = nil
        audioConverterInputSignature = nil
        cancelLegacyVADEndAudioTimer()

        do {
            vadEngine = try SileroVADEngine()
        } catch {
            vadEngine = nil
        }

        return true
    }

    @available(iOS 26.0, macOS 26.0, *)
    private func ensureSpeechAnalyzerAssetsIfNeeded(
        for transcriber: SpeechTranscriber,
        locale: Locale
    ) async throws {
        let installedLocales = await Set(SpeechTranscriber.installedLocales.map(\.identifier))
        if installedLocales.contains(locale.identifier) {
            return
        }

        if let installer = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installer.downloadAndInstall()
        }
    }

    private func stopModernSpeechRecognizer() {
        modernAnalyzerTask?.cancel()
        modernAnalyzerTask = nil
        analyzerFinalizeTask?.cancel()
        analyzerFinalizeTask = nil
        analyzerResultTasks.forEach { $0.cancel() }
        analyzerResultTasks.removeAll()
        recognitionBackend = .legacy
        modernAudioConverter = nil
        modernAudioConverterInputSignature = nil

        if #available(iOS 26.0, macOS 26.0, *) {
            (analyzerInputContinuationState as? AsyncStream<AnalyzerInput>.Continuation)?.finish()
            analyzerInputContinuationState = nil
            let analyzer = speechAnalyzerState as? SpeechAnalyzer
            speechAnalyzerState = nil
            speechTranscriberState = nil
            secondarySpeechTranscriberState = nil
            analyzerInputFormat = nil

            if let analyzer {
                Task {
                    await analyzer.cancelAndFinishNow()
                }
            }
        }
    }

    /// Graceful stop path (spec §1): finish the input stream so the analyzer
    /// finalizes through end of input; result streams then end on their own
    /// and `stopAndWait()` collects what they emit.
    private func finishModernInputAndFinalize() {
        if #available(iOS 26.0, macOS 26.0, *) {
            (analyzerInputContinuationState as? AsyncStream<AnalyzerInput>.Continuation)?.finish()
            analyzerInputContinuationState = nil
            if let analyzer = speechAnalyzerState as? SpeechAnalyzer {
                analyzerFinalizeTask = Task {
                    try? await analyzer.finalizeAndFinishThroughEndOfInput()
                }
            } else {
                speechAnalyzerState = nil
            }
        }
        recognitionBackend = .legacy
    }

    /// Drops the modern backend's state after its result streams drained (or
    /// the wait timed out). Called on captureQueue from `stopAndWait`.
    private func finishModernTeardown() {
        modernAnalyzerTask?.cancel()
        modernAnalyzerTask = nil
        analyzerFinalizeTask?.cancel()
        analyzerFinalizeTask = nil
        analyzerResultTasks.forEach { $0.cancel() }
        analyzerResultTasks.removeAll()
        modernAudioConverter = nil
        modernAudioConverterInputSignature = nil
        speechAnalyzerState = nil
        speechTranscriberState = nil
        secondarySpeechTranscriberState = nil
        analyzerInputFormat = nil
    }

    private func fallbackFromSpeechAnalyzer(_ error: Error) {
        captureQueue.async { [weak self] in
            guard let self,
                  self.recognitionBackend == .speechAnalyzer,
                  let localeIdentifier = self.activeLocaleIdentifier else {
                return
            }

            self.stopModernSpeechRecognizer()

            do {
                try self.configureSpeechRecognizer(localeIdentifier: localeIdentifier)
            } catch {
                self.stopRecognitionAndSurface(error)
            }
        }
    }

    /// Builds a recognition request, keeping recognition on device wherever the
    /// recognizer has a local model. Languages without one — Chinese on Intel, say —
    /// are only served by Apple's speech service, and refusing that would leave them
    /// with no recognition at all.
    private func makeRecognitionRequest(
        requiresOnDeviceRecognition: Bool
    ) -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = requiresOnDeviceRecognition
        request.contextualStrings = recognitionContextualStrings
        return request
    }

    private func sanitizeContextualStrings(_ candidates: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()

        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false,
                  trimmed.count <= SpeechCorrectionService.maximumRecognitionPhraseLength else {
                continue
            }

            let normalized = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard seen.insert(normalized).inserted else {
                continue
            }

            result.append(trimmed)
            if result.count >= SpeechCorrectionService.maximumRecognitionPhrases {
                break
            }
        }

        return result
    }

    private func resetAudioProcessingState() {
        preprocessingConverter = nil
        preprocessingConverterInputSignature = nil
        audioConverter = nil
        audioConverterInputSignature = nil
        modernAudioConverter = nil
        modernAudioConverterInputSignature = nil
        noiseFloorRMS = 0.0012
        highPassPreviousInput = 0
        highPassPreviousOutput = 0
    }



    private func startMicrophoneCapture(deviceUniqueID: String) throws {
        guard let device = AVCaptureDevice(uniqueID: deviceUniqueID) else {
            throw SessionError.missingMicrophoneDevice
        }

        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()

        guard session.canAddInput(input) else {
            throw SessionError.failedToStartCapture(
                localized(.couldNotAddSelectedMicrophoneToCaptureSession)
            )
        }

        guard session.canAddOutput(output) else {
            throw SessionError.failedToStartCapture(
                localized(.couldNotAddMicrophoneAudioOutput)
            )
        }

        session.beginConfiguration()
        session.addInput(input)
        output.setSampleBufferDelegate(self, queue: captureQueue)
        session.addOutput(output)
        session.commitConfiguration()

#if os(iOS)
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement)
            try audioSession.setActive(true)
        } catch {
            let message = localizedErrorDescription(error)
            Task {
                await emitError(message)
            }
        }
#endif
        microphoneCaptureSession = session
        session.startRunning()
    }

#if os(macOS)
    @MainActor
    private func makeApplicationCaptureDescriptor(for source: InputSource) throws -> ApplicationCaptureDescriptor {
        ApplicationCaptureDescriptor(
            appName: source.name,
            processObjectIDs: try resolveApplicationProcessObjectIDs(for: source),
            readStreamFailureMessage: localized(.failedToReadCapturedAudioStreamFormat, source.name)
        )
    }

    private func startApplicationAudioCapture(descriptor: ApplicationCaptureDescriptor) throws {
        let capture = ApplicationAudioCapture(
            appName: descriptor.appName,
            processObjectIDs: descriptor.processObjectIDs,
            readStreamFailureMessage: descriptor.readStreamFailureMessage,
            queue: captureQueue,
            audioHandler: { [weak self] buffer in
                self?.append(audioBuffer: buffer)
            },
            errorHandler: { [weak self] message in
                Task {
                    await self?.emitError(message)
                }
            }
        )

        do {
            try capture.start()
            applicationAudioCapture = capture
        } catch let error as ApplicationAudioCapture.CaptureError {
            throw mapApplicationCaptureError(error)
        } catch {
            throw SessionError.failedToStartCapture(
                localized(
                    .failedToStageWithReasonFormat,
                    "start application audio capture",
                    localizedErrorDescription(error)
                )
            )
        }
    }

    private func resolveApplicationProcessObjectIDs(for source: InputSource) throws -> [AudioObjectID] {
        let runningApp = try resolveRunningApplication(for: source)
        let system = AudioHardwareSystem.shared
        let audioProcesses = try system.processes
        let targetAssociation = ApplicationProcessAssociation(runningApplication: runningApp)
        var relatedProcessIDs: [AudioObjectID] = []
        var seen = Set<AudioObjectID>()

        for process in audioProcesses {
            let processID = try process.pid
            let processObjectID = process.id
            let processBundleIdentifier = (try? process.bundleID) ?? ""
            let processAppBundleURL = applicationBundleURL(forProcessID: processID)
            let executablePath = executablePath(forProcessID: processID)

            let matchesMainProcess = processID == runningApp.processIdentifier
            let matchesBundleIdentifier = targetAssociation.matchesExactBundleIdentifier(processBundleIdentifier)
            let matchesBundleURL = targetAssociation.matchesApplicationBundleURL(processAppBundleURL)
            let matchesHelperBundle = targetAssociation.matchesHelperBundleIdentifier(processBundleIdentifier)
            let matchesHelperPath = targetAssociation.matchesHelperExecutablePath(executablePath)

            guard matchesMainProcess
                || matchesBundleIdentifier
                || matchesBundleURL
                || matchesHelperBundle
                || matchesHelperPath else {
                    continue
                }

            if seen.insert(processObjectID).inserted {
                relatedProcessIDs.append(processObjectID)
            }
        }

        if relatedProcessIDs.isEmpty {
            if let exactProcess = try system.process(for: runningApp.processIdentifier) {
                return [exactProcess.id]
            }

            throw SessionError.applicationNotProducingAudio(source.name)
        }

        return relatedProcessIDs
    }

    private func resolveRunningApplication(for source: InputSource) throws -> NSRunningApplication {
        let runningApps = NSWorkspace.shared.runningApplications
        let application: NSRunningApplication?

        if let processIdentifier = source.processIdentifierHint {
            application = runningApps.first(where: { $0.processIdentifier == processIdentifier })
        } else {
            application = runningApps.first(where: { $0.bundleIdentifier == source.detail })
        }

        guard let application else {
            throw SessionError.missingApplication(source.name)
        }

        return application
    }
#endif

    private func append(sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }

        // Convert to PCMBuffer so gain processing can be applied (same path as app audio).
        // Fall back to direct append if conversion fails.
        if let pcmBuffer = pcmBuffer(from: sampleBuffer) {
            append(audioBuffer: pcmBuffer)
        } else if recognitionBackend == .legacy {
            recognitionRequest?.appendAudioSampleBuffer(sampleBuffer)
        }
    }

    /// Converts a CMSampleBuffer from AVCaptureSession into an AVAudioPCMBuffer so it can
    /// share the format-conversion and gain-boost pipeline in append(audioBuffer:).
    private func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }

        var mutableASBD = asbd.pointee
        guard let format = AVAudioFormat(streamDescription: &mutableASBD) else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }

        pcm.frameLength = AVAudioFrameCount(frameCount)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frameCount), into: pcm.mutableAudioBufferList
        )
        return status == noErr ? pcm : nil
    }

    private func append(audioBuffer: AVAudioPCMBuffer) {
        guard audioBuffer.frameLength > 0 else {
            return
        }

        guard let processingBuffer = prepareProcessingBuffer(from: audioBuffer) else {
            return
        }

        let audioLevels = cleanUpSpeechBuffer(processingBuffer)
        boostIfQuiet(buffer: processingBuffer, levels: audioLevels)

        // Advance the session audio clock: ms of processed 16 kHz audio since
        // the session's first buffer. VAD edges below use this buffer's end.
        audioProcessedMs += Double(processingBuffer.frameLength) / 16_000 * 1_000
        let bufferEndAudioMs = Int(audioProcessedMs.rounded())

        // Feed the diarizer the same 16 kHz mono stream the recognizer hears and
        // remember where this buffer sits on the capture-time axis.
        lastBufferStartCaptureSeconds = diarizationEngine?.append(audioBuffer: processingBuffer)

        var currentVADResult: VADResult?
        if let vadEngine {
            let vadResult = vadEngine.process(buffer: processingBuffer)
            currentVADResult = vadResult
            // One buffer can carry offset-then-onset (end of one utterance and
            // the start of the next); forward them in that order.
            if vadResult.containsSpeechOffset {
                emitEvent(.vad(.offset, audioMs: bufferEndAudioMs))
                if recognitionBackend == .legacy {
                    scheduleLegacyVADEndAudio()
                }
            }
            if vadResult.containsSpeechOnset {
                emitEvent(.vad(.onset, audioMs: bufferEndAudioMs))
                cancelLegacyVADEndAudioTimer()
            }
        }

#if canImport(WhisperKit)
        if usesLocalWhisperRecognizer {
            appendToLocalWhisper(processingBuffer, vadResult: currentVADResult)
            return
        }
#endif

        if recognitionBackend == .speechAnalyzer {
            appendToSpeechAnalyzer(processingBuffer)
            return
        }

        guard let recognitionRequest else {
            return
        }

        guard let recognizerBuffer = makeRecognizerBuffer(from: processingBuffer, nativeFormat: recognitionRequest.nativeAudioFormat) else {
            return
        }

        // Always forward audio to the recognizer — VAD only schedules
        // endAudio() after sustained silence, it never gates the stream.
        if legacyRequestOriginCaptureSeconds == nil {
            legacyRequestOriginCaptureSeconds = lastBufferStartCaptureSeconds
        }
        if legacyRequestOriginAudioMs == nil {
            legacyRequestOriginAudioMs = Int((audioProcessedMs - Double(processingBuffer.frameLength) / 16_000 * 1_000).rounded())
        }
        recognitionRequest.append(recognizerBuffer)
    }

    private func appendToSpeechAnalyzer(_ processingBuffer: AVAudioPCMBuffer) {
        guard #available(macOS 26.0, *),
              recognitionBackend == .speechAnalyzer,
              let continuation = analyzerInputContinuationState as? AsyncStream<AnalyzerInput>.Continuation else {
            return
        }

        guard let analyzerBuffer = makeSpeechAnalyzerBuffer(from: processingBuffer) else {
            return
        }

        // The analyzer's audioTimeRanges start at the first buffer it receives;
        // pin that origin to capture time so emissions can be diarized.
        if analyzerOriginCaptureSeconds == nil {
            analyzerOriginCaptureSeconds = lastBufferStartCaptureSeconds
        }
        // Same origin on the session audio clock (normally 0 — the analyzer
        // sees every buffer from the session's first one).
        if analyzerOriginAudioMs == nil {
            analyzerOriginAudioMs = Int((audioProcessedMs - Double(processingBuffer.frameLength) / 16_000 * 1_000).rounded())
        }

        continuation.yield(AnalyzerInput(buffer: analyzerBuffer))
        lastAnalyzerFedAudioMs = Int(audioProcessedMs.rounded())
    }

#if canImport(WhisperKit)
    private func appendToLocalWhisper(
        _ processingBuffer: AVAudioPCMBuffer,
        vadResult: VADResult?
    ) {
        guard let channel = processingBuffer.floatChannelData?[0] else { return }
        let samples = Array(
            UnsafeBufferPointer(
                start: channel,
                count: Int(processingBuffer.frameLength)
            )
        )
        guard samples.isEmpty == false else { return }

        let startsSpeech = localASRSpeechActive == false
            && (vadResult?.containsSpeechOnset == true || vadResult?.isSpeech == true)
        if startsSpeech {
            localASRSpeechActive = true
            // The segment opens with the pre-roll, so its session-clock start
            // is this buffer's end minus the buffered audio's duration.
            let bufferedSeconds = (Double(localASRPreRoll.count) + Double(samples.count)) / 16_000
            localASRSegmentStartAudioMs = audioProcessedMs - bufferedSeconds * 1_000
            localASRSegment = localASRPreRoll
            localASRPreRoll.removeAll(keepingCapacity: true)
        }

        if localASRSpeechActive {
            localASRSegment.append(contentsOf: samples)
        } else {
            localASRPreRoll.append(contentsOf: samples)
            if localASRPreRoll.count > localASRPreRollSampleCount {
                localASRPreRoll.removeFirst(
                    localASRPreRoll.count - localASRPreRollSampleCount
                )
            }
        }

        let endsSpeech = vadResult?.containsSpeechOffset == true
        let reachesMaximum = localASRSegment.count >= localASRMaximumSegmentSampleCount
        guard localASRSpeechActive, endsSpeech || reachesMaximum else { return }

        enqueueLocalASRSegment(
            localASRSegment,
            startAudioMs: localASRSegmentStartAudioMs
        )
        localASRSegment.removeAll(keepingCapacity: true)
        localASRSegmentStartAudioMs = nil
        if endsSpeech, vadResult?.isSpeech == true {
            // One capture buffer can contain offset then a new onset. Preserve the
            // ambiguous buffer as pre-roll for the new segment rather than dropping
            // the newly-started utterance.
            localASRSpeechActive = true
            localASRSegment = samples
            localASRSegmentStartAudioMs = audioProcessedMs - Double(samples.count) / 16_000 * 1_000
        } else {
            localASRSpeechActive = endsSpeech == false
        }
        if localASRSpeechActive == false {
            localASRPreRoll.removeAll(keepingCapacity: true)
        }
    }

    private func enqueueLocalASRSegment(_ audio: [Float], startAudioMs: Double?) {
        guard audio.count >= localASRMinimumSegmentSampleCount else { return }
        localASRPendingSegments.append((
            audio: audio,
            startAudioMs: startAudioMs ?? audioProcessedMs
        ))
        startNextLocalASRTranscriptionIfNeeded()
    }


    private func startNextLocalASRTranscriptionIfNeeded() {
        guard localASRTranscriptionTask == nil,
              localASRPendingSegments.isEmpty == false else {
            return
        }

        let transcribe: @Sendable ([Float]) async throws -> String
        switch recognitionBackend {
        case .localTaigi:
            guard let engine = taigiEngine else { return }
            transcribe = { audio in
                try await engine.transcribe(audio)
            }
#if os(macOS)
        case .localTibetan:
            guard let engine = tibetanEngine else { return }
            transcribe = { audio in
                try await engine.transcribe(audio)
            }
#endif
        default:
            return
        }

        let pending = localASRPendingSegments.removeFirst()
        let generation = recognitionGeneration
        localASRTranscriptionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.captureQueue.async { [weak self] in
                    guard let self, self.recognitionGeneration == generation else {
                        return
                    }
                    self.localASRTranscriptionTask = nil
                    self.startNextLocalASRTranscriptionIfNeeded()
                }
            }

            do {
                let text = try await transcribe(pending.audio)
                guard Task.isCancelled == false else { return }
                let segmentAudioMs = Double(pending.audio.count) / 16_000 * 1_000
                let segmentRange = CMTimeRange(
                    start: CMTime(seconds: pending.startAudioMs / 1_000, preferredTimescale: 1000),
                    duration: CMTime(seconds: segmentAudioMs / 1_000, preferredTimescale: 1000)
                )
                self.captureQueue.async { [weak self] in
                    guard let self, self.recognitionGeneration == generation else { return }
                    self.emitEvent(.result(AnalyzerResultEvent(
                        lane: CaptionLaneID(
                            sessionID: self.captionSessionID,
                            languageID: self.configuredSourceLanguageID
                        ),
                        isFinal: true,
                        rangeStartMs: Int(pending.startAudioMs.rounded()),
                        rangeDurationMs: Int(segmentAudioMs.rounded()),
                        finalizationMs: nil,
                        text: text.replacingOccurrences(of: "\n", with: " "),
                        runs: [],
                        audioFedMs: Int(self.audioProcessedMs.rounded()),
                        speakerIndex: self.speakerIndex(for: segmentRange)
                    )))
                }
            } catch is CancellationError {
                return
            } catch {
                if Self.isEmptyLocalTranscriptError(error) {
                    // False VAD onset or breath/noise: skip this slice and keep listening.
                    return
                }
                let message = self.localizedErrorDescription(error)
                await self.emitFatalError(message)
            }
        }
    }

    private static func isEmptyLocalTranscriptError(_ error: Error) -> Bool {
        if let engineError = error as? TaigiASREngine.EngineError,
           case .emptyTranscript = engineError {
            return true
        }
#if os(macOS)
        if let engineError = error as? TibetanASREngine.EngineError,
           case .emptyTranscript = engineError {
            return true
        }
#endif
        return false
    }
#endif

    private func prepareProcessingBuffer(from audioBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if audioBuffer.format.matches(processingFormat) {
            guard let copiedBuffer = copyPCMBuffer(audioBuffer) else {
                Task {
                    await emitError(localized(.failedToCopyCapturedAudioForSpeechPreprocessing))
                }
                return nil
            }
            return copiedBuffer
        }

        let inputSignature = AudioFormatSignature(audioBuffer.format)
        if preprocessingConverterInputSignature != inputSignature {
            preprocessingConverter = AVAudioConverter(from: audioBuffer.format, to: processingFormat)
            preprocessingConverterInputSignature = inputSignature
        }

        guard let preprocessingConverter else {
            Task {
                await emitError(localized(.failedToPrepareSpeechPreprocessingAudioConverter))
            }
            return nil
        }

        return convertBuffer(
            audioBuffer,
            using: preprocessingConverter,
            to: processingFormat,
            allocationError: localized(.failedToAllocateSpeechPreprocessingAudioBuffer),
            failurePrefix: localized(.failedToPreprocessCapturedAudio)
        )
    }

    private func makeRecognizerBuffer(
        from processingBuffer: AVAudioPCMBuffer,
        nativeFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        if processingBuffer.format.matches(nativeFormat) {
            return processingBuffer
        }

        let inputSignature = AudioFormatSignature(processingBuffer.format)
        if audioConverterInputSignature != inputSignature {
            audioConverter = AVAudioConverter(from: processingBuffer.format, to: nativeFormat)
            audioConverterInputSignature = inputSignature
        }

        guard let audioConverter else {
            Task {
                await emitError(localized(.failedToPrepareAudioConverterForSpeechRecognition))
            }
            return nil
        }

        return convertBuffer(
            processingBuffer,
            using: audioConverter,
            to: nativeFormat,
            allocationError: localized(.failedToAllocateSpeechRecognitionAudioBuffer),
            failurePrefix: localized(.failedToConvertCapturedAudioForSpeechRecognition)
        )
    }

    private func makeSpeechAnalyzerBuffer(from processingBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard #available(macOS 26.0, *),
              let analyzerInputFormat else {
            return processingBuffer
        }

        if processingBuffer.format.matches(analyzerInputFormat) {
            return processingBuffer
        }

        let inputSignature = AudioFormatSignature(processingBuffer.format)
        if modernAudioConverterInputSignature != inputSignature {
            modernAudioConverter = AVAudioConverter(from: processingBuffer.format, to: analyzerInputFormat)
            modernAudioConverterInputSignature = inputSignature
        }

        guard let modernAudioConverter else {
            return nil
        }

        return convertBuffer(
            processingBuffer,
            using: modernAudioConverter,
            to: analyzerInputFormat,
            allocationError: localized(.failedToAllocateSpeechAnalyzerAudioBuffer),
            failurePrefix: localized(.failedToConvertCapturedAudioForSpeechAnalyzer)
        )
    }

    private func convertBuffer(
        _ inputBuffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to outputFormat: AVAudioFormat,
        allocationError: String,
        failurePrefix: String
    ) -> AVAudioPCMBuffer? {
        let outputFrameCapacity = max(
            AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * outputFormat.sampleRate / inputBuffer.format.sampleRate)),
            1
        )

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) else {
            Task { await emitError(allocationError) }
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

        if let conversionError {
            Task {
                await emitError("\(failurePrefix): \(conversionError.localizedDescription)")
            }
            return nil
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            guard outputBuffer.frameLength > 0 else { return nil }
            return outputBuffer
        case .error:
            Task {
                await emitError("\(failurePrefix).")
            }
            return nil
        @unknown default:
            return nil
        }
    }

    private func copyPCMBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else {
            return nil
        }

        copy.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)

        for (sourceBuffer, destinationBuffer) in zip(sourceBuffers, destinationBuffers) {
            guard let sourceData = sourceBuffer.mData,
                  let destinationData = destinationBuffer.mData else {
                continue
            }

            memcpy(destinationData, sourceData, Int(sourceBuffer.mDataByteSize))
        }

        return copy
    }

    private func cleanUpSpeechBuffer(_ buffer: AVAudioPCMBuffer) -> AudioLevelStats {
        guard let channelData = buffer.floatChannelData else {
            return AudioLevelStats(peak: 0, rms: 0)
        }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else {
            return AudioLevelStats(peak: 0, rms: 0)
        }

        let samples = channelData[0]
        let highPassAlpha: Float = 0.995
        var sumSquares: Float = 0
        var peak: Float = 0

        for index in 0..<frameCount {
            let input = samples[index]
            let filtered = input - highPassPreviousInput + highPassAlpha * highPassPreviousOutput
            highPassPreviousInput = input
            highPassPreviousOutput = filtered
            samples[index] = filtered

            let magnitude = abs(filtered)
            sumSquares += magnitude * magnitude
            if magnitude > peak {
                peak = magnitude
            }
        }

        let rms = sqrt(sumSquares / Float(frameCount))
        updateNoiseFloorEstimate(rms: rms, peak: peak)
        return AudioLevelStats(peak: peak, rms: rms)
    }

    private func updateNoiseFloorEstimate(rms: Float, peak: Float) {
        let clampedRMS = min(max(rms, 0.0003), 0.03)
        let likelyNoiseOnly = peak < 0.02 || rms <= noiseFloorRMS * 1.6
        let smoothing: Float = likelyNoiseOnly ? 0.08 : 0.01
        noiseFloorRMS = max(0.0005, min(0.02, noiseFloorRMS * (1 - smoothing) + clampedRMS * smoothing))
    }

    // MARK: - Audio gain boost

    /// Amplifies a Float32 PCM buffer when the signal is too quiet for the ASR's VAD to
    /// detect reliably. Only applies when the peak is in the "quiet speech" range
    /// (0.002–0.30); leaves silence and normal-to-loud audio untouched.
    ///
    /// - Quiet speech range: peak 0.002 – 0.30 → boost toward target peak 0.35 (up to 4×)
    /// - Silence (< 0.002): no boost (would just amplify noise floor)
    /// - Normal/loud (≥ 0.30): no boost (already loud enough; avoid clipping)
    private func boostIfQuiet(buffer: AVAudioPCMBuffer, levels: AudioLevelStats) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return }

        let peak = levels.peak
        let rms = levels.rms
        let speechFloor = max(0.006, noiseFloorRMS * 4.0)
        let targetPeak: Float = 0.35
        guard peak > speechFloor,
              rms > max(noiseFloorRMS * 1.8, 0.0015),
              peak < targetPeak else {
            return
        }

        let gain = min(targetPeak / peak, 3.0)
        for ch in 0..<channelCount {
            let ptr = channelData[ch]
            for i in 0..<frameCount {
                var v = ptr[i] * gain
                if v > 1.0 { v = 1.0 } else if v < -1.0 { v = -1.0 }
                ptr[i] = v
            }
        }
    }









    @MainActor
    private func emitError(_ message: String) {
        errorHandler?(message)
    }

    @MainActor
    private func emitFatalError(_ message: String) {
        fatalErrorHandler?(message)
    }


    /// Raw forwarding: every transcriber result becomes a `CaptionSessionEvent`
    /// unchanged except newline flattening — segmentation, scoring and commit
    /// policy all live in CaptionCore now.
    @available(iOS 26.0, macOS 26.0, *)
    private func processAnalyzerResult(
        _ result: SpeechTranscriber.Result,
        languageID: String
    ) {
        var runs: [AnalyzerRun] = []
        for run in result.text.runs {
            var runEntry = AnalyzerRun(
                text: String(result.text[run.range].characters),
                startMs: nil,
                durationMs: nil,
                confidence: nil
            )
            if let range = run.audioTimeRange, range.isValid {
                runEntry.startMs = (analyzerOriginAudioMs ?? 0) + cmTimeMilliseconds(range.start)
                runEntry.durationMs = cmTimeMilliseconds(range.duration)
            }
            if let confidence = run.transcriptionConfidence {
                runEntry.confidence = Double(confidence)
            }
            runs.append(runEntry)
        }

        let captureRange = captureTimeRange(from: result.range)
        let event = AnalyzerResultEvent(
            lane: CaptionLaneID(
                sessionID: captionSessionID,
                languageID: languageID
            ),
            isFinal: result.isFinal,
            rangeStartMs: (analyzerOriginAudioMs ?? 0)
                + (result.range.isValid && result.range.start.isNumeric
                    ? cmTimeMilliseconds(result.range.start) : 0),
            rangeDurationMs: result.range.isValid && result.range.duration.isNumeric
                ? cmTimeMilliseconds(result.range.duration) : 0,
            finalizationMs: result.resultsFinalizationTime.isNumeric
                ? (analyzerOriginAudioMs ?? 0)
                    + cmTimeMilliseconds(result.resultsFinalizationTime)
                : nil,
            text: String(result.text.characters)
                .replacingOccurrences(of: "\n", with: " "),
            runs: runs,
            audioFedMs: lastAnalyzerFedAudioMs,
            speakerIndex: result.isFinal ? speakerIndex(for: captureRange) : nil
        )
        emitEvent(.result(event))
    }

    /// Resolves the dominant speaker's display index for a capture-time audio
    /// range. Nil when diarization is off or no segment overlaps.
    private nonisolated func speakerIndex(for audioRange: CMTimeRange?) -> Int? {
        guard let audioRange, audioRange.isValid, audioRange.duration.isNumeric else {
            return nil
        }
        return diarizationEngine?.dominantSpeakerIndex(
            startSeconds: cmTimeSeconds(audioRange.start),
            endSeconds: cmTimeSeconds(audioRange.end)
        )
    }






    private func cmTimeSeconds(_ time: CMTime) -> Double {
        time.isNumeric ? CMTimeGetSeconds(time) : 0
    }

    /// Shifts an analyzer-relative range onto the capture-time axis the
    /// diarizer uses. Identity when the analyzer origin isn't pinned yet.
    private func captureTimeRange(from range: CMTimeRange) -> CMTimeRange {
        guard let origin = analyzerOriginCaptureSeconds, range.isValid else {
            return range
        }
        return CMTimeRange(
            start: CMTime(seconds: cmTimeSeconds(range.start) + origin, preferredTimescale: 1000),
            duration: range.duration
        )
    }






    private func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }















    /// The legacy recognizer emits one volatile hypothesis per partial
    /// callback; a final seals the request's span and the request restarts.
    private func processRecognitionResult(_ result: SFSpeechRecognitionResult) {
        // The recognizer is delivering again — forget any earlier failures.
        consecutiveRecognitionFailures = 0
        let formattedText = result.bestTranscription.formattedString
            .replacingOccurrences(of: "\n", with: " ")
        let originMs = legacyRequestOriginAudioMs ?? Int(audioProcessedMs.rounded())
        let nowMs = Int(audioProcessedMs.rounded())
        emitEvent(.result(AnalyzerResultEvent(
            lane: CaptionLaneID(
                sessionID: captionSessionID,
                languageID: configuredSourceLanguageID
            ),
            isFinal: result.isFinal,
            rangeStartMs: originMs,
            rangeDurationMs: max(nowMs - originMs, 0),
            finalizationMs: nil,
            text: formattedText,
            runs: [],
            audioFedMs: nowMs,
            speakerIndex: result.isFinal
                ? speakerIndex(for: finalAudioRange(
                    firstSegment: result.bestTranscription.segments.first,
                    lastSegment: result.bestTranscription.segments.last
                  ))
                : nil
        )))
        if result.isFinal {
            // The spent request produced its final; start a fresh one so
            // recognition continues across long sessions.
            restartRecognitionTask()
        }
    }

    /// VAD offset on the legacy backend: 1.2 s without an onset ends the
    /// current request's audio so the recognizer emits its final.
    private func scheduleLegacyVADEndAudio() {
        cancelLegacyVADEndAudioTimer()
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now() + .milliseconds(1_200))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.legacyVADEndAudioTimer = nil
            self.recognitionRequest?.endAudio()
        }
        legacyVADEndAudioTimer = timer
        timer.resume()
    }

    private func cancelLegacyVADEndAudioTimer() {
        legacyVADEndAudioTimer?.cancel()
        legacyVADEndAudioTimer = nil
    }

    /// Replaces the spent recognition task with a fresh one so recording continues
    /// indefinitely. Called on captureQueue whenever isFinal is received or on error recovery.
    private func restartRecognitionTask() {
        guard let recognizer = speechRecognizer else { return }

        // A restart from any source supersedes a retry still waiting on its backoff.
        pendingRecognitionRestart?.cancel()
        pendingRecognitionRestart = nil

        // Cleanly end the old request before discarding it.
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        cancelLegacyVADEndAudioTimer()
        vadEngine?.reset()

        // Bump generation BEFORE creating the new handler so any late callbacks
        // dispatched by the cancelled task are silently ignored.
        recognitionGeneration &+= 1

        let request = makeRecognitionRequest(
            requiresOnDeviceRecognition: recognizer.supportsOnDeviceRecognition
        )

        let task = recognizer.recognitionTask(with: request, resultHandler: makeRecognitionHandler())

        recognitionRequest = request
        recognitionTask = task
        // Segment timestamps in this task's results are relative to the first
        // appended buffer; nil marks the origin pending until that append.
        legacyRequestOriginCaptureSeconds = nil
        legacyRequestOriginAudioMs = nil
        // Reset the converter — new request may have a different nativeAudioFormat.
        resetAudioProcessingState()
    }

    private func resetRecognitionFailureState() {
        pendingRecognitionRestart?.cancel()
        pendingRecognitionRestart = nil
        consecutiveRecognitionFailures = 0
        lastRecognitionFailureTime = .distantPast
    }

    /// Recovers from a recognition-task error on captureQueue.
    ///
    /// Retries are spaced by `recognitionRestartBackoff` so a recognizer that fails the
    /// instant it starts cannot loop at full speed. Once the retries are exhausted the
    /// error reaches the UI — otherwise capture keeps running behind an overlay that
    /// still claims to be waiting for audio.
    private func handleRecognitionFailure(_ error: Error) {
        let now = Date()
        if now.timeIntervalSince(lastRecognitionFailureTime) > recognitionFailureWindow {
            consecutiveRecognitionFailures = 0
        }
        lastRecognitionFailureTime = now
        consecutiveRecognitionFailures += 1

        guard consecutiveRecognitionFailures <= recognitionRestartBackoff.count else {
            stopRecognitionAndSurface(error)
            return
        }

        let delay = recognitionRestartBackoff[consecutiveRecognitionFailures - 1]
        guard delay > 0 else {
            restartRecognitionTask()
            return
        }

        pendingRecognitionRestart?.cancel()
        let restart = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRecognitionRestart = nil
            self.restartRecognitionTask()
        }
        pendingRecognitionRestart = restart
        captureQueue.asyncAfter(deadline: .now() + delay, execute: restart)
    }

    /// Ends the session after recognition has failed for good, and reports why.
    ///
    /// Capture is torn down along with the recognizer: audio that nothing transcribes is
    /// only a microphone left open, and the surfaced message tells the user the session
    /// has stopped. `stopOnCaptureQueue` keeps `errorHandler` in place, so the message
    /// still reaches the UI.
    private func stopRecognitionAndSurface(_ error: Error) {
        stopOnCaptureQueue()

        Task {
            await self.emitFatalError(
                self.localized(
                    .speechRecognitionStoppedFormat,
                    self.localizedErrorDescription(error)
                )
            )
        }
    }

    /// Builds the result/error handler used by every recognition task.
    ///
    /// On transient errors (no speech detected, internal failure, etc.) the handler
    /// restarts recognition so the pipeline never goes silent. Repeated failures back
    /// off and are eventually surfaced instead of retried forever — see
    /// `handleRecognitionFailure`. Fatal configuration errors (permission denied,
    /// unsupported locale) propagate to the UI so the user knows why things stopped.
    private func makeRecognitionHandler() -> (SFSpeechRecognitionResult?, Error?) -> Void {
        // Capture the generation at handler-creation time. Any callback arriving
        // after a restart (which bumps recognitionGeneration) will be discarded,
        // preventing stale isFinal results from replaying committed sentences.
        let generation = recognitionGeneration
        return { [weak self] result, error in
            if let error {
                let nsError = error as NSError
                let disposition = Self.legacyRecognitionErrorDisposition(
                    domain: nsError.domain,
                    code: nsError.code,
                    message: nsError.localizedDescription
                )

                // Codes 216/301 are intentional cancellation from our own restart/stop.
                if disposition == .ignore { return }

                self?.captureQueue.async { [weak self] in
                    guard let self, self.speechRecognizer != nil,
                          self.recognitionGeneration == generation else { return }

                    switch disposition {
                    case .ignore:
                        break
                    case .restartImmediately:
                        // Code 1110 is a normal "no speech detected" timeout.
                        self.restartRecognitionTask()
                    case .stopAndSurface:
                        // An exhausted Apple server quota. Retrying only produces more
                        // rejected requests, so fail fast and tell the user.
                        self.stopRecognitionAndSurface(error)
                    case .retryWithBackoff:
                        self.handleRecognitionFailure(error)
                    }
                }
                return
            }

            guard let result else { return }
            self?.captureQueue.async { [weak self] in
                guard let self, self.recognitionGeneration == generation else { return }
                self.processRecognitionResult(result)
            }
        }
    }












    private var activeHeuristicLanguage: RecognitionHeuristicLanguage {
        switch activeLanguageCode {
        case "ja":
            return .japanese
        case "en":
            return .english
        default:
            return .other
        }
    }

    private var activeLanguageCode: String? {
        guard let activeLocaleIdentifier else {
            return nil
        }

        let separators = CharacterSet(charactersIn: "-_")
        return activeLocaleIdentifier
            .components(separatedBy: separators)
            .first?
            .lowercased()
    }







    private func cmTimeMilliseconds(_ time: CMTime) -> Int {
        guard time.isNumeric else { return 0 }
        return Int((CMTimeGetSeconds(time) * 1000.0).rounded())
    }

    // MARK: - Silence-commit timer






    // MARK: - VAD-based silence commit







    private func segmentEndTime(for segment: SFTranscriptionSegment) -> TimeInterval {
        segment.timestamp + segment.duration
    }

    /// Converts a legacy request-relative segment span into a capture-time
    /// `CMTimeRange` for diarization. Nil while the request's first appended
    /// buffer hasn't pinned the origin.
    private func legacyCaptureAudioRange(
        startSegment: SFTranscriptionSegment,
        endSegment: SFTranscriptionSegment
    ) -> CMTimeRange? {
        guard let origin = legacyRequestOriginCaptureSeconds else { return nil }
        let start = origin + startSegment.timestamp
        let end = origin + segmentEndTime(for: endSegment)
        guard end > start else { return nil }
        return CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 1000),
            end: CMTime(seconds: end, preferredTimescale: 1000)
        )
    }

    /// Capture-time range of a legacy final, for speaker attribution.
    private func finalAudioRange(
        firstSegment: SFTranscriptionSegment?,
        lastSegment: SFTranscriptionSegment?
    ) -> CMTimeRange? {
        guard let firstSegment, let lastSegment else { return nil }
        return legacyCaptureAudioRange(startSegment: firstSegment, endSegment: lastSegment)
    }

    // MARK: - Draft helpers (called on captureQueue)






#if os(macOS)
    private func mapApplicationCaptureError(_ error: ApplicationAudioCapture.CaptureError) -> SessionError {
        switch error {
        case .permissionDenied:
            return .audioCapturePermissionDenied
        case .missingOutputDevice:
            return .failedToStartCapture(localized(.noOutputAudioDeviceForAppCapture))
        case .tapFormatUnavailable:
            return .failedToStartCapture(localized(.selectedAppAudioFormatCouldNotBePrepared))
        case .failed(let stage, let status):
            return .failedToStartCapture(
                localized(.failedToStageWithReasonFormat, stage, status.readableDescription)
            )
        }
    }
#endif
#if DEBUG
    /// Opens the session without permission prompts or hardware capture. Audio then
    /// arrives only through `appendInjectedAudioForTesting`, which enters the same
    /// capture-queue path a microphone or application buffer takes: format
    /// conversion, gain, VAD, diarization and the recognizer. Nothing is played.
    var injectsAudioForTesting = false

    func appendInjectedAudioForTesting(_ buffer: AVAudioPCMBuffer) {
        captureQueue.async { [self] in
            append(audioBuffer: buffer)
        }
    }

    /// Replays a fixture event through the same ordered delivery path a real
    /// recognizer event takes.
    func emitEventForTesting(_ event: CaptionSessionEvent) {
        emitEvent(event)
    }










#endif
}

extension LiveTranscriptionSession: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        append(sampleBuffer: sampleBuffer)
    }
}

#if os(macOS)
private final class ApplicationAudioCapture {
    enum CaptureError: Error {
        case permissionDenied
        case missingOutputDevice
        case tapFormatUnavailable
        case failed(stage: String, status: OSStatus)
    }

    private let appName: String
    private let processObjectIDs: [AudioObjectID]
    private let readStreamFailureMessage: String
    private let queue: DispatchQueue
    private let audioHandler: (AVAudioPCMBuffer) -> Void
    private let errorHandler: (String) -> Void

    private let system = AudioHardwareSystem.shared
    private var processTap: AudioHardwareTap?
    private var aggregateDevice: AudioHardwareAggregateDevice?
    private var deviceIOProcID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?

    init(
        appName: String,
        processObjectIDs: [AudioObjectID],
        readStreamFailureMessage: String,
        queue: DispatchQueue,
        audioHandler: @escaping (AVAudioPCMBuffer) -> Void,
        errorHandler: @escaping (String) -> Void
    ) {
        self.appName = appName
        self.processObjectIDs = processObjectIDs
        self.readStreamFailureMessage = readStreamFailureMessage
        self.queue = queue
        self.audioHandler = audioHandler
        self.errorHandler = errorHandler
    }

    func start() throws {
        do {
            let tapDescription = CATapDescription(monoMixdownOfProcesses: processObjectIDs)
            tapDescription.uuid = UUID()
            tapDescription.muteBehavior = .unmuted
            tapDescription.isPrivate = true
            tapDescription.name = "v2s \(appName)"

            guard let processTap = try system.makeProcessTap(description: tapDescription) else {
                throw CaptureError.failed(stage: "create the process tap", status: kAudioHardwareIllegalOperationError)
            }

            self.processTap = processTap

            guard let outputDevice = try system.defaultOutputDevice else {
                throw CaptureError.missingOutputDevice
            }

            let outputUID = try outputDevice.uid
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "v2s-\(appName)",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [
                        kAudioSubDeviceUIDKey: outputUID
                    ]
                ],
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapDriftCompensationKey: true,
                        kAudioSubTapUIDKey: try processTap.uid
                    ]
                ]
            ]

            guard let aggregateDevice = try system.makeAggregateDevice(description: aggregateDescription) else {
                throw CaptureError.failed(stage: "create the aggregate device", status: kAudioHardwareIllegalOperationError)
            }

            self.aggregateDevice = aggregateDevice

            var streamDescription = try processTap.format
            guard let tapFormat = AVAudioFormat(streamDescription: &streamDescription) else {
                throw CaptureError.tapFormatUnavailable
            }

            self.tapFormat = tapFormat

            var deviceIOProcID: AudioDeviceIOProcID?
            let createIOProcStatus = AudioDeviceCreateIOProcIDWithBlock(
                &deviceIOProcID,
                aggregateDevice.id,
                queue
            ) { [weak self] _, inputData, _, _, _ in
                guard let self else {
                    return
                }

                self.handleCapturedAudio(inputData)
            }

            guard createIOProcStatus == noErr, let deviceIOProcID else {
                throw CaptureError.failed(stage: "create the capture callback", status: createIOProcStatus)
            }

            self.deviceIOProcID = deviceIOProcID

            let startStatus = AudioDeviceStart(aggregateDevice.id, deviceIOProcID)
            guard startStatus == noErr else {
                throw CaptureError.failed(stage: "start app audio capture", status: startStatus)
            }
        } catch let error as AudioHardwareError {
            stop()

            if error.error == permErr {
                throw CaptureError.permissionDenied
            }

            throw CaptureError.failed(stage: "configure app audio capture", status: error.error)
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let aggregateDevice, let deviceIOProcID {
            AudioDeviceStop(aggregateDevice.id, deviceIOProcID)
            AudioDeviceDestroyIOProcID(aggregateDevice.id, deviceIOProcID)
        }

        deviceIOProcID = nil

        if let aggregateDevice {
            try? system.destroyAggregateDevice(aggregateDevice)
        }

        aggregateDevice = nil

        if let processTap {
            try? system.destroyProcessTap(processTap)
        }

        processTap = nil
        tapFormat = nil
    }

    private func handleCapturedAudio(_ inputData: UnsafePointer<AudioBufferList>) {
        guard let tapFormat,
              inputData.pointee.mNumberBuffers > 0,
              inputData.pointee.mBuffers.mDataByteSize > 0 else {
            return
        }

        let mutableAudioBufferList = UnsafeMutablePointer<AudioBufferList>(mutating: inputData)

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: tapFormat,
            bufferListNoCopy: mutableAudioBufferList,
            deallocator: nil
        ) else {
            errorHandler(readStreamFailureMessage)
            return
        }

        audioHandler(buffer)
    }
}
#endif

private struct AudioFormatSignature: Equatable {
    let sampleRate: Double
    let channelCount: AVAudioChannelCount
    let commonFormat: AVAudioCommonFormat
    let isInterleaved: Bool

    init(_ format: AVAudioFormat) {
        sampleRate = format.sampleRate
        channelCount = format.channelCount
        commonFormat = format.commonFormat
        isInterleaved = format.isInterleaved
    }
}

private extension AVAudioFormat {
    func matches(_ other: AVAudioFormat) -> Bool {
        AudioFormatSignature(self) == AudioFormatSignature(other)
    }
}

#if os(macOS)
private extension InputSource {
    var processIdentifierHint: pid_t? {
        guard detail.hasPrefix("pid-") else {
            return nil
        }

        return pid_t(detail.dropFirst(4))
    }
}

private struct ApplicationProcessAssociation {
    let bundleIdentifier: String?
    let applicationBundleURL: URL?
    let helperBundlePrefixes: [String]
    let helperPathFragments: [String]

    init(runningApplication: NSRunningApplication) {
        self.bundleIdentifier = runningApplication.bundleIdentifier
        self.applicationBundleURL = runningApplication.bundleURL?.standardizedFileURL

        var helperBundlePrefixes: [String] = []
        var helperPathFragments: [String] = []

        if let bundleIdentifier = runningApplication.bundleIdentifier {
            helperBundlePrefixes.append(bundleIdentifier)

            switch bundleIdentifier {
            case "com.apple.Safari":
                helperBundlePrefixes.append(contentsOf: [
                    "com.apple.WebKit.",
                    "com.apple.Safari"
                ])
                helperPathFragments.append(contentsOf: [
                    "/WebKit.framework/",
                    "/SafariPlatformSupport.framework/",
                    "/Safari.app/"
                ])
            case "com.google.Chrome":
                helperPathFragments.append(contentsOf: [
                    "/Google Chrome.app/",
                    "Google Chrome Helper"
                ])
            case "org.chromium.Chromium":
                helperPathFragments.append(contentsOf: [
                    "/Chromium.app/",
                    "Chromium Helper"
                ])
            case "com.microsoft.edgemac":
                helperPathFragments.append(contentsOf: [
                    "/Microsoft Edge.app/",
                    "Microsoft Edge Helper"
                ])
            case "com.brave.Browser":
                helperPathFragments.append(contentsOf: [
                    "/Brave Browser.app/",
                    "Brave Browser Helper"
                ])
            case "org.mozilla.firefox":
                helperPathFragments.append(contentsOf: [
                    "/Firefox.app/",
                    "plugin-container"
                ])
            default:
                break
            }
        }

        self.helperBundlePrefixes = Array(Set(helperBundlePrefixes))
        self.helperPathFragments = Array(Set(helperPathFragments))
    }

    func matchesExactBundleIdentifier(_ candidate: String) -> Bool {
        guard let bundleIdentifier else {
            return false
        }

        return candidate == bundleIdentifier
    }

    func matchesApplicationBundleURL(_ candidate: URL?) -> Bool {
        guard let applicationBundleURL else {
            return false
        }

        return candidate == applicationBundleURL
    }

    func matchesHelperBundleIdentifier(_ candidate: String) -> Bool {
        guard candidate.isEmpty == false else {
            return false
        }

        return helperBundlePrefixes.contains(where: { candidate.hasPrefix($0) })
    }

    func matchesHelperExecutablePath(_ candidate: String?) -> Bool {
        guard let candidate, candidate.isEmpty == false else {
            return false
        }

        return helperPathFragments.contains(where: { candidate.contains($0) })
    }
}
#endif

private extension String {
    var containsSentenceTerminator: Bool {
        contains(where: { ".!?。！？;；".contains($0) })
    }

    var containsCJKCharacters: Bool {
        unicodeScalars.contains {
            (0x4E00...0x9FFF).contains($0.value)   // CJK Unified Ideographs
                || (0x3040...0x30FF).contains($0.value) // Hiragana + Katakana
                || (0xAC00...0xD7AF).contains($0.value) // Korean Hangul
        }
    }
}

private extension LiveTranscriptionSession {
    enum RecognitionHeuristicLanguage {
        case japanese
        case english
        case other
    }

    static let minimumLatinLeadingOverlapCharacters = 10
    static let minimumCJKLeadingOverlapCharacters = 4
    static let recentCommittedSentenceLimit = 6
    static let committedPrefixContinuationWindow: TimeInterval = 3.0
    /// Stamp rounding between the committed window's end and a re-covering
    /// hypothesis's start. A hypothesis starting past end + slack belongs to
    /// a new window; overlapping windows plus a verbatim full-prefix repeat
    /// remain indistinguishable locally and are documented at the call site.
    static let modernCommittedPrefixWindowEndSlackMs = 250
    /// Lexical scalars a commit's new words must share with the draft's opening
    /// (or all of the shorter one) to finalize that draft.
    static let draftConsumptionSharedOpening = 2
    static let dialogueClauseSeparators: Set<Character> = ["、", ",", "，"]
    static let japaneseDialogueClauseEndingSuffixes = [
        "ね", "よ", "の", "な", "さ", "わ", "ぞ", "ぜ", "かな", "かも", "だよ", "だね"
    ]
    static let japaneseDialogueClauseLeadingPhrases = [
        "俺", "私", "僕", "うん", "いや", "や", "でも", "じゃ", "ただいま", "おかえり", "ありがとう", "ごめん"
    ]
    static let modernVADDeferredJapaneseCommitSuffixes = [
        "けど", "けれど", "けれども", "から", "ので", "のに", "とか", "って",
        "で", "て", "が", "を", "に", "へ", "と", "し"
    ]
    static let modernVADDeferredEnglishCommitSuffixes = [
        " and", " or", " but", " so", " because", " if", " when", " that", " to"
    ]
    static let committedComparisonTrimCharacterSet = CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters)
        .union(.symbols)
    static let leadingOverlapTrimCharacterSet = CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters)
}

#if os(macOS)
private extension OSStatus {
    var readableDescription: String {
        let nsError = NSError(domain: NSOSStatusErrorDomain, code: Int(self))

        if nsError.localizedDescription != "The operation couldn’t be completed. (OSStatus error \(self).)" {
            return nsError.localizedDescription
        }

        if let fourCharacterCode = fourCharacterCode {
            return "\(self) (\(fourCharacterCode))"
        }

        return "\(self)"
    }

    private var fourCharacterCode: String? {
        let bigEndianValue = UInt32(bitPattern: self).bigEndian
        let scalarValues = [
            UInt8((bigEndianValue >> 24) & 0xFF),
            UInt8((bigEndianValue >> 16) & 0xFF),
            UInt8((bigEndianValue >> 8) & 0xFF),
            UInt8(bigEndianValue & 0xFF)
        ]

        guard scalarValues.allSatisfy({ $0 >= 32 && $0 <= 126 }) else {
            return nil
        }

        return String(bytes: scalarValues, encoding: .ascii)
    }
}

private func executablePath(forProcessID processID: pid_t) -> String? {
    let pathBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(MAXPATHLEN))
    defer {
        pathBuffer.deallocate()
    }

    let pathLength = proc_pidpath(processID, pathBuffer, UInt32(MAXPATHLEN))
    guard pathLength > 0 else {
        return nil
    }

    return String(cString: pathBuffer)
}

private func applicationBundleURL(forProcessID processID: pid_t) -> URL? {
    guard let executablePath = executablePath(forProcessID: processID) else {
        return nil
    }

    return URL(fileURLWithPath: executablePath).owningApplicationBundleURL()
}

private extension URL {
    func owningApplicationBundleURL(maxDepth: Int = 16) -> URL? {
        var depth = 0
        var currentURL = standardizedFileURL

        while depth < maxDepth {
            if currentURL.pathExtension == "app" {
                return currentURL.standardizedFileURL
            }

            currentURL = currentURL.deletingLastPathComponent()
            depth += 1
        }

        return nil
    }
}
#endif
