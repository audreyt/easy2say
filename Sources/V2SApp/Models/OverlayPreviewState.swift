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

    // MARK: History layer — committed captions the user can scroll back through
    var history: [OverlayHistoryEntry] = []

    // MARK: Caption identity
    var captionEpoch: Int = 0
    var committedPromotionID: UUID? = nil

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

extension OverlayPreviewState {
    var liveCaptionPresentation: OverlayLiveCaptionPresentation {
        let committedCaption = committedLiveCaption

        guard hasActiveDraftLayer else {
            return OverlayLiveCaptionPresentation(
                precedingCommittedCaption: nil,
                currentCaption: committedCaption
            )
        }

        let sourceText = draftSourceText ?? ""
        let translatedText: String
        if sourceText.isEmpty {
            translatedText = draftTranslatedText ?? ""
        } else {
            translatedText = visibleDraftTranslatedText(
                for: sourceText,
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

        return OverlayLiveCaptionPresentation(
            precedingCommittedCaption: committedCaption,
            currentCaption: OverlayLiveCaptionPresentation.Caption(
                id: identity,
                phase: .tentative,
                translatedText: translatedText,
                sourceText: sourceText
            )
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
            sourceText: sourceText
        )
    }
}
