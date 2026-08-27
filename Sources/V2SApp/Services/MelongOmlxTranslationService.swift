import Foundation

/// Caption-shaped extraction for Melong (DPO chat model).
///
/// The model often appends notes and alternatives after a good first line.
/// Ship the first line, strip a trailing dangler (`...` / `:`), never the rest.
enum MelongCaption {
    static func isTibetanLanguageID(_ identifier: String) -> Bool {
        identifier == "bo" || identifier.hasPrefix("bo-")
    }

    static func prompt(for sourceText: String) -> String {
        """
        Translate Tibetan to English. Output one line only.
        bo: བཀྲ་ཤིས་བདེ་ལེགས།
        en: Tashi Delek.
        bo: དེ་རིང་གནམ་གཤིས་ཡག་པོ་འདུག།
        en: The weather is nice today.
        bo: \(sourceText)
        en:
        """
    }

    static func line(from raw: String) -> String {
        let first = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { $0.isEmpty == false }) ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var line = first
        if line.hasSuffix("...") {
            line = String(line.dropLast(3)).trimmingCharacters(in: .whitespaces)
        }
        if line.hasSuffix("…") {
            line = String(line.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        if line.hasSuffix(":") {
            line = String(line.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return line
    }
}

#if os(macOS)
/// Local-only Melong (MonlamAI/dpo_v2) via a private oMLX sidecar.
///
/// Not shipped. Talks to `127.0.0.1` only. Used for `bo` after Apple Translation
/// reports unsupported, before TranslateGemma. Fail closed if the sidecar is down.
actor MelongOmlxTranslationService {
    enum ServiceError: Error {
        case unavailable
        case emptyTranslation
    }

    private let endpoint: URL
    private let apiKey: String
    private let modelID: String
    private let session: URLSession

    init(
        baseURL: URL? = nil,
        apiKey: String? = nil,
        modelID: String? = nil
    ) {
        let env = ProcessInfo.processInfo.environment
        self.endpoint = baseURL
            ?? URL(string: env["MELONG_OMLX_URL"] ?? "http://127.0.0.1:8001")!
        self.apiKey = apiKey ?? env["MELONG_OMLX_API_KEY"] ?? "v2s-melong"
        self.modelID = modelID ?? env["MELONG_OMLX_MODEL"] ?? "dpo_v2-4bit"
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 45
        self.session = URLSession(configuration: config)
    }

    func prepare(from source: String, to target: String) async throws {
        guard MelongCaption.isTibetanLanguageID(source)
            || MelongCaption.isTibetanLanguageID(target)
        else {
            throw ServiceError.unavailable
        }
        var request = URLRequest(url: endpoint.appending(path: "/v1/models"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ServiceError.unavailable
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        guard body.contains(modelID) else {
            throw ServiceError.unavailable
        }
    }

    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return "" }
        guard MelongCaption.isTibetanLanguageID(source)
            || MelongCaption.isTibetanLanguageID(target)
        else {
            throw ServiceError.unavailable
        }

        let payload: [String: Any] = [
            "model": modelID,
            "temperature": 0,
            "max_tokens": 48,
            "messages": [
                ["role": "user", "content": MelongCaption.prompt(for: trimmed)],
            ],
        ]
        var request = URLRequest(url: endpoint.appending(path: "/v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ServiceError.unavailable
        }
        let decoded = try JSONDecoder().decode(ChatCompletion.self, from: data)
        let raw = decoded.choices.first?.message.content ?? ""
        let line = MelongCaption.line(from: raw)
        guard line.isEmpty == false else {
            throw ServiceError.emptyTranslation
        }
        return line
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
