import AVFoundation
import Combine
import CoreMedia
import Foundation
import Speech
import Translation

/// Drives a two-way, on-device conversation between two languages over a single
/// microphone capture.
///
/// **Why this is not just two captioning sessions.** Apple's Speech stack has no
/// spoken-language identification API: `SpeechTranscriber` is pinned to exactly one
/// `Locale`, and a transcriber fed audio in a language it was not built for still
/// emits fluent-looking text in its own script. And a second `LiveTranscriptionSession`
/// is not an option on iOS: each session owns its own `AVCaptureSession` and activates
/// the one process-wide `AVAudioSession`, so whichever session stops first tears the
/// other one's input down with it.
///
/// So this engine owns one capture, converts it once, and fans the same buffers into
/// two `SpeechTranscriber` lanes — one per conversation side. Both lanes report a mean
/// `transcriptionConfidence` for identical audio, and `ConversationFloorArbiter` turns
/// that confidence gap into a stable answer to "who is talking right now".
///
/// Translation runs in both directions at once through two `TranslationCoordinator`s.
/// One coordinator can anchor only one `TranslationSession`, so a single coordinator
/// would re-anchor — and reload translation models — on every speaker change.
@available(macOS 26.0, *)
@MainActor
final class ConversationEngine: ObservableObject {
    enum Phase: Equatable, Sendable {
        case idle
        case preparing
        case listening
        /// Carries an already-localized message.
        case failed(String)
    }

    /// Debounce before translating a live draft. Long enough that a fast talker does
    /// not queue a translation per word, short enough to read as immediate.
    private static let draftTranslationDelay: Duration = .milliseconds(80)
    /// Cap on retained turns. A market haggle is short; a day of meetings is not.
    private static let turnHistoryLimit = 200

    // MARK: - Published state

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var floor: ConversationSide = .primary
    /// Oldest first. Each side reads this same list in its own language.
    @Published private(set) var turns: [ConversationTurn] = []
    @Published private(set) var primaryDraft = ConversationDraft()
    @Published private(set) var secondaryDraft = ConversationDraft()
    /// Host these with two separate SwiftUI `.translationTask` modifiers so both
    /// directions stay warm for the whole conversation.
    @Published private(set) var primaryTranslationConfiguration: TranslationSession.Configuration?
    @Published private(set) var secondaryTranslationConfiguration: TranslationSession.Configuration?

    /// Language used for engine-produced messages. Set before `start()`.
    var interfaceLanguageID = "en"

    private(set) var primaryLanguageID = "zh-Hant"
    private(set) var secondaryLanguageID = "en"

    var isRunning: Bool {
        switch phase {
        case .preparing, .listening:
            return true
        case .idle, .failed:
            return false
        }
    }

    // MARK: - Private state

    /// One coordinator per direction: `primary` translates what the primary side says
    /// into the secondary language, and vice versa.
    private let translators: [ConversationSide: TranslationCoordinator] = [
        .primary: TranslationCoordinator(),
        .secondary: TranslationCoordinator(),
    ]

    private var arbiter = ConversationFloorArbiter()
    private var lanes: [ConversationSide: ConversationLane] = [:]
    private var hypotheses: [ConversationSide: LaneHypothesis] = [:]
    private var audioTap: ConversationAudioTap?
    private var startTask: Task<Void, Never>?
    private var draftTranslationTasks: [ConversationSide: Task<Void, Never>] = [:]
    private var turnTranslationTasks: [UUID: Task<Void, Never>] = [:]
    /// Identifies the utterance currently being drafted, so a late draft translation
    /// for a superseded utterance is dropped instead of overwriting the new one.
    private var draftID = UUID()
    /// Capture-timeline position through which audio has already become a turn.
    private var committedAudioEndSeconds: Double = 0

    private struct LaneHypothesis {
        var volatileText = ""
        var confidence: Double = 0
        var finalizedText: String?
        /// End of the audio this hypothesis describes, in capture-timeline seconds.
        var endSeconds: Double = 0

        var arbiterObservation: ConversationFloorArbiter.Observation {
            ConversationFloorArbiter.Observation(
                confidence: confidence,
                text: finalizedText ?? volatileText,
                isFinal: finalizedText != nil
            )
        }
    }

    init() {
        for (side, translator) in translators {
            translator.localeIdentifierForLanguageID = { languageID in
                LanguageCatalog.translationLocaleIdentifier(for: languageID)
            }
            translator.onConfigurationChange = { [weak self] configuration in
                guard let self else { return }
                switch side {
                case .primary:
                    self.primaryTranslationConfiguration = configuration
                case .secondary:
                    self.secondaryTranslationConfiguration = configuration
                }
            }
        }
    }

    // MARK: - Reading the conversation

