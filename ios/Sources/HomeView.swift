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
    @State private var microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)

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

    var body: some View {
        GeometryReader { geometry in
            let usesSideBySideCaptions = geometry.size.width > geometry.size.height

            ZStack {
                IOSTheme.background(accent: accent)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    HStack(alignment: .center, spacing: 12) {
                        BrandWordmark(accent: accent)

                        Spacer(minLength: 8)

                        PrivacyBadge(
                            title: model.localized(.iosPrivateBadge),
                            accent: accent
                        )
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

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
                                accent: accent,
                                refresh: model.refreshSources
                            )
                            .padding(24)
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    VStack(spacing: 10) {
                        if microphoneAccessDenied {
                            MicrophonePermissionCallout(
                                title: model.localized(.microphone),
                                message: model.localized(.microphonePermissionDenied),
                                settingsTitle: model.localized(.iosOpenSettings),
                                accent: accent,
                                openSettings: openSystemSettings
                            )
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }

                        ControlBar(
                            model: model,
                            isStartDisabled: isStartDisabled,
                            toggleSession: toggleSession,
                            showTranscript: { showsTranscript = true },
                            showSettings: { showsSettings = true }
                        )
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            }
        }
        .environment(\.locale, model.interfaceLocale)
        .tint(accent)
        .animation(.easeInOut(duration: 0.24), value: microphoneAccessDenied)
        .animation(.easeInOut(duration: 0.24), value: hasNoMicrophones)
        .onAppear {
            refreshMicrophoneAuthorization()
            model.refreshSources()
            updateIdleTimer(for: model.sessionState)
        }
        .onDisappear {
            #if canImport(UIKit)
            UIApplication.shared.isIdleTimerDisabled = false
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            refreshMicrophoneAuthorization()
            model.refreshSources()
        }
        .onChange(of: model.sessionState) { _, state in
            updateIdleTimer(for: state)
            refreshMicrophoneAuthorization()
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
        if model.sessionState == .running {
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

    private func updateIdleTimer(for state: SessionState) {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = state == .running
        #endif
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
                .foregroundStyle(Color.red.opacity(0.90))
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.red.opacity(0.10)))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.90))

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
                .foregroundStyle(Color.white.opacity(0.92))
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
