import Foundation

struct OverlayHistoryEntry: Identifiable, Equatable {
    let id: UUID
    var translatedText: String
    var sourceText: String

    init(id: UUID = UUID(), translatedText: String, sourceText: String) {
        self.id = id
        self.translatedText = translatedText
        self.sourceText = sourceText
    }
}

struct OverlayPreviewState: Equatable {
    // MARK: Committed caption (main display)
    var translatedText: String
    var sourceText: String
    var sourceName: String

    // MARK: Draft layer — partial ASR for the current caption slot
    var draftSourceText: String? = nil
    /// Character boundary separating source words Apple has kept stable from the
    /// mutable hypothesis tail.
    var draftSourceStablePrefixLength: Int = 0
    /// Incremental translation of the current draft text.
    var draftTranslatedText: String? = nil
    /// Boundary inferred from consecutive translation hypotheses. Text before it
    /// survived the latest revision; text after it remains visibly provisional.
    var draftTranslatedStablePrefixLength: Int = 0
    var draftTranslationSourceText: String? = nil
    var draftTranslationPromotionID: UUID? = nil
    var draftPromotionID: UUID? = nil
    var draftAudioStartMs: Int? = nil

    // MARK: History layer — committed captions the user can scroll back through
    var history: [OverlayHistoryEntry] = []

    // MARK: Caption identity
    var captionEpoch: Int = 0
    var committedPromotionID: UUID? = nil
    var committedCaptionID: UUID? = nil
    var committedAudioStartMs: Int? = nil

    // MARK: Derived helpers

    var hasActiveDraftLayer: Bool {
        (draftSourceText?.isEmpty == false) || (draftTranslatedText?.isEmpty == false)
    }

    var hasHistory: Bool {
        history.isEmpty == false
    }

    mutating func setDraftTranslation(_ translatedText: String?, sourceText: String, promotionID: UUID?) {
        guard let translatedText, translatedText.isEmpty == false else {
            clearDraftTranslation()
            return
        }

        let previousTranslation = draftTranslationPromotionID == promotionID
            ? draftTranslatedText
            : nil
        draftTranslatedStablePrefixLength = previousTranslation.map {
            LiveCaptionTextStability.commonStablePrefixLength(previous: $0, current: translatedText)
        } ?? 0
        self.draftTranslatedText = translatedText
        self.draftTranslationSourceText = sourceText
        self.draftTranslationPromotionID = promotionID
    }

    mutating func clearDraftTranslation() {
        draftTranslatedText = nil
        draftTranslatedStablePrefixLength = 0
        draftTranslationSourceText = nil
        draftTranslationPromotionID = nil
    }

    mutating func clearDraftTranslationIfMismatched(sourceText: String, promotionID: UUID?) {
        guard draftTranslatedText != nil else {
            return
        }

        if visibleDraftTranslatedText(for: sourceText, promotionID: promotionID) == nil {
            clearDraftTranslation()
        }
    }

    func currentDraftTranslatedText(for sourceText: String, promotionID: UUID?) -> String? {
        guard let draftTranslatedText,
              draftTranslatedText.isEmpty == false,
              draftTranslationSourceText == sourceText,
              draftTranslationPromotionID == promotionID else {
            return nil
        }

        return draftTranslatedText
    }

    func visibleDraftTranslatedText(for sourceText: String, promotionID: UUID?) -> String? {
        guard let draftTranslatedText,
              draftTranslatedText.isEmpty == false,
              draftTranslationPromotionID == promotionID else {
            return nil
        }

        if promotionID != nil {
            return draftTranslatedText
        }

        return draftTranslationSourceText == sourceText ? draftTranslatedText : nil
    }
}

enum LiveCaptionTextStability {
    static func commonStablePrefixLength(previous: String, current: String) -> Int {
        guard previous != current else { return current.count }

        var previousIndex = previous.startIndex
        var currentIndex = current.startIndex
        var commonLength = 0
        while previousIndex < previous.endIndex,
              currentIndex < current.endIndex,
              previous[previousIndex] == current[currentIndex] {
            previous.formIndex(after: &previousIndex)
            current.formIndex(after: &currentIndex)
            commonLength += 1
        }

        guard commonLength > 0 else { return 0 }
        if currentIndex == current.endIndex {
            return boundaryBeforeActiveTail(
                in: current,
                endingAt: currentIndex,
                length: commonLength
            )
        }

        let previousCharacter = current[current.index(before: currentIndex)]
        let nextCharacter = current[currentIndex]
        guard isWordCharacter(previousCharacter),
              isWordCharacter(nextCharacter),
              containsCJK(previousCharacter) == false,
              containsCJK(nextCharacter) == false else {
            return commonLength
        }

        return boundaryBeforeActiveTail(
            in: current,
            endingAt: currentIndex,
            length: commonLength
        )
    }

