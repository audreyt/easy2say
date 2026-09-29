import Foundation

/// Per-session pacing knobs, mapped from the user's subtitle mode.
struct CaptionTiming: Equatable, Sendable {
    /// Minimum wall gap between draft translation requests on a live row.
    var draftSpacingMs = 1_000.0
    /// Idle wall time without new characters after which the live row seals.
    var idleSealMs = 1_500.0
    /// Wall time after a VAD offset before a terminated last row seals.
    var vadSealMs = 500.0
    /// False disables draft translation requests entirely (finals only).
    var showsDraftTranslations = true
}

struct CaptionSessionConfig: Equatable, Sendable {
    var sessionID: Int
    var primaryLanguageID: String
    var secondaryLanguageID = ""
    var targetLanguageID = ""
    var translates = false
    var timing = CaptionTiming()
}

enum CaptionInput: Equatable, Sendable {
    case sessionStarted(CaptionSessionConfig)
    case result(sessionID: Int, AnalyzerResultEvent)
    case vad(sessionID: Int, VADEdge, audioMs: Int)
    case translationCompleted(requestID: Int, text: String?)
    case tick
    case sessionStopped(sessionID: Int)
    case reset
}

struct CaptionRowID: Hashable, Sendable {
    var sessionID: Int
    var ordinal: Int
}

struct CaptionTranslationRequest: Equatable, Sendable {
    var id: Int
    var rowID: CaptionRowID
    var text: String
    var sourceLanguageID: String
    var targetLanguageID: String
    var isDraft: Bool
}

enum CaptionEffect: Equatable, Sendable {
    case translate(CaptionTranslationRequest)
}

struct CaptionRow: Identifiable, Equatable, Sendable {
    var id: CaptionRowID
    /// Heard language.
    var languageID: String
    /// Translation target ("" when the session does not translate).
    var targetLanguageID: String
    var text: String
    var stableLength: Int
    var isSealed: Bool
    var isFinal: Bool
    /// What to display ("" if none yet).
    var translation: String
    /// True when `translation` was made for other text than `text` or came
    /// from a draft request.
    var translationIsDraft: Bool
    var speakerIndex: Int?
    /// Wall time the row first appeared — document order key.
    var createdMs: Double
}

struct CaptionDocument: Equatable, Sendable {
    var rows: [CaptionRow]
    var revision: Int
}

/// Deterministic reducer: recognizer events in, `CaptionDocument` +
/// translation-request effects out. Sealing and translation are recomputed on
/// every input; `nextWakeMs` tells the driver when `.tick` is next needed.
struct CaptionCore {
    /// Speech corrections handed to the composer (production passes
    /// `speechCorrections.apply`; tests use the identity default).
    private let correct: @Sendable (String, String) -> String

    init(correct: @escaping @Sendable (String, String) -> String = { text, _ in text }) {
        self.correct = correct
    }

    private(set) var document = CaptionDocument(rows: [], revision: 0)

    /// Row cap: oldest rows are dropped beyond this.
    private static let rowLimit = 400
    /// The offset must land at or after `lastArrivalMs - vadSealAudioSlackMs`.
    private static let vadSealAudioSlackMs = 1_200
    /// A failed final translation may be retried once after this delay.
    private static let finalRetryMs = 2_000.0
    private static let cacheLimit = 512

    private struct SessionState {
        var config: CaptionSessionConfig
        var primary = CaptionLaneState()
        var secondary: CaptionLaneState?
        /// Rows that met the freeze bar: their lane text was dropped, so they
        /// never recompose or re-evaluate — they keep their IDs as displayed.
        var frozenRows: [CaptionRow] = []
        /// Absolute ordinal for composed index 0: every composed position
        /// below it has been frozen or dropped, so row IDs stay stable.
        var composedBase = 0
        /// Live rows are only created at absolute ordinals ≥ this floor.
        var displayFloor = 0
        var rows: [CaptionRow] = []
        /// Keyed by absolute row ordinal.
        var runtimes: [Int: RowRuntime] = [:]
        var pendingOffsetAudioMs: Int?
        var pendingOffsetWallMs: Double?
        var stopped = false
    }

