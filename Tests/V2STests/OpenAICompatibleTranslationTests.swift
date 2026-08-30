import XCTest
import Translation
@testable import v2s

final class OpenAICompatibleTranslationTests: XCTestCase {
    func testParseRequiresHTTPURLAndModel() {
        XCTAssertNil(
            OpenAICompatibleTranslation.Config.parse(
                baseURL: "",
                apiKey: "k",
                modelID: "Thomson-1.0-Small"
            )
        )
        XCTAssertNil(
            OpenAICompatibleTranslation.Config.parse(
                baseURL: "http://127.0.0.1:8001",
                apiKey: "k",
                modelID: "  "
            )
        )
        XCTAssertNil(
            OpenAICompatibleTranslation.Config.parse(
                baseURL: "not-a-url",
                apiKey: "",
                modelID: "Thomson-1.0-Small"
            )
        )
        XCTAssertNil(
            OpenAICompatibleTranslation.Config.parse(
                baseURL: "http:127.0.0.1:8001",
                apiKey: "",
                modelID: "Thomson-1.0-Small"
            )
        )
        let config = OpenAICompatibleTranslation.Config.parse(
            baseURL: " http://127.0.0.1:8001/v1 ",
            apiKey: " secret ",
            modelID: " Thomson-1.0-Small "
        )
        XCTAssertEqual(config?.baseURL.absoluteString, "http://127.0.0.1:8001")
        XCTAssertEqual(config?.apiKey, "secret")
        XCTAssertEqual(config?.modelID, "Thomson-1.0-Small")
    }

    func testNormalizedBaseURLStripsV1Suffixes() {
        XCTAssertEqual(
            OpenAICompatibleTranslation.normalizedBaseURL("http://127.0.0.1:8001")?
                .absoluteString,
            "http://127.0.0.1:8001"
        )
        XCTAssertEqual(
            OpenAICompatibleTranslation.normalizedBaseURL("http://127.0.0.1:8001/")?
                .absoluteString,
            "http://127.0.0.1:8001"
        )
        XCTAssertEqual(
            OpenAICompatibleTranslation.normalizedBaseURL("http://127.0.0.1:8001/v1")?
                .absoluteString,
            "http://127.0.0.1:8001"
        )
        XCTAssertEqual(
            OpenAICompatibleTranslation.normalizedBaseURL("http://127.0.0.1:8001/v1/")?
                .absoluteString,
            "http://127.0.0.1:8001"
        )
        XCTAssertEqual(
            OpenAICompatibleTranslation.normalizedBaseURL(
                "http://127.0.0.1:8001/v1/chat/completions"
            )?.absoluteString,
            "http://127.0.0.1:8001"
        )
        XCTAssertEqual(
            OpenAICompatibleTranslation.normalizedBaseURL("https://example.test/omlx/v1")?
                .absoluteString,
            "https://example.test/omlx"
        )
    }

    func testSettingsWinOverEnvironment() {
        let config = OpenAICompatibleTranslation.Config.resolve(
            settingsBaseURL: "http://127.0.0.1:8001",
            settingsAPIKey: "from-settings",
            settingsModelID: "Thomson-1.0-Small",
            environment: [
                "V2S_TRANSLATION_URL": "http://127.0.0.1:9",
                "V2S_TRANSLATION_API_KEY": "from-env",
                "V2S_TRANSLATION_MODEL": "other",
            ]
        )
        XCTAssertEqual(config?.baseURL.absoluteString, "http://127.0.0.1:8001")
        XCTAssertEqual(config?.apiKey, "from-settings")
        XCTAssertEqual(config?.modelID, "Thomson-1.0-Small")
    }

    func testEmptySettingsFallBackToEnvironment() {
        let config = OpenAICompatibleTranslation.Config.resolve(
            settingsBaseURL: "",
            settingsAPIKey: "",
            settingsModelID: "  ",
            environment: [
                "V2S_TRANSLATION_URL": "http://127.0.0.1:8001/v1",
                "V2S_TRANSLATION_API_KEY": "from-env",
                "V2S_TRANSLATION_MODEL": "Thomson-1.0-Small",
            ]
        )
        XCTAssertEqual(config?.baseURL.absoluteString, "http://127.0.0.1:8001")
        XCTAssertEqual(config?.apiKey, "from-env")
        XCTAssertEqual(config?.modelID, "Thomson-1.0-Small")
    }

