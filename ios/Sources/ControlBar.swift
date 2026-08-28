import Foundation
import SwiftUI

struct ControlBar: View {
    @ObservedObject var model: AppModel
    let isStartDisabled: Bool
    let toggleSession: () -> Void
    let showTranscript: () -> Void
    let showSettings: () -> Void
    let selectConversationMode: (Bool) -> Void
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var languageSwapDragOffset: CGFloat = 0
    @State private var languageSwapIsOnRight = false

    /// Chrome is always brand peach; the reader's caption colour stays in the
    /// captions themselves.
    private let accent = IOSTheme.brand

    private var canSwapLanguages: Bool {
        let inputID = model.iOSEffectiveInputLanguageID
        let outputID = model.iOSEffectiveOutputLanguageID
        return model.isLanguagePairLocked == false
            && inputID != outputID
            && model.speechLanguageOptions.contains(where: { $0.id == outputID })
            && model.translationLanguageOptions.contains(where: { $0.id == inputID })
    }

    private var modeFlip: some View {
        ConversationModeSwitch(
            captionsTitle: model.localized(.conversationCaptionsMode),
            conversationTitle: model.localized(.conversationMode),
            accent: accent,
            isConversationActive: model.isConversationModeActive,
            destinationAccessibilityLabel: model.localized(
                model.isConversationModeActive ? .switchToCaptionsMode : .switchToConversationMode
            ),
            select: selectConversationMode
        )
    }

    var body: some View {
        Group {
            if verticalSizeClass == .compact {
                HStack(spacing: 16) {
                    VStack(spacing: 8) {
                        statusLine
                        languageRail
                    }
                    .frame(maxWidth: .infinity)

                    recordingDock
                        .fixedSize(horizontal: true, vertical: false)
                }
                .padding(10)
            } else {
                VStack(spacing: 11) {
                    statusLine
                    languageRail
                    recordingDock
                        .frame(maxWidth: .infinity)
                }
                .padding(12)
            }
        }
        .premiumPanel(cornerRadius: 30)
        .tint(accent)
    }

    private var languageRail: some View {
        HStack(spacing: 8) {
            inputLanguageMenu
                .frame(maxWidth: .infinity)

            directionMedallion

            outputLanguageMenu
                .frame(maxWidth: .infinity)
        }
    }

