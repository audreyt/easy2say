import Combine
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import os.log
import Speech
import SwiftUI
import Translation

private extension Logger {
    static let session = Logger(subsystem: "com.franklioxygen.v2s", category: "session")
    static let caption = Logger(subsystem: "com.franklioxygen.v2s", category: "caption")
}

/// A recognition failure that arrived while its own source was still starting, folded
/// back into that source's startup failure. The message is already localized by the
/// session that produced it.
private struct SessionStartupFailure: Error, AppLocalizableError {
    let message: String

    func localizedDescription(languageID: String) -> String {
        message
    }
}

private enum AppBuildInfo {
#if os(iOS)
    static var marketingVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "52"
    }
#else
    static let marketingVersion = "0.3.40"
    static let buildNumber = "44"
    static let repositoryURLString = "https://github.com/audreyt/easy2say"
    static let repositoryURL = URL(string: repositoryURLString)
#endif
}

@MainActor
final class AppModel: ObservableObject {
    private let settingsStore: SettingsStore
    private let sourceCatalogService: SourceCatalogService
    private let translationCoordinator = TranslationCoordinator()
    private let reverseTranslationCoordinator = TranslationCoordinator()
#if os(macOS) && canImport(CoreAILanguageModels) && canImport(SentencepieceTokenizer)
    private let translateGemmaService = TranslateGemmaTranslationService()
#endif
#if os(macOS)
    private let melongOmlxService = MelongOmlxTranslationService()
#endif
    private let glossaryService = GlossaryService()
    private var speechCorrections = SpeechCorrectionTable.empty
    private let speedMonitor = SpeedMonitor()
    private var liveTranscriptionSession: LiveTranscriptionSession?
    private var liveCaptionConfiguredSourceLanguageID = ""
    private var liveCaptionConfiguredTargetLanguageID = ""
    private var liveTranscriptionSessions: [LiveTranscriptionSession] = []
    /// Sessions whose async model/resource setup has begun but whose capture has not
    /// yet been published. Stop must reach these too — Taigi's first Core ML
    /// specialization can take minutes.
    private var startingTranscriptionSessions: [LiveTranscriptionSession] = []
    private var sessionStartGeneration = 0
    // Sources whose capture actually started. A multi-source session tolerates inputs
    // that fail to open, so this can be a subset of `selectedSources` while running.
    private var activeSources: [InputSource] = []
    private var captionDisplayTask: Task<Void, Never>?
    private var captionTranslationTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingCaptions: [QueuedCaption] = []
    private var readyCaptionTranslations: [UUID: String] = [:]
    private var captionTranslationWaiters: [UUID: [UUID: CheckedContinuation<String?, Never>]] = [:]
    private var displayedCaption: QueuedCaption?
    private var isBootstrapping = true
    private var usesSystemInterfaceLanguage = true
    private var draftTranslationTask: Task<Void, Never>?
    private var draftClearTask: Task<Void, Never>?
    private var committedCaptionArchiveTask: Task<Void, Never>?
    private var languageResourcePreparationTask: Task<Void, Never>?
    private var languageCatalogRefreshTask: Task<Void, Never>?
    private var isRefreshingLanguageCatalogs = false
    private var activeDraftSourceLanguageID: String?
    private var activeDraftTargetLanguageID: String?
    private var activeDraftUsesInverseGlossary = false
    private var lastDraftSourceID: String?
    private var lastDraftStablePrefix = ""
    private var lastDraftTranslationSource = ""
    private var lastDraftTranslationPromotionID: UUID?
    private var draftTranslationGeneration: Int = 0
    private var draftClearGeneration: Int = 0
    private var displayedCaptionLastVisualUpdateAt = Date.distantPast
    private var displayedCaptionLastVisualUpdateWasLateTranslation = false
    // Committed translation per caption; late translations may only replace
    // displayed text that still matches what this pipeline committed.
    private var translationRevisions: [UUID: String] = [:]
    private var recentRecognizedCaptionTexts: [RecentRecognizedCaption] = []
    private var inverseGlossaryCaptionIDs: Set<UUID> = []
    private var recentArchivedCaption: RecentArchivedCaption?
    private var finalizedDraftPromotionIDs: [(id: UUID, time: Date)] = []
    private var captionTranslationGenerations: [UUID: UInt64] = [:]
    private var captionIDByPromotionID: [UUID: UUID] = [:]
    private var transcriptInputLanguageID: String?
    private var transcriptOutputLanguageID: String?
#if DEBUG
    private(set) var isSessionActiveForTesting = false
#endif
    private var isCaptionPipelineActive: Bool {
#if DEBUG
        if isSessionActiveForTesting { return true }
#endif
        return liveTranscriptionSession != nil
    }
    private var statusDescriptor: StatusDescriptor = .ready
    private var cachedInverseGlossary: [String: String] = [:]
    @Published private(set) var applicationSources: [InputSource] = []
    @Published private(set) var microphoneSources: [InputSource] = []
    @Published private(set) var sessionState: SessionState = .idle
    @Published private(set) var statusMessage = ""
    @Published private(set) var overlayState: OverlayPreviewState?
    @Published private(set) var languageResourceStatuses: [LanguageResourceStatus] = []
    @Published private(set) var speechLanguageOptions = LanguageCatalog.speechInput
    /// Speech languages this Mac can recognize without sending audio to Apple.
    @Published private(set) var onDeviceSpeechLanguageIDs: Set<String> = []
    @Published private(set) var translationLanguageOptions = LanguageCatalog.common
    @Published private(set) var translationHostConfiguration: TranslationSession.Configuration?
    @Published private(set) var reverseTranslationHostConfiguration: TranslationSession.Configuration?
    @Published private(set) var transcriptEntries: [TranscriptEntry] = []
    @Published private(set) var transcriptGeneration: Int = 0
    @Published var isOverlayVisible = false
    @Published var isAudienceDisplayVisible = false
    @Published private(set) var overlayHistoryVisibleCount = 0
    @Published private(set) var overlayHistoryScrollOffset = 0

    @Published var selectedSourceID: String? {
        didSet {
            persistSettings()
            syncOverlayPreviewIfNeeded()
        }
    }

    @Published var selectedSourceIDs: Set<String> {
        didSet {
            let primarySourceID = preferredPrimarySourceID(for: selectedSourceIDs)
            if selectedSourceID != primarySourceID {
                selectedSourceID = primarySourceID
            }
            persistSettings()
            syncOverlayPreviewIfNeeded()
        }
    }

    @Published var inputLanguageID: String {
        didSet {
            persistSettings()
            syncOverlayPreviewIfNeeded()
            if isRefreshingLanguageCatalogs == false {
                scheduleSelectedLanguageResourcePreparation(openSystemSettingsIfNeeded: true)
            }
        }
    }

    @Published var sourceLanguageOverrides: [String: String] {
        didSet {
            persistSettings()
            syncOverlayPreviewIfNeeded()
            if sessionState != .running, isRefreshingLanguageCatalogs == false {
                scheduleSelectedLanguageResourcePreparation(openSystemSettingsIfNeeded: true)
            }
        }
    }

    @Published var sourceOutputLanguageOverrides: [String: String] {
        didSet {
            persistSettings()
            syncOverlayPreviewIfNeeded()
            if sessionState != .running, isRefreshingLanguageCatalogs == false {
                scheduleSelectedLanguageResourcePreparation(openSystemSettingsIfNeeded: true)
            }
        }
    }

    @Published var outputLanguageID: String {
        didSet {
            persistSettings()
            syncOverlayPreviewIfNeeded()
            if isRefreshingLanguageCatalogs == false {
                scheduleSelectedLanguageResourcePreparation(
                    refreshTranslations: liveTranscriptionSession != nil,
                    openSystemSettingsIfNeeded: true
                )
            }
        }
    }
    @Published var conversationPrimaryLanguageID: String { didSet { persistSettings() } }
    @Published var conversationSecondaryLanguageID: String { didSet { persistSettings() } }
    @Published var conversationFaceToFace: Bool { didSet { persistSettings() } }
    @Published var isConversationModeActive: Bool { didSet { persistSettings() } }

    @Published var interfaceLanguageID: String {
        didSet {
            guard oldValue != interfaceLanguageID else { return }
            usesSystemInterfaceLanguage = false
            persistSettings()
            AppLocalization.updateEmbeddedBundleLocalizationLanguageID(resolvedInterfaceLanguageID)
            relocalizeInterface(from: oldValue)
        }
    }

    @Published var overlayStyle: OverlayStyle {
        didSet {
            persistSettings()
        }
    }

    @Published var subtitleMode: SubtitleMode {
        didSet {
            persistSettings()
        }
    }

    @Published var subtitleDisplayMode: SubtitleDisplayMode {
        didSet {
            guard oldValue != subtitleDisplayMode else { return }
            persistSettings()
            handleSubtitleDisplayModeChange()
        }
    }

    @Published var glossary: [String: String] {
        didSet {
            cachedInverseGlossary = GlossaryService.buildInverseGlossary(glossary)
            persistSettings()
        }
    }

    init(
        settingsStore: SettingsStore,
        sourceCatalogService: SourceCatalogService
    ) {
        self.settingsStore = settingsStore
        self.sourceCatalogService = sourceCatalogService

        let settings = settingsStore.load()
        self.selectedSourceID = settings.selectedSourceID
        var initialSelectedSourceIDs = Set(settings.selectedSourceIDs)
        if initialSelectedSourceIDs.isEmpty, let selectedSourceID = settings.selectedSourceID {
            initialSelectedSourceIDs = [selectedSourceID]
        }
        self.selectedSourceIDs = initialSelectedSourceIDs
        self.sourceLanguageOverrides = settings.sourceLanguageOverrides
        self.sourceOutputLanguageOverrides = settings.sourceOutputLanguageOverrides
        self.inputLanguageID = settings.inputLanguageID
        self.outputLanguageID = settings.outputLanguageID
        self.conversationPrimaryLanguageID = settings.conversationPrimaryLanguageID
        self.conversationSecondaryLanguageID = settings.conversationSecondaryLanguageID
        self.conversationFaceToFace = settings.conversationFaceToFace
        self.isConversationModeActive = settings.conversationModeActive
        self.usesSystemInterfaceLanguage = settings.interfaceLanguageID == nil
        self.interfaceLanguageID = LanguageCatalog.preferredInterfaceLanguageID(
            storedIdentifier: settings.interfaceLanguageID
        )
        let normalizedOverlayStyle = AppModel.normalizedOverlayStyle(settings.overlayStyle)
        self.overlayStyle = normalizedOverlayStyle
        self.subtitleMode = settings.subtitleMode
        self.subtitleDisplayMode = settings.subtitleDisplayMode
        self.glossary = settings.glossary
        self.cachedInverseGlossary = GlossaryService.buildInverseGlossary(settings.glossary)
        self.translationHostConfiguration = nil
        self.reverseTranslationHostConfiguration = nil
        AppLocalization.updateEmbeddedBundleLocalizationLanguageID(self.interfaceLanguageID)

        translationCoordinator.onConfigurationChange = { [weak self] configuration in
            self?.translationHostConfiguration = configuration
        }
        translationCoordinator.localeIdentifierForLanguageID = { [weak self] languageID in
            self?.translationLocaleIdentifier(for: languageID)
                ?? LanguageCatalog.translationLocaleIdentifier(for: languageID)
        }
        reverseTranslationCoordinator.onConfigurationChange = { [weak self] configuration in
            self?.reverseTranslationHostConfiguration = configuration
        }
        reverseTranslationCoordinator.localeIdentifierForLanguageID = { [weak self] languageID in
            self?.translationLocaleIdentifier(for: languageID)
                ?? LanguageCatalog.translationLocaleIdentifier(for: languageID)
        }
        installTranslationFallbacks(on: translationCoordinator)
        installTranslationFallbacks(on: reverseTranslationCoordinator)
        reloadSpeechCorrections()
        Logger.caption.notice("caption-log-ready")

        isBootstrapping = false
        applyStatusMessage()
        if normalizedOverlayStyle != settings.overlayStyle {
            persistSettings()
        }
        refreshSources()
        refreshSupportedLanguageOptions()
    }

    func installTranslationFallbacks(on coordinator: TranslationCoordinator) {
        coordinator.fallbackPrepare = { [weak self] source, target in
            guard let self else {
                throw TranslationCoordinator.ServiceError.unavailableOnSystem
            }
            try await self.prepareTranslationFallback(from: source, to: target)
        }
        coordinator.fallbackTranslate = { [weak self] text, source, target in
            guard let self else {
                throw TranslationCoordinator.ServiceError.unavailableOnSystem
            }
            return try await self.translateWithFallback(text, from: source, to: target)
        }
    }
    @available(iOS 26.0, macOS 26.0, *)
    func applySpeechSupport(to engine: ConversationEngine) {
        reloadSpeechCorrections()
        engine.speechCorrections = speechCorrections
        engine.glossary = glossary
        engine.recognitionContextualStrings = recognitionContextualStrings(
            for: [engine.primaryLanguageID, engine.secondaryLanguageID],
            glossaryPhrases: Array(glossary.keys)
        )
    }

    @available(iOS 26.0, macOS 26.0, *)
    func installTranslationFallbacks(on engine: ConversationEngine) {
        engine.installTranslationFallbacks(
            prepare: { [weak self] source, target in
                guard let self else {
                    throw TranslationCoordinator.ServiceError.unavailableOnSystem
                }
                try await self.prepareTranslationFallback(from: source, to: target)
            },
            translate: { [weak self] text, source, target in
                guard let self else {
                    throw TranslationCoordinator.ServiceError.unavailableOnSystem
                }
                return try await self.translateWithFallback(text, from: source, to: target)
            }
        )
    }

    private func prepareTranslationFallback(from source: String, to target: String) async throws {
#if os(macOS)
        if MelongCaption.isTibetanLanguageID(source)
            || MelongCaption.isTibetanLanguageID(target)
        {
            do {
                try await melongOmlxService.prepare(from: source, to: target)
                return
            } catch {
                // Sidecar down. Skip AFM: it hallucinates Tibetan.
            }
#if canImport(CoreAILanguageModels) && canImport(SentencepieceTokenizer)
            if #available(macOS 27.0, *) {
                try await translateGemmaService.prepare(from: source, to: target)
                return
            }
#endif
            throw TranslationCoordinator.ServiceError.unsupportedPair(source, target)
        }
#endif
#if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            do {
                try await FoundationModelsTranslationService().prepare(from: source, to: target)
                return
            } catch {
                // Fall through to TranslateGemma when AFM is off or not ready.
            }
        }
#endif
#if os(macOS) && canImport(CoreAILanguageModels) && canImport(SentencepieceTokenizer)
        if #available(macOS 27.0, *) {
            try await translateGemmaService.prepare(from: source, to: target)
            return
        }
#endif
        throw TranslationCoordinator.ServiceError.unsupportedPair(source, target)
    }

    private func translateWithFallback(
        _ text: String,
        from source: String,
        to target: String
    ) async throws -> String {
#if os(macOS)
        if MelongCaption.isTibetanLanguageID(source)
            || MelongCaption.isTibetanLanguageID(target)
        {
            do {
                return try await melongOmlxService.translate(text, from: source, to: target)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Sidecar miss. Skip AFM: it hallucinates Tibetan.
            }
#if canImport(CoreAILanguageModels) && canImport(SentencepieceTokenizer)
            if #available(macOS 27.0, *) {
                return try await translateGemmaService.translate(text, from: source, to: target)
            }
#endif
            throw TranslationCoordinator.ServiceError.unsupportedPair(source, target)
        }
#endif
#if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            do {
                return try await FoundationModelsTranslationService().translate(
                    text,
                    from: source,
                    to: target
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Refusal / empty / unavailable → Gemma when present.
            }
        }
#endif
#if os(macOS) && canImport(CoreAILanguageModels) && canImport(SentencepieceTokenizer)
        if #available(macOS 27.0, *) {
            return try await translateGemmaService.translate(text, from: source, to: target)
        }
