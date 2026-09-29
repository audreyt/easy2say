import AppKit
import SwiftUI

/// Chrome around the caption surface: column header + divider for the
/// two-column layout, scrollbar padding, and the outer insets. All caption
/// layout is `CaptionSurfaceView` + `CaptionViewport`; the document is the
/// single source of truth.
struct CaptionFlowContentView: View {
    @ObservedObject var model: AppModel
    var role: CaptionSurfaceRole = .overlay
    var showsScrollbarPadding: Bool = false
    var updatesModelHistoryVisibleCount: Bool = false
    var reservesColumnHeaderSpace: Bool = true
    var columnHeaderOpacity: Double = 1.0
    var alignsTopDownCaptionsLeading: Bool = false

    var body: some View {
        Group {
            if model.overlayState != nil {
                CaptionSurfaceView(
                    model: model,
                    controller: surfaceController,
                    role: role,
                    alignsTopDownCaptionsLeading: alignsTopDownCaptionsLeading,
                    reportsVisibleRowCount: updatesModelHistoryVisibleCount
                )
                .padding(.top, captionColumnHeaderHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(alignment: .center) { captionColumnDivider }
                .overlay(alignment: .top) { captionColumnHeader }
                .padding(.leading, 20)
                .padding(
                    .trailing,
                    showsScrollbarPadding
                        ? 20 + OverlayHistoryScrollbarLayout.panelWidth + OverlayHistoryScrollbarLayout.contentSpacing
                        : 20
                )
                .padding(.top, 12)
            }
        }
    }

    private var surfaceController: CaptionSurfaceController {
        role == .overlay ? model.overlayCaptionSurface : model.audienceCaptionSurface
    }

    // MARK: - Column header chrome

    private var captionLayout: OverlayCaptionLayout {
        model.overlayStyle.captionLayout
    }

    private var showsOriginalSubtitle: Bool {
        model.showsOriginalSubtitle
    }

    private var showsTranslatedSubtitle: Bool {
        model.showsTranslatedSubtitle
    }

    private var usesColumnCaptions: Bool {
        captionLayout.usesColumns
            && showsTranslatedSubtitle
            && showsOriginalSubtitle
    }

    private func captionLayoutDirection(for languageID: String) -> LayoutDirection {
        Locale.Language(identifier: languageID).characterDirection == .rightToLeft
            ? .rightToLeft
            : .leftToRight
    }

    private var interfaceLabelLayoutDirection: LayoutDirection {
        captionLayoutDirection(for: model.resolvedInterfaceLanguageID)
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
}

extension CaptionFlowContentView {
    /// Gap between the two 50/50 caption columns, and the height reserved for their
    /// role labels above the flow.
    static let captionColumnSpacing: CGFloat = 24.0
    static let columnHeaderHeight: CGFloat = 24.0
}

/// Which surface hosts the Translation session — exactly one does at a time.
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