    /// Mutable per-row bookkeeping that must not affect `document` equality.
    private struct RowRuntime {
        var text = ""
        var isTerminated = false
        var lastArrivalMs = 0
        /// The row's primary-lane character range (freeze checks).
        var primaryCharStart = 0
        var primaryCharEnd = 0
        var textChangedWallMs: Double = 0
        var lastDraftText = ""
        var lastDraftWallMs: Double?
        var draftInFlight = false
        var lastArrivedTranslation = ""
    }

    private struct TranslationKey: Hashable {
        var text: String
        var from: String
        var to: String
    }

    private struct RequestRecord {
        var rowID: CaptionRowID
        var key: TranslationKey
        var isDraft: Bool
    }

    private var sessions: [Int: SessionState] = [:]
    private var nextRequestID = 1
    private var requests: [Int: RequestRecord] = [:]
    private var cache: [TranslationKey: String] = [:]
    /// LRU order, oldest first.
    private var cacheOrder: [TranslationKey] = []
    private var finalRequested: Set<TranslationKey> = []
    private var finalFailedAt: [TranslationKey: Double] = [:]
    private var finalRetried: Set<TranslationKey> = []
    private var wake: Double?

    var nextWakeMs: Double? { wake }

    mutating func apply(_ input: CaptionInput, nowMs: Double) -> [CaptionEffect] {
        switch input {
        case .sessionStarted(let config):
            sessions[config.sessionID] = SessionState(
                config: config,
                secondary: config.secondaryLanguageID.isEmpty ? nil : CaptionLaneState()
            )
        case .result(let sessionID, let event):
            guard let config = sessions[sessionID]?.config else { break }
            let language = LanguageIdentity.canonicalLanguageID(event.lane.languageID)
            if LanguageIdentity.areEquivalent(language, config.primaryLanguageID) {
                sessions[sessionID]?.primary.apply(event)
            } else if sessions[sessionID]?.secondary != nil,
                      LanguageIdentity.areEquivalent(language, config.secondaryLanguageID) {
                sessions[sessionID]?.secondary?.apply(event)
            } else {
                break
            }
            recompose(sessionID: sessionID, nowMs: nowMs)
        case .vad(let sessionID, let edge, let audioMs):
            switch edge {
            case .offset:
                sessions[sessionID]?.pendingOffsetAudioMs = audioMs
                sessions[sessionID]?.pendingOffsetWallMs = nowMs
            case .onset:
                sessions[sessionID]?.pendingOffsetAudioMs = nil
                sessions[sessionID]?.pendingOffsetWallMs = nil
            }
        case .translationCompleted(let requestID, let text):
            completeTranslation(requestID: requestID, text: text, nowMs: nowMs)
        case .tick:
            break
        case .sessionStopped(let sessionID):
            sessions[sessionID]?.stopped = true
            // Recompose so every row is marked final as well as sealed.
            recompose(sessionID: sessionID, nowMs: nowMs)
        case .reset:
            sessions.removeAll()
            requests.removeAll()
            cache.removeAll()
            cacheOrder.removeAll()
            finalRequested.removeAll()
            finalFailedAt.removeAll()
            finalRetried.removeAll()
            nextRequestID = 1
            wake = nil
            if document.rows.isEmpty == false {
                document.rows = []
                document.revision += 1
            }
            return []
        }
        let effects = evaluate(nowMs: nowMs)
        rebuildDocument()
        return effects
    }

    // MARK: - Recomposition