#endif
        throw TranslationCoordinator.ServiceError.unsupportedPair(source, target)
    }

    convenience init() {
        self.init(
            settingsStore: SettingsStore(),
            sourceCatalogService: SourceCatalogService()
        )
    }

    var allSources: [InputSource] {
        applicationSources + microphoneSources
    }

    var selectedSource: InputSource? {
        allSources.first(where: { $0.id == selectedSourceID })
    }

    var selectedSources: [InputSource] {
        let selectedSourceIDs = self.selectedSourceIDs
        guard selectedSourceIDs.isEmpty == false else {
            return selectedSource.map { [$0] } ?? []
        }

        return allSources.filter { selectedSourceIDs.contains($0.id) }
    }

    var selectedSourceDisplayName: String {
        sourceDisplayName(for: selectedSources)
    }

    /// Name for the sources that are actually capturing, falling back to the selection
    /// while no session is running. Status text uses this so a session that started
    /// with only some of the selected inputs does not claim to be using all of them.
    private var activeSourceDisplayName: String {
        activeSources.isEmpty ? selectedSourceDisplayName : sourceDisplayName(for: activeSources)
    }

    private func sourceDisplayName(for sources: [InputSource]) -> String {
        switch sources.count {
        case 0:
            return localized(.selectedSource)
        case 1:
            return sources[0].name
        default:
            if sources.count == allSources.count, allSources.isEmpty == false {
                return localized(.allSources)
            }
            return AppLocalization.multipleSourcesText(
                count: sources.count,
                languageID: resolvedInterfaceLanguageID
            )
        }
    }

    func languageID(for source: InputSource) -> String {
        sourceLanguageOverrides[source.id] ?? inputLanguageID
    }

    func languageOverrideID(for source: InputSource) -> String? {
        sourceLanguageOverrides[source.id]
    }

    func setLanguageID(_ languageID: String, for source: InputSource) {
        var overrides = sourceLanguageOverrides
        let normalizedLanguageID = supportedSpeechInputLanguageID(languageID)
        if normalizedLanguageID == inputLanguageID {
            overrides.removeValue(forKey: source.id)
        } else {
            overrides[source.id] = normalizedLanguageID
        }
        sourceLanguageOverrides = overrides
    }

    func setLanguageOverrideID(_ languageID: String?, for source: InputSource) {
        guard let languageID else {
            var overrides = sourceLanguageOverrides
            overrides.removeValue(forKey: source.id)
            sourceLanguageOverrides = overrides
            return
        }

        setLanguageID(languageID, for: source)
    }

    func outputLanguageIDForSource(_ source: InputSource) -> String {
        if languageID(for: source) == "nan" {
            return "zh-Hant"
        }
        return sourceOutputLanguageOverrides[source.id] ?? outputLanguageID
    }

    func outputLanguageOverrideID(for source: InputSource) -> String? {
        sourceOutputLanguageOverrides[source.id]
    }

    func setOutputLanguageID(_ languageID: String, for source: InputSource) {
        var overrides = sourceOutputLanguageOverrides
        if self.languageID(for: source) == "nan" {
            if outputLanguageID == "zh-Hant" {
                overrides.removeValue(forKey: source.id)
            } else {
                overrides[source.id] = "zh-Hant"
            }
        } else if languageID == outputLanguageID {
            overrides.removeValue(forKey: source.id)
        } else {
            overrides[source.id] = languageID
        }
        sourceOutputLanguageOverrides = overrides
    }

    func setOutputLanguageOverrideID(_ languageID: String?, for source: InputSource) {
        guard let languageID else {
            var overrides = sourceOutputLanguageOverrides
            overrides.removeValue(forKey: source.id)
            sourceOutputLanguageOverrides = overrides
            return
        }

        setOutputLanguageID(languageID, for: source)
    }

    var isSessionStarting: Bool {
        startingTranscriptionSessions.isEmpty == false
    }

    var sessionButtonTitle: String {
        if sessionState == .running || isSessionStarting {
            return localized(.stop)
        }

        if isPreparingSelectedLanguageResources {
            return localized(.wait)
        }

        if hasBlockingLanguageResourceStatuses {
            return localized(.pleaseDownloadLanguageResource)
        }

        return localized(.start)
    }

    var sessionButtonSymbolName: String {
        sessionState == .running || isSessionStarting ? "stop.fill" : "play.fill"
    }

    var showsSessionWaitIndicator: Bool {
        sessionState != .running
            && (isSessionStarting || isPreparingSelectedLanguageResources)
    }

    var isSessionButtonDisabled: Bool {
        if sessionState == .running || isSessionStarting {
            return false
        }

        return selectedSources.isEmpty
            || isPreparingSelectedLanguageResources
            || hasBlockingLanguageResourceStatuses
    }

    var sessionBadgeText: String {
        sessionState.displayName(in: resolvedInterfaceLanguageID)
    }

    var isLanguagePairLocked: Bool {
        sessionState == .running || isSessionStarting
    }

    var resolvedInterfaceLanguageID: String {
        LanguageCatalog.preferredInterfaceLanguageID(storedIdentifier: interfaceLanguageID)
    }

    var interfaceLocale: Locale {
        AppLocalization.locale(for: resolvedInterfaceLanguageID)
    }

    var appVersionDisplayText: String {
        "v\(AppBuildInfo.marketingVersion)"
    }

    var appRepositoryURL: URL? {
#if os(macOS)
        AppBuildInfo.repositoryURL
#else
        nil
#endif
    }

    var showsOriginalSubtitle: Bool {
        subtitleDisplayMode.showsOriginalSubtitle
    }

    var showsTranslatedSubtitle: Bool {
        subtitleDisplayMode.showsTranslatedSubtitle
    }

    func localized(_ key: AppTextKey, _ arguments: CVarArg...) -> String {
        AppLocalization.formattedString(key, languageID: resolvedInterfaceLanguageID, arguments: arguments)
    }

    private var listeningPlaceholderText: String {
        localized(.listening)
    }

    private var captureStoppedText: String {
        localized(.captureStopped)
    }

    private var unableToStartText: String {
        localized(.unableToStart)
    }

    private var previewInputSource: InputSource {
        InputSource(
            id: InputSource.preview.id,
            name: localized(.previewSource),
            detail: InputSource.preview.detail,
            category: InputSource.preview.category
        )
    }

    private func localizedErrorDescription(_ error: Error) -> String {
        AppLocalization.localizedErrorDescription(error, languageID: resolvedInterfaceLanguageID)
    }

    private func setStatus(_ descriptor: StatusDescriptor) {
        guard statusDescriptor != descriptor else {
            return
        }

        statusDescriptor = descriptor
        applyStatusMessage()
    }

    private func applyStatusMessage() {
        let message: String

        switch statusDescriptor {
        case .ready:
            message = localized(.ready)
        case .noInputSourcesDetected:
            message = localized(.noSourcesDetected) + "."
        case .running(let sourceName):
            message = localized(.runningOnFormat, sourceName)
        case .chooseInputSourceBeforeStarting:
            message = localized(.chooseInputSourceBeforeStarting)
        case .checkingLanguageResources:
            message = localized(.checkingLanguageResources)
        case .downloadLanguageResourcesInSystemSettings:
            message = localized(.downloadRequiredLanguageResourcesSystemSettings)
        case .preparing(let sourceName):
            message = localized(.preparingSourceFormat, sourceName)
        case .showingOverlayPreview:
            message = localized(.showingOverlayPreview)
        case .custom(let customMessage):
            message = customMessage
        }

        guard statusMessage != message else {
            return
        }

        statusMessage = message
    }

    private func relocalizeInterface(from oldLanguageID: String) {
        applyStatusMessage()
        relocalizeOverlaySentinelTexts(from: oldLanguageID)

        if liveTranscriptionSession == nil,
           sessionState != .error,
           (isOverlayVisible || isAudienceDisplayVisible) {
            syncOverlayPreviewIfNeeded()
        }

        if languageResourcePreparationTask == nil, languageResourceStatuses.isEmpty == false {
            scheduleSelectedLanguageResourcePreparation(openSystemSettingsIfNeeded: false)
        }
    }

    private func relocalizeOverlaySentinelTexts(from oldLanguageID: String) {
        guard var overlayState else { return }

        let oldListening = AppLocalization.string(.listening, languageID: oldLanguageID)
        let oldCaptureStopped = AppLocalization.string(.captureStopped, languageID: oldLanguageID)
        let oldUnableToStart = AppLocalization.string(.unableToStart, languageID: oldLanguageID)

        if overlayState.translatedText == oldListening {
            overlayState.translatedText = listeningPlaceholderText
        } else if overlayState.translatedText == oldCaptureStopped {
            overlayState.translatedText = captureStoppedText
        } else if overlayState.translatedText == oldUnableToStart {
            overlayState.translatedText = unableToStartText
        }

        self.overlayState = overlayState
    }

    func refreshSources() {
        let snapshot = sourceCatalogService.loadSnapshot()
        if applicationSources != snapshot.applications {
            applicationSources = snapshot.applications
        }
        if microphoneSources != snapshot.microphones {
            microphoneSources = snapshot.microphones
        }

        let availableSources = snapshot.applications + snapshot.microphones
        let availableSourceIDs = Set(availableSources.map(\.id))
        let retainedSelectedSourceIDs = selectedSourceIDs.intersection(availableSourceIDs)

        if retainedSelectedSourceIDs != selectedSourceIDs {
            selectedSourceIDs = retainedSelectedSourceIDs
        }

        if selectedSourceIDs.isEmpty, let firstSourceID = availableSources.first?.id {
            selectedSourceIDs = [firstSourceID]
        }

        let primarySourceID = preferredPrimarySourceID(for: selectedSourceIDs)
        if selectedSourceID != primarySourceID {
            selectedSourceID = primarySourceID
        }

        if sessionState == .running {
            setStatus(.running(sourceName: activeSourceDisplayName))
        } else {
            setStatus(availableSources.isEmpty ? .noInputSourcesDetected : .ready)
        }
    }

    func toggleSession() {
        if sessionState == .running || isSessionStarting {
            stopSession()
        } else {
            Task {
                await startSession()
            }
        }
    }

    func startSession() async {
        sessionStartGeneration &+= 1
        let startGeneration = sessionStartGeneration
        // Finish releasing any earlier capture resources before opening replacements.
        await stopLiveTranscriptionSessionsAndWait()
        guard startGeneration == sessionStartGeneration else { return }
        refreshSources()

        let selectedSources = self.selectedSources
        guard selectedSources.isEmpty == false else {
            sessionState = .error
            setStatus(.chooseInputSourceBeforeStarting)
            return
        }
        let selectedSourceName = selectedSourceDisplayName

        resetLiveTextPipeline()
        setStatus(.checkingLanguageResources)
        await awaitSelectedLanguageResourcePreparationIfNeeded()
        guard startGeneration == sessionStartGeneration else { return }
        guard hasBlockingLanguageResourceStatuses == false else {
            setStatus(.downloadLanguageResourcesInSystemSettings)
            return
        }

        let previousTranscriptEntries = transcriptEntries
        let previousTranscriptInputLanguageID = transcriptInputLanguageID
        let previousTranscriptOutputLanguageID = transcriptOutputLanguageID
        let selectedTranscriptLanguages = transcriptLanguageIDs(for: selectedSources)
        resetTranscript(
            sourceLanguageID: selectedTranscriptLanguages.source,
            targetLanguageID: selectedTranscriptLanguages.target
        )

        isOverlayVisible = true
        overlayState = OverlayPreviewState(
            translatedText: listeningPlaceholderText,
            sourceText: localized(.waitingForAudioFromFormat, selectedSourceName),
            sourceName: selectedSourceName
        )
        overlayHistoryScrollOffset = 0
        setStatus(.preparing(sourceName: selectedSourceName))

        let config = ModeConfig.config(for: subtitleMode)
        reloadSpeechCorrections()
        var startedSessions: [LiveTranscriptionSession] = []
        var startedSources: [InputSource] = []
        var startupFailures: [Error] = []
        var fatalSessionErrors: [(message: String, sessionID: ObjectIdentifier, sourceName: String)] = []
        var isStartingSession = true

        for source in selectedSources {
            let sourceLanguageID = languageID(for: source)
            let targetLanguageID = outputLanguageIDForSource(source)
            // Breeze-ASR-26 hears Taigi but deliberately emits Mandarin Chinese
            // characters rather than native Taibun. Apple Translation must therefore
            // consume that transcript as zh-Hant, while the UI still labels the input
            // language as Taigi.
            let translationSourceLanguageID =
                translationSourceLanguageID(for: sourceLanguageID)
            let primaryRecognitionHints = recognitionContextualStrings(
                for: [translationSourceLanguageID],
                glossaryPhrases: Array(glossary.keys)
            )
            let secondaryRecognitionHints = CaptionLanguagePolicy.shouldEnableDualLane(
                sourceLanguageID: translationSourceLanguageID,
                targetLanguageID: targetLanguageID
            ) ? recognitionContextualStrings(
                for: ["en"],
                glossaryPhrases: Array(glossary.values)
            ) : []
            liveCaptionConfiguredSourceLanguageID = translationSourceLanguageID
            liveCaptionConfiguredTargetLanguageID = targetLanguageID
            let session = LiveTranscriptionSession()
            // Identity only. Capturing the session in the handler it is about to own
            // would retain it for the session's own lifetime.
            let sessionID = ObjectIdentifier(session)
            startingTranscriptionSessions.append(session)

            if sourceLanguageID == "nan" {
                setStatus(.custom(localized(.taigiPreparingModel)))
            }
#if os(macOS)
            if sourceLanguageID == "bo" {
                setStatus(.custom(localized(.tibetanPreparingModel)))
            }
#endif
            do {
                try await session.start(
                    source: source,
                    localeIdentifier: speechLocaleIdentifier(for: sourceLanguageID),
                    interfaceLanguageID: resolvedInterfaceLanguageID,
                    modeConfig: config,
                    contextualStrings: primaryRecognitionHints,
                    secondaryContextualStrings: secondaryRecognitionHints,
                    sourceLanguageID: translationSourceLanguageID,
                    targetLanguageID: targetLanguageID,
                    speechCorrections: speechCorrections,
                    transcriptHandler: { [weak self] sentence in
                        let heardLanguageID = sentence.heardLanguageID.isEmpty
                            ? translationSourceLanguageID
                            : sentence.heardLanguageID
                        let usesInverseGlossary = CaptionLanguagePolicy.shouldReverse(
                            configuredSourceLanguageID: translationSourceLanguageID,
                            configuredTargetLanguageID: targetLanguageID,
                            heardLanguageID: heardLanguageID,
                            heardText: sentence.text,
                            evidence: sentence.dualLaneEvidence
                        )
                        self?.enqueueRecognizedSentence(
                            sentence,
                            source: source,
                            sourceLanguageID: heardLanguageID,
                            targetLanguageID: CaptionLanguagePolicy.translationTarget(
                                heardLanguageID: heardLanguageID,
                                configuredSourceLanguageID: translationSourceLanguageID,
                                configuredTargetLanguageID: targetLanguageID,
                                heardText: sentence.text,
                                evidence: sentence.dualLaneEvidence
                            ),
                            usesInverseGlossary: usesInverseGlossary
                        )
                    },
                    partialHandler: { [weak self] draft in
                        let heardLanguageID = draft?.heardLanguageID.isEmpty == false
                            ? (draft?.heardLanguageID ?? translationSourceLanguageID)
                            : translationSourceLanguageID
                        self?.handlePartialDraft(
                            draft,
                            source: source,
                            sourceLanguageID: heardLanguageID,
                            targetLanguageID: CaptionLanguagePolicy.translationTarget(
                                heardLanguageID: heardLanguageID,
                                configuredSourceLanguageID: translationSourceLanguageID,
                                configuredTargetLanguageID: targetLanguageID,
                                heardText: draft?.sourceText ?? "",
                                evidence: nil
                            )
                        )
                    },
                    errorHandler: { [weak self] message in
                        self?.sessionState = .error
                        self?.setStatus(.custom(message))
                        self?.overlayState = OverlayPreviewState(
                            translatedText: self?.captureStoppedText ?? "",
                            sourceText: message,
                            sourceName: source.name
                        )
                    },
                    fatalErrorHandler: { [weak self] message in
                        guard let self else { return }
                        // While startSession() owns the state machine it decides what a
                        // fatal error means: a source that never finished starting is
                        // only that source's failure, not the whole session's. Recording
                        // the origin lets it tell those apart. Afterwards the failure is
                        // live and ends the session immediately.
                        guard isStartingSession else {
                            self.handleFatalSessionError(message, sourceName: source.name)
                            return
                        }
                        fatalSessionErrors.append((message, sessionID, source.name))
                    }
                )
                startingTranscriptionSessions.removeAll {
                    ObjectIdentifier($0) == sessionID
                }
                guard startGeneration == sessionStartGeneration else {
                    await session.stopAndWait()
                    isStartingSession = false
                    restoreTranscript(
                        entries: previousTranscriptEntries,
                        sourceLanguageID: previousTranscriptInputLanguageID,
                        targetLanguageID: previousTranscriptOutputLanguageID
                    )
                    return
                }

                startedSessions.append(session)
                startedSources.append(source)
            } catch {
                startingTranscriptionSessions.removeAll {
                    ObjectIdentifier($0) == sessionID
                }
                if error is CancellationError
                    || startGeneration != sessionStartGeneration {
                    isStartingSession = false
                    restoreTranscript(
                        entries: previousTranscriptEntries,
                        sourceLanguageID: previousTranscriptInputLanguageID,
                        targetLanguageID: previousTranscriptOutputLanguageID
                    )
                    return
                }
                // A multi-source session is usable as long as at least one input starts.
                await session.stopAndWait()
                startupFailures.append(error)
            }

            // Recognition tasks can fail fatally while this iteration is suspended, on
            // either the success or the failure path, and more than one can land here.
            let pendingFatalErrors = fatalSessionErrors
            fatalSessionErrors.removeAll()

            // A source that did start has died. Stop the siblings here — the handler
            // cannot, because startSession() has not published them yet — and report the
            // failure rather than overwriting it with .running below. This wins over any
            // tolerable failure in the same batch, whatever order they arrived in.
            if let fatal = pendingFatalErrors.first(where: { fatal in
                startedSessions.contains(where: { ObjectIdentifier($0) == fatal.sessionID })
            }) {
                isStartingSession = false
                for startedSession in startedSessions {
                    startedSession.stop()
                }
                handleFatalSessionError(fatal.message, sourceName: fatal.sourceName)
                return
            }

            // What is left came from sources that never opened their capture, so they are
            // not part of the session: record them and carry on with the selections that
            // have not been tried yet.
            for fatal in pendingFatalErrors {
                startupFailures.append(SessionStartupFailure(message: fatal.message))
            }
        }

        isStartingSession = false
        guard startGeneration == sessionStartGeneration else {
            for session in startedSessions {
                await session.stopAndWait()
            }
            restoreTranscript(
                entries: previousTranscriptEntries,
                sourceLanguageID: previousTranscriptInputLanguageID,
                targetLanguageID: previousTranscriptOutputLanguageID
            )
            return
        }

        if startedSessions.isEmpty == false {
            liveTranscriptionSessions = startedSessions
            liveTranscriptionSession = startedSessions.first
            activeSources = startedSources

            // Sources that never opened must not describe the transcript. Retag it from
            // the inputs that actually run, so a lone survivor's language is not left
            // masked by the mixed-selection fallback that summarization reads.
            let activeTranscriptLanguages = transcriptLanguageIDs(for: startedSources)
            updateTranscriptLanguages(
                sourceLanguageID: activeTranscriptLanguages.source,
                targetLanguageID: activeTranscriptLanguages.target
            )

            sessionState = .running
            let activeSourceName = activeSourceDisplayName
            setStatus(.running(sourceName: activeSourceName))

            // Inputs that never opened are tolerated, but not hidden: log every failure
            // and show the first one in the overlay so a partially started session is
            // recognizable. Leave the overlay alone once real audio has replaced the
            // placeholder, which can happen while a later source is still starting.
            for failure in startupFailures {
                Logger.session.error("Input source failed to start: \(self.localizedErrorDescription(failure))")
            }
            if let failure = startupFailures.first,
               overlayState?.translatedText == listeningPlaceholderText {
                overlayState = OverlayPreviewState(
                    translatedText: listeningPlaceholderText,
                    sourceText: localizedErrorDescription(failure),
                    sourceName: activeSourceName
                )
                overlayHistoryScrollOffset = 0
            }
            return
        }

        resetLiveTextPipeline()
        liveTranscriptionSession = nil
        liveTranscriptionSessions.removeAll()
        activeSources.removeAll()
        restoreTranscript(
            entries: previousTranscriptEntries,
            sourceLanguageID: previousTranscriptInputLanguageID,
            targetLanguageID: previousTranscriptOutputLanguageID
        )
        sessionState = .error
        let localizedError = startupFailures.first.map(localizedErrorDescription)
            ?? unableToStartText
        setStatus(.custom(localizedError))
        overlayState = OverlayPreviewState(
            translatedText: unableToStartText,
            sourceText: localizedError,
            sourceName: selectedSourceName
        )
        overlayHistoryScrollOffset = 0
    }

    /// Ends a running session after one of its inputs failed unrecoverably. One input
    /// failing ends the logical session, so its siblings stop before the global
    /// "capture stopped" state is shown.
    private func handleFatalSessionError(_ message: String, sourceName: String) {
        stopLiveTranscriptionSessions()
        sessionState = .error
        setStatus(.custom(message))
        overlayState = OverlayPreviewState(
            translatedText: captureStoppedText,
            sourceText: message,
            sourceName: sourceName
        )
    }

    func stopSession() {
        sessionStartGeneration &+= 1
        resetLiveTextPipeline()
        stopLiveTranscriptionSessions()
        sessionState = .idle
        setStatus(allSources.isEmpty ? .noInputSourcesDetected : .ready)
        isOverlayVisible = false
        overlayState = nil
    }

    private func stopLiveTranscriptionSessions() {
        let sessions = takeLiveTranscriptionSessions()
        for session in sessions {
            session.stop()
        }
    }

    private func stopLiveTranscriptionSessionsAndWait() async {
        let sessions = takeLiveTranscriptionSessions()
        for session in sessions {
            await session.stopAndWait()
        }
    }

    /// Detaches the current sessions atomically on the main actor. The returned strong
    /// references keep them alive until their callers have scheduled or completed stop.
    private func takeLiveTranscriptionSessions() -> [LiveTranscriptionSession] {
        var candidates = startingTranscriptionSessions
        if liveTranscriptionSessions.isEmpty {
            if let liveTranscriptionSession {
                candidates.append(liveTranscriptionSession)
            }
        } else {
            candidates.append(contentsOf: liveTranscriptionSessions)
        }
        var seen = Set<ObjectIdentifier>()
        let sessions = candidates.filter {
            seen.insert(ObjectIdentifier($0)).inserted
        }

        liveTranscriptionSessions.removeAll()
        liveTranscriptionSession = nil
        startingTranscriptionSessions.removeAll()
        activeSources.removeAll()
        return sessions
    }

    func showOverlayPreview() {
        let source = selectedSource ?? previewInputSource
        overlayState = makePreviewState(for: source)
        overlayHistoryScrollOffset = 0
        isOverlayVisible = true

        if sessionState != .running {
            setStatus(.showingOverlayPreview)
        }
    }

    func toggleOverlayVisibility() {
        if isOverlayVisible {
            isOverlayVisible = false
            if sessionState != .running && isAudienceDisplayVisible == false {
                overlayState = nil
                setStatus(allSources.isEmpty ? .noInputSourcesDetected : .ready)
            }
        } else {
            showOverlayPreview()
        }
    }

    func showAudienceDisplay() {
        if overlayState == nil {
            let source = selectedSource ?? previewInputSource
            overlayState = makePreviewState(for: source)
            overlayHistoryScrollOffset = 0
        }
        isAudienceDisplayVisible = true
        if sessionState != .running {
            setStatus(.showingOverlayPreview)
        }
    }

    func hideAudienceDisplay() {
        guard isAudienceDisplayVisible else { return }
        isAudienceDisplayVisible = false
        if sessionState != .running && isOverlayVisible == false {
            overlayState = nil
            setStatus(allSources.isEmpty ? .noInputSourcesDetected : .ready)
        }
    }

    func toggleAudienceDisplayVisibility() {
        if isAudienceDisplayVisible {
            hideAudienceDisplay()
        } else {
            showAudienceDisplay()
        }
    }

    func updateOverlayStyle(_ update: (inout OverlayStyle) -> Void) {
        var style = overlayStyle
        update(&style)
        overlayStyle = AppModel.normalizedOverlayStyle(style)
    }

    func updateOverlayHistoryVisibleCount(_ count: Int) {
        let clampedCount = max(0, count)
        guard overlayHistoryVisibleCount != clampedCount else { return }
        overlayHistoryVisibleCount = clampedCount
        clampOverlayHistoryScrollOffset()
    }

    func scrollOverlayHistory(by delta: Int) {
        guard delta != 0 else { return }
        setOverlayHistoryScrollOffset(overlayHistoryScrollOffset + delta)
    }

    func setOverlayHistoryScrollOffset(_ offset: Int) {
        let clampedOffset = min(max(offset, 0), overlayHistoryMaxScrollOffset)
        guard overlayHistoryScrollOffset != clampedOffset else { return }
        overlayHistoryScrollOffset = clampedOffset
    }

    func persistSettings() {
        guard isBootstrapping == false else {
            return
        }

        let settings = AppSettings(
            selectedSourceID: selectedSourceID,
            selectedSourceIDs: orderedSelectedSourceIDs(),
            sourceLanguageOverrides: sourceLanguageOverrides,
            sourceOutputLanguageOverrides: sourceOutputLanguageOverrides,
            inputLanguageID: inputLanguageID,
            outputLanguageID: outputLanguageID,
            conversationPrimaryLanguageID: conversationPrimaryLanguageID,
            conversationSecondaryLanguageID: conversationSecondaryLanguageID,
            conversationFaceToFace: conversationFaceToFace,
            conversationModeActive: isConversationModeActive,
            interfaceLanguageID: usesSystemInterfaceLanguage ? nil : interfaceLanguageID,
            overlayStyle: overlayStyle,
            subtitleMode: subtitleMode,
            subtitleDisplayMode: subtitleDisplayMode,
            glossary: glossary
        )

        settingsStore.save(settings)
    }

    private static func normalizedOverlayStyle(_ style: OverlayStyle) -> OverlayStyle {
        var normalized = style
        normalized.translatedFirst = true
        return normalized
    }

    private func reloadSpeechCorrections() {
        do {
            speechCorrections = try SpeechCorrectionService.loadDefault()
        } catch {
            speechCorrections = .empty
            setStatus(.custom(String(describing: error)))
        }
    }

    private func recognitionContextualStrings(
        for languageIDs: [String],
        glossaryPhrases: [String]
    ) -> [String] {
        SpeechCorrectionService.recognitionPhrases(
            corrections: speechCorrections,
            languageIDs: languageIDs,
            glossaryKeys: glossaryPhrases
        )
    }

    private func translationCoordinator(from sourceLanguageID: String, to targetLanguageID: String) -> TranslationCoordinator {
        if LanguageIdentity.isEnglish(sourceLanguageID),
           CaptionLanguagePolicy.shouldEnableDualLane(
            sourceLanguageID: liveCaptionConfiguredSourceLanguageID,
            targetLanguageID: liveCaptionConfiguredTargetLanguageID
           ) {
            return reverseTranslationCoordinator
        }
        return translationCoordinator
    }

    private func languagePanes(
        heard: String,
        translated: String,
        usesInverseGlossary: Bool
    ) -> (sourceText: String, translatedText: String) {
        usesInverseGlossary
            ? (sourceText: translated, translatedText: heard)
            : (sourceText: heard, translatedText: translated)
    }

    func languageName(for identifier: String) -> String {
        LanguageCatalog.displayName(for: identifier, in: resolvedInterfaceLanguageID)
    }

    func supportedSpeechInputLanguageID(_ identifier: String) -> String {
        speechLanguageOptions.contains(where: { $0.id == identifier }) ? identifier : "en"
    }

    /// Names the selected speech languages that this Mac can only recognize through
    /// Apple's servers, or nil when everything selected stays on device.
    var serverSpeechRecognitionNotice: String? {
        let selectedLanguageIDs = selectedSources.isEmpty
            ? [inputLanguageID]
            : selectedSources.map { languageID(for: $0) }

        let serverLanguageIDs = Set(selectedLanguageIDs).subtracting(onDeviceSpeechLanguageIDs)
        guard serverLanguageIDs.isEmpty == false else {
            return nil
        }

        let names = serverLanguageIDs
            .map { languageName(for: $0) }
            .sorted()
            .joined(separator: ", ")

        return localized(.speechUsesAppleServersFormat, names)
    }

    private func speechLocaleIdentifier(for languageID: String) -> String {
        speechLanguageOptions.first(where: { $0.id == languageID })?.localeIdentifier
            ?? LanguageCatalog.speechLocaleIdentifier(for: languageID)
    }

    private func translationLocaleIdentifier(for languageID: String) -> String {
        translationLanguageOptions.first(where: { $0.id == languageID })?.localeIdentifier
            ?? LanguageCatalog.translationLocaleIdentifier(for: languageID)
    }

    private func translationSourceLanguageID(for speechLanguageID: String) -> String {
        speechLanguageID == "nan" ? "zh-Hant" : speechLanguageID
    }

    private func refreshSupportedLanguageOptions() {
        languageCatalogRefreshTask?.cancel()
        languageCatalogRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let resolvedSpeechCatalog = await self.loadSupportedSpeechLanguageOptions()
            let resolvedSpeechOptions = resolvedSpeechCatalog.options
            let resolvedTranslationOptions = await self.loadSupportedTranslationLanguageOptions()
            guard Task.isCancelled == false else { return }

            isRefreshingLanguageCatalogs = true
            defer { isRefreshingLanguageCatalogs = false }

            if resolvedSpeechOptions.isEmpty == false {
                speechLanguageOptions = resolvedSpeechOptions
                onDeviceSpeechLanguageIDs = resolvedSpeechCatalog.onDeviceLanguageIDs
                let supportedIDs = Set(resolvedSpeechOptions.map(\.id))
                sourceLanguageOverrides = sourceLanguageOverrides.filter {
                    supportedIDs.contains($0.value)
                }
                if supportedIDs.contains(inputLanguageID) == false {
                    inputLanguageID = resolvedSpeechOptions.first(where: { $0.id == "en" })?.id
                        ?? resolvedSpeechOptions[0].id
                }
            }

            if resolvedTranslationOptions.isEmpty == false {
                translationLanguageOptions = resolvedTranslationOptions
                let supportedIDs = Set(resolvedTranslationOptions.map(\.id))
                sourceOutputLanguageOverrides = sourceOutputLanguageOverrides.filter {
                    supportedIDs.contains($0.value)
                }
                if supportedIDs.contains(outputLanguageID) == false {
                    outputLanguageID = resolvedTranslationOptions.first(where: { $0.id == "en" })?.id
                        ?? resolvedTranslationOptions[0].id
                }
            }
        }
    }

    private func loadSupportedSpeechLanguageOptions() async -> SpeechLanguageCatalog {
        var locales: [Locale] = []
        // Locales that can be recognized without leaving the Mac. A language keeps only
        // one locale, so these have to outrank the rest — otherwise a variant with no
        // local model could win a language and push the whole session onto Apple's
        // speech service.
        var onDeviceLocaleIdentifiers: Set<String> = []

        if #available(macOS 26.0, *), SpeechTranscriber.isAvailable {
            let modernLocales = await SpeechTranscriber.supportedLocales
            locales.append(contentsOf: modernLocales)
            onDeviceLocaleIdentifiers.formUnion(modernLocales.map(\.identifier))
        }

