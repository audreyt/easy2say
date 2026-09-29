import CoreText
import SwiftUI

/// Which surface a caption view serves. The presenter overlay scrolls old
/// rows up off the bottom-anchored pane; the audience display fills from the
/// top and shows large type.
enum CaptionSurfaceRole {
    case overlay
    case audience
}

/// Owns the `CaptionViewport` for one surface. Views push document/config
/// updates in; the emitted `CaptionScreen` is what the view draws verbatim.
@MainActor
final class CaptionSurfaceController: ObservableObject {
    @Published private(set) var screen = CaptionScreen(lines: [], badges: [], contentTop: 0)

    private var viewport = CaptionViewport()
    private var lastDocument: CaptionDocument?
    /// The surface's viewport configuration — pushed by the view on appear /
    /// size / style changes; AppModel reuses it for same-turn document updates.
    private(set) var lastConfig: CaptionViewportConfig?
    private var rowCount = 0

#if DEBUG
    /// Every screen the view could have drawn, in order. The render harness
    /// reads these; they must never diverge from `screen`.
    private(set) var screensForTesting: [CaptionScreen] = []
#endif

    /// Rows with at least one line intersecting the viewport.
    var visibleRowCount: Int {
        Set(screen.lines.map(\.id.row)).count
    }

    /// Rows in the document most recently laid out.
    var totalRowCount: Int {
        rowCount
    }

    /// The view's current layout request. Re-emits with the cached document
    /// when the config actually changed.
    func setConfig(_ config: CaptionViewportConfig) {
        guard config != lastConfig else { return }
        lastConfig = config
        guard let lastDocument else { return }
        emit(viewport.update(lastDocument, config: config))
    }

    /// Push a new document using the last known viewport config — the same
    /// main-actor turn the model changed, so the view never draws a stale
    /// screen beside fresh state. Without a config (surface not yet shown)
    /// the document is only remembered; `setConfig` emits it on appear.
    func update(document: CaptionDocument) {
        guard let lastConfig else {
            lastDocument = document
            rowCount = document.rows.count
            return
        }
        update(document: document, config: lastConfig)
    }

    func update(document: CaptionDocument, config: CaptionViewportConfig) {
        guard document != lastDocument || config != lastConfig else { return }
        lastDocument = document
        lastConfig = config
        rowCount = document.rows.count
        emit(viewport.update(document, config: config))
    }

    func scrollBack(rows: Int) {
        viewport.scrollBack(rows: rows)
        guard let lastDocument, let lastConfig else { return }
        emit(viewport.update(lastDocument, config: lastConfig))
    }

    private func emit(_ new: CaptionScreen) {
        guard new != screen else { return }
        screen = new
#if DEBUG
        screensForTesting.append(new)
#endif
    }
}

/// Per-pane drawing style handed to `CaptionScreenView`. The font is the same
/// `CTFont` instance the viewport broke lines with.
struct CaptionPaneSurfaceStyle {
    var color: Color
    var typography: CaptionTypography
    /// Horizontal alignment inside the line's column width.
    var alignment: Alignment
    var layoutDirection: LayoutDirection
}

