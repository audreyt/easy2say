#if os(macOS) && canImport(WhisperKit)
import Foundation
import WhisperKit

/// Internal-evaluation Tibetan ASR using Monlam's private Whisper Turbo checkpoint.
///
/// The converted model is never committed or shipped. It is exposed only when the
/// locally generated `MonlamWhisperTibetan` bundle is present in this macOS app.
actor TibetanASREngine {
    enum EngineError: LocalizedError, AppLocalizableError {
        case modelNotFound
        case emptyTranscript

        func localizedDescription(languageID: String) -> String {
            switch self {
            case .modelNotFound:
                return AppLocalization.string(
                    .tibetanModelMissing,
                    languageID: languageID
                )
            case .emptyTranscript:
                return AppLocalization.string(
                    .tibetanEmptyTranscript,
                    languageID: languageID
                )
            }
        }

        var errorDescription: String? {
            localizedDescription(languageID: "en")
        }
    }

    @MainActor private static var cachedEngine: TibetanASREngine?
    @MainActor private static var loadTask: Task<TibetanASREngine, Error>?

    private let whisperKit: WhisperKit

    @MainActor
    static func load() async throws -> TibetanASREngine {
        if let cachedEngine { return cachedEngine }
        if let loadTask { return try await loadTask.value }

        let task = Task<TibetanASREngine, Error> {
            guard let modelFolder = Bundle.main.url(
                forResource: "MonlamWhisperTibetan",
                withExtension: nil
            ) else {
                throw EngineError.modelNotFound
            }
            let config = WhisperKitConfig(
                modelFolder: modelFolder.path,
                tokenizerFolder: modelFolder,
                verbose: false,
                prewarm: false,
                load: true,
                download: false
            )
            let whisperKit = try await WhisperKit(config)
            return TibetanASREngine(whisperKit: whisperKit)
        }
        loadTask = task
        do {
            let engine = try await task.value
            cachedEngine = engine
            loadTask = nil
            return engine
        } catch {
            loadTask = nil
            throw error
        }
    }

    private init(whisperKit: WhisperKit) {
        self.whisperKit = whisperKit
    }

    func transcribe(_ audio: [Float]) async throws -> String {
        guard audio.isEmpty == false else {
            throw EngineError.emptyTranscript
        }
        let results = try await whisperKit.transcribe(
            audioArray: audio,
            decodeOptions: DecodingOptions(
                task: .transcribe,
                language: "bo",
                temperature: 0,
                temperatureFallbackCount: 0,
                usePrefillPrompt: true,
                skipSpecialTokens: false,
                withoutTimestamps: true,
                wordTimestamps: false,
                concurrentWorkerCount: 1,
                chunkingStrategy: ChunkingStrategy.none
            )
        )
        let text = Self.sanitizedTranscript(
            results.flatMap(\.segments).map(\.text).joined(separator: " ")
        )
        guard text.isEmpty == false else {
            throw EngineError.emptyTranscript
        }
        return text
    }

    /// The Monlam tokenizer stores its Tibetan vocabulary as added tokens.
    /// swift-transformers currently drops every added token when
    /// `skipSpecialTokens` is enabled, including non-special Tibetan text; that also
    /// leaves WhisperKit's aggregate result text empty. Decode each segment in full
    /// and remove only Whisper's `<|...|>` control tokens.
    static func sanitizedTranscript(_ rawText: String) -> String {
        var remainder = rawText[...]
        var cleaned = ""
        while let start = remainder.range(of: "<|") {
            cleaned.append(contentsOf: remainder[..<start.lowerBound])
            let afterStart = remainder[start.upperBound...]
            guard let end = afterStart.range(of: "|>") else {
                cleaned.append(contentsOf: remainder[start.lowerBound...])
                remainder = ""
                break
            }
            remainder = afterStart[end.upperBound...]
        }
        cleaned.append(contentsOf: remainder)
        return cleaned
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
