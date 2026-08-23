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
            let tokenizerFolder = try stageTokenizer()

            // Keep the 851 MB compiled models read-only in the bundle. Only the
            // generated 3.8 MB tokenizer/config pair is staged into writable
            // Application Support. Setting `load: false` lets us install the local
            // tokenizer before model loading, so WhisperKit never enters its Hub
            // fallback and never tries to write under the app bundle.
            let config = WhisperKitConfig(
                modelFolder: modelFolder.path,
                tokenizerFolder: tokenizerFolder,
                verbose: false,
                prewarm: false,
                load: false,
                download: false
            )
            let whisperKit = try await WhisperKit(config)
            whisperKit.tokenizer = try await ModelUtilities.loadTokenizer(
                for: .largev2,
                tokenizerFolder: tokenizerFolder,
                additionalSearchPaths: [tokenizerFolder]
            )
            try await whisperKit.loadModels()
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

    private static func stageTokenizer() throws -> URL {
        guard let tokenizerSource = Bundle.main.url(
            forResource: "BreezeASR26Tokenizer",
            withExtension: "json"
        ), let configSource = Bundle.main.url(
            forResource: "BreezeASR26TokenizerConfig",
            withExtension: "json"
        ) else {
            throw EngineError.modelNotFound
        }

        let fileManager = FileManager.default
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let folder = root
            .appendingPathComponent("v2s", isDirectory: true)
            .appendingPathComponent(
                "BreezeASR26Tokenizer-ccce05d8",
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        try Data(contentsOf: tokenizerSource).write(
            to: folder.appendingPathComponent("tokenizer.json"),
            options: .atomic
        )
        try Data(contentsOf: configSource).write(
            to: folder.appendingPathComponent("tokenizer_config.json"),
            options: .atomic
        )
        return folder
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
