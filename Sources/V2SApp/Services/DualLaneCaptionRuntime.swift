import Foundation
import Speech

/// Owns two `ConversationLane`s plus `DualLanePairing` on one shared analyzer.
/// LiveTranscriptionSession keeps capture and VAD; this only arbitrates language.
@available(iOS 26.0, macOS 26.0, *)
final class DualLaneCaptionRuntime: @unchecked Sendable {
    let primaryLanguageID: String
    let secondaryLanguageID: String

    private let queueKey = DispatchSpecificKey<Void>()
    private let queue: DispatchQueue
    private var pairing = DualLanePairing()
    private var lanes: [ConversationSide: ConversationLane] = [:]
    private var generation = 0
    private var utteranceGeneration: UInt64 = 0
    private var graceTimer: DispatchWorkItem?
    #if DEBUG
    private var graceTimerScheduleCount = 0
    #endif
    var onStep: ((DualLaneStep, String) -> Void)?
    var onFailure: ((Error) -> Void)?

    init(primaryLanguageID: String, secondaryLanguageID: String) {
        self.primaryLanguageID = primaryLanguageID
        self.secondaryLanguageID = secondaryLanguageID
        let q = DispatchQueue(label: "org.audreyt.v2s.caption.duallane.\(UUID().uuidString)", qos: .userInitiated)
        self.queue = q
        q.setSpecific(key: queueKey, value: ())
    }

    func languageID(for side: ConversationSide) -> String {
        side == .primary ? primaryLanguageID : secondaryLanguageID
    }

    private func performSync<T>(_ block: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return block()
        } else {
            return queue.sync(execute: block)
        }
    }

    func start(primary: SpeechTranscriber, secondary: SpeechTranscriber) {
        performSync {
            finishInternal()
            generation &+= 1
            utteranceGeneration &+= 1
            let generation = generation
            pairing = DualLanePairing()

            let primaryLane = ConversationLane(side: .primary, transcriber: primary)
            let secondaryLane = ConversationLane(side: .secondary, transcriber: secondary)
            lanes = [.primary: primaryLane, .secondary: secondaryLane]

            for lane in [primaryLane, secondaryLane] {
                let side = lane.side
                lane.start(
                    onUpdate: { [weak self] update in
                        self?.queue.async { [weak self] in
                            self?.handle(update, generation: generation)
                        }
                    },
                    onFailure: { [weak self] error in
                        self?.queue.async { [weak self] in
                            self?.handleFailure(error, side: side, generation: generation)
                        }
                    }
                )
            }
        }
    }

    func finish() {
        performSync {
            finishInternal()
        }
    }

    private func finishInternal() {
        cancelGraceTimer()
        generation &+= 1
        utteranceGeneration &+= 1
        let oldLanes = lanes
        lanes.removeAll()
        pairing = DualLanePairing()
        for lane in oldLanes.values {
            lane.finish()
        }
    }

    private func cancelGraceTimer() {
        graceTimer?.cancel()
        graceTimer = nil
    }

    private func scheduleGraceTimerIfNeeded(generation: Int, utteranceGen: UInt64) {
        guard graceTimer == nil else { return }
        #if DEBUG
        graceTimerScheduleCount &+= 1
        #endif
        let item = DispatchWorkItem { [weak self] in
            self?.fireGraceTimer(generation: generation, utteranceGen: utteranceGen)
        }
        graceTimer = item
        queue.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    private func fireGraceTimer(generation: Int, utteranceGen: UInt64) {
        performSync {
            guard generation == self.generation, utteranceGen == self.utteranceGeneration else { return }
            cancelGraceTimer()
            guard let flushStep = pairing.commitSoleFinalist() else { return }
            self.utteranceGeneration &+= 1
            let floorLanguageID = languageID(for: flushStep.floor)
            let callback = self.onStep
            callback?(flushStep, floorLanguageID)
        }
    }

    private func handle(_ rawUpdate: ConversationLane.Update, generation: Int) {
        let callback: (() -> Void)? = performSync {
            guard generation == self.generation else { return nil }
            guard let update = rawUpdate.trimmingAudio(
                beforeOrAt: pairing.committedAudioEndSeconds,
                tolerance: DualLanePairing.audioTimelineTolerance
            ), update.text.isEmpty == false else {
                return nil
            }

            let observation = DualLaneObservation(
                side: update.side,
                text: update.text,
                confidence: update.confidence,
                isFinal: update.isFinal,
                startSeconds: update.startSeconds,
                endSeconds: update.endSeconds
            )
            let step = pairing.ingest(observation)

            if step.commitText != nil {
                cancelGraceTimer()
                self.utteranceGeneration &+= 1
            } else if step.isPendingFinalGrace {
                scheduleGraceTimerIfNeeded(generation: generation, utteranceGen: self.utteranceGeneration)
            }

            let floorLanguageID = languageID(for: step.floor)
            let stepCallback = self.onStep
            return {
                stepCallback?(step, floorLanguageID)
            }
        }
        callback?()
    }

    private func handleFailure(_ error: Error, side: ConversationSide, generation: Int) {
        let callbacks: (stepCallback: (() -> Void)?, failureCallback: (() -> Void)?) = performSync {
            guard generation == self.generation else { return (nil, nil) }
            cancelGraceTimer()
            self.utteranceGeneration &+= 1
            let flushStep = pairing.markLaneUnavailable(side)
            let stepCallback = self.onStep
            let failureCallback = self.onFailure

            let stepAction: (() -> Void)?
            if let flushStep {
                let floorLanguageID = languageID(for: flushStep.floor)
                stepAction = {
                    stepCallback?(flushStep, floorLanguageID)
                }
            } else {
                stepAction = nil
            }

            let failureAction: (() -> Void)? = {
                failureCallback?(error)
            }
            return (stepAction, failureAction)
        }
        callbacks.stepCallback?()
        callbacks.failureCallback?()
    }

    #if DEBUG
    func currentGenerationForTesting() -> Int {
        performSync { generation }
    }

    func isGraceTimerScheduledForTesting() -> Bool {
        performSync { graceTimer != nil }
    }

    func graceTimerScheduleCountForTesting() -> Int {
        performSync { graceTimerScheduleCount }
    }

    func handleUpdateForTesting(_ update: ConversationLane.Update, generation: Int) {
        handle(update, generation: generation)
    }

    func handleFailureForTesting(_ error: Error, side: ConversationSide = .secondary, generation: Int) {
        handleFailure(error, side: side, generation: generation)
    }

    func fireGraceTimerForTesting() {
        performSync {
            fireGraceTimer(generation: generation, utteranceGen: utteranceGeneration)
        }
    }

    func runOnQueueForTesting<T>(_ block: () -> T) -> T {
        performSync(block)
    }
    #endif
}
