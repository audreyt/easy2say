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
