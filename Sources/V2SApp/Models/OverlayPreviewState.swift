import Foundation

/// The committed caption shown beside the document-driven surfaces: status and
/// preview text while a session idles, the last row's pane texts once rows
/// exist. Draft/history machinery is gone — `CaptionDocument` owns that now.
struct OverlayPreviewState: Equatable {
    var translatedText: String
    var sourceText: String
    var sourceName: String

    /// Bumps for each new committed caption so the presentation identity
    /// changes when a different row takes over.
    var captionEpoch: Int = 0
    var committedSpeakerIndex: Int? = nil
    /// Committed in the live pipeline; the iOS UI-test harness uses .tentative
    /// for the dimmed pre-commit look.
    var phase: OverlayLiveCaptionPresentation.Phase = .committed

    var liveCaptionPresentation: OverlayLiveCaptionPresentation {
        OverlayLiveCaptionPresentation(
            precedingCommittedCaption: nil,
            currentCaption: committedLiveCaption
        )
    }

    private var committedLiveCaption: OverlayLiveCaptionPresentation.Caption? {
        guard translatedText.isEmpty == false || sourceText.isEmpty == false else {
            return nil
        }
        return OverlayLiveCaptionPresentation.Caption(
            id: .captionEpoch(captionEpoch),
            phase: phase,
            translatedText: translatedText,
            sourceText: sourceText,
            speakerIndex: committedSpeakerIndex
        )
    }
}

struct OverlayLiveCaptionPresentation: Equatable {
    enum Phase: Equatable {
        case tentative
        case committed
    }

    enum Identity: Hashable {
        case promotion(UUID)
        /// A committed-lane text with no caption behind it (status placeholders).
        case captionEpoch(Int)
        /// A draft with no producer identity. Its own case, so it can never
        /// alias a committed row.
        case draftEpoch(Int)
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
        /// Display speaker index (0 = first speaker heard), or nil.
        let speakerIndex: Int?

        init(
            id: Identity,
            phase: Phase,
            translatedText: String,
            sourceText: String,
            translatedStablePrefixLength: Int? = nil,
            sourceStablePrefixLength: Int? = nil,
            translatedAgedPrefixLength: Int = 0,
            sourceAgedPrefixLength: Int = 0,
            representedHistoryEntryIDs: Set<UUID> = [],
            speakerIndex: Int? = nil
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
            self.speakerIndex = speakerIndex
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

    /// The committed row to display; kept for API compatibility with iOS
    /// `CaptionHalves`, which reads `currentCaption`.
    var displayCaption: Caption? {
        currentCaption ?? precedingCommittedCaption
    }
}
