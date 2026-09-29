import CoreGraphics
import CoreText
import Foundation

/// CoreText line breaking: the single source of truth for where caption text
/// wraps. The viewport projects these ranges; views draw them verbatim.
enum CaptionLineBreaker {
    /// Breaks `text` into lines of at most `width`. Lines keep their trailing
    /// whitespace, so `lines.map { text[$0] }.joined() == text`.
    static func lines(_ text: String, font: CTFont, width: CGFloat) -> [Range<String.Index>] {
        guard text.isEmpty == false else { return [] }
        guard width > 0 else { return [text.startIndex..<text.endIndex] }

        let attributed = NSAttributedString(
            string: text,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)

        var ranges: [Range<String.Index>] = []
        var start = 0   // UTF-16 offset
        let utf16Count = text.utf16.count
        while start < utf16Count {
            let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
            guard count > 0 else { break }
            let end = min(start + count, utf16Count)
            if let lower = characterIndex(ofUTF16: start, in: text),
               let upper = characterIndex(ofUTF16: end, in: text),
               lower < upper {
                ranges.append(lower..<upper)
            }
            start = end
        }
        return ranges
    }

    /// Line pitch matching the current overlay's NSFont formula.
    static func lineHeight(_ font: CTFont) -> CGFloat {
        ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
    }

    /// CTTypesetter returns UTF-16 code-unit offsets; snap to the Character
    /// boundary at or before it (an offset can land inside a cluster).
    private static func characterIndex(ofUTF16 offset: Int, in text: String) -> String.Index? {
        var position = text.utf16.index(
            text.utf16.startIndex,
            offsetBy: min(offset, text.utf16.count)
        )
        while true {
            if let index = String.Index(position, within: text) {
                return index
            }
            guard position > text.utf16.startIndex else { return nil }
            position = text.utf16.index(before: position)
        }
    }
}
