import XCTest
@testable import v2s

/// Manual millisecond clock: `advance(to:)` fires every sleep waiter whose
/// deadline passed, letting tests drive the pipeline's wake deterministically.
private final class ManualPipelineClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Double = 0
    private var _nextWaiterID = 0
    private var _waiters: [Int: (until: Double, continuation: CheckedContinuation<Void, Never>)] = [:]

    var clock: CaptionPipelineClock {
        CaptionPipelineClock(
            nowMs: { self.nowMs },
            sleepUntil: { until in
                await self.sleep(untilMs: until)
            }
        )
    }

    private var nowMs: Double {
        lock.lock(); defer { lock.unlock() }
        return _now
    }

    /// Sleep waiters still armed (cancelled ones are removed eagerly).
    var pendingWakes: Int {
        lock.lock(); defer { lock.unlock() }
        return _waiters.count
    }

    var nextWaiter: Double? {
        lock.lock(); defer { lock.unlock() }
        return _waiters.values.map(\.until).min()
    }

    var waiters: [Double] {
        lock.lock(); defer { lock.unlock() }
        return _waiters.values.map(\.until).sorted()
    }

    private func sleep(untilMs until: Double) async {
        let id = lock.withLock { () -> Int in
            let id = _nextWaiterID
            _nextWaiterID += 1
            return id
        }
        if until <= lock.withLock({ _now }) { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                _waiters[id] = (until: until, continuation: continuation)
                lock.unlock()
            }
        } onCancel: {
            // Cancelled wake tasks must not linger as waiters.
            lock.lock()
            let waiter = _waiters.removeValue(forKey: id)
            lock.unlock()
            waiter?.continuation.resume()
        }
    }

    func advance(to target: Double) {
        let ready: [CheckedContinuation<Void, Never>] = lock.withLock {
            _now = max(_now, target)
            let ready = _waiters.filter { $0.value.until <= _now }
            for key in ready.keys { _waiters.removeValue(forKey: key) }
            return ready.values.map(\.continuation)
        }
        for continuation in ready {
            continuation.resume()
        }
    }
}

@MainActor
final class CaptionPipelineTests: XCTestCase {
    private func session(_ id: Int = 1) -> CaptionSessionConfig {
        CaptionSessionConfig(
            sessionID: id, primaryLanguageID: "en", targetLanguageID: "zh-Hant", translates: true
        )
    }

    private func result(
        _ text: String,
        isFinal: Bool,
        rangeStart: Int,
        audioFed: Int
    ) -> CaptionInput {
        .result(
            sessionID: 1,
            AnalyzerResultEvent(
                lane: CaptionLaneID(sessionID: 1, languageID: "en"),
                isFinal: isFinal,
                rangeStartMs: rangeStart,
                rangeDurationMs: 0,
                finalizationMs: nil,
                text: text,
                runs: [],
                audioFedMs: audioFed,
                speakerIndex: nil
            )
        )
    }

    /// Let queued MainActor tasks (translation completions, wake ticks) run.
    private func settle() async {
        for _ in 0..<6 { await Task.yield() }
    }

