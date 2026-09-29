import XCTest
@testable import v2s

/// Replays the recorded `*-natural` SpeechAnalyzer traces through `CaptionCore`
/// on a virtual clock and evaluates every document snapshot with the
/// lead-authored `CaptionScreenOracle`. A fake translator completes each
/// request 180 ms (virtual) later with the flicker harness's deterministic
/// translation.
final class CaptionTraceReplayTests: XCTestCase {
    private let translationLatencyMs = 180.0

    func testEnglishNaturalReplay() throws {
        let outcome = try replay(
            "english-natural",
            config: CaptionSessionConfig(
                sessionID: 1, primaryLanguageID: "en", targetLanguageID: "zh-Hant", translates: true
            ),
            originalLanguageID: "en"
        )
        try assertOutcome(outcome)
    }

    func testMandarinNaturalReplay() throws {
        let outcome = try replay(
            "mandarin-natural",
            config: CaptionSessionConfig(
                sessionID: 1,
                primaryLanguageID: "zh-Hant",
                secondaryLanguageID: "en",
                targetLanguageID: "en",
                translates: true
            ),
            originalLanguageID: "zh-Hant"
        )
        try assertOutcome(outcome)
        // Four rows: the final boundary at "…一直改變" ends a row even though
        // the recognizer left no 。 there.
        XCTAssertEqual(outcome.document.rows.count, 4)
        XCTAssertEqual(
            outcome.document.rows.map(\.text),
            [
                "大家早安 ，謝謝各位今天來參加我們的第一場會議。",
                "我們要談談字幕在講者還在說話的時候應該如何出現在螢幕上因為每一句話在講者說完之前都會一直改變",
                "任何東西都不應該閃爍。",
                "文字也不應該消失之後又出現 ，現在開始吧。",
            ]
        )
        // Every row is zh-Hant; no row consists of Latin text.
        for row in outcome.document.rows {
            XCTAssertEqual(row.languageID, "zh-Hant")
            let hasLatin = row.text.unicodeScalars.contains(where: LanguageIdentity.isLatinScalar)
            let hasCJK = row.text.unicodeScalars.contains(where: LanguageIdentity.isCJKScalar)
            XCTAssertFalse(hasLatin && !hasCJK, "row is Latin-only: \(row.text)")
        }
    }

    func testCodeswitchNaturalReplay() throws {
        let outcome = try replay(
            "codeswitch-natural",
            config: CaptionSessionConfig(
                sessionID: 1,
                primaryLanguageID: "zh-Hant",
                secondaryLanguageID: "en",
                targetLanguageID: "en",
                translates: true
            ),
            originalLanguageID: "zh-Hant"
        )
        try assertOutcome(outcome)
        // Final rows, lexically: zh 今天我們要示範及時字幕 / en Good morning
        // everyone / en Thank you for joining us today / zh 接下來…執行 (one or
        // two rows) / en Any questions so far / en Great let us continue.
        let rows = outcome.document.rows
        XCTAssertGreaterThanOrEqual(rows.count, 6, "rows: \(rows.map(\.text))")
        XCTAssertEqual(rows[0].languageID, "zh-Hant")
        XCTAssertEqual(lexical(rows[0].text), lexical("今天我們要示範及時字幕"))
        XCTAssertEqual(rows[1].languageID, "en")
        XCTAssertEqual(lexical(rows[1].text), lexical("Good morning everyone"))
        XCTAssertEqual(rows[2].languageID, "en")
        XCTAssertEqual(lexical(rows[2].text), lexical("Thank you for joining us today"))
        // zh segment: one or two zh rows whose joined lexical text matches.
        var zhTail = ""
        var index = 3
        while index < rows.count, rows[index].languageID == "zh-Hant" {
            zhTail += lexical(rows[index].text)
            index += 1
        }
        XCTAssertEqual(zhTail, lexical("接下來請大家看一下這個展示它完全在裝置上執行"))
        XCTAssertEqual(rows[index].languageID, "en")
        XCTAssertEqual(lexical(rows[index].text), lexical("Any questions so far"))
        XCTAssertEqual(rows[index + 1].languageID, "en")
        XCTAssertEqual(lexical(rows[index + 1].text), lexical("Great let us continue"))
        XCTAssertEqual(rows.count, index + 2)
    }

    func testMonologueNaturalReplay() throws {
        let outcome = try replay(
            "monologue-natural",
            config: CaptionSessionConfig(
                sessionID: 1, primaryLanguageID: "en", targetLanguageID: "zh-Hant", translates: true
            ),
            originalLanguageID: "en"
        )
        try assertOutcome(outcome)
    }

