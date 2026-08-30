import AppKit
import SwiftUI

struct CaptionFlowContentView: View {
    @ObservedObject var model: AppModel
    var showsScrollbarPadding: Bool = false
    var updatesModelHistoryVisibleCount: Bool = false
    var reservesColumnHeaderSpace: Bool = true
    var columnHeaderOpacity: Double = 1.0

    @State private var lastLiveLayersHeight: CGFloat = 0.0
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
                        .transaction { transaction in
                            transaction.animation = nil
                            transaction.disablesAnimations = true
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .bottom)
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
                            lastLiveLayersHeight = 0
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
        let presentation = state.liveCaptionPresentation

        return VStack(alignment: .center, spacing: Self.liveStackSpacing) {
            if let precedingCaption = presentation.precedingCommittedCaption {
                precedingCommittedLayer(precedingCaption)
            }

            if let currentCaption = presentation.currentCaption {
                currentCaptionLayer(currentCaption)
            } else if shouldReserveCurrentCaptionSlot(for: state) {
                currentCaptionSlotPlaceholder
            }
        }
    }

    private func currentCaptionLayer(
        _ caption: OverlayLiveCaptionPresentation.Caption
    ) -> some View {
        let isTentative = caption.phase == .tentative
        let layer = captionPair(
            translated: caption.translatedText,
            translatedColor: isTentative ? tentativeSubtitleColor : baseSubtitleColor,
            source: caption.sourceText,
            sourceColor: isTentative ? tentativeSubtitleColor : subtitleColor(opacity: 0.82),
            reservesEmptyLines: true
        )
        .padding(.bottom, Self.currentCaptionBottomInset)

#if DEBUG
        return layer.background(currentCaptionFrameReader)
#else
        return layer
#endif
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

    private func precedingCommittedLayer(
        _ caption: OverlayLiveCaptionPresentation.Caption
    ) -> some View {
        captionPair(
            translated: caption.translatedText,
            translatedColor: subtitleColor(opacity: 0.68),
            source: caption.sourceText,
            sourceColor: subtitleColor(opacity: 0.46)
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

    private func shouldReserveCurrentCaptionSlot(for state: OverlayPreviewState) -> Bool {
        state.liveCaptionPresentation.currentCaption != nil
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
        return estimatedCaptionPairHeight(
            showsTranslated: showsTranslatedSubtitle && translatedText.isEmpty == false,
            showsSource: showsOriginalSubtitle && entry.sourceText.isEmpty == false && usesFallback == false
        )
    }

    private func estimatedLiveLayersHeight(for state: OverlayPreviewState) -> CGFloat {
        let presentation = state.liveCaptionPresentation
        let captionHeight = estimatedCaptionPairHeight(
            showsTranslated: showsTranslatedSubtitle,
            showsSource: showsOriginalSubtitle
        )
        var height: CGFloat = 0

        if presentation.precedingCommittedCaption != nil {
            height += captionHeight + Self.liveStackSpacing
        }

        if shouldReserveCurrentCaptionSlot(for: state) {
            height += captionHeight + Self.currentCaptionBottomInset
        }

        return height
    }

    private var currentCaptionSlotPlaceholder: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(
                height: estimatedCaptionPairHeight(
                    showsTranslated: showsTranslatedSubtitle,
                    showsSource: showsOriginalSubtitle
                ) + Self.currentCaptionBottomInset
            )
            .accessibilityHidden(true)
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
        translated: String,
        translatedColor: Color,
        source: String,
        sourceColor: Color,
        reservesEmptyLines: Bool = false
    ) -> some View {
        if usesColumnCaptions {
            HStack(alignment: .top, spacing: Self.captionColumnSpacing) {
                inLayoutOrder(
                    translated: {
                        captionColumn {
                            if translated.isEmpty == false {
                                translatedText(translated, color: translatedColor)
                            } else if reservesEmptyLines {
                                translatedText(" ", color: translatedColor)
                                    .hidden()
                                    .accessibilityHidden(true)
                            }
                        }
                        .environment(\.layoutDirection, translatedCaptionLayoutDirection)
                    },
                    original: {
                        captionColumn {
                            if source.isEmpty == false {
                                sourceText(source, color: sourceColor)
                            } else if reservesEmptyLines {
                                sourceText(" ", color: sourceColor)
                                    .hidden()
                                    .accessibilityHidden(true)
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
                sourceColor: sourceColor,
                reservesEmptyLines: reservesEmptyLines
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
        sourceColor: Color,
        reservesEmptyLines: Bool
    ) -> some View {
        let usesFallback = usesSourceAsTranslationFallback(
            translated: translated,
            source: source
        ) && (reservesEmptyLines == false || showsOriginalSubtitle == false)
        let primaryTranslatedText = usesFallback ? source : translated
        let showsTranslatedLine = showsTranslatedSubtitle
            && (primaryTranslatedText.isEmpty == false || reservesEmptyLines)
        let showsSourceLine = showsOriginalSubtitle
            && usesFallback == false
            && (source.isEmpty == false || reservesEmptyLines)

        return VStack(spacing: Self.captionPairSpacing) {
            inLayoutOrder(
                translated: {
                    Group {
                        if primaryTranslatedText.isEmpty == false {
                            translatedText(
                                primaryTranslatedText,
                                color: translatedColor
                            )
                        } else if showsTranslatedLine {
                            translatedText(" ", color: translatedColor)
                                .hidden()
                                .accessibilityHidden(true)
                        }
                    }
                    .environment(
                        \.layoutDirection,
                        usesFallback ? originalCaptionLayoutDirection : translatedCaptionLayoutDirection
                    )
                },
                original: {
                    Group {
                        if source.isEmpty == false && usesFallback == false {
                            sourceText(
                                source,
                                color: sourceColor
                            )
                        } else if showsSourceLine {
                            sourceText(" ", color: sourceColor)
                                .hidden()
                                .accessibilityHidden(true)
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

    private var tentativeSubtitleColor: Color {
        Color(nsColor: .secondaryLabelColor)
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
