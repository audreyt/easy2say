import Foundation

/// Wall-clock source for `CaptionPipeline` so tests can drive virtual time.
struct CaptionPipelineClock: Sendable {
    /// Milliseconds on an arbitrary, monotonic timeline.
    var nowMs: @Sendable () -> Double
    /// Suspend until the timeline reaches `target`.
    var sleepUntil: @Sendable (Double) async -> Void

    static let continuous = CaptionPipelineClock(
        nowMs: { ProcessInfo.processInfo.systemUptime * 1_000 },
        sleepUntil: { until in
            let remaining = until - ProcessInfo.processInfo.systemUptime * 1_000
            guard remaining > 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000))
        }
    )
}

/// Drives `CaptionCore` on the main actor: applies inputs, runs translation
/// effects as Tasks, arms a single wake Task for `nextWakeMs`, and publishes
/// the document only when its revision changes.
@MainActor
final class CaptionPipeline {
    typealias Translate = @Sendable (CaptionTranslationRequest) async -> String?

    private var core = CaptionCore()
    private let correct: @Sendable (String, String) -> String
    private let translate: Translate
    private let clock: CaptionPipelineClock

    var onDocumentChange: ((CaptionDocument) -> Void)?
    private(set) var document = CaptionDocument(rows: [], revision: 0)

    private var wakeTask: Task<Void, Never>?
    private var wakeTargetMs: Double?
    private var translationTasks: [Int: Task<Void, Never>] = [:]
    /// Pending 30 ms coalescing flush; nil while nothing is owed.
    private var flushTask: Task<Void, Never>?
    static let publishCoalesceMs: Double = 30

    init(
        correct: @escaping @Sendable (String, String) -> String = { text, _ in text },
        translate: @escaping Translate,
        clock: CaptionPipelineClock = .continuous
    ) {
        self.correct = correct
        self.translate = translate
        self.clock = clock
    }

    /// Inputs apply to the core immediately (effects run now); the document
    /// publishes at most once per 30 ms — an ASR burst's intermediate states
    /// never reach the screen.
    func handle(_ input: CaptionInput) {
        switch input {
        case .reset:
            wakeTask?.cancel()
            wakeTask = nil
            wakeTargetMs = nil
            for task in translationTasks.values { task.cancel() }
            translationTasks.removeAll()
        default:
            break
        }

        let effects = core.apply(input, nowMs: clock.nowMs())
        for effect in effects {
            guard case .translate(let request) = effect else { continue }
            startTranslation(request)
        }
        armWake()

        switch input {
        case .reset, .sessionStopped:
            publishNow()
        default:
            if core.document.revision != document.revision, flushTask == nil {
                armFlush(deadline: clock.nowMs() + Self.publishCoalesceMs)
            }
        }
    }

    private func startTranslation(_ request: CaptionTranslationRequest) {
        let translate = self.translate
        let task = Task { [weak self] in
            let text = await translate(request)
            guard Task.isCancelled == false else { return }
            self?.translationTasks[request.id] = nil
            self?.handle(
                .translationCompleted(requestID: request.id, text: text)
            )
        }
        translationTasks[request.id] = task
    }

    /// Re-arms the wake task only when the target changed — never two pending.
    private func armWake() {
        let target = core.nextWakeMs
        guard target != wakeTargetMs else { return }
        wakeTask?.cancel()
        wakeTargetMs = target
        guard let target else {
            wakeTask = nil
            return
        }
        let sleepUntil = clock.sleepUntil
        wakeTask = Task { [weak self] in
            await sleepUntil(target)
            guard Task.isCancelled == false, let self else { return }
            if self.wakeTargetMs == target {
                self.wakeTask = nil
                self.wakeTargetMs = nil
            }
            self.handle(.tick)
        }
    }

    /// One pending flush at a time; its deadline is the first unflushed
    /// change's +30 ms window.
    private func armFlush(deadline: Double) {
        let sleepUntil = clock.sleepUntil
        flushTask = Task { [weak self] in
            await sleepUntil(deadline)
            guard Task.isCancelled == false, let self else { return }
            self.flushTask = nil
            self.publish()
        }
    }

    /// `.reset` and `.sessionStopped` flush everything owed immediately.
    private func publishNow() {
        flushTask?.cancel()
        flushTask = nil
        publish()
    }

    private func publish() {
        let current = core.document
        guard current.revision != document.revision else { return }
        document = current
        onDocumentChange?(current)
    }
}
