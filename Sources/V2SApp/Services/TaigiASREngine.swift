#if canImport(WhisperKit)
import Foundation
import WhisperKit

/// Serial, local Breeze-ASR-26 inference for Taiwanese Hokkien speech.
///
/// The model intentionally emits Mandarin Chinese characters rather than native
/// Taibun orthography. AppModel routes that output through Apple Translation as
/// zh-Hant while continuing to label the captured language as Taigi.
actor TaigiASREngine {
    enum EngineError: LocalizedError, AppLocalizableError {
        case modelNotFound
        case emptyTranscript

        func localizedDescription(languageID: String) -> String {
            switch self {
            case .modelNotFound:
                return AppLocalization.string(.taigiModelMissing, languageID: languageID)
            case .emptyTranscript:
                return AppLocalization.string(.taigiEmptyTranscript, languageID: languageID)
            }
        }

        var errorDescription: String? {
            localizedDescription(languageID: "en")
        }
    }

    private let whisperKit: WhisperKit
    private let normalizer = TaiwanChineseNormalizer()
    @MainActor private static var cachedEngine: TaigiASREngine?
    @MainActor private static var loadTask: Task<TaigiASREngine, Error>?

    @MainActor
    static func load() async throws -> TaigiASREngine {
        if let cachedEngine {
            return cachedEngine
        }
        if let loadTask {
            return try await loadTask.value
        }

        let task = Task<TaigiASREngine, Error> {
            guard let modelFolder = Bundle.main.url(
                forResource: "BreezeASR26",
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
            return TaigiASREngine(whisperKit: whisperKit)
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

        // Breeze-ASR-26 uses Whisper's shared Chinese token and is trained to emit
        // Mandarin-character transcriptions for Taigi speech. Passing `zh` is exact;
        // WhisperKit does not define a `nan` token, and `zh-Hant` is not a Whisper
        // language token.
        let options = DecodingOptions(
            task: .transcribe,
            language: "zh",
            temperature: 0,
            temperatureFallbackCount: 0,
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            wordTimestamps: false,
            concurrentWorkerCount: 1,
            chunkingStrategy: ChunkingStrategy.none
        )
        let results = try await whisperKit.transcribe(
            audioArray: audio,
            decodeOptions: options
        )
        let text = results
            .map(\.text)
            .joined(separator: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false else {
            throw EngineError.emptyTranscript
        }
        return normalizer.normalize(text)
    }
}
#endif
