import Foundation

/// The two display panes. `.original` is the configured input-language pane
/// (zh-Hant in dual lane); `.translated` is the target pane.
enum CaptionPane: Hashable, Sendable {
    case original
    case translated
}

struct CaptionPaneText: Equatable, Hashable, Sendable {
    var text: String
    var stableLength: Int
    var isDraft: Bool
}

struct CaptionPaneConfig: Equatable, Sendable {
    /// Configured input language (zh-Hant in a zh+en dual-lane session).
    var originalLanguageID: String
    var showsOriginal: Bool
    var showsTranslated: Bool
}

/// Which text goes in which pane for each row.
enum CaptionPaneProjection {
    static func paneTexts(
        for row: CaptionRow,
        config: CaptionPaneConfig
    ) -> [CaptionPane: CaptionPaneText] {
        let heardIsOriginal = LanguageIdentity.areEquivalent(
            row.languageID,
            config.originalLanguageID
        )
        let noTranslation = row.targetLanguageID.isEmpty
            || LanguageIdentity.areEquivalent(row.languageID, row.targetLanguageID)

        var original: CaptionPaneText
        var translated: CaptionPaneText
        if heardIsOriginal {
            original = CaptionPaneText(
                text: row.text,
                stableLength: row.stableLength,
                isDraft: false
            )
            translated = translatedText(for: row)
        } else {
            // Dual lane: the heard English row reads as the translated lane.
            translated = CaptionPaneText(
                text: row.text,
                stableLength: row.stableLength,
                isDraft: false
            )
            original = translatedText(for: row)
        }
        // No translation configured: the other pane mirrors the heard text.
        if noTranslation {
            let mirror = CaptionPaneText(
                text: row.text,
                stableLength: row.stableLength,
                isDraft: false
            )
            if heardIsOriginal {
                translated = mirror
            } else {
                original = mirror
            }
        }

        var result: [CaptionPane: CaptionPaneText] = [:]
        if config.showsOriginal {
            result[.original] = original
        }
        if config.showsTranslated {
            var pane = translated
            // Translated-only mode falls back to the row's own text while the
            // translation is empty.
            if config.showsOriginal == false, pane.text.isEmpty {
                pane = CaptionPaneText(
                    text: row.text,
                    stableLength: row.stableLength,
                    isDraft: false
                )
            }
            result[.translated] = pane
        }
        return result
    }

    private static func translatedText(for row: CaptionRow) -> CaptionPaneText {
        CaptionPaneText(
            text: row.translation,
            stableLength: row.translationIsDraft ? 0 : row.translation.count,
            isDraft: row.translationIsDraft
        )
    }

    /// If both panes would show the same words, keep only the leading pane.
    static func suppressingDuplicatePanes(
        _ texts: [CaptionPane: CaptionPaneText],
        leadingPane: CaptionPane
    ) -> [CaptionPane: CaptionPaneText] {
        guard let original = texts[.original],
              let translated = texts[.translated],
              lexicallyEqual(original.text, translated.text),
              let leading = texts[leadingPane] else {
            return texts
        }
        return [leadingPane: leading]
    }

    /// Letters-and-digits, case/diacritic-folded comparison — the same notion
    /// of equality the screen oracle uses.
    private static func lexicallyEqual(_ lhs: String, _ rhs: String) -> Bool {
        func key(_ text: String) -> [Unicode.Scalar] {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .unicodeScalars
                .filter {
                    CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
                }
        }
        return key(lhs) == key(rhs)
    }
}