    /// english-natural ×20 in one session (~535 s of speech): freezing must
    /// keep the retained lane text and per-event cost bounded.
    func testEnglishNaturalTwentyTimesStaysBounded() throws {
        let trace = try AnalyzerTraceFixture.load("english-natural", sessionID: 1)
        var core = CaptionCore()
        _ = core.apply(
            .sessionStarted(
                CaptionSessionConfig(
                    sessionID: 1, primaryLanguageID: "en",
                    targetLanguageID: "zh-Hant", translates: true
                )
            ),
            nowMs: 0
        )
        var now = 0.0
        var completions: [(due: Double, requestID: Int, text: String)] = []
        var maxRetained = 0

        func deliver(_ effects: [CaptionEffect]) {
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
        }

        func advance(to target: Double) {
            while true {
                let nextCompletion = completions.first?.due
                let nextWake = core.nextWakeMs
                if let nextCompletion, nextCompletion <= target,
                   nextWake == nil || nextCompletion <= nextWake! {
                    let pending = completions.removeFirst()
                    now = max(now, pending.due)
                    deliver(core.apply(
                        .translationCompleted(requestID: pending.requestID, text: pending.text),
                        nowMs: now
                    ))
                } else if let nextWake, nextWake <= target {
                    now = max(now, nextWake)
                    deliver(core.apply(.tick, nowMs: now))
                } else {
                    break
                }
            }
            now = max(now, target)
        }

        let steps = Dictionary(grouping: trace.inputs, by: { $0.wallMs })
        let wallTimes = steps.keys.sorted()
        let copySpanMs = Double((wallTimes.last ?? 0) + 1)
        let audioSpanMs = trace.totalAudioMs

        let started = Date()
        for copy in 0..<20 {
            let wallOffset = Double(copy) * copySpanMs
            let audioOffset = copy * audioSpanMs
            for wallMs in wallTimes {
                advance(to: wallOffset + Double(wallMs))
                for step in steps[wallMs] ?? [] {
                    deliver(core.apply(shifted(step.input, audioMs: audioOffset), nowMs: now))
                }
                deliver(core.apply(.tick, nowMs: now))
                if let counts = core.laneCharacterCounts(sessionID: 1) {
                    maxRetained = max(maxRetained, counts.primary + counts.secondary)
                }
            }
        }
        _ = core.apply(.sessionStopped(sessionID: 1), nowMs: now)
        advance(to: .infinity)
        let elapsed = Date().timeIntervalSince(started)

        print("[trace-replay] english×20: maxRetainedChars=\(maxRetained) wall=\(elapsed)s rows=\(core.document.rows.count)")
        XCTAssertLessThan(maxRetained, 2_000, "lane retained characters grew unbounded")
        XCTAssertLessThan(elapsed, 5.0, "20× replay took \(elapsed)s")
        XCTAssertEqual(core.document.rows.count, 20 * 6)
    }

    /// Shifts every audio-timeline field of an input by `audioMs`.
    private func shifted(_ input: CaptionInput, audioMs: Int) -> CaptionInput {
        switch input {
        case .result(let sessionID, var event):
            event.rangeStartMs += audioMs
            event.audioFedMs += audioMs
            if var finalization = event.finalizationMs {
                finalization += audioMs
                event.finalizationMs = finalization
            }
            event.runs = event.runs.map { run in
                var run = run
                if var start = run.startMs { start += audioMs; run.startMs = start }
                return run
            }
            return .result(sessionID: sessionID, event)
        case .vad(let sessionID, let edge, let audio):
            return .vad(sessionID: sessionID, edge, audioMs: audio + audioMs)
        default:
            return input
        }
    }

    // MARK: - Driver

    private struct PendingCompletion {
        var due: Double
        var requestID: Int
        var text: String
    }

    private struct ReplayOutcome {
        var document: CaptionDocument
        var violations: [CaptionViolation]
        var metricsSummary: String
        var metrics: [String: CaptionPaneMetrics]
        var draftRequestsPerRow: [CaptionRowID: Int]
        var draftTimes: [CaptionRowID: [Double]]
        var finalRequestCount: Int
        var sealedTexts: Set<String>
        var rowLiveSeconds: [CaptionRowID: Double]
        var coverage: [(sentence: String, recall: Double)]
        var rowCount: Int
        var draftCount: Int
    }