    func languageID(for side: ConversationSide) -> String {
        side == .primary ? primaryLanguageID : secondaryLanguageID
    }

    func draft(for side: ConversationSide) -> ConversationDraft {
        side == .primary ? primaryDraft : secondaryDraft
    }

    /// A committed turn as `reader` sees it: their own words verbatim, the other
    /// person's words translated. Neither side is ever shown a language they do not
    /// read, which is the whole point of the mode.
    func text(of turn: ConversationTurn, readBy reader: ConversationSide) -> String {
        turn.side == reader ? turn.sourceText : turn.translatedText
    }

    /// The live, uncommitted utterance as `reader` sees it. Empty when nobody is
    /// mid-sentence.
    func draftText(readBy reader: ConversationSide) -> String {
        let speaking = draft(for: floor)
        guard speaking.sourceText.isEmpty == false else {
            return ""
        }
        return floor == reader ? speaking.sourceText : speaking.translatedText
    }

    // MARK: - Lifecycle

    func configure(primaryLanguageID: String, secondaryLanguageID: String) {
        guard primaryLanguageID != self.primaryLanguageID
            || secondaryLanguageID != self.secondaryLanguageID else {
            return
        }

        self.primaryLanguageID = primaryLanguageID
        self.secondaryLanguageID = secondaryLanguageID

        if isRunning {
            stop()
        }
        translators.values.forEach { $0.reset() }
    }

