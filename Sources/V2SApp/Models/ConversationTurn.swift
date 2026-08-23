import Foundation

/// Which of the two conversation participants a piece of speech belongs to.
///
/// A conversation session pins exactly two languages: `primary` is the device
/// owner's language, `secondary` is the other person's. The side is a position in
/// the layout, not an identity — the same physical person can hold either side.
enum ConversationSide: String, Codable, CaseIterable, Sendable {
    case primary
    case secondary

    var opposite: ConversationSide {
        self == .primary ? .secondary : .primary
    }
}

/// One completed utterance, transcribed in the speaker's language and translated
/// into the listener's language.
struct ConversationTurn: Identifiable, Equatable, Sendable {
    let id: UUID
    /// The side that spoke this turn.
    let side: ConversationSide
    /// Transcript in the speaker's own language.
    var sourceText: String
    /// Translation into the listener's language. Empty until translation lands.
    var translatedText: String
    let sourceLanguageID: String
    let targetLanguageID: String

    init(
        id: UUID = UUID(),
        side: ConversationSide,
        sourceText: String,
        translatedText: String = "",
        sourceLanguageID: String,
        targetLanguageID: String
    ) {
        self.id = id
        self.side = side
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.sourceLanguageID = sourceLanguageID
        self.targetLanguageID = targetLanguageID
    }
}

/// The live, uncommitted hypothesis for one side. Rendered word by word while the
/// person is still speaking, then replaced by a `ConversationTurn` on commit.
struct ConversationDraft: Equatable, Sendable {
    /// Identifies the utterance this draft belongs to, so a late-arriving
    /// translation can be discarded once the utterance has moved on.
    let id: UUID
    var sourceText: String
    var translatedText: String

    init(id: UUID = UUID(), sourceText: String = "", translatedText: String = "") {
        self.id = id
        self.sourceText = sourceText
        self.translatedText = translatedText
    }

    var isEmpty: Bool {
        sourceText.isEmpty && translatedText.isEmpty
    }
}