#if canImport(WhisperKit)
        // Breeze-ASR-26 is a bundled, local Whisper model. Expose Taigi only when the
        // complete model folder is present, so a checkout that has not run the
        // deterministic fetch script never advertises a non-working language.
        if Bundle.main.url(forResource: "BreezeASR26", withExtension: nil) != nil {
            let taigiLocale = Locale(identifier: "nan-TW")
            locales.append(taigiLocale)
            onDeviceLocaleIdentifiers.insert(taigiLocale.identifier)
        }
#endif
#if os(macOS) && canImport(WhisperKit)
        if Bundle.main.url(
            forResource: "MonlamWhisperTibetan",
            withExtension: nil
        ) != nil {
            let tibetanLocale = Locale(identifier: "bo")
            locales.append(tibetanLocale)
            onDeviceLocaleIdentifiers.insert(tibetanLocale.identifier)
        }
#endif

        // Keep server-capable legacy locales available on macOS, where upstream
        // deliberately discloses that tradeoff. The iOS fork promises local-only
        // transcription: on iOS a legacy locale is selectable only when the device
        // confirms an on-device model for that exact locale.
        for locale in SFSpeechRecognizer.supportedLocales() {
            let supportsOnDeviceRecognition =
                SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition == true
#if os(iOS)
            guard supportsOnDeviceRecognition else {
                continue
            }
#endif
            locales.append(locale)
            if supportsOnDeviceRecognition {
                onDeviceLocaleIdentifiers.insert(locale.identifier)
            }
        }

        let options = LanguageCatalog.options(for: locales, preferring: onDeviceLocaleIdentifiers)
        let onDeviceLanguageIDs = options
            .filter { $0.localeIdentifier.map(onDeviceLocaleIdentifiers.contains) ?? false }
            .map(\.id)

        return SpeechLanguageCatalog(options: options, onDeviceLanguageIDs: Set(onDeviceLanguageIDs))
    }

    private func loadSupportedTranslationLanguageOptions() async -> [LanguageOption] {
        guard #available(macOS 15.0, *) else { return [] }
        var options = LanguageCatalog.options(
            for: await LanguageAvailability().supportedLanguages
        )
#if os(macOS) && canImport(CoreAILanguageModels) && canImport(SentencepieceTokenizer)
        // Apple Translation reports bo as .unsupported. AFM (SystemLanguageModel)
        // hallucinates on Tibetan script, so do not advertise bo from AFM availability.
        // TranslateGemma is the only working local bo translator on this desk.
        if Bundle.main.url(forResource: "TranslateGemma", withExtension: nil) != nil,
           options.contains(where: { $0.id == "bo" }) == false {
            options.append(
                LanguageOption(
                    id: "bo",
                    displayName: "Tibetan",
                    localeIdentifier: "bo"
                )
            )
        }
#endif
        return options
    }

    private func preferredPrimarySourceID(for selectedSourceIDs: Set<String>) -> String? {
        if let selectedSourceID, selectedSourceIDs.contains(selectedSourceID) {
            return selectedSourceID
        }

        return allSources.first(where: { selectedSourceIDs.contains($0.id) })?.id
    }

    private func orderedSelectedSourceIDs() -> [String] {
        let orderedSourceIDs = allSources.map(\.id).filter { selectedSourceIDs.contains($0) }
        let remainingSourceIDs = selectedSourceIDs.subtracting(Set(orderedSourceIDs)).sorted()
        return orderedSourceIDs + remainingSourceIDs
    }

    private func selectedResourcePreparationRequirements() -> (
        speechLanguageIDs: [String],
        translationPairs: [LanguagePairRequirement]
    ) {
        let selectedSources = self.selectedSources
        guard selectedSources.isEmpty == false else {
            let translationSource = translationSourceLanguageID(for: inputLanguageID)
            let effectiveOutputLanguageID =
                inputLanguageID == "nan" ? "zh-Hant" : outputLanguageID
            let translationPairs = translationSource == effectiveOutputLanguageID
                ? []
                : [
                    LanguagePairRequirement(
                        sourceLanguageID: translationSource,
                        targetLanguageID: effectiveOutputLanguageID
                    ),
                ]
            let usesLocalSpeechModel = inputLanguageID == "nan" || inputLanguageID == "bo"
            let speechLanguages = usesLocalSpeechModel ? [] : [inputLanguageID]
            return (speechLanguages, translationPairs)
        }

        var speechLanguageIDs = Set(
            selectedSources
                .map { languageID(for: $0) }
                .filter { $0 != "nan" && $0 != "bo" }
        )
        for source in selectedSources {
            let sourceLanguageID = languageID(for: source)
            let targetLanguageID = outputLanguageIDForSource(source)
            if CaptionLanguagePolicy.shouldEnableDualLane(
                sourceLanguageID: sourceLanguageID,
                targetLanguageID: targetLanguageID
            ) {
                speechLanguageIDs.insert("en")
            }
        }
        let sortedSpeechLanguageIDs = speechLanguageIDs.sorted()
        let translationPairs = Set(
            selectedSources.flatMap { source -> [LanguagePairRequirement] in
                let sourceLanguageID = translationSourceLanguageID(
                    for: languageID(for: source)
                )
                let targetLanguageID = outputLanguageIDForSource(source)
                guard sourceLanguageID != targetLanguageID else {
                    return []
                }
                var pairs = [
                    LanguagePairRequirement(
                        sourceLanguageID: sourceLanguageID,
                        targetLanguageID: targetLanguageID
                    )
                ]
                if CaptionLanguagePolicy.shouldEnableDualLane(
                    sourceLanguageID: sourceLanguageID,
                    targetLanguageID: targetLanguageID
                ) {
                    pairs.append(
                        LanguagePairRequirement(
                            sourceLanguageID: targetLanguageID,
                            targetLanguageID: sourceLanguageID
                        )
                    )
                }
                return pairs
            }
        )
        .sorted {
            if $0.sourceLanguageID == $1.sourceLanguageID {
                return $0.targetLanguageID < $1.targetLanguageID
            }
            return $0.sourceLanguageID < $1.sourceLanguageID
        }

        return (sortedSpeechLanguageIDs, translationPairs)
    }

    @available(iOS 18.0, macOS 15.0, *)
    func runTranslationHost(using session: TranslationSession) async {
        await translationCoordinator.run(using: session)
    }

    @available(iOS 18.0, macOS 15.0, *)
    func runReverseTranslationHost(using session: TranslationSession) async {
        await reverseTranslationCoordinator.run(using: session)
    }

    func refreshLanguageResources() {
        scheduleSelectedLanguageResourcePreparation()
    }

    private func scheduleSelectedLanguageResourcePreparation(
        refreshTranslations: Bool = false,
        openSystemSettingsIfNeeded: Bool = false
    ) {
        guard isBootstrapping == false else {
            return
        }

        let requirements = selectedResourcePreparationRequirements()

        languageResourcePreparationTask?.cancel()
        languageResourceStatuses = []

        languageResourcePreparationTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            defer { self.languageResourcePreparationTask = nil }

            await self.prepareSelectedLanguageResources(
                speechLanguageIDs: requirements.speechLanguageIDs,
                translationPairs: requirements.translationPairs,
                openSystemSettingsIfNeeded: openSystemSettingsIfNeeded
            )

            guard Task.isCancelled == false,
                  refreshTranslations,
                  self.hasBlockingLanguageResourceStatuses == false else {
                return
            }

            self.refreshCaptionTranslations()
        }
    }

    private func awaitSelectedLanguageResourcePreparationIfNeeded() async {
        if languageResourcePreparationTask == nil {
            scheduleSelectedLanguageResourcePreparation()
        }

        await languageResourcePreparationTask?.value
    }

    private var isPreparingSelectedLanguageResources: Bool {
        languageResourcePreparationTask != nil
            || languageResourceStatuses.contains(where: { $0.isError == false })
    }

    private var hasBlockingLanguageResourceStatuses: Bool {
        languageResourceStatuses.contains(where: \.isError)
    }

    private func prepareSelectedLanguageResources(
        speechLanguageIDs: [String],
        translationPairs: [LanguagePairRequirement],
        openSystemSettingsIfNeeded: Bool
    ) async {
        var destinationsToOpen = Set<LanguageResourceSystemSettingsDestination>()
        await withTaskGroup(of: LanguageResourceSystemSettingsDestination?.self) { group in
            for speechLanguageID in speechLanguageIDs {
                group.addTask { [weak self] in
                    guard let self else {
                        return nil
                    }

                    return await self.prepareSpeechRecognitionResourceIfNeeded(for: speechLanguageID)
                }
            }

            for translationPair in translationPairs {
                group.addTask { [weak self] in
                    guard let self else {
                        return nil
                    }

                    return await self.prepareTranslationResourceIfNeeded(
                        from: translationPair.sourceLanguageID,
                        to: translationPair.targetLanguageID
                    )
                }
            }

            for await destination in group {
                if let destination {
                    destinationsToOpen.insert(destination)
                }
            }
        }

        guard openSystemSettingsIfNeeded else {
            return
        }

        if destinationsToOpen.contains(.translationLanguages) {
            openSystemSettings(for: .translationLanguages)
        } else if let destination = destinationsToOpen.first {
            openSystemSettings(for: destination)
        }
    }

    private func prepareSpeechRecognitionResourceIfNeeded(
        for languageID: String
    ) async -> LanguageResourceSystemSettingsDestination? {
        guard #available(macOS 26.0, *), SpeechTranscriber.isAvailable else {
            // There are no modern speech assets to prepare when SpeechTranscriber is
            // unavailable. The session will use SFSpeechRecognizer instead.
            removeLanguageResourceStatus(id: "speech:\(languageID)")
            return nil
        }

        let title = localized(.speechTitleFormat, languageName(for: languageID))
        let statusID = "speech:\(languageID)"
        let requestedLocale = Locale(identifier: speechLocaleIdentifier(for: languageID))
        let resolvedLocale = await LiveTranscriptionSession.modernSpeechLocale(equivalentTo: requestedLocale)
        let hasLegacyRecognizer = SFSpeechRecognizer(locale: requestedLocale) != nil

        guard let resolvedLocale else {
            if hasLegacyRecognizer {
                removeLanguageResourceStatus(id: statusID)
                return nil
            }

            upsertLanguageResourceStatus(
                LanguageResourceStatus(
                    id: statusID,
                    kind: .speech,
                    title: title,
                    detail: localized(.speechNotAvailableOnMacOS),
                    progress: nil,
                    isError: true
                )
            )
            return nil
        }

        let transcriber = makeSpeechTranscriber(locale: resolvedLocale)

        do {
            try await ensureSpeechAssetsReady(
                for: [transcriber],
                statusID: statusID,
                title: title
            )
            removeLanguageResourceStatus(id: statusID)
        } catch is CancellationError {
            removeLanguageResourceStatus(id: statusID)
        } catch LanguageResourcePreparationError.unsupportedSpeechLanguage where hasLegacyRecognizer {
            // Apple ships no modern assets for this language on this Mac. The session
            // falls back to SFSpeechRecognizer, so this must not block starting.
            removeLanguageResourceStatus(id: statusID)
        } catch {
            upsertLanguageResourceStatus(
                LanguageResourceStatus(
                    id: statusID,
                    kind: .speech,
                    title: title,
                    detail: localizedErrorDescription(error),
                    progress: nil,
                    isError: true
                )
            )
        }

        return nil
    }

    @available(macOS 26.0, *)
    private func ensureSpeechAssetsReady(
        for modules: [any SpeechModule],
        statusID: String,
        title: String
    ) async throws {
        let detail = localized(.downloadingSpeechResources)
        let maxPollingRetries = 150 // ~30 seconds at 200ms intervals
        var pollingRetryCount = 0

        while true {
            try Task.checkCancellation()

            switch await AssetInventory.status(forModules: modules) {
            case .installed:
                return
            case .unsupported:
                throw LanguageResourcePreparationError.unsupportedSpeechLanguage
            case .supported:
                if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                    try await installSpeechAssets(
                        request,
                        statusID: statusID,
                        title: title,
                        detail: detail
                    )
                    return
                }

                pollingRetryCount += 1
                if pollingRetryCount > maxPollingRetries {
                    throw LanguageResourcePreparationError.speechDownloadTimedOut
                }

                upsertLanguageResourceStatus(
                    LanguageResourceStatus(
                        id: statusID,
                        kind: .speech,
                        title: title,
                        detail: detail,
                        progress: nil,
                        isError: false
                    )
                )
            case .downloading:
                // Reset polling count — an active download is making progress
                pollingRetryCount = 0

                upsertLanguageResourceStatus(
                    LanguageResourceStatus(
                        id: statusID,
                        kind: .speech,
                        title: title,
                        detail: detail,
                        progress: nil,
                        isError: false
                    )
                )
            @unknown default:
                pollingRetryCount += 1
                if pollingRetryCount > maxPollingRetries {
                    throw LanguageResourcePreparationError.speechDownloadTimedOut
                }

                upsertLanguageResourceStatus(
                    LanguageResourceStatus(
                        id: statusID,
                        kind: .speech,
                        title: title,
                        detail: detail,
                        progress: nil,
                        isError: false
                    )
                )
            }

            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    @available(macOS 26.0, *)
    private func installSpeechAssets(
        _ request: AssetInstallationRequest,
        statusID: String,
        title: String,
        detail: String
    ) async throws {
        let progressTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            while Task.isCancelled == false {
                let progress = normalizedProgressValue(request.progress.fractionCompleted)
                self.upsertLanguageResourceStatus(
                    LanguageResourceStatus(
                        id: statusID,
                        kind: .speech,
                        title: title,
                        detail: detail,
                        progress: progress,
                        isError: false
                    )
                )

                do {
                    try await Task.sleep(nanoseconds: 120_000_000)
                } catch {
                    return
                }
            }
        }

        defer { progressTask.cancel() }

        try await request.downloadAndInstall()
    }

    private func prepareTranslationResourceIfNeeded(
        from sourceLanguageID: String,
        to targetLanguageID: String
    ) async -> LanguageResourceSystemSettingsDestination? {
        let title = localized(
            .translationTitleFormat,
            languageName(for: sourceLanguageID),
            languageName(for: targetLanguageID)
        )
        let statusID = "translation:\(sourceLanguageID)->\(targetLanguageID)"
        let downloadingDetail = localized(.downloadingTranslationResources)
        let waitingDetail = localized(.waitingTranslationResourcesInstalling)
        let manualDownloadDetail = localized(.manualTranslationDownloadDetail)
        let localFallbackDetail = localized(.preparingLocalTranslationFallback)
        let maxAttempts = 3
        var attemptCount = 0

        while Task.isCancelled == false {
            let availabilityStatus = await translationAvailabilityStatus(
                from: sourceLanguageID,
                to: targetLanguageID
            )

            switch availabilityStatus {
            case .unsupported:
                upsertLanguageResourceStatus(
                    LanguageResourceStatus(
                        id: statusID,
                        kind: .translation,
                        title: title,
                        detail: localFallbackDetail,
                        progress: nil,
                        isError: false
                    )
                )
                do {
                    try await prepareTranslationResourceWithTimeout(
                        from: sourceLanguageID,
                        to: targetLanguageID
                    )
                    removeLanguageResourceStatus(id: statusID)
                } catch is CancellationError {
                    removeLanguageResourceStatus(id: statusID)
                } catch {
                    upsertLanguageResourceStatus(
                        LanguageResourceStatus(
                            id: statusID,
                            kind: .translation,
                            title: title,
                            detail: localizedErrorDescription(error),
                            progress: nil,
                            isError: true
                        )
                    )
                }
                return nil
            case .supported, .installed:
                attemptCount += 1
                if attemptCount > maxAttempts {
                    upsertLanguageResourceStatus(
                        LanguageResourceStatus(
                            id: statusID,
                            kind: .translation,
                            title: title,
                            detail: manualDownloadDetail,
                            progress: nil,
                            isError: true
                        )
                    )
                    return .translationLanguages
                }

                upsertLanguageResourceStatus(
                    LanguageResourceStatus(
                        id: statusID,
                        kind: .translation,
                        title: title,
                        detail: availabilityStatus == .supported ? downloadingDetail : waitingDetail,
                        progress: nil,
                        isError: false
                    )
                )

                do {
                    try await prepareTranslationResourceWithTimeout(
                        from: sourceLanguageID,
                        to: targetLanguageID
                    )
                    removeLanguageResourceStatus(id: statusID)
                    return nil
                } catch is CancellationError {
                    removeLanguageResourceStatus(id: statusID)
                    return nil
                } catch {
                    if let error = error as? LanguageResourcePreparationError,
                       error == .translationDownloadTimedOut {
                        upsertLanguageResourceStatus(
                            LanguageResourceStatus(
                                id: statusID,
                                kind: .translation,
                                title: title,
                                detail: manualDownloadDetail,
                                progress: nil,
                                isError: true
                            )
                        )
                        return .translationLanguages
                    }

                    if let serviceError = error as? TranslationCoordinator.ServiceError {
                        upsertLanguageResourceStatus(
                            LanguageResourceStatus(
                            id: statusID,
                            kind: .translation,
                            title: title,
                            detail: serviceError.localizedDescription(languageID: resolvedInterfaceLanguageID),
                            progress: nil,
                            isError: true
                        )
                        )
                        return nil
                    }

                    let nsError = error as NSError
                    if nsError.domain == "TranslationErrorDomain", nsError.code == 14 {
                        upsertLanguageResourceStatus(
                            LanguageResourceStatus(
                                id: statusID,
                                kind: .translation,
                                title: title,
                                detail: manualDownloadDetail,
                                progress: nil,
                                isError: true
                            )
                        )
                        return .translationLanguages
                    }

                    let refreshedStatus = await translationAvailabilityStatus(
                        from: sourceLanguageID,
                        to: targetLanguageID
                    )

                    if refreshedStatus == .supported || refreshedStatus == .installed {
                        upsertLanguageResourceStatus(
                            LanguageResourceStatus(
                                id: statusID,
                                kind: .translation,
                                title: title,
                                detail: waitingDetail,
                                progress: nil,
                                isError: false
                            )
                        )

                        do {
                            try await Task.sleep(nanoseconds: 800_000_000)
                        } catch {
                            removeLanguageResourceStatus(id: statusID)
                            return nil
                        }

                        continue
                    }

                    upsertLanguageResourceStatus(
                        LanguageResourceStatus(
                            id: statusID,
                            kind: .translation,
                            title: title,
                            detail: localizedErrorDescription(error),
                            progress: nil,
                            isError: true
                        )
                    )
                    return nil
                }
            @unknown default:
                attemptCount += 1
                if attemptCount > maxAttempts {
                    upsertLanguageResourceStatus(
                        LanguageResourceStatus(
                            id: statusID,
                            kind: .translation,
                            title: title,
                            detail: manualDownloadDetail,
                            progress: nil,
                            isError: true
                        )
                    )
                    return .translationLanguages
                }

                upsertLanguageResourceStatus(
                    LanguageResourceStatus(
                        id: statusID,
                        kind: .translation,
                        title: title,
                        detail: waitingDetail,
                        progress: nil,
                        isError: false
                    )
                )

                do {
                    try await Task.sleep(nanoseconds: 800_000_000)
                } catch {
                    removeLanguageResourceStatus(id: statusID)
                    return nil
                }
            }
        }

        removeLanguageResourceStatus(id: statusID)
        return nil
    }

    private func prepareTranslationResourceWithTimeout(
        from sourceLanguageID: String,
        to targetLanguageID: String
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [translationCoordinator] in
                try await translationCoordinator.prepareIfNeeded(
                    from: sourceLanguageID,
                    to: targetLanguageID
                )
            }

            group.addTask {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                throw LanguageResourcePreparationError.translationDownloadTimedOut
            }

            let result: Void? = try await group.next()
            group.cancelAll()
            _ = result
        }
    }

    @available(macOS 26.0, *)
    private func makeSpeechTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
    }

    private func normalizedProgressValue(_ fractionCompleted: Double) -> Double? {
        guard fractionCompleted.isFinite, fractionCompleted >= 0 else {
            return nil
        }

        return min(max(fractionCompleted, 0), 1)
    }

    private func translationAvailabilityStatus(
        from sourceLanguageID: String,
        to targetLanguageID: String
    ) async -> LanguageAvailability.Status {
        guard #available(macOS 15.0, *) else {
            return .unsupported
        }

        let sourceLanguage = Locale.Language(
            identifier: translationLocaleIdentifier(for: sourceLanguageID)
        )
        let targetLanguage = Locale.Language(
            identifier: translationLocaleIdentifier(for: targetLanguageID)
        )
        let availability = LanguageAvailability()
        return await availability.status(from: sourceLanguage, to: targetLanguage)
    }

    private func upsertLanguageResourceStatus(_ status: LanguageResourceStatus) {
        if let existingIndex = languageResourceStatuses.firstIndex(where: { $0.id == status.id }) {
            languageResourceStatuses[existingIndex] = status
        } else {
            languageResourceStatuses.append(status)
        }

        languageResourceStatuses.sort { lhs, rhs in
            if lhs.kind.rawValue == rhs.kind.rawValue {
                return lhs.title < rhs.title
            }
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
    }

    private func removeLanguageResourceStatus(id: String) {
        languageResourceStatuses.removeAll { $0.id == id }
    }

    private func openSystemSettings(for destination: LanguageResourceSystemSettingsDestination) {
        guard let url = URL(string: destination.urlString) else {
            return
        }

#if os(macOS)
        if NSWorkspace.shared.open(url) == false,
           let fallbackURL = URL(string: "x-apple.systempreferences:") {
            _ = NSWorkspace.shared.open(fallbackURL)
        }
#else
        UIApplication.shared.open(url)
#endif
    }

    // MARK: - Draft handler

    private func handlePartialDraft(
        _ draft: DraftSegment?,
        source: InputSource,
        sourceLanguageID: String,
        targetLanguageID: String
    ) {
        guard liveTranscriptionSession != nil else { return }
        if let draft, isFinalizedDraftPromotionID(draft.segmentId) {
            return
        }

        let draftText = sanitizedDisplayText(draft?.sourceText ?? "")
        let draftPromotionID = draft?.segmentId
        if draftText.isEmpty {
            if isDraftPromotionPending() {
                return
            }
            scheduleDraftClear()
            return
        }

        cancelCommittedCaptionArchive()
        cancelPendingDraftClear()
        activeDraftSourceLanguageID = sourceLanguageID
        activeDraftTargetLanguageID = targetLanguageID
        let isReversed = CaptionLanguagePolicy.shouldReverse(
            configuredSourceLanguageID: liveCaptionConfiguredSourceLanguageID,
            configuredTargetLanguageID: liveCaptionConfiguredTargetLanguageID,
            heardLanguageID: sourceLanguageID,
            heardText: draftText
        )
        activeDraftUsesInverseGlossary = isReversed
        if isReversed {
            overlayState?.draftTranslatedText = draftText
            overlayState?.draftSourceText = nil
        } else {
            overlayState?.draftSourceText = draftText
            overlayState?.clearDraftTranslationIfMismatched(
                sourceText: draftText,
                promotionID: draftPromotionID
            )
        }
        overlayState?.draftStablePrefixLength = min(draft?.stablePrefixLength ?? 0, draftText.count)
        overlayState?.draftPromotionID = draftPromotionID
        overlayState?.sourceName = source.name
        dismissListeningPlaceholderIfNeeded()

        let stablePrefix = String(draftText.prefix(min(draft?.stablePrefixLength ?? 0, draftText.count)))
        lastDraftStablePrefix = stablePrefix

        guard draftText != lastDraftTranslationSource
                || draftPromotionID != lastDraftTranslationPromotionID
                || source.id != lastDraftSourceID else {
            return
        }
        lastDraftSourceID = source.id
        lastDraftTranslationSource = draftText
        lastDraftTranslationPromotionID = draftPromotionID

        if shouldReserveDraftTranslationSlot(
            sourceLanguageID: sourceLanguageID,
            targetLanguageID: targetLanguageID
        ) {
            scheduleDraftTranslation(
                for: draftText,
                promotionID: draftPromotionID,
                sourceLanguageID: sourceLanguageID,
                targetLanguageID: targetLanguageID,
                usesInverseGlossary: isReversed
            )
        } else {
            draftTranslationTask?.cancel()
            draftTranslationTask = nil
            draftTranslationGeneration &+= 1
            if isReversed {
                overlayState?.draftTranslatedText = draftText
                overlayState?.draftSourceText = draftText
            } else {
                overlayState?.setDraftTranslation(
                    draftText,
                    sourceText: draftText,
                    promotionID: draftPromotionID
                )
            }
        }
    }
    private func scheduleDraftClear() {
        draftClearTask?.cancel()
        draftClearGeneration &+= 1
        let generation = draftClearGeneration

        draftClearTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await Task.sleep(nanoseconds: Self.draftClearDelayNanoseconds)
            } catch {
                return
            }

            guard !Task.isCancelled,
                  liveTranscriptionSession != nil,
                  generation == draftClearGeneration else { return }

            clearDraftOverlay()
            scheduleCommittedCaptionArchiveIfNeeded()
        }
    }

    private func cancelPendingDraftClear() {
        draftClearTask?.cancel()
        draftClearTask = nil
        draftClearGeneration &+= 1
    }

    private func clearDraftOverlay() {
        draftClearTask?.cancel()
        draftClearTask = nil
        overlayState?.draftSourceText = nil
        overlayState?.draftStablePrefixLength = 0
        overlayState?.draftPromotionID = nil
        overlayState?.clearDraftTranslation()
        activeDraftSourceLanguageID = nil
        activeDraftTargetLanguageID = nil
        activeDraftUsesInverseGlossary = false
        lastDraftSourceID = nil
        lastDraftStablePrefix = ""
        lastDraftTranslationSource = ""
        lastDraftTranslationPromotionID = nil
        draftTranslationTask?.cancel()
        draftTranslationTask = nil
        draftTranslationGeneration &+= 1
    }
    private func scheduleDraftTranslation(
        for text: String,
        promotionID: UUID?,
        sourceLanguageID: String,
        targetLanguageID: String,
        usesInverseGlossary: Bool
    ) {
        draftTranslationTask?.cancel()
        draftTranslationGeneration &+= 1
        let generation = draftTranslationGeneration
        draftTranslationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Keep draft translation responsive while still coalescing very fast ASR churn.
            do { try await Task.sleep(nanoseconds: 60_000_000) } catch { return }
            guard !Task.isCancelled, liveTranscriptionSession != nil else { return }

            guard generation == draftTranslationGeneration else { return }

            guard sourceLanguageID != targetLanguageID else {
                guard overlayState?.draftPromotionID == promotionID,
                      activeDraftSourceLanguageID == sourceLanguageID,
                      activeDraftTargetLanguageID == targetLanguageID else {
                    return
                }
                if usesInverseGlossary {
                    overlayState?.draftTranslatedText = text
                    overlayState?.draftSourceText = text
                } else {
                    overlayState?.setDraftTranslation(
                        text,
                        sourceText: text,
                        promotionID: promotionID
                    )
                }
                return
            }

            // Runs until it completes or a newer draft supersedes it — the next
            // scheduleDraftTranslation call cancels this task, and the staleness
            // guards below drop results whose draft is no longer visible. A slow
            // translation that lands while the draft is still current is more
            // useful applied late than discarded on a fixed deadline.
            let effectiveGlossary = usesInverseGlossary ? cachedInverseGlossary : glossary
            let translation = try? await glossaryService.translating(
                sourceText: text,
                glossary: effectiveGlossary
            ) { preparedInput in
                try await self.translationCoordinator(
                    from: sourceLanguageID,
                    to: targetLanguageID
                ).translate(
                    preparedInput,
                    from: sourceLanguageID,
                    to: targetLanguageID
                )
            }

            guard !Task.isCancelled,
                  liveTranscriptionSession != nil,
                  generation == draftTranslationGeneration,
                  overlayState?.draftPromotionID == promotionID,
                  activeDraftSourceLanguageID == sourceLanguageID,
                  activeDraftTargetLanguageID == targetLanguageID else { return }
            if let translation {
                let resolvedTranslation = translation.translatedText
                if shouldTreatAsMissingTranslation(
                    resolvedTranslation,
                    sourceText: translation.sourceText,
                    sourceLanguageID: sourceLanguageID,
                    targetLanguageID: targetLanguageID
                ) == false {
                    overlayState?.setDraftTranslation(
                        resolvedTranslation,
                        sourceText: translation.sourceText,
                        promotionID: promotionID
                    )
                }
            }
        }
    }

    // MARK: - Overlay history

    /// Archives the current committed caption, then clears the live overlay text.
    private func clearOverlayText() {
        if let currentCaption = currentCommittedCaptionHistoryPayload() {
            rememberArchivedCaption(
                sourceText: currentCaption.sourceText,
                promotionID: displayedCaption?.promotionID
            )
            appendOverlayHistoryEntry(
                captionID: displayedCaption?.id,
                translatedText: currentCaption.translatedText,
                sourceText: currentCaption.sourceText
            )
        }
        cancelCommittedCaptionArchive()
        clearDraftOverlay()
        overlayState?.translatedText = ""
        overlayState?.sourceText = ""
        overlayState?.committedPromotionID = nil
        displayedCaption = nil
        displayedCaptionLastVisualUpdateAt = Date.distantPast
        displayedCaptionLastVisualUpdateWasLateTranslation = false
    }

    /// Archives the currently committed caption into the scrollback history before
    /// the next sentence replaces it.
    private func capturePreviousCaption() {
        guard let currentCaption = currentCommittedCaptionHistoryPayload() else { return }
        rememberArchivedCaption(
            sourceText: currentCaption.sourceText,
            promotionID: displayedCaption?.promotionID
        )
        appendOverlayHistoryEntry(
            captionID: displayedCaption?.id,
            translatedText: currentCaption.translatedText,
            sourceText: currentCaption.sourceText
        )
    }

    private func updateCommittedOverlay(
        translatedText: String,
        sourceText: String,
        promotionID: UUID? = nil,
        bumpEpoch: Bool = false,
        lateTranslation: Bool = false
    ) {
        if overlayState == nil {
            overlayState = OverlayPreviewState(
                translatedText: translatedText,
                sourceText: sourceText,
                sourceName: displayedCaption?.sourceName ?? ""
            )
        } else {
            overlayState?.translatedText = translatedText
            overlayState?.sourceText = sourceText
        }

        if bumpEpoch {
            overlayState?.captionEpoch = (overlayState?.captionEpoch ?? 0) + 1
        }
        if let promotionID {
            overlayState?.committedPromotionID = promotionID
        }
        displayedCaptionLastVisualUpdateAt = Date()
        displayedCaptionLastVisualUpdateWasLateTranslation = lateTranslation
    }

    // MARK: - Settings sync

    private func syncOverlayPreviewIfNeeded() {
        guard isCaptionPipelineActive == false else {
            return
        }

        guard isOverlayVisible || isAudienceDisplayVisible else {
            return
        }

        let source = selectedSource ?? previewInputSource
        overlayState = makePreviewState(for: source)
        overlayHistoryScrollOffset = 0
    }

    private func handleSubtitleDisplayModeChange() {
        guard liveTranscriptionSession != nil else {
            return
        }

        if showsTranslatedSubtitle {
            let draftText = sanitizedDisplayText(overlayState?.draftSourceText ?? "")
            guard draftText.isEmpty == false else {
                scheduleCommittedCaptionArchiveIfNeeded()
                return
            }

            if let activeDraftSourceLanguageID,
               let activeDraftTargetLanguageID,
               shouldReserveDraftTranslationSlot(
                   sourceLanguageID: activeDraftSourceLanguageID,
                   targetLanguageID: activeDraftTargetLanguageID
               ) {
                scheduleDraftTranslation(
                    for: draftText,
                    promotionID: overlayState?.draftPromotionID,
                    sourceLanguageID: activeDraftSourceLanguageID,
                    targetLanguageID: activeDraftTargetLanguageID,
                    usesInverseGlossary: activeDraftUsesInverseGlossary
                )
            } else {
                draftTranslationTask?.cancel()
                draftTranslationTask = nil
                draftTranslationGeneration &+= 1
                overlayState?.setDraftTranslation(
                    draftText,
                    sourceText: draftText,
                    promotionID: overlayState?.draftPromotionID
                )
            }
        } else {
            draftTranslationTask?.cancel()
            draftTranslationTask = nil
            draftTranslationGeneration &+= 1
            overlayState?.clearDraftTranslation()
        }

        scheduleCommittedCaptionArchiveIfNeeded()
    }

    private func makePreviewState(for source: InputSource) -> OverlayPreviewState {
        let sourceLanguageID = languageID(for: source)
        let targetLanguageID = outputLanguageIDForSource(source)
        let sourceText = sampleText(for: sourceLanguageID)
        let translatedText: String

        if sourceLanguageID == targetLanguageID {
            translatedText = sourceText
        } else {
            translatedText = sampleText(for: targetLanguageID)
        }

        return OverlayPreviewState(
            translatedText: translatedText,
            sourceText: sourceText,
            sourceName: source.name
        )
    }

    // MARK: - Caption queue

    private func enqueueRecognizedSentence(
        _ sentence: RecognizedSentence,
        source: InputSource,
        sourceLanguageID: String,
        targetLanguageID: String,
        usesInverseGlossary: Bool
    ) {
        let sourceText = sanitizedDisplayText(sentence.text)
        guard sourceText.isEmpty == false else {
            logCaptionEnqueue(
                kind: "drop-empty",
                captionID: nil,
                promotionID: sentence.promotionSegmentID,
                replacesID: sentence.replacesPromotionSegmentID,
                revision: nil,
                sourceID: source.id,
                sourceKind: source.category.rawValue
            )
            return
        }

        if let replacesID = sentence.replacesPromotionSegmentID {
            if handleSentenceReplacement(
                replacesID: replacesID,
                sentence: sentence,
                sourceText: sourceText,
                source: source,
                sourceLanguageID: sourceLanguageID,
                targetLanguageID: targetLanguageID,
                usesInverseGlossary: usesInverseGlossary
            ) {
                return
            }
            logCaptionEnqueue(
                kind: "replace-miss",
                captionID: captionIDByPromotionID[replacesID],
                promotionID: sentence.promotionSegmentID,
                replacesID: replacesID,
                revision: nil,
                sourceID: source.id,
                sourceKind: source.category.rawValue
            )
        }

        if let promotionID = sentence.promotionSegmentID {
            guard isFinalizedDraftPromotionID(promotionID) == false else {
                logCaptionEnqueue(
                    kind: "drop-finalized-draft",
                    captionID: captionIDByPromotionID[promotionID],
                    promotionID: promotionID,
                    replacesID: sentence.replacesPromotionSegmentID,
                    revision: nil,
                    sourceID: source.id,
                    sourceKind: source.category.rawValue
                )
                return
            }

            let promotedDraftTranslation = promotedDraftTranslationSnapshot(for: sentence.promotionSegmentID)
            markDraftPromotionFinalized(promotionID)
            cancelCommittedCaptionArchive()

            guard shouldEnqueueRecognizedSentence(sourceText, promotionID: promotionID) else {
                logCaptionEnqueue(
                    kind: "drop-enqueue-guard",
                    captionID: captionIDByPromotionID[promotionID],
                    promotionID: promotionID,
                    replacesID: sentence.replacesPromotionSegmentID,
                    revision: nil,
                    sourceID: source.id,
                    sourceKind: source.category.rawValue
                )
                return
            }

            let caption = QueuedCaption(
                id: UUID(),
                promotionID: promotionID,
                sourceText: sourceText,
                sourceName: source.name,
                sourceLanguageID: sourceLanguageID,
                targetLanguageID: targetLanguageID,
                usesInverseGlossary: usesInverseGlossary,
                promotedDraftTranslation: promotedDraftTranslation
            )
            captionIDByPromotionID[promotionID] = caption.id
            if usesInverseGlossary {
                inverseGlossaryCaptionIDs.insert(caption.id)
            }
            rememberRecognizedSentence(sourceText, promotionID: promotionID)
            pendingCaptions.append(caption)
            translateCaption(caption)
            logCaptionEnqueue(
                kind: "append",
                captionID: caption.id,
                promotionID: promotionID,
                replacesID: sentence.replacesPromotionSegmentID,
                revision: caption.revision,
                sourceID: source.id,
                sourceKind: source.category.rawValue
            )
        } else {
            cancelCommittedCaptionArchive()

            guard shouldEnqueueRecognizedSentence(sourceText, promotionID: nil) else {
                logCaptionEnqueue(
                    kind: "drop-enqueue-guard",
                    captionID: nil,
                    promotionID: nil,
                    replacesID: sentence.replacesPromotionSegmentID,
                    revision: nil,
                    sourceID: source.id,
                    sourceKind: source.category.rawValue
                )
                return
            }

            let captionID = UUID()
            let promotionID = UUID()
            let caption = QueuedCaption(
                id: captionID,
                promotionID: promotionID,
                sourceText: sourceText,
                sourceName: source.name,
                sourceLanguageID: sourceLanguageID,
                targetLanguageID: targetLanguageID,
                usesInverseGlossary: usesInverseGlossary,
                promotedDraftTranslation: nil
            )
            captionIDByPromotionID[promotionID] = caption.id
            if usesInverseGlossary {
                inverseGlossaryCaptionIDs.insert(caption.id)
            }

            rememberRecognizedSentence(sourceText, promotionID: promotionID)
            pendingCaptions.append(caption)
            translateCaption(caption)
            logCaptionEnqueue(
                kind: "append",
                captionID: caption.id,
                promotionID: promotionID,
                replacesID: sentence.replacesPromotionSegmentID,
                revision: caption.revision,
                sourceID: source.id,
                sourceKind: source.category.rawValue,
                promotionOrigin: "generated"
            )
        }

        // Keep the currently displayed caption plus up to two fresh arrivals.
        // This avoids losing the first sentence when a single ASR result is split
        // into two back-to-back captions.
        while pendingCaptions.count > 3 {
            let dropped = pendingCaptions.remove(at: 1)
            captionTranslationTasks[dropped.id]?.cancel()
            captionTranslationTasks.removeValue(forKey: dropped.id)
            updateReadyCaptionTranslation(nil, for: dropped.id)
            logCaptionEnqueue(
                kind: "drop-pending-overflow",
                captionID: dropped.id,
                promotionID: dropped.promotionID,
                replacesID: nil,
                revision: dropped.revision,
                sourceID: source.id,
                sourceKind: source.category.rawValue
            )
        }

        processCaptionQueueIfNeeded()

        // Record speech rate for speed-protection monitor
        let nowMs = Int(Date().timeIntervalSinceReferenceDate * 1000)
        Task { await speedMonitor.record(chars: sourceText.count, nowMs: nowMs) }

        if sessionState != .running {
            sessionState = .running
        }

        setStatus(.running(sourceName: activeSourceDisplayName))
    }

    private func handleSentenceReplacement(
        replacesID: UUID,
        sentence: RecognizedSentence,
        sourceText: String,
        source: InputSource,
        sourceLanguageID: String,
        targetLanguageID: String,
        usesInverseGlossary: Bool
    ) -> Bool {
        let newPromotionID = sentence.promotionSegmentID ?? replacesID
        markDraftPromotionFinalized(newPromotionID)
        markDraftPromotionFinalized(replacesID)

        let targetCaptionID = captionIDByPromotionID[replacesID] ?? replacesID

        // Case 1: Active displayed caption is being revised
        if let current = displayedCaption,
           current.promotionID == replacesID || current.id == replacesID || current.id == targetCaptionID {
            let captionID = current.id
            captionIDByPromotionID[newPromotionID] = captionID
            let newRevision = (current.revision &+ 1)
            let promotedDraft = promotedDraftTranslationSnapshot(for: newPromotionID)
            let updatedCaption = QueuedCaption(
                id: captionID,
                promotionID: newPromotionID,
                sourceText: sourceText,
                sourceName: source.name,
                sourceLanguageID: sourceLanguageID,
                targetLanguageID: targetLanguageID,
                usesInverseGlossary: usesInverseGlossary,
                promotedDraftTranslation: promotedDraft,
                revision: newRevision
            )
            displayedCaption = updatedCaption

            if usesInverseGlossary {
                inverseGlossaryCaptionIDs.insert(captionID)
            } else {
                inverseGlossaryCaptionIDs.remove(captionID)
            }

            let translationExpected = sourceLanguageID != targetLanguageID
            let initialTranslation = promotedDraft
            let panes = languagePanes(
                heard: sourceText,
                translated: initialTranslation ?? (translationExpected ? "" : sourceText),
                usesInverseGlossary: usesInverseGlossary
            )
            updateCommittedOverlay(
                translatedText: panes.translatedText,
                sourceText: panes.sourceText,
                promotionID: newPromotionID
            )
            upsertTranscriptEntry(
                id: captionID,
                sourceText: sourceText,
                translatedText: initialTranslation ?? (translationExpected ? "" : sourceText)
            )

            if let hIndex = overlayState?.history.lastIndex(where: { $0.id == captionID }) {
                overlayState?.history[hIndex].sourceText = panes.sourceText
                overlayState?.history[hIndex].translatedText = panes.translatedText
            }

            cancelCommittedCaptionArchive()
            translateCaption(updatedCaption)
            rememberRecognizedSentence(sourceText)
            logCaptionEnqueue(
                kind: "replace-displayed",
                captionID: captionID,
                promotionID: newPromotionID,
                replacesID: replacesID,
                revision: newRevision,
                sourceID: source.id,
                sourceKind: source.category.rawValue
            )
            return true
        }

        // Case 2: Caption waiting in pendingCaptions is being revised
        if let index = pendingCaptions.firstIndex(where: {
            $0.promotionID == replacesID || $0.id == replacesID || $0.id == targetCaptionID
        }) {
            let old = pendingCaptions[index]
            captionIDByPromotionID[newPromotionID] = old.id
            let newRevision = (old.revision &+ 1)
            let promotedDraft = promotedDraftTranslationSnapshot(for: newPromotionID)
            let updated = QueuedCaption(
                id: old.id,
                promotionID: newPromotionID,
                sourceText: sourceText,
                sourceName: source.name,
                sourceLanguageID: sourceLanguageID,
                targetLanguageID: targetLanguageID,
                usesInverseGlossary: usesInverseGlossary,
                promotedDraftTranslation: promotedDraft,
                revision: newRevision
            )
            pendingCaptions[index] = updated

            if usesInverseGlossary {
                inverseGlossaryCaptionIDs.insert(old.id)
            } else {
                inverseGlossaryCaptionIDs.remove(old.id)
            }

            translateCaption(updated)
            rememberRecognizedSentence(sourceText)
            logCaptionEnqueue(
                kind: "replace-pending",
                captionID: old.id,
                promotionID: newPromotionID,
                replacesID: replacesID,
                revision: newRevision,
                sourceID: source.id,
                sourceKind: source.category.rawValue
            )
            return true
        }

        // Case 3: Caption was already archived in history
        if let hIndex = overlayState?.history.lastIndex(where: { $0.id == targetCaptionID || $0.id == replacesID }) {
            let captionID = overlayState!.history[hIndex].id
            captionIDByPromotionID[newPromotionID] = captionID
            let translationExpected = sourceLanguageID != targetLanguageID
            let panes = languagePanes(
                heard: sourceText,
                translated: translationExpected ? "" : sourceText,
                usesInverseGlossary: usesInverseGlossary
            )
            overlayState?.history[hIndex].sourceText = panes.sourceText
            overlayState?.history[hIndex].translatedText = panes.translatedText

            if let tIndex = transcriptEntries.firstIndex(where: { $0.id == captionID }) {
                transcriptEntries[tIndex].sourceText = sourceText
                transcriptEntries[tIndex].translatedText = translationExpected ? "" : sourceText
            }
            if translationExpected {
                translateHistoryRevision(
                    id: captionID,
                    sourceText: sourceText,
                    sourceLanguageID: sourceLanguageID,
                    targetLanguageID: targetLanguageID,
                    usesInverseGlossary: usesInverseGlossary
                )
            }
            rememberRecognizedSentence(sourceText)
            logCaptionEnqueue(
                kind: "replace-history",
                captionID: captionID,
                promotionID: newPromotionID,
                replacesID: replacesID,
                revision: nil,
                sourceID: source.id,
                sourceKind: source.category.rawValue
            )
            return true
        }

        return false
    }

    /// Privacy-safe caption identity log. Never interpolates transcript text.
    private func logCaptionEnqueue(
        kind: String,
        captionID: UUID?,
        promotionID: UUID?,
        replacesID: UUID?,
        revision: UInt64?,
        sourceID: String,
        sourceKind: String,
        promotionOrigin: String = "inbound"
    ) {
        let captionText = captionID?.uuidString ?? "-"
        let promotionText = promotionID?.uuidString ?? "-"
        let replacesText = replacesID?.uuidString ?? "-"
        let revisionText = revision.map(String.init) ?? "-"
        Logger.caption.notice("enqueue kind=\(kind, privacy: .public) caption=\(captionText, privacy: .public) promotion=\(promotionText, privacy: .public) origin=\(promotionOrigin, privacy: .public) replaces=\(replacesText, privacy: .public) revision=\(revisionText, privacy: .public) sourceKind=\(sourceKind, privacy: .public) source=\(sourceID, privacy: .public)")
    }

    private func refreshCaptionTranslations() {
        guard liveTranscriptionSession != nil else {
            return
        }

        cancelCaptionTranslations()
        readyCaptionTranslations.removeAll()

        for caption in pendingCaptions {
            translateCaption(caption)
        }

        if let displayedCaption {
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                let translatedText = await translatedText(for: displayedCaption)
                guard liveTranscriptionSession != nil,
                      self.displayedCaption?.id == displayedCaption.id else {
                    return
                }

                let translationExpected = displayedCaption.sourceLanguageID != displayedCaption.targetLanguageID
                let resolvedTranslation = translationExpected
                    ? (translatedText ?? "")
                    : displayedCaption.sourceText

                let panes = languagePanes(
                    heard: displayedCaption.sourceText,
                    translated: resolvedTranslation,
                    usesInverseGlossary: displayedCaption.usesInverseGlossary
                )
                updateCommittedOverlay(
                    translatedText: panes.translatedText,
                    sourceText: panes.sourceText,
                    lateTranslation: translationExpected && resolvedTranslation.isEmpty == false
                )
                upsertTranscriptEntry(
                    id: displayedCaption.id,
                    sourceText: displayedCaption.sourceText,
                    translatedText: resolvedTranslation
                )
            }
        }
    }

    private func shouldReserveDraftTranslationSlot(
        sourceLanguageID: String,
        targetLanguageID: String
    ) -> Bool {
        showsTranslatedSubtitle && sourceLanguageID != targetLanguageID
    }

    var shouldReserveDraftTranslationSlot: Bool {
        guard let activeDraftSourceLanguageID,
              let activeDraftTargetLanguageID else {
            return false
        }
        return shouldReserveDraftTranslationSlot(
            sourceLanguageID: activeDraftSourceLanguageID,
            targetLanguageID: activeDraftTargetLanguageID
        )
    }

    var transcriptSourceLanguageID: String {
        transcriptInputLanguageID ?? inputLanguageID
    }

    var transcriptTargetLanguageID: String {
        transcriptOutputLanguageID ?? outputLanguageID
    }

    var hasTranscript: Bool {
        transcriptEntries.isEmpty == false
    }

    func transcriptText(isTranslation: Bool) -> String {
        transcriptEntries
            .map { isTranslation ? $0.translatedText : $0.sourceText }
            .filter { $0.isEmpty == false }
            .joined(separator: "\n")
    }

    func clearTranscript() {
        transcriptEntries.removeAll()
        transcriptGeneration &+= 1
    }

    var shouldReserveCommittedCaptionSlot: Bool {
        guard sessionState == .running else {
            return false
        }

        return displayedCaption != nil
            || pendingCaptions.isEmpty == false
            || hasActiveDraftOverlay
            || overlayState?.draftPromotionID != nil
            || overlayState?.history.isEmpty == false
    }

    private func resetLiveTextPipeline() {
        captionDisplayTask?.cancel()
        captionDisplayTask = nil
        draftClearTask?.cancel()
        draftClearTask = nil
        draftTranslationTask?.cancel()
        draftTranslationTask = nil
        committedCaptionArchiveTask?.cancel()
        committedCaptionArchiveTask = nil
        activeDraftSourceLanguageID = nil
        activeDraftTargetLanguageID = nil
        activeDraftUsesInverseGlossary = false
        lastDraftSourceID = nil
        lastDraftStablePrefix = ""
        lastDraftTranslationSource = ""
        lastDraftTranslationPromotionID = nil
        draftTranslationGeneration &+= 1
        draftClearGeneration &+= 1
        cancelCaptionTranslations()
        resumeAllCaptionTranslationWaiters()
        pendingCaptions.removeAll()
        readyCaptionTranslations.removeAll()
        translationRevisions.removeAll()
        inverseGlossaryCaptionIDs.removeAll()
        recentRecognizedCaptionTexts.removeAll()
        recentArchivedCaption = nil
        finalizedDraftPromotionIDs.removeAll()
        captionTranslationGenerations.removeAll()
        captionIDByPromotionID.removeAll()
        displayedCaption = nil
        overlayHistoryScrollOffset = 0
        displayedCaptionLastVisualUpdateAt = Date.distantPast
        displayedCaptionLastVisualUpdateWasLateTranslation = false

        translationCoordinator.invalidateSession()
        translationCoordinator.reset()
        reverseTranslationCoordinator.invalidateSession()
        reverseTranslationCoordinator.reset()

        Task {
            await speedMonitor.reset()
        }
    }

    private func processCaptionQueueIfNeeded() {
        guard captionDisplayTask == nil else {
            return
        }

        captionDisplayTask = Task { @MainActor [weak self] in
            await self?.processCaptionQueue()
        }
    }

    private func processCaptionQueue() async {
        // Guaranteed to run even if we break or the task is cancelled.
        defer {
            captionDisplayTask = nil
            scheduleCommittedCaptionArchiveIfNeeded()
        }

        while Task.isCancelled == false {
            guard isCaptionPipelineActive else { break }
            guard let caption = pendingCaptions.first else {
                // Keep the most recent committed caption in the primary white slot
                // until a newer caption arrives and replaces it.
                break
            }

            let captionID = caption.id
            let startRevision = caption.revision

            // Caption cleanup runs on every exit from this iteration: normal
            // completion, break, or sleep cancellation.
            defer {
                if let index = pendingCaptions.firstIndex(where: { $0.id == captionID }) {
                    if pendingCaptions[index].revision <= startRevision {
                        pendingCaptions.remove(at: index)
                    }
                }
                if displayedCaption?.id != captionID || displayedCaption?.revision == startRevision {
                    updateReadyCaptionTranslation(nil, for: captionID)
                }
            }

            // Archive the current caption before the next sentence replaces it.
            capturePreviousCaption()

            // Use the best available translation for the initial committed display:
            // 1. Pre-computed caption translation (if ready)
            // 2. Draft translation captured at the promotion moment
            // 3. Leave the translated slot empty until the final translation arrives
            let earlyTranslation = readyCaptionTranslations[caption.id]
            let initialTranslation = earlyTranslation
                ?? (caption.promotedDraftTranslation?.isEmpty == false ? caption.promotedDraftTranslation : nil)
            let translationExpected = caption.sourceLanguageID != caption.targetLanguageID

            cancelCommittedCaptionArchive()
            displayedCaption = caption

            // If a draft translation was visible, skip the fade-in so the committed
            // text replaces the draft seamlessly instead of flashing.
            let hadDraftTranslation = initialTranslation?.isEmpty == false

            overlayState?.skipCommittedFadeIn = hadDraftTranslation
            let panes = languagePanes(
                heard: caption.sourceText,
                translated: initialTranslation ?? (translationExpected ? "" : caption.sourceText),
                usesInverseGlossary: caption.usesInverseGlossary
            )
            updateCommittedOverlay(
                translatedText: panes.translatedText,
                sourceText: panes.sourceText,
                promotionID: caption.promotionID,
                bumpEpoch: true
            )
            upsertTranscriptEntry(
                id: caption.id,
                sourceText: caption.sourceText,
                translatedText: initialTranslation ?? (translationExpected ? "" : caption.sourceText)
            )
            overlayState?.sourceName = caption.sourceName
            clearDraftOverlay()

            let finalTranslation: String?
            if let earlyTranslation {
                finalTranslation = earlyTranslation
            } else {
                // Dynamic wait: base 3s + 1s per 30 chars, capped at 15s
                let captionCharCount = caption.sourceText.count
                let waitTimeout = min(max(3.0, 3.0 + Double(captionCharCount / 30) * 1.0), 15.0)
                let waited = await waitForTranslatedCaption(id: caption.id, timeout: waitTimeout)
                // Race fallback: the timeout may have resumed our waiter with nil at the
                // same moment the translation finished and ran applyLateCaptionTranslation.
                // Re-read the ready map so we don't clobber a just-applied backfill below.
                finalTranslation = waited ?? readyCaptionTranslations[caption.id]
            }

            guard isCaptionPipelineActive else { break }

            guard let activeCaption = displayedCaption, activeCaption.id == captionID else {
                continue
            }

            if activeCaption.revision == startRevision {
                let resolvedTranslation = resolvedCommittedTranslationText(
                    finalTranslation: finalTranslation,
                    initialTranslation: initialTranslation,
                    translationExpected: translationExpected,
                    sourceText: activeCaption.sourceText
                )

                // If nothing translated for a translation-expected caption, the session may be stuck.
                let translationFailed = translationExpected
                    && resolvedTranslation.isEmpty
                    && initialTranslation == nil

                if translationFailed {
                    translationCoordinator.consecutiveTimeouts += 1
                } else {
                    translationCoordinator.consecutiveTimeouts = 0
                }

                // After 2 consecutive failed captions, recover the session and reissue
                // affected translations so late backfill still has work to complete.
                if translationCoordinator.consecutiveTimeouts >= 2 {
                    translationCoordinator.recoverSession(
                        source: activeCaption.sourceLanguageID,
                        target: activeCaption.targetLanguageID
                    )

                    let captionsToRetry = [activeCaption] + pendingCaptions.filter { $0.id != activeCaption.id }
                    for captionToRetry in captionsToRetry {
                        translateCaption(captionToRetry)
                    }
                }

                let finalPanes = languagePanes(
                    heard: activeCaption.sourceText,
                    translated: resolvedTranslation,
                    usesInverseGlossary: activeCaption.usesInverseGlossary
                )
                updateCommittedOverlay(
                    translatedText: finalPanes.translatedText,
                    sourceText: finalPanes.sourceText,
                    lateTranslation: translationExpected && resolvedTranslation.isEmpty == false
                )
                upsertTranscriptEntry(
                    id: activeCaption.id,
                    sourceText: activeCaption.sourceText,
                    translatedText: resolvedTranslation
                )
                if resolvedTranslation.isEmpty == false {
                    translationRevisions[activeCaption.id] = resolvedTranslation
                } else {
                    translationRevisions.removeValue(forKey: activeCaption.id)
                }
            }

            let latestActiveCaption = displayedCaption ?? activeCaption
            let holdDuration = computeDisplayDuration(
                sourceText: latestActiveCaption.sourceText,
                translatedText: translationRevisions[latestActiveCaption.id] ?? ""
            )

            let completedHold = await holdDisplayedCaption(
                latestActiveCaption,
                initialHoldDuration: holdDuration
            )
            if completedHold == false {
                break
            }
        }
    }

    private func normalizedCaptionText(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
    }

    private func comparableCaptionText(_ text: String) -> String {
        normalizedCaptionText(text)
            .trimmingCharacters(in: Self.captionComparisonTrimCharacterSet)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private func relaxedComparableCaptionText(_ text: String) -> String {
        comparableCaptionText(text)
            .replacingOccurrences(
                of: "[ー〜～]+$",
                with: "",
                options: .regularExpression
            )
    }

    private func isNearDuplicateCaptionText(_ lhs: String, _ rhs: String) -> Bool {
        let lhsComparable = comparableCaptionText(lhs)
        let rhsComparable = comparableCaptionText(rhs)
        guard lhsComparable.isEmpty == false,
              rhsComparable.isEmpty == false else {
            return false
        }

        if lhsComparable == rhsComparable {
            return true
        }

        if relaxedComparableCaptionText(lhs) == relaxedComparableCaptionText(rhs) {
            return true
        }

        let maxLength = max(lhsComparable.count, rhsComparable.count)
        guard maxLength >= Self.recentRecognizedNearDuplicateMinimumLength else {
            return false
        }

        let similarity = CaptionLanguagePolicy.normalizedEditSimilarity(lhsComparable, rhsComparable)
        return (1.0 - similarity) <= Self.recentRecognizedNearDuplicateSimilarityThreshold
    }

    private func sanitizedDisplayText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return ""
        }

        return containsSubtitleContent(trimmed) ? trimmed : ""
    }

    private func containsSubtitleContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar) == false
                && CharacterSet.punctuationCharacters.contains(scalar) == false
                && CharacterSet.symbols.contains(scalar) == false
        }
    }

    private func shouldEnqueueRecognizedSentence(_ text: String, promotionID: UUID? = nil) -> Bool {
        let now = Date()
        let comparable = comparableCaptionText(text)
        recentRecognizedCaptionTexts.removeAll { now.timeIntervalSince($0.time) > 6.0 }

        if comparable.isEmpty {
            return false
        }

        if let displayedCaption {
            if let promotionID, displayedCaption.promotionID == promotionID {
                return false
            }
            if promotionID == nil {
                if comparableCaptionText(displayedCaption.sourceText) == comparable
                    && isNearDuplicateCaptionText(displayedCaption.sourceText, text) {
                    return false
                }
            }
        }

        if pendingCaptions.contains(where: {
            if let promotionID, $0.promotionID == promotionID {
                return true
            }
            if promotionID == nil {
                return comparableCaptionText($0.sourceText) == comparable
                    && isNearDuplicateCaptionText($0.sourceText, text)
            }
            return false
        }) {
            return false
        }

        if shouldSuppressArchivedCaptionReplay(
            comparableText: comparable,
            promotionID: promotionID,
            now: now
        ) {
            return false
        }

        return true
    }

    private func rememberRecognizedSentence(_ text: String, promotionID: UUID? = nil) {
        let now = Date()
        recentRecognizedCaptionTexts.removeAll { now.timeIntervalSince($0.time) > 6.0 }
        recentRecognizedCaptionTexts.append(
            RecentRecognizedCaption(
                rawText: text,
                comparableText: comparableCaptionText(text),
                time: now,
                promotionID: promotionID
            )
        )
    }

    private func rememberArchivedCaption(sourceText: String, promotionID: UUID?) {
        let comparable = comparableCaptionText(sourceText)
        guard comparable.isEmpty == false else {
            recentArchivedCaption = nil
            return
        }

        recentArchivedCaption = RecentArchivedCaption(
            rawText: sourceText,
            comparableText: comparable,
            time: Date(),
            promotionID: promotionID
        )
    }

    private func promotedDraftTranslationSnapshot(for promotionID: UUID?) -> String? {
        guard let promotionID,
              let state = overlayState,
              let draftText = state.draftSourceText,
              state.draftPromotionID == promotionID,
              let currentDraftTranslation = state.visibleDraftTranslatedText(
                  for: draftText,
                  promotionID: promotionID
              ) else {
            return nil
        }

        let draftTranslation = sanitizedDisplayText(currentDraftTranslation)
        return draftTranslation.isEmpty ? nil : draftTranslation
    }

    private func markDraftPromotionFinalized(_ id: UUID) {
        let now = Date()
        pruneFinalizedDraftPromotionIDs(now: now)
        finalizedDraftPromotionIDs.removeAll { $0.id == id }
        finalizedDraftPromotionIDs.append((id: id, time: now))
    }

    private func isFinalizedDraftPromotionID(_ id: UUID) -> Bool {
        let now = Date()
        pruneFinalizedDraftPromotionIDs(now: now)
        return finalizedDraftPromotionIDs.contains { $0.id == id }
    }

    private func pruneFinalizedDraftPromotionIDs(now: Date) {
        finalizedDraftPromotionIDs.removeAll { now.timeIntervalSince($0.time) > 12.0 }

        if finalizedDraftPromotionIDs.count > Self.finalizedDraftPromotionLimit {
            finalizedDraftPromotionIDs.removeFirst(
                finalizedDraftPromotionIDs.count - Self.finalizedDraftPromotionLimit
            )
        }
    }

    private func isDraftPromotionPending() -> Bool {
        guard let draftPromotionID = overlayState?.draftPromotionID else {
            return false
        }

        if displayedCaption?.promotionID == draftPromotionID {
            return true
        }

        return pendingCaptions.contains { $0.promotionID == draftPromotionID }
    }

    private func shouldSuppressArchivedCaptionReplay(
        comparableText: String,
        promotionID: UUID?,
        now: Date
    ) -> Bool {
        guard comparableText.isEmpty == false,
              displayedCaption == nil,
              pendingCaptions.isEmpty,
              hasActiveDraftOverlay == false,
              overlayState?.draftPromotionID == nil,
              let recentArchivedCaption,
              now.timeIntervalSince(recentArchivedCaption.time) <= Self.archivedCaptionReplaySuppressionWindow else {
            return false
        }

        if let promotionID,
           recentArchivedCaption.promotionID == promotionID {
            return true
        }

        if recentArchivedCaption.comparableText == comparableText {
            return true
        }

        let maxLength = max(recentArchivedCaption.comparableText.count, comparableText.count)
        guard maxLength >= Self.archivedCaptionNearDuplicateMinimumLength else {
            return false
        }

        let similarity = CaptionLanguagePolicy.normalizedEditSimilarity(
            recentArchivedCaption.comparableText,
            comparableText
        )

        // Suppress only very close revisions of the just-archived sentence.
        return (1.0 - similarity) <= Self.archivedCaptionReplaySimilarityThreshold
    }

    private func waitForTranslatedCaption(id: UUID, timeout: Double = 1.5) async -> String? {
        if let translatedText = readyCaptionTranslations[id] {
            return translatedText
        }

        guard isCaptionPipelineActive else {
            return nil
        }

        let waiterID = UUID()
        let timeoutNanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
        let timeoutTask = Task { @MainActor [weak self] in
            if timeoutNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                } catch {
                    return
                }
            }

            self?.resumeCaptionTranslationWaiter(
                captionID: id,
                waiterID: waiterID,
                translatedText: nil
            )
        }

        return await withTaskCancellationHandler {
            let translatedText = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                if let translatedText = readyCaptionTranslations[id] {
                    continuation.resume(returning: translatedText)
                    return
                }

                guard isCaptionPipelineActive else {
                    continuation.resume(returning: nil)
                    return
                }

                captionTranslationWaiters[id, default: [:]][waiterID] = continuation
            }

            timeoutTask.cancel()
            return translatedText
        } onCancel: {
            timeoutTask.cancel()
            Task { @MainActor [weak self] in
                self?.resumeCaptionTranslationWaiter(
                    captionID: id,
                    waiterID: waiterID,
                    translatedText: nil
                )
            }
        }
    }

    private func translateCaption(_ caption: QueuedCaption) {
        let generation = (captionTranslationGenerations[caption.id] ?? 0) &+ 1
        captionTranslationGenerations[caption.id] = generation
        captionTranslationTasks[caption.id]?.cancel()

        captionTranslationTasks[caption.id] = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let translatedText = await self.translatedText(for: caption)
            guard Task.isCancelled == false else {
                return
            }

            self.completeCaptionTranslation(translatedText, for: caption.id, generation: generation)
        }
    }

    private func translateHistoryRevision(
        id: UUID,
        sourceText: String,
        sourceLanguageID: String,
        targetLanguageID: String,
        usesInverseGlossary: Bool
    ) {
        let generation = (captionTranslationGenerations[id] ?? 0) &+ 1
        captionTranslationGenerations[id] = generation
        captionTranslationTasks[id]?.cancel()

        captionTranslationTasks[id] = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let translated = await self.translatedText(
                sourceText: sourceText,
                sourceLanguageID: sourceLanguageID,
                targetLanguageID: targetLanguageID,
                usesInverseGlossary: usesInverseGlossary
            )
            guard Task.isCancelled == false else {
                return
            }

            self.completeCaptionTranslation(translated ?? "", for: id, generation: generation)
        }
    }

    @discardableResult
    private func completeCaptionTranslation(
        _ translatedText: String?,
        for captionID: UUID,
        generation: UInt64
    ) -> Bool {
        let resolvedID = captionIDByPromotionID[captionID] ?? captionID
        guard isCaptionPipelineActive,
              captionTranslationGenerations[resolvedID] == generation else {
            return false
        }

        updateReadyCaptionTranslation(translatedText, for: resolvedID)
        captionTranslationTasks.removeValue(forKey: resolvedID)
        return true
    }
    private func updateReadyCaptionTranslation(_ translatedText: String?, for captionID: UUID) {
        if let translatedText {
            if shouldCacheReadyCaptionTranslation(for: captionID) {
                readyCaptionTranslations[captionID] = translatedText
            } else {
                readyCaptionTranslations.removeValue(forKey: captionID)
            }
        } else {
            readyCaptionTranslations.removeValue(forKey: captionID)
        }

        resumeCaptionTranslationWaiters(for: captionID, translatedText: translatedText)

        if let translatedText, translatedText.isEmpty == false {
            applyLateCaptionTranslation(translatedText, for: captionID)
        }
    }

    /// shouldCacheReadyCaptionTranslation
    /// Returns true when a completed translation still belongs to the active caption flow.
    private func shouldCacheReadyCaptionTranslation(for captionID: UUID) -> Bool {
        displayedCaption?.id == captionID
            || pendingCaptions.contains(where: { $0.id == captionID })
            || captionTranslationWaiters[captionID]?.isEmpty == false
    }

    /// Backfills a translation that finished after `processCaptionQueue` already moved on.
    /// Without this, captions whose translation arrived after the wait timeout would stay
    /// permanently untranslated in the live overlay, scrollback history, and transcript.
    private func applyLateCaptionTranslation(_ translatedText: String, for captionID: UUID) {
        var didApplyTranslation = false
        var didApplyDisplayedTranslation = false

        if displayedCaption?.id == captionID,
           let caption = displayedCaption {
            let panes = languagePanes(
                heard: caption.sourceText,
                translated: translatedText,
                usesInverseGlossary: caption.usesInverseGlossary
            )
            updateCommittedOverlay(
                translatedText: panes.translatedText,
                sourceText: panes.sourceText,
                lateTranslation: true
            )
            didApplyTranslation = true
            didApplyDisplayedTranslation = true
        }

        if let index = overlayState?.history.lastIndex(where: { $0.id == captionID }) {
            if let transcriptEntry = transcriptEntries.first(where: { $0.id == captionID }) {
                let panes = languagePanes(
                    heard: transcriptEntry.sourceText,
                    translated: translatedText,
                    usesInverseGlossary: inverseGlossaryCaptionIDs.contains(captionID)
                )
                overlayState?.history[index].translatedText = panes.translatedText
                overlayState?.history[index].sourceText = panes.sourceText
            } else {
                overlayState?.history[index].translatedText = translatedText
            }
            didApplyTranslation = true
        }
        if let index = transcriptEntries.firstIndex(where: { $0.id == captionID }),
           shouldReplaceCommittedTranslation(transcriptEntries[index].translatedText, for: captionID) {
            transcriptEntries[index].translatedText = translatedText
            didApplyTranslation = true
        }

        if didApplyTranslation {
            translationRevisions[captionID] = translatedText
        }

        if didApplyDisplayedTranslation {
            scheduleCommittedCaptionArchiveIfNeeded()
        }
    }

    /// holdDisplayedCaption
    /// Keeps the current caption visible, extending the hold if a late translation appears mid-display.
    private func holdDisplayedCaption(_ caption: QueuedCaption, initialHoldDuration: Double) async -> Bool {
        var targetDuration = initialHoldDuration
        var observedLateTranslationAt = Date.distantPast
        var heldRevision = caption.revision

        while Task.isCancelled == false {
            guard isCaptionPipelineActive,
                  displayedCaption?.id == caption.id else {
                return false
            }

            if let active = displayedCaption, active.id == caption.id, active.revision > heldRevision {
                heldRevision = active.revision
                if let state = overlayState {
                    targetDuration = computeDisplayDuration(
                        sourceText: state.sourceText,
                        translatedText: state.translatedText
                    )
                }
            }

            let elapsed = max(0, Date().timeIntervalSince(displayedCaptionLastVisualUpdateAt))
            let remainingDelay = max(0, targetDuration - elapsed)
            if remainingDelay > 0 {
                do {
                    try await Task.sleep(nanoseconds: min(UInt64(remainingDelay * 1_000_000_000), 50_000_000))
                } catch {
                    return false
                }
            } else {
                return true
            }

            guard isCaptionPipelineActive,
                  displayedCaption?.id == caption.id else {
                return false
            }

            if displayedCaptionLastVisualUpdateWasLateTranslation,
               displayedCaptionLastVisualUpdateAt > observedLateTranslationAt,
               let state = overlayState,
               state.translatedText.isEmpty == false {
                observedLateTranslationAt = displayedCaptionLastVisualUpdateAt
                targetDuration = computeDisplayDuration(
                    sourceText: state.sourceText,
                    translatedText: state.translatedText
                )
                continue
            }
        }

        return false
    }

    private func shouldReplaceCommittedTranslation(_ currentText: String, for captionID: UUID) -> Bool {
        if currentText.isEmpty {
            return true
        }

        return translationRevisions[captionID] == currentText
    }

    private func resumeCaptionTranslationWaiter(
        captionID: UUID,
        waiterID: UUID,
        translatedText: String?
    ) {
        guard var waiters = captionTranslationWaiters[captionID],
              let continuation = waiters.removeValue(forKey: waiterID) else {
            return
        }

        if waiters.isEmpty {
            captionTranslationWaiters.removeValue(forKey: captionID)
        } else {
            captionTranslationWaiters[captionID] = waiters
        }

        continuation.resume(returning: translatedText)
    }

    private func resumeCaptionTranslationWaiters(for captionID: UUID, translatedText: String?) {
        guard let waiters = captionTranslationWaiters.removeValue(forKey: captionID) else {
            return
        }

        for continuation in waiters.values {
            continuation.resume(returning: translatedText)
        }
    }

    private func resumeAllCaptionTranslationWaiters(translatedText: String? = nil) {
        let waiters = captionTranslationWaiters
        captionTranslationWaiters.removeAll()

        for captionWaiters in waiters.values {
            for continuation in captionWaiters.values {
                continuation.resume(returning: translatedText)
            }
        }
    }

    private func translatedText(for caption: QueuedCaption) async -> String? {
        await translatedText(
            sourceText: caption.sourceText,
            sourceLanguageID: caption.sourceLanguageID,
            targetLanguageID: caption.targetLanguageID,
            usesInverseGlossary: caption.usesInverseGlossary
        )
    }

    private func translatedText(
        sourceText: String,
        sourceLanguageID: String,
        targetLanguageID: String,
        usesInverseGlossary: Bool
    ) async -> String? {
        guard sourceLanguageID != targetLanguageID else {
            return sourceText
        }

        // The committed caption display path has its own wait timeout. Keep this
        // request alive so a slow translation can still backfill overlay history
        // and transcript entries instead of being dropped permanently.
        // Forward zh→en uses the configured map; affirmative reverse en→zh uses
        // the collision-safe inverse compiled when the glossary changes.
        let effectiveGlossary = usesInverseGlossary ? cachedInverseGlossary : glossary
        let translation: (sourceText: String, translatedText: String)?
        do {
            translation = try await glossaryService.translating(
                sourceText: sourceText,
                glossary: effectiveGlossary
            ) { preparedInput in
                try await self.translationCoordinator(
                    from: sourceLanguageID,
                    to: targetLanguageID
                ).translate(
                    preparedInput,
                    from: sourceLanguageID,
                    to: targetLanguageID
                )
            }
        } catch {
            translation = nil
        }

        guard let translation else {
            return nil
        }

        let translated = sanitizedDisplayText(translation.translatedText)
        guard translated.isEmpty == false,
              shouldTreatAsMissingTranslation(
                  translated,
                  sourceText: translation.sourceText,
                  sourceLanguageID: sourceLanguageID,
                  targetLanguageID: targetLanguageID
              ) == false else {
            return nil
        }
        return translated
    }

    private func resolvedCommittedTranslationText(
        finalTranslation: String?,
        initialTranslation: String?,
        translationExpected: Bool,
        sourceText: String
    ) -> String {
        guard translationExpected else {
            return sourceText
        }

        if let finalTranslation, finalTranslation.isEmpty == false {
            return finalTranslation
        }

        if let initialTranslation, initialTranslation.isEmpty == false {
            return initialTranslation
        }

        return ""
    }

    private func shouldTreatAsMissingTranslation(
        _ translatedText: String,
        sourceText: String,
        sourceLanguageID: String,
        targetLanguageID: String
    ) -> Bool {
        guard sourceLanguageID != targetLanguageID else {
            return false
        }

        let comparableSource = comparableCaptionText(sourceText)
        let comparableTranslation = comparableCaptionText(translatedText)
        guard comparableSource.isEmpty == false,
              comparableSource == comparableTranslation else {
            return false
        }

        return comparableSource.count >= Self.sameLanguageTranslationSuppressionMinimumLength
    }

    /// Language metadata for a transcript fed by `sources`. A mixed selection has no
    /// single language, so it falls back to the global pair.
    private func transcriptLanguageIDs(for sources: [InputSource]) -> (source: String, target: String) {
        let inputIDs = Set(sources.map { languageID(for: $0) })
        let outputIDs = Set(sources.map { outputLanguageIDForSource($0) })
        return (
            inputIDs.count == 1 ? inputIDs.first! : inputLanguageID,
            outputIDs.count == 1 ? outputIDs.first! : outputLanguageID
        )
    }

    /// Retags an existing transcript without discarding it, for when the set of inputs
    /// feeding it turns out to be narrower than the selection it was reset for.
    private func updateTranscriptLanguages(sourceLanguageID: String, targetLanguageID: String) {
        guard transcriptInputLanguageID != sourceLanguageID
            || transcriptOutputLanguageID != targetLanguageID else {
            return
        }

        transcriptInputLanguageID = sourceLanguageID
        transcriptOutputLanguageID = targetLanguageID
        transcriptGeneration &+= 1
    }

    private func resetTranscript(sourceLanguageID: String, targetLanguageID: String) {
        transcriptEntries.removeAll()
        transcriptInputLanguageID = sourceLanguageID
        transcriptOutputLanguageID = targetLanguageID
        transcriptGeneration &+= 1
    }

    private func restoreTranscript(
        entries: [TranscriptEntry],
        sourceLanguageID: String?,
        targetLanguageID: String?
    ) {
        transcriptEntries = entries
        transcriptInputLanguageID = sourceLanguageID
        transcriptOutputLanguageID = targetLanguageID
        transcriptGeneration &+= 1
    }

    private func upsertTranscriptEntry(
        id: UUID,
        sourceText: String,
        translatedText: String
    ) {
        let entry = TranscriptEntry(
            id: id,
            sourceText: sourceText,
            translatedText: translatedText
        )

        if let existingIndex = transcriptEntries.firstIndex(where: { $0.id == id }) {
            transcriptEntries[existingIndex] = entry
        } else {
            transcriptEntries.append(entry)
        }
    }

    private func cancelCaptionTranslations() {
        for task in captionTranslationTasks.values {
            task.cancel()
        }

        captionTranslationTasks.removeAll()
    }

    private func cancelCommittedCaptionArchive() {
        committedCaptionArchiveTask?.cancel()
        committedCaptionArchiveTask = nil
    }

    private func scheduleCommittedCaptionArchiveIfNeeded() {
        cancelCommittedCaptionArchive()

        guard isCaptionPipelineActive,
              pendingCaptions.isEmpty,
              hasActiveDraftOverlay == false,
              currentCommittedCaptionHistoryPayload() != nil else {
            return
        }

        let elapsed = max(0, Date().timeIntervalSince(displayedCaptionLastVisualUpdateAt))
        let remainingDelay = max(0, Self.committedCaptionIdleArchiveDelay - elapsed)

        committedCaptionArchiveTask = Task { @MainActor [weak self] in
            guard let self else { return }

            if remainingDelay > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(remainingDelay * 1_000_000_000))
                } catch {
                    return
                }
            }

            guard !Task.isCancelled,
                  isCaptionPipelineActive,
                  pendingCaptions.isEmpty,
                  hasActiveDraftOverlay == false,
                  currentCommittedCaptionHistoryPayload() != nil else {
                return
            }

            clearOverlayText()
        }
    }

    private var hasActiveDraftOverlay: Bool {
        sanitizedDisplayText(overlayState?.draftSourceText ?? "").isEmpty == false
    }

    private func currentCommittedCaptionHistoryPayload() -> (translatedText: String, sourceText: String)? {
        guard let current = overlayState,
              let displayed = displayedCaption,
              current.translatedText.isEmpty == false || current.sourceText.isEmpty == false,
              current.translatedText != listeningPlaceholderText,
              current.translatedText != captureStoppedText,
              current.translatedText != unableToStartText else {
            return nil
        }

        let isSameLanguage = displayed.sourceLanguageID == displayed.targetLanguageID
        let translated = isSameLanguage ? displayed.sourceText : (current.translatedText.isEmpty ? displayed.sourceText : current.translatedText)
        let source = current.sourceText.isEmpty ? displayed.sourceText : current.sourceText
        return (translated, source)
    }

    private var overlayHistoryCount: Int {
        overlayState?.history.count ?? 0
    }

    private var overlayHistoryMaxScrollOffset: Int {
        max(0, overlayHistoryCount - max(0, overlayHistoryVisibleCount))
    }

    private func clampOverlayHistoryScrollOffset() {
        overlayHistoryScrollOffset = min(max(overlayHistoryScrollOffset, 0), overlayHistoryMaxScrollOffset)
    }

    private func appendOverlayHistoryEntry(
        captionID: UUID? = nil,
        translatedText: String,
        sourceText: String
    ) {
        guard shouldStoreOverlayHistory(translatedText: translatedText, sourceText: sourceText) else {
            return
        }

        if let lastEntry = overlayState?.history.last,
           lastEntry.translatedText == translatedText,
           lastEntry.sourceText == sourceText {
            return
        }

        if overlayHistoryScrollOffset > 0 {
            overlayHistoryScrollOffset += 1
        }

        overlayState?.history.append(
            OverlayHistoryEntry(
                id: captionID ?? UUID(),
                translatedText: translatedText,
                sourceText: sourceText
            )
        )

        let overflow = max(0, (overlayState?.history.count ?? 0) - Self.overlayHistoryLimit)
        if overflow > 0 {
            overlayState?.history.removeFirst(overflow)
            if overlayHistoryScrollOffset > 0 {
                overlayHistoryScrollOffset = max(0, overlayHistoryScrollOffset - overflow)
            }
        }

        clampOverlayHistoryScrollOffset()
    }

    private func shouldStoreOverlayHistory(translatedText: String, sourceText: String) -> Bool {
        let normalizedTranslated = sanitizedDisplayText(translatedText)
        let normalizedSource = sanitizedDisplayText(sourceText)
        guard normalizedTranslated.isEmpty == false || normalizedSource.isEmpty == false else {
            return false
        }

        switch normalizedTranslated {
        case listeningPlaceholderText, captureStoppedText, unableToStartText:
            return false
        default:
            return true
        }
    }

    private func dismissListeningPlaceholderIfNeeded() {
        guard overlayState?.translatedText == listeningPlaceholderText else {
            return
        }

        overlayState?.translatedText = ""
        overlayState?.sourceText = ""
    }

    // MARK: - Display duration (strategy §10)

    /// max(min_hold, reading_time, audio_span × sync_factor), clamped to [1.2, adaptive_max] s
    private func computeDisplayDuration(sourceText: String, translatedText: String) -> Double {
        let displayText: String
        if showsTranslatedSubtitle {
            displayText = translatedText.isEmpty ? sourceText : translatedText
        } else {
            displayText = sourceText.isEmpty ? translatedText : sourceText
        }
        let charCount = Double(displayText.count)
        let isCJK = displayText.unicodeScalars.contains {
            (0x4E00...0x9FFF).contains($0.value)
                || (0x3040...0x30FF).contains($0.value)
                || (0xAC00...0xD7AF).contains($0.value)
        }

        let cps: Double = isCJK ? 7.0 : 13.5
        var readingTime = charCount / cps

        // Bilingual factor: both source and translation shown simultaneously
        if showsOriginalSubtitle && showsTranslatedSubtitle && inputLanguageID != outputLanguageID {
            readingTime *= 1.15
        }

        // Min hold based on length tier
        let minHold: Double
        switch charCount {
        case ..<10:   minHold = 1.2
        case 10..<21: minHold = 1.6
        default:      minHold = 2.0
        }

        let maxHold: Double
        if showsTranslatedSubtitle {
            if isCJK {
                switch charCount {
                case ..<24:  maxHold = 4.5
                case ..<36:  maxHold = 5.4
                default:     maxHold = 6.2
                }
            } else {
                switch charCount {
                case ..<48:  maxHold = 4.5
                case ..<72:  maxHold = 5.4
                default:     maxHold = 6.2
                }
            }
        } else {
            maxHold = 4.5
        }

        return min(max(minHold, readingTime), maxHold)
    }

    private func sampleText(for languageID: String) -> String {
        switch languageID {
        case "zh-Hans":
            return "欢迎使用 Easy2Say，顶部字幕条已经准备好了。"
        case "zh-Hant":
            return "歡迎使用 Easy2Say，頂部字幕列已經準備好了。"
        case "es":
            return "Bienvenido a Easy2Say. La barra de subtitulos ya esta lista."
        case "de":
            return "Willkommen bei Easy2Say. Die Untertitel-Leiste ist bereit."
        case "ja":
            return "Easy2Say へようこそ。字幕バーの準備ができました。"
        case "fr":
            return "Bienvenue dans Easy2Say. La barre de sous-titres est prete."
        case "it":
            return "Benvenuto in Easy2Say. La barra dei sottotitoli e pronta."
        case "ko":
            return "Easy2Say에 오신 것을 환영합니다. 자막 바가 준비되었습니다."
        case "yue":
            return "歡迎使用 Easy2Say，字幕列已經準備好。"
        case "ar":
            return "مرحبا بك في Easy2Say. شريط الترجمة جاهز."
        case "pt":
            return "Bem-vindo ao Easy2Say. A barra de legendas esta pronta."
        case "ru":
            return "Добро пожаловать в Easy2Say. Строка субтитров готова."
        default:
            return "Welcome to Easy2Say. The subtitle bar is ready."
        }
    }

