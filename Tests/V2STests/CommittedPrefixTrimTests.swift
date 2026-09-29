import CoreMedia
import Foundation
import XCTest
@testable import v2s

/// Regression: after a commit, SpeechTranscriber keeps emitting volatile
/// hypotheses for the same analyzer window. Those hypotheses restart at the
/// window start and re-cover already-committed text, often with different
/// spacing or punctuation ("大家早安謝謝各位…" vs committed "大家早安 ，謝謝各位…。").
/// The pending-text trim must drop the re-covered span on a normalized
/// comparison so the live draft never duplicates a committed row — while an
/// independent utterance from a new window is never trimmed.
final class CommittedPrefixTrimTests: XCTestCase {
    @MainActor
    func testVolatileHypothesisRecoveringFinalCommitIsTrimmed() async {
        let session = LiveTranscriptionSession()
        var drafts: [DraftSegment?] = []
        var committed: [RecognizedSentence] = []
        session.installPartialHandlerForTesting { drafts.append($0) }
        session.installTranscriptHandlerForTesting { committed.append($0) }

        let window = CMTimeRange(
            start: CMTime(seconds: 0.0, preferredTimescale: 1000),
            duration: CMTime(seconds: 3.0, preferredTimescale: 1000)
        )

        // The window finalizes mid-sentence: everything heard so far commits.
        session.processModernRecognitionTextForTesting(
            "大家早安 ，謝謝各位今天來參加我們的第一場會議。我們",
            isFinal: true,
            audioRange: window,
            sourceLanguageID: "zh-Hant"
        )
        await session.awaitPendingEmissionsForTesting()
        XCTAssertFalse(committed.isEmpty)

        // A volatile hypothesis for the same window re-covers the committed
        // text without its punctuation and continues. Only the new tail may
        // reach the live draft.
        session.processModernRecognitionTextForTesting(
            "大家早安謝謝各位今天來參加我們的第一場會議我們要談談",
            isFinal: false,
            audioRange: window,
            sourceLanguageID: "zh-Hant"
        )
        await session.awaitPendingEmissionsForTesting()
        XCTAssertEqual(drafts.last??.sourceText, "要談談")

        // Growth keeps trimming the same committed span.
        session.processModernRecognitionTextForTesting(
            "大家早安謝謝各位今天來參加我們的第一場會議我們要談談字幕",
            isFinal: false,
            audioRange: window,
            sourceLanguageID: "zh-Hant"
        )
        await session.awaitPendingEmissionsForTesting()
        XCTAssertEqual(drafts.last??.sourceText, "要談談字幕")

        // A hypothesis covering only committed audio emits no new draft —
        // but it must NOT clear the live draft, whose words were never
        // committed. Clearing it vanishes the row for a frame.
        session.processModernRecognitionTextForTesting(
            "大家早安",
            isFinal: false,
            audioRange: window,
            sourceLanguageID: "zh-Hant"
        )
        await session.awaitPendingEmissionsForTesting()
        XCTAssertEqual(drafts.last??.sourceText, "要談談字幕")

        // A verbatim repeat of the committed text likewise leaves the
        // uncovered draft alone.
        session.processModernRecognitionTextForTesting(
            "大家早安 ，謝謝各位今天來參加我們的第一場會議。我們",
            isFinal: false,
            audioRange: window,
            sourceLanguageID: "zh-Hant"
        )
        await session.awaitPendingEmissionsForTesting()
        XCTAssertEqual(drafts.last??.sourceText, "要談談字幕")
    }

    @MainActor
    func testIndependentUtteranceSharingFirstWordIsNeverTrimmed() async {
        let session = LiveTranscriptionSession()
        var drafts: [DraftSegment?] = []
        session.installPartialHandlerForTesting { drafts.append($0) }
        session.installTranscriptHandlerForTesting { _ in }

        let firstWindow = CMTimeRange(
            start: CMTime(seconds: 0.0, preferredTimescale: 1000),
            duration: CMTime(seconds: 3.0, preferredTimescale: 1000)
        )
        session.processModernRecognitionTextForTesting(
            "大家早安 ，謝謝各位。",
            isFinal: true,
            audioRange: firstWindow,
            sourceLanguageID: "zh-Hant"
        )
        await session.awaitPendingEmissionsForTesting()

        // A new analyzer window carrying a different utterance that merely
        // shares the opening word must surface in full.
        let nextWindow = CMTimeRange(
            start: CMTime(seconds: 10.0, preferredTimescale: 1000),
            duration: CMTime(seconds: 3.0, preferredTimescale: 1000)
        )
        session.processModernRecognitionTextForTesting(
            "大家早安全新的一句",
            isFinal: false,
            audioRange: nextWindow,
            sourceLanguageID: "zh-Hant"
        )
        await session.awaitPendingEmissionsForTesting()
        XCTAssertEqual(drafts.last??.sourceText, "大家早安全新的一句")
    }

