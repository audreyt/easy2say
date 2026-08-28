import AppKit
import SwiftUI

struct StatusBarPopoverView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: AppModel
    let closePopover: () -> Void
    let openAdvancedSettings: () -> Void
    let showTranscript: () -> Void
    let quitApp: () -> Void

    private var isLive: Bool {
        model.sessionState == .running
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider().padding(.horizontal, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    sourceSection
                    languageSection
                    overlaySection
                }
                .padding(16)
            }
            Divider().padding(.horizontal, 16)
            footerSection
        }
        .frame(width: 340)
        .background(.regularMaterial)
        .environment(\.locale, model.interfaceLocale)
        .v2sTranslationHost(model: model)
        .onChange(of: model.sessionState) { _, newState in
            if newState == .running {
                closePopover()
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                BrandMarkBadge(size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: "Easy2say")
                        .font(.headline)
                    Text(model.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    VersionLink(
                        versionText: model.appVersionDisplayText,
                        repositoryURL: model.appRepositoryURL,
                        font: .caption2.monospacedDigit()
                    )
                    Text(model.sessionBadgeText)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(isLive ? EasyBrand.plum : Color.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background {
                            if isLive {
                                Capsule().fill(EasyBrand.peach)
                            } else {
                                Capsule().fill(.fill.tertiary)
                            }
                        }
                }
            }
            Button {
                model.toggleSession()
            } label: {
                SessionActionButtonLabel(
                    title: model.sessionButtonTitle,
                    symbolName: model.sessionButtonSymbolName,
                    showsActivity: model.showsSessionWaitIndicator
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isSessionButtonDisabled)
        }
        .tint(EasyBrand.controlTint(for: colorScheme))
        .padding(16)
    }

    // MARK: - Input Source

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(model.localized(.inputSource), icon: "mic.fill")
            SettingsControlRow(label: model.localized(.sourceShort)) {
                SourceMultiSelectPicker(
                    sources: model.allSources,
                    interfaceLanguageID: model.resolvedInterfaceLanguageID,
                    emptyTitle: model.allSources.isEmpty ? model.localized(.noSources) : model.localized(.choose),
                    selection: model.selectedSourcesBinding
                )
            }
            SecondaryRefreshButton(
                title: model.localized(.refreshSources),
                action: model.refreshSources
            )
        }
    }

    // MARK: - Languages

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(model.localized(.languages), icon: "globe")
            SettingsControlRow(label: model.localized(.defaultInputLanguage)) {
                CommonLanguageMenuPicker(
                    interfaceLanguageID: model.resolvedInterfaceLanguageID,
                    options: model.speechLanguageOptions,
                    selection: model.inputLanguageSelectionBinding
                )
                .disabled(model.isLanguagePairLocked)
            }
            if let notice = model.serverSpeechRecognitionNotice {
                Label(notice, systemImage: "icloud")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingsControlRow(label: model.localized(.defaultSubtitleLanguage)) {
                CommonLanguageMenuPicker(
                    interfaceLanguageID: model.resolvedInterfaceLanguageID,
                    options: model.translationLanguageOptions,
                    selection: model.outputLanguageSelectionBinding
                )
                .disabled(
                    model.isLanguagePairLocked
                        || model.inputLanguageID == "nan"
                )
            }
            SettingsControlRow(label: model.localized(.modeShort)) {
                SubtitleModeMenuPicker(
                    interfaceLanguageID: model.resolvedInterfaceLanguageID,
                    showsDetail: false,
                    selection: model.subtitleModeSelectionBinding
                )
            }
            SettingsControlRow(label: model.localized(.displayShort)) {
                SubtitleDisplayModeMenuPicker(
                    interfaceLanguageID: model.resolvedInterfaceLanguageID,
                    selection: model.subtitleDisplayModeSelectionBinding
                )
            }
            LanguageResourcesFooter(model: model)
        }
    }

    // MARK: - Overlay

    private var overlaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader(model.localized(.overlay), icon: "rectangle.on.rectangle")
                Spacer()
                Button {
                    showTranscript()
                } label: {
                    Text(model.localized(.transcript))
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button {
                    if model.isOverlayVisible { model.toggleOverlayVisibility() }
                    else { model.showOverlayPreview() }
                } label: {
                    Text(model.isOverlayVisible ? model.localized(.hideOverlay) : model.localized(.showPreview))
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            SettingsControlRow(label: model.localized(.captionLayout)) {
                CaptionLayoutMenuPicker(
                    interfaceLanguageID: model.resolvedInterfaceLanguageID,
                    selection: model.overlayCaptionLayoutSelectionBinding
                )
            }
            SettingsControlRow(label: model.localized(.audienceDisplay)) {
                Button {
                    model.toggleAudienceDisplayVisibility()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: model.isAudienceDisplayVisible ? "tv.fill" : "tv")
                        Text(model.isAudienceDisplayVisible ? model.localized(.hideAudienceDisplay) : model.localized(.showAudienceDisplay))
                    }
                    .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            VStack(spacing: 6) {
                SettingsControlRow(label: model.localized(.textOutline)) {
                    Toggle("", isOn: textOutlineEnabledBinding)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
                SettingsControlRow(label: model.localized(.attachToSource)) {
                    Toggle("", isOn: attachToSourceBinding)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
            }
            VStack(spacing: 8) {
                compactSlider(
                    label: model.localized(.opacity),
                    value: overlayOpacityBinding, in: 0.0 ... 1.0,
                    display: "\(Int((model.overlayStyle.backgroundOpacity * 100).rounded()))%"
                )
                compactSlider(
                    label: model.localized(.fontSize),
                    value: translatedFontBinding, in: 8 ... 34,
                    display: "\(Int(model.overlayStyle.translatedFontSize.rounded()))pt"
                )
                compactSlider(
                    label: model.localized(.sourceSize),
                    value: sourceFontBinding, in: 5 ... 28,
                    display: "\(Int(model.overlayStyle.sourceFontSize.rounded()))pt"
                )
            }
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button { openAdvancedSettings() } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(model.localized(.advancedSettings))
            Button { quitApp() } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(model.localized(.quit))
            .help(model.localized(.quit))
            Spacer()
            if model.selectedSources.isEmpty == false {
                Text(model.selectedSourceDisplayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Layout helpers

    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
    }

    private func compactSlider(
        label: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        display: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(display)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
                .controlSize(.small)
        }
    }

    // MARK: - Bindings

    private var overlayOpacityBinding: Binding<Double> {
        Binding(
            get: { model.overlayStyle.backgroundOpacity },
            set: { v in model.updateOverlayStyle { $0.backgroundOpacity = v } }
        )
    }
    private var translatedFontBinding: Binding<Double> {
        Binding(
            get: { model.overlayStyle.translatedFontSize },
            set: { v in model.updateOverlayStyle { $0.translatedFontSize = v } }
        )
    }
    private var textOutlineEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.overlayStyle.showsTextOutline },
            set: { v in model.updateOverlayStyle { $0.showsTextOutline = v } }
        )
    }
    private var attachToSourceBinding: Binding<Bool> {
        Binding(
            get: { model.overlayStyle.attachToSource },
            set: { v in model.updateOverlayStyle { $0.attachToSource = v } }
        )
    }
    private var sourceFontBinding: Binding<Double> {
        Binding(
            get: { model.overlayStyle.sourceFontSize },
            set: { v in model.updateOverlayStyle { $0.sourceFontSize = v } }
        )
    }
}

/// The shipped app icon, reused as the brand chip so the menu-bar UI and the Dock
/// show one paired-voice mark rather than two drawings of it.
struct BrandMarkBadge: View {
    let size: CGFloat

    var body: some View {
        Group {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else {
                EasyBrand.plum
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct VersionLink: View {
    @Environment(\.openURL) private var openURL

    let versionText: String
    let repositoryURL: URL?
    let font: Font

    var body: some View {
        Group {
            if let repositoryURL {
                Button {
                    openURL(repositoryURL)
                } label: {
                    versionLabel
                }
                .buttonStyle(.plain)
                .help(repositoryURL.absoluteString)
            } else {
                versionLabel
                    .help(versionText)
            }
        }
    }

    private var versionLabel: some View {
        Text(verbatim: versionText)
            .font(font)
            .foregroundStyle(.secondary)
    }
}
