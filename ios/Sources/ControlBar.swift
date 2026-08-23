import Foundation
import SwiftUI

struct ControlBar: View {
    @ObservedObject var model: AppModel
    let isStartDisabled: Bool
    let toggleSession: () -> Void
    let showTranscript: () -> Void
    let showSettings: () -> Void

    private var accent: Color {
        IOSTheme.color(model.iOSCaptionAccentColor)
    }

    var body: some View {
        VStack(spacing: 10) {
            statusLine

            ViewThatFits(in: .horizontal) {
                wideControls
                    .fixedSize(horizontal: true, vertical: false)
                stackedControls
            }
        }
        .padding(12)
        .premiumPanel(cornerRadius: 28)
        .tint(accent)
    }

    private var wideControls: some View {
        HStack(spacing: 8) {
            sourceMenu
                .frame(minWidth: 106)
            inputLanguageMenu
                .frame(minWidth: 96)
            outputLanguageMenu
                .frame(minWidth: 96)

            ControlIconButton(
                symbol: "doc.text",
                title: model.localized(.transcript),
                action: showTranscript
            )

            SessionCapsuleButton(
                title: model.sessionButtonTitle,
                isLive: model.sessionState == .running,
                showsActivity: model.showsSessionWaitIndicator,
                isDisabled: isStartDisabled,
                accent: accent,
                action: toggleSession
            )
            .frame(minWidth: 126)

            ControlIconButton(
                symbol: "gearshape.fill",
                title: model.localized(.iosSettings),
                action: showSettings
            )
        }
    }

    private var stackedControls: some View {
        VStack(spacing: 9) {
            // Compact width cannot fit three menus side by side without the
            // microphone value collapsing, so the source gets its own full-width
            // row and the two language menus keep equal halves below it.
            sourceMenu
                .frame(minWidth: 160, maxWidth: .infinity)

            HStack(spacing: 8) {
                inputLanguageMenu
                    .frame(minWidth: 92, maxWidth: .infinity)
                    .layoutPriority(1)
                outputLanguageMenu
                    .frame(minWidth: 92, maxWidth: .infinity)
                    .layoutPriority(1)
            }

            HStack(spacing: 12) {
                ControlIconButton(
                    symbol: "doc.text",
                    title: model.localized(.transcript),
                    action: showTranscript
                )

                SessionCapsuleButton(
                    title: model.sessionButtonTitle,
                    isLive: model.sessionState == .running,
                    showsActivity: model.showsSessionWaitIndicator,
                    isDisabled: isStartDisabled,
                    accent: accent,
                    action: toggleSession
                )
                .frame(maxWidth: 210)

                ControlIconButton(
                    symbol: "gearshape.fill",
                    title: model.localized(.iosSettings),
                    action: showSettings
                )
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if let resourceStatus = prioritizedResourceStatus {
            HStack(spacing: 8) {
                Image(systemName: resourceStatus.isError ? "exclamationmark.triangle.fill" : "arrow.down.circle.fill")
                    .foregroundStyle(resourceStatus.isError ? Color.red.opacity(0.92) : accent)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(resourceStatus.title)
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.88))
                        .lineLimit(1)

                    if resourceStatus.detail.isEmpty == false {
                        Text(resourceStatus.detail)
                            .font(.system(.caption2, design: .rounded))
                            .foregroundStyle(resourceStatus.isError ? Color.red.opacity(0.88) : IOSTheme.secondaryText)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 8)

                if let progress = resourceStatus.progress, resourceStatus.isError == false {
                    ProgressView(value: progress)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .accessibilityValue("\(Int((progress * 100).rounded()))%")
                } else if resourceStatus.isError == false {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .transition(.opacity)
        } else {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                    .shadow(color: statusColor.opacity(0.8), radius: model.sessionState == .running ? 5 : 0)
                    .accessibilityHidden(true)

                Text(model.statusMessage.isEmpty ? model.sessionBadgeText : model.statusMessage)
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .lineLimit(2)

                Spacer(minLength: 0)
            }
            .transition(.opacity)
        }
    }

    private var prioritizedResourceStatus: LanguageResourceStatus? {
        model.languageResourceStatuses.first(where: \.isError)
            ?? model.languageResourceStatuses.first
    }

    private var statusColor: Color {
        switch model.sessionState {
        case .idle:
            return Color.white.opacity(0.34)
        case .running:
            return accent
        case .error:
            return .red
        }
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
            ControlMenuLabel(
                // Static, width-stable caption: localized "Microphone" strings
                // vary enough in length to squeeze the device name out of view.
                title: "MIC",
                value: selectedSourceDisplay,
                symbol: "mic"
            )
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
            ControlMenuLabel(
                title: model.localized(.inputShort),
                value: LanguageCatalog.autonym(for: model.iOSEffectiveInputLanguageID),
                symbol: "waveform"
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
            ControlMenuLabel(
                title: model.localized(.subtitleShort),
                value: LanguageCatalog.autonym(for: model.iOSEffectiveOutputLanguageID),
                symbol: "character.bubble"
            )
        }
        .disabled(model.isLanguagePairLocked)
        .accessibilityLabel(model.localized(.subtitleLanguage))
    }

}

private struct ControlMenuLabel: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 14)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(Color.white.opacity(0.46))
                    .lineLimit(1)
                    .fixedSize()

                Text(value)
                    .font(.system(.caption2, design: .rounded, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.90))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .truncationMode(.tail)
            }
            // Floor on the text column: without it the surrounding HStack can
            // squeeze the VStack to zero, leaving only icon + chevron visible.
            .frame(minWidth: 52, alignment: .leading)
            .layoutPriority(1)

            Spacer(minLength: 4)

            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.30))
                .frame(width: 9)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.055))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.085), lineWidth: 0.5)
        }
        .contentShape(Rectangle())
    }
}

struct ControlIconButton: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.white.opacity(0.065)))
                .overlay {
                    Circle().stroke(Color.white.opacity(0.09), lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.white.opacity(0.88))
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

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: isLive == false)) { context in
            let pulse = isLive
                ? (sin(context.date.timeIntervalSinceReferenceDate * 3.2) + 1.0) / 2.0
                : 0.0

            Button(action: action) {
                HStack(spacing: 8) {
                    if showsActivity {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color.black.opacity(0.78))
                    } else {
                        Image(systemName: isLive ? "stop.fill" : "mic.fill")
                            .font(.system(size: 14, weight: .bold))
                            .accessibilityHidden(true)
                    }

                    Text(title)
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .lineLimit(1)
                }
                .foregroundStyle(Color.black.opacity(0.82))
                .frame(maxWidth: .infinity, minHeight: 46)
                .padding(.horizontal, 18)
                .background(
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [accent.opacity(0.98), accent.opacity(0.72)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.28), lineWidth: 0.5)
                }
                .shadow(
                    color: accent.opacity(isLive ? 0.20 + pulse * 0.28 : 0.12),
                    radius: isLive ? 10 + pulse * 9 : 8,
                    y: 3
                )
                .scaleEffect(isLive ? 1.0 + pulse * 0.008 : 1.0)
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .opacity(isDisabled ? 0.42 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: isDisabled)
            .accessibilityLabel(title)
        }
    }
}
