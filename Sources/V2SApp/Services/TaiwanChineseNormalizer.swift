import Foundation

/// Converts Chinese ASR output into Traditional Chinese with Taiwan terminology.
///
/// ICU supplies the character-level Hans→Hant transform. OpenCC's small Apache-2.0
/// `TWPhrases` dictionary then fixes Taiwan lexical choices such as 軟件→軟體 and
/// 內存→記憶體. The phrase pass is longest-match-first so a specific multi-character
/// term wins over its prefix and never cascades through its own replacement.
struct TaiwanChineseNormalizer: Sendable {
    private struct Entry: Sendable {
        let source: String
        let target: String
        let sourceLength: Int
    }

    private static let entriesByFirstCharacter: [Character: [Entry]] = loadEntries()

    func normalize(_ text: String) -> String {
        let traditional = text.applyingTransform(
            StringTransform("Hans-Hant"),
            reverse: false
        ) ?? text
        guard traditional.isEmpty == false,
              Self.entriesByFirstCharacter.isEmpty == false else {
            return traditional
        }

        var output = ""
        output.reserveCapacity(traditional.utf8.count)
        var index = traditional.startIndex

        while index < traditional.endIndex {
            let first = traditional[index]
            var matched = false

            if let candidates = Self.entriesByFirstCharacter[first] {
                let suffix = traditional[index...]
                for entry in candidates where suffix.hasPrefix(entry.source) {
                    output.append(entry.target)
                    index = traditional.index(
                        index,
                        offsetBy: entry.sourceLength,
                        limitedBy: traditional.endIndex
                    ) ?? traditional.endIndex
                    matched = true
                    break
                }
            }

            if matched == false {
                output.append(first)
                index = traditional.index(after: index)
            }
        }

        return output
    }

    private static func loadEntries() -> [Character: [Entry]] {
        guard let url = resourceBundle.url(
            forResource: "TWPhrases",
            withExtension: "txt"
        ), let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return [:]
        }

        var result: [Character: [Entry]] = [:]
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.isEmpty == false, line.hasPrefix("#") == false else {
                continue
            }

            let columns = line.split(separator: "\t", maxSplits: 1)
            guard columns.count == 2 else { continue }
            let source = String(columns[0])
            // OpenCC separates alternative targets with spaces. The first is the
            // preferred Taiwan form used by s2twp.
            guard let preferred = columns[1].split(separator: " ").first else {
                continue
            }
            let target = String(preferred)
            guard let first = source.first, source.isEmpty == false else { continue }
            result[first, default: []].append(
                Entry(source: source, target: target, sourceLength: source.count)
            )
        }

        for key in result.keys {
            result[key]?.sort {
                if $0.sourceLength == $1.sourceLength {
                    return $0.source < $1.source
                }
                return $0.sourceLength > $1.sourceLength
            }
        }
        return result
    }

    private static var resourceBundle: Bundle {
#if SWIFT_PACKAGE
        Bundle.module
#else
        Bundle.main
#endif
    }
}
