import AppKit
import SwiftUI

@MainActor
final class AudienceDisplayPresentationState: ObservableObject {
    private typealias Caption = OverlayLiveCaptionPresentation.Caption
    private typealias Identity = OverlayLiveCaptionPresentation.Identity

    private enum UpdateOrigin {
        case history
        case live
    }

    private struct IncomingUtterance {
        let caption: Caption
        let identityAliases: Set<Identity>
        let historyEntryIDs: Set<UUID>
        let liveIdentity: Identity?
        let origin: UpdateOrigin
    }

    private struct RetainedUtterance {
        var caption: Caption
        var identityAliases: Set<Identity>
        var historyEntryIDs: Set<UUID>
        var latestLiveIdentity: Identity?
    }

    private static let emptyLiveCaptionPresentation = OverlayLiveCaptionPresentation(
        precedingCommittedCaption: nil,
        currentCaption: nil
    )

    @Published private(set) var isFullScreen = false
    @Published private(set) var liveCaptionPresentation: OverlayLiveCaptionPresentation

    private var retainedUtterances: [RetainedUtterance] = []
    private var seenHistoryEntryIDs: Set<UUID> = []
    private var retiredIdentityAliases: Set<Identity> = []

    init(initialOverlayState: OverlayPreviewState? = nil) {
        liveCaptionPresentation = Self.emptyLiveCaptionPresentation
        if let initialOverlayState {
            consume(initialOverlayState)
        }
    }

    func setFullScreen(_ isFullScreen: Bool) {
        guard self.isFullScreen != isFullScreen else { return }
        self.isFullScreen = isFullScreen
    }

    /// Audience captions are a persistent two-utterance projection. Overlay history
    /// is scrollback; it must never replace a newer audience utterance merely because
    /// a draft expired or a committed caption moved into history.
    func consume(_ overlayState: OverlayPreviewState?) {
        guard let overlayState else {
            resetCaptions()
            return
        }

        for entry in overlayState.history {
            consumeHistoryEntry(entry)
        }

        let livePresentation = overlayState.liveCaptionPresentation
        if let precedingCaption = livePresentation.precedingCommittedCaption {
            consumeLiveCaption(precedingCaption, from: overlayState)
        }
        if let currentCaption = livePresentation.currentCaption {
            consumeLiveCaption(currentCaption, from: overlayState)
        }

        publishLiveCaptionPresentation()
    }

    private func consumeHistoryEntry(_ entry: OverlayHistoryEntry) {
        let identity = Identity.promotion(entry.id)
        let caption = Caption(
            id: identity,
            phase: .committed,
            translatedText: entry.translatedText,
            sourceText: entry.sourceText,
            representedHistoryEntryIDs: [entry.id]
        )
        let incoming = IncomingUtterance(
            caption: caption,
            identityAliases: [identity],
            historyEntryIDs: [entry.id],
            liveIdentity: nil,
            origin: .history
        )

        let hasRetainedMatch = matchingIndices(for: incoming).isEmpty == false
        if hasRetainedMatch == false, seenHistoryEntryIDs.contains(entry.id) {
            return
        }
        seenHistoryEntryIDs.insert(entry.id)

        let fallbackIndex = hasRetainedMatch
            ? nil
            : unboundLivePromotionFallbackIndex(for: entry)

        upsert(incoming, preferredIndex: fallbackIndex)
    }

    /// A live caption can become committed before AppModel publishes its first
    /// history ID. Reconcile that later archive only with the unique newest
    /// unbound live row; older retained rows are never eligible.
    private func unboundLivePromotionFallbackIndex(for entry: OverlayHistoryEntry) -> Int? {
        let matchingUnboundIndices = retainedUtterances.indices.filter { index in
            let retained = retainedUtterances[index]
            guard retained.historyEntryIDs.isEmpty else {
                return false
            }

            let retainedSource = retained.caption.sourceText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let archivedSource = entry.sourceText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if retainedSource.isEmpty == false,
               archivedSource.isEmpty == false,
               case .sameUtterance = LiveCaptionReplay.relation(
                   committedSourceText: retainedSource,
                   draftSourceText: archivedSource
               ) {
                return true
            }

            let retainedSemanticText = semanticText(
                sourceText: retained.caption.sourceText,
                translatedText: retained.caption.translatedText
            )
            let archivedSemanticText = semanticText(
                sourceText: entry.sourceText,
                translatedText: entry.translatedText
            )
            return retainedSemanticText.isEmpty == false
                && retainedSemanticText == archivedSemanticText
        }

        guard matchingUnboundIndices.count == 1,
              let candidateIndex = matchingUnboundIndices.first,
              candidateIndex == retainedUtterances.indices.last else {
            return nil
        }
        return candidateIndex
    }