    private mutating func recompose(sessionID: Int, nowMs: Double) {
        guard var session = sessions[sessionID] else { return }
        let composed = CaptionComposer.compose(
            primary: session.primary,
            secondary: session.secondary,
            config: ComposerConfig(
                primaryLanguageID: session.config.primaryLanguageID,
                secondaryLanguageID: session.config.secondaryLanguageID,
                correct: correct
            )
        )
        var rows: [CaptionRow] = []
        var runtimes: [Int: RowRuntime] = [:]
        for row in composed {
            let absoluteOrdinal = session.composedBase + row.ordinal
            guard absoluteOrdinal >= session.displayFloor else { continue }
            var runtime = session.runtimes[absoluteOrdinal] ?? RowRuntime()
            if runtime.text != row.text {
                runtime.textChangedWallMs = nowMs
            }
            runtime.text = row.text
            runtime.isTerminated = row.isTerminated
            runtime.lastArrivalMs = row.lastArrivalMs
            runtime.primaryCharStart = row.primaryRange.lowerBound
            runtime.primaryCharEnd = row.primaryRange.upperBound
            if let index = session.rows.firstIndex(where: { $0.id.ordinal == absoluteOrdinal }) {
                var existing = session.rows[index]
                existing.languageID = row.languageID
                existing.text = row.text
                existing.stableLength = row.stableLength
                existing.isFinal = row.isFinal || session.stopped
                existing.speakerIndex = row.speakerIndex
                existing.targetLanguageID = translationTarget(
                    heardLanguageID: row.languageID,
                    config: session.config
                )
                rows.append(existing)
            } else {
                rows.append(
                    CaptionRow(
                        id: CaptionRowID(sessionID: sessionID, ordinal: absoluteOrdinal),
                        languageID: row.languageID,
                        targetLanguageID: translationTarget(
                            heardLanguageID: row.languageID,
                            config: session.config
                        ),
                        text: row.text,
                        stableLength: row.stableLength,
                        isSealed: false,
                        isFinal: row.isFinal || session.stopped,
                        translation: "",
                        translationIsDraft: false,
                        speakerIndex: row.speakerIndex,
                        createdMs: nowMs
                    )
                )
            }
            runtimes[absoluteOrdinal] = runtime
        }
        session.rows = rows
        session.runtimes = runtimes
        sessions[sessionID] = session
    }

    private func translationTarget(heardLanguageID: String, config: CaptionSessionConfig) -> String {
        guard config.translates else { return "" }
        if config.secondaryLanguageID.isEmpty == false,
           LanguageIdentity.isEnglish(heardLanguageID),
           LanguageIdentity.areEquivalent(heardLanguageID, config.secondaryLanguageID) {
            // Dual lane: English rows translate into the other lane's language.
            return config.primaryLanguageID
        }
        return config.targetLanguageID
    }

    // MARK: - Completion

    private mutating func completeTranslation(requestID: Int, text: String?, nowMs: Double) {
        guard let record = requests.removeValue(forKey: requestID) else { return }
        if let text {
            // Only final translations enter the cache; drafts populate the
            // row's lastArrivedTranslation (a final for the same text is still
            // requested once the row seals).
            if record.isDraft == false {
                cacheInsert(record.key, text)
            }
            // Stale completions for a dropped row are ignored for display.
            sessions[record.rowID.sessionID]?.runtimes[record.rowID.ordinal]?.lastArrivedTranslation = text
            if record.isDraft {
                sessions[record.rowID.sessionID]?.runtimes[record.rowID.ordinal]?.draftInFlight = false
            }
        } else if record.isDraft {
            sessions[record.rowID.sessionID]?.runtimes[record.rowID.ordinal]?.draftInFlight = false
        } else {
            finalFailedAt[record.key] = nowMs
        }
    }

    // MARK: - Evaluation