    func start() async {
        guard isRunning == false else {
            return
        }

        guard primaryLanguageID != secondaryLanguageID else {
            phase = .failed(localized(.conversationSameLanguage))
            return
        }

        phase = .preparing
        arbiter = ConversationFloorArbiter()
        floor = arbiter.floor
        hypotheses = [.primary: LaneHypothesis(), .secondary: LaneHypothesis()]
        committedAudioEndSeconds = 0
        clearDrafts()

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performStart()
        }
        startTask = task
        await task.value
    }

    func stop() {
        startTask?.cancel()
        startTask = nil

        for task in draftTranslationTasks.values {
            task.cancel()
        }
        draftTranslationTasks.removeAll()

        audioTap?.stop()
        audioTap = nil

        for lane in lanes.values {
            lane.finish()
        }
        lanes.removeAll()

        hypotheses = [:]
        clearDrafts()
        if case .failed = phase {} else {
            phase = .idle
        }
    }

    /// Hands the floor to `side` for the current utterance.
    ///
    /// The manual override matters: in a loud room the arbiter can attribute an
    /// utterance to the wrong side, and tapping the right half is faster than
    /// out-arguing a confidence score.
    func claimFloor(_ side: ConversationSide) {
        guard isRunning else {
            return
        }
        guard side != floor else {
            return
        }

        let carried = draft(for: floor)
        arbiter.pin(side)
        floor = side
        migrateDraft(carried, to: side)
    }

    func clearTurns() {
        for task in turnTranslationTasks.values {
            task.cancel()
        }
        turnTranslationTasks.removeAll()
        turns.removeAll()
    }

    // MARK: - Translation hosts

    func runPrimaryTranslationHost(using session: TranslationSession) async {
        await translators[.primary]?.run(using: session)
    }

    func runSecondaryTranslationHost(using session: TranslationSession) async {
        await translators[.secondary]?.run(using: session)
    }

    // MARK: - Startup

    private func performStart() async {
        guard SpeechTranscriber.isAvailable else {
            phase = .failed(localized(.conversationUnavailableFormat, autonym(for: primaryLanguageID)))
            return
        }

        guard await requestRequiredPermissions() else {
            return
        }

        var transcribers: [ConversationSide: SpeechTranscriber] = [:]
        var resolvedLocales: [ConversationSide: Locale] = [:]
        for side in ConversationSide.allCases {
            let languageID = languageID(for: side)
            let requested = Locale(identifier: LanguageCatalog.speechLocaleIdentifier(for: languageID))
            guard let resolved = await LiveTranscriptionSession.modernSpeechLocale(equivalentTo: requested) else {
                phase = .failed(localized(.conversationUnavailableFormat, autonym(for: languageID)))
                return
            }

            resolvedLocales[side] = resolved
            transcribers[side] = SpeechTranscriber(
                locale: resolved,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults],
                attributeOptions: [.audioTimeRange, .transcriptionConfidence]
            )
        }

        guard Task.isCancelled == false else {
            return
        }

        let modules = ConversationSide.allCases.compactMap { transcribers[$0] }
        do {
            try await ConversationLane.installAssetsIfNeeded(
                for: ConversationSide.allCases.compactMap { side in
                    guard let transcriber = transcribers[side], let locale = resolvedLocales[side] else {
                        return nil
                    }
                    return (transcriber: transcriber, locale: locale)
                }
            )
        } catch {
            phase = .failed(localizedErrorDescription(error))
            return
        }

        guard Task.isCancelled == false else {
            return
        }

        // One format both lanes accept, so the capture is converted once and the same
        // buffer object is handed to both analyzers.
        let captureFormat = ConversationAudioTap.captureFormat
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: modules,
            considering: captureFormat
        ) ?? captureFormat

        var startedLanes: [ConversationSide: ConversationLane] = [:]
        for side in ConversationSide.allCases {
            guard let transcriber = transcribers[side] else { continue }
            let lane = ConversationLane(side: side, transcriber: transcriber)
            do {
                try await lane.start(analyzerFormat: analyzerFormat) { [weak self] update in
                    Task { @MainActor [weak self] in
                        self?.apply(update)
                    }
                }
            } catch {
                startedLanes.values.forEach { $0.finish() }
                lane.finish()
                phase = .failed(localizedErrorDescription(error))
                return
            }
            startedLanes[side] = lane
        }

        guard Task.isCancelled == false else {
            startedLanes.values.forEach { $0.finish() }
            return
        }

        lanes = startedLanes

        let tap = ConversationAudioTap(outputFormat: analyzerFormat)
        // Hand the lanes to the closure directly rather than reading `self.lanes` on
        // the main actor: an actor hop per 10 ms buffer would cost a Task allocation
        // 100 times a second and add jitter to the one signal the arbiter depends on.
        let laneFanout = ConversationSide.allCases.compactMap { startedLanes[$0] }
        tap.onBuffer = { buffer in
            for lane in laneFanout {
                lane.append(buffer)
            }
        }

        do {
            try tap.start()
        } catch {
            startedLanes.values.forEach { $0.finish() }
            lanes.removeAll()
            phase = .failed(localizedErrorDescription(error))
            return
        }

        audioTap = tap

        // Warm both directions before the first utterance so the opening sentence is
        // not the one that pays for model loading.
        for side in ConversationSide.allCases {
            let source = languageID(for: side)
            let target = languageID(for: side.opposite)
            Task { [weak self] in
                try? await self?.translators[side]?.prepareIfNeeded(from: source, to: target)
            }
        }

        phase = .listening
    }

    // MARK: - Lane results

    private func apply(_ update: ConversationLane.Update) {
        guard case .listening = phase else {
            return
        }

        // Both lanes hear every utterance, so the lane that lost the floor keeps
        // working and finalizes the same audio a beat later. Without this guard that
        // late result would land as a second turn, attributed to the wrong side and
        // written in the wrong language.
        guard isStale(update) == false else {
            return
        }

        var hypothesis = hypotheses[update.side] ?? LaneHypothesis()
        hypothesis.confidence = update.confidence
        if update.isFinal {
            hypothesis.finalizedText = update.text
            hypothesis.volatileText = update.text
            hypothesis.endSeconds = update.endSeconds
        } else {
            hypothesis.volatileText = update.text
            hypothesis.endSeconds = update.endSeconds
        }
        hypotheses[update.side] = hypothesis

        let didMoveFloor = arbiter.observe(
            primary: hypotheses[.primary]?.arbiterObservation ?? .silent,
            secondary: hypotheses[.secondary]?.arbiterObservation ?? .silent
        )

        if didMoveFloor {
            let carried = draft(for: floor)
            floor = arbiter.floor
            migrateDraft(carried, to: floor)
        }

        if let finalized = hypotheses[floor]?.finalizedText, finalized.isEmpty == false {
            commitTurn(text: finalized, side: floor)
            return
        }

        publishDraft(for: floor)
    }

    /// Tolerance absorbing the small timeline differences between the two analyzers.
    private static let audioTimelineTolerance: Double = 0.05

    /// True when `update` describes audio already committed as a turn.
    private func isStale(_ update: ConversationLane.Update) -> Bool {
        guard committedAudioEndSeconds > 0 else {
            return false
        }

        if update.endSeconds <= committedAudioEndSeconds + Self.audioTimelineTolerance {
            return true
        }

        // A finalized result that reaches back into committed audio is the other lane
        // describing the turn that already shipped, not a new one.
        return update.isFinal
            && update.startSeconds + Self.audioTimelineTolerance < committedAudioEndSeconds
    }

    private func publishDraft(for side: ConversationSide) {
        guard let text = hypotheses[side]?.volatileText, text.isEmpty == false else {
            return
        }

        var updated = draft(for: side)
        guard updated.sourceText != text else {
            return
        }
        updated.sourceText = text
        setDraft(updated, for: side)
        scheduleDraftTranslation(text: text, side: side, draftID: draftID)
    }

    /// Moves the in-flight hypothesis to the side that just won the floor, so the words
    /// already on screen keep their place instead of blinking out and reappearing.
    private func migrateDraft(_ carried: ConversationDraft, to side: ConversationSide) {
        draftID = UUID()
        clearDrafts()

        guard let text = hypotheses[side]?.volatileText, text.isEmpty == false else {
            // The winning lane has no words yet: keep the losing lane's text visible
            // for one more beat rather than flashing an empty pane.
            if carried.sourceText.isEmpty == false {
                setDraft(ConversationDraft(id: draftID, sourceText: carried.sourceText), for: side)
            }
            return
        }

        setDraft(ConversationDraft(id: draftID, sourceText: text), for: side)
        scheduleDraftTranslation(text: text, side: side, draftID: draftID)
    }

    private func scheduleDraftTranslation(text: String, side: ConversationSide, draftID: UUID) {
        draftTranslationTasks[side]?.cancel()

        let source = languageID(for: side)
        let target = languageID(for: side.opposite)
        draftTranslationTasks[side] = Task { [weak self] in
            try? await Task.sleep(for: Self.draftTranslationDelay)
            guard Task.isCancelled == false, let self else { return }
            guard let translated = try? await self.translators[side]?.translate(
                text,
                from: source,
                to: target
            ) else {
                return
            }

            guard Task.isCancelled == false,
                  self.draftID == draftID,
                  self.floor == side,
                  self.draft(for: side).sourceText == text else {
                return
            }

            var updated = self.draft(for: side)
            updated.translatedText = translated
            self.setDraft(updated, for: side)
        }
    }

    private func commitTurn(text: String, side: ConversationSide) {
        let sourceLanguageID = languageID(for: side)
        let targetLanguageID = languageID(for: side.opposite)
        // A draft translation that already landed for exactly this text is the same
        // work; carry it so the committed turn is readable immediately.
        let carriedTranslation: String = {
            let current = draft(for: side)
            return current.sourceText == text ? current.translatedText : ""
        }()

        let turn = ConversationTurn(
            side: side,
            sourceText: text,
            translatedText: carriedTranslation,
            sourceLanguageID: sourceLanguageID,
            targetLanguageID: targetLanguageID
        )

        turns.append(turn)
        if turns.count > Self.turnHistoryLimit {
            turns.removeFirst(turns.count - Self.turnHistoryLimit)
        }

        // Reset the utterance: both lanes heard it, only one owned it.
        committedAudioEndSeconds = max(
            committedAudioEndSeconds,
            hypotheses[side]?.endSeconds ?? committedAudioEndSeconds
        )
        hypotheses = [.primary: LaneHypothesis(), .secondary: LaneHypothesis()]
        arbiter.commitUtterance()
        draftID = UUID()
        for task in draftTranslationTasks.values {
            task.cancel()
        }
        draftTranslationTasks.removeAll()
        clearDrafts()

        guard carriedTranslation.isEmpty else {
            return
        }

        let turnID = turn.id
        turnTranslationTasks[turnID] = Task { [weak self] in
            guard let self else { return }
            defer { self.turnTranslationTasks[turnID] = nil }
            guard let translated = try? await self.translators[side]?.translate(
                text,
                from: sourceLanguageID,
                to: targetLanguageID
            ) else {
                return
            }
            guard Task.isCancelled == false,
                  let index = self.turns.firstIndex(where: { $0.id == turnID }) else {
                return
            }
            self.turns[index].translatedText = translated
        }
    }

    // MARK: - Helpers

    /// Both permissions are required before either lane can produce a word, so ask
    /// once here rather than letting a lane fail opaquely.
    private func requestRequiredPermissions() async -> Bool {
        let speechAuthorized: Bool
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            speechAuthorized = true
        case .notDetermined:
            speechAuthorized = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        case .denied, .restricted:
            speechAuthorized = false
        @unknown default:
            speechAuthorized = false
        }

        guard speechAuthorized else {
            phase = .failed(localized(.speechPermissionDenied))
            return false
        }

        guard await ConversationAudioTap.requestMicrophoneAccess() else {
            phase = .failed(localized(.microphonePermissionDenied))
            return false
        }

        return true
    }

    private func setDraft(_ draft: ConversationDraft, for side: ConversationSide) {
        switch side {
        case .primary:
            primaryDraft = draft
        case .secondary:
            secondaryDraft = draft
        }
    }

    private func clearDrafts() {
        primaryDraft = ConversationDraft(id: draftID)
        secondaryDraft = ConversationDraft(id: draftID)
    }

    private func autonym(for languageID: String) -> String {
        LanguageCatalog.autonym(for: languageID)
    }

    private func localized(_ key: AppTextKey, _ arguments: CVarArg...) -> String {
        AppLocalization.formattedString(key, languageID: interfaceLanguageID, arguments: arguments)
    }

    private func localizedErrorDescription(_ error: Error) -> String {
        AppLocalization.localizedErrorDescription(error, languageID: interfaceLanguageID)
    }
}