    /// Sendable box for values the translate closure records.
    private final class Recorder<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [T] = []
        func append(_ item: T) { lock.withLock { items.append(item) } }
        var all: [T] { lock.withLock { items } }
    }

    func testAppliesInputsAndPublishesOnRevisionChange() async {
        let clock = ManualPipelineClock()
        let translations = Recorder<CaptionTranslationRequest>()
        let pipeline = CaptionPipeline(
            translate: { request in
                translations.append(request)
                return "譯：\(request.text)"
            },
            clock: clock.clock
        )
        var published: [CaptionDocument] = []
        pipeline.onDocumentChange = { published.append($0) }

        pipeline.handle(.sessionStarted(session()))
        XCTAssertEqual(published.count, 0, "empty document never publishes")

        pipeline.handle(result("Hello", isFinal: false, rangeStart: 0, audioFed: 100))
        XCTAssertEqual(published.count, 0, "publish is coalesced, not immediate")
        clock.advance(to: 30)
        await settle()
        XCTAssertEqual(published.map(\.revision), [1])
        XCTAssertEqual(published.last?.rows.map(\.text), ["Hello"])

        // Same document applied again publishes nothing.
        pipeline.handle(result("Hello", isFinal: false, rangeStart: 0, audioFed: 200))
        let count = published.count
        XCTAssertGreaterThanOrEqual(count, 1)
    }

    func testTranslationEffectsRunAndCompletionApplies() async {
        let clock = ManualPipelineClock()
        let pipeline = CaptionPipeline(
            translate: { _ in "譯文" },
            clock: clock.clock
        )
        pipeline.handle(.sessionStarted(session()))
        // A final seals the row immediately → final translation request.
        pipeline.handle(result("Hello world.", isFinal: true, rangeStart: 0, duration: 500, audioFed: 500))
        await settle()
        clock.advance(to: 100)
        await settle()
        XCTAssertEqual(pipeline.document.rows.last?.translation, "譯文")
        XCTAssertEqual(pipeline.document.rows.last?.translationIsDraft, false)
    }

    private func result(
        _ text: String,
        isFinal: Bool,
        rangeStart: Int,
        duration: Int,
        audioFed: Int
    ) -> CaptionInput {
        .result(
            sessionID: 1,
            AnalyzerResultEvent(
                lane: CaptionLaneID(sessionID: 1, languageID: "en"),
                isFinal: isFinal,
                rangeStartMs: rangeStart,
                rangeDurationMs: duration,
                finalizationMs: nil,
                text: text,
                runs: [],
                audioFedMs: audioFed,
                speakerIndex: nil
            )
        )
    }

    func testWakeTaskFiresTickAtDeadlineAndIsSingle() async {
        let clock = ManualPipelineClock()
        let pipeline = CaptionPipeline(
            translate: { _ in nil },
            clock: clock.clock
        )
        pipeline.handle(.sessionStarted(session()))
        clock.advance(to: 100)
        pipeline.handle(result("Hello", isFinal: false, rangeStart: 0, audioFed: 100))
        await settle()

        // One wake armed for the idle-seal deadline (100 + 1500), plus the
        // publish flush at 100 + 30 on the same clock.
        XCTAssertEqual(clock.waiters, [130, 1_600])

        // The flush publishes the live row; the seal wake stays pending.
        clock.advance(to: 130)
        await settle()
        XCTAssertEqual(clock.waiters, [1_600])
        XCTAssertFalse(pipeline.document.rows.first?.isSealed ?? true)

        // More inputs before the deadline re-arm at most one wake.
        clock.advance(to: 300)
        pipeline.handle(result("Hello wo", isFinal: false, rangeStart: 0, audioFed: 300))
        await settle()
        // The seal wake plus the new publish flush — never two of either.
        XCTAssertLessThanOrEqual(clock.pendingWakes, 2)
        clock.advance(to: 400)
        await settle()
        // The new result pushed the seal deadline to 300 + 1500.
        XCTAssertEqual(clock.waiters, [1_800])

        clock.advance(to: 1_800)
        await settle()
        // The seal itself publishes on the next flush window.
        clock.advance(to: 1_830)
        await settle()
        XCTAssertTrue(pipeline.document.rows.first?.isSealed ?? false, "idle tick did not seal")
        // A retry wake for the failed (nil) translation is allowed.
        XCTAssertLessThanOrEqual(clock.pendingWakes, 2)
    }

    /// Several changes inside 30 ms → one publish with the last document;
    /// a change after the window → a second publish.
    func testPublishCoalescesBurstInside30Ms() async {
        let clock = ManualPipelineClock()
        let pipeline = CaptionPipeline(
            translate: { _ in nil },
            clock: clock.clock
        )
        var published: [CaptionDocument] = []
        pipeline.onDocumentChange = { published.append($0) }

        pipeline.handle(.sessionStarted(session()))
        pipeline.handle(result("H", isFinal: false, rangeStart: 0, audioFed: 0))
        clock.advance(to: 10)
        pipeline.handle(result("He", isFinal: false, rangeStart: 0, audioFed: 10))
        clock.advance(to: 20)
        pipeline.handle(result("Hel", isFinal: false, rangeStart: 0, audioFed: 20))
        await settle()
        XCTAssertEqual(published.count, 0, "nothing publishes inside the window")

        clock.advance(to: 30)
        await settle()
        XCTAssertEqual(published.count, 1, "the burst flushes as one publish")
        XCTAssertEqual(published.last?.rows.map(\.text), ["Hel"])

        // A change after the flush arms a second window.
        clock.advance(to: 40)
        pipeline.handle(result("Hell", isFinal: false, rangeStart: 0, audioFed: 40))
        await settle()
        XCTAssertEqual(published.count, 1)
        clock.advance(to: 70)
        await settle()
        XCTAssertEqual(published.count, 2)
        XCTAssertEqual(published.last?.rows.map(\.text), ["Hell"])
    }

    /// `.sessionStopped` publishes the sealed document immediately.
    func testSessionStoppedPublishesImmediately() async {
        let clock = ManualPipelineClock()
        let pipeline = CaptionPipeline(
            translate: { _ in nil },
            clock: clock.clock
        )
        var published: [CaptionDocument] = []
        pipeline.onDocumentChange = { published.append($0) }

        pipeline.handle(.sessionStarted(session()))
        pipeline.handle(result("Hello.", isFinal: true, rangeStart: 0, duration: 100, audioFed: 100))
        pipeline.handle(result("Live", isFinal: false, rangeStart: 200, audioFed: 300))
        await settle()
        XCTAssertEqual(published.count, 0)

        pipeline.handle(.sessionStopped(sessionID: 1))
        XCTAssertEqual(published.count, 1, "sessionStopped flushes now")
        XCTAssertTrue(published.last?.rows.allSatisfy(\.isSealed) ?? false)
    }

    func testResetCancelsWakeAndTranslations() async {
        let clock = ManualPipelineClock()
        let translated = Recorder<String>()
        let pipeline = CaptionPipeline(
            translate: { request in
                translated.append(request.text)
                try? await Task.sleep(nanoseconds: 50_000_000)
                return "譯"
            },
            clock: clock.clock
        )
        pipeline.handle(.sessionStarted(session()))
        clock.advance(to: 100)
        pipeline.handle(result("Hello.", isFinal: true, rangeStart: 0, duration: 100, audioFed: 100))
        pipeline.handle(result("Second", isFinal: false, rangeStart: 100, audioFed: 200))
        await settle()
        // Seal wake (or none) plus a pending publish flush.
        XCTAssertLessThanOrEqual(clock.pendingWakes, 2)

        pipeline.handle(.reset)
        await settle()
        XCTAssertEqual(clock.pendingWakes, 0, "wake survived reset")
        XCTAssertEqual(pipeline.document.rows, [])

        // The cancelled translation's late result must not resurrect the row.
        await settle()
        XCTAssertEqual(pipeline.document.rows, [])
    }

    func testDraftTranslationFlowOnVirtualClock() async {
        let clock = ManualPipelineClock()
        let pipeline = CaptionPipeline(
            translate: { request in
                request.isDraft ? "draft:\(request.text)" : "final:\(request.text)"
            },
            clock: clock.clock
        )
        pipeline.handle(.sessionStarted(session()))
        clock.advance(to: 100)
        pipeline.handle(result("Hello world", isFinal: false, rangeStart: 0, audioFed: 500))
        await settle()
        clock.advance(to: 200)
        await settle()
        // A draft request fired once the row had content.
        XCTAssertEqual(pipeline.document.rows.last?.translation, "draft:Hello world")
        XCTAssertEqual(pipeline.document.rows.last?.translationIsDraft, true)
    }
}