    private func consumeLiveCaption(
        _ caption: Caption,
        from overlayState: OverlayPreviewState
    ) {
        guard caption.sourceText.isEmpty == false || caption.translatedText.isEmpty == false else {
            return
        }

        var identityAliases: Set<Identity> = [caption.id]
        var historyEntryIDs = caption.representedHistoryEntryIDs

        // A continuing draft can replace the committed row under a new promotion
        // identity. Carry the committed aliases into that merged utterance so a
        // later draft clear cannot reveal the older committed text again.
        if caption.phase == .tentative,
           overlayState.hasActiveDraftLayer,
           let draftSourceText = overlayState.draftSourceText,
           case .sameUtterance = LiveCaptionReplay.relation(
               committedSourceText: overlayState.sourceText,
               draftSourceText: draftSourceText
           ) {
            let committedIdentity = overlayState.committedPromotionID
                .map(Identity.promotion)
                ?? .captionEpoch(overlayState.captionEpoch)
            identityAliases.insert(committedIdentity)
            if let committedCaptionID = overlayState.committedCaptionID {
                identityAliases.insert(.promotion(committedCaptionID))
                historyEntryIDs.insert(committedCaptionID)
            }
        }

        upsert(
            IncomingUtterance(
                caption: caption,
                identityAliases: identityAliases,
                historyEntryIDs: historyEntryIDs,
                liveIdentity: caption.id,
                origin: .live
            )
        )
    }

    private func upsert(
        _ incoming: IncomingUtterance,
        preferredIndex: Int? = nil
    ) {
        var matches = matchingIndices(for: incoming)
        if let preferredIndex, matches.contains(preferredIndex) == false {
            matches.append(preferredIndex)
        }
        matches.sort()

        guard let targetIndex = matches.last else {
            guard incoming.identityAliases.isDisjoint(with: retiredIdentityAliases) else {
                return
            }
            retainedUtterances.append(
                RetainedUtterance(
                    caption: incoming.caption,
                    identityAliases: incoming.identityAliases,
                    historyEntryIDs: incoming.historyEntryIDs,
                    latestLiveIdentity: incoming.liveIdentity
                )
            )
            trimToLatestUtterances()
            return
        }

        var retained = retainedUtterances[targetIndex]
        for index in matches where index != targetIndex {
            let duplicate = retainedUtterances[index]
            retained.identityAliases.formUnion(duplicate.identityAliases)
            retained.historyEntryIDs.formUnion(duplicate.historyEntryIDs)
            if retained.latestLiveIdentity == nil {
                retained.latestLiveIdentity = duplicate.latestLiveIdentity
            }
        }

        for index in matches.reversed() {
            retainedUtterances.remove(at: index)
        }
        let insertionIndex = targetIndex - matches.count(where: { $0 < targetIndex })
        retainedUtterances.insert(retained, at: insertionIndex)

        var updated = retainedUtterances[insertionIndex]
        apply(incoming, to: &updated)
        retainedUtterances[insertionIndex] = updated
        trimToLatestUtterances()
    }

