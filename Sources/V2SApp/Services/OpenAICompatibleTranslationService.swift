import Foundation
#if os(macOS)
import Security
#endif

/// Preferred OpenAI-compatible `/v1` caption translator. It is selected only
/// after `/v1/models` confirms the configured model.
enum OpenAICompatibleTranslation {
    struct Config: Equatable, Sendable {
        var baseURL: URL
        var apiKey: String
        var modelID: String

        static func parse(baseURL: String, apiKey: String, modelID: String) -> Config? {
            let model = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard model.isEmpty == false,
                  let url = normalizedBaseURL(baseURL)
            else {
                return nil
            }
            return Config(
                baseURL: url,
                apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                modelID: model
            )
        }

        static func resolve(
            settingsBaseURL: String,
            settingsAPIKey: String,
            settingsModelID: String,
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> Config? {
            let url = nonempty(settingsBaseURL) ?? environment["V2S_TRANSLATION_URL"] ?? ""
            let model = nonempty(settingsModelID) ?? environment["V2S_TRANSLATION_MODEL"] ?? ""
            let key = nonempty(settingsAPIKey) ?? environment["V2S_TRANSLATION_API_KEY"] ?? ""
            return parse(baseURL: url, apiKey: key, modelID: model)
        }
    }

    static func systemPrompt(from source: String, to target: String) -> String {
        let sourceName = LanguageCatalog.displayName(for: source)
        let targetName = LanguageCatalog.displayName(for: target)
        return """
        You translate live captions from \(sourceName) (\(source)) to \(targetName) \
        (\(target)). Output ONLY the translation. No quotes, no romanization, no explanation.
        """
    }

    static func userPrompt(text: String, from source: String, to target: String) -> String {
        if isTibetan(source), target == "en" || target.hasPrefix("en-") {
            return """
            Translate Tibetan to English. Output one line only.
            bo: བཀྲ་ཤིས་བདེ་ལེགས།
            en: Tashi Delek.
            bo: དེ་རིང་གནམ་གཤིས་ཡག་པོ་འདུག།
            en: The weather is nice today.
            bo: \(text)
            en:
            """
        }
        let sourceName = LanguageCatalog.displayName(for: source)
        let targetName = LanguageCatalog.displayName(for: target)
        return "Translate from \(sourceName) (\(source)) to \(targetName) (\(target)):\n\n\(text)"
    }

    static func isTibetan(_ identifier: String) -> Bool {
        identifier == "bo" || identifier.hasPrefix("bo-")
    }

    static func line(from raw: String) -> String {
        var text = raw.replacingOccurrences(
            of: #"(?is)<think>.*?</think>"#,
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "\n")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let first = lines.first(where: { line in
            line.isEmpty == false
                && line.lowercased().hasPrefix("<think") == false
                && line.lowercased().hasPrefix("</think") == false
                && line.hasPrefix("```") == false
        }) ?? ""
        return stripDanglers(stripWrappingQuotes(first))
    }

    static func normalizedBaseURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false,
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false
        else {
            return nil
        }
        var path = components.path
        while path.hasSuffix("/") {
            path.removeLast()
        }
        if path.hasSuffix("/v1/chat/completions") {
            path.removeLast("/v1/chat/completions".count)
        } else if path.hasSuffix("/v1") {
            path.removeLast(3)
        }
        components.path = path == "/" ? "" : path
        return components.url
    }

    private static func nonempty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stripWrappingQuotes(_ line: String) -> String {
        var result = line
        let pairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("'", "'")]
        for (open, close) in pairs where result.count >= 2 {
            if result.first == open, result.last == close {
                result = String(result.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return result
    }

    private static func stripDanglers(_ line: String) -> String {
        var result = line
        if result.hasSuffix("...") {
            result = String(result.dropLast(3)).trimmingCharacters(in: .whitespaces)
        }
        if result.hasSuffix("…") {
            result = String(result.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        if result.hasSuffix(":") {
            result = String(result.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return result
    }
}

#if os(macOS)
enum CustomTranslationAPIKeyStore {
    private static let service = "Easy2Say.OpenAICompatibleTranslation"
    private static let account = "APIKey"

    static func load() -> String {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let apiKey = String(data: data, encoding: .utf8)
        else {
            return ""
        }
        return apiKey
    }

    @discardableResult
    static func save(_ apiKey: String) -> Bool {
        let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            let status = SecItemDelete(baseQuery as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }

        let attributes = [kSecValueData as String: Data(value.utf8)]
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return true
        }
        guard updateStatus == errSecItemNotFound else {
            return false
        }

        var item = baseQuery
        item[kSecValueData as String] = Data(value.utf8)
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

actor OpenAICompatibleTranslationService {
    enum ServiceError: LocalizedError, AppLocalizableError {
        case unavailable
        case emptyTranslation

        func localizedDescription(languageID: String) -> String {
            switch self {
            case .unavailable:
                return AppLocalization.string(
                    .customTranslationUnavailable,
                    languageID: languageID
                )
            case .emptyTranslation:
                return AppLocalization.string(
                    .customTranslationEmptyTranslation,
                    languageID: languageID
                )
            }
        }

        var errorDescription: String? {
            localizedDescription(languageID: "en")
        }
    }

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 90
            self.session = URLSession(configuration: config)
        }
    }

    func prepare(
        from source: String,
        to target: String,
        config: OpenAICompatibleTranslation.Config
    ) async throws {
        _ = source
        _ = target
        var request = URLRequest(url: config.baseURL.appending(path: "v1/models"))
        request.httpMethod = "GET"
        applyAPIKey(config.apiKey, to: &request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ServiceError.unavailable
        }
        let list = try JSONDecoder().decode(ModelsList.self, from: data)
        guard list.data.contains(where: { $0.id == config.modelID }) else {
            throw ServiceError.unavailable
        }
    }

    func translate(
        _ text: String,
        from source: String,
        to target: String,
        config: OpenAICompatibleTranslation.Config
    ) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return "" }

        let payload: [String: Any] = [
            "model": config.modelID,
            "temperature": 0,
            "max_tokens": min(128, max(32, trimmed.count + 16)),
            "stream": false,
            "chat_template_kwargs": ["enable_thinking": false],
            "messages": [
                [
                    "role": "system",
                    "content": OpenAICompatibleTranslation.systemPrompt(from: source, to: target),
                ],
                [
                    "role": "user",
                    "content": OpenAICompatibleTranslation.userPrompt(
                        text: trimmed,
                        from: source,
                        to: target
                    ),
                ],
            ],
        ]
        var request = URLRequest(
            url: config.baseURL.appending(path: "v1/chat/completions")
        )
        request.httpMethod = "POST"
        applyAPIKey(config.apiKey, to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ServiceError.unavailable
        }
        let decoded = try JSONDecoder().decode(ChatCompletion.self, from: data)
        let raw = decoded.choices.first?.message.content ?? ""
        let line = OpenAICompatibleTranslation.line(from: raw)
        guard line.isEmpty == false else {
            throw ServiceError.emptyTranslation
        }
        return line
    }

    private func applyAPIKey(_ apiKey: String, to request: inout URLRequest) {
        guard apiKey.isEmpty == false else { return }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }

    private struct ModelsList: Decodable {
        struct Model: Decodable {
            let id: String
        }

        let data: [Model]
    }

    private struct ChatCompletion: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }

            let message: Message
        }

        let choices: [Choice]
    }
}
#endif