/// Draws a `CaptionScreen` verbatim: absolute line offsets, per-run opacity,
/// the 8-copy outline, speaker badges, top fade, clip. The only animation is
/// line offsets easing into place as content scrolls up.
struct CaptionScreenView: View {
    let screen: CaptionScreen
    let paneStyles: [CaptionPane: CaptionPaneSurfaceStyle]
    let leadingPane: CaptionPane
    let outlineColor: Color?
    let badgeLabel: (Int) -> String
    let badgeColor: (Int) -> Color
    let badgeFontSize: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let outlineOffsets: [CGSize] = [
        CGSize(width: -1, height: 0),
        CGSize(width: 1, height: 0),
        CGSize(width: 0, height: -1),
        CGSize(width: 0, height: 1),
        CGSize(width: -1, height: -1),
        CGSize(width: -1, height: 1),
        CGSize(width: 1, height: -1),
        CGSize(width: 1, height: 1),
    ]

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(screen.lines) { line in
                lineView(for: line)
            }
            ForEach(screen.badges) { badge in
                badgeView(for: badge)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .mask(topFadeMask)
        // Text and colour changes never animate; only the line offsets ease as
        // the content coordinate shifts upward.
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.18),
            value: screen.contentTop
        )
    }

    private func lineView(for line: CaptionScreenLine) -> some View {
        let style = paneStyles[line.id.pane] ?? .fallback
        return ZStack(alignment: style.alignment) {
            if let outlineColor, line.text.isEmpty == false {
                ForEach(Self.outlineOffsets.indices, id: \.self) { index in
                    Text(verbatim: line.text)
                        .font(Font(style.typography.font))
                        .foregroundStyle(outlineColor)
                        .lineLimit(1)
                        .fixedSize()
                        .offset(
                            x: Self.outlineOffsets[index].width,
                            y: Self.outlineOffsets[index].height
                        )
                }
            }
            Text(attributedText(for: line, style: style))
                .font(Font(style.typography.font))
                .lineLimit(1)
                .fixedSize()
                // Nothing inside a line animates.
                .transaction { transaction in
                    transaction.animation = nil
                }
        }
        .frame(width: line.width, alignment: style.alignment)
        .offset(x: line.x, y: line.y)
        .environment(\.layoutDirection, style.layoutDirection)
        .accessibilityLabel(line.text)
        .accessibilityHidden(line.text.isEmpty)
    }

    /// Stable prefix at full opacity; mutable tail — or a draft line
    /// wholesale — dimmed.
    private func attributedText(
        for line: CaptionScreenLine,
        style: CaptionPaneSurfaceStyle
    ) -> AttributedString {
        OverlayCaptionRuns(
            text: line.text,
            agedPrefixLength: 0,
            stablePrefixLength: line.isDraft ? 0 : line.stableCount
        ).attributedString(baseColor: style.color)
    }

    private func badgeView(for badge: CaptionScreenBadge) -> some View {
        Text(badgeLabel(badge.speakerIndex))
            .font(.system(size: badgeFontSize, weight: .semibold))
            .foregroundStyle(.white.opacity(0.72))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous).fill(badgeColor(badge.speakerIndex))
            )
            .offset(y: badge.y)
            .allowsHitTesting(false)
    }

    /// One leading-pane line of fade, only while scrolled content sits above
    /// the viewport — an un-scrolled first row draws fully opaque.
    private var topFadeMask: some View {
        VStack(spacing: 0) {
            if screen.hasContentAbove {
                LinearGradient(
                    colors: [.clear, .white.opacity(0.6), .white],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: leadingLineHeight)
            }
            Color.white
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var leadingLineHeight: CGFloat {
        let font = (paneStyles[leadingPane] ?? .fallback).typography.font
        return ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
    }

}

extension CaptionPaneSurfaceStyle {
    static let fallback = CaptionPaneSurfaceStyle(
        color: .white,
        typography: .system(size: 17, weight: .regular),
        alignment: .center,
        layoutDirection: .leftToRight
    )
}

/// GeometryReader wrapper that builds the `CaptionViewportConfig` for its
/// role from the AppModel style and drives the controller.
struct CaptionSurfaceView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var controller: CaptionSurfaceController
    let role: CaptionSurfaceRole
    /// Top-down stacked captions align leading (the overlay column look) when
    /// the surface asks for it.
    var alignsTopDownCaptionsLeading = false
    /// Publish `visibleRowCount` to `model.overlayHistoryVisibleCount` so the
    /// history scrollbar can measure itself.
    var reportsVisibleRowCount = false

    var body: some View {
        GeometryReader { proxy in
            let config = viewportConfig(for: proxy.size)
            Group {
                // Draw what the controller last emitted — the model pushes
                // documents into it in the same turn they change.
                if controller.totalRowCount == 0 {
                    placeholder(for: proxy.size)
                } else {
                    CaptionScreenView(
                        screen: controller.screen,
                        paneStyles: paneStyles(for: proxy.size),
                        leadingPane: captionLayout.leadsWithTranslation ? .translated : .original,
                        outlineColor: model.overlayStyle.showsTextOutline
                            ? model.overlayStyle.textOutlineColor.color
                            : nil,
                        badgeLabel: { model.speakerLabel(for: $0) },
                        badgeColor: { Self.speakerBadgeColor(for: $0) },
                        badgeFontSize: badgeFontSize(for: proxy.size)
                    )
                }
            }
            .onAppear {
                controller.setConfig(config)
                if role == .overlay {
                    controller.scrollBack(rows: model.overlayHistoryScrollOffset)
                }
                reportVisibleCount()
            }
            .onChange(of: proxy.size) { _, _ in
                controller.setConfig(config)
            }
            .onChange(of: styleSignature) { _, _ in
                controller.setConfig(config)
            }
            .onChange(of: model.overlayHistoryScrollOffset) { _, offset in
                if role == .overlay {
                    controller.scrollBack(rows: offset)
                }
            }
            .onChange(of: controller.visibleRowCount) { _, _ in
                reportVisibleCount()
            }
        }
    }

    // MARK: - Configuration

    private func viewportConfig(for size: CGSize) -> CaptionViewportConfig {
        let scale = fontScale(for: size)
        let translatedSize = CGFloat(model.overlayStyle.scaledTranslatedFontSize) * scale
        let sourceSize = displayedSourceFontSize * scale
        let leadingPane: CaptionPane = captionLayout.leadsWithTranslation
            ? .translated
            : .original
        let arrangement: CaptionViewportConfig.Arrangement = usesColumnCaptions
            ? .columns(leading: leadingPane)
            : .stacked(leading: leadingPane)
        return CaptionViewportConfig(
            width: size.width,
            height: size.height,
            columnSpacing: 24,
            pairSpacing: 4,
            rowSpacing: 10,
            arrangement: arrangement,
            anchoring: role == .audience ? .top : .bottom,
            panes: model.captionPaneConfig,
            typography: [
                .translated: .system(size: translatedSize, weight: .semibold),
                .original: .system(size: sourceSize, weight: sourceFontWeight),
            ],
            showsSpeakerBadges: model.showsSpeakerBadges,
            badgeHeight: badgeHeight(for: size)
        )
    }

    private func fontScale(for size: CGSize) -> CGFloat {
        role == .audience ? max(1, size.height / 540) : 1
    }

    private var captionLayout: OverlayCaptionLayout {
        model.overlayStyle.captionLayout
    }

    private var usesColumnCaptions: Bool {
        captionLayout.usesColumns
            && model.showsTranslatedSubtitle
            && model.showsOriginalSubtitle
    }

    /// Everything that changes the viewport config besides size and document.
    private var styleSignature: Int {
        var hasher = Hasher()
        hasher.combine(model.overlayStyle.scaledTranslatedFontSize)
        hasher.combine(model.overlayStyle.scaledSourceFontSize)
        hasher.combine(model.overlayStyle.captionLayout)
        hasher.combine(model.subtitleDisplayMode)
        hasher.combine(model.showsSpeakerBadges)
        hasher.combine(model.inputLanguageID)
        hasher.combine(model.outputLanguageID)
        hasher.combine(model.liveDraftCaptions)
        return hasher.finalize()
    }

    private var usesTranslatedTypographyForSourceText: Bool {
        model.showsOriginalSubtitle && model.showsTranslatedSubtitle == false
    }

    private var displayedSourceFontSize: CGFloat {
        usesTranslatedTypographyForSourceText
            ? CGFloat(model.overlayStyle.scaledTranslatedFontSize)
            : CGFloat(model.overlayStyle.scaledSourceFontSize)
    }

    private var sourceFontWeight: CaptionFontWeight {
        usesTranslatedTypographyForSourceText ? .semibold : .regular
    }

    private func badgeFontSize(for size: CGSize) -> CGFloat {
        max(displayedSourceFontSize * fontScale(for: size) * 0.72, 9)
    }

    private func badgeHeight(for size: CGSize) -> CGFloat {
        ceil(
            CaptionLineBreaker.lineHeight(
                CaptionTypography.system(size: badgeFontSize(for: size), weight: .semibold).font
            )
        ) + 4
    }

    private var usesLeadingCaptionAlignment: Bool {
        usesColumnCaptions || (alignsTopDownCaptionsLeading && captionLayout == .topDown)
    }

    private func paneLayoutDirection(for languageID: String) -> LayoutDirection {
        Locale.Language(identifier: languageID).characterDirection == .rightToLeft
            ? .rightToLeft
            : .leftToRight
    }

    /// Pane styles at the same scale the viewport laid out with.
    private func paneStyles(for size: CGSize) -> [CaptionPane: CaptionPaneSurfaceStyle] {
        let subtitleColor = model.overlayStyle.subtitleColor.color
        let scale = fontScale(for: size)
        return [
            .translated: CaptionPaneSurfaceStyle(
                color: subtitleColor,
                typography: .system(
                    size: CGFloat(model.overlayStyle.scaledTranslatedFontSize) * scale,
                    weight: .semibold
                ),
                alignment: paneAlignment(for: model.outputLanguageID),
                layoutDirection: paneLayoutDirection(for: model.outputLanguageID)
            ),
            .original: CaptionPaneSurfaceStyle(
                color: subtitleColor,
                typography: .system(
                    size: displayedSourceFontSize * scale,
                    weight: sourceFontWeight
                ),
                alignment: paneAlignment(for: model.inputLanguageID),
                layoutDirection: paneLayoutDirection(for: model.inputLanguageID)
            ),
        ]
    }

    /// Leading alignment unless the pane's language is RTL, then trailing.
    private func paneAlignment(for languageID: String) -> Alignment {
        if paneLayoutDirection(for: languageID) == .rightToLeft {
            return .trailing
        }
        return usesLeadingCaptionAlignment ? .leading : .center
    }

    private func reportVisibleCount() {
        guard reportsVisibleRowCount else { return }
        model.updateOverlayHistoryVisibleCount(controller.visibleRowCount)
    }

    // MARK: - Placeholder

    /// No caption rows yet: show the committed/status text the old view drew —
    /// preview sample, "Listening…", or the error string — static, aligned per
    /// style.
    private func placeholder(for size: CGSize) -> some View {
        let state = model.overlayState
        let translated = state?.translatedText ?? ""
        let source = state?.sourceText ?? ""
        let leadingFirst = captionLayout.leadsWithTranslation
        let primary = model.showsTranslatedSubtitle ? translated : ""
        let secondary = model.showsOriginalSubtitle ? source : ""
        return VStack(alignment: placeholderStackAlignment, spacing: 4) {
            if leadingFirst == false, secondary.isEmpty == false {
                placeholderText(secondary, pane: .original, size: size)
            }
            if primary.isEmpty == false {
                placeholderText(primary, pane: .translated, size: size)
            }
            if leadingFirst, secondary.isEmpty == false {
                placeholderText(secondary, pane: .original, size: size)
            }
        }
        .frame(maxWidth: .infinity, alignment: placeholderFrameAlignment)
        .frame(maxHeight: .infinity, alignment: role == .audience ? .top : .bottom)
        .padding(.bottom, role == .audience ? 0 : 3)
    }

    private func placeholderText(_ text: String, pane: CaptionPane, size: CGSize) -> some View {
        let style = paneStyles(for: size)[pane] ?? .fallback
        return Text(verbatim: text)
            .font(Font(style.typography.font))
            .foregroundStyle(style.color)
            .lineLimit(2)
            .multilineTextAlignment(textAlignment(for: style.alignment))
            .environment(\.layoutDirection, style.layoutDirection)
    }

    private var placeholderStackAlignment: HorizontalAlignment {
        switch usesLeadingCaptionAlignment {
        case true: return .leading
        case false: return .center
        }
    }

    private var placeholderFrameAlignment: Alignment {
        usesLeadingCaptionAlignment ? .leading : .center
    }

    private func textAlignment(for alignment: Alignment) -> TextAlignment {
        switch alignment {
        case .leading: return .leading
        case .trailing: return .trailing
        default: return .center
        }
    }

    static func speakerBadgeColor(for index: Int) -> Color {
        let hues: [Double] = [0.58, 0.08, 0.38, 0.78, 0.18, 0.68, 0.48, 0.88]
        return Color(hue: hues[index % hues.count], saturation: 0.55, brightness: 0.42)
    }
}