    static func separator(between leading: String, and trailing: String) -> String {
        guard let last = leading.last, let first = trailing.first else { return "" }
        if last.isWhitespace || first.isWhitespace || first.isPunctuation {
            return ""
        }
        if containsCJK(last) && containsCJK(first) {
            return ""
        }
        if Self.fullWidthPunctuation.contains(last) {
            return ""
        }
        return " "
    }

    private static func boundaryBeforeActiveTail(
        in text: String,
        endingAt endIndex: String.Index,
        length: Int
    ) -> Int {
        guard length > 0 else { return 0 }
        if containsCJK(text[text.index(before: endIndex)]) {
            return length - 1
        }

        var boundary = endIndex
        var boundaryLength = length
        while boundary != text.startIndex {
            let candidate = text.index(before: boundary)
            guard isWordCharacter(text[candidate]) else { break }
            boundary = candidate
            boundaryLength -= 1
        }
        return boundaryLength
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    private static func containsCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains(where: LanguageIdentity.isCJKScalar)
    }

    private static let fullWidthPunctuation: Set<Character> = [
        "，", "。", "！", "？", "、", "；", "："
    ]
}

struct OverlayLiveCaptionPresentation: Equatable {
    enum Phase: Equatable {
        case tentative
        case committed
    }

    enum Identity: Hashable {
        case promotion(UUID)
        case captionEpoch(Int)
    }

    struct Caption: Identifiable, Equatable {
        let id: Identity
        let phase: Phase
        let translatedText: String
        let sourceText: String
        let translatedStablePrefixLength: Int
        let sourceStablePrefixLength: Int
        let translatedAgedPrefixLength: Int
        let sourceAgedPrefixLength: Int
        let representedHistoryEntryIDs: Set<UUID>

        init(
            id: Identity,
            phase: Phase,
            translatedText: String,
            sourceText: String,
            translatedStablePrefixLength: Int? = nil,
            sourceStablePrefixLength: Int? = nil,
            translatedAgedPrefixLength: Int = 0,
            sourceAgedPrefixLength: Int = 0,
            representedHistoryEntryIDs: Set<UUID> = []
        ) {
            self.id = id
            self.phase = phase
            self.translatedText = translatedText
            self.sourceText = sourceText
            self.translatedStablePrefixLength = Self.clampedStablePrefixLength(
                translatedStablePrefixLength ?? (phase == .committed ? translatedText.count : 0),
                in: translatedText
            )
            self.sourceStablePrefixLength = Self.clampedStablePrefixLength(
                sourceStablePrefixLength ?? (phase == .committed ? sourceText.count : 0),
                in: sourceText
            )
            self.translatedAgedPrefixLength = Self.clampedAgedPrefixLength(
                translatedAgedPrefixLength,
                stablePrefixLength: self.translatedStablePrefixLength
            )
            self.sourceAgedPrefixLength = Self.clampedAgedPrefixLength(
                sourceAgedPrefixLength,
                stablePrefixLength: self.sourceStablePrefixLength
            )
            self.representedHistoryEntryIDs = representedHistoryEntryIDs
        }

        var translatedStableText: String {
            String(translatedText.prefix(translatedStablePrefixLength))
        }

        var translatedMutableText: String {
            String(translatedText.dropFirst(translatedStablePrefixLength))
        }

        var sourceStableText: String {
            String(sourceText.prefix(sourceStablePrefixLength))
        }

        var sourceMutableText: String {
            String(sourceText.dropFirst(sourceStablePrefixLength))
        }

        private static func clampedStablePrefixLength(_ length: Int, in text: String) -> Int {
            min(max(0, length), text.count)
        }

        private static func clampedAgedPrefixLength(_ length: Int, stablePrefixLength: Int) -> Int {
            min(max(0, length), stablePrefixLength)
        }
    }

    let precedingCommittedCaption: Caption?
    let currentCaption: Caption?

    /// One visual lane per language. A preceding commit remains white while the
    /// current mutable suffix updates in place; layout clips the lane to its newest
    /// two wrapped lines.
    var displayCaption: Caption? {
        guard let currentCaption else {
            return precedingCommittedCaption
        }
        guard let precedingCommittedCaption else {
            return currentCaption
        }
        return Self.combinedCaption(
            preceding: precedingCommittedCaption,
            current: currentCaption,
            deduplicatesEqualLaneText: true,
            preservesEmptyLaneRows: false
        )
    }