    /// The three viewport configurations A2 replays every trace through.
    private func viewportConfigs(
        originalLanguageID: String
    ) -> [(name: String, config: CaptionViewportConfig)] {
        let panes = CaptionPaneConfig(
            originalLanguageID: originalLanguageID, showsOriginal: true, showsTranslated: true
        )
        return [
            (
                "overlay",
                CaptionViewportConfig(
                    width: 1_060, height: 190,
                    arrangement: .stacked(leading: .translated),
                    anchoring: .bottom,
                    panes: panes,
                    typography: [
                        .translated: .system(size: 24, weight: .semibold),
                        .original: .system(size: 18, weight: .regular),
                    ],
                    showsSpeakerBadges: false, badgeHeight: 0
                )
            ),
            (
                "overlayColumns",
                CaptionViewportConfig(
                    width: 1_060, height: 150,
                    arrangement: .columns(leading: .original),
                    anchoring: .bottom,
                    panes: panes,
                    typography: [
                        .translated: .system(size: 24, weight: .semibold),
                        .original: .system(size: 18, weight: .regular),
                    ],
                    showsSpeakerBadges: false, badgeHeight: 0
                )
            ),
            (
                "audience",
                CaptionViewportConfig(
                    width: 1_690, height: 950,
                    arrangement: .columns(leading: .original),
                    anchoring: .top,
                    panes: panes,
                    typography: [
                        .translated: .system(size: 48, weight: .semibold),
                        .original: .system(size: 40, weight: .regular),
                    ],
                    showsSpeakerBadges: false, badgeHeight: 0
                )
            ),
        ]
    }

    private func replay(
        _ name: String,
        config: CaptionSessionConfig,
        originalLanguageID: String
    ) throws -> ReplayOutcome {
        let trace = try AnalyzerTraceFixture.load(name, sessionID: config.sessionID)
        var core = CaptionCore()
        _ = core.apply(.sessionStarted(config), nowMs: 0)

        let configs = viewportConfigs(originalLanguageID: originalLanguageID)
        var viewports = configs.map { ($0.name, CaptionViewport()) }
        let configsByName = Dictionary(
            uniqueKeysWithValues: configs.map { ($0.name, $0.config) }
        )

        var now = 0.0
        var screens: [ObservedScreen] = []
        var completions: [PendingCompletion] = []
        var draftsPerRow: [CaptionRowID: Int] = [:]
        var draftTimes: [CaptionRowID: [Double]] = [:]
        var finalRequests = 0
        var sealedTexts: Set<String> = []
        var rowCreatedAt: [CaptionRowID: Double] = [:]
        var rowSealedAt: [CaptionRowID: Double] = [:]
        var rowLastUnsealedAt: [CaptionRowID: Double] = [:]

        func recordEffects(_ effects: [CaptionEffect]) {
            for effect in effects {
                guard case .translate(let request) = effect else { continue }
                if request.isDraft {
                    draftsPerRow[request.rowID, default: 0] += 1
                    draftTimes[request.rowID, default: []].append(now)
                } else {
                    finalRequests += 1
                }
                completions.append(
                    PendingCompletion(
                        due: now + translationLatencyMs,
                        requestID: request.id,
                        text: CaptionE2EHarness.fakeTranslation(
                            request.text,
                            target: request.targetLanguageID
                        )
                    )
                )
                completions.sort { $0.due < $1.due }
            }
        }

        func snapshot() {
            let document = core.document
            var panes: [String: [ObservedLine]] = [:]
            var sourceLines: [ObservedLine] = []
            var translatedLines: [ObservedLine] = []
            for row in document.rows {
                sourceLines.append(
                    ObservedLine(row.text, stable: row.stableLength, startsRow: true)
                )
                translatedLines.append(
                    ObservedLine(
                        row.translation,
                        stable: row.translationIsDraft ? 0 : row.translation.count,
                        startsRow: true
                    )
                )
                if rowCreatedAt[row.id] == nil { rowCreatedAt[row.id] = now }
                if row.isSealed {
                    sealedTexts.insert(row.text)
                    if rowSealedAt[row.id] == nil { rowSealedAt[row.id] = now }
                } else {
                    rowLastUnsealedAt[row.id] = now
                }
            }
            panes["source"] = sourceLines
            panes["translated"] = translatedLines

            // Every snapshot also renders through all three viewports.
            for index in viewports.indices {
                let (name, _) = viewports[index]
                let screen = viewports[index].1.update(
                    document, config: configsByName[name]!
                )
                for pane in [CaptionPane.original, .translated] {
                    let lines = screen.lines
                        .filter { $0.id.pane == pane }
                        .sorted { $0.y < $1.y }
                        .map {
                            ObservedLine(
                                $0.text,
                                stable: $0.isDraft ? 0 : $0.stableCount,
                                startsRow: $0.startsRow
                            )
                        }
                    panes["\(name).\(pane == .original ? "original" : "translated")"] = lines
                }
            }
            screens.append(ObservedScreen(time: now / 1_000, panes: panes))
        }

        /// Deliver completions and scheduled ticks up to `target` in virtual
        /// time order.
        func advance(to target: Double) {
            while true {
                let nextCompletion = completions.first?.due
                let nextWake = core.nextWakeMs
                if let nextCompletion, nextCompletion <= target,
                   nextWake == nil || nextCompletion <= nextWake! {
                    let pending = completions.removeFirst()
                    now = max(now, pending.due)
                    recordEffects(
                        core.apply(
                            .translationCompleted(requestID: pending.requestID, text: pending.text),
                            nowMs: now
                        )
                    )
                    snapshot()
                } else if let nextWake, nextWake <= target {
                    now = max(now, nextWake)
                    recordEffects(core.apply(.tick, nowMs: now))
                    snapshot()
                } else {
                    break
                }
            }
            now = max(now, target)
        }

        // Group inputs by wallMs into steps.
        var steps: [Int: [CaptionInput]] = [:]
        for (wallMs, input) in trace.inputs {
            steps[wallMs, default: []].append(input)
        }
        let wallTimes = steps.keys.sorted()

        for wallMs in wallTimes {
            advance(to: Double(wallMs))
            for input in steps[wallMs] ?? [] {
                recordEffects(core.apply(input, nowMs: Double(wallMs)))
            }
            recordEffects(core.apply(.tick, nowMs: Double(wallMs)))
            snapshot()
        }

        recordEffects(core.apply(.sessionStopped(sessionID: config.sessionID), nowMs: now))
        snapshot()

        // Drain until neither completions nor wakes remain.
        var iterations = 0
        while completions.isEmpty == false || core.nextWakeMs != nil {
            advance(to: .infinity)
            iterations += 1
            XCTAssertLessThan(iterations, 10_000, "replay driver never settled")
            if iterations >= 10_000 { break }
        }

        let report = CaptionScreenOracle.evaluate(screens)
        let transcript = core.document.rows.map(\.text)
        let script = trace.segments.map(\.text).joined(separator: " ")
        var liveSeconds: [CaptionRowID: Double] = [:]
        for (id, created) in rowCreatedAt {
            // Live window: creation → last snapshot where the row was still
            // unsealed (drafts may fire anywhere in it).
            let liveUntil = rowLastUnsealedAt[id] ?? rowSealedAt[id] ?? now
            liveSeconds[id] = (liveUntil - created) / 1_000
        }
        let outcome = ReplayOutcome(
            document: core.document,
            violations: report.violations,
            metricsSummary: report.summary,
            metrics: report.metrics,
            draftRequestsPerRow: draftsPerRow,
            draftTimes: draftTimes,
            finalRequestCount: finalRequests,
            sealedTexts: sealedTexts,
            rowLiveSeconds: liveSeconds,
            coverage: CaptionCoverage.sentenceRecall(script: script, transcript: transcript),
            rowCount: core.document.rows.count,
            draftCount: draftsPerRow.values.reduce(0, +)
        )
        print(
            "[trace-replay] \(name): rows=\(outcome.rowCount) drafts=\(outcome.draftCount) finals=\(outcome.finalRequestCount)"
        )
        print("[trace-replay] \(name) oracle:\n\(outcome.metricsSummary)")
        return outcome
    }

