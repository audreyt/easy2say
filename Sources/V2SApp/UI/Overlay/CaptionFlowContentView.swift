import AppKit
import SwiftUI

struct CaptionFlowContentView: View {
    enum LiveCaptionProjection {
        case overlayLaneDeduplication
        case audienceUtterancePairs
    }

    @ObservedObject var model: AppModel
    var liveCaptionPresentationOverride: OverlayLiveCaptionPresentation? = nil
    var liveCaptionProjection: LiveCaptionProjection = .overlayLaneDeduplication
    var showsScrollbarPadding: Bool = false
    var updatesModelHistoryVisibleCount: Bool = false
    var reservesColumnHeaderSpace: Bool = true
    var columnHeaderOpacity: Double = 1.0
    var showsHistory: Bool = true
    var alignsTopDownCaptionsLeading: Bool = false
    var animatesLiveCaptionLineEntrance: Bool = true
    var stabilizesLiveCaptionLinePositions: Bool = false

    @State private var lastLiveLayersHeight: CGFloat = 0.0
    @State private var measuredHistoryEntryHeights: [UUID: CGFloat] = [:]

    @State private var liveVisibleLaneTexts: Set<String> = []
    @State private var liveVisibleHistoryEntryIDs: Set<UUID> = []

    var body: some View {
        Group {
            if let state = model.overlayState {
                GeometryReader { proxy in
                    let captionAreaHeight = proxy.size.height - captionColumnHeaderHeight
                    let availableHistoryHeight = availableHistoryHeight(for: captionAreaHeight, state: state)
                    let visibleLiveHistoryEntryIDs = liveVisibleHistoryEntryIDs.isEmpty
                        ? initialVisibleHistoryEntryIDs(for: state)
                        : liveVisibleHistoryEntryIDs
                    let visibleHistoryEntries = showsHistory
                        ? historyVisibleEntries(
                            from: state.history,
                            availableHeight: availableHistoryHeight,
                            liveHistoryEntryIDs: visibleLiveHistoryEntryIDs
                        )
                        : []
                    let visibleHistoryCount = visibleHistoryEntries.count
                    ZStack(alignment: liveFlowAlignment) {
                        if shouldReserveCurrentCaptionSlot(for: state) {
                            currentCaptionSlotPlaceholder
                        }

                        VStack(alignment: liveStackHorizontalAlignment, spacing: Self.liveStackSpacing) {
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
                        .transaction { transaction in
                            transaction.animation = nil
                            transaction.disablesAnimations = true
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: liveFlowAlignment)
                    }
                    .padding(.top, captionColumnHeaderHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .mask(continuousFlowMask)
                    .background(alignment: .center) { captionColumnDivider }
                    .overlay(alignment: .top) { captionColumnHeader }
                    .onPreferenceChange(LiveLayersHeightPreferenceKey.self) { height in
                        guard height > 0 else { return }
                        lastLiveLayersHeight = ceil(height)
                    }
                    .onPreferenceChange(HistoryEntryHeightsPreferenceKey.self) { heights in
                        guard heights.isEmpty == false else { return }
                        for (id, height) in heights where height > 0 {
                            measuredHistoryEntryHeights[id] = ceil(height)
                        }
                    }
                    .onPreferenceChange(LiveCaptionVisibleTextsPreferenceKey.self) { texts in
                        liveVisibleLaneTexts = texts
                        recordRenderedCaptionState(
                            liveTexts: texts,
                            liveHistoryEntryIDs: liveVisibleHistoryEntryIDs,
                            historyEntryIDs: visibleHistoryEntries.map(\.id)
                        )
                    }
                    .onPreferenceChange(LiveCaptionVisibleHistoryEntryIDsPreferenceKey.self) { ids in
                        liveVisibleHistoryEntryIDs = ids
                        recordRenderedCaptionState(
                            liveTexts: liveVisibleLaneTexts,
                            liveHistoryEntryIDs: ids,
                            historyEntryIDs: visibleHistoryEntries.map(\.id)
                        )
                    }
                    .onAppear {
                        if updatesModelHistoryVisibleCount {
                            model.updateOverlayHistoryVisibleCount(visibleHistoryCount)
                        }
                        recordRenderedCaptionState(
                            liveTexts: liveVisibleLaneTexts,
                            liveHistoryEntryIDs: liveVisibleHistoryEntryIDs,
                            historyEntryIDs: visibleHistoryEntries.map(\.id)
                        )
                    }
                    .onChange(of: visibleHistoryCount) { _, newCount in
                        if updatesModelHistoryVisibleCount {
                            model.updateOverlayHistoryVisibleCount(newCount)
                        }
                    }
                    .onChange(of: visibleHistoryEntries.map(\.id)) { _, ids in
                        recordRenderedCaptionState(
                            liveTexts: liveVisibleLaneTexts,
                            liveHistoryEntryIDs: liveVisibleHistoryEntryIDs,
                            historyEntryIDs: ids
                        )
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
                            lastLiveLayersHeight = 0
                            measuredHistoryEntryHeights = [:]
                            liveVisibleLaneTexts = []
                            liveVisibleHistoryEntryIDs = []
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

    private func recordRenderedCaptionState(
        liveTexts: Set<String>,
        liveHistoryEntryIDs: Set<UUID>,
        historyEntryIDs: [UUID]
    ) {
#if DEBUG
        model.recordRenderedCaptionStateForTesting(
            liveTexts: liveTexts,
            liveHistoryEntryIDs: liveHistoryEntryIDs,
            historyEntryIDs: historyEntryIDs
        )
#endif
    }

    private var liveFlowAlignment: Alignment {
        if stabilizesLiveCaptionLinePositions {
            return usesLeadingCaptionAlignment ? .topLeading : .top
        }
        return usesLeadingCaptionAlignment ? .bottomLeading : .bottom
    }

    // MARK: - Continuous flow
    private func liveCaptionPresentation(
        for state: OverlayPreviewState
    ) -> OverlayLiveCaptionPresentation {
        liveCaptionPresentationOverride ?? state.liveCaptionPresentation
    }

    private func liveDisplayCaption(
        for state: OverlayPreviewState
    ) -> OverlayLiveCaptionPresentation.Caption? {
        let presentation = liveCaptionPresentation(for: state)
        switch liveCaptionProjection {
        case .overlayLaneDeduplication:
            return presentation.displayCaption
        case .audienceUtterancePairs:
            return presentation.audienceDisplayCaption
        }
    }


    private func liveLayers(_ state: OverlayPreviewState) -> some View {

        return Group {
            if let displayCaption = liveDisplayCaption(for: state) {
                if stabilizesLiveCaptionLinePositions {
                    currentCaptionLayer(displayCaption)
                        .frame(height: currentCaptionSlotHeight, alignment: .top)
                } else {
                    currentCaptionLayer(displayCaption)
                }
            } else if shouldReserveCurrentCaptionSlot(for: state) {
                currentCaptionSlotPlaceholder
            }
        }
    }

    private func currentCaptionLayer(
        _ caption: OverlayLiveCaptionPresentation.Caption
    ) -> some View {
        let layer = captionPair(
            translated: CaptionLaneContent(
                text: caption.translatedText,
                color: baseSubtitleColor,
                agedPrefixLength: caption.translatedAgedPrefixLength,
                stablePrefixLength: caption.translatedStablePrefixLength,
                representedHistoryEntryIDs: caption.representedHistoryEntryIDs
            ),
            source: CaptionLaneContent(
                text: caption.sourceText,
                color: baseSubtitleColor,
                agedPrefixLength: caption.sourceAgedPrefixLength,
                stablePrefixLength: caption.sourceStablePrefixLength,
                representedHistoryEntryIDs: caption.representedHistoryEntryIDs
            ),
            reservesEmptyLines: true,
            maximumVisibleLines: Self.liveCaptionLineLimit,
            risesNewLines: animatesLiveCaptionLineEntrance
        )
        .padding(.bottom, Self.currentCaptionBottomInset)

        return layer
    }

#if DEBUG
    private var currentCaptionFrameReader: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            Color.clear
                .onAppear {
                    model.recordLiveCaptionFrameForTesting(frame)
                }
                .onChange(of: frame) { _, newFrame in
                    model.recordLiveCaptionFrameForTesting(newFrame)
                }
        }
    }
#endif

    private func translatedText(
        _ lane: CaptionLaneContent,
        maximumVisibleLines: Int? = nil,
        risesNewLines: Bool = false
    ) -> CaptionLaneText {
        captionLaneText(
            lane,
            fontSize: model.overlayStyle.scaledTranslatedFontSize,
            weight: .semibold,
            lineHeight: translatedLineHeight,
            maximumVisibleLines: maximumVisibleLines,
            risesNewLines: risesNewLines
        )
    }

    private func sourceText(
        _ lane: CaptionLaneContent,
        maximumVisibleLines: Int? = nil,
        risesNewLines: Bool = false
    ) -> CaptionLaneText {
        captionLaneText(
            lane,
            fontSize: displayedSourceFontSize,
            weight: displayedSourceFontWeight,
            lineHeight: sourceLineHeight,
            maximumVisibleLines: maximumVisibleLines,
            risesNewLines: risesNewLines
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
            translated: CaptionLaneContent(
                text: entry.translatedText,
                color: subtitleColor(opacity: translatedOpacity)
            ),
            source: CaptionLaneContent(
                text: entry.sourceText,
                color: subtitleColor(opacity: sourceOpacity)
            )
        )
        .background(historyEntryHeightReader(for: entry.id))
    }

    private func historyVisibleEntries(
        from history: [OverlayHistoryEntry],
        availableHeight: CGFloat,
        liveHistoryEntryIDs: Set<UUID>
    ) -> [OverlayHistoryEntry] {
        guard availableHeight > 0 else { return [] }
        let offset = min(max(model.overlayHistoryScrollOffset, 0), max(0, history.count - 1))
        let upperBound = max(0, history.count - offset)
        guard upperBound > 0 else { return [] }

        var newestFirst: [OverlayHistoryEntry] = []
        var consumedHeight: CGFloat = 0
        var index = upperBound - 1

        while index >= 0 {
            defer { index -= 1 }
            let entry = history[index]
            guard liveHistoryEntryIDs.contains(entry.id) == false else { continue }

            let nextHeight = historyEntryHeight(for: entry) + Self.liveStackSpacing
            if newestFirst.isEmpty || consumedHeight + nextHeight <= availableHeight {
                newestFirst.append(entry)
                consumedHeight += nextHeight
            } else {
                break
            }
        }

        return Array(newestFirst.reversed())
    }

    private func initialVisibleHistoryEntryIDs(
        for state: OverlayPreviewState
    ) -> Set<UUID> {
        liveDisplayCaption(for: state)?.representedHistoryEntryIDs ?? []
    }

    private func availableHistoryHeight(for height: CGFloat, state: OverlayPreviewState) -> CGFloat {
        max(height - reservedFlowHeight(for: state), 0)
    }

    private func reservedFlowHeight(for state: OverlayPreviewState) -> CGFloat {
        max(lastLiveLayersHeight, estimatedLiveLayersHeight(for: state))
    }

    private func shouldReserveCurrentCaptionSlot(for state: OverlayPreviewState) -> Bool {
        liveDisplayCaption(for: state) != nil
            || model.shouldReserveCommittedCaptionSlot
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
        let suppression = duplicateLaneSuppression(
            translated: translatedText,
            source: entry.sourceText
        )
        return estimatedCaptionPairHeight(
            showsTranslated: showsTranslatedSubtitle
                && translatedText.isEmpty == false
                && suppression.translated == false,
            showsSource: showsOriginalSubtitle
                && entry.sourceText.isEmpty == false
                && usesFallback == false
                && suppression.source == false
        )
    }

    private func estimatedLiveLayersHeight(for state: OverlayPreviewState) -> CGFloat {
        guard shouldReserveCurrentCaptionSlot(for: state) else { return 0 }
        return currentCaptionSlotHeight
    }

    private var currentCaptionSlotHeight: CGFloat {
        estimatedCaptionPairHeight(
            showsTranslated: showsTranslatedSubtitle,
            showsSource: showsOriginalSubtitle,
            linesPerLane: Self.liveCaptionLineLimit
        ) + Self.currentCaptionBottomInset
    }

    private var currentCaptionSlotPlaceholder: some View {
        let placeholder = Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: currentCaptionSlotHeight)
            .accessibilityHidden(true)

#if DEBUG
        return placeholder.background(currentCaptionFrameReader)
#else
        return placeholder
#endif
    }

    private var liveLayersHeightReader: some View {
        GeometryReader { proxy in
            Color.clear
                .preference(key: LiveLayersHeightPreferenceKey.self, value: proxy.size.height)
        }
    }

    private func historyEntryHeightReader(for id: UUID) -> some View {
        GeometryReader { proxy in
            Color.clear
                .preference(key: HistoryEntryHeightsPreferenceKey.self, value: [id: proxy.size.height])
        }
    }

    @ViewBuilder
    private func captionPair(
        translated: CaptionLaneContent,
        source: CaptionLaneContent,
        reservesEmptyLines: Bool = false,
        maximumVisibleLines: Int? = nil,
        risesNewLines: Bool = false
    ) -> some View {
        let suppression = duplicateLaneSuppression(
            translated: translated.text,
            source: source.text
        )
        if usesColumnCaptions {
            HStack(alignment: .top, spacing: Self.captionColumnSpacing) {
                inLayoutOrder(
                    translated: {
                        captionColumn {
                            if suppression.translated == false,
                               translated.text.isEmpty == false || reservesEmptyLines {
                                translatedText(
                                    translated,
                                    maximumVisibleLines: maximumVisibleLines,
                                    risesNewLines: risesNewLines
                                )
                            }
                        }
                        .environment(\.layoutDirection, translatedCaptionLayoutDirection)
                    },
                    original: {
                        captionColumn {
                            if suppression.source == false,
                               source.text.isEmpty == false || reservesEmptyLines {
                                sourceText(
                                    source,
                                    maximumVisibleLines: maximumVisibleLines,
                                    risesNewLines: risesNewLines
                                )
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
                source: source,
                reservesEmptyLines: reservesEmptyLines,
                maximumVisibleLines: maximumVisibleLines,
                risesNewLines: risesNewLines
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
        translated: CaptionLaneContent,
        source: CaptionLaneContent,
        reservesEmptyLines: Bool,
        maximumVisibleLines: Int?,
        risesNewLines: Bool
    ) -> some View {
        let usesFallback = usesSourceAsTranslationFallback(
            translated: translated.text,
            source: source.text
        ) && (reservesEmptyLines == false || showsOriginalSubtitle == false)
        // The fallback lane borrows the original's text and run boundaries but
        // keeps the translation lane's colour, so history ageing still applies.
        let primaryTranslated = usesFallback ? source.recolored(translated.color) : translated
        let suppression = duplicateLaneSuppression(
            translated: primaryTranslated.text,
            source: source.text
        )
        let showsTranslatedLine = showsTranslatedSubtitle
            && (primaryTranslated.text.isEmpty == false || reservesEmptyLines)
        let showsSourceLine = showsOriginalSubtitle
            && usesFallback == false
            && (source.text.isEmpty == false || reservesEmptyLines)

        return VStack(alignment: liveStackHorizontalAlignment, spacing: Self.captionPairSpacing) {
            inLayoutOrder(
                translated: {
                    Group {
                        if suppression.translated == false,
                           primaryTranslated.text.isEmpty == false || showsTranslatedLine {
                            translatedText(
                                primaryTranslated,
                                maximumVisibleLines: maximumVisibleLines,
                                risesNewLines: risesNewLines
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
                        if suppression.source == false,
                           (source.text.isEmpty == false && usesFallback == false) || showsSourceLine {
                            sourceText(
                                source,
                                maximumVisibleLines: maximumVisibleLines,
                                risesNewLines: risesNewLines
                            )
                        }
                    }
                    .environment(\.layoutDirection, originalCaptionLayoutDirection)
                }
            )
        }
    }

    private func duplicateLaneSuppression(
        translated: String,
        source: String
    ) -> (translated: Bool, source: Bool) {
        guard case .overlayLaneDeduplication = liveCaptionProjection else {
            return (false, false)
        }
        guard showsTranslatedSubtitle,
              showsOriginalSubtitle,
              CaptionTextVisibility.areEquivalent(translated, source) else {
            return (false, false)
        }
        return captionLayout.leadsWithTranslation ? (false, true) : (true, false)
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
        captionLineHeight(
            fontSize: model.overlayStyle.scaledTranslatedFontSize,
            weight: .semibold
        )
    }

    private var sourceLineHeight: CGFloat {
        captionLineHeight(
            fontSize: displayedSourceFontSize,
            weight: usesTranslatedTypographyForSourceText ? .semibold : .regular
        )
    }

    private func captionLineHeight(fontSize: Double, weight: NSFont.Weight) -> CGFloat {
        let font = NSFont.systemFont(ofSize: CGFloat(fontSize), weight: weight)
        return ceil(font.ascender - font.descender + font.leading)
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
        showsSource: Bool,
        linesPerLane: Int = 1
    ) -> CGFloat {
        let lineCount = CGFloat(max(1, linesPerLane))
        let translatedHeight = showsTranslated ? translatedLineHeight * lineCount : 0
        let sourceHeight = showsSource ? sourceLineHeight * lineCount : 0

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

    private var usesLeadingCaptionAlignment: Bool {
        usesColumnCaptions
            || (alignsTopDownCaptionsLeading && captionLayout == .topDown)
    }

    private var captionTextAlignment: TextAlignment {
        usesLeadingCaptionAlignment ? .leading : .center
    }

    private var captionFrameAlignment: Alignment {
        usesLeadingCaptionAlignment ? .leading : .center
    }

    private var liveStackHorizontalAlignment: HorizontalAlignment {
        usesLeadingCaptionAlignment ? .leading : .center
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

    private func captionLaneText(
        _ lane: CaptionLaneContent,
        fontSize: Double,
        weight: Font.Weight,
        lineHeight: CGFloat,
        maximumVisibleLines: Int?,
        risesNewLines: Bool
    ) -> CaptionLaneText {
        CaptionLaneText(
            text: lane.text,
            attributedText: lane.runs.attributedString(baseColor: lane.color),
            representedHistoryEntryIDs: lane.representedHistoryEntryIDs,
            fontSize: fontSize,
            weight: weight,
            lineHeight: lineHeight,
            maximumVisibleLines: maximumVisibleLines,
            textAlignment: captionTextAlignment,
            frameAlignment: captionFrameAlignment,
            outlineColor: model.overlayStyle.showsTextOutline ? baseTextOutlineColor : nil,
            risesNewLines: risesNewLines,
            stabilizesLinePositions: stabilizesLiveCaptionLinePositions
        )
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
    static let liveCaptionLineLimit = 2
    static let liveStackSpacing: CGFloat = 10.0
    static let currentCaptionBottomInset: CGFloat = 3.0
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

/// One caption lane as the flow renders it: the text, the base colour it draws
/// in, and the boundaries that split it into aged, stable, and mutable runs.
struct CaptionLaneContent: Equatable {
    let text: String
    let color: Color
    let agedPrefixLength: Int
    /// `nil` means the lane is settled text with no revisable tail — history.
    let stablePrefixLength: Int?
    let representedHistoryEntryIDs: Set<UUID>

    init(
        text: String,
        color: Color,
        agedPrefixLength: Int = 0,
        stablePrefixLength: Int? = nil,
        representedHistoryEntryIDs: Set<UUID> = []
    ) {
        self.text = text
        self.color = color
        self.agedPrefixLength = agedPrefixLength
        self.stablePrefixLength = stablePrefixLength
        self.representedHistoryEntryIDs = representedHistoryEntryIDs
    }

    var runs: OverlayCaptionRuns {
        OverlayCaptionRuns(
            text: text,
            agedPrefixLength: agedPrefixLength,
            stablePrefixLength: stablePrefixLength ?? text.count
        )
    }

    func recolored(_ color: Color) -> CaptionLaneContent {
        CaptionLaneContent(
            text: text,
            color: color,
            agedPrefixLength: agedPrefixLength,
            stablePrefixLength: stablePrefixLength,
            representedHistoryEntryIDs: representedHistoryEntryIDs
        )
    }
}

/// A settled native text layout: the exact string that produced it, the number
/// of visual lines SwiftUI wrapped it into, and the width it was measured at.
struct CaptionLineRiseLayoutSnapshot: Equatable {
    let text: String
    let lineCount: Int
    let width: CGFloat

    init(text: String, lineCount: Int, width: CGFloat) {
        self.text = text
        self.lineCount = lineCount
        self.width = width
    }

    /// The settled layout of a lane that has no caption text yet.
    static func empty(width: CGFloat) -> CaptionLineRiseLayoutSnapshot {
        CaptionLineRiseLayoutSnapshot(text: "", lineCount: 0, width: width)
    }
}

/// Which visual lines of the current layout are newly added and should rise.
struct CaptionLineRisePlan: Equatable {
    let enteringLineIndices: Set<Int>

    /// Nothing rises: every visual line draws fully settled.
    static let settled = CaptionLineRisePlan(enteringLineIndices: [])

    var isEmpty: Bool {
        enteringLineIndices.isEmpty
    }
}

/// The live-caption line rise: only text the analyzer *added* moves, and only
/// the visual lines that addition created.
enum CaptionLineRise {
    static let duration: Double = 0.24
    /// Rise distance as a fraction of the lane width, so the motion keeps its
    /// proportion when the overlay is resized or the display changes.
    static let translationRatio: CGFloat = 0.007
    static let curve = UnitCurve.bezier(
        startControlPoint: UnitPoint(x: 0.16, y: 1.0),
        endControlPoint: UnitPoint(x: 0.3, y: 1.0)
    )

    static func translation(forWidth width: CGFloat) -> CGFloat {
        width * translationRatio
    }

    /// Pure: decides which visual lines are entering by comparing two settled
    /// layouts. Deliberately conservative — anything that is not a strict text
    /// prefix addition producing extra visual lines draws fully settled, so
    /// mutable-tail rewrites, stable-boundary moves, final promotion, removal,
    /// and width reflow never animate.
    static func plan(
        previous: CaptionLineRiseLayoutSnapshot?,
        candidate: CaptionLineRiseLayoutSnapshot
    ) -> CaptionLineRisePlan {
        guard let previous else { return .settled }
        guard previous.width == candidate.width else { return .settled }
        guard previous.text != candidate.text else { return .settled }
        guard candidate.text.hasPrefix(previous.text) else { return .settled }
        guard candidate.lineCount > previous.lineCount else { return .settled }

        return CaptionLineRisePlan(
            enteringLineIndices: Set(previous.lineCount..<candidate.lineCount)
        )
    }
}

/// Lifts the entering visual lines into place. Every other line draws exactly
/// as SwiftUI laid it out, so a revision inside an existing line — or the whole
/// lane reflowing — never re-animates settled text.
struct CaptionLineRiseRenderer: TextRenderer {
    var progress: Double
    var enteringLineIndices: Set<Int>
    var translation: CGFloat

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        let settledProgress = min(max(progress, 0.0), 1.0)

        for (index, line) in layout.enumerated() {
            guard enteringLineIndices.contains(index) else {
                ctx.draw(line)
                continue
            }

            var lineContext = ctx
            lineContext.opacity = settledProgress
            lineContext.translateBy(x: 0, y: translation * (1.0 - settledProgress))
            lineContext.draw(line)
        }
    }
}

/// One rendered caption lane, outline and foreground drawn by a single text
/// renderer so they stay pixel-synchronised. A hidden probe lays incoming text
/// out at the visible lane's own width and publishes it through `Text.LayoutKey`
/// outside the draw phase. The lane then swaps the measured caption into its one
/// visible slot together with its presentation decision. Animated lanes can rise
/// from their first painted frame; stabilized lanes keep the first visible
/// baseline fixed while a second line fills, then clip from the top only when
/// the oldest line rolls out.
struct CaptionLaneText: View {
    let text: String
    let attributedText: AttributedString
    let representedHistoryEntryIDs: Set<UUID>
    let fontSize: Double
    let weight: Font.Weight
    let lineHeight: CGFloat
    let maximumVisibleLines: Int?
    let textAlignment: TextAlignment
    let frameAlignment: Alignment
    let outlineColor: Color?
    let risesNewLines: Bool
    let stabilizesLinePositions: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var visible: VisibleCaption?
    @State private var measured: MeasuredCandidate?
    @State private var enteringLineIndices: Set<Int> = []
    @State private var riseGeneration: Int = 0

    /// What the lane is drawing right now, paired with the settled layout it was
    /// measured at. One value, so text and identity can only commit together.
    private struct VisibleCaption: Equatable {
        let attributedText: AttributedString
        let layout: CaptionLineRiseLayoutSnapshot
        let representedHistoryEntryIDs: Set<UUID>
    }

    /// One hidden measurement: which string was laid out, into how many visual
    /// lines, and at what width. All three come from the same layout pass, so a
    /// plan can never pair a new width's line count with the old width.
    private struct MeasuredCandidate: Equatable {
        let text: String
        let lineCount: Int
        let width: CGFloat
    }

    var body: some View {
        if risesNewLines || stabilizesLinePositions {
            clipped(preflightedLane)
                .background(alignment: .top) { candidateProbe }
                // A boundary move — final promotion, or a new aged prefix —
                // changes the runs without changing the string, so the probe's
                // layout does not change and cannot report it.
                .onChange(of: attributedText) { _, _ in
                    reconcile()
                }
                .onChange(of: representedHistoryEntryIDs) { _, _ in
                    reconcile()
                }
        } else {
            // History never revises, rises, or needs a stable two-line viewport.
            clipped(
                laneLayers(text: text, attributedText: attributedText)
            )
        }
    }

    @ViewBuilder
    private func clipped<Content: View>(_ content: Content) -> some View {
        if maximumVisibleLines != nil {
            content
                .frame(
                    height: lineHeight * CGFloat(visibleLineCount),
                    alignment: stabilizesLinePositions ? .top : .bottom
                )
                .clipped()
        } else {
            content
        }
    }

    private var visibleLineCount: Int {
        guard let maximumVisibleLines else { return 1 }
        return min(max(1, visible?.layout.lineCount ?? 1), max(1, maximumVisibleLines))
    }

    @ViewBuilder
    private var preflightedLane: some View {
        if risesNewLines {
            risingLane
        } else {
            visibleLane
        }
    }

    private var visibleLane: some View {
        laneLayers(
            text: visible?.layout.text ?? "",
            attributedText: visible?.attributedText ?? AttributedString()
        )
        .offset(y: stabilizedLineOffset)
        .preference(
            key: LiveCaptionVisibleTextsPreferenceKey.self,
            value: Set([visible?.layout.text].compactMap { text in
                guard let text, text.isEmpty == false else { return nil }
                return text
            })
        )
        .preference(
            key: LiveCaptionVisibleHistoryEntryIDsPreferenceKey.self,
            value: visible?.representedHistoryEntryIDs ?? []
        )
    }

    private var stabilizedLineOffset: CGFloat {
        guard stabilizesLinePositions,
              let maximumVisibleLines,
              let lineCount = visible?.layout.lineCount,
              lineCount > maximumVisibleLines else {
            return 0
        }
        return -lineHeight * CGFloat(lineCount - maximumVisibleLines)
    }

    private var risingLane: some View {
        let entering = enteringLineIndices
        // The rise distance belongs to the width the entering lines were
        // measured at, not to whatever the container may have become since.
        let translation = CaptionLineRise.translation(forWidth: visible?.layout.width ?? 0)

        return visibleLane
        .keyframeAnimator(
            initialValue: 1.0,
            trigger: riseGeneration,
            content: { lane, progress in
                lane.textRenderer(
                    CaptionLineRiseRenderer(
                        progress: progress,
                        enteringLineIndices: entering,
                        translation: translation
                    )
                )
            },
            keyframes: { _ in
                // The content swap and this track start in the same commit, so
                // the entering lines' first drawn frame is progress 0.
                MoveKeyframe(0.0)
                LinearKeyframe(
                    1.0,
                    duration: CaptionLineRise.duration,
                    timingCurve: CaptionLineRise.curve
                )
            }
        )
        // The flow disables animation wholesale; the renderer's own progress is
        // the single exception, and nothing else in the lane animates.
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = false
        }
    }

    /// Lays the incoming caption out at the visible lane's width without ever
    /// showing it. The geometry proxy and the published layout come from the
    /// same pass of this subtree, so the measurement is internally consistent;
    /// the layout preference is read inside the subtree, so it reports the
    /// candidate only — never the text already on screen.
    private var candidateProbe: some View {
        GeometryReader { proxy in
            captionText(Text(text.isEmpty ? " " : text))
                .onPreferenceChange(Text.LayoutKey.self) { layouts in
                    // The probe publishes one layout; `max` is the honest
                    // reduction over whatever the subtree reported.
                    let lineCount = layouts.map(\.layout.count).max() ?? 0
                    measured = MeasuredCandidate(
                        text: text,
                        lineCount: lineCount,
                        width: proxy.size.width
                    )
                    reconcile()
                }
        }
        .opacity(0)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func laneLayers(text: String, attributedText: AttributedString) -> some View {
        ZStack {
            if let outlineColor, text.isEmpty == false {
                outlineLayer(text: text, color: outlineColor)
            }

            captionText(Text(text.isEmpty ? AttributedString(" ") : attributedText))
        }
        // An empty lane still reserves its line box; it just has nothing to show.
        .opacity(text.isEmpty ? 0 : 1)
        .accessibilityHidden(text.isEmpty)
    }

    private func outlineLayer(text: String, color: Color) -> some View {
        ZStack {
            ForEach(CaptionFlowContentView.textOutlineOffsets.indices, id: \.self) { index in
                let offset = CaptionFlowContentView.textOutlineOffsets[index]
                captionText(Text(text).foregroundStyle(color))
                    .offset(x: offset.width, y: offset.height)
            }
        }
    }

    private func captionText(_ text: Text) -> some View {
        text
            .font(.system(size: fontSize, weight: weight))
            .multilineTextAlignment(textAlignment)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: frameAlignment)
    }

    /// Promotes the measured candidate into the visible slot, atomically with the
    /// rise decision it implies. Refuses to act on anything it has not measured,
    /// so a caption is never drawn before its plan is known.
    private func reconcile() {
        // Only a measurement of the text about to be shown can decide anything.
        guard let measured, measured.width > 0, measured.text == text else { return }

        let candidate: CaptionLineRiseLayoutSnapshot
        if text.isEmpty {
            candidate = .empty(width: measured.width)
        } else {
            guard measured.lineCount > 0 else { return }
            candidate = CaptionLineRiseLayoutSnapshot(
                text: text,
                lineCount: measured.lineCount,
                width: measured.width
            )
        }

        let incoming = VisibleCaption(
            attributedText: attributedText,
            layout: candidate,
            representedHistoryEntryIDs: representedHistoryEntryIDs
        )
        guard incoming != visible else { return }

        // A lane's first caption is measured against an empty lane at the same
        // width, so its opening line rises like any other newly added line.
        let previous = visible?.layout ?? .empty(width: measured.width)
        let plan: CaptionLineRisePlan = risesNewLines && reduceMotion == false
            ? CaptionLineRise.plan(previous: previous, candidate: candidate)
            : .settled

        enteringLineIndices = plan.enteringLineIndices
        visible = incoming
        if plan.isEmpty == false {
            riseGeneration &+= 1
        }
    }
}

enum CaptionTextVisibility {
    static func normalized(_ text: String) -> String? {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    static func areEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        guard let lhs = normalized(lhs), let rhs = normalized(rhs) else {
            return false
        }
        return lhs == rhs
    }
}

struct LiveLayersHeightPreferenceKey: PreferenceKey {
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

struct LiveCaptionVisibleTextsPreferenceKey: PreferenceKey {
    static var defaultValue: Set<String> = []

    static func reduce(value: inout Set<String>, nextValue: () -> Set<String>) {
        value.formUnion(nextValue())
    }
}

struct LiveCaptionVisibleHistoryEntryIDsPreferenceKey: PreferenceKey {
    static var defaultValue: Set<UUID> = []

    static func reduce(value: inout Set<UUID>, nextValue: () -> Set<UUID>) {
        value.formUnion(nextValue())
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