    /// Recomputes sealing, translation display, and pending requests for every
    /// session. Returns the effects this evaluation emits; also refreshes
    /// `nextWakeMs` with the earliest pending timer.
    private mutating func evaluate(nowMs: Double) -> [CaptionEffect] {
        var effects: [CaptionEffect] = []
        var nextWake: Double?
        func schedule(_ deadline: Double) {
            if deadline > nowMs, deadline < (nextWake ?? .infinity) {
                nextWake = deadline
            }
        }

        for sessionID in sessions.keys.sorted() {
            guard var session = sessions[sessionID] else { continue }
            let lastIndex = session.rows.count - 1
            for index in session.rows.indices {
                var row = session.rows[index]
                var runtime = session.runtimes[row.id.ordinal] ?? RowRuntime()

                var sealed = session.stopped || index < lastIndex || row.isFinal
                if sealed == false {
                    if runtime.isTerminated,
                       let offsetAudioMs = session.pendingOffsetAudioMs,
                       let offsetWallMs = session.pendingOffsetWallMs,
                       offsetAudioMs >= runtime.lastArrivalMs - Self.vadSealAudioSlackMs {
                        if nowMs - offsetWallMs >= session.config.timing.vadSealMs {
                            sealed = true
                        } else {
                            schedule(offsetWallMs + session.config.timing.vadSealMs)
                        }
                    }
                    if sealed == false {
                        if nowMs - runtime.textChangedWallMs >= session.config.timing.idleSealMs {
                            sealed = true
                        } else {
                            schedule(runtime.textChangedWallMs + session.config.timing.idleSealMs)
                        }
                    }
                }
                row.isSealed = sealed

                let target = row.targetLanguageID
                if session.config.translates,
                   target.isEmpty == false,
                   LanguageIdentity.areEquivalent(row.languageID, target) == false {
                    let key = TranslationKey(text: row.text, from: row.languageID, to: target)
                    if let cached = cacheLookup(key) {
                        row.translation = cached
                        row.translationIsDraft = false
                    } else if runtime.lastArrivedTranslation.isEmpty == false {
                        row.translation = runtime.lastArrivedTranslation
                        row.translationIsDraft = true
                    } else if row.text.isEmpty {
                        row.translation = ""
                    }

                    if sealed {
                        if cache[key] == nil, inflightFinal(key) == false {
                            if let failedAt = finalFailedAt[key] {
                                if finalRetried.contains(key) == false {
                                    if nowMs - failedAt >= Self.finalRetryMs {
                                        effects.append(emitTranslation(row: row, key: key, isDraft: false))
                                        finalRetried.insert(key)
                                    } else {
                                        schedule(failedAt + Self.finalRetryMs)
                                    }
                                }
                            } else if finalRequested.contains(key) == false {
                                effects.append(emitTranslation(row: row, key: key, isDraft: false))
                                finalRequested.insert(key)
                            }
                        }
                    } else if session.config.timing.showsDraftTranslations,
                              row.text != runtime.lastDraftText,
                              runtime.draftInFlight == false {
                        if let lastDraft = runtime.lastDraftWallMs, nowMs - lastDraft < session.config.timing.draftSpacingMs {
                            schedule(lastDraft + session.config.timing.draftSpacingMs)
                        } else if runtime.lastDraftWallMs != nil || hasDraftableContent(row.text) {
                            effects.append(emitTranslation(row: row, key: key, isDraft: true))
                            runtime.lastDraftText = row.text
                            runtime.lastDraftWallMs = nowMs
                            runtime.draftInFlight = true
                        }
                    }
                }

                session.rows[index] = row
                session.runtimes[row.id.ordinal] = runtime
            }
            freezeEligibleRows(&session)
            sessions[sessionID] = session
        }
        wake = nextWake
        return effects
    }

    /// Freezes the longest eligible prefix of primary finals: every row lying
    /// entirely within them is final, sealed, translation-complete, and not
    /// among the last two rows. Frozen rows keep their IDs forever; the lane
    /// forgets their characters so recompose stays O(live text).
    private mutating func freezeEligibleRows(_ session: inout SessionState) {
        let rowCount = session.rows.count
        guard rowCount > 2 else { return }
        var cumulativeCharacters = 0
        var freezeFinals = 0
        var cutoffEnd = 0
        for (index, final) in session.primary.finals.enumerated() {
            cumulativeCharacters += final.text.count
            var usable = true
            var hardBlocked = false
            for (rowIndex, row) in session.rows.enumerated() {
                let runtime = session.runtimes[row.id.ordinal]
                let rowEnd = runtime?.primaryCharEnd ?? .max
                let rowStart = runtime?.primaryCharStart ?? 0
                if rowEnd <= cumulativeCharacters {
                    // Entirely inside the candidate prefix: must qualify.
                    let translated = needsTranslation(row, config: session.config) == false
                        || cache[TranslationKey(
                            text: row.text, from: row.languageID, to: row.targetLanguageID
                        )] != nil
                    if row.isFinal == false || row.isSealed == false || translated == false
                        || rowIndex > rowCount - 3 {
                        usable = false
                        hardBlocked = true   // larger prefixes cover it too
                        break
                    }
                } else if rowStart < cumulativeCharacters {
                    // Straddles the boundary — freezing here would erase its
                    // leading characters. A larger prefix may subsume it.
                    usable = false
                }
            }
            if usable {
                freezeFinals = index + 1
                cutoffEnd = cumulativeCharacters
            }
            if hardBlocked { break }
        }
        guard freezeFinals > 0 else { return }
        // Covered rows are a leading prefix of session.rows.
        let frozenCount = session.rows
            .prefix { (session.runtimes[$0.id.ordinal]?.primaryCharEnd ?? .max) <= cutoffEnd }
            .count
        let frozen = Array(session.rows.prefix(frozenCount))
        session.rows.removeFirst(frozenCount)
        for row in frozen {
            session.runtimes[row.id.ordinal] = nil
        }
        session.frozenRows += frozen
        // Composed index 0 now maps past the last frozen row's ordinal.
        session.composedBase = (frozen.last?.id.ordinal ?? session.composedBase - 1) + 1
        let lastDroppedEnd = session.primary.finals[freezeFinals - 1].rangeEndMs
        session.primary.dropLeadingFinals(freezeFinals)
        // Dual lane: drop secondary finals safely past the freeze horizon
        // (windows look back 1500 ms).
        if var secondary = session.secondary {
            let dropCount = secondary.finals
                .prefix { $0.rangeEndMs <= lastDroppedEnd - 1_500 }
                .count
            secondary.dropLeadingFinals(dropCount)
            session.secondary = secondary
        }
    }

