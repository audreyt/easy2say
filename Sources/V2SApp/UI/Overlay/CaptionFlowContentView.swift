import AppKit
import SwiftUI

struct CaptionFlowContentView: View {
    @ObservedObject var model: AppModel
    var showsScrollbarPadding: Bool = false
    var updatesModelHistoryVisibleCount: Bool = false
    var reservesColumnHeaderSpace: Bool = true
    var columnHeaderOpacity: Double = 1.0

    @Namespace private var captionFlowNamespace
    @State private var lastDraftSlotHeight: CGFloat = 0.0
    @State private var lastLiveLayersHeight: CGFloat = 0.0
    @State private var lastCommittedSlotHeight: CGFloat = 0.0
    @State private var measuredHistoryEntryHeights: [UUID: CGFloat] = [:]

    var body: some View {
        Group {
            if let state = model.overlayState {
                GeometryReader { proxy in
                    let captionAreaHeight = proxy.size.height - captionColumnHeaderHeight
                    let availableHistoryHeight = availableHistoryHeight(for: captionAreaHeight, state: state)
                    let visibleHistoryEntries = historyVisibleEntries(from: state.history, availableHeight: availableHistoryHeight)
                    let visibleHistoryCount = visibleHistoryEntries.count

                    ZStack(alignment: .bottom) {
                        VStack(alignment: .center, spacing: Self.liveStackSpacing) {
                            ForEach(Array(visibleHistoryEntries.enumerated()), id: \.element.id) { index, entry in
                                historyEntry(
                                    entry,
                                    index: index,
                                    totalCount: visibleHistoryEntries.count
                                )
                            }

                            liveLayers(state)
                                .background(liveLayersHeightReader)
                        }
                        .animation(
                            Self.captionFlowAnimation,
                            value: historyLayoutAnimationState(for: state, visibleHistoryEntries: visibleHistoryEntries)
                        )
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .bottom)
                    }
                    .padding(.top, captionColumnHeaderHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .mask(continuousFlowMask)
                    .background(alignment: .center) { captionColumnDivider }
                    .overlay(alignment: .top) { captionColumnHeader }
                    .onPreferenceChange(DraftSlotHeightPreferenceKey.self) { height in
                        guard height > 0 else { return }
                        let snappedHeight = ceil(height)
                        let downwardDelta = lastDraftSlotHeight - snappedHeight

                        if lastDraftSlotHeight == 0
                            || snappedHeight >= lastDraftSlotHeight
                            || downwardDelta >= Self.draftHeightJitterTolerance {
                            lastDraftSlotHeight = snappedHeight
                        }
                    }
                    .onPreferenceChange(LiveLayersHeightPreferenceKey.self) { height in
                        guard height > 0 else { return }
                        lastLiveLayersHeight = ceil(height)
                    }
                    .onPreferenceChange(CommittedSlotHeightPreferenceKey.self) { height in
                        guard height > 0 else { return }
                        lastCommittedSlotHeight = ceil(height)
                    }
                    .onPreferenceChange(HistoryEntryHeightsPreferenceKey.self) { heights in
                        guard heights.isEmpty == false else { return }
                        for (id, height) in heights where height > 0 {
                            measuredHistoryEntryHeights[id] = ceil(height)
                        }
                    }
                    .onAppear {
                        if updatesModelHistoryVisibleCount {
                            model.updateOverlayHistoryVisibleCount(visibleHistoryCount)
                        }
                    }
                    .onChange(of: visibleHistoryCount) { _, newCount in
                        if updatesModelHistoryVisibleCount {
                            model.updateOverlayHistoryVisibleCount(newCount)
                        }
                    }
                    .onChange(of: state.history.map(\.id)) { _, ids in
                        let validIDs = Set(ids)
                        measuredHistoryEntryHeights = measuredHistoryEntryHeights.filter { validIDs.contains($0.key) }
                    }
                    .onChange(of: state.history.count) { _, _ in
                        if updatesModelHistoryVisibleCount {
                            model.updateOverlayHistoryVisibleCount(visibleHistoryCount)
                        }
                    }
                    .onChange(of: model.sessionState) { _, newState in
                        if newState != .running {
                            lastDraftSlotHeight = 0
                            lastLiveLayersHeight = 0
                            lastCommittedSlotHeight = 0
                            measuredHistoryEntryHeights = [:]
                        }
                    }
                }
                .padding(.leading, 20)
                .padding(
                    .trailing,
                    showsScrollbarPadding
                        ? 20 + OverlayHistoryScrollbarLayout.panelWidth + OverlayHistoryScrollbarLayout.contentSpacing
                        : 20
                )
                .padding(.top, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Continuous flow

    private func liveLayers(_ state: OverlayPreviewState) -> some View {
        VStack(alignment: .center, spacing: Self.liveStackSpacing) {
            if hasCommittedCaption(state) {
                committedLayer(state)
            } else if shouldReserveCommittedSlot(for: state) {
                committedSlotPlaceholder
            }

            draftLayer(state)
        }
        .animation(Self.captionFlowAnimation, value: flowAnimationState(for: state))
    }

    private func committedLayer(_ state: OverlayPreviewState) -> some View {
        applyingPromotionTransition(
            to: captionPair(
                translated: state.translatedText,
                translatedColor: baseSubtitleColor,
                source: state.sourceText,
                sourceColor: subtitleColor(opacity: 0.82)
            )
            .background(committedSlotHeightReader),
            key: promotionKey(
                promotionID: state.committedPromotionID,
                sourceText: state.sourceText,
                translatedText: state.translatedText
            )
        )
    }

    private func translatedText(_ text: String, color: Color) -> some View {
        captionText(
            attributedCaptionText(
                text: text,
                fillColor: color
            ),
            rawText: text,
            fontSize: model.overlayStyle.scaledTranslatedFontSize,
            weight: .semibold
        )
    }

    private func sourceText(_ text: String, color: Color) -> some View {
        captionText(
            attributedCaptionText(
                text: text,
                fillColor: color
            ),
            rawText: text,
            fontSize: displayedSourceFontSize,
            weight: displayedSourceFontWeight
        )
    }

    // MARK: - Draft layer (50–65% opacity, stable prefix slightly brighter)

    private func draftLayer(_ state: OverlayPreviewState) -> some View {
        ZStack(alignment: .top) {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let draftText = state.draftSourceText, !draftText.isEmpty {
                let visibleDraftTranslatedText = displayedDraftTranslatedText(
                    for: state,
                    draftText: draftText
                )
                applyingPromotionTransition(
                    to: draftBody(state: state, draftText: draftText, translated: visibleDraftTranslatedText)
                        .background(draftSlotHeightReader),
                    key: promotionKey(
                        promotionID: state.draftPromotionID,
                        sourceText: draftText,
                        translatedText: visibleDraftTranslatedText ?? draftText
                    )
                )
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: draftSlotHeight(for: state),
            maxHeight: draftSlotHeight(for: state),
            alignment: .top
        )
    }

    @ViewBuilder
    private func draftBody(
        state: OverlayPreviewState,
        draftText: String,
        translated: String?
    ) -> some View {
        if usesColumnCaptions {
            HStack(alignment: .top, spacing: Self.captionColumnSpacing) {
                inLayoutOrder(
                    translated: {
                        captionColumn {
                            draftTranslatedLine(translated)
                        }
                        .environment(\.layoutDirection, draftTranslatedCaptionLayoutDirection)
                    },
                    original: {
                        captionColumn {
                            draftSourceLine(state: state, draftText: draftText)
                        }
                        .environment(\.layoutDirection, originalCaptionLayoutDirection)
                    }
                )
            }
            .environment(\.layoutDirection, .leftToRight)
        } else {
            VStack(spacing: 2) {
                inLayoutOrder(
                    translated: {
                        Group {
                            if showsTranslatedSubtitle {
                                draftTranslatedLine(translated)
                            }
                        }
                        .environment(\.layoutDirection, draftTranslatedCaptionLayoutDirection)
                    },
                    original: {
                        Group {
                            if showsOriginalSubtitle {
                                draftSourceLine(state: state, draftText: draftText)
                            }
                        }
                        .environment(\.layoutDirection, originalCaptionLayoutDirection)
                    }
                )
            }
        }
    }

    @ViewBuilder
    private func draftTranslatedLine(_ translated: String?) -> some View {
        if let translated {
            translatedText(
                translated,
                color: subtitleColor(opacity: 0.55)
            )
        } else if model.shouldReserveDraftTranslationSlot {
            Text(" ")
                .font(.system(size: model.overlayStyle.scaledTranslatedFontSize, weight: .semibold))
                .multilineTextAlignment(captionTextAlignment)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .hidden()
                .accessibilityHidden(true)
        }
    }

    private func draftSourceLine(state: OverlayPreviewState, draftText: String) -> some View {
        let prefixLen = min(state.draftStablePrefixLength, draftText.count)
        let stable = String(draftText.prefix(prefixLen))
        let mutable = String(draftText.dropFirst(prefixLen))

        return captionText(
            draftSourceAttributedText(
                stable: stable,
                mutable: mutable
            ),
            rawText: draftText,
            fontSize: displayedSourceFontSize,
            weight: displayedSourceFontWeight
        )
    }

    private func historyEntry(
        _ entry: OverlayHistoryEntry,
        index: Int,
        totalCount: Int
    ) -> some View {
        let ageProgress = totalCount > 1
            ? Double(index) / Double(totalCount - 1)
            : 1.0
        let translatedOpacity = 0.34 + (0.34 * ageProgress)
        let sourceOpacity = 0.22 + (0.24 * ageProgress)

        return captionPair(
            translated: entry.translatedText,
            translatedColor: subtitleColor(opacity: translatedOpacity),
            source: entry.sourceText,
            sourceColor: subtitleColor(opacity: sourceOpacity)
        )
        .background(historyEntryHeightReader(for: entry.id))
    }

    private func historyVisibleEntries(from history: [OverlayHistoryEntry], availableHeight: CGFloat) -> [OverlayHistoryEntry] {
        guard availableHeight > 0 else { return [] }
        let offset = min(max(model.overlayHistoryScrollOffset, 0), max(0, history.count - 1))
        let upperBound = max(0, history.count - offset)
        guard upperBound > 0 else { return [] }

        var lowerBound = upperBound
        var consumedHeight: CGFloat = 0

        while lowerBound > 0 {
            let entry = history[lowerBound - 1]
            let nextHeight = historyEntryHeight(for: entry) + Self.liveStackSpacing
            if lowerBound == upperBound || consumedHeight + nextHeight <= availableHeight {
                consumedHeight += nextHeight
                lowerBound -= 1
            } else {
                break
            }
        }

        return Array(history[lowerBound..<upperBound])
    }

    private func availableHistoryHeight(for height: CGFloat, state: OverlayPreviewState) -> CGFloat {
        max(height - reservedFlowHeight(for: state), 0)
    }

    private func reservedFlowHeight(for state: OverlayPreviewState) -> CGFloat {
        max(lastLiveLayersHeight, estimatedLiveLayersHeight(for: state))
    }

    private func hasCommittedCaption(_ state: OverlayPreviewState) -> Bool {
        usesSourceAsTranslationFallback(
            translated: state.translatedText,
            source: state.sourceText
        )
            || (showsTranslatedSubtitle && state.translatedText.isEmpty == false)
            || (showsOriginalSubtitle && state.sourceText.isEmpty == false)
    }

    private func shouldReserveCommittedSlot(for state: OverlayPreviewState) -> Bool {
        hasCommittedCaption(state) || model.shouldReserveCommittedCaptionSlot
    }

    private func flowAnimationState(for state: OverlayPreviewState) -> OverlayFlowAnimationState {
        OverlayFlowAnimationState(
            captionEpoch: state.captionEpoch,
            translatedText: state.translatedText,
            sourceText: state.sourceText,
            committedPromotionID: state.committedPromotionID,
            draftPromotionID: state.draftPromotionID,
            reservesCommittedSlot: shouldReserveCommittedSlot(for: state)
        )
    }

    private func historyLayoutAnimationState(
        for state: OverlayPreviewState,
        visibleHistoryEntries: [OverlayHistoryEntry]
    ) -> OverlayHistoryLayoutAnimationState {
        OverlayHistoryLayoutAnimationState(
            historyIDs: visibleHistoryEntries.map(\.id),
            reservesCommittedSlot: shouldReserveCommittedSlot(for: state),
            draftPromotionID: state.draftPromotionID
        )
    }

    private var estimatedCommittedSlotHeight: CGFloat {
        estimatedCaptionPairHeight(
            showsTranslated: showsTranslatedSubtitle,
            showsSource: showsOriginalSubtitle
        )
    }

    private var committedSlotHeight: CGFloat {
        max(lastCommittedSlotHeight, estimatedCommittedSlotHeight)
    }

    private func historyEntryHeight(for entry: OverlayHistoryEntry) -> CGFloat {
        max(measuredHistoryEntryHeights[entry.id] ?? 0, estimatedHistoryEntryHeight(for: entry))
    }

    private func estimatedHistoryEntryHeight(for entry: OverlayHistoryEntry) -> CGFloat {
        let usesFallback = usesSourceAsTranslationFallback(
            translated: entry.translatedText,
            source: entry.sourceText
        )
        let translatedText = usesFallback ? entry.sourceText : entry.translatedText
        return estimatedCaptionPairHeight(
            showsTranslated: showsTranslatedSubtitle && translatedText.isEmpty == false,
            showsSource: showsOriginalSubtitle && entry.sourceText.isEmpty == false && usesFallback == false
        )
    }

    private func estimatedLiveLayersHeight(for state: OverlayPreviewState) -> CGFloat {
        var height = draftSlotHeight(for: state)

        if shouldReserveCommittedSlot(for: state) {
            height += committedSlotHeight + Self.liveStackSpacing
        }

        return height
    }

    private func draftSlotHeight(for state: OverlayPreviewState) -> CGFloat {
        max(lastDraftSlotHeight, estimatedDraftRowHeight(for: state)) + Self.draftBottomInset
    }

    private func estimatedDraftRowHeight(for state: OverlayPreviewState) -> CGFloat {
        let currentDraftTranslation = state.visibleDraftTranslatedText(
            for: state.draftSourceText ?? "",
            promotionID: state.draftPromotionID
        )
        let translatedHeight = showsTranslatedSubtitle && (
            (currentDraftTranslation?.isEmpty == false) || model.shouldReserveDraftTranslationSlot
        )
            ? translatedLineHeight
            : 0
        let sourceHeight = showsOriginalSubtitle ? sourceLineHeight : 0
        return usesColumnCaptions
            ? max(translatedHeight, sourceHeight)
            : translatedHeight + sourceHeight
    }

    private func displayedDraftTranslatedText(
        for state: OverlayPreviewState,
        draftText: String
    ) -> String? {
        if model.shouldReserveDraftTranslationSlot && showsOriginalSubtitle == false {
            return draftText
        }

        guard let draftTranslated = state.visibleDraftTranslatedText(
            for: draftText,
            promotionID: state.draftPromotionID
        ),
              draftTranslated.isEmpty == false else {
            return nil
        }

        return draftTranslated
    }

    private var draftSlotHeightReader: some View {
        GeometryReader { proxy in
            Color.clear
                .preference(key: DraftSlotHeightPreferenceKey.self, value: proxy.size.height)
        }
    }

    private var committedSlotPlaceholder: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: committedSlotHeight)
            .accessibilityHidden(true)
    }

    private var liveLayersHeightReader: some View {
        GeometryReader { proxy in
            Color.clear
                .preference(key: LiveLayersHeightPreferenceKey.self, value: proxy.size.height)
        }
    }

    private var committedSlotHeightReader: some View {
        GeometryReader { proxy in
            Color.clear
                .preference(key: CommittedSlotHeightPreferenceKey.self, value: proxy.size.height)
        }
    }

    private func historyEntryHeightReader(for id: UUID) -> some View {
        GeometryReader { proxy in
            Color.clear
                .preference(key: HistoryEntryHeightsPreferenceKey.self, value: [id: proxy.size.height])
        }
    }

    private func promotionKey(
        promotionID: UUID?,
        sourceText: String,
        translatedText: String
    ) -> String? {
        if let promotionID {
            return "live-caption:\(promotionID.uuidString)"
        }

        let normalizedSource = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedSource.isEmpty == false {
            return "live-caption:\(normalizedSource)"
        }

        let normalizedTranslation = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedTranslation.isEmpty == false else { return nil }
        return "live-caption:\(normalizedTranslation)"
    }

    @ViewBuilder
    private func applyingPromotionTransition<Content: View>(
        to content: Content,
        key: String?
    ) -> some View {
        if let key {
            content.matchedGeometryEffect(
                id: key,
                in: captionFlowNamespace,
                properties: .frame,
                anchor: .bottom
            )
        } else {
            content
        }
    }

    @ViewBuilder
    private func captionPair(
        translated: String,
        translatedColor: Color,
        source: String,
        sourceColor: Color
    ) -> some View {
        if usesColumnCaptions {
            HStack(alignment: .top, spacing: Self.captionColumnSpacing) {
                inLayoutOrder(
                    translated: {
                        captionColumn {
                            if translated.isEmpty == false {
                                translatedText(translated, color: translatedColor)
                            }
                        }
                        .environment(\.layoutDirection, translatedCaptionLayoutDirection)
                    },
                    original: {
                        captionColumn {
                            if source.isEmpty == false {
                                sourceText(source, color: sourceColor)
                            }
                        }
                        .environment(\.layoutDirection, originalCaptionLayoutDirection)
                    }
                )
            }
            .environment(\.layoutDirection, .leftToRight)
        } else {
            stackedCaptionPair(
                translated: translated,
                translatedColor: translatedColor,
                source: source,
                sourceColor: sourceColor
            )
        }
    }

    @ViewBuilder
    private func captionColumn<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func inLayoutOrder<Translated: View, Original: View>(
        @ViewBuilder translated: () -> Translated,
        @ViewBuilder original: () -> Original
    ) -> some View {
        if captionLayout.leadsWithTranslation {
            translated()
            original()
        } else {
            original()
            translated()
        }
    }

    private func stackedCaptionPair(
        translated: String,
        translatedColor: Color,
        source: String,
        sourceColor: Color
    ) -> some View {
        let usesFallback = usesSourceAsTranslationFallback(
            translated: translated,
            source: source
        )
        let primaryTranslatedText = usesFallback ? source : translated
        let showsTranslatedLine = showsTranslatedSubtitle && primaryTranslatedText.isEmpty == false
        let showsSourceLine = showsOriginalSubtitle && source.isEmpty == false && usesFallback == false

        return VStack(spacing: Self.captionPairSpacing) {
            inLayoutOrder(
                translated: {
                    Group {
                        if showsTranslatedLine {
                            translatedText(
                                primaryTranslatedText,
                                color: translatedColor
                            )
                        }
                    }
                    .environment(
                        \.layoutDirection,
                        usesFallback ? originalCaptionLayoutDirection : translatedCaptionLayoutDirection
                    )
                },
                original: {
                    Group {
                        if showsSourceLine {
                            sourceText(
                                source,
                                color: sourceColor
                            )
                        }
                    }
                    .environment(\.layoutDirection, originalCaptionLayoutDirection)
                }
            )
        }
    }

    private func usesSourceAsTranslationFallback(translated: String, source: String) -> Bool {
        showsTranslatedSubtitle
            && translated.isEmpty
            && source.isEmpty == false
            && (
                showsOriginalSubtitle == false
                    || (usesColumnCaptions == false && captionLayout.leadsWithTranslation)
            )
    }

    private var showsOriginalSubtitle: Bool {
        model.showsOriginalSubtitle
    }

    private var showsTranslatedSubtitle: Bool {
        model.showsTranslatedSubtitle
    }

    private var translatedLineHeight: CGFloat {
        CGFloat(model.overlayStyle.scaledTranslatedFontSize + 10.0)
    }

    private var sourceLineHeight: CGFloat {
        if usesTranslatedTypographyForSourceText {
            return translatedLineHeight
        }

        return CGFloat(model.overlayStyle.scaledSourceFontSize + 14.0)
    }

    private var usesTranslatedTypographyForSourceText: Bool {
        showsOriginalSubtitle && !showsTranslatedSubtitle
    }

    private var displayedSourceFontSize: Double {
        usesTranslatedTypographyForSourceText
            ? model.overlayStyle.scaledTranslatedFontSize
            : model.overlayStyle.scaledSourceFontSize
    }

    private var displayedSourceFontWeight: Font.Weight {
        usesTranslatedTypographyForSourceText ? .semibold : .regular
    }

    private func estimatedCaptionPairHeight(
        showsTranslated: Bool,
        showsSource: Bool
    ) -> CGFloat {
        let translatedHeight = showsTranslated ? translatedLineHeight : 0
        let sourceHeight = showsSource ? sourceLineHeight : 0

        if usesColumnCaptions {
            return max(translatedHeight, sourceHeight)
        }

        let spacingHeight = (showsTranslated && showsSource) ? Self.captionPairSpacing : 0
        return translatedHeight + spacingHeight + sourceHeight
    }

    private var captionLayout: OverlayCaptionLayout {
        model.overlayStyle.captionLayout
    }

    private var translatedCaptionLayoutDirection: LayoutDirection {
        captionLayoutDirection(for: model.outputLanguageID)
    }

    private var draftTranslatedCaptionLayoutDirection: LayoutDirection {
        model.shouldReserveDraftTranslationSlot && showsOriginalSubtitle == false
            ? originalCaptionLayoutDirection
            : translatedCaptionLayoutDirection
    }

    private var originalCaptionLayoutDirection: LayoutDirection {
        captionLayoutDirection(for: model.inputLanguageID)
    }

    private func captionLayoutDirection(for languageID: String) -> LayoutDirection {
        Locale.Language(identifier: languageID).characterDirection == .rightToLeft
            ? .rightToLeft
            : .leftToRight
    }

    private var interfaceLabelLayoutDirection: LayoutDirection {
        captionLayoutDirection(for: model.resolvedInterfaceLanguageID)
    }

    private var usesColumnCaptions: Bool {
        captionLayout.usesColumns
            && showsTranslatedSubtitle
            && showsOriginalSubtitle
    }

    private var captionTextAlignment: TextAlignment {
        usesColumnCaptions ? .leading : .center
    }

    private var captionFrameAlignment: Alignment {
        usesColumnCaptions ? .leading : .center
    }

    private var captionColumnHeaderHeight: CGFloat {
        (reservesColumnHeaderSpace && usesColumnCaptions) ? Self.columnHeaderHeight : 0
    }

    @ViewBuilder
    private var captionColumnDivider: some View {
        if usesColumnCaptions {
            LinearGradient(
                stops: [
                    .init(color: EasyBrand.peach.opacity(0.0), location: 0.0),
                    .init(color: EasyBrand.peach.opacity(0.30), location: 0.16),
                    .init(color: EasyBrand.peach.opacity(0.30), location: 0.94),
                    .init(color: EasyBrand.peach.opacity(0.0), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var captionColumnHeader: some View {
        if usesColumnCaptions {
            HStack(alignment: .firstTextBaseline, spacing: Self.captionColumnSpacing) {
                inLayoutOrder(
                    translated: {
                        captionColumnLabel(
                            role: model.localized(.subtitleShort),
                            language: model.languageName(for: model.outputLanguageID)
                        )
                        .environment(\.layoutDirection, interfaceLabelLayoutDirection)
                    },
                    original: {
                        captionColumnLabel(
                            role: model.localized(.inputShort),
                            language: model.languageName(for: model.inputLanguageID)
                        )
                        .environment(\.layoutDirection, interfaceLabelLayoutDirection)
                    }
                )
            }
            .frame(height: Self.columnHeaderHeight, alignment: .center)
            .environment(\.layoutDirection, .leftToRight)
            .opacity(columnHeaderOpacity)
            .accessibilityHidden(columnHeaderOpacity <= 0.001)
            .animation(.easeInOut(duration: 0.25), value: columnHeaderOpacity)
        }
    }

    private func captionColumnLabel(role: String, language: String) -> some View {
        Text(verbatim: "\(role) · \(language)")
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(EasyBrand.cream.opacity(0.92))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background {
                Capsule()
                    .fill(EasyBrand.plum.opacity(0.94))
                    .overlay {
                        Capsule()
                            .stroke(EasyBrand.peach.opacity(0.32), lineWidth: 0.5)
                    }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var continuousFlowMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.0),
                .init(color: .white.opacity(0.8), location: 0.10),
                .init(color: .white, location: 0.22),
                .init(color: .white, location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func captionText(
        _ attributedText: AttributedString,
        rawText: String,
        fontSize: Double,
        weight: Font.Weight
    ) -> some View {
        ZStack {
            if model.overlayStyle.showsTextOutline, rawText.isEmpty == false {
                outlineText(
                    rawText,
                    fontSize: fontSize,
                    weight: weight
                )
            }

            Text(attributedText)
                .font(.system(size: fontSize, weight: weight))
                .multilineTextAlignment(captionTextAlignment)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: captionFrameAlignment)
        }
    }

    private func attributedCaptionText(
        text: String,
        fillColor: Color
    ) -> AttributedString {
        var attributed = AttributedString(text)
        attributed.foregroundColor = fillColor
        return attributed
    }

    private func draftSourceAttributedText(
        stable: String,
        mutable: String
    ) -> AttributedString {
        var attributed = AttributedString()

        if stable.isEmpty == false {
            var stablePart = AttributedString(stable)
            stablePart.foregroundColor = subtitleColor(opacity: 0.62)
            attributed += stablePart
        }

        if mutable.isEmpty == false {
            var mutablePart = AttributedString(mutable)
            mutablePart.foregroundColor = subtitleColor(opacity: 0.48)
            attributed += mutablePart
        }

        return attributed
    }

    private func outlineText(
        _ text: String,
        fontSize: Double,
        weight: Font.Weight
    ) -> some View {
        ZStack {
            ForEach(Self.textOutlineOffsets.indices, id: \.self) { index in
                let offset = Self.textOutlineOffsets[index]
                Text(text)
                    .font(.system(size: fontSize, weight: weight))
                    .foregroundStyle(baseTextOutlineColor)
                    .multilineTextAlignment(captionTextAlignment)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: captionFrameAlignment)
                    .offset(x: offset.width, y: offset.height)
            }
        }
    }

    private var baseSubtitleColor: Color {
        model.overlayStyle.subtitleColor.color
    }

    private var baseTextOutlineColor: Color {
        model.overlayStyle.textOutlineColor.color
    }

    private func subtitleColor(opacity: Double) -> Color {
        baseSubtitleColor.opacity(opacity)
    }
}

extension CaptionFlowContentView {
    static let captionFlowAnimation = Animation.interactiveSpring(
        response: 0.32,
        dampingFraction: 0.88,
        blendDuration: 0.08
    )
    static let liveStackSpacing: CGFloat = 10.0
    static let draftBottomInset: CGFloat = 3.0
    static let draftHeightJitterTolerance: CGFloat = 6.0
    static let captionPairSpacing: CGFloat = 4.0
    /// Gap between the two 50/50 caption columns, and the height reserved for their
    /// role labels above the flow.
    static let captionColumnSpacing: CGFloat = 24.0
    static let columnHeaderHeight: CGFloat = 24.0
    static let textOutlineOffsets: [CGSize] = [
        CGSize(width: -1, height: 0),
        CGSize(width: 1, height: 0),
        CGSize(width: 0, height: -1),
        CGSize(width: 0, height: 1),
        CGSize(width: -1, height: -1),
        CGSize(width: -1, height: 1),
        CGSize(width: 1, height: -1),
        CGSize(width: 1, height: 1)
    ]
}

struct OverlayFlowAnimationState: Equatable {
    let captionEpoch: Int
    let translatedText: String
    let sourceText: String
    let committedPromotionID: UUID?
    let draftPromotionID: UUID?
    let reservesCommittedSlot: Bool
}

struct OverlayHistoryLayoutAnimationState: Equatable {
    let historyIDs: [UUID]
    let reservesCommittedSlot: Bool
    let draftPromotionID: UUID?
}

struct DraftSlotHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0.0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct LiveLayersHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0.0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct CommittedSlotHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0.0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct HistoryEntryHeightsPreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGFloat] = [:]

    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

enum TranslationHostRole: Equatable {
    case presenterOverlay
    case audienceDisplay

    func shouldHost(isOverlayVisible: Bool, isAudienceVisible: Bool) -> Bool {
        Self.shouldHost(
            role: self,
            isOverlayVisible: isOverlayVisible,
            isAudienceVisible: isAudienceVisible
        )
    }

    static func shouldHost(
        role: TranslationHostRole,
        isOverlayVisible: Bool,
        isAudienceVisible: Bool
    ) -> Bool {
        switch role {
        case .presenterOverlay:
            return isOverlayVisible || !isAudienceVisible
        case .audienceDisplay:
            return !isOverlayVisible && isAudienceVisible
        }
    }
}

struct OverlayTranslationHostModifier: ViewModifier {
    @ObservedObject var model: AppModel
    let role: TranslationHostRole

    func body(content: Content) -> some View {
        if role.shouldHost(
            isOverlayVisible: model.isOverlayVisible,
            isAudienceVisible: model.isAudienceDisplayVisible
        ) {
            content.v2sTranslationHost(model: model)
        } else {
            content
        }
    }
}
