import Foundation
import XCTest
@testable import v2s

final class AppSettingsTests: XCTestCase {
    func testLegacySingleSourceSettingsDecodeIntoMultiSourceFields() throws {
        let json = """
        {
          "selectedSourceID": "mic-1",
          "inputLanguageID": "en",
          "outputLanguageID": "ja",
          "overlayStyle": {
            "translatedFontSize": 20,
            "sourceFontSize": 16,
            "backgroundOpacity": 0.7,
            "subtitleColor": { "kind": "defaultSubtitle" },
            "textColor": { "kind": "defaultText" },
            "backgroundColor": { "kind": "defaultBackground" },
            "showsTextOutline": true,
            "textOutlineColor": { "kind": "defaultTextOutline" },
            "attachToSource": true,
            "translatedFirst": true
          },
          "subtitleMode": "balanced",
          "subtitleDisplayMode": "both",
          "glossary": {}
        }
        """

        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        XCTAssertEqual(settings.selectedSourceID, "mic-1")
        XCTAssertEqual(settings.selectedSourceIDs, ["mic-1"])
        XCTAssertTrue(settings.sourceLanguageOverrides.isEmpty)
        XCTAssertTrue(settings.sourceOutputLanguageOverrides.isEmpty)
    }

    func testMultiSourceSettingsRoundTripPreservesOverrides() throws {
        let settings = AppSettings(
            selectedSourceID: "mic-1",
            selectedSourceIDs: ["mic-1", "app-1"],
            sourceLanguageOverrides: ["app-1": "fr"],
            sourceOutputLanguageOverrides: ["mic-1": "zh-Hans", "app-1": "de"],
            inputLanguageID: "en",
            outputLanguageID: "ja",
            interfaceLanguageID: "en",
            overlayStyle: .default,
            subtitleMode: .balanced,
            subtitleDisplayMode: .both,
            glossary: ["CEO": "Chief Executive Officer"]
        )

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.selectedSourceID, "mic-1")
        XCTAssertEqual(decoded.selectedSourceIDs, ["mic-1", "app-1"])
        XCTAssertEqual(decoded.sourceLanguageOverrides, ["app-1": "fr"])
        XCTAssertEqual(
            decoded.sourceOutputLanguageOverrides,
            ["mic-1": "zh-Hans", "app-1": "de"]
        )
        XCTAssertEqual(decoded.inputLanguageID, "en")
        XCTAssertEqual(decoded.outputLanguageID, "ja")
        XCTAssertEqual(decoded.interfaceLanguageID, "en")
        XCTAssertEqual(decoded.glossary, ["CEO": "Chief Executive Officer"])
    }

    func testConversationSettingsDefaultForLegacyFiles() throws {
        let data = try JSONEncoder().encode(AppSettings.default)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "conversationPrimaryLanguageID")
        object.removeValue(forKey: "conversationSecondaryLanguageID")
        object.removeValue(forKey: "conversationFaceToFace")
        object.removeValue(forKey: "conversationModeActive")

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyData)

        XCTAssertEqual(decoded.conversationPrimaryLanguageID, "zh-Hant")
        XCTAssertEqual(decoded.conversationSecondaryLanguageID, "en")
        XCTAssertTrue(decoded.conversationFaceToFace)
        XCTAssertFalse(decoded.conversationModeActive)
    }

    func testConversationSettingsSurviveRoundTrip() throws {
        var settings = AppSettings.default
        settings.conversationPrimaryLanguageID = "ja"
        settings.conversationSecondaryLanguageID = "fr"
        settings.conversationFaceToFace = false
        settings.conversationModeActive = true

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.conversationPrimaryLanguageID, "ja")
        XCTAssertEqual(decoded.conversationSecondaryLanguageID, "fr")
        XCTAssertFalse(decoded.conversationFaceToFace)
        XCTAssertTrue(decoded.conversationModeActive)
    }

    func testInvisibleInRecordingDefaultsToOffForSettingsSavedBeforeTheToggleExisted() throws {
        let json = """
        {
          "selectedSourceID": "mic-1",
          "inputLanguageID": "en",
          "outputLanguageID": "ja",
          "overlayStyle": {
            "translatedFontSize": 20,
            "sourceFontSize": 16,
            "backgroundOpacity": 0.7,
            "topInset": 12,
            "widthRatio": 0.82,
            "minWidth": 720,
            "maxWidth": 1440,
            "clickThrough": true,
            "translatedFirst": true
          },
          "subtitleMode": "balanced",
          "subtitleDisplayMode": "both",
          "glossary": {}
        }
        """

        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        XCTAssertFalse(settings.overlayStyle.invisibleInRecording)
    }

    func testInvisibleInRecordingSurvivesAnEncodeDecodeRoundTrip() throws {
        var style = OverlayStyle.default
        style.invisibleInRecording = true

        let data = try JSONEncoder().encode(style)
        let decoded = try JSONDecoder().decode(OverlayStyle.self, from: data)

        XCTAssertTrue(decoded.invisibleInRecording)
    }

    func testCaptionLayoutPreservesLegacyTranslationFirstOrder() throws {
        let data = try JSONEncoder().encode(OverlayStyle.default)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "captionLayout")

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(OverlayStyle.self, from: legacyData)

        XCTAssertEqual(decoded.captionLayout, .topDown)
    }

    func testCaptionLayoutPreservesLegacyOriginalFirstOrder() throws {
        var style = OverlayStyle.default
        style.translatedFirst = false
        let data = try JSONEncoder().encode(style)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "captionLayout")

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(OverlayStyle.self, from: legacyData)

        XCTAssertEqual(decoded.captionLayout, .bottomUp)
    }

    func testEveryCaptionLayoutSurvivesRoundTrip() throws {
        for layout in OverlayCaptionLayout.allCases {
            var style = OverlayStyle.default
            style.captionLayout = layout

            let data = try JSONEncoder().encode(style)
            let decoded = try JSONDecoder().decode(OverlayStyle.self, from: data)

            XCTAssertEqual(decoded.captionLayout, layout)
        }
    }

    func testCaptionLayoutDirectionsMapToAxesAndLeadingLanguage() {
        XCTAssertFalse(OverlayCaptionLayout.topDown.usesColumns)
        XCTAssertTrue(OverlayCaptionLayout.topDown.leadsWithTranslation)
        XCTAssertFalse(OverlayCaptionLayout.bottomUp.usesColumns)
        XCTAssertFalse(OverlayCaptionLayout.bottomUp.leadsWithTranslation)
        XCTAssertTrue(OverlayCaptionLayout.leftToRight.usesColumns)
        XCTAssertTrue(OverlayCaptionLayout.leftToRight.leadsWithTranslation)
        XCTAssertTrue(OverlayCaptionLayout.rightToLeft.usesColumns)
        XCTAssertFalse(OverlayCaptionLayout.rightToLeft.leadsWithTranslation)
    }

    func testHansPrimarySeedsEnglishHansPair() {
        let settings = AppSettings.seeded(primaryLanguage: "zh-Hans-CN")

        XCTAssertEqual(settings.inputLanguageID, "en")
        XCTAssertEqual(settings.outputLanguageID, "zh-Hans")
        XCTAssertEqual(settings.conversationPrimaryLanguageID, "zh-Hans")
        XCTAssertEqual(settings.conversationSecondaryLanguageID, "en")
    }

    func testEnglishPrimaryKeepsTraditionalDefault() {
        let settings = AppSettings.seeded(primaryLanguage: "en-US")

        XCTAssertEqual(settings.inputLanguageID, "en")
        XCTAssertEqual(settings.outputLanguageID, "zh-Hant")
        XCTAssertEqual(settings.conversationPrimaryLanguageID, "zh-Hant")
        XCTAssertEqual(settings.conversationSecondaryLanguageID, "en")
    }

    func testHansFallbackDoesNotOverrideEnglishPrimary() {
        XCTAssertFalse(AppSettings.prefersSimplifiedChinese("en-US"))
        XCTAssertTrue(AppSettings.prefersSimplifiedChinese("zh-CN"))
    }

    func testCustomTranslationSettingsDefaultForLegacyFiles() throws {
        let data = try JSONEncoder().encode(AppSettings.default)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "customTranslationBaseURL")
        object.removeValue(forKey: "customTranslationModelID")

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyData)

        XCTAssertEqual(decoded.customTranslationBaseURL, "")
        XCTAssertEqual(decoded.customTranslationModelID, "")
    }

    func testCustomTranslationSettingsSurviveRoundTrip() throws {
        var settings = AppSettings.default
        settings.customTranslationBaseURL = "http://127.0.0.1:8001/v1"
        settings.customTranslationModelID = "Thomson-1.0-Small"

        let data = try JSONEncoder().encode(settings)
        let encodedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNil(encodedObject["customTranslationAPIKey"])
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.customTranslationBaseURL, "http://127.0.0.1:8001/v1")
        XCTAssertEqual(decoded.customTranslationModelID, "Thomson-1.0-Small")
    }

    @MainActor
    func testMissingSettingsFileKeepsMacDefaults() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("settings.json")
        let settings = SettingsStore(fileURL: missing).load()

        XCTAssertEqual(settings.inputLanguageID, "en")
        XCTAssertEqual(settings.outputLanguageID, "zh-Hant")
        XCTAssertEqual(settings.conversationPrimaryLanguageID, "zh-Hant")
        XCTAssertEqual(settings.conversationSecondaryLanguageID, "en")
    }

}
