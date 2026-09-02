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

struct RecognizedSentence: Equatable, Sendable {
    let text: String
    let promotionSegmentID: UUID?
    let replacesPromotionSegmentID: UUID?
    let heardLanguageID: String
    let dualLaneEvidence: DualLaneEvidence?
    let audioStartMs: Int?

    init(
        text: String,
        promotionSegmentID: UUID? = nil,
        replacesPromotionSegmentID: UUID? = nil,
        heardLanguageID: String = "",
        dualLaneEvidence: DualLaneEvidence? = nil,
        audioStartMs: Int? = nil
    ) {
        self.text = text
        self.promotionSegmentID = promotionSegmentID
        self.replacesPromotionSegmentID = replacesPromotionSegmentID
        self.heardLanguageID = heardLanguageID
        self.dualLaneEvidence = dualLaneEvidence
        self.audioStartMs = audioStartMs
    }
}

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

    private struct CommittedEmission {
        let text: String
        let promotionSegmentID: UUID?
        let heardLanguageID: String
        let dualLaneEvidence: DualLaneEvidence?
        let isProvisionalSilence: Bool
        let audioRange: CMTimeRange?
        let audioEndTime: TimeInterval?
        let audioStartMs: Int?

        init(
            text: String,
            promotionSegmentID: UUID? = nil,
            heardLanguageID: String = "",
            dualLaneEvidence: DualLaneEvidence? = nil,
            isProvisionalSilence: Bool = false,
            audioRange: CMTimeRange? = nil,
            audioEndTime: TimeInterval? = nil,
            audioStartMs: Int? = nil
        ) {
            self.text = text
            self.promotionSegmentID = promotionSegmentID
            self.heardLanguageID = heardLanguageID
            self.dualLaneEvidence = dualLaneEvidence
            self.isProvisionalSilence = isProvisionalSilence
            self.audioRange = audioRange
            self.audioEndTime = audioEndTime
            self.audioStartMs = audioStartMs
        }
    }

#if os(macOS)
    private struct ApplicationCaptureDescriptor: Sendable {
        let appName: String
        let processObjectIDs: [AudioObjectID]
        let readStreamFailureMessage: String
    }
#endif

    @MainActor
    private struct RecentCommittedSentence {
        let rawText: String
        let comparableText: String
        let time: Date
        let isProvisionalSilence: Bool
        let allowsPrefixContinuation: Bool
        let promotionSegmentID: UUID?
        let rootPromotionSegmentID: UUID?
        var acceptedPromotionIDs: Set<UUID>
        let audioRange: CMTimeRange?
        let audioEndTime: TimeInterval?

        init(
            rawText: String,
            comparableText: String,
            time: Date,
            isProvisionalSilence: Bool = false,
            allowsPrefixContinuation: Bool,
            promotionSegmentID: UUID?,
            rootPromotionSegmentID: UUID? = nil,
            acceptedPromotionIDs: Set<UUID> = [],
            audioRange: CMTimeRange? = nil,
            audioEndTime: TimeInterval? = nil
        ) {
            self.rawText = rawText
            self.comparableText = comparableText
            self.time = time
            self.isProvisionalSilence = isProvisionalSilence
            self.allowsPrefixContinuation = allowsPrefixContinuation
            self.promotionSegmentID = promotionSegmentID
            self.rootPromotionSegmentID = rootPromotionSegmentID ?? promotionSegmentID
            var ids = acceptedPromotionIDs
            if let promotionSegmentID {
                ids.insert(promotionSegmentID)
            }
            self.acceptedPromotionIDs = ids
            self.audioRange = audioRange
            self.audioEndTime = audioEndTime
        }
    }
    struct PreparedSentenceEmission: Equatable, Sendable {
        let text: String
        let promotionSegmentID: UUID?
        let replacesPromotionSegmentID: UUID?
    }

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
    private var committedSegmentCount = 0
    private let committedBoundaryToleranceSec: TimeInterval = 0.08
    private var committedAudioBoundaryTime: TimeInterval?
    private var primaryRecognitionContextualStrings: [String] = []
    private var secondaryRecognitionContextualStrings: [String] = []
    private var recognitionContextualStrings: [String] = []
    private var recognitionBackend: RecognitionBackend = .legacy
    private var activeLocaleIdentifier: String?
    private var configuredSourceLanguageID = ""
    private var configuredTargetLanguageID = ""
    private var currentHeardLanguageID = ""
    private var speechCorrections = SpeechCorrectionTable.empty
    private var dualLaneRuntime: AnyObject?
    private var interfaceLanguageID = "en"
    private var modernAnalyzerTask: Task<Void, Never>?
    private var modernResultsTask: Task<Void, Never>?
    private var lastModernCommittedResultIdentity: String?
    private var speechAnalyzerState: AnyObject?
    private var speechTranscriberState: AnyObject?
    private var analyzerInputContinuationState: Any?
    private var analyzerInputFormat: AVAudioFormat?
    private var latestModernText = ""
    private var lastModernAudioStartMs: Int?
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

    private func enqueueCommittedSequence(
        _ emissions: [CommittedEmission],
        clearDraftAfter: Bool
    ) {
        enqueuePresentationWork {
            self.emitCommittedSequence(emissions, clearDraftAfter: clearDraftAfter)
        }
    }

    private func enqueuePartialDraft(_ draft: DraftSegment?) {
        enqueuePresentationWork {
            self.emitPartialDraft(draft)
        }
    }

    func awaitPendingEmissionsForTesting() async {
        await appendPresentationWork({}).value
    }
    private var modernCommittedPrefixText = ""
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
    private var localASRPendingSegments: [[Float]] = []
    private var localASRTranscriptionTask: Task<Void, Never>?
    private let localASRPreRollSampleCount = 4_800  // 300 ms at 16 kHz
    private let localASRMinimumSegmentSampleCount = 4_000
    private let localASRMaximumSegmentSampleCount = 240_000  // 15 seconds
#endif

    private var microphoneCaptureSession: AVCaptureSession?
#if os(macOS)
    private var applicationAudioCapture: ApplicationAudioCapture?
