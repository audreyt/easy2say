import Foundation

/// One lane's hypothesis for the audio observed so far. Shared by conversation
/// mode and caption dual-lane reverse so pairing rules stay one convention.
struct DualLaneHypothesis: Equatable, Sendable {
    var volatileText = ""
    var confidence: Double?
    var finalizedText: String?
    var startSeconds: Double = 0
    var endSeconds: Double = 0

    var hasSpeech: Bool {
        (finalizedText ?? volatileText).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var arbiterObservation: ConversationFloorArbiter.Observation {
        ConversationFloorArbiter.Observation(
            confidence: confidence,
            text: finalizedText ?? volatileText,
            isFinal: finalizedText != nil
        )
    }
}

struct DualLaneObservation: Equatable, Sendable {
    var side: ConversationSide
    var text: String
    var confidence: Double?
    var isFinal: Bool
    var startSeconds: Double
    var endSeconds: Double
}

/// Immutable arbitration evidence from dual-lane recognition.
struct DualLaneEvidence: Equatable, Sendable {
    let arbiterFloor: ConversationSide
    let selectedSide: ConversationSide
    let resolution: CaptionLaneResolution
    let winnerConfidence: Double?
    let competingConfidence: Double?
    let primaryScript: CaptionLanguagePolicy.HeardScript
    let secondaryScript: CaptionLanguagePolicy.HeardScript
    let isMixedSpeechSuspected: Bool

    init(
        arbiterFloor: ConversationSide = .primary,
        selectedSide: ConversationSide = .primary,
        resolution: CaptionLaneResolution = .normalMandarinOrMixed,
        winnerConfidence: Double? = nil,
        competingConfidence: Double? = nil,
        primaryScript: CaptionLanguagePolicy.HeardScript = .empty,
        secondaryScript: CaptionLanguagePolicy.HeardScript = .empty,
        isMixedSpeechSuspected: Bool = false
    ) {
        self.arbiterFloor = arbiterFloor
        self.selectedSide = selectedSide
        self.resolution = resolution
        self.winnerConfidence = winnerConfidence
        self.competingConfidence = competingConfidence
        self.primaryScript = primaryScript
        self.secondaryScript = secondaryScript
        self.isMixedSpeechSuspected = isMixedSpeechSuspected
    }
}

struct DualLaneStep: Equatable, Sendable {
    var floor: ConversationSide
    var floorMoved: Bool
    var draftSide: ConversationSide?
    var draftText: String?
    var commitSide: ConversationSide?
    var commitText: String?
    var evidence: DualLaneEvidence?
    var isPendingFinalGrace: Bool = false
}

/// Confidence-gap pairing for two locale-pinned transcribers sharing one capture.
///
/// Copied from the conversation engine's proven rules: overlapping ranges, both
/// lanes advanced before a volatile comparison, and never awarding a turn merely
/// because the wrong-language lane finalized first.
struct DualLanePairing: Equatable, Sendable {
    typealias LanePolicy = CaptionLanguagePolicy.CaptionLanePolicy

    static let defaultLanePolicy: LanePolicy = { primaryText, secondaryText, primaryConfidence, secondaryConfidence, arbiterFloor in
        CaptionLanguagePolicy.defaultResolveCaptionLane(
            primaryText: primaryText,
            secondaryText: secondaryText,
            primaryConfidence: primaryConfidence,
            secondaryConfidence: secondaryConfidence,
            arbiterFloor: arbiterFloor
        )
    }

    static let audioTimelineTolerance: Double = 0.05
    static let arbitrationAdvanceTolerance: Double = 0.005

    var arbiter = ConversationFloorArbiter()
    var hypotheses: [ConversationSide: DualLaneHypothesis] = [
        .primary: DualLaneHypothesis(),
        .secondary: DualLaneHypothesis(),
    ]
    var lastArbitratedEndSeconds: [ConversationSide: Double] = [:]
    var committedAudioEndSeconds: Double = 0
    private(set) var unavailableSide: ConversationSide?
    var lanePolicy: LanePolicy = Self.defaultLanePolicy

    static func == (lhs: DualLanePairing, rhs: DualLanePairing) -> Bool {
        lhs.arbiter == rhs.arbiter
            && lhs.hypotheses == rhs.hypotheses
            && lhs.lastArbitratedEndSeconds == rhs.lastArbitratedEndSeconds
            && lhs.committedAudioEndSeconds == rhs.committedAudioEndSeconds
            && lhs.unavailableSide == rhs.unavailableSide
    }

    var floor: ConversationSide {
        arbiter.floor
    }

    var hasPendingSoleFinalist: Bool {
        let hasPrimary = hypotheses[.primary]?.finalizedText != nil
        let hasSecondary = hypotheses[.secondary]?.finalizedText != nil
        return (hasPrimary && !hasSecondary) || (hasSecondary && !hasPrimary)
    }