    /// Audience Display preserves each retained utterance as one atomic row in
    /// both language lanes. Equal text is never collapsed in only one lane, and
    /// a missing source or translation gets an invisible non-breaking-space row
    /// so the two lane sequences cannot become misaligned.
    var audienceDisplayCaption: Caption? {
        guard let currentCaption else {
            return precedingCommittedCaption
        }
        guard let precedingCommittedCaption else {
            return currentCaption
        }
        return Self.combinedCaption(
            preceding: precedingCommittedCaption,
            current: currentCaption,
            deduplicatesEqualLaneText: false,
            preservesEmptyLaneRows: true
        )
    }

    private static func combinedCaption(
        preceding: Caption,
        current: Caption,
        deduplicatesEqualLaneText: Bool,
        preservesEmptyLaneRows: Bool
    ) -> Caption {
        let precedingTranslated = projectedLane(
            text: preceding.translatedText,
            stablePrefixLength: preceding.translatedStablePrefixLength,
            preservesEmptyRow: preservesEmptyLaneRows
        )
        let currentTranslated = projectedLane(
            text: current.translatedText,
            stablePrefixLength: current.translatedStablePrefixLength,
            preservesEmptyRow: preservesEmptyLaneRows
        )
        let precedingSource = projectedLane(
            text: preceding.sourceText,
            stablePrefixLength: preceding.sourceStablePrefixLength,
            preservesEmptyRow: preservesEmptyLaneRows
        )
        let currentSource = projectedLane(
            text: current.sourceText,
            stablePrefixLength: current.sourceStablePrefixLength,
            preservesEmptyRow: preservesEmptyLaneRows
        )
        let translated = joinedLane(
            leadingText: precedingTranslated.text,
            trailingText: currentTranslated.text,
            trailingStablePrefixLength: currentTranslated.stablePrefixLength,
            deduplicatesEqualText: deduplicatesEqualLaneText
        )
        let source = joinedLane(
            leadingText: precedingSource.text,
            trailingText: currentSource.text,
            trailingStablePrefixLength: currentSource.stablePrefixLength,
            deduplicatesEqualText: deduplicatesEqualLaneText
        )
        var representedHistoryEntryIDs = current.representedHistoryEntryIDs
        if translated.includesLeadingText || source.includesLeadingText {
            representedHistoryEntryIDs.formUnion(preceding.representedHistoryEntryIDs)
        }
        return Caption(
            id: current.id,
            phase: current.phase,
            translatedText: translated.text,
            sourceText: source.text,
            translatedStablePrefixLength: translated.stablePrefixLength,
            sourceStablePrefixLength: source.stablePrefixLength,
            translatedAgedPrefixLength: translated.agedPrefixLength,
            sourceAgedPrefixLength: source.agedPrefixLength,
            representedHistoryEntryIDs: representedHistoryEntryIDs
        )
    }


    private static func projectedLane(
        text: String,
        stablePrefixLength: Int,
        preservesEmptyRow: Bool
    ) -> (text: String, stablePrefixLength: Int) {
        let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard preservesEmptyRow, isEmpty else {
            return (text, min(stablePrefixLength, text.count))
        }
        return (audienceEmptyLaneRow, audienceEmptyLaneRow.count)
    }

    private static let audienceEmptyLaneRow = "\u{00A0}"

    private static func joinedLane(
        leadingText: String,
        trailingText: String,
        trailingStablePrefixLength: Int,
        deduplicatesEqualText: Bool
    ) -> (
        text: String,
        stablePrefixLength: Int,
        agedPrefixLength: Int,
        includesLeadingText: Bool
    ) {
        guard leadingText.isEmpty == false else {
            return (
                trailingText,
                min(trailingStablePrefixLength, trailingText.count),
                0,
                false
            )
        }
        guard trailingText.isEmpty == false else {
            return (leadingText, leadingText.count, 0, true)
        }

        if deduplicatesEqualText {
            let normalizedLeading = leadingText.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedTrailing = trailingText.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedLeading == normalizedTrailing {
                return (
                    trailingText,
                    min(trailingStablePrefixLength, trailingText.count),
                    0,
                    false
                )
            }
        }

        let separator = "\n"
        let text = leadingText + separator + trailingText
        let trailingStable = min(trailingStablePrefixLength, trailingText.count)
        return (
            text,
            leadingText.count + separator.count + trailingStable,
            leadingText.count,
            true
        )
    }
}