    private func apply(
        _ incoming: IncomingUtterance,
        to retained: inout RetainedUtterance
    ) {
        let identityWasAlreadyKnown = incoming.liveIdentity.map {
            retained.identityAliases.contains($0)
        } ?? false
        let isOlderLiveIdentity = incoming.origin == .live
            && identityWasAlreadyKnown
            && incoming.liveIdentity != retained.latestLiveIdentity

        retained.identityAliases.formUnion(incoming.identityAliases)
        retained.historyEntryIDs.formUnion(incoming.historyEntryIDs)
        let representedHistoryEntryIDs =
            retained.caption.representedHistoryEntryIDs.union(retained.historyEntryIDs)

        if incoming.origin == .history,
           isHistorySourceRollback(
               currentSourceText: retained.caption.sourceText,
               incomingSourceText: incoming.caption.sourceText
           ) {
            retained.caption = Caption(
                id: retained.caption.id,
                phase: retained.caption.phase,
                translatedText: retained.caption.translatedText,
                sourceText: retained.caption.sourceText,
                translatedStablePrefixLength: retained.caption.translatedStablePrefixLength,
                sourceStablePrefixLength: retained.caption.sourceStablePrefixLength,
                translatedAgedPrefixLength: retained.caption.translatedAgedPrefixLength,
                sourceAgedPrefixLength: retained.caption.sourceAgedPrefixLength,
                representedHistoryEntryIDs: representedHistoryEntryIDs
            )
            return
        }

        if isOlderLiveIdentity {
            let sourceIsUnchanged = incoming.caption.sourceText == retained.caption.sourceText
            let shouldFillMissingTranslation = sourceIsUnchanged
                && retained.caption.translatedText.isEmpty
                && incoming.caption.translatedText.isEmpty == false

            retained.caption = Caption(
                id: retained.caption.id,
                phase: retained.caption.phase,
                translatedText: shouldFillMissingTranslation
                    ? incoming.caption.translatedText
                    : retained.caption.translatedText,
                sourceText: retained.caption.sourceText,
                translatedStablePrefixLength: shouldFillMissingTranslation
                    ? incoming.caption.translatedStablePrefixLength
                    : retained.caption.translatedStablePrefixLength,
                sourceStablePrefixLength: retained.caption.sourceStablePrefixLength,
                translatedAgedPrefixLength: shouldFillMissingTranslation
                    ? incoming.caption.translatedAgedPrefixLength
                    : retained.caption.translatedAgedPrefixLength,
                sourceAgedPrefixLength: retained.caption.sourceAgedPrefixLength,
                representedHistoryEntryIDs: representedHistoryEntryIDs
            )
            return
        }

        let sourceChanged = incoming.caption.sourceText != retained.caption.sourceText
        let preservesExistingTranslation = sourceChanged == false
            && incoming.caption.translatedText.isEmpty
            && retained.caption.translatedText.isEmpty == false

        retained.caption = Caption(
            id: retained.caption.id,
            phase: incoming.caption.phase,
            translatedText: preservesExistingTranslation
                ? retained.caption.translatedText
                : incoming.caption.translatedText,
            sourceText: incoming.caption.sourceText,
            translatedStablePrefixLength: preservesExistingTranslation
                ? retained.caption.translatedStablePrefixLength
                : incoming.caption.translatedStablePrefixLength,
            sourceStablePrefixLength: incoming.caption.sourceStablePrefixLength,
            translatedAgedPrefixLength: preservesExistingTranslation
                ? retained.caption.translatedAgedPrefixLength
                : incoming.caption.translatedAgedPrefixLength,
            sourceAgedPrefixLength: incoming.caption.sourceAgedPrefixLength,
            representedHistoryEntryIDs: representedHistoryEntryIDs
        )
        if let liveIdentity = incoming.liveIdentity {
            retained.latestLiveIdentity = liveIdentity
        }
    }

    private func isHistorySourceRollback(
        currentSourceText: String,
        incomingSourceText: String
    ) -> Bool {
        let current = LiveCaptionReplay.comparableText(currentSourceText)
        let incoming = LiveCaptionReplay.comparableText(incomingSourceText)
        guard incoming.isEmpty == false,
              incoming.count < current.count else {
            return false
        }

        if current.hasPrefix(incoming) {
            return true
        }
        if case .sameUtterance = LiveCaptionReplay.relation(
            committedSourceText: incomingSourceText,
            draftSourceText: currentSourceText
        ) {
            return true
        }
        return false
    }

    private func matchingIndices(for incoming: IncomingUtterance) -> [Int] {
        retainedUtterances.indices.filter { index in
            let retained = retainedUtterances[index]
            return retained.identityAliases.isDisjoint(with: incoming.identityAliases) == false
                || retained.historyEntryIDs.isDisjoint(with: incoming.historyEntryIDs) == false
        }
    }