    private func assertOutcome(_ outcome: ReplayOutcome) throws {
        XCTAssertEqual(
            outcome.violations,
            [],
            "oracle violations:\n\(outcome.violations.map(\.description).joined(separator: "\n"))"
        )
        for (pane, metrics) in outcome.metrics {
            XCTAssertEqual(metrics.settledReflows, 0, "settled lines reflowed in \(pane)")
        }
        for entry in outcome.coverage {
            XCTAssertGreaterThanOrEqual(
                entry.recall,
                CaptionCoverage.minimumSentenceRecall,
                "spoken sentence missing from final rows: \(entry.sentence)"
            )
        }
        for row in outcome.document.rows where row.targetLanguageID.isEmpty == false {
            XCTAssertFalse(row.translation.isEmpty, "final row has no translation: \(row.text)")
            XCTAssertFalse(row.translationIsDraft, "final row still draft-translated: \(row.text)")
        }
        XCTAssertEqual(
            outcome.finalRequestCount,
            outcome.sealedTexts.count,
            "final requests must equal distinct sealed row texts"
        )
        for (rowID, count) in outcome.draftRequestsPerRow {
            let liveSeconds = outcome.rowLiveSeconds[rowID] ?? 0
            let times = outcome.draftTimes[rowID] ?? []
            XCTAssertLessThanOrEqual(
                count,
                Int(liveSeconds.rounded(.up)) + 1,
                "row \(rowID.ordinal) got \(count) drafts over \(liveSeconds)s at \(times)"
            )
        }
    }

    private func lexical(_ text: String) -> String {
        String(String.UnicodeScalarView(CaptionScreenOracle.lexical(text)))
    }
}