    @MainActor
    func testVolatileHypothesisRecoveringProvisionalCommitIsTrimmed() async {
        let session = LiveTranscriptionSession()
        var drafts: [DraftSegment?] = []
        var committed: [RecognizedSentence] = []
        session.installPartialHandlerForTesting { drafts.append($0) }
        session.installTranscriptHandlerForTesting { committed.append($0) }

        let window = CMTimeRange(
            start: CMTime(seconds: 0.0, preferredTimescale: 1000),
            duration: CMTime(seconds: 3.0, preferredTimescale: 1000)
        )

        session.processModernRecognitionTextForTesting(
            "Good morning, everyone.",
            isFinal: false,
            audioRange: window,
            sourceLanguageID: "en"
        )
        await session.awaitPendingEmissionsForTesting()
        session.backdateLastDraftTextChangeForTesting(secondsAgo: 1)
        session.forceVADCommitOnSilenceForTesting()
        await session.awaitPendingEmissionsForTesting()
        XCTAssertEqual(committed.map(\.text), ["Good morning, everyone."])

        // Same window, punctuation and spacing revised, utterance continues.
        session.processModernRecognitionTextForTesting(
            "Good morning everyone thank you",
            isFinal: false,
            audioRange: window,
            sourceLanguageID: "en"
        )
        await session.awaitPendingEmissionsForTesting()
        XCTAssertEqual(drafts.last??.sourceText, "thank you")
    }

    /// Window-final shape from the mandarin e2e (~19.6 s): the analyzer's
    /// final re-covers the whole window, including a sentence committed long
    /// before the 8 s commit-history retention. The final must contribute
    /// only the not-yet-committed tail — re-emitting the covered sentence
    /// duplicates the live row with a fresh, hence untranslated, promotion
    /// while the long draft vanishes.
    @MainActor
    func testWindowFinalNeverRecommitsSentencesCommittedLongAgo() async {
        let session = LiveTranscriptionSession()
        var committed: [RecognizedSentence] = []
        session.installTranscriptHandlerForTesting { committed.append($0) }
        session.installPartialHandlerForTesting { _ in }

        let firstWindow = CMTimeRange(
            start: CMTime(seconds: 0.0, preferredTimescale: 1000),
            duration: CMTime(seconds: 3.0, preferredTimescale: 1000)
        )
        session.processModernRecognitionTextForTesting(
            "大家早安 ，謝謝各位今天來參加我們的第一場會議。",
            isFinal: true,
            audioRange: firstWindow,
            sourceLanguageID: "zh-Hant"
        )
        await session.awaitPendingEmissionsForTesting()
        XCTAssertEqual(committed.count, 1)

        // The window keeps growing past the committed sentence.
        let fullWindow = CMTimeRange(
            start: CMTime(seconds: 0.0, preferredTimescale: 1000),
            duration: CMTime(seconds: 12.0, preferredTimescale: 1000)
        )
        session.processModernRecognitionTextForTesting(
            "大家早安謝謝各位今天來參加我們的第一場會議我們要談談字幕",
            isFinal: false,
            audioRange: fullWindow,
            sourceLanguageID: "zh-Hant"
        )
        await session.awaitPendingEmissionsForTesting()

        // More than the commit-history retention passes before the
        // window-final lands, so history alone no longer suppresses the
        // replay of the first sentence.
        await session.expireCommittedSentenceHistoryForTesting()

        session.processModernRecognitionTextForTesting(
            "大家早安 ，謝謝各位今天來參加我們的第一場會議。我們要談談字幕在講者還在說話的時候應該如何出現在螢幕上。",
            isFinal: true,
            audioRange: fullWindow,
            sourceLanguageID: "zh-Hant"
        )
        await session.awaitPendingEmissionsForTesting()

        let firstKey = CaptionLexicalKey("大家早安 ，謝謝各位今天來參加我們的第一場會議。")
        XCTAssertEqual(
            committed.filter { CaptionLexicalKey($0.text) == firstKey }.count,
            1,
            "window-final re-emitted the covered sentence: \(committed.map(\.text))"
        )
        XCTAssertTrue(
            committed.contains { $0.text.contains("要談談") },
            "window-final lost the new tail: \(committed.map(\.text))"
        )
    }

