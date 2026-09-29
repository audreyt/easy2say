import Foundation

/// Rolling state of one recognizer lane: analyzer finals plus the current
/// volatile hypothesis. Displayed text is `finals` concatenated in audio order
/// followed by the volatile tail; the lane never edits either.
struct CaptionLaneState: Equatable, Sendable {
    struct FinalizedSegment: Equatable, Sendable {
        var rangeStartMs: Int
        var rangeDurationMs: Int
        var text: String
        var runs: [AnalyzerRun]
        var speakerIndex: Int?

        var rangeEndMs: Int { rangeStartMs + rangeDurationMs }
    }

    private(set) var finals: [FinalizedSegment] = []
    private(set) var volatileText = ""
    private(set) var volatileRangeStartMs: Int?
    private(set) var finalizedThroughMs = 0
    /// `audioFedMs` at which each character of `text` first appeared,
    /// parallel to `Array(text)`.
    private(set) var arrivalMs: [Int] = []
    private var previousCharacters: [Character] = []

    init() {}

    /// Finals in audio order followed by the volatile tail, raw.
    var text: String {
        finals.map(\.text).joined() + volatileText
    }

    /// Character count of the finals part of `text`.
    var finalCharacterCount: Int {
        finals.reduce(0) { $0 + $1.text.count }
    }

    mutating func apply(_ event: AnalyzerResultEvent) {
        if event.isFinal {
            let segment = FinalizedSegment(
                rangeStartMs: event.rangeStartMs,
                rangeDurationMs: event.rangeDurationMs,
                text: event.text,
                runs: event.runs,
                speakerIndex: event.speakerIndex
            )
            if let index = finals.firstIndex(where: { $0.rangeStartMs == event.rangeStartMs }) {
                finals[index] = segment
            } else {
                finals.append(segment)
                finals.sort { $0.rangeStartMs < $1.rangeStartMs }
            }
            if let volatileStart = volatileRangeStartMs, volatileStart < segment.rangeEndMs {
                volatileText = ""
                volatileRangeStartMs = nil
            }
            finalizedThroughMs = max(finalizedThroughMs, event.finalizationMs ?? segment.rangeEndMs)
        } else {
            // A volatile behind the finalization frontier is stale.
            guard event.rangeStartMs >= finalizedThroughMs - 50 else { return }
            volatileText = event.text
            volatileRangeStartMs = event.rangeStartMs
        }
        stampArrivals(audioFedMs: event.audioFedMs)
    }

    /// Mean of the non-nil run confidences of one final, nil when unannotated.
    func meanConfidence(ofFinalAt index: Int) -> Double? {
        var total = 0.0
        var count = 0
        for run in finals[index].runs {
            if let confidence = run.confidence {
                total += confidence
                count += 1
            }
        }
        return count > 0 ? total / Double(count) : nil
    }

    /// Removes the first `count` finals and their characters/arrival stamps
    /// from the lane. Later finals, the volatile tail, and
    /// `finalizedThroughMs` are untouched; used by core freezing so a long
    /// session does not recompose an ever-growing transcript.
    mutating func dropLeadingFinals(_ count: Int) {
        let dropped = min(count, finals.count)
        guard dropped > 0 else { return }
        let characters = finals.prefix(dropped).reduce(0) { $0 + $1.text.count }
        finals.removeFirst(dropped)
        arrivalMs.removeFirst(min(characters, arrivalMs.count))
        previousCharacters.removeFirst(min(characters, previousCharacters.count))
    }

    /// Characters that survived the last apply keep their arrival stamp;
    /// everything after the common prefix is stamped with this event's
    /// `audioFedMs`. Volatile is append-only, so only the tail re-stamps.
    private mutating func stampArrivals(audioFedMs: Int) {
        let newCharacters = Array(text)
        var common = 0
        while common < previousCharacters.count,
              common < newCharacters.count,
              previousCharacters[common] == newCharacters[common] {
            common += 1
        }
        arrivalMs = Array(arrivalMs.prefix(common))
        while arrivalMs.count < newCharacters.count {
            arrivalMs.append(audioFedMs)
        }
        previousCharacters = newCharacters
    }
}