    func testLineStripsThinkTagsQuotesAndDanglers() {
        XCTAssertEqual(
            OpenAICompatibleTranslation.line(
                from: "<think>\nplan\n</think>\nThe weather is nice today."
            ),
            "The weather is nice today."
        )
        XCTAssertEqual(
            OpenAICompatibleTranslation.line(
                from: "\"The weather is nice today.\""
            ),
            "The weather is nice today."
        )
        XCTAssertEqual(
            OpenAICompatibleTranslation.line(
                from: "The weather is nice today...\n(literally: good weather)"
            ),
            "The weather is nice today"
        )
        XCTAssertEqual(
            OpenAICompatibleTranslation.line(from: "```\nHello.\n```"),
            "Hello."
        )
    }

    func testPromptNamesThePairAndForbidsCommentary() {
        let system = OpenAICompatibleTranslation.systemPrompt(from: "zh-Hant", to: "en")
        XCTAssertTrue(system.contains("English (en)"))
        XCTAssertTrue(system.contains("No quotes"))
        let user = OpenAICompatibleTranslation.userPrompt(
            text: "今天天氣很好。",
            from: "zh-Hant",
            to: "en"
        )
        XCTAssertTrue(user.contains("Chinese (Traditional) (zh-Hant)"))
        XCTAssertTrue(user.contains("今天天氣很好。"))
        XCTAssertTrue(OpenAICompatibleTranslation.isTibetan("bo"))
        XCTAssertTrue(OpenAICompatibleTranslation.isTibetan("bo-CN"))
        XCTAssertFalse(OpenAICompatibleTranslation.isTibetan("en"))
        let tibetan = OpenAICompatibleTranslation.userPrompt(
            text: "ང་འགྲོ་གི་ཡིན།",
            from: "bo",
            to: "en"
        )
        XCTAssertTrue(tibetan.contains("bo: བཀྲ་ཤིས་བདེ་ལེགས།"))
        XCTAssertTrue(tibetan.contains("en: The weather is nice today."))
        XCTAssertTrue(tibetan.contains("bo: ང་འགྲོ་གི་ཡིན།"))
        XCTAssertTrue(tibetan.hasSuffix("en:"))
    }

    @MainActor
    func testSupportedAppleHandoffPreparesBeforeTranslation() {
        XCTAssertTrue(
            TranslationCoordinator.requiresApplePreparation(for: .supported)
        )
        XCTAssertFalse(
            TranslationCoordinator.requiresApplePreparation(for: .installed)
        )
    }

    @MainActor
    func testAppleOperationFailureFallsBackAfterPreferredFailure() async throws {
        let coordinator = TranslationCoordinator()
        var applePreparedBeforeTranslation = false
        var fallbackTranslateCalls = 0
        coordinator.preferredPrepare = { _, _ in true }
        coordinator.preferredTranslate = { _, _, _ in
            throw OpenAICompatibleTranslationService.ServiceError.unavailable
        }
        coordinator.appleAvailability = { _, _ in .supported }
        coordinator.appleTranslate = { _, _, _, prepareIfNeeded in
            applePreparedBeforeTranslation = prepareIfNeeded
            throw URLError(.cannotConnectToHost)
        }
        coordinator.fallbackTranslate = { text, _, _ in
            fallbackTranslateCalls += 1
            return "AFM: \(text)"
        }

        try await coordinator.prepareIfNeeded(from: "en", to: "fr")
        let result = try await coordinator.translate(
            "hello",
            from: "en",
            to: "fr"
        )

        XCTAssertTrue(applePreparedBeforeTranslation)
        XCTAssertEqual(fallbackTranslateCalls, 1)
        XCTAssertEqual(result, "AFM: hello")
    }