    private func needsTranslation(_ row: CaptionRow, config: CaptionSessionConfig) -> Bool {
        config.translates
            && row.targetLanguageID.isEmpty == false
            && LanguageIdentity.areEquivalent(row.languageID, row.targetLanguageID) == false
    }

    /// The first draft of a row needs a minimum of content; later drafts only
    /// the spacing gate. CJK counts characters, Latin needs one complete word.
    private func hasDraftableContent(_ text: String) -> Bool {
        var cjk = 0
        var word = false
        var completeWord = false
        for scalar in text.unicodeScalars {
            if LanguageIdentity.isCJKScalar(scalar) {
                cjk += 1
                if word { completeWord = true }
                word = false
            } else if CharacterSet.alphanumerics.contains(scalar) {
                word = true
            } else if word {
                completeWord = true
                word = false
            }
        }
        return cjk >= 2 || completeWord
    }

    private mutating func emitTranslation(
        row: CaptionRow,
        key: TranslationKey,
        isDraft: Bool
    ) -> CaptionEffect {
        let request = CaptionTranslationRequest(
            id: nextRequestID,
            rowID: row.id,
            text: row.text,
            sourceLanguageID: key.from,
            targetLanguageID: key.to,
            isDraft: isDraft
        )
        nextRequestID += 1
        requests[request.id] = RequestRecord(rowID: row.id, key: key, isDraft: isDraft)
        return .translate(request)
    }

    private func inflightFinal(_ key: TranslationKey) -> Bool {
        requests.values.contains { $0.key == key && $0.isDraft == false }
    }

    private func cacheLookup(_ key: TranslationKey) -> String? {
        cache[key]
    }

    private mutating func cacheInsert(_ key: TranslationKey, _ translation: String) {
        if cache[key] == nil {
            cacheOrder.append(key)
        } else {
            cacheOrder.removeAll { $0 == key }
            cacheOrder.append(key)
        }
        cache[key] = translation
        while cacheOrder.count > Self.cacheLimit, let oldest = cacheOrder.first {
            cacheOrder.removeFirst()
            cache[oldest] = nil
        }
    }

    // MARK: - Document

    /// All rows (frozen + live) across sessions in document order:
    /// first-appearance time, then session, then ordinal.
    private func allRows() -> [CaptionRow] {
        var rows: [CaptionRow] = []
        for session in sessions.values {
            rows += session.frozenRows
            rows += session.rows
        }
        rows.sort {
            ($0.createdMs, $0.id.sessionID, $0.id.ordinal)
                < ($1.createdMs, $1.id.sessionID, $1.id.ordinal)
        }
        return rows
    }

    private mutating func rebuildDocument() {
        var rows = allRows()
        // Enforce the row cap by dropping the oldest rows first.
        while rows.count > Self.rowLimit {
            let dropped = rows.removeFirst()
            guard var session = sessions[dropped.id.sessionID] else { continue }
            if let index = session.frozenRows.firstIndex(where: { $0.id == dropped.id }) {
                session.frozenRows.remove(at: index)
            }
            if let index = session.rows.firstIndex(where: { $0.id == dropped.id }) {
                session.rows.remove(at: index)
                session.displayFloor = max(session.displayFloor, dropped.id.ordinal + 1)
            }
            session.runtimes[dropped.id.ordinal] = nil
            sessions[dropped.id.sessionID] = session
        }
        if rows != document.rows {
            document.rows = rows
            document.revision += 1
        }
    }

    /// Testing aid: characters currently retained in a session's lanes.
    func laneCharacterCounts(sessionID: Int) -> (primary: Int, secondary: Int)? {
        guard let session = sessions[sessionID] else { return nil }
        return (session.primary.text.count, session.secondary?.text.count ?? 0)
    }
}
