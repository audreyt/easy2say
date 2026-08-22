import SwiftUI

struct CaptionHalves: View {
    @ObservedObject var model: AppModel
    let isHorizontal: Bool

    private var accent: Color {
        IOSTheme.color(model.iOSCaptionAccentColor)
    }

    var body: some View {
        Group {
            switch model.subtitleDisplayMode {
            case .both:
                splitCaptions
            case .originalOnly:
                sourceCaption
            case .translatedOnly:
                translatedCaption
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.subtitleDisplayMode)
    }

    @ViewBuilder
    private var splitCaptions: some View {
        if isHorizontal {
            HStack(spacing: 0) {
                sourceCaption
                CaptionHairline(isVertical: true, accent: accent)
                translatedCaption
            }
        } else {
            VStack(spacing: 0) {
                sourceCaption
                CaptionHairline(isVertical: false, accent: accent)
                translatedCaption
            }
        }
    }

    private var sourceCaption: some View {
        CaptionPane(
            model: model,
            role: .source,
            languageID: model.iOSEffectiveInputLanguageID,
            accent: accent
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var translatedCaption: some View {
        CaptionPane(
            model: model,
            role: .translation,
            languageID: model.iOSEffectiveOutputLanguageID,
            accent: accent
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private enum CaptionRole: String {
    case source
    case translation
}

private struct CaptionPane: View {
    @ObservedObject var model: AppModel
    let role: CaptionRole
    let languageID: String
    let accent: Color

    @ScaledMetric(relativeTo: .largeTitle) private var baseCaptionSize: CGFloat = 34

    private var languageName: String {
        LanguageCatalog.autonym(for: languageID)
    }

    private var committedText: String {
        guard let state = model.overlayState else { return "" }
        switch role {
        case .source:
            return state.sourceText
        case .translation:
            return state.translatedText
        }
    }

    private var draftText: String? {
        guard let state = model.overlayState,
              let sourceDraft = state.draftSourceText,
              sourceDraft.isEmpty == false else {
            return nil
        }

        switch role {
        case .source:
            return sourceDraft
        case .translation:
            return state.visibleDraftTranslatedText(
                for: sourceDraft,
                promotionID: state.draftPromotionID
            )
        }
    }

    private var showsDraft: Bool {
        draftText?.isEmpty == false
    }

    private var visibleText: String {
        if let draftText, draftText.isEmpty == false {
            return draftText
        }
        return committedText
    }

    private var transitionIdentity: String {
        let epoch = model.overlayState?.captionEpoch ?? 0
        return "\(role.rawValue)-\(epoch)-\(showsDraft)-\(visibleText)"
    }

    private var placeholderKey: AppTextKey {
        role == .source ? .iosSourcePlaceholder : .iosTranslationPlaceholder
    }

    private var placeholderSymbol: String {
        role == .source ? "waveform" : "character.bubble"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            languageChip

            Group {
                if model.sessionState == .idle {
                    idlePlaceholder
                } else if visibleText.isEmpty {
                    waitingPlaceholder
                } else {
                    captionText
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }

    private var languageChip: some View {
        Text(languageName)
            .font(.system(.caption, design: .rounded, weight: .semibold))
            .foregroundStyle(accent.opacity(0.92))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(accent.opacity(0.09))
            )
            .overlay {
                Capsule(style: .continuous)
                    .stroke(accent.opacity(0.20), lineWidth: 0.5)
            }
    }

    private var idlePlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: placeholderSymbol)
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(accent.opacity(0.46))
                .accessibilityHidden(true)

            Text(languageName)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.88))

            Text(model.localized(placeholderKey))
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(IOSTheme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
        .transition(.opacity)
    }

    private var waitingPlaceholder: some View {
        VStack(spacing: 10) {
            AnimatedEllipsis(color: accent)
            Text(model.localized(.listening))
                .font(.system(.subheadline, design: .rounded, weight: .medium))
                .foregroundStyle(IOSTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var captionText: some View {
        HStack(alignment: .lastTextBaseline, spacing: 7) {
            Text(visibleText)
                .font(
                    .system(
                        size: baseCaptionSize * CGFloat(model.overlayStyle.overlayScaleFactor),
                        weight: showsDraft ? .medium : .semibold,
                        design: .rounded
                    )
                )
                .foregroundStyle(accent.opacity(showsDraft ? 0.68 : 1.0))
                .multilineTextAlignment(.center)
                .lineLimit(nil)
                .minimumScaleFactor(0.5)
                .allowsTightening(true)
                .fixedSize(horizontal: false, vertical: false)

            if showsDraft {
                AnimatedEllipsis(color: accent.opacity(0.72))
                    .padding(.bottom, 4)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .id(transitionIdentity)
        .transition(
            .asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.985)),
                removal: .opacity
            )
        )
        .animation(.easeOut(duration: 0.28), value: transitionIdentity)
        .accessibilityLabel(visibleText)
    }
}

private struct CaptionHairline: View {
    let isVertical: Bool
    let accent: Color

    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [.clear, accent.opacity(0.62), Color.white.opacity(0.08), .clear],
                    startPoint: isVertical ? .top : .leading,
                    endPoint: isVertical ? .bottom : .trailing
                )
            )
            .frame(
                width: isVertical ? 0.5 : nil,
                height: isVertical ? nil : 0.5
            )
            .accessibilityHidden(true)
    }
}

private struct AnimatedEllipsis: View {
    let color: Color
    @State private var phase = 0

    var body: some View {
        Text(String(repeating: "·", count: phase + 1))
            .font(.system(.headline, design: .rounded, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 22, alignment: .leading)
            .task {
                while Task.isCancelled == false {
                    try? await Task.sleep(nanoseconds: 360_000_000)
                    guard Task.isCancelled == false else { break }
                    withAnimation(.easeInOut(duration: 0.18)) {
                        phase = (phase + 1) % 3
                    }
                }
            }
    }
}
