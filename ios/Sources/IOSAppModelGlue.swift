import AVFAudio
import Foundation

@MainActor
extension AppModel {
    var iOSSelectedMicrophoneSource: InputSource? {
        if let selectedSourceID,
           let selected = microphoneSources.first(where: { $0.id == selectedSourceID }) {
            return selected
        }

        if let selected = microphoneSources.first(where: { selectedSourceIDs.contains($0.id) }) {
            return selected
        }

        return microphoneSources.first
    }

    var iOSEffectiveInputLanguageID: String {
        guard let source = iOSSelectedMicrophoneSource else {
            return inputLanguageID
        }
        return languageID(for: source)
    }

    var iOSEffectiveOutputLanguageID: String {
        guard let source = iOSSelectedMicrophoneSource else {
            return outputLanguageID
        }
        return outputLanguageIDForSource(source)
    }

    var iOSCaptionAccentColor: OverlayColor {
        overlayStyle.subtitleColor
    }

    func selectIOSMicrophone(_ source: InputSource) {
        guard source.category == .microphone else { return }
        selectedSourceIDs = Set([source.id])
        selectedSourceID = source.id

        // Steer the live route immediately so picking a microphone works while a
        // session is already capturing. The resulting route change comes back
        // through handleAudioRouteChange, which re-syncs the selection to whatever
        // the system actually routed — the menu never shows an input that isn't
        // really capturing.
        let audioSession = AVAudioSession.sharedInstance()
        guard let port = audioSession.availableInputs?
            .first(where: { $0.uid == source.id }) else {
            return
        }
        try? audioSession.setPreferredInput(port)
    }

    func observeAudioRouteChanges() {
        guard audioRouteChangeObserver == nil else { return }
        audioRouteChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason = reasonValue.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            Task { @MainActor [weak self] in
                self?.handleAudioRouteChange(reason: reason)
            }
        }
    }

    func handleAudioRouteChange(reason: AVAudioSession.RouteChangeReason?) {
        // Newly attached hardware follows the system default even when an earlier
        // manual pick pinned another input; a pick only lasts for the connection
        // it was made in. Clearing the preference lets CarPlay or a headset take
        // the route the way it would in any other app.
        if reason == .newDeviceAvailable {
            try? AVAudioSession.sharedInstance().setPreferredInput(nil)
        }
        refreshSources()
        syncSelectionToCurrentAudioRoute()
    }

    /// Mirrors the selection to the input the system is actually routing from, so
    /// stale persisted picks never override a CarPlay or headset connection.
    func syncSelectionToCurrentAudioRoute() {
        guard let currentInputUID = AVAudioSession.sharedInstance()
            .currentRoute.inputs.first?.uid,
            microphoneSources.contains(where: { $0.id == currentInputUID }),
            selectedSourceIDs != [currentInputUID] else {
            return
        }
        selectedSourceIDs = [currentInputUID]
        selectedSourceID = currentInputUID
    }

    func setIOSInputLanguageID(_ languageID: String) {
        guard let source = iOSSelectedMicrophoneSource else {
            inputLanguageID = languageID
            return
        }
        setLanguageID(languageID, for: source)
    }

    func setIOSOutputLanguageID(_ languageID: String) {
        guard let source = iOSSelectedMicrophoneSource else {
            outputLanguageID = languageID
            return
        }
        setOutputLanguageID(languageID, for: source)
    }
}
