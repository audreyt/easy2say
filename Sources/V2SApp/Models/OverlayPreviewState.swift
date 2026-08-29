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
    /// Incremental translation of the current draft text.
    var draftTranslatedText: String? = nil
    var draftTranslationSourceText: String? = nil
    var draftTranslationPromotionID: UUID? = nil
    var draftPromotionID: UUID? = nil
    var draftAudioStartMs: Int? = nil

    // MARK: History layer — committed captions the user can scroll back through
    var history: [OverlayHistoryEntry] = []

    // MARK: Caption identity
    var captionEpoch: Int = 0
    var committedPromotionID: UUID? = nil
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

        self.draftTranslatedText = translatedText
        self.draftTranslationSourceText = sourceText
        self.draftTranslationPromotionID = promotionID
    }

    mutating func clearDraftTranslation() {
        draftTranslatedText = nil
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
    }

    let precedingCommittedCaption: Caption?
    let currentCaption: Caption?
}

/// Reconstructs one exclusive live caption from a committed row plus the current
/// draft. Livecaption-style replay updates a single slot in place; partial clauses
/// must not stack as separate rows.
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
            sourceText: draftSourceText
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
            let translatedText: String
            if displaySourceText == draftSourceText {
                translatedText = draftTranslatedText
            } else if displaySourceText == committedCaption.sourceText {
                translatedText = committedCaption.translatedText
            } else {
                translatedText = ""
            }
            return OverlayLiveCaptionPresentation(
                precedingCommittedCaption: nil,
                currentCaption: OverlayLiveCaptionPresentation.Caption(
                    id: identity,
                    phase: .tentative,
                    translatedText: translatedText,
                    sourceText: displaySourceText
                )
            )
        case .independent:
            return OverlayLiveCaptionPresentation(
                precedingCommittedCaption: committedCaption,
                currentCaption: draftCaption
            )
        }
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
            sourceText: sourceText
        )
    }
}
