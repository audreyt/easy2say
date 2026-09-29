import Foundation
@testable import v2s

/// One caption-document emission during a virtual-time trace replay.
struct CaptionReplayFrame {
    /// Wall time (ms) the document was produced.
    var wallMs: Double
    var document: CaptionDocument
}

/// Drives `CaptionCore` through a recorded `AnalyzerTraceFixture.Trace` in virtual time:
/// inputs in wall-clock order, translation completions 180 ms after their
/// effect, ticks at each `nextWakeMs`. Emits a frame after every apply that
/// changed the document.
enum CaptionTraceReplayDriver {
    static let translationLatencyMs = 180.0

    static func run(
        _ trace: AnalyzerTraceFixture.Trace,
        config: CaptionSessionConfig,
        translationLatencyMs: Double = translationLatencyMs
    ) -> (frames: [CaptionReplayFrame], document: CaptionDocument) {
        var core = CaptionCore()
        _ = core.apply(.sessionStarted(config), nowMs: 0)

        var now = 0.0
        var frames: [CaptionReplayFrame] = []
        var lastRevision = core.document.revision
        var completions: [(due: Double, requestID: Int, text: String)] = []

        func collect() {
            guard core.document.revision != lastRevision else { return }
            lastRevision = core.document.revision
            frames.append(CaptionReplayFrame(wallMs: now, document: core.document))
        }

        func record(_ effects: [CaptionEffect]) {
            for effect in effects {
                guard case .translate(let request) = effect else { continue }
                completions.append((
                    due: now + translationLatencyMs,
                    requestID: request.id,
                    text: CaptionE2EHarness.fakeTranslation(
                        request.text, target: request.targetLanguageID
                    )
                ))
                completions.sort { $0.due < $1.due }
            }
            collect()
        }

        func advance(to target: Double) {
            while true {
                let nextCompletion = completions.first?.due
                let nextWake = core.nextWakeMs
                if let nextCompletion, nextCompletion <= target,
                   nextWake == nil || nextCompletion <= nextWake! {
                    let pending = completions.removeFirst()
                    now = max(now, pending.due)
                    record(core.apply(
                        .translationCompleted(requestID: pending.requestID, text: pending.text),
                        nowMs: now
                    ))
                } else if let nextWake, nextWake <= target {
                    now = max(now, nextWake)
                    record(core.apply(.tick, nowMs: now))
                } else {
                    break
                }
            }
            now = max(now, target)
        }

        var steps: [Int: [CaptionInput]] = [:]
        for (wallMs, input) in trace.inputs {
            steps[wallMs, default: []].append(input)
        }
        for wallMs in steps.keys.sorted() {
            advance(to: Double(wallMs))
            for input in steps[wallMs] ?? [] {
                record(core.apply(input, nowMs: now))
            }
        }
        // Flush the tail: session stop, then every remaining wake/completion.
        advance(to: Double(trace.totalAudioMs) + 1_000)
        record(core.apply(.sessionStopped(sessionID: config.sessionID), nowMs: now))
        advance(to: .infinity)

        return (frames, core.document)
    }
}
