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
@available(iOS 26.0, macOS 26.0, *)
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
    var speechCorrections = SpeechCorrectionTable.empty
    var recognitionContextualStrings: [String] = []
    var glossary: [String: String] = [:] {
        didSet {
            cachedInverseGlossary = GlossaryService.buildInverseGlossary(glossary)
        }
    }

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
    private let glossaryService = GlossaryService()
    private var cachedInverseGlossary: [String: String] = [:]

    private var arbiter = ConversationFloorArbiter()
    private var lanes: [ConversationSide: ConversationLane] = [:]
    private var hypotheses: [ConversationSide: LaneHypothesis] = [:]
    private var lastArbitratedEndSeconds: [ConversationSide: Double] = [:]
    private var audioTap: ConversationAudioTap?
    private var speechAnalyzer: SpeechAnalyzer?
    private var analyzerInputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    /// Invalidates callbacks and asynchronous startup work from earlier runs.
    private var runGeneration = 0
    private var draftTranslationTasks: [ConversationSide: Task<Void, Never>] = [:]
    private var turnTranslationTasks: [UUID: Task<Void, Never>] = [:]
    /// Identifies the utterance currently being drafted, so a late draft translation
    /// for a superseded utterance is dropped instead of overwriting the new one.
    private var draftID = UUID()
    /// Capture-timeline position through which audio has already become a turn.
    private var committedAudioEndSeconds: Double = 0

    private struct LaneHypothesis {
        var volatileText = ""
        var confidence: Double?
        var finalizedText: String?
        /// Range of the pending, already-trimmed audio in the shared timeline.
        var startSeconds: Double = 0
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
        // Coordinators support queued pair switches. Do not reset them here: the last
        // committed turn from the prior run may still need its listener translation.
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
        runGeneration &+= 1
        let generation = runGeneration
        arbiter = ConversationFloorArbiter()
        floor = arbiter.floor
        hypotheses = [.primary: LaneHypothesis(), .secondary: LaneHypothesis()]
        lastArbitratedEndSeconds = [:]
        committedAudioEndSeconds = 0
        clearDrafts()

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performStart(generation: generation)
        }
        startTask = task
        await task.value
    }

    func stop() {
        runGeneration &+= 1
        startTask?.cancel()
        startTask = nil

        for task in draftTranslationTasks.values {
            task.cancel()
        }
        draftTranslationTasks.removeAll()

        audioTap?.stop()
        audioTap = nil
        analyzerInputContinuation?.finish()
        analyzerInputContinuation = nil
        analyzerTask?.cancel()
        analyzerTask = nil

        for lane in lanes.values {
            lane.finish()
        }
        lanes.removeAll()

        if let analyzer = speechAnalyzer {
            speechAnalyzer = nil
            Task {
                await analyzer.cancelAndFinishNow()
            }
        }

        hypotheses = [:]
        lastArbitratedEndSeconds = [:]
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

        let previousFloor = floor
        let carried = draft(for: previousFloor)
        arbiter.pin(side)
        floor = side
        if previousFloor != side {
            migrateDraft(carried, to: side)
        }
        if phase == .listening,
           let finalized = hypotheses[side]?.finalizedText,
           finalized.isEmpty == false {
            // An explicit tap is the human resolution when automatic evidence never
            // aligns (for example, one recognizer emits no hypothesis at all).
            commitTurn(text: finalized, side: side)
        }
    }

    func clearTurns() {
        for task in turnTranslationTasks.values {
            task.cancel()
        }
        turnTranslationTasks.removeAll()
        turns.removeAll()
    }

    // MARK: - Translation hosts

    func installTranslationFallbacks(
        prepare: @escaping (String, String) async throws -> Void,
        translate: @escaping (String, String, String) async throws -> String
    ) {
        for coordinator in translators.values {
            coordinator.fallbackPrepare = prepare
            coordinator.fallbackTranslate = translate
        }
    }

    func runPrimaryTranslationHost(using session: TranslationSession) async {
        await translators[.primary]?.run(using: session)
    }

    func runSecondaryTranslationHost(using session: TranslationSession) async {
        await translators[.secondary]?.run(using: session)
    }

    // MARK: - Startup

    private func performStart(generation: Int) async {
        guard generation == runGeneration else { return }
        guard SpeechTranscriber.isAvailable else {
            failRun(
                localized(.conversationUnavailableFormat, autonym(for: primaryLanguageID)),
                generation: generation
            )
            return
        }

        guard await requestRequiredPermissions(generation: generation),
              generation == runGeneration,
              Task.isCancelled == false else {
            return
        }

        var transcribers: [ConversationSide: SpeechTranscriber] = [:]
        var resolvedLocales: [ConversationSide: Locale] = [:]
        for side in ConversationSide.allCases {
            let languageID = languageID(for: side)
            let requested = Locale(
                identifier: LanguageCatalog.speechLocaleIdentifier(for: languageID)
            )
            guard let resolved = await LiveTranscriptionSession.modernSpeechLocale(
                equivalentTo: requested
            ) else {
                failRun(
                    localized(.conversationUnavailableFormat, autonym(for: languageID)),
                    generation: generation
                )
                return
            }
            guard generation == runGeneration, Task.isCancelled == false else { return }

            resolvedLocales[side] = resolved
            transcribers[side] = SpeechTranscriber(
                locale: resolved,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults],
                attributeOptions: [.audioTimeRange, .transcriptionConfidence]
            )
        }

        let modules = ConversationSide.allCases.compactMap { transcribers[$0] }
        do {
            try await ConversationLane.installAssetsIfNeeded(
                for: ConversationSide.allCases.compactMap { side in
                    guard let transcriber = transcribers[side],
                          let locale = resolvedLocales[side] else {
                        return nil
                    }
                    return (transcriber: transcriber, locale: locale)
                }
            )
        } catch is CancellationError {
            return
        } catch {
            handleRunFailure(error, generation: generation)
            return
        }
        guard generation == runGeneration, Task.isCancelled == false else { return }

        let captureFormat = ConversationAudioTap.captureFormat
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: modules,
            considering: captureFormat
        ) ?? captureFormat
        guard generation == runGeneration, Task.isCancelled == false else { return }

        let analyzer = SpeechAnalyzer(
            modules: modules,
            options: SpeechAnalyzer.Options(
                priority: .userInitiated,
                modelRetention: .whileInUse
            )
        )
        let sharedNeutral = SpeechCorrectionService.neutralRecognitionPhrases(
            corrections: speechCorrections,
            languageIDs: [primaryLanguageID, secondaryLanguageID],
            glossaryKeys: recognitionContextualStrings
        )
        if sharedNeutral.isEmpty == false {
            let context = AnalysisContext()
            context.contextualStrings[.general] = sharedNeutral
            try? await analyzer.setContext(context)
        }
        do {
            try await analyzer.prepareToAnalyze(in: analyzerFormat)
        } catch is CancellationError {
            return
        } catch {
            handleRunFailure(error, generation: generation)
            return
        }
        guard generation == runGeneration, Task.isCancelled == false else {
            await analyzer.cancelAndFinishNow()
            return
        }

        // Validate and prepare both translation directions before opening the mic.
        // A conversation with one unavailable direction would otherwise look healthy
        // while one reader's half stays empty.
        do {
            async let primaryPreparation: Void = translators[.primary]!.prepareIfNeeded(
                from: primaryLanguageID,
                to: secondaryLanguageID
            )
            async let secondaryPreparation: Void = translators[.secondary]!.prepareIfNeeded(
                from: secondaryLanguageID,
                to: primaryLanguageID
            )
            _ = try await (primaryPreparation, secondaryPreparation)
        } catch is CancellationError {
            await analyzer.cancelAndFinishNow()
            return
        } catch {
            await analyzer.cancelAndFinishNow()
            handleRunFailure(error, generation: generation)
            return
        }
        guard generation == runGeneration, Task.isCancelled == false else {
            await analyzer.cancelAndFinishNow()
            return
        }

        var continuation: AsyncStream<AnalyzerInput>.Continuation!
        let inputStream = AsyncStream<AnalyzerInput>(
            bufferingPolicy: .bufferingNewest(12)
        ) {
            continuation = $0
        }

        var startedLanes: [ConversationSide: ConversationLane] = [:]
        for side in ConversationSide.allCases {
            guard let transcriber = transcribers[side] else { continue }
            let lane = ConversationLane(side: side, transcriber: transcriber)
            lane.start(
                onUpdate: { [weak self] update in
                    Task { @MainActor [weak self] in
                        guard let self, self.runGeneration == generation else { return }
                        self.apply(update, generation: generation)
                    }
                },
                onFailure: { [weak self] error in
                    Task { @MainActor [weak self] in
                        self?.handleRunFailure(error, generation: generation)
                    }
                }
            )
            startedLanes[side] = lane
        }

        lanes = startedLanes
        speechAnalyzer = analyzer
        analyzerInputContinuation = continuation
        analyzerTask = Task { [weak self] in
            do {
                try await analyzer.start(inputSequence: inputStream)
            } catch is CancellationError {
                return
            } catch {
                Task { @MainActor [weak self] in
                    self?.handleRunFailure(error, generation: generation)
                }
            }
        }

        let tap = ConversationAudioTap(outputFormat: analyzerFormat)
        tap.onBuffer = { buffer in
            _ = continuation.yield(AnalyzerInput(buffer: buffer))
        }
        // Own the pending tap before `start()` suspends. `stop()` can then serialize
        // behind capture startup instead of letting a new run overlap it.
        audioTap = tap

        do {
            try await tap.start()
        } catch is CancellationError {
            return
        } catch {
            tap.stop()
            if audioTap === tap {
                audioTap = nil
            }
            handleRunFailure(error, generation: generation)
            return
        }

        guard generation == runGeneration,
              Task.isCancelled == false,
              phase == .preparing else {
            tap.stop()
            if audioTap === tap {
                audioTap = nil
            }
            return
        }

        phase = .listening
    }

    // MARK: - Lane results

    private func failRun(_ message: String, generation: Int) {
        guard generation == runGeneration else { return }
        phase = .failed(message)
        stop()
    }

    private func handleRunFailure(_ error: Error, generation: Int) {
        guard generation == runGeneration,
              phase == .preparing || phase == .listening else {
            return
        }
        phase = .failed(localizedErrorDescription(error))
        stop()
    }


    private func apply(_ rawUpdate: ConversationLane.Update, generation: Int) {
        guard generation == runGeneration, phase == .listening else {
            return
        }

        // A slower lane can emit a result spanning both the prior turn and new
        // speech. Trim by attributed run identity instead of dropping the whole
        // result; otherwise either the old turn duplicates or the new words vanish.
        guard let update = rawUpdate.trimmingAudio(
            beforeOrAt: committedAudioEndSeconds,
            tolerance: Self.audioTimelineTolerance
        ), update.text.isEmpty == false else {
            return
        }

        var hypothesis = hypotheses[update.side] ?? LaneHypothesis()
        hypothesis.confidence = update.confidence
        hypothesis.startSeconds = update.startSeconds
        hypothesis.endSeconds = update.endSeconds
        hypothesis.volatileText = update.text
        hypothesis.finalizedText = update.isFinal ? update.text : nil
        hypotheses[update.side] = hypothesis

        let pendingFinalSide: ConversationSide? = {
            if update.isFinal { return update.side }
            if hypotheses[.primary]?.finalizedText != nil { return .primary }
            if hypotheses[.secondary]?.finalizedText != nil { return .secondary }
            return nil
        }()
        let didMoveFloor = updateFloor(finalSide: pendingFinalSide)
        if didMoveFloor {
            let carried = draft(for: floor)
            floor = arbiter.floor
            migrateDraft(carried, to: floor)
        }

        if let finalized = finalizedFloorReadyToCommit() {
            commitTurn(text: finalized, side: floor)
            return
        }

        publishDraft(for: floor, generation: generation)
    }

    private func finalizedFloorReadyToCommit() -> String? {
        guard let finalized = hypotheses[floor]?.finalizedText,
              finalized.isEmpty == false else {
            return nil
        }
        if arbiter.hasPinnedFloor {
            return finalized
        }
        guard let primary = hypotheses[.primary],
              let secondary = hypotheses[.secondary],
              rangesAlign(primary, secondary) else {
            return nil
        }
        return finalized
    }

    /// Tolerance absorbing small timeline differences between the two modules.
    private static let audioTimelineTolerance: Double = 0.05
    private static let arbitrationAdvanceTolerance: Double = 0.005

    /// Compares only hypotheses that describe overlapping audio and, for volatile
    /// updates, only after both lanes have advanced since the prior comparison.
    /// This prevents three fast updates from one lane defeating one stale observation
    /// from the other and satisfying `requiredWins` without three paired comparisons.
    private func updateFloor(finalSide: ConversationSide?) -> Bool {
        let primary = hypotheses[.primary]
        let secondary = hypotheses[.secondary]

        if finalSide != nil {
            // A fast wrong-language lane can finalize before the correct lane has
            // aligned evidence. Keep the established floor until both modules have
            // described the same audio; never award a turn merely for finishing first.
            guard let primary, let secondary,
                  rangesAlign(primary, secondary) else {
                return false
            }
            lastArbitratedEndSeconds[.primary] = primary.endSeconds
            lastArbitratedEndSeconds[.secondary] = secondary.endSeconds
            return arbiter.resolveFinal(
                primary: primary.arbiterObservation,
                secondary: secondary.arbiterObservation
            )
        }

        guard let primary, let secondary,
              rangesAlign(primary, secondary),
              primary.endSeconds
                > (lastArbitratedEndSeconds[.primary] ?? 0)
                    + Self.arbitrationAdvanceTolerance,
              secondary.endSeconds
                > (lastArbitratedEndSeconds[.secondary] ?? 0)
                    + Self.arbitrationAdvanceTolerance else {
            return false
        }

        lastArbitratedEndSeconds[.primary] = primary.endSeconds
        lastArbitratedEndSeconds[.secondary] = secondary.endSeconds
        return arbiter.observe(
            primary: primary.arbiterObservation,
            secondary: secondary.arbiterObservation
        )
    }

    private func rangesAlign(_ lhs: LaneHypothesis, _ rhs: LaneHypothesis) -> Bool {
        let overlap = max(
            0,
            min(lhs.endSeconds, rhs.endSeconds)
                - max(lhs.startSeconds, rhs.startSeconds)
        )
        let shorterDuration = max(
            0.001,
            min(
                lhs.endSeconds - lhs.startSeconds,
                rhs.endSeconds - rhs.startSeconds
            )
        )
        return overlap / shorterDuration >= 0.5
    }

    private func publishDraft(for side: ConversationSide, generation: Int) {
        guard let rawText = hypotheses[side]?.volatileText, rawText.isEmpty == false else {
            return
        }
        let text = speechCorrections.apply(rawText, languageID: languageID(for: side))

        var updated = draft(for: side)
        guard updated.sourceText != text else {
            return
        }
        updated.sourceText = text
        setDraft(updated, for: side)
        scheduleDraftTranslation(
            text: text,
            side: side,
            draftID: draftID,
            generation: generation
        )
    }

    /// Moves the in-flight hypothesis to the side that just won the floor, so the words
    /// already on screen keep their place instead of blinking out and reappearing.
    private func migrateDraft(_ carried: ConversationDraft, to side: ConversationSide) {
        draftID = UUID()
        clearDrafts()

        guard let rawText = hypotheses[side]?.volatileText, rawText.isEmpty == false else {
            // The winning lane has no words yet: keep the losing lane's text visible
            // for one more beat rather than flashing an empty pane.
            if carried.sourceText.isEmpty == false {
                setDraft(ConversationDraft(id: draftID, sourceText: carried.sourceText), for: side)
            }
            return
        }

        let text = speechCorrections.apply(rawText, languageID: languageID(for: side))
        setDraft(ConversationDraft(id: draftID, sourceText: text), for: side)
        scheduleDraftTranslation(
            text: text,
            side: side,
            draftID: draftID,
            generation: runGeneration
        )
    }

    private func scheduleDraftTranslation(
        text: String,
        side: ConversationSide,
        draftID: UUID,
        generation: Int
    ) {
        draftTranslationTasks[side]?.cancel()

        let source = languageID(for: side)
        let target = languageID(for: side.opposite)
        draftTranslationTasks[side] = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.draftTranslationDelay)
                guard Task.isCancelled == false, let self,
                      generation == self.runGeneration,
                      self.draftID == draftID,
                      self.floor == side,
                      self.draft(for: side).sourceText == text else {
                    return
                }

                let effectiveGlossary = self.effectiveGlossary(from: source, to: target)
                let translation = try await self.glossaryService.translating(
                    sourceText: text,
                    glossary: effectiveGlossary
                ) { preparedInput in
                    try await self.translators[side]!.translate(
                        preparedInput,
                        from: source,
                        to: target
                    )
                }
                guard Task.isCancelled == false,
                      generation == self.runGeneration,
                      self.draftID == draftID,
                      self.floor == side,
                      self.draft(for: side).sourceText == text else {
                    return
                }

                var updated = self.draft(for: side)
                updated.translatedText = translation.translatedText
                self.setDraft(updated, for: side)
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      generation == self.runGeneration,
                      self.draftID == draftID,
                      self.floor == side else {
                    return
                }
                self.handleRunFailure(error, generation: generation)
            }
        }
    }

    private func commitTurn(text: String, side: ConversationSide) {
        let sourceLanguageID = languageID(for: side)
        let targetLanguageID = languageID(for: side.opposite)
        let correctedText = speechCorrections.apply(text, languageID: sourceLanguageID)
        let carriedTranslation: String = {
            let current = draft(for: side)
            return current.sourceText == correctedText ? current.translatedText : ""
        }()

        let turn = ConversationTurn(
            side: side,
            sourceText: correctedText,
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
        lastArbitratedEndSeconds = [:]
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
        let generation = runGeneration
        turnTranslationTasks[turnID] = Task { [weak self] in
            guard let self else { return }
            defer { self.turnTranslationTasks[turnID] = nil }
            do {
                let effectiveGlossary = self.effectiveGlossary(
                    from: sourceLanguageID,
                    to: targetLanguageID
                )
                let translation = try await self.glossaryService.translating(
                    sourceText: correctedText,
                    glossary: effectiveGlossary
                ) { preparedInput in
                    try await self.translators[side]!.translate(
                        preparedInput,
                        from: sourceLanguageID,
                        to: targetLanguageID
                    )
                }
                guard Task.isCancelled == false,
                      let index = self.turns.firstIndex(where: { $0.id == turnID }) else {
                    return
                }
                // A stopped run retains its turns, so a pending listener translation
                // is still valuable and safe to backfill by immutable turn ID.
                self.turns[index].translatedText = translation.translatedText
            } catch is CancellationError {
                return
            } catch {
                guard generation == self.runGeneration,
                      self.turns.contains(where: { $0.id == turnID }) else {
                    return
                }
                self.handleRunFailure(error, generation: generation)
            }
        }
    }

    // MARK: - Helpers
    private func effectiveGlossary(
        from sourceLanguageID: String,
        to targetLanguageID: String
    ) -> [String: String] {
        if LanguageIdentity.isEnglish(sourceLanguageID),
           LanguageIdentity.isTraditionalChinese(targetLanguageID) {
            return cachedInverseGlossary
        }
        return glossary
    }


    /// Both permissions are required before either lane can produce a word, so ask
    /// once here rather than letting a lane fail opaquely.
    private func requestRequiredPermissions(generation: Int) async -> Bool {
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

        guard generation == runGeneration else { return false }
        guard speechAuthorized else {
            failRun(localized(.speechPermissionDenied), generation: generation)
            return false
        }

        let microphoneAuthorized = await ConversationAudioTap.requestMicrophoneAccess()
        guard generation == runGeneration else { return false }
        guard microphoneAuthorized else {
            failRun(localized(.microphonePermissionDenied), generation: generation)
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
