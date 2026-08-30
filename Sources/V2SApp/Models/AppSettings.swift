import Foundation

struct AppSettings: Codable {
    var selectedSourceID: String?
    var selectedSourceIDs: [String]
    var sourceLanguageOverrides: [String: String]
    var sourceOutputLanguageOverrides: [String: String]
    var inputLanguageID: String
    var outputLanguageID: String
    var conversationPrimaryLanguageID: String
    var conversationSecondaryLanguageID: String
    var conversationFaceToFace: Bool
    var conversationModeActive: Bool
    var interfaceLanguageID: String?
    var overlayStyle: OverlayStyle
    var subtitleMode: SubtitleMode
    var subtitleDisplayMode: SubtitleDisplayMode
    var glossary: [String: String]
    var customTranslationBaseURL: String
    var customTranslationModelID: String

    static let `default` = AppSettings(
        selectedSourceID: nil,
        selectedSourceIDs: [],
        sourceLanguageOverrides: [:],
        sourceOutputLanguageOverrides: [:],
        inputLanguageID: "en",
        outputLanguageID: "zh-Hant",
        conversationPrimaryLanguageID: "zh-Hant",
        conversationSecondaryLanguageID: "en",
        conversationFaceToFace: true,
        conversationModeActive: false,
        interfaceLanguageID: nil,
        overlayStyle: .default,
        subtitleMode: .balanced,
        subtitleDisplayMode: .both,
        glossary: [:],
        customTranslationBaseURL: "",
        customTranslationModelID: ""
    )

    // Custom decoder so existing settings files load cleanly as new fields are added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selectedSourceID = try? c.decodeIfPresent(String.self, forKey: .selectedSourceID)
        selectedSourceIDs = (try? c.decodeIfPresent([String].self, forKey: .selectedSourceIDs))
            ?? selectedSourceID.map { [$0] }
            ?? AppSettings.default.selectedSourceIDs
        sourceLanguageOverrides = (try? c.decodeIfPresent([String: String].self, forKey: .sourceLanguageOverrides))
            ?? AppSettings.default.sourceLanguageOverrides
        sourceOutputLanguageOverrides = (try? c.decodeIfPresent([String: String].self, forKey: .sourceOutputLanguageOverrides))
            ?? AppSettings.default.sourceOutputLanguageOverrides
        inputLanguageID = (try? c.decodeIfPresent(String.self, forKey: .inputLanguageID))
            ?? AppSettings.default.inputLanguageID
        outputLanguageID = (try? c.decodeIfPresent(String.self, forKey: .outputLanguageID))
            ?? AppSettings.default.outputLanguageID
        conversationPrimaryLanguageID = (try? c.decodeIfPresent(String.self, forKey: .conversationPrimaryLanguageID))
            ?? AppSettings.default.conversationPrimaryLanguageID
        conversationSecondaryLanguageID = (try? c.decodeIfPresent(String.self, forKey: .conversationSecondaryLanguageID))
            ?? AppSettings.default.conversationSecondaryLanguageID
        conversationFaceToFace = (try? c.decodeIfPresent(Bool.self, forKey: .conversationFaceToFace))
            ?? AppSettings.default.conversationFaceToFace
        conversationModeActive = (try? c.decodeIfPresent(Bool.self, forKey: .conversationModeActive))
            ?? AppSettings.default.conversationModeActive
        interfaceLanguageID = try? c.decodeIfPresent(String.self, forKey: .interfaceLanguageID)
        overlayStyle = (try? c.decodeIfPresent(OverlayStyle.self, forKey: .overlayStyle))
            ?? AppSettings.default.overlayStyle
        subtitleMode = (try? c.decodeIfPresent(SubtitleMode.self, forKey: .subtitleMode))
            ?? AppSettings.default.subtitleMode
        subtitleDisplayMode = (try? c.decodeIfPresent(SubtitleDisplayMode.self, forKey: .subtitleDisplayMode))
            ?? AppSettings.default.subtitleDisplayMode
        glossary = (try? c.decodeIfPresent([String: String].self, forKey: .glossary))
            ?? AppSettings.default.glossary
        customTranslationBaseURL = (try? c.decodeIfPresent(
            String.self,
            forKey: .customTranslationBaseURL
        )) ?? AppSettings.default.customTranslationBaseURL
        customTranslationModelID = (try? c.decodeIfPresent(
            String.self,
            forKey: .customTranslationModelID
        )) ?? AppSettings.default.customTranslationModelID
    }

    init(
        selectedSourceID: String?,
        selectedSourceIDs: [String] = [],
        sourceLanguageOverrides: [String: String] = [:],
        sourceOutputLanguageOverrides: [String: String] = [:],
        inputLanguageID: String,
        outputLanguageID: String,
        conversationPrimaryLanguageID: String = "zh-Hant",
        conversationSecondaryLanguageID: String = "en",
        conversationFaceToFace: Bool = true,
        conversationModeActive: Bool = false,
        interfaceLanguageID: String?,
        overlayStyle: OverlayStyle,
        subtitleMode: SubtitleMode,
        subtitleDisplayMode: SubtitleDisplayMode,
        glossary: [String: String],
        customTranslationBaseURL: String = "",
        customTranslationModelID: String = ""
    ) {
        self.selectedSourceID = selectedSourceID
        self.selectedSourceIDs = selectedSourceIDs
        self.sourceLanguageOverrides = sourceLanguageOverrides
        self.sourceOutputLanguageOverrides = sourceOutputLanguageOverrides
        self.inputLanguageID  = inputLanguageID
        self.outputLanguageID = outputLanguageID
        self.conversationPrimaryLanguageID = conversationPrimaryLanguageID
        self.conversationSecondaryLanguageID = conversationSecondaryLanguageID
        self.conversationFaceToFace = conversationFaceToFace
        self.conversationModeActive = conversationModeActive
        self.interfaceLanguageID = interfaceLanguageID
        self.overlayStyle     = overlayStyle
        self.subtitleMode     = subtitleMode
        self.subtitleDisplayMode = subtitleDisplayMode
        self.glossary         = glossary
        self.customTranslationBaseURL = customTranslationBaseURL
        self.customTranslationModelID = customTranslationModelID
    }
}

extension AppSettings {
    /// First launch only. Hans as the *primary* system language gets en↔zh-Hans.
    /// English-primary (even with Hans in the fallback list) keeps en↔zh-Hant.
    static func seeded(primaryLanguage: String = Locale.preferredLanguages.first ?? "en") -> AppSettings {
        var settings = AppSettings.default
        guard prefersSimplifiedChinese(primaryLanguage) else { return settings }
        settings.inputLanguageID = "en"
        settings.outputLanguageID = "zh-Hans"
        settings.conversationPrimaryLanguageID = "zh-Hans"
        settings.conversationSecondaryLanguageID = "en"
        return settings
    }

    static func prefersSimplifiedChinese(_ tag: String) -> Bool {
        let lowered = tag.replacingOccurrences(of: "_", with: "-").lowercased()
        return lowered.hasPrefix("zh-hans")
            || lowered.hasPrefix("zh-cn")
            || lowered.hasPrefix("zh-sg")
    }
}
