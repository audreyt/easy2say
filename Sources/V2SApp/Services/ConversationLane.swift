import AVFoundation
import CoreMedia
import Foundation
import Speech

/// One locale-pinned transcriber inside a conversation session.
///
/// A lane owns a `SpeechTranscriber` and the `SpeechAnalyzer` feeding it, and nothing
/// else — the microphone, the format conversion and the arbitration all live one level
/// up in `ConversationEngine`, because both lanes must see byte-identical audio for a
/// confidence comparison between them to mean anything.
@available(macOS 26.0, *)
final class ConversationLane: @unchecked Sendable {
    struct Update: Sendable {
        let side: ConversationSide
        let text: String
        /// Mean `transcriptionConfidence` over the result's runs, in `0...1`.
        let confidence: Double
        let isFinal: Bool
        /// Position of this result in the capture timeline. Both lanes are fed the
        /// same buffers from the same instant, so their timelines are comparable —
        /// which is what lets the engine recognise a result describing audio it has
        /// already turned into a turn.
        let startSeconds: Double
        let endSeconds: Double
    }

    /// Confidence assumed when a result carries no `transcriptionConfidence` runs.
    /// Neutral by construction: an absent score must not decide the floor.
    private static let assumedConfidence: Double = 0.82

    let side: ConversationSide

    private let transcriber: SpeechTranscriber
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    /// Guards against re-emitting a finalized result, which `SpeechTranscriber` can
    /// redeliver when a later volatile result refines the same range.
    private var lastFinalIdentity: String?

    init(side: ConversationSide, transcriber: SpeechTranscriber) {
        self.side = side
        self.transcriber = transcriber
    }

    /// Downloads the on-device assets both lanes need, in one request.
    ///
    /// Asking per lane would serialize two downloads and could leave the session half
    /// usable — a conversation with one working language is not a conversation.
    static func installAssetsIfNeeded(
        for modules: [(transcriber: SpeechTranscriber, locale: Locale)]
    ) async throws {
        let installed = await Set(SpeechTranscriber.installedLocales.map(\.identifier))
        let missing = modules
            .filter { installed.contains($0.locale.identifier) == false }
            .map(\.transcriber)

        guard missing.isEmpty == false else {
            return
        }

        if let installer = try await AssetInventory.assetInstallationRequest(supporting: missing) {
            try await installer.downloadAndInstall()
        }
    }

    func start(
        analyzerFormat: AVAudioFormat,
        onUpdate: @escaping @Sendable (Update) -> Void
    ) async throws {
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .whileInUse)
        )
        try await analyzer.prepareToAnalyze(in: analyzerFormat)

        let stream = AsyncStream<AnalyzerInput>(bufferingPolicy: .bufferingNewest(12)) { continuation in
            self.continuation = continuation
        }

        let side = side
        let transcriber = transcriber
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    guard let update = self.update(from: result, side: side) else { continue }
                    onUpdate(update)
                }
            } catch {
                // A lane that dies takes its language with it; the surviving lane keeps
                // transcribing, and the arbiter simply never hands it the floor.
                return
            }
        }

        analyzerTask = Task {
            try? await analyzer.start(inputSequence: stream)
        }

        self.analyzer = analyzer
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        continuation?.yield(AnalyzerInput(buffer: buffer))
    }

    func finish() {
        continuation?.finish()
        continuation = nil
        resultsTask?.cancel()
        resultsTask = nil
        analyzerTask?.cancel()
        analyzerTask = nil

        if let analyzer {
            self.analyzer = nil
            Task {
                await analyzer.cancelAndFinishNow()
            }
        }
    }

    // MARK: - Private

    private func update(from result: SpeechTranscriber.Result, side: ConversationSide) -> Update? {
        let text = String(result.text.characters)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if result.isFinal {
            let identity = "\(result.range.start.value):\(result.range.duration.value):\(text)"
            guard identity != lastFinalIdentity else { return nil }
            lastFinalIdentity = identity
        }

        let start = CMTimeGetSeconds(result.range.start)
        let end = CMTimeGetSeconds(result.range.end)

        return Update(
            side: side,
            text: text,
            confidence: averageConfidence(of: result.text),
            isFinal: result.isFinal,
            // A malformed range must not silence a lane, so fall back to a window that
            // never reads as already-committed.
            startSeconds: start.isFinite ? start : 0,
            endSeconds: end.isFinite ? end : .greatestFiniteMagnitude
        )
    }

    private func averageConfidence(of text: AttributedString) -> Double {
        var total: Double = 0
        var count = 0

        for run in text.runs {
            if let confidence = run.transcriptionConfidence {
                total += confidence
                count += 1
            }
        }

        guard count > 0 else {
            return Self.assumedConfidence
        }
        return total / Double(count)
    }
}