#if DEBUG
    func enqueueRecognizedSentenceForTesting(
        _ sentence: RecognizedSentence,
        source: InputSource = .preview,
        sourceLanguageID: String = "zh-Hant",
        targetLanguageID: String = "en",
        usesInverseGlossary: Bool = false
    ) {
        isSessionActiveForTesting = true
        enqueueRecognizedSentence(
            sentence,
            source: source,
            sourceLanguageID: sourceLanguageID,
            targetLanguageID: targetLanguageID,
            usesInverseGlossary: usesInverseGlossary
        )
    }

    func runCaptionQueueTurnForTesting() async {
        guard isCaptionPipelineActive else { return }
        for _ in 0..<15 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    var displayedCaptionForTesting: (sourceText: String, promotionID: UUID)? {
        guard let displayedCaption else { return nil }
        return (displayedCaption.sourceText, displayedCaption.promotionID)
    }

    var overlayHistoryForTesting: [OverlayHistoryEntry] {
        overlayState?.history ?? []
    }

    var transcriptEntriesForTesting: [TranscriptEntry] {
        transcriptEntries
    }
    func completeHeldCaptionForTesting() {
        displayedCaptionLastVisualUpdateAt = Date.distantPast - 1000
    }
    @discardableResult
    func completeCaptionTranslationForTesting(captionID: UUID, generation: UInt64, translatedText: String) -> Bool {
        completeCaptionTranslation(translatedText, for: captionID, generation: generation)
    }

    func currentTranslationGenerationForTesting(captionID: UUID) -> UInt64? {
        let resolved = captionIDByPromotionID[captionID] ?? captionID
        return captionTranslationGenerations[resolved]
    }
#endif
}