    @discardableResult
    mutating func markLaneUnavailable(_ side: ConversationSide) -> DualLaneStep? {
        unavailableSide = side
        guard side == .secondary else {
            return nil
        }
        let didMoveFloor = updateFloor()
        let floor = arbiter.floor
        if let commitText = finalizedFloorReadyToCommit() {
            let primaryText = hypotheses[.primary]?.finalizedText ?? hypotheses[.primary]?.volatileText ?? ""
            let secondaryText = hypotheses[.secondary]?.finalizedText ?? hypotheses[.secondary]?.volatileText ?? ""
            let primScript = CaptionLanguagePolicy.classifyHeardScript(primaryText)
            let secScript = CaptionLanguagePolicy.classifyHeardScript(secondaryText)
            let winConf = hypotheses[floor]?.confidence
            let compConf = hypotheses[floor.opposite]?.confidence

            let (_, resolution) = lanePolicy(
                primaryText,
                secondaryText,
                hypotheses[.primary]?.confidence,
                hypotheses[.secondary]?.confidence,
                floor
            )

            var step = DualLaneStep(floor: floor, floorMoved: didMoveFloor)
            step.commitSide = floor
            step.commitText = commitText
            step.evidence = DualLaneEvidence(
                arbiterFloor: floor,
                selectedSide: floor,
                resolution: resolution,
                winnerConfidence: winConf,
                competingConfidence: compConf,
                primaryScript: primScript,
                secondaryScript: secScript,
                isMixedSpeechSuspected: resolution == .normalMandarinOrMixed && primScript == .containsHan
            )
            resetUtterance()
            return step
        }
        return nil
    }

    mutating func resetUtterance() {
        hypotheses = [.primary: DualLaneHypothesis(), .secondary: DualLaneHypothesis()]
        lastArbitratedEndSeconds = [:]
        arbiter.commitUtterance()
    }

    mutating func noteCommittedAudioEnd(_ endSeconds: Double) {
        committedAudioEndSeconds = max(committedAudioEndSeconds, endSeconds)
    }

    mutating func commitSoleFinalist() -> DualLaneStep? {
        let primaryText = hypotheses[.primary]?.finalizedText ?? hypotheses[.primary]?.volatileText ?? ""
        let secondaryText = hypotheses[.secondary]?.finalizedText ?? hypotheses[.secondary]?.volatileText ?? ""
        guard primaryText.isEmpty == false || secondaryText.isEmpty == false else { return nil }

        let primConf = hypotheses[.primary]?.confidence
        let secConf = hypotheses[.secondary]?.confidence
        let primScript = CaptionLanguagePolicy.classifyHeardScript(primaryText)
        let secScript = CaptionLanguagePolicy.classifyHeardScript(secondaryText)

        let candidateSide: ConversationSide = hypotheses[.primary]?.finalizedText != nil ? .primary : (hypotheses[.secondary]?.finalizedText != nil ? .secondary : floor)

        let (selectedSide, resolution) = lanePolicy(
            primaryText,
            secondaryText,
            primConf,
            secConf,
            candidateSide
        )

        // If secondary was selected, resolution MUST be .pureEnglish; never secondary + normal
        if selectedSide == .secondary && resolution != .pureEnglish {
            return nil
        }

        let effectiveCommitText = selectedSide == .primary
            ? (hypotheses[.primary]?.finalizedText ?? hypotheses[.primary]?.volatileText ?? "")
            : (hypotheses[.secondary]?.finalizedText ?? "")

        guard effectiveCommitText.isEmpty == false else { return nil }

        if floor != selectedSide {
            arbiter.pin(selectedSide)
        }

        var step = DualLaneStep(floor: selectedSide, floorMoved: true)
        step.commitSide = selectedSide
        step.commitText = effectiveCommitText
        step.evidence = DualLaneEvidence(
            arbiterFloor: candidateSide,
            selectedSide: selectedSide,
            resolution: resolution,
            winnerConfidence: hypotheses[selectedSide]?.confidence,
            competingConfidence: hypotheses[selectedSide.opposite]?.confidence,
            primaryScript: primScript,
            secondaryScript: secScript,
            isMixedSpeechSuspected: resolution == .normalMandarinOrMixed && primScript == .containsHan
        )
        resetUtterance()
        return step
    }