    private func trimToLatestUtterances() {
        let overflow = max(0, retainedUtterances.count - 2)
        guard overflow > 0 else { return }

        let retired = retainedUtterances.prefix(overflow)
        for utterance in retired {
            retiredIdentityAliases.formUnion(utterance.identityAliases)
            seenHistoryEntryIDs.formUnion(utterance.historyEntryIDs)
        }
        retainedUtterances.removeFirst(overflow)
    }

    private func publishLiveCaptionPresentation() {
        let nextPresentation: OverlayLiveCaptionPresentation
        switch retainedUtterances.count {
        case 0:
            nextPresentation = Self.emptyLiveCaptionPresentation
        case 1:
            nextPresentation = OverlayLiveCaptionPresentation(
                precedingCommittedCaption: nil,
                currentCaption: retainedUtterances[0].caption
            )
        default:
            nextPresentation = OverlayLiveCaptionPresentation(
                precedingCommittedCaption: retainedUtterances[0].caption,
                currentCaption: retainedUtterances[1].caption
            )
        }

        guard liveCaptionPresentation != nextPresentation else { return }
        liveCaptionPresentation = nextPresentation
    }

    private func resetCaptions() {
        retainedUtterances.removeAll()
        seenHistoryEntryIDs.removeAll()
        retiredIdentityAliases.removeAll()
        guard liveCaptionPresentation != Self.emptyLiveCaptionPresentation else { return }
        liveCaptionPresentation = Self.emptyLiveCaptionPresentation
    }

    private func semanticText(sourceText: String, translatedText: String) -> String {
        let source = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        if source.isEmpty == false {
            return source
        }
        return translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}


struct AudienceDisplayView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var presentationState: AudienceDisplayPresentationState
    let onExit: () -> Void

    @State private var isHovering = false
    @State private var hoverDismissTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
                .ignoresSafeArea()

            GeometryReader { proxy in
                let horizontalPadding = max(32, (proxy.size.width - maxContentWidth(for: proxy.size.width)) / 2)
                let bottomPadding = max(36, proxy.size.height * 0.06)
                let topPadding = max(32, proxy.size.height * 0.05)

                CaptionFlowContentView(
                    model: model,
                    liveCaptionPresentationOverride: presentationState.liveCaptionPresentation,
                    liveCaptionProjection: .audienceUtterancePairs,
                    showsScrollbarPadding: false,
                    updatesModelHistoryVisibleCount: false,
                    reservesColumnHeaderSpace: false,
                    columnHeaderOpacity: isHovering ? 1.0 : 0.0,
                    showsHistory: false,
                    alignsTopDownCaptionsLeading: true,
                    animatesLiveCaptionLineEntrance: false,
                    stabilizesLiveCaptionLinePositions: true
                )
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, bottomPadding)
                .padding(.top, topPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            AudienceDisplayExitAffordance(
                title: exitButtonTitle,
                action: onExit
            )
            .opacity(isHovering ? 1.0 : 0.0)
            .accessibilityHidden(isHovering == false)
            .animation(.easeInOut(duration: 0.25), value: isHovering)
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                if isHovering == false {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isHovering = true
                    }
                }
                hoverDismissTask?.cancel()
                hoverDismissTask = Task {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    if Task.isCancelled == false {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            isHovering = false
                        }
                    }
                }
            case .ended:
                hoverDismissTask?.cancel()
                withAnimation(.easeInOut(duration: 0.35)) {
                    isHovering = false
                }
            }
        }
        .modifier(OverlayTranslationHostModifier(model: model, role: .audienceDisplay))
    }

    private var exitButtonTitle: String {
        let key: AppTextKey = presentationState.isFullScreen
            ? .iosExitFullscreen
            : .hideAudienceDisplay
        return "\(model.localized(key)) (Esc)"
    }

    private func maxContentWidth(for screenWidth: CGFloat) -> CGFloat {
        min(screenWidth * 0.88, 1600)
    }
}

struct AudienceDisplayExitAffordance: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Color.white.opacity(0.88))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                Capsule()
                    .fill(Color.black.opacity(0.70))
                    .overlay {
                        Capsule()
                            .stroke(Color.white.opacity(0.24), lineWidth: 1)
                    }
            }
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}