private enum StatusDescriptor: Equatable {
    case ready
    case noInputSourcesDetected
    case running(sourceName: String)
    case chooseInputSourceBeforeStarting
    case checkingLanguageResources
    case downloadLanguageResourcesInSystemSettings
    case preparing(sourceName: String)
    case showingOverlayPreview
    case custom(String)
}

private extension AppModel {
    static let overlayHistoryLimit = 120
    static let draftClearDelayNanoseconds: UInt64 = 150_000_000
    static let committedCaptionIdleArchiveDelay: TimeInterval = 0.9
    static let archivedCaptionReplaySuppressionWindow: TimeInterval = 1.8
    static let archivedCaptionReplaySimilarityThreshold = 0.18
    static let archivedCaptionNearDuplicateMinimumLength = 8
    static let recentRecognizedNearDuplicateMinimumLength = 4
    static let recentRecognizedNearDuplicateSimilarityThreshold = 0.22
    static let sameLanguageTranslationSuppressionMinimumLength = 8
    static let finalizedDraftPromotionLimit = 32
    static let captionComparisonTrimCharacterSet = CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters)
        .union(.symbols)
}

private struct RecentRecognizedCaption {
    let rawText: String
    let comparableText: String
    let time: Date
    let promotionID: UUID?
}

private struct RecentArchivedCaption {
    let rawText: String
    let comparableText: String
    let time: Date
    let promotionID: UUID?
}

