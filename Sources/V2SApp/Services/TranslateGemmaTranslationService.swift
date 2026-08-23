#if os(macOS) && canImport(CoreAILanguageModels) && canImport(SentencepieceTokenizer)
import CoreAILanguageModels
import Foundation
import SentencepieceTokenizer

/// Local macOS translation fallback for pairs Apple Translation does not support.
///
/// TranslateGemma is loaded only after Apple reports an unsupported pair. Prompt
/// tokens are produced directly with Gemma's SentencePiece model because the generic
/// Swift Transformers tokenizer currently mis-tokenizes Tibetan. The Core AI engine
/// receives exact raw token IDs and keeps its KV cache private to this actor.
@available(macOS 27.0, *)
actor TranslateGemmaTranslationService {
    enum ServiceError: LocalizedError, AppLocalizableError {
        case modelNotFound
        case emptyTranslation

        func localizedDescription(languageID: String) -> String {
            switch self {
            case .modelNotFound:
                return AppLocalization.string(
                    .translateGemmaModelMissing,
                    languageID: languageID
                )
            case .emptyTranslation:
                return AppLocalization.string(
                    .translateGemmaEmptyTranslation,
                    languageID: languageID
                )
            }
        }

        var errorDescription: String? {
            localizedDescription(languageID: "en")
        }
    }

    private static let bosToken: Int32 = 2
    private static let startOfTurnToken: Int32 = 105
    private static let endOfTurnToken: Int32 = 106
    private static let eosToken: Int32 = 1

    private var engine: (any InferenceEngine)?
    private var tokenizer: SentencepieceTokenizer?
    private var loadTask: Task<Void, Error>?

    func prepare(from source: String, to target: String) async throws {
        _ = source
        _ = target
        try await loadIfNeeded()
    }

    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return "" }
        try await loadIfNeeded()
        guard let engine, let tokenizer else {
            throw ServiceError.modelNotFound
        }

        let sourceCode = modelLanguageCode(for: source)
        let targetCode = modelLanguageCode(for: target)
        let sourceName = languageName(for: sourceCode)
        let targetName = languageName(for: targetCode)
        let body = """
        You are a professional \(sourceName) (\(sourceCode)) to \(targetName) (\(targetCode)) translator. Your goal is to accurately convey the meaning and nuances of the original \(sourceName) text while adhering to \(targetName) grammar, vocabulary, and cultural sensitivities.
        Produce only the \(targetName) translation, without any additional explanations or commentary. Please translate the following \(sourceName) text into \(targetName):


        \(trimmed)
        """

        var prompt: [Int32] = [Self.bosToken, Self.startOfTurnToken]
        prompt.append(contentsOf: try tokenizer.encode("user\n\(body)").map(Int32.init))
        prompt.append(Self.endOfTurnToken)
        prompt.append(Self.startOfTurnToken)
        prompt.append(contentsOf: try tokenizer.encode("model\n").map(Int32.init))

        try await engine.reset()
        let sequence = try await engine.generate(
            with: prompt,
            samplingConfiguration: .greedy,
            inferenceOptions: InferenceOptions(
                maxTokens: min(256, max(32, trimmed.count * 3)),
                includeLogits: false
            )
        )

        var generated: [Int] = []
        for try await output in sequence {
            if output.tokenId == Self.eosToken
                || output.tokenId == Self.endOfTurnToken {
                sequence.setStopReason(.eos)
                break
            }
            generated.append(Int(output.tokenId))
        }

        let translation = try tokenizer.decode(generated)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard translation.isEmpty == false else {
            throw ServiceError.emptyTranslation
        }
        return translation
    }

    private func loadIfNeeded() async throws {
        guard engine == nil || tokenizer == nil else { return }
        if let loadTask {
            try await loadTask.value
            return
        }

        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            try await self.loadResources()
        }
        loadTask = task
        do {
            try await task.value
            loadTask = nil
        } catch {
            loadTask = nil
            throw error
        }
    }

    private func loadResources() async throws {
        guard engine == nil || tokenizer == nil else { return }
        guard let resources = Bundle.main.url(
            forResource: "TranslateGemma",
            withExtension: nil
        ), let sentencePiece = Bundle.main.url(
            forResource: "tokenizer",
            withExtension: "model",
            subdirectory: "TranslateGemma"
        ) else {
            throw ServiceError.modelNotFound
        }

        let runner = try CoreAIRunner(contentsOf: resources)
        let loadedEngine = try await runner.makeInferenceEngine()
        let loadedTokenizer = try SentencepieceTokenizer(
            modelPath: sentencePiece.path,
            tokenOffset: 0
        )
        engine = loadedEngine
        tokenizer = loadedTokenizer
    }

    private func modelLanguageCode(for identifier: String) -> String {
        switch identifier {
        case "zh-Hans": return "zh-CN"
        case "zh-Hant": return "zh-TW"
        case "pt": return "pt-BR"
        case "nb": return "nb-NO"
        default: return identifier.replacingOccurrences(of: "_", with: "-")
        }
    }

    private func languageName(for code: String) -> String {
        let base = code.split(separator: "-").first.map(String.init) ?? code
        switch base {
        case "bo": return "Tibetan"
        case "zh": return "Chinese"
        case "en": return "English"
        default:
            return Locale(identifier: "en").localizedString(
                forLanguageCode: base
            ) ?? base
        }
    }
}
#endif