    private var directionMedallion: some View {
        let restingOffset: CGFloat = languageSwapIsOnRight ? 15 : -15

        return ZStack {
            Capsule(style: .continuous)
                .fill(accent.opacity(0.075))
                .frame(width: 64, height: 34)
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(accent.opacity(0.18), lineWidth: 0.75)
                }

            HStack {
                Circle()
                    .fill(IOSTheme.primaryText.opacity(languageSwapIsOnRight ? 0.16 : 0.34))
                    .frame(width: 3, height: 3)

                Spacer()

                Circle()
                    .fill(IOSTheme.primaryText.opacity(languageSwapIsOnRight ? 0.34 : 0.16))
                    .frame(width: 3, height: 3)
            }
            .frame(width: 50)
            .accessibilityHidden(true)

            Circle()
                .fill(accent.opacity(0.20))
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(accent.opacity(0.96))
                }
                .overlay {
                    Circle()
                        .stroke(accent.opacity(0.32), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.28), radius: 4, y: 2)
                .offset(x: restingOffset + languageSwapDragOffset)
        }
        // The track reads at 34pt tall; the drag/tap area stays at the 44pt minimum.
        .frame(width: 64, height: 44)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { value in
                    guard canSwapLanguages else { return }
                    let proposedOffset = restingOffset + value.translation.width
                    let clampedOffset = min(max(proposedOffset, -15), 15)
                    languageSwapDragOffset = clampedOffset - restingOffset
                }
                .onEnded { value in
                    guard canSwapLanguages else { return }
                    let crossedThreshold = languageSwapIsOnRight
                        ? value.translation.width <= -14
                        : value.translation.width >= 14
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.78)) {
                        if crossedThreshold {
                            swapLanguages()
                            languageSwapIsOnRight.toggle()
                        }
                        languageSwapDragOffset = 0
                    }
                }
                .exclusively(
                    before: TapGesture()
                        .onEnded {
                            toggleLanguagesFromSlider()
                        }
                )
        )
        .allowsHitTesting(canSwapLanguages)
        .opacity(canSwapLanguages ? 1.0 : 0.42)
        .accessibilityElement()
        .accessibilityLabel(model.localized(.swapInputAndSubtitleLanguages))
        .accessibilityValue(
            "\(LanguageCatalog.autonym(for: model.iOSEffectiveInputLanguageID)) → "
                + LanguageCatalog.autonym(for: model.iOSEffectiveOutputLanguageID)
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            toggleLanguagesFromSlider()
        }
    }

    private func toggleLanguagesFromSlider() {
        guard canSwapLanguages else { return }
        withAnimation(.spring(response: 0.24, dampingFraction: 0.78)) {
            swapLanguages()
            languageSwapIsOnRight.toggle()
            languageSwapDragOffset = 0
        }
    }

    private func swapLanguages() {
        guard canSwapLanguages else { return }
        let inputID = model.iOSEffectiveInputLanguageID
        let outputID = model.iOSEffectiveOutputLanguageID
        model.setIOSInputLanguageID(outputID)
        model.setIOSOutputLanguageID(inputID)
    }

    private var recordingDock: some View {
        HStack(alignment: .center, spacing: 28) {
            ControlIconButton(
                symbol: "gearshape.fill",
                title: model.localized(.iosSettings),
                action: showSettings
            )

            SessionCapsuleButton(
                title: model.sessionButtonTitle,
                isLive: model.sessionState == .running,
                showsActivity: model.showsSessionWaitIndicator,
                isDisabled: isStartDisabled,
                accent: accent,
                action: toggleSession
            )

            ControlIconButton(
                symbol: "doc.text",
                title: model.localized(.transcript),
                action: showTranscript
            )
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if let resourceStatus = prioritizedResourceStatus {
            HStack(spacing: 9) {
                Image(
                    systemName: resourceStatus.isError
                        ? "exclamationmark.triangle.fill"
                        : "arrow.down.circle.fill"
                )
                .foregroundStyle(resourceStatus.isError ? IOSTheme.alert : accent)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(resourceStatus.title)
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                        .foregroundStyle(IOSTheme.primaryText.opacity(0.90))
                        .lineLimit(1)

                    Text(resourceStatus.detail)
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(
                            resourceStatus.isError
                                ? IOSTheme.alert
                                : IOSTheme.secondaryText
                        )
                        .lineLimit(2)
                }

                Spacer(minLength: 4)

                if let progress = resourceStatus.progress, resourceStatus.isError == false {
                    ProgressView(value: progress)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(accent)
                } else if resourceStatus.isError == false {
                    ProgressView()
                        .controlSize(.small)
                        .tint(accent)
                }

                modeFlip
                sourceMenu
            }
            .transition(.opacity)
        } else {
            HStack(spacing: 9) {
                BrandStatusMark(
                    isLive: model.sessionState == .running,
                    isError: model.sessionState == .error
                )

                Text(
                    model.statusMessage.isEmpty
                        ? model.sessionBadgeText
                        : model.statusMessage
                )
                .font(.system(.caption, design: .rounded, weight: .medium))
                .foregroundStyle(IOSTheme.secondaryText)
                .lineLimit(2)

                Spacer(minLength: 4)

                modeFlip
                sourceMenu
            }
            .transition(.opacity)
        }
    }

    private var prioritizedResourceStatus: LanguageResourceStatus? {
        model.languageResourceStatuses.first(where: \.isError)
            ?? model.languageResourceStatuses.first
    }

    private var selectedSourceDisplay: String {
        guard let source = model.iOSSelectedMicrophoneSource else {
            return model.localized(.iosNoMicrophonesTitle)
        }
        let name = source.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? model.localized(.microphone) : name
    }

    private var sourceMenu: some View {
        Menu {
            if model.microphoneSources.isEmpty {
                Button(model.localized(.iosNoMicrophonesTitle)) {}
                    .disabled(true)
            } else {
                ForEach(model.microphoneSources) { source in
                    Button {
                        model.selectIOSMicrophone(source)
                    } label: {
                        if model.iOSSelectedMicrophoneSource?.id == source.id {
                            Label(source.name, systemImage: "checkmark")
                        } else {
                            Text(source.name)
                        }
                    }
                }
            }

            Divider()

            Button {
                model.refreshSources()
            } label: {
                Label(model.localized(.refreshSources), systemImage: "arrow.clockwise")
            }
        } label: {
            MicrophoneChip(value: selectedSourceDisplay, accent: accent)
        }
        .disabled(model.sessionState == .running)
        .accessibilityLabel(model.localized(.inputSource))
    }

    private var inputLanguageMenu: some View {
        Menu {
            ForEach(model.speechLanguageOptions) { option in
                Button {
                    model.setIOSInputLanguageID(option.id)
                } label: {
                    let title = LanguageCatalog.autonym(for: option.id)
                    if option.id == model.iOSEffectiveInputLanguageID {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
            }
        } label: {
            LanguagePill(
                role: model.localized(.inputShort),
                value: LanguageCatalog.autonym(for: model.iOSEffectiveInputLanguageID),
                symbol: "waveform",
                accent: accent
            )
        }
        .disabled(model.isLanguagePairLocked)
        .accessibilityLabel(model.localized(.inputLanguage))
    }

    private var outputLanguageMenu: some View {
        Menu {
            ForEach(model.translationLanguageOptions) { option in
                Button {
                    model.setIOSOutputLanguageID(option.id)
                } label: {
                    let title = LanguageCatalog.autonym(for: option.id)
                    if option.id == model.iOSEffectiveOutputLanguageID {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
            }
        } label: {
            LanguagePill(
                role: model.localized(.subtitleShort),
                value: LanguageCatalog.autonym(for: model.iOSEffectiveOutputLanguageID),
                symbol: "character.bubble",
                accent: accent
            )
        }
        .disabled(model.isLanguagePairLocked)
        .accessibilityLabel(model.localized(.subtitleLanguage))
    }
}

private struct LanguagePill: View {
    let role: String
    let value: String
    let symbol: String
    let accent: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent.opacity(0.92))
                .frame(width: 14)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(role.uppercased())
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(0.7)
                    .foregroundStyle(IOSTheme.tertiaryText)
                    .lineLimit(1)

                Text(value)
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(IOSTheme.primaryText.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(IOSTheme.primaryText.opacity(0.38))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity, minHeight: 48)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(accent.opacity(0.075))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(accent.opacity(0.17), lineWidth: 0.5)
        }
        .contentShape(Rectangle())
    }
}