private struct LanguagePairRequirement: Hashable {
    let sourceLanguageID: String
    let targetLanguageID: String
}

private struct QueuedCaption: Identifiable, Equatable {
    let id: UUID
    let promotionID: UUID
    let sourceText: String
    let sourceName: String
    let sourceLanguageID: String
    let targetLanguageID: String
    let usesInverseGlossary: Bool
    let promotedDraftTranslation: String?
    let revision: UInt64

    init(
        id: UUID,
        promotionID: UUID,
        sourceText: String,
        sourceName: String,
        sourceLanguageID: String,
        targetLanguageID: String,
        usesInverseGlossary: Bool,
        promotedDraftTranslation: String?,
        revision: UInt64 = 0
    ) {
        self.id = id
        self.promotionID = promotionID
        self.sourceText = sourceText
        self.sourceName = sourceName
        self.sourceLanguageID = sourceLanguageID
        self.targetLanguageID = targetLanguageID
        self.usesInverseGlossary = usesInverseGlossary
        self.promotedDraftTranslation = promotedDraftTranslation
        self.revision = revision
    }
}

struct TranscriptEntry: Identifiable, Equatable {
    let id: UUID
    var sourceText: String
    var translatedText: String
}

private struct SpeechLanguageCatalog {
    let options: [LanguageOption]
    let onDeviceLanguageIDs: Set<String>
}

