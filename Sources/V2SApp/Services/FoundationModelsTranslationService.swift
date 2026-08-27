import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum FoundationModelsTranslationRefusal {
    static func looksLikeRefusal(_ text: String) -> Bool {
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard lowered.isEmpty == false else { return false }
        if lowered.hasPrefix("sorry") && (lowered.contains("can't") || lowered.contains("cannot") || lowered.contains("unable")) {
            return true
        }
        if lowered.contains("i can't help") || lowered.contains("i cannot help") {
            return true
        }
        if text.contains("無法協助") || text.contains("无法协助") || text.contains("我無法") || text.contains("我无法") {
            return true
        }
        return false
    }
}

#if canImport(FoundationModels)
/// On-device AFM fallback for pairs Apple Translation reports unsupported.
///
/// Uses `permissiveContentTransformations` so caption speech (including
/// profanity) is treated as a transform, not a chat request. The model can
/// still refuse in the string; callers should fall through to TranslateGemma
/// or show source.
@available(iOS 26.0, macOS 26.0, *)
actor FoundationModelsTranslationService {
    enum ServiceError: LocalizedError, AppLocalizableError {
        case unavailable
        case emptyTranslation
        case refused

        func localizedDescription(languageID: String) -> String {
            switch self {
            case .unavailable:
                return AppLocalization.string(.foundationModelsTranslationUnavailable, languageID: languageID)
            case .emptyTranslation:
                return AppLocalization.string(.foundationModelsTranslationEmpty, languageID: languageID)
            case .refused:
                return AppLocalization.string(.foundationModelsTranslationRefused, languageID: languageID)
            }
        }

        var errorDescription: String? {
            localizedDescription(languageID: "en")
        }
    }

    func prepare(from source: String, to target: String) async throws {
        _ = source
        _ = target
        _ = try readyModel()
    }

    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return "" }
        let model = try readyModel()
        let sourceName = LanguageCatalog.displayName(for: source)
        let targetName = LanguageCatalog.displayName(for: target)
        let instructions = """
        You are a translator for live captions. Output ONLY the \(targetName) \
        (\(target)) translation. No quotes, no romanization, no explanation.
        """
        let session = LanguageModelSession(
            model: model,
            tools: [],
            instructions: instructions
        )
        let prompt = "Translate from \(sourceName) (\(source)) to \(targetName) (\(target)):\n\n\(trimmed)"
        let content: String
        do {
            let response = try await session.respond(to: prompt)
            content = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ServiceError.refused
        }
        guard content.isEmpty == false else {
            throw ServiceError.emptyTranslation
        }
        if FoundationModelsTranslationRefusal.looksLikeRefusal(content) {
            throw ServiceError.refused
        }
        return content
    }

    private func readyModel() throws -> SystemLanguageModel {
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        guard model.isAvailable else {
            throw ServiceError.unavailable
        }
        return model
    }
}
#endif
