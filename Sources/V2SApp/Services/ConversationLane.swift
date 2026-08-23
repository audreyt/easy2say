import CoreMedia
import Foundation
import Speech

/// One locale-pinned result lane inside a shared conversation `SpeechAnalyzer`.
///
/// Both transcribers are modules of the same analyzer and therefore consume the exact
/// same `AnalyzerInput` stream. This class only consumes one transcriber's results; the
/// engine owns capture, the analyzer, input buffering, arbitration, and translation.
@available(macOS 26.0, *)
final class ConversationLane: @unchecked Sendable {
    struct TimedSpan: Equatable, Sendable {
        let text: String
        let confidence: Double
        let startSeconds: Double
        let endSeconds: Double
    }

    struct Update: Sendable {
        let side: ConversationSide
        let text: String
        /// Mean `transcriptionConfidence` over the result's runs, in `0...1`.
        let confidence: Double
        let isFinal: Bool
        /// Position of this result in the shared capture timeline.
        let startSeconds: Double
        let endSeconds: Double
        /// Attributed-string runs retain their own audio identity. The engine uses
        /// these to trim audio already committed by the other lane without dropping
        /// new words from a result that spans both old and new speech.
        let spans: [TimedSpan]

        /// Removes text at or before the committed audio boundary.
        func trimmingAudio(beforeOrAt boundary: Double, tolerance: Double) -> Update? {
            guard boundary > 0 else { return self }

            if spans.isEmpty == false {
                let pending = spans.filter {
                    $0.endSeconds > boundary + tolerance
                }
                guard pending.isEmpty == false else { return nil }

                let pendingText = Self.normalizedText(
                    pending.map(\.text).joined()
                )
                guard pendingText.isEmpty == false else { return nil }

                return Update(
                    side: side,
                    text: pendingText,
                    confidence: pending.map(\.confidence).reduce(0, +) / Double(pending.count),
                    isFinal: isFinal,
                    startSeconds: pending.map(\.startSeconds).min() ?? startSeconds,
                    endSeconds: pending.map(\.endSeconds).max() ?? endSeconds,
                    spans: pending
                )
            }

            // `audioTimeRange` was requested, but preserve a wholly-new result if an
            // OS build omits run-level attributes. An overlapping result cannot be
            // safely split and is dropped instead of duplicating committed speech.
            guard startSeconds + tolerance >= boundary else { return nil }
            return self
        }

        private static func normalizedText(_ text: String) -> String {
            text
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Confidence assumed when a run carries no `transcriptionConfidence`.
    /// Neutral by construction: an absent score must not decide the floor.
    private static let assumedConfidence: Double = 0.82

    let side: ConversationSide
    let transcriber: SpeechTranscriber

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
        onUpdate: @escaping @Sendable (Update) -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) {
        let side = side
        let transcriber = transcriber
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    guard let update = self.update(from: result, side: side) else { continue }
                    onUpdate(update)
                }
            } catch is CancellationError {
                return
            } catch {
                onFailure(error)
            }
        }
    }

    func finish() {
        resultsTask?.cancel()
        resultsTask = nil
    }

    // MARK: - Private

    private func update(from result: SpeechTranscriber.Result, side: ConversationSide) -> Update? {
        let text = normalizedText(result.text)

        if result.isFinal {
            let identity = "\(result.range.start.value):\(result.range.duration.value):\(text)"
            guard identity != lastFinalIdentity else { return nil }
            lastFinalIdentity = identity
        }

        let resultStart = seconds(result.range.start, fallback: 0)
        let resultEnd = seconds(result.range.end, fallback: .greatestFiniteMagnitude)
        let spans = timedSpans(in: result.text)

        return Update(
            side: side,
            text: text,
            confidence: averageConfidence(of: result.text),
            isFinal: result.isFinal,
            startSeconds: spans.map(\.startSeconds).min() ?? resultStart,
            endSeconds: spans.map(\.endSeconds).max() ?? resultEnd,
            spans: spans
        )
    }

    private func timedSpans(in text: AttributedString) -> [TimedSpan] {
        var spans: [TimedSpan] = []
        for run in text.runs {
            let fragment = String(text[run.range].characters)
            guard fragment.isEmpty == false else { continue }
            // One untimed fragment makes the result unsplittable. Return no spans so
            // `trimmingAudio` takes its conservative whole-result overlap fallback.
            guard let timeRange = run.audioTimeRange else { return [] }
            let start = CMTimeGetSeconds(timeRange.start)
            let end = CMTimeGetSeconds(timeRange.end)
            guard start.isFinite, end.isFinite else { return [] }
            spans.append(
                TimedSpan(
                    text: fragment,
                    confidence: run.transcriptionConfidence ?? Self.assumedConfidence,
                    startSeconds: start,
                    endSeconds: end
                )
            )
        }
        return spans
    }

    private func averageConfidence(of text: AttributedString) -> Double {
        let values = text.runs.compactMap { $0.transcriptionConfidence }
        guard values.isEmpty == false else {
            return Self.assumedConfidence
        }
        return values.reduce(0, +) / Double(values.count)
    }

    private func normalizedText(_ text: AttributedString) -> String {
        String(text.characters)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func seconds(_ time: CMTime, fallback: Double) -> Double {
        let value = CMTimeGetSeconds(time)
        return value.isFinite ? value : fallback
    }
}