private enum LanguageResourcePreparationError: LocalizedError, AppLocalizableError {
    case unsupportedSpeechLanguage
    case speechDownloadTimedOut
    case translationDownloadTimedOut

    func localizedDescription(languageID: String) -> String {
        switch self {
        case .unsupportedSpeechLanguage:
            return AppLocalization.string(.speechResourcesNotSupportedOnMacOS, languageID: languageID)
        case .speechDownloadTimedOut:
            return AppLocalization.string(.speechResourceDownloadTimedOut, languageID: languageID)
        case .translationDownloadTimedOut:
            return AppLocalization.string(.translationResourceDownloadTimedOut, languageID: languageID)
        }
    }

    var errorDescription: String? {
        localizedDescription(languageID: "en")
    }
}

private enum LanguageResourceSystemSettingsDestination: Hashable {
    case keyboard
    case translationLanguages

    var urlString: String {
        switch self {
        case .keyboard:
            return "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
        case .translationLanguages:
            return "x-apple.systempreferences:com.apple.Localization-Settings.extension"
        }
    }
}

struct LanguageResourceStatus: Identifiable, Equatable {
    enum Kind: Int {
        case speech = 0
        case translation = 1
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let progress: Double?
    let isError: Bool
}

extension View {
    @ViewBuilder
    func v2sTranslationHost(model: AppModel) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            self
                .translationTask(model.translationHostConfiguration) { session in
                    await model.runTranslationHost(using: session)
                }
                .translationTask(model.reverseTranslationHostConfiguration) { session in
                    await model.runReverseTranslationHost(using: session)
                }
        } else {
            self
        }
    }
}
