import Foundation

/// Stable identity for one recognizer lane within a capture session.
struct CaptionLaneID: Hashable, Sendable {
    var sessionID: Int
    var languageID: String
}

/// One attributed run of a recognizer result (word timing plus confidence).
struct AnalyzerRun: Equatable, Sendable {
    var text: String
    var startMs: Int?
    var durationMs: Int?
    var confidence: Double?
}

/// One recognizer result, backend-neutral. `text` is raw and untrimmed; the
/// analyzer's audio range decides which utterance it belongs to.
struct AnalyzerResultEvent: Equatable, Sendable {
    var lane: CaptionLaneID
    var isFinal: Bool
    var rangeStartMs: Int
    var rangeDurationMs: Int
    var finalizationMs: Int?
    var text: String
    var runs: [AnalyzerRun]
    /// Analyzer audio position when the result was observed.
    var audioFedMs: Int
    /// Filled by the session for finals when diarization attributes it.
    var speakerIndex: Int?
}

enum VADEdge: Equatable, Sendable {
    case onset, offset
}

/// What a `LiveTranscriptionSession` emits on its ordered presentation queue.
/// All timestamps are on the session audio clock: milliseconds of processed
/// 16 kHz audio since the session's first buffer.
enum CaptionSessionEvent: Equatable, Sendable {
    case result(AnalyzerResultEvent)
    case vad(VADEdge, audioMs: Int)
}
