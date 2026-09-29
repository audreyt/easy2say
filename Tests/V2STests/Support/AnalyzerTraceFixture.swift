import Foundation
@testable import v2s

/// Loads a recorded SpeechAnalyzer probe trace (`Fixtures/AnalyzerTraces/*.jsonl`,
/// schema per PROBE_SPEC.md) into `CaptionInput`s for replay through
/// `CaptionCore`. Module identifiers map to caption language IDs ("zh-TW" →
/// "zh-Hant", "en-US" → "en"); finalize events are dropped.
enum AnalyzerTraceFixture {
    struct Segment {
        var voice: String
        var text: String
    }

    struct Trace {
        var scenario: String
        var modules: [String]
        var segments: [Segment]
        var totalAudioMs: Int
        /// Ordered by the `wallMs` recorded at observation time.
        var inputs: [(wallMs: Int, input: CaptionInput)]
    }

    static func load(_ name: String, sessionID: Int) throws -> Trace {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: "jsonl",
            subdirectory: "Fixtures/AnalyzerTraces"
        ) else {
            throw NSError(
                domain: "AnalyzerTraceFixture",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "fixture \(name).jsonl not found"]
            )
        }
        let content = try String(contentsOf: url, encoding: .utf8)
        var scenario = ""
        var modules: [String] = []
        var segments: [Segment] = []
        var totalAudioMs = 0
        var inputs: [(wallMs: Int, input: CaptionInput)] = []

        for line in content.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                  let event = object as? [String: Any],
                  let type = event["type"] as? String else {
                continue
            }
            switch type {
            case "meta":
                scenario = event["scenario"] as? String ?? ""
                modules = event["modules"] as? [String] ?? []
                totalAudioMs = event["totalAudioMs"] as? Int ?? 0
                segments = (event["segments"] as? [[String: Any]] ?? []).map {
                    Segment(voice: $0["voice"] as? String ?? "", text: $0["text"] as? String ?? "")
                }
            case "result":
                let wallMs = event["wallMs"] as? Int ?? 0
                let module = event["module"] as? String ?? ""
                let result = AnalyzerResultEvent(
                    lane: CaptionLaneID(sessionID: sessionID, languageID: languageID(for: module)),
                    isFinal: event["isFinal"] as? Bool ?? false,
                    rangeStartMs: event["rangeStartMs"] as? Int ?? 0,
                    rangeDurationMs: event["rangeDurMs"] as? Int ?? 0,
                    finalizationMs: event["finalizationMs"] as? Int,
                    text: event["text"] as? String ?? "",
                    runs: (event["runs"] as? [[String: Any]] ?? []).map {
                        AnalyzerRun(
                            text: $0["t"] as? String ?? "",
                            startMs: $0["s"] as? Int,
                            durationMs: $0["d"] as? Int,
                            confidence: $0["c"] as? Double
                        )
                    },
                    audioFedMs: event["audioFedMs"] as? Int ?? 0,
                    speakerIndex: nil
                )
                inputs.append((wallMs: wallMs, input: .result(sessionID: sessionID, result)))
            case "vad":
                let wallMs = event["wallMs"] as? Int ?? 0
                let edge: VADEdge = (event["edge"] as? String) == "onset" ? .onset : .offset
                inputs.append(
                    (wallMs: wallMs, input: .vad(sessionID: sessionID, edge, audioMs: event["audioMs"] as? Int ?? 0))
                )
            default:
                // meta, finalizeCall, finalizeReturn, end
                continue
            }
        }
        return Trace(
            scenario: scenario,
            modules: modules,
            segments: segments,
            totalAudioMs: totalAudioMs,
            inputs: inputs
        )
    }

    private static func languageID(for module: String) -> String {
        LanguageIdentity.canonicalLanguageID(module)
    }
}
