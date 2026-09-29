import XCTest
@testable import v2s

final class CaptionCoreTests: XCTestCase {
    private let config = CaptionSessionConfig(
        sessionID: 1,
        primaryLanguageID: "en",
        targetLanguageID: "zh-Hant",
        translates: true
    )

    private func sessionConfig(_ sessionID: Int) -> CaptionSessionConfig {
        CaptionSessionConfig(
            sessionID: sessionID,
            primaryLanguageID: "en",
            targetLanguageID: "zh-Hant",
            translates: true
        )
    }

    private func result(
        _ text: String,
        isFinal: Bool,
        rangeStart: Int,
        duration: Int = 0,
        audioFed: Int,
        sessionID: Int = 1,
        language: String = "en"
    ) -> CaptionInput {
        .result(
            sessionID: sessionID,
            AnalyzerResultEvent(
                lane: CaptionLaneID(sessionID: sessionID, languageID: language),
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

    private func translates(_ effects: [CaptionEffect]) -> [CaptionTranslationRequest] {
        effects.compactMap { effect in
            guard case .translate(let request) = effect else { return nil }
            return request
        }
    }

    func testRowsAppendThenSealAndTranslateOnce() {
        var core = CaptionCore()
        _ = core.apply(.sessionStarted(config), nowMs: 0)

        let effects = core.apply(
            result("Hello world.", isFinal: false, rangeStart: 0, audioFed: 900),
            nowMs: 100
        )
        XCTAssertEqual(core.document.rows.map(\.text), ["Hello world."])
        // First live draft goes immediately (terminated word + space-free still
        // needs ≥1 complete word; "Hello world." has one).
        XCTAssertEqual(translates(effects).count, 1)
        XCTAssertTrue(translates(effects)[0].isDraft)

        // A second row seals the first → exactly one final request.
        let finalEffects = core.apply(
            result("Hello world. Next li", isFinal: false, rangeStart: 0, audioFed: 1400),
            nowMs: 500
        )
        XCTAssertEqual(core.document.rows.map(\.text), ["Hello world.", "Next li"])
        XCTAssertTrue(core.document.rows[0].isSealed)
        let finals = translates(finalEffects).filter { $0.isDraft == false }
        XCTAssertEqual(finals.map(\.text), ["Hello world."])
    }

    func testDraftThrottleSpacingAndInFlight() {
        var core = CaptionCore()
        _ = core.apply(.sessionStarted(config), nowMs: 0)

        let first = core.apply(result("Hello wo", isFinal: false, rangeStart: 0, audioFed: 300), nowMs: 0)
        XCTAssertEqual(translates(first).count, 1)
        let firstID = translates(first)[0].id

        // Changed text, in-flight draft → no new request.
        let second = core.apply(result("Hello wor", isFinal: false, rangeStart: 0, audioFed: 500), nowMs: 200)
        XCTAssertEqual(translates(second).count, 0)

        // Complete the first draft; too soon for another → schedules a wake.
        let third = core.apply(.translationCompleted(requestID: firstID, text: "問好"), nowMs: 400)
        XCTAssertEqual(translates(third).count, 0)
        XCTAssertEqual(core.nextWakeMs, 1000)

        // Tick at the scheduled time fires the next draft.
        let fourth = core.apply(.tick, nowMs: 1000)
        XCTAssertEqual(translates(fourth).count, 1)
        XCTAssertTrue(translates(fourth)[0].isDraft)
        XCTAssertEqual(translates(fourth)[0].text, "Hello wor")
    }

    func testVADOffsetSealsTerminatedLastRowAfter500ms() {
        var core = CaptionCore()
        _ = core.apply(.sessionStarted(config), nowMs: 0)
        _ = core.apply(result("All done.", isFinal: false, rangeStart: 0, audioFed: 900), nowMs: 900)
        _ = core.apply(.vad(sessionID: 1, .offset, audioMs: 1000), nowMs: 1000)
        XCTAssertFalse(core.document.rows[0].isSealed)
        XCTAssertEqual(core.nextWakeMs, 1500)
        let effects = core.apply(.tick, nowMs: 1500)
        XCTAssertTrue(core.document.rows[0].isSealed)
        XCTAssertEqual(translates(effects).filter { $0.isDraft == false }.map(\.text), ["All done."])
    }

    func testOnsetBefore500msCancelsOffsetSeal() {
        var core = CaptionCore()
        _ = core.apply(.sessionStarted(config), nowMs: 0)
        _ = core.apply(result("All done.", isFinal: false, rangeStart: 0, audioFed: 900), nowMs: 900)
        _ = core.apply(.vad(sessionID: 1, .offset, audioMs: 1000), nowMs: 1000)
        _ = core.apply(.vad(sessionID: 1, .onset, audioMs: 1200), nowMs: 1200)
        _ = core.apply(.tick, nowMs: 1600)
        XCTAssertFalse(core.document.rows[0].isSealed)
        // But 1500 ms of no new characters seals it anyway.
        _ = core.apply(.tick, nowMs: 2400)
        XCTAssertTrue(core.document.rows[0].isSealed)
    }

    func testIdleSealAfter1500msAndUnsealOnNewCharacters() {
        var core = CaptionCore()
        _ = core.apply(.sessionStarted(config), nowMs: 0)
        _ = core.apply(result("Still talking", isFinal: false, rangeStart: 0, audioFed: 100), nowMs: 100)
        _ = core.apply(.tick, nowMs: 100 + 1_499)
        XCTAssertFalse(core.document.rows[0].isSealed)
        _ = core.apply(.tick, nowMs: 100 + 1_500)
        XCTAssertTrue(core.document.rows[0].isSealed)
        // New characters unseal it again.
        _ = core.apply(result("Still talking now", isFinal: false, rangeStart: 0, audioFed: 3200), nowMs: 3200)
        XCTAssertFalse(core.document.rows[0].isSealed)
    }

    func testMonotonicTranslationDisplay() {
        var core = CaptionCore()
        _ = core.apply(.sessionStarted(config), nowMs: 0)
        let e1 = core.apply(result("Hello wo", isFinal: false, rangeStart: 0, audioFed: 300), nowMs: 0)
        let draftID = translates(e1)[0].id
        _ = core.apply(.translationCompleted(requestID: draftID, text: "你好"), nowMs: 200)
        XCTAssertEqual(core.document.rows[0].translation, "你好")
        XCTAssertTrue(core.document.rows[0].translationIsDraft)

        // Text changes: display keeps the arrived translation (draft flag stays).
        _ = core.apply(result("Hello world.", isFinal: false, rangeStart: 0, audioFed: 600), nowMs: 600)
        XCTAssertEqual(core.document.rows[0].translation, "你好")
        XCTAssertTrue(core.document.rows[0].translationIsDraft)

        // Seal it (a second row appears) → one final request for the sealed text.
        let sealEffects = core.apply(
            result("Hello world. Next", isFinal: false, rangeStart: 0, audioFed: 900),
            nowMs: 900
        )
        let finals = translates(sealEffects).filter { $0.isDraft == false }
        XCTAssertEqual(finals.map(\.text), ["Hello world."])

        // Its completion lands → exact-text final translation, non-draft.
        _ = core.apply(.translationCompleted(requestID: finals[0].id, text: "你好世界。"), nowMs: 1100)
        XCTAssertEqual(core.document.rows[0].translation, "你好世界。")
        XCTAssertFalse(core.document.rows[0].translationIsDraft)
    }

    func testFinalTranslationRetryOnceAfterFailure() {
        var core = CaptionCore()
        _ = core.apply(.sessionStarted(config), nowMs: 0)
        _ = core.apply(result("Hello world.", isFinal: false, rangeStart: 0, audioFed: 900), nowMs: 900)
        let sealEffects = core.apply(
            result("Hello world. Tail", isFinal: false, rangeStart: 0, audioFed: 1200),
            nowMs: 1200
        )
        let finalRequest = translates(sealEffects).first { $0.isDraft == false }
        XCTAssertNotNil(finalRequest)

        // Failure → the row-0 text may not be re-requested for 2 s. (Row 1
        // "Tail" idle-seals meanwhile and gets its own final.)
        _ = core.apply(.translationCompleted(requestID: finalRequest!.id, text: nil), nowMs: 1500)
        let early = translates(core.apply(.tick, nowMs: 3400))
        XCTAssertEqual(early.filter { $0.text == "Hello world." }.count, 0)
        let retry = translates(core.apply(.tick, nowMs: 3500))
            .filter { $0.isDraft == false && $0.text == "Hello world." }
        XCTAssertEqual(retry.count, 1)

        // A second failure is not retried.
        _ = core.apply(.translationCompleted(requestID: retry[0].id, text: nil), nowMs: 3600)
        XCTAssertEqual(translates(core.apply(.tick, nowMs: 6000)).filter { $0.text == "Hello world." }.count, 0)
    }

    func testRevisionDoesNotMoveOnNoChange() {
        var core = CaptionCore()
        _ = core.apply(.sessionStarted(config), nowMs: 0)
        _ = core.apply(result("Hello", isFinal: false, rangeStart: 0, audioFed: 100), nowMs: 100)
        let revision = core.document.revision
        _ = core.apply(result("Hello", isFinal: false, rangeStart: 0, audioFed: 200), nowMs: 200)
        XCTAssertEqual(core.document.revision, revision)
        _ = core.apply(.tick, nowMs: 300)
        XCTAssertEqual(core.document.revision, revision)
    }

    func testSessionStoppedSealsAndFinalizesAllRows() {
        var core = CaptionCore()
        _ = core.apply(.sessionStarted(config), nowMs: 0)
        _ = core.apply(result("Good morni", isFinal: false, rangeStart: 0, audioFed: 300), nowMs: 300)
        let effects = core.apply(.sessionStopped(sessionID: 1), nowMs: 400)
        XCTAssertTrue(core.document.rows[0].isSealed)
        XCTAssertTrue(core.document.rows[0].isFinal)
        XCTAssertEqual(translates(effects).filter { $0.isDraft == false }.count, 1)
    }

    func testResetClearsDocument() {
        var core = CaptionCore()
        _ = core.apply(.sessionStarted(config), nowMs: 0)
        _ = core.apply(result("Hello", isFinal: false, rangeStart: 0, audioFed: 100), nowMs: 100)
        _ = core.apply(.reset, nowMs: 200)
        XCTAssertEqual(core.document.rows, [])
        XCTAssertEqual(core.nextWakeMs, nil)
    }

    func testRowsAcrossSessionsOrderByCreationTime() {
        var core = CaptionCore()
        _ = core.apply(.sessionStarted(sessionConfig(1)), nowMs: 0)
        _ = core.apply(.sessionStarted(sessionConfig(2)), nowMs: 0)

        // Session 1's first row appears before session 2's.
        _ = core.apply(
            result("One alpha.", isFinal: false, rangeStart: 0, audioFed: 100, sessionID: 1),
            nowMs: 100
        )
        _ = core.apply(
            result("Two alpha.", isFinal: false, rangeStart: 0, audioFed: 200, sessionID: 2),
            nowMs: 200
        )
        // Session 1's SECOND row arrives later — it must land below session 2's
        // row, not above it.
        _ = core.apply(
            result("One alpha. One beta.", isFinal: false, rangeStart: 0, audioFed: 300, sessionID: 1),
            nowMs: 300
        )
        _ = core.apply(
            result("Two alpha. Two beta.", isFinal: false, rangeStart: 0, audioFed: 400, sessionID: 2),
            nowMs: 400
        )

        let order = core.document.rows.map { "\($0.id.sessionID):\($0.id.ordinal)" }
        XCTAssertEqual(order, ["1:0", "2:0", "1:1", "2:1"])
        // Rows are appended chronologically — never inserted above an older
        // row of another session.
        let created = core.document.rows.map(\.createdMs)
        XCTAssertEqual(created, created.sorted())
    }
}