#endif

    private var transcriptHandler: (@MainActor (RecognizedSentence) -> Void)?
    private var partialHandler: (@MainActor (DraftSegment?) -> Void)?
    private var errorHandler: (@MainActor (String) -> Void)?
    /// Reports an unrecoverable recognition failure after this session has stopped.
    /// The owner uses this separate callback to stop sibling sessions as well.
    private var fatalErrorHandler: (@MainActor (String) -> Void)?
    @MainActor private var recentCommittedSentenceHistory: [RecentCommittedSentence] = []

    private func localized(_ key: AppTextKey, _ arguments: CVarArg...) -> String {
        AppLocalization.formattedString(key, languageID: interfaceLanguageID, arguments: arguments)
    }

    private func localizedErrorDescription(_ error: Error) -> String {
        AppLocalization.localizedErrorDescription(error, languageID: interfaceLanguageID)
    }

    // MARK: Draft state (accessed only on captureQueue)
    private var modeConfig: ModeConfig = .balanced
    private var currentDraftId = UUID()
    private var lastDraftText = ""
    private var lastDraftTextChangeTime = Date.distantPast
    private var lastRecognitionResultTime = Date.distantPast
    private var draftChangeHistory: [(text: String, time: Date)] = []
    private var draftPrefixCandidate = ""
    private var draftPrefixCandidateTime = Date.distantPast
    private var confirmedStablePrefixLength = 0

    // MARK: Silence-commit timer (captureQueue)
    // Fires when the ASR stops delivering new results — i.e. the user has paused.
    // This is more reliable than measuring inter-word gaps because the last word in
    // a sentence has no "next segment" and therefore never triggers a pause boundary.
    private var silenceCommitTimer: DispatchSourceTimer?
    private var latestSegments: [SFTranscriptionSegment] = []
    private var latestFormattedText: NSString = ""

    // MARK: Silero VAD (captureQueue)
    private var vadEngine: SileroVADEngine?
    private var lastVADProbability: Float = 0.0
    private var vadSilenceCommitTimer: DispatchSourceTimer?
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

    private enum SilenceCommitTrigger {
        case asrInactivity
        case vadOffset
    }

    func start(
        source: InputSource,
        localeIdentifier: String,
        interfaceLanguageID: String,
        modeConfig: ModeConfig = .balanced,
        contextualStrings: [String] = [],
        secondaryContextualStrings: [String] = [],
        sourceLanguageID: String = "",
        targetLanguageID: String = "",
        speechCorrections: SpeechCorrectionTable = .empty,
        transcriptHandler: @escaping @MainActor (RecognizedSentence) -> Void,
        partialHandler: @escaping @MainActor (DraftSegment?) -> Void,
        errorHandler: @escaping @MainActor (String) -> Void,
        fatalErrorHandler: @escaping @MainActor (String) -> Void
    ) async throws {
        self.transcriptHandler = transcriptHandler
        self.partialHandler = partialHandler
        self.modeConfig = modeConfig
        self.primaryRecognitionContextualStrings = sanitizeContextualStrings(contextualStrings)
        self.secondaryRecognitionContextualStrings = sanitizeContextualStrings(secondaryContextualStrings)
        self.recognitionContextualStrings = self.primaryRecognitionContextualStrings
        self.activeLocaleIdentifier = localeIdentifier
        self.configuredSourceLanguageID = sourceLanguageID
        self.configuredTargetLanguageID = targetLanguageID
        self.currentHeardLanguageID = sourceLanguageID
        self.speechCorrections = speechCorrections
        self.interfaceLanguageID = interfaceLanguageID
        self.errorHandler = errorHandler
        self.fatalErrorHandler = fatalErrorHandler
        let startGeneration: Int = try await runOnCaptureQueue {
            self.lifecycleGeneration &+= 1
            self.startupCancelled = false
            return self.lifecycleGeneration
        }
        await MainActor.run {
            recentCommittedSentenceHistory.removeAll()
        }
        try await ensureStartupIsCurrent(startGeneration)

        let usesLocalTaigi = localeIdentifier.lowercased().hasPrefix("nan")
#if os(macOS) && canImport(WhisperKit)
        let usesLocalTibetan = localeIdentifier.lowercased().hasPrefix("bo")
#else
        let usesLocalTibetan = false
#endif
        try await requestRequiredPermissions(
            for: source,
            requiresSpeechAuthorization:
                usesLocalTaigi == false && usesLocalTibetan == false
        )
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

    /// Stops the session and returns only after its capture queue has released all
    /// microphone/Core Audio resources. Used before starting replacement sessions.
    func stopAndWait() async {
        await withCheckedContinuation { continuation in
            captureQueue.async { [self] in
                stopOnCaptureQueue()
                continuation.resume()
            }
        }
    }

    private func stopOnCaptureQueue() {
        startupCancelled = true
        lifecycleGeneration &+= 1
        cancelSilenceTimer()
        cancelVADSilenceTimer()

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

        stopModernSpeechRecognizer()
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
        resetLegacyTranscriptionState()

        vadEngine = nil
        lastVADProbability = 0

        resetModernTranscriptionState()
        partialHandler = nil
        resetDraftState()
        Task { @MainActor [weak self] in
            self?.recentCommittedSentenceHistory.removeAll()
        }
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
        resetLegacyTranscriptionState()
        resetModernTranscriptionState()
        cancelSilenceTimer()
        cancelVADSilenceTimer()
        resetDraftState()
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
        resetLegacyTranscriptionState()
        resetModernTranscriptionState()
        cancelSilenceTimer()
        cancelVADSilenceTimer()
        resetDraftState()
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
        resetRecognitionFailureState()
        resetAudioProcessingState()
        resetLegacyTranscriptionState()
        resetModernTranscriptionState()
        cancelSilenceTimer()
        resetDraftState()

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
            let sharedNeutral = SpeechCorrectionService.neutralRecognitionPhrases(
                corrections: speechCorrections,
                languageIDs: [configuredSourceLanguageID, "en"],
                glossaryKeys: primaryRecognitionContextualStrings + secondaryRecognitionContextualStrings
            )
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

        modernResultsTask?.cancel()
        if let secondaryTranscriber {
            let runtime = DualLaneCaptionRuntime(
                primaryLanguageID: configuredSourceLanguageID,
                secondaryLanguageID: "en"
            )
            runtime.onStep = { [weak self] step, heardLanguageID in
                self?.captureQueue.async { [weak self] in
                    self?.processDualLaneStep(
                        step,
                        heardLanguageID: heardLanguageID
                    )
                }
            }
            runtime.onFailure = { [weak self] error in
                self?.fallbackFromSpeechAnalyzer(error)
            }
            runtime.start(primary: primaryTranscriber, secondary: secondaryTranscriber)
            dualLaneRuntime = runtime
            modernResultsTask = nil
        } else {
            dualLaneRuntime = nil
            modernResultsTask = Task { [weak self] in
                do {
                    for try await result in primaryTranscriber.results {
                        self?.captureQueue.async { [weak self] in
                            self?.processModernRecognitionResult(result)
                        }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    self?.fallbackFromSpeechAnalyzer(error)
                }
            }
        }

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
        analyzerInputFormat = preferredFormat
        recognitionBackend = .speechAnalyzer
        recognitionRequest = nil
        recognitionTask = nil
        speechRecognizer = nil
        audioConverter = nil
        audioConverterInputSignature = nil
        resetLegacyTranscriptionState()
        resetModernTranscriptionState()
        cancelSilenceTimer()
        cancelVADSilenceTimer()
        resetDraftState()
        lastModernCommittedResultIdentity = nil

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
        modernResultsTask?.cancel()
        modernResultsTask = nil
        lastModernCommittedResultIdentity = nil
        recognitionBackend = .legacy
        modernAudioConverter = nil
        modernAudioConverterInputSignature = nil
        resetModernTranscriptionState()
        if #available(iOS 26.0, macOS 26.0, *) {
            (dualLaneRuntime as? DualLaneCaptionRuntime)?.finish()
        }
        dualLaneRuntime = nil

        if #available(iOS 26.0, macOS 26.0, *) {
            (analyzerInputContinuationState as? AsyncStream<AnalyzerInput>.Continuation)?.finish()
            analyzerInputContinuationState = nil
            let analyzer = speechAnalyzerState as? SpeechAnalyzer
            speechAnalyzerState = nil
            speechTranscriberState = nil
            analyzerInputFormat = nil

            if let analyzer {
                Task {
                    await analyzer.cancelAndFinishNow()
                }
            }
        }
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

    private func resetModernTranscriptionState() {
        latestModernText = ""
        modernCommittedPrefixText = ""
        lastModernAudioStartMs = nil
    }

    private func resetLegacyTranscriptionState() {
        committedSegmentCount = 0
        committedAudioBoundaryTime = nil
        latestSegments = []
        latestFormattedText = ""
    }

    private func startMicrophoneCapture(deviceUniqueID: String) throws {
#if os(iOS)
        // The audio session must be configured and active before capture starts:
        // `deviceUniqueID` names an AVAudioSession route port (CarPlay, Bluetooth,
        // built-in), and only `setPreferredInput` can steer capture to it — route
        // ports are not AVCaptureDevices. The preference is best-effort; when the
        // port has vanished the system keeps routing from its own default.
        let audioSession = AVAudioSession.sharedInstance()
        try IOSAudioSessionConfigurator.applyRecordCategory()
        if let preferredPort = audioSession.availableInputs?
            .first(where: { $0.uid == deviceUniqueID }) {
            // A disappearing route should not prevent capture from falling back to
            // the system input, but category setup and activation are mandatory when
            // automatic AVCaptureSession audio-session management is disabled.
            try? audioSession.setPreferredInput(preferredPort)
        }
        try audioSession.setActive(true)

        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw SessionError.missingMicrophoneDevice
        }
#else
        guard let device = AVCaptureDevice(uniqueID: deviceUniqueID) else {
            throw SessionError.missingMicrophoneDevice
        }
#endif

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

#if os(iOS)
        // The session above is the authoritative configuration; left on, the capture
        // session would reapply its own category on start and drop the Bluetooth
        // option plus the preferred input.
        session.automaticallyConfiguresApplicationAudioSession = false
#endif

        session.beginConfiguration()
        session.addInput(input)
        output.setSampleBufferDelegate(self, queue: captureQueue)
        session.addOutput(output)
        session.commitConfiguration()

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

        var currentVADResult: VADResult?
        if let vadEngine {
            let vadResult = vadEngine.process(buffer: processingBuffer)
            currentVADResult = vadResult
            lastVADProbability = vadResult.speechProbability

#if canImport(WhisperKit)
            let usesASRSilenceTimers = usesLocalWhisperRecognizer == false
#else
            let usesASRSilenceTimers = true
#endif
            if usesASRSilenceTimers {
                if vadResult.containsSpeechOffset {
                    scheduleVADSilenceCommit()
                }
                if vadResult.containsSpeechOnset {
                    cancelVADSilenceTimer()
                }
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

        // Always forward audio to the recognizer — VAD is used only
        // for silence-commit timing, not to gate the audio stream.
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

        continuation.yield(AnalyzerInput(buffer: analyzerBuffer))
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

        enqueueLocalASRSegment(localASRSegment)
        localASRSegment.removeAll(keepingCapacity: true)
        if endsSpeech, vadResult?.isSpeech == true {
            // One capture buffer can contain offset then a new onset. Preserve the
            // ambiguous buffer as pre-roll for the new segment rather than dropping
            // the newly-started utterance.
            localASRSpeechActive = true
            localASRSegment = samples
        } else {
            localASRSpeechActive = endsSpeech == false
        }
        if localASRSpeechActive == false {
            localASRPreRoll.removeAll(keepingCapacity: true)
        }
    }

    private func enqueueLocalASRSegment(_ audio: [Float]) {
        guard audio.count >= localASRMinimumSegmentSampleCount else { return }
        localASRPendingSegments.append(audio)
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

        let audio = localASRPendingSegments.removeFirst()
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
                let text = try await transcribe(audio)
                guard Task.isCancelled == false else { return }
                if let prepared = await self.prepareCommittedSentenceForEmission(text, pendingPromotionID: nil) {
                    await self.emitRecognizedSentence(
                        RecognizedSentence(
                            text: prepared.text,
                            promotionSegmentID: prepared.promotionSegmentID,
                            replacesPromotionSegmentID: prepared.replacesPromotionSegmentID,
                            heardLanguageID: currentHeardLanguageID
                        )
                    )
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
    private func emitRecognizedSentence(_ sentence: RecognizedSentence) {
        transcriptHandler?(sentence)
    }

    @MainActor
    private func emitRecognizedText(_ text: String, promotionSegmentID: UUID? = nil) {
        let sentenceTexts = splitCommittedEmissionUnits(in: text)
        var pendingPromotionID = promotionSegmentID

        for sentenceText in sentenceTexts {
            guard let prepared = prepareCommittedSentenceForEmission(sentenceText, pendingPromotionID: pendingPromotionID) else {
                continue
            }
            emitRecognizedSentence(
                RecognizedSentence(
                    text: prepared.text,
                    promotionSegmentID: prepared.promotionSegmentID,
                    replacesPromotionSegmentID: prepared.replacesPromotionSegmentID,
                    heardLanguageID: currentHeardLanguageID
                )
            )
            pendingPromotionID = nil
        }
    }

    @MainActor
    private func emitCommittedSequence(
        _ emissions: [CommittedEmission],
        clearDraftAfter: Bool = false
    ) {
        pruneRecentCommittedSentenceHistory()

        for emission in emissions {
            let sentenceTexts = splitCommittedEmissionUnits(in: emission.text)
            var pendingPromotionID = emission.promotionSegmentID
            let emissionLang = emission.heardLanguageID.isEmpty
                ? currentHeardLanguageID
                : emission.heardLanguageID
            let parentStartMs = emission.audioStartMs

            for (unitIndex, sentenceText) in sentenceTexts.enumerated() {
                let corrected = speechCorrections.apply(sentenceText, languageID: emissionLang)
                guard let prepared = prepareCommittedSentenceForEmission(
                    corrected,
                    pendingPromotionID: pendingPromotionID,
                    isProvisionalSilence: emission.isProvisionalSilence,
                    audioRange: emission.audioRange,
                    audioEndTime: emission.audioEndTime
                ) else {
                    continue
                }
                let isTrailingUnit = unitIndex == sentenceTexts.count - 1
                emitRecognizedSentence(
                    RecognizedSentence(
                        text: prepared.text,
                        promotionSegmentID: prepared.promotionSegmentID,
                        replacesPromotionSegmentID: prepared.replacesPromotionSegmentID,
                        heardLanguageID: emissionLang,
                        dualLaneEvidence: emission.dualLaneEvidence,
                        audioStartMs: isTrailingUnit ? parentStartMs : nil
                    )
                )
                pendingPromotionID = nil
            }
        }
        if clearDraftAfter {
            emitPartialDraft(nil)
        }
    }

    private func splitCommittedEmissionUnits(in text: String) -> [String] {
        splitRecognizedSentences(in: text).flatMap(splitDialogueClausesIfNeeded)
    }

    private func splitDialogueClausesIfNeeded(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return []
        }

        guard let separatorRange = singleDialogueClauseSeparatorRange(in: trimmed) else {
            return [trimmed]
        }

        let left = String(trimmed[..<separatorRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let right = String(trimmed[separatorRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

        guard shouldSplitDialogueClauses(left: left, right: right) else {
            return [trimmed]
        }

        return [left, right]
    }

    private func singleDialogueClauseSeparatorRange(in text: String) -> Range<String.Index>? {
        var separatorRange: Range<String.Index>?

        for index in text.indices where Self.dialogueClauseSeparators.contains(text[index]) {
            if separatorRange != nil {
                return nil
            }

            separatorRange = index..<text.index(after: index)
        }

        return separatorRange
    }

    private func shouldSplitDialogueClauses(left: String, right: String) -> Bool {
        guard activeHeuristicLanguage == .japanese,
              left.isEmpty == false,
              right.isEmpty == false,
              left.containsCJKCharacters || right.containsCJKCharacters else {
            return false
        }

        let maxClauseLength = 18
        guard left.count <= maxClauseLength,
              right.count <= maxClauseLength else {
            return false
        }

        let leftLooksComplete = Self.japaneseDialogueClauseEndingSuffixes.contains(where: { left.hasSuffix($0) })
            || left.containsSentenceTerminator
        let rightLooksLikeNewTurn = Self.japaneseDialogueClauseLeadingPhrases.contains(where: { right.hasPrefix($0) })

        return leftLooksComplete || rightLooksLikeNewTurn
    }

    @MainActor
    private func emitPartialDraft(_ draft: DraftSegment?) {
        guard var draft else {
            partialHandler?(nil)
            return
        }
        let languageID = currentHeardLanguageID.isEmpty
            ? configuredSourceLanguageID
            : currentHeardLanguageID
        let corrected = speechCorrections.apply(
            draft.sourceText,
            stablePrefixLength: draft.stablePrefixLength,
            languageID: languageID
        )
        draft.sourceText = corrected.text
        draft.stablePrefixLength = corrected.stablePrefixLength
        draft.mutableTailText = String(corrected.text.dropFirst(min(corrected.stablePrefixLength, corrected.text.count)))
        partialHandler?(draft)
    }

    @MainActor
    private func emitError(_ message: String) {
        errorHandler?(message)
    }

    @MainActor
    private func emitFatalError(_ message: String) {
        fatalErrorHandler?(message)
    }

    @MainActor
    private func prepareCommittedSentenceForEmission(
        _ text: String,
        pendingPromotionID: UUID? = nil,
        isProvisionalSilence: Bool = false,
        audioRange: CMTimeRange? = nil,
        audioEndTime: TimeInterval? = nil
    ) -> PreparedSentenceEmission? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return nil
        }

        let comparable = comparableCommittedSentenceText(trimmed)
        guard comparable.isEmpty == false else {
            return nil
        }

        // Replay suppression: if this exact promotion ID was already accepted in recent history, drop duplicate callback.
        if let pendingPromotionID,
           recentCommittedSentenceHistory.contains(where: { $0.acceptedPromotionIDs.contains(pendingPromotionID) }) {
            return nil
        }

        // Continuation, replay, or in-place revision check against recent history:
        if let continuation = committedContinuationOrRevision(
            from: trimmed,
            comparableText: comparable,
            pendingPromotionID: pendingPromotionID,
            isProvisionalSilence: isProvisionalSilence,
            audioRange: audioRange,
            audioEndTime: audioEndTime
        ) {
            return continuation
        }

        // Legacy nil-ID replay suppression: if no ID provided and exact text was recently committed, drop duplicate.
        if pendingPromotionID == nil,
           recentCommittedSentenceHistory.contains(where: { $0.comparableText == comparable }) {
            return nil
        }

        let bestOverlap = recentCommittedSentenceHistory
            .suffix(3)
            .map { leadingOverlapLength(previous: $0.rawText, current: trimmed) }
            .max() ?? 0

        let candidateText: String
        // Only trim partial leading overlap if it does NOT drop the entire text when a distinct promotion ID is provided.
        if shouldTrimLeadingOverlap(length: bestOverlap, in: trimmed) && (bestOverlap < trimmed.count || pendingPromotionID == nil) {
            candidateText = dropLeadingCharacters(bestOverlap, from: trimmed)
                .trimmingCharacters(in: Self.leadingOverlapTrimCharacterSet)
        } else {
            candidateText = trimmed
        }

        guard candidateText.isEmpty == false else {
            return nil
        }

        let candidateComparable = comparableCommittedSentenceText(candidateText)
        guard candidateComparable.isEmpty == false else {
            return nil
        }

        if pendingPromotionID == nil,
           recentCommittedSentenceHistory.contains(where: { $0.comparableText == candidateComparable }) {
            return nil
        }

        let emissionPromotionID = pendingPromotionID ?? UUID()
        rememberCommittedSentence(
            candidateText,
            isProvisionalSilence: isProvisionalSilence,
            promotionSegmentID: emissionPromotionID,
            rootPromotionSegmentID: emissionPromotionID,
            audioRange: audioRange,
            audioEndTime: audioEndTime
        )

        return PreparedSentenceEmission(
            text: candidateText,
            promotionSegmentID: emissionPromotionID,
            replacesPromotionSegmentID: nil
        )
    }

    @MainActor
    private func rememberCommittedSentence(
        _ text: String,
        isProvisionalSilence: Bool = false,
        promotionSegmentID: UUID?,
        rootPromotionSegmentID: UUID? = nil,
        audioRange: CMTimeRange? = nil,
        audioEndTime: TimeInterval? = nil
    ) {
        let comparable = comparableCommittedSentenceText(text)
        guard comparable.isEmpty == false else {
            return
        }

        let allowsContinuation = isProvisionalSilence
            || (SentenceBoundaryHeuristics.endsWithLikelySentenceTerminator(in: text) == false)

        recentCommittedSentenceHistory.append(
            RecentCommittedSentence(
                rawText: text,
                comparableText: comparable,
                time: Date(),
                isProvisionalSilence: isProvisionalSilence,
                allowsPrefixContinuation: allowsContinuation,
                promotionSegmentID: promotionSegmentID,
                rootPromotionSegmentID: rootPromotionSegmentID ?? promotionSegmentID,
                audioRange: audioRange,
                audioEndTime: audioEndTime
            )
        )
        pruneRecentCommittedSentenceHistory()
    }

    @MainActor
    private func committedContinuationOrRevision(
        from text: String,
        comparableText: String,
        pendingPromotionID: UUID?,
        isProvisionalSilence: Bool,
        audioRange: CMTimeRange?,
        audioEndTime: TimeInterval?
    ) -> PreparedSentenceEmission? {
        let now = Date()

        for (index, previous) in recentCommittedSentenceHistory.enumerated().reversed() {
            let elapsed = now.timeIntervalSince(previous.time)
            guard elapsed <= Self.committedPrefixContinuationWindow else {
                continue
            }

            let isAudioSpanMatch: Bool
            if let prevRange = previous.audioRange, let currRange = audioRange {
                let prevStart = cmTimeSeconds(prevRange.start)
                let currStart = cmTimeSeconds(currRange.start)
                isAudioSpanMatch = abs(prevStart - currStart) <= 0.35
            } else if let prevEnd = previous.audioEndTime, let currEnd = audioEndTime {
                isAudioSpanMatch = currEnd <= prevEnd + 0.15
            } else {
                isAudioSpanMatch = false
            }

            let prevStripped = canonicalSentencePunctuationStripped(previous.rawText)
            let currStripped = canonicalSentencePunctuationStripped(text)

            let isSameComparable = (previous.comparableText == comparableText) || (prevStripped == currStripped)
            let isNearDup = isNearDuplicateCommittedText(prevStripped, currStripped)
            let isPrefixExt = currStripped.hasPrefix(prevStripped)
                && currStripped.count > prevStripped.count
            let isFuzzyExt = isFuzzyPrefixMatch(previous: prevStripped, current: currStripped)
            // Audio match must be gated by semantic relation, never unconditional.
            let hasSemanticRelation = isSameComparable || isNearDup || isPrefixExt || isFuzzyExt
            let isMatch: Bool
            if pendingPromotionID == nil && isSameComparable {
                return nil
            } else if isAudioSpanMatch {
                isMatch = hasSemanticRelation
            } else if previous.isProvisionalSilence {
                isMatch = hasSemanticRelation
            } else if previous.allowsPrefixContinuation {
                isMatch = isPrefixExt || isFuzzyExt || (isSameComparable && elapsed <= 1.5)
            } else {
                isMatch = false
            }

            guard isMatch else {
                continue
            }

            let newPromotionID = pendingPromotionID ?? UUID()
            let rootID = previous.rootPromotionSegmentID ?? previous.promotionSegmentID ?? newPromotionID
            var updatedIDs = previous.acceptedPromotionIDs
            updatedIDs.insert(newPromotionID)

            recentCommittedSentenceHistory.remove(at: index)
            recentCommittedSentenceHistory.append(
                RecentCommittedSentence(
                    rawText: text,
                    comparableText: comparableText,
                    time: now,
                    isProvisionalSilence: isProvisionalSilence,
                    allowsPrefixContinuation: isProvisionalSilence
                        || (SentenceBoundaryHeuristics.endsWithLikelySentenceTerminator(in: text) == false),
                    promotionSegmentID: newPromotionID,
                    rootPromotionSegmentID: rootID,
                    acceptedPromotionIDs: updatedIDs,
                    audioRange: audioRange ?? previous.audioRange,
                    audioEndTime: audioEndTime ?? previous.audioEndTime
                )
            )

            return PreparedSentenceEmission(
                text: text,
                promotionSegmentID: newPromotionID,
                replacesPromotionSegmentID: rootID
            )
        }

        return nil
    }

    private func canonicalSentencePunctuationStripped(_ text: String) -> String {
        text.unicodeScalars.filter {
            CharacterSet.punctuationCharacters.contains($0) == false
                && CharacterSet.symbols.contains($0) == false
        }
        .map(String.init)
        .joined()
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { $0.isEmpty == false }
        .joined(separator: " ")
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func isNearDuplicateCommittedText(_ lhs: String, _ rhs: String) -> Bool {
        let lhsClean = canonicalSentencePunctuationStripped(lhs)
        let rhsClean = canonicalSentencePunctuationStripped(rhs)
        if lhsClean == rhsClean {
            return true
        }
        let maxLen = max(lhsClean.count, rhsClean.count)
        guard maxLen >= 3 else {
            return false
        }
        let similarity = CaptionLanguagePolicy.normalizedEditSimilarity(lhsClean, rhsClean)
        return similarity >= 0.82
    }

    private func isFuzzyPrefixMatch(previous: String, current: String) -> Bool {
        let prevClean = canonicalSentencePunctuationStripped(previous)
        let currClean = canonicalSentencePunctuationStripped(current)
        guard prevClean.count >= 2, currClean.count > prevClean.count else {
            return false
        }
        let prevLen = prevClean.count
        let currentPrefix = String(currClean.prefix(prevLen))
        let similarity = CaptionLanguagePolicy.normalizedEditSimilarity(prevClean, currentPrefix)
        return similarity >= 0.72
    }

    private func cmTimeSeconds(_ time: CMTime) -> Double {
        time.isNumeric ? CMTimeGetSeconds(time) : 0
    }

    @MainActor
    private func pruneRecentCommittedSentenceHistory() {
        let now = Date()
        recentCommittedSentenceHistory.removeAll { now.timeIntervalSince($0.time) > 8.0 }
        if recentCommittedSentenceHistory.count > Self.recentCommittedSentenceLimit {
            recentCommittedSentenceHistory.removeFirst(
                recentCommittedSentenceHistory.count - Self.recentCommittedSentenceLimit
            )
        }
    }

    private func comparableCommittedSentenceText(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
            .trimmingCharacters(in: Self.committedComparisonTrimCharacterSet)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func leadingOverlapLength(previous: String, current: String) -> Int {
        let previousCharacters = Array(previous)
        let currentCharacters = Array(current)
        let maxOverlap = min(previousCharacters.count, currentCharacters.count)

        guard maxOverlap > 0 else {
            return 0
        }

        for overlap in stride(from: maxOverlap, through: 1, by: -1) {
            if Array(previousCharacters.suffix(overlap)) == Array(currentCharacters.prefix(overlap)) {
                return overlap
            }
        }

        return 0
    }

    private func shouldTrimLeadingOverlap(length: Int, in text: String) -> Bool {
        guard length > 0, text.isEmpty == false else {
            return false
        }

        let minimumOverlap = text.containsCJKCharacters
            ? Self.minimumCJKLeadingOverlapCharacters
            : Self.minimumLatinLeadingOverlapCharacters
        let overlapRatio = Double(length) / Double(text.count)
        return length >= minimumOverlap && overlapRatio >= 0.35
    }

    private func dropLeadingCharacters(_ count: Int, from text: String) -> String {
        guard count > 0 else {
            return text
        }

        var index = text.startIndex
        var remaining = count
        while remaining > 0, index < text.endIndex {
            index = text.index(after: index)
            remaining -= 1
        }

        return String(text[index...])
    }

    private func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func splitRecognizedSentences(in text: String) -> [String] {
        let normalizedText = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedText.isEmpty == false else {
            return []
        }

        let nsText = normalizedText as NSString
        let sentenceRanges = sentenceRanges(in: nsText)
        guard sentenceRanges.isEmpty == false else {
            return [normalizedText]
        }

        return sentenceRanges.compactMap { range in
            let sentence = nsText.substring(with: range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return sentence.isEmpty ? nil : sentence
        }
    }

    private func sentenceRanges(in text: NSString) -> [NSRange] {
        SentenceBoundaryHeuristics.sentenceRanges(in: text)
    }
    private func pendingModernText(from fullText: String) -> String {
        guard modernCommittedPrefixText.isEmpty == false else {
            return fullText
        }
        if fullText.hasPrefix(modernCommittedPrefixText) {
            return String(fullText.dropFirst(modernCommittedPrefixText.count))
        }

        let committedSentences = splitRecognizedSentences(in: modernCommittedPrefixText)
        let nsFullText = fullText as NSString
        let fullSentenceRanges = sentenceRanges(in: nsFullText)
        let fullSentences = fullSentenceRanges.map {
            nsFullText.substring(with: $0).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard committedSentences.isEmpty == false,
              fullSentences.isEmpty == false else {
            return fullText
        }

        let committedComparable = committedSentences.map(comparableCommittedSentenceText)
        let fullComparable = fullSentences.map(comparableCommittedSentenceText)
        let maxOverlap = min(committedComparable.count, fullComparable.count)

        for overlap in stride(from: maxOverlap, through: 1, by: -1) {
            if Array(committedComparable.suffix(overlap)) == Array(fullComparable.prefix(overlap)) {
                let matchedRange = fullSentenceRanges[overlap - 1]
                let nextLocation = matchedRange.location + matchedRange.length
                guard nextLocation < nsFullText.length else {
                    return ""
                }

                return nsFullText.substring(from: nextLocation)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return fullText
    }

    private func committableModernText(in rawText: String) -> (committedRawText: String, remainingRawText: String)? {
        let trimmedText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.isEmpty == false else {
            return nil
        }

        let nsText = rawText as NSString
        let sentenceRanges = sentenceRanges(in: nsText)
        guard sentenceRanges.isEmpty == false else {
            return nil
        }

        if SentenceBoundaryHeuristics.endsWithLikelySentenceTerminator(in: trimmedText) {
            return (rawText, "")
        }

        guard sentenceRanges.count >= 2,
              let trailingSentenceRange = sentenceRanges.last,
              trailingSentenceRange.location > 0 else {
            return nil
        }

        let committedRawText = nsText.substring(to: trailingSentenceRange.location)
        let remainingRawText = nsText.substring(from: trailingSentenceRange.location)
        guard committedRawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }

        return (committedRawText, remainingRawText)
    }

    private func hasLikelyPunctuationBoundary(
        afterSegmentAt index: Int,
        in formattedText: NSString,
        segments: [SFTranscriptionSegment]
    ) -> Bool {
        let currentRange = segments[index].substringRange
        let boundaryEndLocation = index < segments.count - 1
            ? segments[index + 1].substringRange.location
            : formattedText.length

        guard boundaryEndLocation > currentRange.location else {
            return false
        }

        let boundaryText = formattedText.substring(
            with: NSRange(location: currentRange.location, length: boundaryEndLocation - currentRange.location)
        )
        let nextText = index < segments.count - 1 ? segments[index + 1].substring : nil

        return SentenceBoundaryHeuristics.endsWithLikelySentenceTerminator(
            in: boundaryText,
            followedBy: nextText
        )
    }

    private func emittedTextRange(
        in formattedText: NSString,
        segments: [SFTranscriptionSegment],
        from startIndex: Int,
        to endIndex: Int
    ) -> NSRange {
        let startLocation = segments[startIndex].substringRange.location
        let endLocation = endIndex < segments.count - 1
            ? segments[endIndex + 1].substringRange.location
            : formattedText.length

        return NSRange(location: startLocation, length: max(0, endLocation - startLocation))
    }

    private func processRecognitionResult(_ result: SFSpeechRecognitionResult) {
        lastRecognitionResultTime = Date()
        // The recognizer is delivering again — forget any earlier failures.
        consecutiveRecognitionFailures = 0
        let transcription = result.bestTranscription
        let segments = transcription.segments
        let formattedText = transcription.formattedString as NSString
        var committedEmissions: [CommittedEmission] = []

        // Always save the latest transcript so the silence timer can commit it
        latestSegments = segments
        latestFormattedText = formattedText

        alignCommittedSegmentCount(to: segments)

        guard committedSegmentCount < segments.count else {
            cancelSilenceTimer()
            // The task has no more pending text. If it just finished, restart it.
            if result.isFinal { restartRecognitionTask() }
            return
        }

        var sentenceStartIndex = committedSegmentCount

        for index in committedSegmentCount..<segments.count {
            let segment = segments[index]
            let nextPauseDuration: TimeInterval?

            if index < segments.count - 1 {
                let nextSegment = segments[index + 1]
                nextPauseDuration = nextSegment.timestamp - (segment.timestamp + segment.duration)
            } else {
                nextPauseDuration = nil
            }

            let currentSegmentCount = index - sentenceStartIndex + 1
            let sentenceStartTimestamp = segments[sentenceStartIndex].timestamp
            let sentenceEndTimestamp = segment.timestamp + segment.duration
            let currentSentenceDuration = max(sentenceEndTimestamp - sentenceStartTimestamp, 0)
            // Apple may place restored punctuation in the gap before the next segment
            // rather than inside the current segment substring.
            let punctuationBoundary = hasLikelyPunctuationBoundary(
                afterSegmentAt: index,
                in: formattedText,
                segments: segments
            )
            // 0.85 s was too conservative and often merged two short sentences.
            let strongPauseBoundary = (nextPauseDuration ?? 0) >= max(0.55, Double(modeConfig.minSilenceCommitMs) / 1000.0 + 0.24)
            // Char-length limit removed: 40 chars is only ~6 English words and caused
            // false mid-sentence cuts. Segment count + audio duration are sufficient.
            let forcedBoundary = currentSegmentCount >= 18
                || currentSentenceDuration >= modeConfig.maxChunkAudioSec
            let finalBoundary = result.isFinal && index == segments.count - 1

            guard punctuationBoundary || strongPauseBoundary || forcedBoundary || finalBoundary else {
                continue
            }

            // When a purely forced cut lands close to the end of available segments,
            // absorb the tiny tail rather than leaving a 1–2 word orphan that would
            // be emitted as a meaningless standalone sentence by the silence timer.
            var commitEndIndex = index
            if forcedBoundary && !punctuationBoundary && !strongPauseBoundary && !finalBoundary {
                let tailCount = (segments.count - 1) - index
                if tailCount > 0 && tailCount <= 2 {
                    commitEndIndex = segments.count - 1
                }
            }

            let commitRange = emittedTextRange(
                in: formattedText,
                segments: segments,
                from: sentenceStartIndex,
                to: commitEndIndex
            )

            let sentenceText = formattedText.substring(with: commitRange)
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let committedDraftID = currentDraftId

            if sentenceText.isEmpty == false {
                committedEmissions.append(
                    CommittedEmission(
                        text: sentenceText,
                        promotionSegmentID: committedDraftID,
                        isProvisionalSilence: !result.isFinal,
                        audioEndTime: segmentEndTime(for: segments[commitEndIndex])
                    )
                )
            }

            committedAudioBoundaryTime = segmentEndTime(for: segments[commitEndIndex])
            sentenceStartIndex = commitEndIndex + 1
            committedSegmentCount = sentenceStartIndex
            resetDraftState()

            // If we consumed all remaining segments (tail absorption or final boundary),
            // stop iterating to avoid referencing segments beyond the committed range.
            if commitEndIndex >= segments.count - 1 { break }
        }

        let shouldClearDraftAfterCommit = committedSegmentCount >= segments.count

        // Emit draft update for the uncommitted tail
        if committedSegmentCount < segments.count {
            emitDraftUpdate(
                draftRange: committedSegmentCount..<segments.count,
                allSegments: segments,
                formattedText: formattedText
            )
            // Schedule a silence-based commit: if no new ASR result arrives within
            // silenceCommitDeadlineMs, the user has paused → commit whatever we have.
            scheduleSilenceCommit()
        } else {
            cancelSilenceTimer()
        }

        if committedEmissions.isEmpty == false {
            enqueueCommittedSequence(
                committedEmissions,
                clearDraftAfter: shouldClearDraftAfterCommit
            )
        } else if shouldClearDraftAfterCommit {
            enqueuePartialDraft(nil)
        }

        // SFSpeechRecognizer marks isFinal = true when its internal session ends
        // (after a long pause or utterance limit). Once final, the task delivers no
        // more callbacks — new audio is silently ignored. Restart immediately so
        // recognition continues without interruption.
        if result.isFinal {
            restartRecognitionTask()
        }
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
        cancelSilenceTimer()
        cancelVADSilenceTimer()
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
        // Reset the converter — new request may have a different nativeAudioFormat.
        resetAudioProcessingState()
        resetLegacyTranscriptionState()
        resetModernTranscriptionState()
        resetDraftState()
        enqueuePartialDraft(nil)
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

    @available(iOS 26.0, macOS 26.0, *)
    private func processDualLaneStep(
        _ step: DualLaneStep,
        heardLanguageID: String
    ) {
        if let commitText = step.commitText {
            let resolved = resolveHeardCaption(
                text: commitText,
                heardLanguageID: heardLanguageID,
                evidence: step.evidence
            )
            currentHeardLanguageID = resolved.languageID
            let text = resolved.text
            cancelSilenceTimer()
            cancelVADSilenceTimer()
            resetModernTranscriptionState()
            let committedDraftID = currentDraftId
            resetDraftState()
            guard text.isEmpty == false else {
                enqueuePartialDraft(nil)
                return
            }
            enqueueCommittedSequence(
                [
                    CommittedEmission(
                        text: text,
                        promotionSegmentID: committedDraftID,
                        heardLanguageID: resolved.languageID,
                        dualLaneEvidence: step.evidence,
                        isProvisionalSilence: false
                    )
                ],
                clearDraftAfter: true
            )
            return
        }

        guard let draftText = step.draftText, draftText.isEmpty == false else {
            return
        }
        let resolved = resolveHeardCaption(
            text: draftText,
            heardLanguageID: heardLanguageID,
            evidence: nil
        )
        currentHeardLanguageID = resolved.languageID
        latestModernText = resolved.text
        emitCorrectedDraft(resolved.text)
    }

    private func resolveHeardCaption(
        text: String,
        heardLanguageID: String,
        evidence: DualLaneEvidence? = nil
    ) -> (text: String, languageID: String) {
        var languageID = heardLanguageID.isEmpty ? configuredSourceLanguageID : heardLanguageID
        if LanguageIdentity.isEnglish(languageID),
           CaptionLanguagePolicy.shouldReverse(
            configuredSourceLanguageID: configuredSourceLanguageID,
            configuredTargetLanguageID: configuredTargetLanguageID,
            heardLanguageID: languageID,
            heardText: text,
            evidence: evidence
           ) == false {
            languageID = configuredSourceLanguageID
        }
        return (text, languageID)
    }

    private func emitCorrectedDraft(_ text: String) {
        let now = Date()
        lastRecognitionResultTime = now
        observeDraftText(text, at: now)
        latestModernText = text
        let draftStability = currentDraftStability(at: now)
        let boundaryScore: Float = SentenceBoundaryHeuristics.endsWithLikelySentenceTerminator(in: text) ? 0.9 : 0.45
        let draft = DraftSegment(
            segmentId: currentDraftId,
            sourceText: text,
            stablePrefixLength: computeStablePrefixLength(text: text, now: now),
            mutableTailText: String(text.dropFirst(min(computeStablePrefixLength(text: text, now: now), text.count))),
            avgConfidence: 0.82,
            startMs: lastModernAudioStartMs ?? 0,
            lastUpdateMs: Int(now.timeIntervalSinceReferenceDate * 1000),
            silenceMs: draftStability.silenceMs,
            stabilityScore: draftStability.stabilityScore,
            boundaryScore: boundaryScore,
            chunkScore: ChunkScorer.score(
                vadProbability: lastVADProbability,
                stabilityScore: draftStability.stabilityScore,
                boundaryScore: boundaryScore,
                lengthFitScore: draftLengthFitScore(for: text),
                confidenceScore: 0.82
            ),
            vadProbability: lastVADProbability,
            words: [],
            heardLanguageID: currentHeardLanguageID,
            audioHypothesisStartMs: lastModernAudioStartMs
        )
        enqueuePartialDraft(draft)
        scheduleSilenceCommit()
    }

    @available(iOS 26.0, macOS 26.0, *)
    private func processModernRecognitionResult(_ result: SpeechTranscriber.Result) {
        processModernRecognitionText(
            normalizedTranscriberText(result.text),
            isFinal: result.isFinal,
            audioRange: result.range
        )
    }

    private func processModernRecognitionText(_ fullText: String, isFinal: Bool, audioRange: CMTimeRange) {
        let now = Date()
        lastRecognitionResultTime = now
        lastModernAudioStartMs = cmTimeMilliseconds(audioRange.start)
        let pendingRawText = pendingModernText(from: fullText)
        currentHeardLanguageID = configuredSourceLanguageID
        let text = pendingRawText.trimmingCharacters(in: .whitespacesAndNewlines)


        if isFinal {
            let identity = "\(cmTimeMilliseconds(audioRange.start)):\(cmTimeMilliseconds(audioRange.duration)):\(fullText)"
            guard identity != lastModernCommittedResultIdentity else { return }
            lastModernCommittedResultIdentity = identity

            cancelSilenceTimer()
            cancelVADSilenceTimer()
            let fullUtteranceText = fullText
            let hypothesisStartMs = lastModernAudioStartMs
            resetModernTranscriptionState()
            let committedDraftID = currentDraftId
            resetDraftState()

            let textToEmit = fullUtteranceText.trimmingCharacters(in: .whitespacesAndNewlines)
            if textToEmit.isEmpty == false {
                enqueueCommittedSequence(
                    [
                        CommittedEmission(
                            text: textToEmit,
                            promotionSegmentID: committedDraftID,
                            heardLanguageID: currentHeardLanguageID,
                            isProvisionalSilence: false,
                            audioRange: audioRange,
                            audioStartMs: hypothesisStartMs
                        )
                    ],
                    clearDraftAfter: true
                )
            } else {
                enqueuePartialDraft(nil)
            }
            return
        }

        guard text.isEmpty == false else {
            latestModernText = ""
            cancelSilenceTimer()
            cancelVADSilenceTimer()
            enqueuePartialDraft(nil)
            return
        }

        observeDraftText(text, at: now)
        latestModernText = pendingRawText
        if let split = committableModernText(in: pendingRawText),
           split.remainingRawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           SentenceBoundaryHeuristics.endsWithLikelySentenceTerminator(in: text),
           canFastCommitModernBoundary(at: now) {
            let committedText = split.committedRawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard committedText.isEmpty == false else {
                latestModernText = ""
                enqueuePartialDraft(nil)
                return
            }
            cancelSilenceTimer()
            modernCommittedPrefixText += split.committedRawText
            latestModernText = split.remainingRawText
            let committedDraftID = currentDraftId
            resetDraftState()
            enqueueCommittedSequence(
                [
                    CommittedEmission(
                        text: committedText,
                        promotionSegmentID: committedDraftID,
                        isProvisionalSilence: true,
                        audioRange: audioRange,
                        audioStartMs: lastModernAudioStartMs
                    )
                ],
                clearDraftAfter: true
            )
            return
        }

        emitCorrectedDraft(text)
    }

    private func observeDraftText(_ text: String, at now: Date) {
        if text != lastDraftText {
            lastDraftText = text
            lastDraftTextChangeTime = now
            draftChangeHistory.append((text: text, time: now))
        }
        draftChangeHistory.removeAll { now.timeIntervalSince($0.time) > 0.4 }
    }

    private func currentDraftStability(at now: Date) -> (silenceMs: Int, stabilityScore: Float) {
        let silenceMs = Int(now.timeIntervalSince(lastDraftTextChangeTime) * 1000)
        let recentChanges = draftChangeHistory.count
        let stabilityScore: Float
        switch recentChanges {
        case 0, 1: stabilityScore = 1.0
        case 2:    stabilityScore = 0.7
        default:   stabilityScore = max(0.1, 0.5 - Float(recentChanges - 2) * 0.15)
        }

        return (silenceMs, stabilityScore)
    }

    private func canFastCommitModernBoundary(at now: Date) -> Bool {
        Int(now.timeIntervalSince(lastDraftTextChangeTime) * 1000) >= modernBoundaryCommitStabilityDelayMs
    }

    private func canVADCommitModernDraft(_ rawText: String, at now: Date) -> Bool {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false else {
            return false
        }

        guard shouldHoldModernVADCommit(for: text) == false else {
            return false
        }

        guard SentenceBoundaryHeuristics.endsWithLikelySentenceTerminator(in: text) else {
            return false
        }

        let stableForMs = Int(now.timeIntervalSince(lastDraftTextChangeTime) * 1000)
        let minimumStableMs = max(vadSilenceCommitDeadlineMs, 260)
        return stableForMs >= minimumStableMs
    }

    private func shouldHoldModernVADCommit(for text: String) -> Bool {
        guard SentenceBoundaryHeuristics.endsWithLikelySentenceTerminator(in: text) == false else {
            return false
        }

        if SentenceBoundaryHeuristics.endsWithLikelyNonTerminalAbbreviation(in: text) {
            return true
        }

        switch activeHeuristicLanguage {
        case .japanese:
            return Self.modernVADDeferredJapaneseCommitSuffixes.contains(where: { text.hasSuffix($0) })
        case .english:
            let normalized = text.lowercased()
            return Self.modernVADDeferredEnglishCommitSuffixes.contains(where: { normalized.hasSuffix($0) })
        case .other:
            // Mandarin and mixed speech often omit punctuation until isFinal.
            // Hold the draft rather than freezing a short clause as its own turn.
            return true
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

    @available(iOS 26.0, macOS 26.0, *)
    private func emitDraftUpdate(from result: SpeechTranscriber.Result, text: String) {
        let now = Date()
        observeDraftText(text, at: now)
        let draftStability = currentDraftStability(at: now)
        let silenceMs = draftStability.silenceMs
        let stabilityScore = draftStability.stabilityScore

        let boundaryScore: Float = SentenceBoundaryHeuristics.endsWithLikelySentenceTerminator(in: text) ? 0.9 : 0.45
        let lengthFitScore = draftLengthFitScore(for: text)
        let averageConfidence = transcriberAverageConfidence(result.text)

        let chunkScore = ChunkScorer.score(
            vadProbability: lastVADProbability,
            stabilityScore: stabilityScore,
            boundaryScore: boundaryScore,
            lengthFitScore: lengthFitScore,
            confidenceScore: averageConfidence
        )

        let stablePrefixLen = computeStablePrefixLength(text: text, now: now)
        let mutableTail = String(text.dropFirst(min(stablePrefixLen, text.count)))
        let timeRange = transcriberTimeRange(result.text)
        let startMs = timeRange.map { cmTimeMilliseconds($0.start) } ?? 0

        let draft = DraftSegment(
            segmentId: currentDraftId,
            sourceText: text,
            stablePrefixLength: stablePrefixLen,
            mutableTailText: mutableTail,
            avgConfidence: averageConfidence,
            startMs: startMs,
            lastUpdateMs: Int(now.timeIntervalSinceReferenceDate * 1000),
            silenceMs: silenceMs,
            stabilityScore: stabilityScore,
            boundaryScore: boundaryScore,
            chunkScore: chunkScore,
            vadProbability: lastVADProbability,
            words: [],
            audioHypothesisStartMs: timeRange.map { cmTimeMilliseconds($0.start) }
        )

        enqueuePartialDraft(draft)
    }

    @available(iOS 26.0, macOS 26.0, *)
    private func normalizedTranscriberText(_ text: AttributedString) -> String {
        String(text.characters)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @available(iOS 26.0, macOS 26.0, *)
    private func transcriberAverageConfidence(_ text: AttributedString) -> Float {
        var total: Double = 0
        var count = 0

        for run in text.runs {
            if let confidence = run.transcriptionConfidence {
                total += confidence
                count += 1
            }
        }

        guard count > 0 else { return 0.82 }
        return Float(total / Double(count))
    }

    @available(iOS 26.0, macOS 26.0, *)
    private func transcriberTimeRange(_ text: AttributedString) -> CMTimeRange? {
        for run in text.runs {
            if let timeRange = run.audioTimeRange {
                return timeRange
            }
        }

        return nil
    }

    @available(iOS 26.0, macOS 26.0, *)
    private func modernResultIdentity(for result: SpeechTranscriber.Result) -> String {
        let startMs = cmTimeMilliseconds(result.range.start)
        let durationMs = cmTimeMilliseconds(result.range.duration)
        return "\(startMs):\(durationMs):\(normalizedTranscriberText(result.text))"
    }

    private func draftLengthFitScore(for text: String) -> Float {
        let charCount = text.count
        let isCJK = text.containsCJKCharacters

        if isCJK {
            switch charCount {
            case 12...20: return 1.0
            case 5..<12:  return Float(charCount) / 12.0 * 0.6
            case 21...30: return 0.7
            default:      return 0.3
            }
        }

        switch charCount {
        case 28...56: return 1.0
        case 10..<28: return Float(charCount) / 28.0 * 0.6
        case 57...84: return 0.7
        default:      return 0.3
        }
    }

    private func cmTimeMilliseconds(_ time: CMTime) -> Int {
        guard time.isNumeric else { return 0 }
        return Int((CMTimeGetSeconds(time) * 1000.0).rounded())
    }

    // MARK: - Silence-commit timer

    /// Time after the last ASR callback before we force-commit pending text.
    ///
    /// 420 ms was too short: SFSpeechRecognizer can take 400–600 ms between consecutive
    /// partial-result callbacks for the same utterance on a loaded device, causing the
    /// timer to fire between two ASR deliveries for the same sentence.
    ///
    /// ~600–690 ms sits safely above:
    ///   • inter-result ASR delivery gaps (typically 100–500 ms during speech)
    ///   • natural within-sentence pauses in Mandarin/Japanese (200–450 ms)
    /// and below clear sentence-ending silences (≥ 600 ms for most speakers).
    ///
    /// Follow ≈ 600 ms · Balanced ≈ 630 ms · Reading ≈ 690 ms.
    private var silenceCommitDeadlineMs: Int {
        max(600, modeConfig.minSilenceCommitMs + 350)
    }

    /// Require a short stable window before promoting a punctuation-ended partial.
    /// This keeps the fast path responsive without freezing a still-revisable boundary.
    private var modernBoundaryCommitStabilityDelayMs: Int {
        max(160, min(modeConfig.minSilenceCommitMs, 240))
    }

    private var vadSilenceCommitDeadlineMs: Int {
        max(280, modeConfig.minSilenceCommitMs)
    }

    private func scheduleSilenceCommit() {
        scheduleSilenceCommit(trigger: .asrInactivity, afterMs: silenceCommitDeadlineMs)
    }

    private func cancelSilenceTimer() {
        silenceCommitTimer?.cancel()
        silenceCommitTimer = nil
    }

    // MARK: - VAD-based silence commit

    /// Schedules a fast commit based on Silero VAD detecting speech offset.
    /// Uses the mode's minSilenceCommitMs (100–200 ms) — much faster than the
    /// ASR-inactivity timer (700+ ms).
    private func scheduleVADSilenceCommit() {
        scheduleSilenceCommit(trigger: .vadOffset, afterMs: vadSilenceCommitDeadlineMs)
    }

    private func cancelVADSilenceTimer() {
        vadSilenceCommitTimer?.cancel()
        vadSilenceCommitTimer = nil
    }

    private func scheduleSilenceCommit(trigger: SilenceCommitTrigger, afterMs: Int) {
        cancelSilenceCommitTimer(for: trigger)
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now() + .milliseconds(afterMs))
        timer.setEventHandler { [weak self] in
            self?.forceCommitOnSilence(trigger: trigger)
        }
        timer.resume()

        switch trigger {
        case .asrInactivity:
            silenceCommitTimer = timer
        case .vadOffset:
            vadSilenceCommitTimer = timer
        }
    }

    private func cancelSilenceCommitTimer(for trigger: SilenceCommitTrigger) {
        switch trigger {
        case .asrInactivity:
            cancelSilenceTimer()
        case .vadOffset:
            cancelVADSilenceTimer()
        }
    }

    /// Called by the silence timer when no new ASR result has arrived for
    /// silenceCommitDeadlineMs — meaning the user has paused.
    private func forceCommitOnSilence(trigger: SilenceCommitTrigger) {
        switch trigger {
        case .asrInactivity:
            silenceCommitTimer = nil
        case .vadOffset:
            vadSilenceCommitTimer = nil
        }

        if recognitionBackend == .speechAnalyzer {
            let committedRawText: String
            let remainingRawText: String

            switch trigger {
            case .asrInactivity:
                guard let split = committableModernText(in: latestModernText) else {
                    return
                }
                committedRawText = split.committedRawText
                remainingRawText = split.remainingRawText
            case .vadOffset:
                let now = Date()
                guard canVADCommitModernDraft(latestModernText, at: now) else {
                    return
                }
                committedRawText = latestModernText
                remainingRawText = ""
            }

            let text = committedRawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.isEmpty == false else {
                latestModernText = remainingRawText
                return
            }

            modernCommittedPrefixText += committedRawText
            latestModernText = remainingRawText
            let committedDraftID = currentDraftId
            let hypothesisStartMs = lastModernAudioStartMs
            resetDraftState()
            enqueueCommittedSequence(
                [
                    CommittedEmission(
                        text: text,
                        promotionSegmentID: committedDraftID,
                        heardLanguageID: currentHeardLanguageID,
                        isProvisionalSilence: true,
                        audioStartMs: hypothesisStartMs
                    )
                ],
                clearDraftAfter: remainingRawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
            return
        }

        let segments = latestSegments
        let formattedText = latestFormattedText

        guard committedSegmentCount < segments.count else { return }

        let pendingSegments = Array(segments[committedSegmentCount...])
        if let delayMs = requiredCommitDelayMs(trigger: trigger, pendingSegments: pendingSegments) {
            scheduleSilenceCommit(trigger: trigger, afterMs: delayMs)
            return
        }

        let lastIdx = segments.count - 1
        let currentRange = combinedRange(for: segments, from: committedSegmentCount, to: lastIdx)
        let sentenceText = (formattedText.substring(with: currentRange) as String)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let committedDraftID = currentDraftId

        committedAudioBoundaryTime = segmentEndTime(for: segments[lastIdx])
        committedSegmentCount = segments.count
        resetDraftState()
        if sentenceText.isEmpty == false {
            enqueueCommittedSequence(
                [
                    CommittedEmission(
                        text: sentenceText,
                        promotionSegmentID: committedDraftID,
                        heardLanguageID: currentHeardLanguageID,
                        isProvisionalSilence: true,
                        audioEndTime: committedAudioBoundaryTime
                    )
                ],
                clearDraftAfter: true
            )
        } else {
            enqueuePartialDraft(nil)
        }
    }
    private func requiredCommitDelayMs(
        trigger: SilenceCommitTrigger,
        pendingSegments: [SFTranscriptionSegment]
    ) -> Int? {
        guard pendingSegments.isEmpty == false else {
            return nil
        }

        let now = Date()
        let lastUpdateTime = max(lastRecognitionResultTime, lastDraftTextChangeTime)
        let elapsedMs = Int(now.timeIntervalSince(lastUpdateTime) * 1000)
        let averageConfidence = pendingSegments.map(\.confidence).reduce(0, +) / Float(pendingSegments.count)

        var settleWindowMs = trigger == .vadOffset ? 320 : 220
        if pendingSegments.count <= 2 {
            settleWindowMs += 80
        }
        if averageConfidence < 0.78 {
            settleWindowMs += 120
        }

        guard elapsedMs < settleWindowMs else {
            return nil
        }

        return settleWindowMs - max(elapsedMs, 0)
    }

    private func alignCommittedSegmentCount(to segments: [SFTranscriptionSegment]) {
        if segments.count < committedSegmentCount {
            resetLegacyTranscriptionState()
            resetDraftState()
            return
        }

        guard let committedAudioBoundaryTime else {
            return
        }

        let alignedCount = segments.prefix {
            segmentEndTime(for: $0) <= committedAudioBoundaryTime + committedBoundaryToleranceSec
        }.count

        guard alignedCount != committedSegmentCount else {
            return
        }

        committedSegmentCount = alignedCount
        resetDraftState()
    }

    private func segmentEndTime(for segment: SFTranscriptionSegment) -> TimeInterval {
        segment.timestamp + segment.duration
    }

    // MARK: - Draft helpers (called on captureQueue)

    private func resetDraftState() {
        currentDraftId = UUID()
        lastDraftText = ""
        lastDraftTextChangeTime = Date.distantPast
        lastRecognitionResultTime = Date.distantPast
        draftChangeHistory = []
        draftPrefixCandidate = ""
        draftPrefixCandidateTime = Date.distantPast
        confirmedStablePrefixLength = 0
    }

    private func emitDraftUpdate(
        draftRange: Range<Int>,
        allSegments: [SFTranscriptionSegment],
        formattedText: NSString
    ) {
        let now = Date()
        let lastIdx = draftRange.upperBound - 1
        let draftNSRange = combinedRange(for: allSegments, from: draftRange.lowerBound, to: lastIdx)
        let text = (formattedText.substring(with: draftNSRange) as String)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            enqueuePartialDraft(nil)
            return
        }

        observeDraftText(text, at: now)
        let draftStability = currentDraftStability(at: now)
        let silenceMs = draftStability.silenceMs
        let stabilityScore = draftStability.stabilityScore

        // Boundary score: sentence-terminating punctuation scores highest
        let boundaryScore: Float = SentenceBoundaryHeuristics.endsWithLikelySentenceTerminator(in: text) ? 0.9 : 0.45

        // Length fit score
        let lengthFitScore = draftLengthFitScore(for: text)

        let draftSegs = Array(allSegments[draftRange])
        let avgConfidence = draftSegs.map(\.confidence).reduce(0, +) / Float(draftSegs.count)

        let chunkScore = ChunkScorer.score(
            vadProbability: lastVADProbability,
            stabilityScore: stabilityScore,
            boundaryScore: boundaryScore,
            lengthFitScore: lengthFitScore,
            confidenceScore: avgConfidence
        )

        let stablePrefixLen = computeStablePrefixLength(text: text, now: now)
        let mutableTail = String(text.dropFirst(min(stablePrefixLen, text.count)))

        let words = draftSegs.map { seg in
            WordToken(
                text: seg.substring,
                startMs: Int(seg.timestamp * 1000),
                endMs: Int((seg.timestamp + seg.duration) * 1000),
                confidence: seg.confidence,
                stable: seg.confidence >= 0.80
            )
        }

        let draft = DraftSegment(
            segmentId: currentDraftId,
            sourceText: text,
            stablePrefixLength: stablePrefixLen,
            mutableTailText: mutableTail,
            avgConfidence: avgConfidence,
            startMs: Int(draftSegs[0].timestamp * 1000),
            lastUpdateMs: Int(now.timeIntervalSinceReferenceDate * 1000),
            silenceMs: silenceMs,
            stabilityScore: stabilityScore,
            boundaryScore: boundaryScore,
            chunkScore: chunkScore,
            vadProbability: lastVADProbability,
            words: words
        )

        enqueuePartialDraft(draft)
    }

    /// Returns the character count of the stable (frozen) prefix.
    /// A prefix is stable once it has been unchanged for >= 400 ms.
    private func computeStablePrefixLength(text: String, now: Date) -> Int {
        let mutableLen = mutableTailCharCount(for: text)
        let candidateLen = max(0, text.count - mutableLen)
        let candidate = String(text.prefix(candidateLen))

        if candidate == draftPrefixCandidate {
            if now.timeIntervalSince(draftPrefixCandidateTime) >= 0.4 {
                confirmedStablePrefixLength = candidateLen
            }
        } else if text.hasPrefix(draftPrefixCandidate) {
            // Text grew but prefix region unchanged — slide candidate forward
            draftPrefixCandidate = candidate
        } else {
            // Prefix regressed — reset
            draftPrefixCandidate = candidate
            draftPrefixCandidateTime = now
            confirmedStablePrefixLength = 0
        }

        return confirmedStablePrefixLength
    }

    /// Characters in the mutable tail: last 12 for CJK, last 35 for Latin (≈ 6 words).
    private func mutableTailCharCount(for text: String) -> Int {
        text.containsCJKCharacters ? min(12, text.count) : min(35, text.count)
    }

    private func combinedRange(for segments: [SFTranscriptionSegment], from startIndex: Int, to endIndex: Int) -> NSRange {
        let firstRange = segments[startIndex].substringRange
        let lastRange = segments[endIndex].substringRange
        let endLocation = lastRange.location + lastRange.length
        return NSRange(location: firstRange.location, length: endLocation - firstRange.location)
    }

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
    @MainActor
    func prepareCommittedSentenceForEmissionForTesting(
        _ text: String,
        pendingPromotionID: UUID? = nil,
        isProvisionalSilence: Bool = false,
        audioRange: CMTimeRange? = nil,
        audioEndTime: TimeInterval? = nil
    ) -> PreparedSentenceEmission? {
        prepareCommittedSentenceForEmission(
            text,
            pendingPromotionID: pendingPromotionID,
            isProvisionalSilence: isProvisionalSilence,
            audioRange: audioRange,
            audioEndTime: audioEndTime
        )
    }

    @MainActor
    func rememberCommittedSentenceForTesting(
        _ text: String,
        isProvisionalSilence: Bool = false,
        promotionSegmentID: UUID? = nil,
        rootPromotionSegmentID: UUID? = nil,
        audioRange: CMTimeRange? = nil,
        audioEndTime: TimeInterval? = nil
    ) {
        rememberCommittedSentence(
            text,
            isProvisionalSilence: isProvisionalSilence,
            promotionSegmentID: promotionSegmentID,
            rootPromotionSegmentID: rootPromotionSegmentID,
            audioRange: audioRange,
            audioEndTime: audioEndTime
        )
    }

    func installTranscriptHandlerForTesting(_ handler: ((RecognizedSentence) -> Void)?) {
        transcriptHandler = handler
    }

    func installPartialHandlerForTesting(_ handler: ((DraftSegment?) -> Void)?) {
        partialHandler = handler
    }


    func processModernRecognitionTextForTesting(
        _ fullText: String,
        isFinal: Bool,
        audioRange: CMTimeRange,
        sourceLanguageID: String = "en"
    ) {
        recognitionBackend = .speechAnalyzer
        if configuredSourceLanguageID.isEmpty {
            configuredSourceLanguageID = sourceLanguageID
            currentHeardLanguageID = sourceLanguageID
        }
        processModernRecognitionText(fullText, isFinal: isFinal, audioRange: audioRange)
    }

    func forceCommitOnSilenceForTesting() {
        recognitionBackend = .speechAnalyzer
        forceCommitOnSilence(trigger: .asrInactivity)
    }

    func forceVADCommitOnSilenceForTesting() {
        recognitionBackend = .speechAnalyzer
        forceCommitOnSilence(trigger: .vadOffset)
    }

    func backdateLastDraftTextChangeForTesting(secondsAgo: TimeInterval) {
        lastDraftTextChangeTime = Date().addingTimeInterval(-secondsAgo)
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