    /// A window-final that restates only an older sentence must not consume the
    /// live draft, even when the draft's words occur inside that sentence
    /// ("我們" in "…參加我們的第一場會議"): the draft keeps its row and identity,
    /// and the commit carries no draft promotion ID. Taking the ID made the
    /// presentation absorb the draft (mandarin e2e ~8 s); clearing the draft
    /// lost its words (~19.9 s).
    @MainActor
    func testCommitNotCoveringDraftLeavesDraftAlone() async {
        let session = LiveTranscriptionSession()
        var drafts: [DraftSegment?] = []
        var committed: [RecognizedSentence] = []
        session.installPartialHandlerForTesting { drafts.append($0) }
        session.installTranscriptHandlerForTesting { committed.append($0) }

        let window = CMTimeRange(
            start: CMTime(seconds: 0.0, preferredTimescale: 1000),
            duration: CMTime(seconds: 6.0, preferredTimescale: 1000)
        )

        // A live draft for the new utterance.
        session.processModernRecognitionTextForTesting(
            "我們",
            isFinal: false,
            audioRange: window,
            sourceLanguageID: "zh-Hant"
        )
        await session.awaitPendingEmissionsForTesting()
        let draftID = drafts.last??.segmentId
        XCTAssertNotNil(draftID)

        // The window finalizes with only the older sentence, which happens to
        // contain the draft's word.
        session.processModernRecognitionTextForTesting(
            "大家早安 ，謝謝各位今天來參加我們的第一場會議。",
            isFinal: true,
            audioRange: window,
            sourceLanguageID: "zh-Hant"
        )
        await session.awaitPendingEmissionsForTesting()

        XCTAssertFalse(committed.isEmpty, "the older sentence was not committed")
        XCTAssertFalse(
            committed.contains { $0.promotionSegmentID == draftID },
            "a commit that does not cover the draft must not take its ID: \(committed)"
        )
        XCTAssertEqual(
            drafts.last??.sourceText, "我們",
            "non-consuming commit cleared the live draft"
        )
        XCTAssertEqual(
            drafts.last??.segmentId, draftID,
            "non-consuming commit churned the draft's identity"
        )
    }

    /// The consuming case: a window-final that covers the live draft's words
    /// takes the draft's ID as its promotion and clears the row — the
    /// provisional→final revision path.
    @MainActor
    func testCommitCoveringDraftConsumesIt() async {
        let session = LiveTranscriptionSession()
        var drafts: [DraftSegment?] = []
        var committed: [RecognizedSentence] = []
        session.installPartialHandlerForTesting { drafts.append($0) }
        session.installTranscriptHandlerForTesting { committed.append($0) }

        let window = CMTimeRange(
            start: CMTime(seconds: 0.0, preferredTimescale: 1000),
            duration: CMTime(seconds: 6.0, preferredTimescale: 1000)
        )

        session.processModernRecognitionTextForTesting(
            "我們要談談字幕",
            isFinal: false,
            audioRange: window,
            sourceLanguageID: "zh-Hant"
        )
        await session.awaitPendingEmissionsForTesting()
        let draftID = try? XCTUnwrap(drafts.last??.segmentId)
        XCTAssertNotNil(draftID)

        session.processModernRecognitionTextForTesting(
            "我們要談談字幕在講者還在說話的時候應該如何出現在螢幕上。",
            isFinal: true,
            audioRange: window,
            sourceLanguageID: "zh-Hant"
        )
        await session.awaitPendingEmissionsForTesting()

        XCTAssertTrue(
            committed.contains { $0.promotionSegmentID == draftID },
            "consuming commit did not take the draft's promotion ID: \(committed)"
        )
        XCTAssertNil(drafts.last ?? nil, "consuming commit left the draft visible")
    }
}
