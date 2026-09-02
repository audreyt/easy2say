import SwiftUI

struct SettingsSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showsAcknowledgments = false

    private var accent: Color {
        IOSTheme.color(model.iOSCaptionAccentColor)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                IOSTheme.background(accent: accent)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        captionAppearanceSection
                        displaySection
                        audioInputSection
                        conversationSection
                        translationFallbackSection
                        interfaceLanguageSection
                        acknowledgmentsSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 34)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle(model.localized(.iosSettings))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(model.localized(.done)) {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .environment(\.locale, model.interfaceLocale)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showsAcknowledgments) {
            AcknowledgmentsSheet(
                title: model.localized(.acknowledgments),
                doneTitle: model.localized(.done)
            )
        }
    }

    private var captionAppearanceSection: some View {
        SettingsSectionCard(
            title: model.localized(.iosCaptionScale),
            symbol: "textformat.size",
            accent: accent
        ) {
            VStack(spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.localized(.iosCaptionScale))
                        .font(.system(.subheadline, design: .rounded, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.82))

                    Spacer()

                    Text("\(Int((model.overlayStyle.overlayScaleFactor * 100).rounded()))%")
                        .font(.system(.caption, design: .monospaced, weight: .semibold))
                        .foregroundStyle(accent)
                }

                Slider(value: captionScaleBinding, in: 0.75...1.50, step: 0.05)
                    .tint(accent)
                    .accessibilityLabel(model.localized(.iosCaptionScale))

                Rectangle()
                    .fill(IOSTheme.hairline)
                    .frame(height: 0.5)

                VStack(alignment: .leading, spacing: 12) {
                    Text(model.localized(.iosAccent))
                        .font(.system(.subheadline, design: .rounded, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.82))

                    HStack(spacing: 9) {
                        ForEach(CaptionAccentPreset.allCases) { preset in
                            accentButton(preset)
                        }
                    }
                }
            }
        }
    }

    private var displaySection: some View {
        SettingsSectionCard(
            title: model.localized(.subtitleDisplay),
            symbol: "captions.bubble",
            accent: accent
        ) {
            Picker(model.localized(.subtitleDisplay), selection: $model.subtitleDisplayMode) {
                ForEach(SubtitleDisplayMode.allCases, id: \.self) { mode in
                    Text(mode.displayName(in: model.resolvedInterfaceLanguageID))
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var audioInputSection: some View {
        SettingsSectionCard(
            title: model.localized(.inputSource),
            symbol: "mic.fill",
            accent: accent
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Menu {
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

                    Divider()

                    Button {
                        model.refreshSources()
                    } label: {
                        Label(model.localized(.refreshSources), systemImage: "arrow.clockwise")
                    }
                } label: {
                    HStack(spacing: 12) {
                        Text(
                            model.iOSSelectedMicrophoneSource?.name
                                ?? model.localized(.iosNoMicrophonesTitle)
                        )
                        .font(.system(.body, design: .rounded, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.88))
                        .lineLimit(1)

                        Spacer()

                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(accent)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(Color.white.opacity(0.055))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .stroke(Color.white.opacity(0.085), lineWidth: 0.5)
                    }
                }
                .accessibilityLabel(model.localized(.inputSource))

                Text(model.localized(.iosAudioInputHint))
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(IOSTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var conversationSection: some View {
        SettingsSectionCard(
            title: model.localized(.conversationMode),
            symbol: "person.2.wave.2.fill",
            accent: accent
        ) {
            VStack(alignment: .leading, spacing: 16) {
                conversationLanguageMenu(
                    title: model.localized(.conversationYourLanguage),
                    selection: $model.conversationPrimaryLanguageID
                )

                conversationLanguageMenu(
                    title: model.localized(.conversationTheirLanguage),
                    selection: $model.conversationSecondaryLanguageID
                )

                if model.conversationPrimaryLanguageID == model.conversationSecondaryLanguageID {
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.red.opacity(0.90))
                            .accessibilityHidden(true)

                        Text(model.localized(.conversationSameLanguage))
                            .font(.system(.caption, design: .rounded, weight: .medium))
                            .foregroundStyle(Color.red.opacity(0.88))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Rectangle()
                    .fill(IOSTheme.hairline)
                    .frame(height: 0.5)

                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: $model.conversationFaceToFace) {
                        Text(model.localized(.conversationFaceToFace))
                            .font(.system(.subheadline, design: .rounded, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.82))
                    }
                    .tint(accent)

                    Text(model.localized(.conversationFaceToFaceHint))
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(IOSTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(model.localized(.conversationAssistedHint))
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(IOSTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func conversationLanguageMenu(
        title: String,
        selection: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.52))

            Menu {
                ForEach(model.speechLanguageOptions.filter { $0.id != "nan" }) { option in
                    Button {
                        selection.wrappedValue = option.id
                    } label: {
                        let name = LanguageCatalog.autonym(for: option.id)
                        if option.id == selection.wrappedValue {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    Text(LanguageCatalog.autonym(for: selection.wrappedValue))
                        .font(.system(.body, design: .rounded, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.88))
                        .lineLimit(1)

                    Spacer()

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(accent)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                .background(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(Color.white.opacity(0.055))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(Color.white.opacity(0.085), lineWidth: 0.5)
                }
            }
            .accessibilityLabel(title)
        }
    }

    private var translationFallbackSection: some View {
        SettingsSectionCard(
            title: model.localized(.translation),
            symbol: "sparkles",
            accent: accent
        ) {
            Text(model.localized(.foundationModelsTranslationFallbackHint))
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(IOSTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var interfaceLanguageSection: some View {
        SettingsSectionCard(
            title: model.localized(.interfaceLanguage),
            symbol: "globe",
            accent: accent
        ) {
            Menu {
                ForEach(LanguageCatalog.interface) { option in
                    Button {
                        model.interfaceLanguageID = option.id
                    } label: {
                        let title = option.localizedDisplayName(in: model.resolvedInterfaceLanguageID)
                        if option.id == model.resolvedInterfaceLanguageID {
                            Label(title, systemImage: "checkmark")
                        } else {
                            Text(title)
                        }
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    Text(currentInterfaceLanguageName)
                        .font(.system(.body, design: .rounded, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.88))

                    Spacer()

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(accent)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                .background(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(Color.white.opacity(0.055))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(Color.white.opacity(0.085), lineWidth: 0.5)
                }
            }
            .accessibilityLabel(model.localized(.interfaceLanguage))
        }
    }

    private var acknowledgmentsSection: some View {
        SettingsSectionCard(
            title: model.localized(.acknowledgments),
            symbol: "doc.text",
            accent: accent
        ) {
            Button {
                showsAcknowledgments = true
            } label: {
                HStack(spacing: 12) {
                    Text(model.localized(.acknowledgmentsHint))
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(IOSTheme.secondaryText)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(accent)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var captionScaleBinding: Binding<Double> {
        Binding(
            get: { model.overlayStyle.overlayScaleFactor },
            set: { scale in
                model.updateOverlayStyle { style in
                    style.overlayScaleFactor = scale
                }
            }
        )
    }

    private var selectedAccent: CaptionAccentPreset {
        CaptionAccentPreset.closest(to: model.overlayStyle.subtitleColor)
    }

    private var currentInterfaceLanguageName: String {
        LanguageCatalog.interface
            .first(where: { $0.id == model.resolvedInterfaceLanguageID })?
            .localizedDisplayName(in: model.resolvedInterfaceLanguageID)
            ?? LanguageCatalog.displayName(
                for: model.resolvedInterfaceLanguageID,
                in: model.resolvedInterfaceLanguageID
            )
    }

    private func accentButton(_ preset: CaptionAccentPreset) -> some View {
        let isSelected = preset == selectedAccent
        return Button {
            model.updateOverlayStyle { style in
                style.subtitleColor = preset.overlayColor
            }
        } label: {
            VStack(spacing: 7) {
                ZStack {
                    Circle()
                        .fill(preset.color)
                        .frame(width: 27, height: 27)
                        .shadow(color: preset.color.opacity(0.32), radius: 7)

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(Color.black.opacity(0.74))
                    }
                }

                Text(model.localized(preset.localizationKey))
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.52))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? preset.color.opacity(0.10) : Color.white.opacity(0.035))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? preset.color.opacity(0.58) : Color.white.opacity(0.07), lineWidth: 0.75)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.localized(preset.localizationKey))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SettingsSectionCard<Content: View>: View {
    let title: String
    let symbol: String
    let accent: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text(title)
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.90))
            } icon: {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(accent)
            }

            content()
        }
        .padding(18)
        .premiumPanel(cornerRadius: 22)
    }
}

private struct AcknowledgmentsSheet: View {
    let title: String
    let doneTitle: String
    @Environment(\.dismiss) private var dismiss

    private static let fileNames = [
        "Easy2Say-MIT.txt",
        "NOTICE.txt",
        "THIRD_PARTY_NOTICES.txt",
        "Breeze-ASR-26.txt",
        "WhisperKit.txt",
        "Silero-VAD.txt",
        "OpenCC.txt",
    ]

    private var text: String {
        Self.fileNames.compactMap { fileName in
            guard let url = Bundle.main.url(
                forResource: fileName,
                withExtension: nil,
                subdirectory: "Acknowledgments"
            ),
            let body = try? String(contentsOf: url, encoding: .utf8) else {
                return nil
            }
            return "=== \(fileName) ===\n\n\(body)"
        }
        .joined(separator: "\n\n")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.78))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
            }
            .background(IOSTheme.canvas.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(doneTitle) { dismiss() }
                }
            }
        }
    }
}