/// Reconstructs one exclusive live caption from a committed row plus the current
/// draft. Replay updates a single slot in place; partial clauses must not stack
/// as separate rows.
enum LiveCaptionReplay: Sendable {
    enum Relation: Equatable, Sendable {
        case sameUtterance(displaySourceText: String)
        case independent
    }

    static func relation(
        committedSourceText: String,
        draftSourceText: String
    ) -> Relation {
        let committed = committedSourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let draft = draftSourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard committed.isEmpty == false, draft.isEmpty == false else {
            return .independent
        }

        let committedComparable = comparableText(committed)
        let draftComparable = comparableText(draft)
        guard committedComparable.isEmpty == false, draftComparable.isEmpty == false else {
            return .independent
        }

        if draftComparable == committedComparable
            || draftComparable.hasPrefix(committedComparable)
            || committedComparable.hasPrefix(draftComparable) {
            return .sameUtterance(displaySourceText: draft)
        }

        if hasCompleteSentenceBoundary(committed) {
            return .independent
        }

        if let joined = overlapJoinedText(committed: committed, draft: draft) {
            return .sameUtterance(displaySourceText: joined)
        }

        if startsLikeLatinContinuation(draft) {
            let spacer = committed.last?.isWhitespace == true ? "" : " "
            return .sameUtterance(displaySourceText: committed + spacer + draft)
        }

        return .independent
    }

    static func comparableText(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: comparableTrimCharacterSet) }
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static let comparableTrimCharacterSet = CharacterSet.punctuationCharacters
        .union(.symbols)

    private static func overlapJoinedText(committed: String, draft: String) -> String? {
        let committedChars = Array(committed)
        let draftChars = Array(draft)
        let maxOverlap = min(committedChars.count, draftChars.count)
        let minimumOverlap = containsCJK(committed) || containsCJK(draft) ? 2 : 3
        guard maxOverlap >= minimumOverlap else {
            return nil
        }

        for overlap in stride(from: maxOverlap, through: minimumOverlap, by: -1) {
            let suffix = String(committedChars.suffix(overlap))
            let prefix = String(draftChars.prefix(overlap))
            guard comparableText(suffix) == comparableText(prefix),
                  comparableText(suffix).count >= minimumOverlap,
                  isTokenBoundaryOverlap(in: committed, overlap: overlap) else {
                continue
            }
            return String(committedChars.dropLast(overlap)) + draft
        }

        return nil
    }

    private static func isTokenBoundaryOverlap(in committed: String, overlap: Int) -> Bool {
        let cutIndex = committed.index(committed.endIndex, offsetBy: -overlap)
        if cutIndex == committed.startIndex {
            return true
        }
        let previous = committed[committed.index(before: cutIndex)]
        if previous.isWhitespace || previous.isPunctuation {
            return true
        }
        return containsCJK(committed)
    }

    private static func startsLikeLatinContinuation(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.first(where: { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) || LanguageIdentity.isCJKScalar($0) }) else {
            return false
        }
        if LanguageIdentity.isCJKScalar(scalar) {
            return false
        }
        return CharacterSet.lowercaseLetters.contains(scalar)
    }

    static func hasCompleteSentenceBoundary(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("...") || trimmed.hasSuffix("…") {
            return false
        }
        return SentenceBoundaryHeuristics.endsWithLikelySentenceTerminator(in: trimmed)
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: LanguageIdentity.isCJKScalar)
    }
}

extension OverlayPreviewState {