    mutating func ingest(_ observation: DualLaneObservation) -> DualLaneStep {
        var hypothesis = hypotheses[observation.side] ?? DualLaneHypothesis()
        hypothesis.confidence = observation.confidence
        hypothesis.startSeconds = observation.startSeconds
        hypothesis.endSeconds = observation.endSeconds
        if observation.isFinal {
            hypothesis.finalizedText = observation.text
        } else {
            hypothesis.volatileText = observation.text
            hypothesis.finalizedText = nil
        }
        hypotheses[observation.side] = hypothesis

        let didMoveFloor = updateFloor()
        let floor = arbiter.floor
        var step = DualLaneStep(floor: floor, floorMoved: didMoveFloor)

        if let commitText = finalizedFloorReadyToCommit() {
            let primaryText = hypotheses[.primary]?.finalizedText ?? hypotheses[.primary]?.volatileText ?? ""
            let secondaryText = hypotheses[.secondary]?.finalizedText ?? hypotheses[.secondary]?.volatileText ?? ""
            let primConf = hypotheses[.primary]?.confidence
            let secConf = hypotheses[.secondary]?.confidence
            let primScript = CaptionLanguagePolicy.classifyHeardScript(primaryText)
            let secScript = CaptionLanguagePolicy.classifyHeardScript(secondaryText)
            let (selectedSide, resolution) = lanePolicy(
                primaryText,
                secondaryText,
                primConf,
                secConf,
                floor
            )

            let effectiveCommitText = selectedSide == .primary ? primaryText : (hypotheses[.secondary]?.finalizedText ?? commitText)

            step.floor = selectedSide
            step.commitSide = selectedSide
            step.commitText = effectiveCommitText
            step.evidence = DualLaneEvidence(
                arbiterFloor: floor,
                selectedSide: selectedSide,
                resolution: resolution,
                winnerConfidence: hypotheses[selectedSide]?.confidence,
                competingConfidence: hypotheses[selectedSide.opposite]?.confidence,
                primaryScript: primScript,
                secondaryScript: secScript,
                isMixedSpeechSuspected: resolution == .normalMandarinOrMixed && primScript == .containsHan
            )
            noteCommittedAudioEnd(hypotheses[selectedSide]?.endSeconds ?? committedAudioEndSeconds)
            resetUtterance()
            return step
        }

        step.isPendingFinalGrace = hasPendingSoleFinalist

        if let primaryDraft = hypotheses[.primary]?.volatileText, primaryDraft.isEmpty == false {
            step.draftSide = .primary
            step.draftText = primaryDraft
        }
        return step
    }

    mutating func updateFloor() -> Bool {
        if let unavailableSide {
            let survivor = unavailableSide.opposite
            if floor != survivor {
                arbiter.pin(survivor)
                return true
            }
            return false
        }

        guard let primary = hypotheses[.primary],
              let secondary = hypotheses[.secondary],
              rangesAlign(primary, secondary) else {
            return false
        }

        let bothFinalized = primary.finalizedText != nil && secondary.finalizedText != nil

        if bothFinalized {
            lastArbitratedEndSeconds[.primary] = primary.endSeconds
            lastArbitratedEndSeconds[.secondary] = secondary.endSeconds
            return arbiter.resolveFinal(
                primary: primary.arbiterObservation,
                secondary: secondary.arbiterObservation
            )
        }

        guard primary.endSeconds
                > (lastArbitratedEndSeconds[.primary] ?? 0)
                    + Self.arbitrationAdvanceTolerance,
              secondary.endSeconds
                > (lastArbitratedEndSeconds[.secondary] ?? 0)
                    + Self.arbitrationAdvanceTolerance else {
            return false
        }

        lastArbitratedEndSeconds[.primary] = primary.endSeconds
        lastArbitratedEndSeconds[.secondary] = secondary.endSeconds
        return arbiter.observe(
            primary: primary.arbiterObservation,
            secondary: secondary.arbiterObservation
        )
    }

    func finalizedFloorReadyToCommit() -> String? {
        guard let finalized = hypotheses[arbiter.floor]?.finalizedText,
              finalized.isEmpty == false else {
            return nil
        }
        if let unavailableSide {
            // Only secondary lane failure allows primary survivor commit; primary failure fails closed
            return (unavailableSide == .secondary && arbiter.floor == .primary) ? finalized : nil
        }
        guard let primary = hypotheses[.primary],
              let secondary = hypotheses[.secondary],
              primary.finalizedText != nil,
              secondary.finalizedText != nil,
              rangesAlign(primary, secondary) else {
            return nil
        }
        return finalized
    }

    func rangesAlign(_ lhs: DualLaneHypothesis, _ rhs: DualLaneHypothesis) -> Bool {
        guard lhs.hasSpeech, rhs.hasSpeech else {
            return false
        }
        let overlap = max(
            0,
            min(lhs.endSeconds, rhs.endSeconds)
                - max(lhs.startSeconds, rhs.startSeconds)
        )
        let shorterDuration = max(
            0.001,
            min(
                lhs.endSeconds - lhs.startSeconds,
                rhs.endSeconds - rhs.startSeconds
            )
        )
        return overlap / shorterDuration >= 0.5
    }
}
