import AVFoundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct HomeView: View {
    @ObservedObject var model: AppModel

    @Environment(\.scenePhase) private var scenePhase

    @State private var showsTranscript = false
    @State private var showsSettings = false
    @State private var isFullscreen = false
    @State private var showsFullscreenChrome = true
    @State private var fullscreenHideTask: Task<Void, Never>? = nil
    @State private var microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
    // The engine lives here so both of its `.translationTask` hosts stay attached
    // to the live view tree for the whole session, not just while the
    // conversation surface is on screen.
    @StateObject private var conversation = ConversationEngine()

    private var accent: Color {
        IOSTheme.color(model.iOSCaptionAccentColor)
    }

    private var microphoneAccessDenied: Bool {
        microphoneAuthorization == .denied || microphoneAuthorization == .restricted
    }

    private var hasNoMicrophones: Bool {
        model.microphoneSources.isEmpty
    }

    private var isStartDisabled: Bool {
        guard model.sessionState != .running else { return false }
        return hasNoMicrophones || microphoneAccessDenied || model.isSessionButtonDisabled
    }

    private var isConversationStartDisabled: Bool {
        guard conversation.isRunning == false else { return false }
        return hasNoMicrophones || microphoneAccessDenied
    }


    var body: some View {
        GeometryReader { geometry in
            let usesSideBySideCaptions = geometry.size.width > geometry.size.height

            ZStack {
                IOSTheme.background(accent: accent)
                    .ignoresSafeArea()

                if isFullscreen {
                    fullscreenView(isHorizontal: usesSideBySideCaptions)
                        .transition(.opacity)
                } else {
                    VStack(spacing: 0) {
                        if model.isConversationModeActive {
                            ConversationView(
                                model: model,
                                engine: conversation,
                                isStartDisabled: isConversationStartDisabled,
                                toggleSession: toggleConversation,
                                showSettings: { showsSettings = true },
                                showCaptions: { setConversationMode(false) }
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            ZStack {
                                CaptionHalves(
                                    model: model,
                                    isHorizontal: usesSideBySideCaptions
                                )

                                if hasNoMicrophones && microphoneAccessDenied == false {
                                    NoMicrophoneCard(
                                        title: model.localized(.iosNoMicrophonesTitle),
                                        message: model.localized(.iosNoMicrophonesMessage),
                                        refreshTitle: model.localized(.refreshSources),
                                        accent: IOSTheme.brand,
                                        refresh: model.refreshSources
                                    )
                                    .padding(24)
                                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }

                        VStack(spacing: 10) {
                            if microphoneAccessDenied {
                                MicrophonePermissionCallout(
                                    title: model.localized(.microphone),
                                    message: model.localized(.microphonePermissionDenied),
                                    settingsTitle: model.localized(.iosOpenSettings),
                                    accent: IOSTheme.brand,
                                    openSettings: openSystemSettings
                                )
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                            }

                            if model.isConversationModeActive == false {
                                ControlBar(
                                    model: model,
                                    isStartDisabled: isStartDisabled,
                                    toggleSession: toggleSession,
                                    showTranscript: { showsTranscript = true },
                                    showSettings: { showsSettings = true },
                                    showFullscreen: enterFullscreen,
                                    selectConversationMode: setConversationMode
                                )
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 14)
                    }
                    .transition(.opacity)
                }
            }
        }
        .v2sConversationTranslationHost(engine: conversation)
        .environment(\.locale, model.interfaceLocale)
        .tint(IOSTheme.brand)
        .statusBarHidden(isFullscreen)
        .persistentSystemOverlays(isFullscreen ? .hidden : .automatic)
        .animation(.easeInOut(duration: 0.28), value: isFullscreen)
        .animation(.easeInOut(duration: 0.24), value: microphoneAccessDenied)
        .animation(.easeInOut(duration: 0.24), value: hasNoMicrophones)
        .onAppear {
            refreshMicrophoneAuthorization()
            model.refreshSources()
            model.installTranslationBackends(on: conversation)
            updateIdleTimer()
        }
        .onDisappear {
            fullscreenHideTask?.cancel()
            #if canImport(UIKit)
            UIApplication.shared.isIdleTimerDisabled = false
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            refreshMicrophoneAuthorization()
            model.refreshSources()
        }
        .onChange(of: model.sessionState) { _, _ in
            updateIdleTimer()
            refreshMicrophoneAuthorization()
        }
        .onChange(of: conversation.phase) { _, _ in
            updateIdleTimer()
        }
        .onChange(of: isFullscreen) { _, _ in
            updateIdleTimer()
        }
        .onChange(of: model.isConversationModeActive) { _, isActive in
            if isActive && isFullscreen {
                exitFullscreen()
            }
        }
        .onChange(of: model.conversationPrimaryLanguageID) { _, _ in
            restartConversationIfRunning()
        }
        .onChange(of: model.conversationSecondaryLanguageID) { _, _ in
            restartConversationIfRunning()
        }
        .onChange(of: model.transcriptEntries.count) { oldCount, newCount in
            guard newCount > oldCount, model.sessionState == .running else { return }
            #if canImport(UIKit)
            UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.72)
            #endif
        }
        .sheet(isPresented: $showsTranscript) {
            TranscriptSheet(model: model)
        }
        .sheet(isPresented: $showsSettings) {
            SettingsSheet(model: model)
        }
    }

    private func toggleSession() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.72)
        #endif
        if model.sessionState == .running || model.isSessionStarting {
            model.stopSession()
            return
        }

        guard hasNoMicrophones == false else { return }

        Task { @MainActor in
            guard await ensureMicrophoneAccess() else { return }
            await model.startSession()
            refreshMicrophoneAuthorization()
        }
    }

    /// One microphone cannot serve two capture graphs, so switching modes always
    /// stops whatever is currently listening.
    private func setConversationMode(_ isActive: Bool) {
        guard model.isConversationModeActive != isActive else { return }
        #if canImport(UIKit)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif

        if isActive {
            if model.sessionState == .running || model.isSessionStarting {
                model.stopSession()
            }
        } else if conversation.isRunning {
            conversation.stop()
        }

        model.isConversationModeActive = isActive
    }

    private func toggleConversation() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.72)
        #endif
        if conversation.isRunning {
            conversation.stop()
            return
        }

        startConversation()
    }

    /// A language change mid-conversation has to rebuild both transcriber lanes, so
    /// restart rather than leaving the new selection silently inert until next time.
    private func restartConversationIfRunning() {
        guard conversation.isRunning else { return }
        conversation.stop()
        startConversation()
    }

    private func startConversation() {
        guard hasNoMicrophones == false else { return }

        if model.sessionState == .running || model.isSessionStarting {
            model.stopSession()
        }

        Task { @MainActor in
            guard await ensureMicrophoneAccess() else { return }
            conversation.interfaceLanguageID = model.resolvedInterfaceLanguageID
            conversation.configure(
                primaryLanguageID: model.conversationPrimaryLanguageID,
                secondaryLanguageID: model.conversationSecondaryLanguageID
            )
            model.applySpeechSupport(to: conversation)
            await conversation.start()
            refreshMicrophoneAuthorization()
        }
    }

    @MainActor
    private func ensureMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneAuthorization = .authorized
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
            return granted
        case .denied, .restricted:
            microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
            return false
        @unknown default:
            microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
            return false
        }
    }

    private func refreshMicrophoneAuthorization() {
        microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    private func updateIdleTimer() {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled =
            model.sessionState == .running
            || model.isSessionStarting
            || conversation.isRunning
            || isFullscreen
        #endif
    }

    private func enterFullscreen() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.72)
        #endif
        withAnimation(.easeInOut(duration: 0.28)) {
            isFullscreen = true
            showsFullscreenChrome = true
        }
        scheduleFullscreenChromeAutoHide()
        updateIdleTimer()
    }

    private func exitFullscreen() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.72)
        #endif
        fullscreenHideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.28)) {
            isFullscreen = false
        }
        updateIdleTimer()
    }

    private func toggleFullscreenChrome() {
        #if canImport(UIKit)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
        withAnimation(.easeInOut(duration: 0.22)) {
            showsFullscreenChrome.toggle()
        }
        if showsFullscreenChrome {
            scheduleFullscreenChromeAutoHide()
        } else {
            fullscreenHideTask?.cancel()
        }
    }

    private func scheduleFullscreenChromeAutoHide() {
        fullscreenHideTask?.cancel()
        fullscreenHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.28)) {
                showsFullscreenChrome = false
            }
        }
    }

    @ViewBuilder
    private func fullscreenView(isHorizontal: Bool) -> some View {
        ZStack {
            CaptionHalves(
                model: model,
                isHorizontal: isHorizontal
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                toggleFullscreenChrome()
            }

            if showsFullscreenChrome || UIAccessibility.isVoiceOverRunning {
                VStack(spacing: 0) {
                    HStack {
                        Spacer()

                        Button(action: exitFullscreen) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.down.right.and.arrow.up.left")
                                    .font(.system(size: 13, weight: .semibold))
                                    .accessibilityHidden(true)
                                Text(model.localized(.iosExitFullscreen))
                                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                            }
                            .foregroundStyle(IOSTheme.primaryText.opacity(0.92))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(IOSTheme.elevated.opacity(0.88))
                            )
                            .overlay {
                                Capsule(style: .continuous)
                                    .stroke(IOSTheme.hairline, lineWidth: 0.5)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(model.localized(.iosExitFullscreen))
                        .accessibilityIdentifier("exit-fullscreen-button")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    Spacer()

                    HStack {
                        Spacer()
                        SessionCapsuleButton(
                            title: model.sessionButtonTitle,
                            isLive: model.sessionState == .running,
                            showsActivity: model.showsSessionWaitIndicator,
                            isDisabled: isStartDisabled,
                            accent: accent,
                            action: toggleSession
                        )
                        Spacer()
                    }
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .animation(.easeInOut(duration: 0.24), value: showsFullscreenChrome)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityAction(named: model.localized(.iosExitFullscreen)) {
            exitFullscreen()
        }
    }

    private func openSystemSettings() {
        #if canImport(UIKit)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #endif
    }
}

private struct MicrophonePermissionCallout: View {
    let title: String
    let message: String
    let settingsTitle: String
    let accent: Color
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(IOSTheme.alert)
                .frame(width: 34, height: 34)
                .background(Circle().fill(IOSTheme.alert.opacity(0.12)))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(IOSTheme.primaryText.opacity(0.92))

                Text(message)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(IOSTheme.secondaryText)
                    .lineLimit(2)
            }

            Spacer(minLength: 6)

            Button(settingsTitle, action: openSettings)
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .buttonStyle(.bordered)
                .tint(accent)
        }
        .padding(12)
        .premiumPanel(cornerRadius: 19)
    }
}

private struct NoMicrophoneCard: View {
    let title: String
    let message: String
    let refreshTitle: String
    let accent: Color
    let refresh: () -> Void

    var body: some View {
        VStack(spacing: 13) {
            Image(systemName: "mic.slash")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(accent.opacity(0.62))
                .accessibilityHidden(true)

            Text(title)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(IOSTheme.primaryText.opacity(0.94))
                .multilineTextAlignment(.center)

            Text(message)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(IOSTheme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: refresh) {
                Label(refreshTitle, systemImage: "arrow.clockwise")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 38)
            }
            .buttonStyle(.bordered)
            .tint(accent)
        }
        .padding(22)
        .frame(maxWidth: 390)
        .premiumPanel(cornerRadius: 24)
    }
}