    var liveCaptionPresentation: OverlayLiveCaptionPresentation {
        let committedCaption = committedLiveCaption

        guard hasActiveDraftLayer else {
            return OverlayLiveCaptionPresentation(
                precedingCommittedCaption: nil,
                currentCaption: committedCaption
            )
        }

        let draftSourceText = self.draftSourceText ?? ""
        let draftTranslatedText: String
        if draftSourceText.isEmpty {
            draftTranslatedText = self.draftTranslatedText ?? ""
        } else {
            draftTranslatedText = visibleDraftTranslatedText(
                for: draftSourceText,
                promotionID: draftPromotionID
            ) ?? ""
        }

        let identity = draftPromotionID
            .map(OverlayLiveCaptionPresentation.Identity.promotion)
            ?? .captionEpoch(captionEpoch &+ 1)

        // Promotion publishes the committed caption before the draft is cleared.
        // Collapse that overlap so SwiftUI sees one stable slot and committed text wins.
        if committedCaption?.id == identity {
            return OverlayLiveCaptionPresentation(
                precedingCommittedCaption: nil,
                currentCaption: committedCaption
            )
        }

        let draftCaption = OverlayLiveCaptionPresentation.Caption(
            id: identity,
            phase: .tentative,
            translatedText: draftTranslatedText,
            sourceText: draftSourceText,
            translatedStablePrefixLength: draftTranslatedStablePrefixLength,
            sourceStablePrefixLength: draftSourceStablePrefixLength,
            translatedAgedPrefixLength: 0,
            sourceAgedPrefixLength: 0
        )

        guard let committedCaption else {
            return OverlayLiveCaptionPresentation(
                precedingCommittedCaption: nil,
                currentCaption: draftCaption
            )
        }

        switch LiveCaptionReplay.relation(
            committedSourceText: committedCaption.sourceText,
            draftSourceText: draftSourceText
        ) {
        case .sameUtterance(let displaySourceText):
            let source = mergedSameUtteranceLane(
                committedText: committedCaption.sourceText,
                draftText: draftSourceText,
                draftStablePrefixLength: draftSourceStablePrefixLength,
                displayText: displaySourceText
            )
            let translated = mergedSameUtteranceLane(
                committedText: committedCaption.translatedText,
                draftText: draftTranslatedText,
                draftStablePrefixLength: draftTranslatedStablePrefixLength,
                appendIndependent: displaySourceText != draftSourceText
            )
            return OverlayLiveCaptionPresentation(
                precedingCommittedCaption: nil,
                currentCaption: OverlayLiveCaptionPresentation.Caption(
                    id: identity,
                    phase: .tentative,
                    translatedText: translated.text,
                    sourceText: source.text,
                    translatedStablePrefixLength: translated.stablePrefixLength,
                    sourceStablePrefixLength: source.stablePrefixLength,
                    translatedAgedPrefixLength: 0,
                    sourceAgedPrefixLength: 0
                )
            )
        case .independent:
            return OverlayLiveCaptionPresentation(
                precedingCommittedCaption: committedCaption,
                currentCaption: draftCaption
            )
        }
    }

    private func mergedSameUtteranceLane(
        committedText: String,
        draftText: String,
        draftStablePrefixLength: Int,
        displayText preferredDisplayText: String? = nil,
        appendIndependent: Bool = false
    ) -> (text: String, stablePrefixLength: Int) {
        guard draftText.isEmpty == false else {
            return (committedText, committedText.count)
        }
        guard committedText.isEmpty == false else {
            return (draftText, min(draftStablePrefixLength, draftText.count))
        }

        let displayText: String
        if let preferredDisplayText {
            displayText = preferredDisplayText
        } else {
            switch LiveCaptionReplay.relation(
                committedSourceText: committedText,
                draftSourceText: draftText
            ) {
            case .sameUtterance(let mergedText):
                displayText = mergedText
            case .independent:
                if appendIndependent {
                    let separator = LiveCaptionTextStability.separator(
                        between: committedText,
                        and: draftText
                    )
                    displayText = committedText + separator + draftText
                } else {
                    displayText = draftText
                }
            }
        }

        var stablePrefixLength = min(draftStablePrefixLength, draftText.count)
        if displayText == committedText {
            stablePrefixLength = displayText.count
        } else if displayText == draftText {
            if draftText.hasPrefix(committedText) {
                stablePrefixLength = max(stablePrefixLength, committedText.count)
            } else if committedText.hasPrefix(draftText) {
                stablePrefixLength = draftText.count
            } else {
                stablePrefixLength = max(
                    stablePrefixLength,
                    LiveCaptionTextStability.commonStablePrefixLength(
                        previous: committedText,
                        current: draftText
                    )
                )
            }
        } else if displayText.hasSuffix(draftText) {
            let draftStart = displayText.count - draftText.count
            stablePrefixLength = max(
                min(displayText.count, committedText.count),
                draftStart + stablePrefixLength
            )
        }

        return (
            displayText,
            min(max(0, stablePrefixLength), displayText.count)
        )
    }

    private var committedLiveCaption: OverlayLiveCaptionPresentation.Caption? {
        guard translatedText.isEmpty == false || sourceText.isEmpty == false else {
            return nil
        }

        let identity = committedPromotionID
            .map(OverlayLiveCaptionPresentation.Identity.promotion)
            ?? .captionEpoch(captionEpoch)

        return OverlayLiveCaptionPresentation.Caption(
            id: identity,
            phase: .committed,
            translatedText: translatedText,
            sourceText: sourceText,
            translatedAgedPrefixLength: 0,
            sourceAgedPrefixLength: 0,
            representedHistoryEntryIDs: committedCaptionID.map { [$0] } ?? []
        )
    }
}
