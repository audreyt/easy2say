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
    private let sourceCatalogService: any SourceCatalogProviding
    private let translationCoordinator = TranslationCoordinator()
    private let reverseTranslationCoordinator = TranslationCoordinator()
#if os(macOS)
    private let openAICompatibleTranslationService = OpenAICompatibleTranslationService()
#endif
    private let glossaryService = GlossaryService()
    private var speechCorrections = SpeechCorrectionTable.empty
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
    /// Single analyzer-driven caption pipeline; created in `init` and fed
    /// `CaptionSessionEvent`s forwarded from every started session.
    private(set) var captionPipeline: CaptionPipeline!
    /// Next lane `sessionID` allocated for a transcription session.
    private var nextCaptionSessionID = 1
    /// sessionID assigned at start, keyed by the session's identity.
    private var sessionCaptionIDs: [ObjectIdentifier: Int] = [:]
    /// Stable transcript entry UUID per caption row.
    private var transcriptEntryIDsByRow: [CaptionRowID: UUID] = [:]
    /// Row ordinal currently shown as the committed caption on `overlayState`.
    private var overlayCommittedRowID: CaptionRowID?
    private var isBootstrapping = true
    private var usesSystemInterfaceLanguage = true
    private var languageResourcePreparationTask: Task<Void, Never>?
    private var languageCatalogRefreshTask: Task<Void, Never>?
    private var isRefreshingLanguageCatalogs = false
    private var transcriptInputLanguageID: String?
    private var transcriptOutputLanguageID: String?
    private var isCaptionPipelineActive: Bool {
        liveTranscriptionSession != nil
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
    /// Analyzer-driven caption document (V2). Fed by tests / DEBUG hooks in A3;
    /// the transcription session wires it in A4.
    @Published private(set) var captionDocument = CaptionDocument(rows: [], revision: 0) {
        didSet { pushDisplayedCaptionDocumentToControllers() }
    }

    /// Overlay/audience caption surfaces render through these.
    let overlayCaptionSurface = CaptionSurfaceController()
    let audienceCaptionSurface = CaptionSurfaceController()

    /// Pane configuration from the current display settings.
    var captionPaneConfig: CaptionPaneConfig {
        CaptionPaneConfig(
            originalLanguageID: translationSourceLanguageID(for: inputLanguageID),
            showsOriginal: showsOriginalSubtitle,
            showsTranslated: showsTranslatedSubtitle
        )
    }

    /// The document surfaces draw: with "Live draft captions" off, only sealed
    /// rows reach the glass.
    var displayedCaptionDocument: CaptionDocument {
        guard liveDraftCaptions == false else { return captionDocument }
        return CaptionDocument(
            rows: captionDocument.rows.filter(\.isSealed),
            revision: captionDocument.revision
        )
    }

    /// Same-turn push: whatever published the document change also lays out the
    /// surfaces, so no body pass can render a stale screen next to fresh state.
    private func pushDisplayedCaptionDocumentToControllers() {
        let document = displayedCaptionDocument
        overlayCaptionSurface.update(document: document)
        audienceCaptionSurface.update(document: document)
        syncTranscriptEntries(from: captionDocument)
        syncCommittedCaptionState(from: captionDocument)
    }

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
    /// Run live diarization so committed captions and turns get a speaker index.
    @Published var speakerDiarizationEnabled: Bool { didSet { persistSettings() } }
    /// Show the "Speaker A/B/…" pill on captions and turns. Independent of
    /// `speakerDiarizationEnabled` — attribution can keep running while the
    /// pill stays hidden.
    @Published var showsSpeakerBadges: Bool { didSet { persistSettings() } }
    /// Show the gray in-progress hypothesis while speech is being recognized.
    /// Off renders committed captions only — no revisable tail.
    @Published var liveDraftCaptions: Bool {
        didSet {
            pushDisplayedCaptionDocumentToControllers()
            persistSettings()
        }
    }

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
    @Published var customTranslationBaseURL: String {
        didSet { translationBackendConfigurationDidChange() }
    }
    @Published var customTranslationAPIKey: String {
        didSet { customTranslationAPIKeyDidChange() }
    }
    @Published var customTranslationModelID: String {
        didSet { translationBackendConfigurationDidChange() }
    }

    init(
        settingsStore: SettingsStore,
        sourceCatalogService: any SourceCatalogProviding
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
        self.speakerDiarizationEnabled = settings.speakerDiarizationEnabled
        self.showsSpeakerBadges = settings.showsSpeakerBadges
        self.liveDraftCaptions = settings.liveDraftCaptions
        self.usesSystemInterfaceLanguage = settings.interfaceLanguageID == nil
        self.interfaceLanguageID = LanguageCatalog.preferredInterfaceLanguageID(
            storedIdentifier: settings.interfaceLanguageID
        )
        let normalizedOverlayStyle = AppModel.normalizedOverlayStyle(settings.overlayStyle)
        self.overlayStyle = normalizedOverlayStyle
        self.subtitleMode = settings.subtitleMode
        self.subtitleDisplayMode = settings.subtitleDisplayMode
        self.glossary = settings.glossary
        self.customTranslationBaseURL = settings.customTranslationBaseURL
#if os(macOS)
        self.customTranslationAPIKey = CustomTranslationAPIKeyStore.load()
#else
        self.customTranslationAPIKey = ""
#endif
        self.customTranslationModelID = settings.customTranslationModelID
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
        captionPipeline = CaptionPipeline(
            correct: { [weak self] text, languageID in
                MainActor.assumeIsolated {
                    self?.speechCorrections.apply(text, languageID: languageID) ?? text
                }
            },
            translate: { [weak self] request in
                await self?.captionTranslate(request)
            }
        )
        captionPipeline.onDocumentChange = { [weak self] document in
            self?.captionDocument = document
        }
        installTranslationBackends(on: translationCoordinator)
        installTranslationBackends(on: reverseTranslationCoordinator)
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

    func installTranslationBackends(on coordinator: TranslationCoordinator) {
        coordinator.preferredPrepare = { [weak self] source, target in
            guard let self else { return false }
            return try await self.preparePreferredTranslationBackend(
                from: source,
                to: target
            )
        }
        coordinator.preferredTranslate = { [weak self] text, source, target in
            guard let self else { return nil }
            return try await self.translateWithPreferredBackend(
                text,
                from: source,
                to: target
            )
        }
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
    func installTranslationBackends(on engine: ConversationEngine) {
        engine.installTranslationBackends(
            preferredPrepare: { [weak self] source, target in
                guard let self else { return false }
                return try await self.preparePreferredTranslationBackend(
                    from: source,
                    to: target
                )
            },
            preferredTranslate: { [weak self] text, source, target in
                guard let self else { return nil }
                return try await self.translateWithPreferredBackend(
                    text,
                    from: source,
                    to: target
                )
            },
            fallbackPrepare: { [weak self] source, target in
                guard let self else {
                    throw TranslationCoordinator.ServiceError.unavailableOnSystem
                }
                try await self.prepareTranslationFallback(from: source, to: target)
            },
            fallbackTranslate: { [weak self] text, source, target in
                guard let self else {
                    throw TranslationCoordinator.ServiceError.unavailableOnSystem
                }
                return try await self.translateWithFallback(text, from: source, to: target)
            }
        )
    }

    private func preparePreferredTranslationBackend(
        from source: String,
        to target: String
    ) async throws -> Bool {
#if os(macOS)
        guard let config = customTranslationConfig else { return false }
        try await openAICompatibleTranslationService.prepare(
            from: source,
            to: target,
            config: config
        )
        return true
#else
        _ = source
        _ = target
        return false
#endif
    }

    private func translateWithPreferredBackend(
        _ text: String,
        from source: String,
        to target: String
    ) async throws -> String? {
#if os(macOS)
        guard let config = customTranslationConfig else { return nil }
        return try await openAICompatibleTranslationService.translate(
            text,
            from: source,
            to: target,
            config: config
        )
#else
        _ = text
        _ = source
        _ = target
        return nil
#endif
    }

    private func prepareTranslationFallback(from source: String, to target: String) async throws {
#if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            try await FoundationModelsTranslationService().prepare(from: source, to: target)
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
#if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            return try await FoundationModelsTranslationService().translate(
                text,
                from: source,
                to: target
            )
        }
#endif
        throw TranslationCoordinator.ServiceError.unsupportedPair(source, target)
    }

#if os(macOS)
    private var customTranslationConfig: OpenAICompatibleTranslation.Config? {
        OpenAICompatibleTranslation.Config.resolve(
            settingsBaseURL: customTranslationBaseURL,
            settingsAPIKey: customTranslationAPIKey,
            settingsModelID: customTranslationModelID
        )
    }
#endif

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
#if DEBUG
            let session = makeTranscriptionSessionForTesting?() ?? LiveTranscriptionSession()
#else
            let session = LiveTranscriptionSession()
#endif
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
            let captionSessionID = nextCaptionSessionID
            nextCaptionSessionID += 1
            sessionCaptionIDs[sessionID] = captionSessionID
            let wantsDualLane = CaptionLanguagePolicy.shouldEnableDualLane(
                sourceLanguageID: translationSourceLanguageID,
                targetLanguageID: targetLanguageID
            )
            captionPipeline.handle(.sessionStarted(CaptionSessionConfig(
                sessionID: captionSessionID,
                primaryLanguageID: translationSourceLanguageID,
                secondaryLanguageID: wantsDualLane ? "en" : "",
                targetLanguageID: targetLanguageID,
                translates: translationSourceLanguageID != targetLanguageID || wantsDualLane,
                timing: Self.captionTiming(for: subtitleMode)
            )))

            do {
                try await session.start(
                    source: source,
                    localeIdentifier: speechLocaleIdentifier(for: sourceLanguageID),
                    interfaceLanguageID: resolvedInterfaceLanguageID,
                    contextualStrings: primaryRecognitionHints,
                    secondaryContextualStrings: secondaryRecognitionHints,
                    sourceLanguageID: translationSourceLanguageID,
                    targetLanguageID: targetLanguageID,
                    speakerDiarizationEnabled: speakerDiarizationEnabled,
                    captionSessionID: captionSessionID,
                    eventHandler: { [weak self] event in
                        self?.handleCaptionSessionEvent(
                            sessionID: captionSessionID,
                            event: event
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
                    sendSessionStopped(for: session)
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
                sendSessionStopped(for: session)
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
                    sendSessionStopped(for: startedSession)
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
                sendSessionStopped(for: session)
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

    /// Stops the sessions on their capture queues; after each drain finishes,
    /// `sessionStopped` seals the session's caption rows.
    private func stopLiveTranscriptionSessions() {
        let sessions = takeLiveTranscriptionSessions()
        Task { [self] in
            for session in sessions {
                await session.stopAndWait()
                sendSessionStopped(for: session)
            }
        }
    }

    private func stopLiveTranscriptionSessionsAndWait() async {
        let sessions = takeLiveTranscriptionSessions()
        for session in sessions {
            await session.stopAndWait()
            sendSessionStopped(for: session)
        }
    }

    private func sendSessionStopped(for session: LiveTranscriptionSession) {
        guard let captionSessionID = sessionCaptionIDs.removeValue(
            forKey: ObjectIdentifier(session)
        ) else { return }
        captionPipeline.handle(.sessionStopped(sessionID: captionSessionID))
    }

    // MARK: - Caption pipeline

    /// The session's ordered event queue delivers these on the main actor in
    /// capture order.
    private func handleCaptionSessionEvent(sessionID: Int, event: CaptionSessionEvent) {
        switch event {
        case .result(let result):
            captionPipeline.handle(.result(sessionID: sessionID, result))
        case .vad(let edge, let audioMs):
            captionPipeline.handle(.vad(sessionID: sessionID, edge, audioMs: audioMs))
        }
    }

    /// SubtitleMode -> caption pacing (spec A4): follow prioritizes latency,
    /// reading prefers settled lines and shows no draft translations.
    static func captionTiming(for mode: SubtitleMode) -> CaptionTiming {
        switch mode {
        case .follow:
            return CaptionTiming(
                draftSpacingMs: 700,
                idleSealMs: 1_200,
                vadSealMs: 400,
                showsDraftTranslations: true
            )
        case .balanced:
            return CaptionTiming(
                draftSpacingMs: 1_000,
                idleSealMs: 1_500,
                vadSealMs: 500,
                showsDraftTranslations: true
            )
        case .reading:
            return CaptionTiming(
                draftSpacingMs: 1_600,
                idleSealMs: 2_000,
                vadSealMs: 700,
                showsDraftTranslations: false
            )
        }
    }

    /// Pipeline translation closure: preferred backend with fallback behind the
    /// glossary service, inverse glossary when a heard language maps back to the
    /// configured source (dual-lane English rows translating zh→en→zh).
    private func captionTranslate(_ request: CaptionTranslationRequest) async -> String? {
        let configuredSource = translationSourceLanguageID(for: inputLanguageID)
        let configuredTarget = outputLanguageID
        let usesInverseGlossary = CaptionLanguagePolicy.shouldReverse(
            configuredSourceLanguageID: configuredSource,
            configuredTargetLanguageID: configuredTarget,
            heardLanguageID: request.sourceLanguageID,
            heardText: request.text,
            evidence: nil
        ) || request.targetLanguageID == configuredSource
        return await translatedText(
            sourceText: request.text,
            sourceLanguageID: request.sourceLanguageID,
            targetLanguageID: request.targetLanguageID,
            usesInverseGlossary: usesInverseGlossary
        )
    }

    /// One transcript entry per sealed row, keyed by a stable UUID so entries
    /// update in place while the row's text or translation settles. The columns
    /// are row-semantic (spoken text + its translation); pane projection maps
    /// display panes, which invert for dual-lane English rows.
    private func syncTranscriptEntries(from document: CaptionDocument) {
        var entries: [TranscriptEntry] = []
        for row in document.rows where row.isSealed {
            let entryID: UUID
            if let existing = transcriptEntryIDsByRow[row.id] {
                entryID = existing
            } else {
                entryID = UUID()
                transcriptEntryIDsByRow[row.id] = entryID
            }
            entries.append(TranscriptEntry(
                id: entryID,
                sourceText: row.text,
                translatedText: row.translation,
                speakerIndex: row.speakerIndex
            ))
        }
        transcriptEntries = entries
        transcriptGeneration &+= 1
    }

    /// While a session runs and the document has rows, `overlayState` exposes a
    /// committed-only caption built from the last row's pane texts so iOS
    /// `CaptionHalves` shows the latest row.
    private func syncCommittedCaptionState(from document: CaptionDocument) {
        guard isCaptionPipelineActive else { return }
        guard let last = document.rows.last else { return }

        var state = overlayState ?? OverlayPreviewState(
            translatedText: "",
            sourceText: "",
            sourceName: activeSourceDisplayName
        )
        let panes = CaptionPaneProjection.paneTexts(for: last, config: captionPaneConfig)
        state.translatedText = panes[.translated]?.text ?? ""
        state.sourceText = panes[.original]?.text ?? ""
        state.committedSpeakerIndex = last.speakerIndex
        if overlayCommittedRowID != last.id {
            state.captionEpoch += 1
            overlayCommittedRowID = last.id
        }
        overlayState = state
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
            speakerDiarizationEnabled: speakerDiarizationEnabled,
            showsSpeakerBadges: showsSpeakerBadges,
            liveDraftCaptions: liveDraftCaptions,
            interfaceLanguageID: usesSystemInterfaceLanguage ? nil : interfaceLanguageID,
            overlayStyle: overlayStyle,
            subtitleMode: subtitleMode,
            subtitleDisplayMode: subtitleDisplayMode,
            glossary: glossary,
            customTranslationBaseURL: customTranslationBaseURL,
            customTranslationModelID: customTranslationModelID
        )

        settingsStore.save(settings)
    }

    private func customTranslationAPIKeyDidChange() {
        guard isBootstrapping == false else { return }
#if os(macOS)
        if CustomTranslationAPIKeyStore.save(customTranslationAPIKey) == false {
            fputs("Failed to save custom translation API key to Keychain.\n", stderr)
        }
#endif
        translationBackendConfigurationDidChange()
    }

    private func translationBackendConfigurationDidChange() {
        guard isBootstrapping == false else { return }
        translationCoordinator.reset()
        reverseTranslationCoordinator.reset()
        persistSettings()
        refreshSupportedLanguageOptions()
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
#if os(macOS)
        if let config = customTranslationConfig {
            do {
                try await openAICompatibleTranslationService.prepare(
                    from: "bo",
                    to: "en",
                    config: config
                )
                if options.contains(where: { $0.id == "bo" }) == false {
                    options.append(
                        LanguageOption(
                            id: "bo",
                            displayName: "Tibetan",
                            localeIdentifier: "bo"
                        )
                    )
                }
            } catch is CancellationError {
                return options
            } catch {
                // A configured but unavailable endpoint does not advertise
                // language pairs Apple Translation does not support.
            }
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

            // Translations now flow through the caption pipeline; sealed rows
            // re-request finals per the core's retry policy.
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
#if DEBUG
        if let translationAvailabilityForTesting {
            return translationAvailabilityForTesting
        }
#endif
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








    // MARK: - Overlay history



    /// Applies one logical caption update and publishes it once. The audience
    /// display folds every published `overlayState` into the rows it retains, so
    /// field-by-field writes would hand it states no viewer should see.
    private func updateOverlay(_ update: (inout OverlayPreviewState) -> Void) {
        guard var state = overlayState else { return }
        update(&state)
        if state != overlayState {
            overlayState = state
        }
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
        // Pane arrangement changes come from `captionPaneConfig`; the views
        // push a new viewport config on the style signature, but the surfaces
        // also need the document re-emitted so placeholders redraw now.
        pushDisplayedCaptionDocumentToControllers()
        syncCommittedCaptionState(from: captionDocument)
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
            .map { entry in
                let text = isTranslation ? entry.translatedText : entry.sourceText
                guard let speakerIndex = entry.speakerIndex else { return text }
                return "\(speakerLabel(for: speakerIndex)): \(text)"
            }
            .filter { $0.isEmpty == false }
            .joined(separator: "\n")
    }

    /// "Speaker A" / "Speaker B" … in the interface language.
    func speakerLabel(for index: Int) -> String {
        let letter = String(UnicodeScalar(UInt8(ascii: "A") + UInt8(min(index, 25))))
        return localized(.speakerNameFormat, letter)
    }

    func clearTranscript() {
        transcriptEntries.removeAll()
        transcriptEntryIDsByRow.removeAll()
        transcriptGeneration &+= 1
        captionPipeline.handle(.reset)
    }


    private func resetLiveTextPipeline() {
        translationCoordinator.invalidateSession()
        translationCoordinator.reset()
        reverseTranslationCoordinator.invalidateSession()
        reverseTranslationCoordinator.reset()
        overlayCommittedRowID = nil
    }








    private func normalizedCaptionText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
    }

    private func comparableCaptionText(_ text: String) -> String {
        normalizedCaptionText(text)
            .trimmingCharacters(in: Self.captionComparisonTrimCharacterSet)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }



    private func containsSubtitleContent(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            CharacterSet.letters.contains($0)
                || CharacterSet.decimalDigits.contains($0)
                || LanguageIdentity.isCJKScalar($0)
        }
    }

    private func sanitizedDisplayText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return ""
        }

        return containsSubtitleContent(trimmed) ? trimmed : ""
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
        transcriptEntryIDsByRow.removeAll()
        transcriptInputLanguageID = sourceLanguageID
        transcriptOutputLanguageID = targetLanguageID
        transcriptGeneration &+= 1
        // Transcript reset is the caption document's reset boundary.
        captionPipeline.handle(.reset)
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








    private var overlayHistoryCount: Int {
        displayedCaptionDocument.rows.count
    }

    private var overlayHistoryMaxScrollOffset: Int {
        max(0, overlayHistoryCount - max(0, overlayHistoryVisibleCount))
    }

    private func clampOverlayHistoryScrollOffset() {
        overlayHistoryScrollOffset = min(max(overlayHistoryScrollOffset, 0), overlayHistoryMaxScrollOffset)
    }




    // MARK: - Display duration (strategy §10)


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
    /// Supplies the session `startSession()` opens for each selected source, so an
    /// end-to-end test can drive the production recognizer with injected audio.
    var makeTranscriptionSessionForTesting: (() -> LiveTranscriptionSession)?

    /// Answers translation availability and Apple-tier translation for both
    /// directions without a view-anchored `TranslationSession`, so caption timing
    /// under a known translation latency is reproducible.
    private var translationAvailabilityForTesting: LanguageAvailability.Status?

    func installTranslationForTesting(
        _ translate: @escaping @MainActor (String, String, String) async throws -> String
    ) {
        translationAvailabilityForTesting = .installed
        for coordinator in [translationCoordinator, reverseTranslationCoordinator] {
            coordinator.appleAvailability = { _, _ in .installed }
            coordinator.appleTranslate = { text, source, target, _ in
                try await translate(text, source, target)
            }
        }
    }

    func setOverlayStateForTesting(_ state: OverlayPreviewState) {
        overlayState = state
        sessionState = .running
    }

    func setCaptionDocumentForTesting(_ document: CaptionDocument) {
        captionDocument = document
    }







    var overlayStateForTesting: OverlayPreviewState? {
        overlayState
    }




    var transcriptEntriesForTesting: [TranscriptEntry] {
        transcriptEntries
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
    static let sameLanguageTranslationSuppressionMinimumLength = 8
    static let captionComparisonTrimCharacterSet = CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters)
        .union(.symbols)
}



private struct LanguagePairRequirement: Hashable {
    let sourceLanguageID: String
    let targetLanguageID: String
}


struct TranscriptEntry: Identifiable, Equatable {
    let id: UUID
    var sourceText: String
    var translatedText: String
    /// Display speaker index (0 = first speaker heard), or nil.
    var speakerIndex: Int? = nil
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
