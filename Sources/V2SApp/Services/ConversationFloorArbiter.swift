import Foundation

/// Decides which of two locale-pinned transcribers is hearing the current speaker.
///
/// Apple's Speech stack has no spoken-language identification API: `SpeechTranscriber`
/// is pinned to exactly one `Locale`, and a transcriber fed audio in a language it was
/// not built for still emits confident-looking text in its own script. A conversation
/// session therefore runs both of the session's languages over the same microphone
/// capture and arbitrates between their hypotheses.
///
/// Both lanes report a mean `transcriptionConfidence` for the same audio, so the
/// discriminating signal is the confidence gap. Raw comparison flickers — the two lanes
/// trade the lead several times per second early in an utterance — so a challenger must
/// clear `margin` for `requiredWins` consecutive observations before the floor moves.
/// Once a lane has produced a finalized result the floor is sticky until the next
/// utterance starts, which keeps a finished turn from being retroactively reassigned.
///
/// This type is a value type with no dependencies so the policy is unit-testable
/// without audio, a recognizer, or a main actor.
struct ConversationFloorArbiter: Equatable, Sendable {
    /// What one lane heard for the audio observed so far.
    struct Observation: Equatable, Sendable {
        /// Mean transcription confidence in `0...1`.
        let confidence: Double
        /// The lane's current hypothesis. An empty hypothesis never wins the floor.
        let text: String
        /// Whether the lane has finalized this utterance.
        let isFinal: Bool

        init(confidence: Double, text: String, isFinal: Bool = false) {
            self.confidence = confidence
            self.text = text
            self.isFinal = isFinal
        }

        static let silent = Observation(confidence: 0, text: "", isFinal: false)

        var hasSpeech: Bool {
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }

    /// Confidence advantage a challenger must hold to be considered ahead.
    let margin: Double
    /// Consecutive ahead-by-`margin` observations required before the floor moves.
    let requiredWins: Int

    private(set) var floor: ConversationSide
    /// Set while the user has explicitly claimed a side. A pin overrides scoring
    /// until the utterance it applies to has committed.
    private(set) var pinnedSide: ConversationSide?
    private var challenger: ConversationSide?
    private var challengerWins = 0
    private var isFloorSticky = false

    init(
        floor: ConversationSide = .primary,
        margin: Double = 0.08,
        requiredWins: Int = 3
    ) {
        self.floor = floor
        self.margin = max(0, margin)
        self.requiredWins = max(1, requiredWins)
    }

    var hasPinnedFloor: Bool {
        pinnedSide != nil
    }

    /// Forces the floor to `side` and holds it there until the next commit.
    ///
    /// Used by the two "I'm speaking" targets: in a loud room the fastest way to fix a
    /// misattributed turn is to claim the floor by hand rather than to out-argue the
    /// arbiter.
    mutating func pin(_ side: ConversationSide) {
        pinnedSide = side
        floor = side
        challenger = nil
        challengerWins = 0
        isFloorSticky = false
    }

    /// Clears per-utterance state. Called when a turn commits or the session resets,
    /// so the next utterance is scored from scratch.
    mutating func commitUtterance() {
        pinnedSide = nil
        challenger = nil
        challengerWins = 0
        isFloorSticky = false
    }

    /// Folds one observation per lane into the floor decision.
    ///
    /// - Returns: `true` when the floor moved, so the caller can migrate the in-flight
    ///   draft to the other lane.
    @discardableResult
    mutating func observe(
        primary: Observation,
        secondary: Observation
    ) -> Bool {
        if let pinnedSide {
            floor = pinnedSide
            return false
        }

        let incumbent = floor == .primary ? primary : secondary
        let contender = floor == .primary ? secondary : primary

        // A finalized incumbent owns the rest of the utterance.
        if incumbent.isFinal, incumbent.hasSpeech {
            isFloorSticky = true
        }
        if isFloorSticky {
            challenger = nil
            challengerWins = 0
            return false
        }

        // Silence on the challenging lane is not evidence.
        guard contender.hasSpeech else {
            challenger = nil
            challengerWins = 0
            return false
        }

        // An incumbent with nothing to say yields immediately: the other lane is the
        // only one hearing words, and waiting out the margin would drop the opening
        // of the utterance.
        if incumbent.hasSpeech == false {
            return moveFloor()
        }

        guard contender.confidence >= incumbent.confidence + margin else {
            challenger = nil
            challengerWins = 0
            return false
        }

        let contenderSide = floor.opposite
        if challenger == contenderSide {
            challengerWins += 1
        } else {
            challenger = contenderSide
            challengerWins = 1
        }

        guard challengerWins >= requiredWins else {
            return false
        }

        return moveFloor()
    }

    /// Resolves the floor when one lane finalizes the utterance. A final decision uses
    /// one confidence comparison instead of waiting for three volatile updates, then
    /// stays sticky until the engine commits the turn.
    @discardableResult
    mutating func resolveFinal(
        primary: Observation,
        secondary: Observation
    ) -> Bool {
        if let pinnedSide {
            floor = pinnedSide
            return false
        }

        let incumbent = floor == .primary ? primary : secondary
        let contender = floor == .primary ? secondary : primary
        let shouldMove = contender.hasSpeech
            && (incumbent.hasSpeech == false
                || contender.confidence >= incumbent.confidence + margin)
        let moved = shouldMove ? moveFloor() : false
        isFloorSticky = true
        return moved
    }

    private mutating func moveFloor() -> Bool {
        floor = floor.opposite
        challenger = nil
        challengerWins = 0
        return true
    }
}