private struct MicrophoneChip: View {
    let value: String
    let accent: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "mic.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(accent.opacity(0.90))
                .accessibilityHidden(true)

            Text(value)
                .font(.system(.caption2, design: .rounded, weight: .semibold))
                .foregroundStyle(IOSTheme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)

            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(IOSTheme.primaryText.opacity(0.34))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .frame(maxWidth: 144)
        .background(
            Capsule(style: .continuous)
                .fill(IOSTheme.primaryText.opacity(0.055))
        )
        .overlay {
            Capsule(style: .continuous)
                .stroke(IOSTheme.hairline, lineWidth: 0.5)
        }
        .contentShape(Capsule(style: .continuous))
    }
}

struct ControlIconButton: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(IOSTheme.primaryText.opacity(0.88))
                .frame(width: 48, height: 48)
                .background(
                    Circle()
                        .fill(IOSTheme.primaryText.opacity(0.065))
                )
                .overlay {
                    Circle()
                        .stroke(IOSTheme.hairline, lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

struct SessionCapsuleButton: View {
    let title: String
    let isLive: Bool
    let showsActivity: Bool
    let isDisabled: Bool
    let accent: Color
    let action: () -> Void

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var usesCompactDock: Bool {
        verticalSizeClass == .compact
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: isLive == false)) { context in
            let pulse = isLive
                ? (sin(context.date.timeIntervalSinceReferenceDate * 3.2) + 1.0) / 2.0
                : 0.0
            let buttonSize: CGFloat = usesCompactDock ? 56 : 68
            let haloSize: CGFloat = usesCompactDock ? 68 : 82
            let hitSize: CGFloat = usesCompactDock ? 70 : 84

            Button(action: action) {
                VStack(spacing: usesCompactDock ? 0 : 5) {
                    ZStack {
                        if isLive {
                            Circle()
                                .stroke(accent.opacity(0.30), lineWidth: 2)
                                .frame(width: haloSize, height: haloSize)
                                .scaleEffect(1.0 + pulse * 0.10)
                                .opacity(0.72 - pulse * 0.28)
                        }

                        Circle()
                            .fill(
                                isLive
                                    ? AnyShapeStyle(IOSTheme.primaryText.opacity(0.075))
                                    : AnyShapeStyle(
                                        LinearGradient(
                                            colors: [accent.opacity(0.98), accent.opacity(0.72)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                            )
                            .frame(width: buttonSize, height: buttonSize)
                            .overlay {
                                Circle()
                                    .stroke(IOSTheme.primaryText.opacity(isLive ? 0.14 : 0.30), lineWidth: 0.5)
                            }
                            .shadow(
                                color: accent.opacity(isLive ? 0.18 + pulse * 0.22 : 0.16),
                                radius: isLive ? 10 + pulse * 8 : 9,
                                y: 3
                            )

                        if showsActivity {
                            ProgressView()
                                .controlSize(usesCompactDock ? .small : .regular)
                                .tint(EasyBrand.plum)
                        } else if isLive {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(IOSTheme.alert)
                                .frame(
                                    width: usesCompactDock ? 16 : 19,
                                    height: usesCompactDock ? 16 : 19
                                )
                                .accessibilityHidden(true)
                        } else {
                            Image(systemName: "mic.fill")
                                .font(
                                    .system(
                                        size: usesCompactDock ? 18 : 22,
                                        weight: .bold
                                    )
                                )
                                .foregroundStyle(EasyBrand.plum)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(width: hitSize, height: hitSize)

                    if usesCompactDock == false {
                        Text(title)
                            .font(.system(.caption2, design: .rounded, weight: .semibold))
                            .foregroundStyle(IOSTheme.secondaryText.opacity(0.94))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                            .frame(maxWidth: 116)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .opacity(isDisabled ? 0.62 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: isDisabled)
            .accessibilityLabel(title)
        }
    }
}
