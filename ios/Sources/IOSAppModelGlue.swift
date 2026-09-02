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

        // Steer the live route immediately so picking a microphone works while a
        // session is already capturing. The resulting route change comes back
        // through handleAudioRouteChange, which re-syncs the selection to whatever
        // the system actually routed — the menu never shows an input that isn't
        // really capturing.
        let audioSession = AVAudioSession.sharedInstance()
        guard let port = audioSession.availableInputs?
            .first(where: { $0.uid == source.id }) else {
            refreshSources()
            syncSelectionToCurrentAudioRoute()
            return
        }
        do {
            try IOSAudioSessionConfigurator.applyRecordCategory()
            try audioSession.setPreferredInput(port)
            selectedSourceIDs = Set([source.id])
            selectedSourceID = source.id
        } catch {
            // Do not leave the checkmark on a route the system rejected.
            refreshSources()
            syncSelectionToCurrentAudioRoute()
        }
    }

    func applyIOSSelectedMicrophonePreference() {
        guard let source = iOSSelectedMicrophoneSource else { return }
        selectIOSMicrophone(source)
    }

    func observeAudioRouteChanges() {
        guard audioRouteObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let routeObserver = center.addObserver(
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
        let inputsObserver = center.addObserver(
            forName: AVAudioSession.availableInputsChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleAvailableAudioInputsChange()
            }
        }
        audioRouteObservers = [routeObserver, inputsObserver]
    }

    func handleAudioRouteChange(reason: AVAudioSession.RouteChangeReason?) {
        // Newly attached hardware follows the system default even when an earlier
        // manual pick pinned another input; a pick only lasts for the connection
        // it was made in. Clearing the preference lets CarPlay or a headset take
        // the route the way it would in any other app.
        if reason == .newDeviceAvailable {
            let previousSourceIDs = Set(microphoneSources.map(\.id))
            try? AVAudioSession.sharedInstance().setPreferredInput(nil)
            refreshSources()
            let addedSources = microphoneSources.filter {
                previousSourceIDs.contains($0.id) == false
            }
            if addedSources.count == 1, let addedSource = addedSources.first {
                setIOSSelectedMicrophoneID(addedSource.id)
            } else if addedSources.isEmpty == false {
                syncSelectionToCurrentAudioRoute()
            }
            return
        }
        refreshSources()
        syncSelectionToCurrentAudioRoute()
    }

    func handleAvailableAudioInputsChange() {
        let previousSourceIDs = Set(microphoneSources.map(\.id))
        refreshSources()

        // A preferred built-in mic can keep the current route unchanged when new
        // hardware appears. In that case routeChangeNotification alone is not enough
        // to implement "newly connected devices are used automatically". Clear the
        // old preference and retain the sole newly exposed port as the startup choice
        // even while the audio session is inactive and currentRoute has no input yet.
        let addedSources = microphoneSources.filter { previousSourceIDs.contains($0.id) == false }
        guard addedSources.isEmpty == false else { return }
        try? AVAudioSession.sharedInstance().setPreferredInput(nil)

        if addedSources.count == 1, let addedSource = addedSources.first {
            setIOSSelectedMicrophoneID(addedSource.id)
        } else {
            syncSelectionToCurrentAudioRoute()
        }
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
        setIOSSelectedMicrophoneID(currentInputUID)
    }

    private func setIOSSelectedMicrophoneID(_ sourceID: String) {
        selectedSourceIDs = [sourceID]
        selectedSourceID = sourceID
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