    @MainActor
    func testAppleOperationCancellationDoesNotFallBack() async throws {
        let coordinator = TranslationCoordinator()
        var fallbackTranslateCalls = 0
        coordinator.preferredPrepare = { _, _ in true }
        coordinator.preferredTranslate = { _, _, _ in
            throw OpenAICompatibleTranslationService.ServiceError.unavailable
        }
        coordinator.appleAvailability = { _, _ in .supported }
        coordinator.appleTranslate = { _, _, _, _ in
            throw CancellationError()
        }
        coordinator.fallbackTranslate = { text, _, _ in
            fallbackTranslateCalls += 1
            return "AFM: \(text)"
        }

        try await coordinator.prepareIfNeeded(from: "en", to: "fr")
        do {
            _ = try await coordinator.translate("hello", from: "en", to: "fr")
            XCTFail("Cancellation should propagate")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        XCTAssertEqual(fallbackTranslateCalls, 0)
    }

    @MainActor
    func testPreferredBackendRunsBeforeAppleTranslation() async throws {
        let coordinator = TranslationCoordinator()
        var prepareCalls = 0
        var translateCalls = 0
        coordinator.preferredPrepare = { _, _ in
            prepareCalls += 1
            return true
        }
        coordinator.preferredTranslate = { text, _, _ in
            translateCalls += 1
            return "/v1: \(text)"
        }

        try await coordinator.prepareIfNeeded(from: "en", to: "zh-Hant")
        let result = try await coordinator.translate(
            "hello",
            from: "en",
            to: "zh-Hant"
        )

        XCTAssertEqual(prepareCalls, 1)
        XCTAssertEqual(translateCalls, 1)
        XCTAssertEqual(result, "/v1: hello")
        XCTAssertNil(coordinator.configuration)
    }

    @MainActor
    func testRejectedPreferredModelSkipsPreferredTranslationAndUsesFallback() async throws {
        let coordinator = TranslationCoordinator()
        var preferredTranslateCalls = 0
        var fallbackPrepareCalls = 0
        var fallbackTranslateCalls = 0
        coordinator.preferredPrepare = { _, _ in
            throw OpenAICompatibleTranslationService.ServiceError.unavailable
        }
        coordinator.preferredTranslate = { text, _, _ in
            preferredTranslateCalls += 1
            return "/v1: \(text)"
        }
        coordinator.fallbackPrepare = { _, _ in
            fallbackPrepareCalls += 1
        }
        coordinator.fallbackTranslate = { text, _, _ in
            fallbackTranslateCalls += 1
            return "AFM: \(text)"
        }

        try await coordinator.prepareIfNeeded(from: "bo", to: "en")
        let result = try await coordinator.translate(
            "བཀྲ་ཤིས་བདེ་ལེགས།",
            from: "bo",
            to: "en"
        )

        XCTAssertEqual(preferredTranslateCalls, 0)
        XCTAssertEqual(fallbackPrepareCalls, 1)
        XCTAssertEqual(fallbackTranslateCalls, 1)
        XCTAssertEqual(result, "AFM: བཀྲ་ཤིས་བདེ་ལེགས།")
    }

    @MainActor
    func testPreferredRequestFailureContinuesToAppleThenFallback() async throws {
        let coordinator = TranslationCoordinator()
        var preferredTranslateCalls = 0
        var fallbackTranslateCalls = 0
        coordinator.preferredPrepare = { _, _ in true }
        coordinator.preferredTranslate = { _, _, _ in
            preferredTranslateCalls += 1
            throw OpenAICompatibleTranslationService.ServiceError.unavailable
        }
        coordinator.fallbackTranslate = { text, _, _ in
            fallbackTranslateCalls += 1
            return "AFM: \(text)"
        }

        try await coordinator.prepareIfNeeded(from: "bo", to: "en")
        let result = try await coordinator.translate(
            "བཀྲ་ཤིས་བདེ་ལེགས།",
            from: "bo",
            to: "en"
        )

        XCTAssertEqual(preferredTranslateCalls, 1)
        XCTAssertEqual(fallbackTranslateCalls, 1)
        XCTAssertEqual(result, "AFM: བཀྲ་ཤིས་བདེ་ལེགས།")
    }

#if os(macOS)
    func testLiveThomsonOmlxTranslation() async throws {
        guard let config = OpenAICompatibleTranslation.Config.parse(
            baseURL: "http://127.0.0.1:8001",
            apiKey: "",
            modelID: "Thomson-1.0-Small"
        ) else {
            return XCTFail("Thomson config should parse")
        }
        let service = OpenAICompatibleTranslationService()
        do {
            try await service.prepare(from: "zh-Hant", to: "en", config: config)
        } catch {
            throw XCTSkip("oMLX Thomson-1.0-Small is not loaded: \(error)")
        }
        let translated = try await service.translate(
            "今天天氣很好。",
            from: "zh-Hant",
            to: "en",
            config: config
        )
        XCTAssertFalse(translated.contains("<think>"))
        XCTAssertFalse(translated.isEmpty)
        let lowered = translated.lowercased()
        XCTAssertTrue(
            lowered.contains("weather") || lowered.contains("nice"),
            "unexpected Thomson caption: \(translated)"
        )
    }
#endif
}
