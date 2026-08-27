import Foundation
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .animation(.easeInOut(duration: 0.25), value: model.subtitleDisplayMode)
    }

    @ViewBuilder
    private var splitCaptions: some View {
        if isHorizontal {
            HStack(spacing: 10) {
                sourceCaption
                translatedCaption
            }
        } else {
            VStack(spacing: 10) {
                sourceCaption
                translatedCaption
            }
        }
    }

    private var sourceCaption: some View {
        CaptionPane(
            model: model,
            role: .source,
            accent: accent
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var translatedCaption: some View {
        CaptionPane(
            model: model,
            role: .translation,
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
    let accent: Color

    @ScaledMetric(relativeTo: .largeTitle) private var baseCaptionSize: CGFloat = 34


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

    private var tentativeText: String? {
        guard let draftText, draftText.isEmpty == false else { return nil }
        guard committedText.isEmpty == false else { return draftText }
        guard draftText != committedText else { return nil }

        if draftText.hasPrefix(committedText) {
            let tail = String(draftText.dropFirst(committedText.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return tail.isEmpty ? nil : tail
        }
        return draftText
    }


    private var visibleText: String {
        [committedText, tentativeText]
            .compactMap { $0 }
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
    }

    private var transitionIdentity: String {
        let epoch = model.overlayState?.captionEpoch ?? 0
        return "\(role.rawValue)-\(epoch)-\(committedText)-\(tentativeText ?? "")"
    }

    private var placeholderKey: AppTextKey {
        role == .source ? .iosSourcePlaceholder : .iosTranslationPlaceholder
    }

    private var placeholderSymbol: String {
        role == .source ? "waveform" : "character.bubble"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if model.sessionState == .idle {
                    idlePlaceholder
                } else if visibleText.isEmpty {
                    waitingPlaceholder
                } else {
                    captionText
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(IOSTheme.elevated.opacity(0.74))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(IOSTheme.hairline, lineWidth: 0.5)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }


    private var idlePlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: placeholderSymbol)
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(accent.opacity(0.46))
                .accessibilityHidden(true)

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
        VStack(alignment: .leading, spacing: 10) {
            if committedText.isEmpty == false {
                Text(committedText)
                    .font(
                        .system(
                            size: baseCaptionSize * CGFloat(model.overlayStyle.overlayScaleFactor),
                            weight: .semibold,
                            design: .rounded
                        )
                    )
                    .foregroundStyle(accent)
                    .multilineTextAlignment(.leading)
                    .lineLimit(nil)
                    .minimumScaleFactor(0.5)
                    .allowsTightening(true)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let tentativeText {
                HStack(alignment: .lastTextBaseline, spacing: 7) {
                    Text(tentativeText)
                        .font(
                            .system(
                                size: baseCaptionSize * CGFloat(model.overlayStyle.overlayScaleFactor),
                                weight: .medium,
                                design: .rounded
                            )
                        )
                        .foregroundStyle(IOSTheme.secondaryText)
                        .multilineTextAlignment(.leading)
                        .lineLimit(nil)
                        .minimumScaleFactor(0.5)
                        .allowsTightening(true)
                        .fixedSize(horizontal: false, vertical: true)

                    AnimatedEllipsis(color: accent.opacity(0.64))
                        .padding(.bottom, 4)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .id(transitionIdentity)
        .transition(.opacity)
        .animation(.easeOut(duration: 0.24), value: transitionIdentity)
        .accessibilityLabel(visibleText)
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
