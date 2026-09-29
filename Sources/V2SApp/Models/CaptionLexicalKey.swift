import Foundation

/// The words a caption says, without its spacing, punctuation or case.
///
/// Letters and digits only, case- and diacritic-folded, so "Hello, world." and
/// "hello world", or "大家早安 ，謝謝" and "大家早安謝謝", have equal keys. Every key
/// scalar remembers the character of `text` it came from, so a match between
/// keys maps back to a cut position in the original string.
struct CaptionLexicalKey: Equatable, Sendable {
    let text: String
    let scalars: [Unicode.Scalar]
    /// `characterIndices[i]` is the index in `text` of the character that
    /// produced `scalars[i]`.
    private let characterIndices: [String.Index]

    init(_ text: String) {
        self.text = text
        var scalars: [Unicode.Scalar] = []
        var characterIndices: [String.Index] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            let folded = text[index..<next].folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Self.foldingLocale
            )
            for scalar in folded.unicodeScalars where Self.isLexical(scalar) {
                scalars.append(scalar)
                characterIndices.append(index)
            }
            index = next
        }
        self.scalars = scalars
        self.characterIndices = characterIndices
    }

    static func == (lhs: CaptionLexicalKey, rhs: CaptionLexicalKey) -> Bool {
        lhs.scalars == rhs.scalars
    }

    var isEmpty: Bool { scalars.isEmpty }

    /// Number of key scalars; the unit of every length this type accepts.
    var count: Int { scalars.count }

    func hasPrefix(_ other: CaptionLexicalKey) -> Bool {
        scalars.starts(with: other.scalars)
    }

    /// `text` after the characters that produced the first `length` key scalars,
    /// starting at the next letter or digit. Empty when nothing lexical follows.
    func remainder(afterKeyPrefix length: Int) -> Substring {
        guard length > 0 else { return text[...] }
        guard length < characterIndices.count else { return text[text.endIndex...] }
        let lastConsumed = characterIndices[length - 1]
        var cut = characterIndices[length]
        // A character that folds to several scalars cannot be split: if the
        // prefix ends inside it, the remainder starts after that character.
        if cut == lastConsumed {
            let after = text.index(after: lastConsumed)
            guard let next = characterIndices[length...].first(where: { $0 >= after }) else {
                return text[text.endIndex...]
            }
            cut = next
        }
        return text[cut...]
    }

    private static let foldingLocale = Locale(identifier: "en_US_POSIX")

    private static func isLexical(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar)
    }
}
