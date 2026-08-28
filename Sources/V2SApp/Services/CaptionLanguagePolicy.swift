import Foundation
import NaturalLanguage

/// Stable language identity for speech-correction scoping and zh↔en caption reverse.
enum LanguageIdentity: Sendable {
    static func canonicalLanguageID(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return trimmed }
        let normalized = trimmed.replacingOccurrences(of: "_", with: "-")
        let parts = normalized.split(separator: "-").map(String.init)
        guard let language = parts.first?.lowercased() else {
            return trimmed
        }

        if language == "zh" || language == "zho" {
            let rest = parts.dropFirst().map { $0.lowercased() }
            if rest.contains(where: { $0 == "hant" || $0 == "tw" || $0 == "hk" || $0 == "mo" }) {
                return "zh-Hant"
            }
            if rest.contains(where: { $0 == "hans" || $0 == "cn" || $0 == "sg" }) {
                return "zh-Hans"
            }
            return "zh-Hant"
        }
        if language == "en" {
            return "en"
        }
        return language
    }

    static func areEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        canonicalLanguageID(lhs) == canonicalLanguageID(rhs)
    }

    static func isTraditionalChinese(_ languageID: String) -> Bool {
        canonicalLanguageID(languageID) == "zh-Hant"
    }

    static func isEnglish(_ languageID: String) -> Bool {
        canonicalLanguageID(languageID) == "en"
    }

    static func isLatinScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (value >= 0x0041 && value <= 0x005A)
            || (value >= 0x0061 && value <= 0x007A)
            || (value >= 0x00C0 && value <= 0x024F)
            || (value >= 0x1E00 && value <= 0x1EFF)
    }

    static func isHanScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (value >= 0x4E00 && value <= 0x9FFF)
            || (value >= 0x3400 && value <= 0x4DBF)
            || (value >= 0x20000 && value <= 0x2A6DF)
            || (value >= 0x2A700 && value <= 0x2B73F)
            || (value >= 0x2B740 && value <= 0x2B81F)
            || (value >= 0x2B820 && value <= 0x2CEAF)
            || (value >= 0xF900 && value <= 0xFAFF)
            || (value >= 0x2F800 && value <= 0x2FA1F)
    }

    static func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return isHanScalar(scalar)
            || (value >= 0x3040 && value <= 0x309F)
            || (value >= 0x30A0 && value <= 0x30FF)
            || (value >= 0xAC00 && value <= 0xD7AF)
    }
}

enum CaptionLaneResolution: Equatable, Sendable {
    case normalMandarinOrMixed
    case pureEnglish
}

/// Dual-lane caption reverse is in scope only for configured zh-Hant/zh-TW → en.
enum CaptionLanguagePolicy: Sendable {
    enum HeardScript: Equatable, Sendable {
        case empty
        case entirelyLatin
        case containsHan
        case other
    }

    typealias CaptionLanePolicy = @Sendable (
        _ primaryText: String,
        _ secondaryText: String,
        _ primaryConfidence: Double?,
        _ secondaryConfidence: Double?,
        _ arbiterFloor: ConversationSide
    ) -> (selectedSide: ConversationSide, resolution: CaptionLaneResolution)

    /// Always-warm dual lanes for this pair, so entering fullscreen does not restart capture.
    static func shouldEnableDualLane(sourceLanguageID: String, targetLanguageID: String) -> Bool {
        LanguageIdentity.isTraditionalChinese(sourceLanguageID)
            && LanguageIdentity.isEnglish(targetLanguageID)
    }

    /// Classify lexical letters only. Punctuation, whitespace, and digits are ignored.
    /// Non-ASCII Latin characters (café, naïve, Søren) are correctly classified as Latin.
    static func classifyHeardScript(_ text: String) -> HeardScript {
        var sawLatin = false
        var sawHan = false
        var sawOtherLetter = false

        for scalar in text.unicodeScalars {
            if CharacterSet.decimalDigits.contains(scalar)
                || CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.symbols.contains(scalar) {
                continue
            }
            if LanguageIdentity.isHanScalar(scalar) {
                sawHan = true
                continue
            }
            if CharacterSet.letters.contains(scalar) {
                if LanguageIdentity.isLatinScalar(scalar) {
                    sawLatin = true
                } else {
                    sawOtherLetter = true
                }
            }
        }

        if sawHan {
            return .containsHan
        }
        if sawLatin && sawOtherLetter == false {
            return .entirelyLatin
        }
        if sawLatin == false && sawOtherLetter == false {
            return .empty
        }
        return .other
    }

    /// Canonical lexical-normalization helper removing punctuation/digits and folding case with en_US_POSIX.
    static func canonicalLexicalText(_ text: String) -> String {
        let foldedText = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        var result = ""
        result.reserveCapacity(foldedText.utf8.count)
        var lastWasSpace = false

        for scalar in foldedText.unicodeScalars {
            if CharacterSet.decimalDigits.contains(scalar)
                || CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.symbols.contains(scalar) {
                continue
            }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !lastWasSpace && !result.isEmpty {
                    result.append(" ")
                    lastWasSpace = true
                }
                continue
            }
            if CharacterSet.letters.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasSpace = false
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Two-row Levenshtein distance on Unicode scalar arrays using O(min(N, M)) memory with two row buffers.
    static func levenshteinDistance(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Int {
        if a == b { return 0 }
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        let (shorter, longer) = a.count <= b.count ? (a, b) : (b, a)
        var previousRow = Array(0...shorter.count)
        var currentRow = Array(repeating: 0, count: shorter.count + 1)

        for (i, longerElem) in longer.enumerated() {
            currentRow[0] = i + 1
            for (j, shorterElem) in shorter.enumerated() {
                let cost = (longerElem == shorterElem) ? 0 : 1
                currentRow[j + 1] = min(
                    currentRow[j] + 1,
                    previousRow[j + 1] + 1,
                    previousRow[j] + cost
                )
            }
            swap(&previousRow, &currentRow)
        }
        return previousRow[shorter.count]
    }

    static func normalizedEditSimilarity(_ s1: String, _ s2: String) -> Double {
        let a = Array(s1.unicodeScalars)
        let b = Array(s2.unicodeScalars)
        let maxLen = max(a.count, b.count)
        guard maxLen > 0 else { return 1.0 }
        let distance = levenshteinDistance(a, b)
        return max(0.0, 1.0 - (Double(distance) / Double(maxLen)))
    }

    static func englishLanguageProbability(in text: String) -> Double {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return 0.0
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        return hypotheses[.english] ?? 0.0
    }

    /// Conservative affirmative pure-English lane selection derived from 20 empirical probe metrics.
    static func defaultResolveCaptionLane(
        primaryText: String,
        secondaryText: String,
        primaryConfidence: Double?,
        secondaryConfidence: Double?,
        arbiterFloor: ConversationSide
    ) -> (selectedSide: ConversationSide, resolution: CaptionLaneResolution) {
        let primScript = classifyHeardScript(primaryText)
        let secScript = classifyHeardScript(secondaryText)

        if primScript == .containsHan {
            return (selectedSide: .primary, resolution: .normalMandarinOrMixed)
        }

        guard primScript == .entirelyLatin, secScript == .entirelyLatin else {
            return (selectedSide: arbiterFloor, resolution: .normalMandarinOrMixed)
        }

        let normPrimary = canonicalLexicalText(primaryText)
        let normSecondary = canonicalLexicalText(secondaryText)

        guard normPrimary.isEmpty == false, normSecondary.isEmpty == false else {
            return (selectedSide: arbiterFloor, resolution: .normalMandarinOrMixed)
        }

        if normPrimary == normSecondary {
            return (selectedSide: .secondary, resolution: .pureEnglish)
        }

        let primaryTokens = normPrimary.split(separator: " ")
        let secondaryTokens = normSecondary.split(separator: " ")

        if primaryTokens.count <= 1 || secondaryTokens.count <= 1 {
            return (selectedSide: .primary, resolution: .normalMandarinOrMixed)
        }

        let similarity = normalizedEditSimilarity(normPrimary, normSecondary)
        let enProb = englishLanguageProbability(in: secondaryText)

        if similarity >= 0.64 && enProb >= 0.80 {
            return (selectedSide: .secondary, resolution: .pureEnglish)
        }

        return (selectedSide: .primary, resolution: .normalMandarinOrMixed)
    }

    /// Reverse only when affirmative pureEnglish resolution is established in dual lane.
    static func shouldReverse(
        configuredSourceLanguageID: String,
        configuredTargetLanguageID: String,
        heardLanguageID: String,
        heardText: String,
        evidence: DualLaneEvidence? = nil
    ) -> Bool {
        guard shouldEnableDualLane(
            sourceLanguageID: configuredSourceLanguageID,
            targetLanguageID: configuredTargetLanguageID
        ) else {
            return false
        }
        guard LanguageIdentity.isEnglish(heardLanguageID),
              let evidence,
              evidence.resolution == .pureEnglish,
              evidence.selectedSide == .secondary else {
            return false
        }
        return classifyHeardScript(heardText) == .entirelyLatin
    }

    /// Language panes, not source-role panes. For eligible zh→en, `sourceText` is the
    /// zh pane and `translatedText` is the en pane.
    static func overlayPanes(
        heardText: String,
        translatedText: String,
        heardLanguageID: String,
        configuredSourceLanguageID: String,
        configuredTargetLanguageID: String,
        evidence: DualLaneEvidence? = nil
    ) -> (sourceText: String, translatedText: String) {
        let reverse = shouldReverse(
            configuredSourceLanguageID: configuredSourceLanguageID,
            configuredTargetLanguageID: configuredTargetLanguageID,
            heardLanguageID: heardLanguageID,
            heardText: heardText,
            evidence: evidence
        )
        if reverse {
            return (sourceText: translatedText, translatedText: heardText)
        }
        return (sourceText: heardText, translatedText: translatedText)
    }

    static func translationTarget(
        heardLanguageID: String,
        configuredSourceLanguageID: String,
        configuredTargetLanguageID: String,
        heardText: String = "",
        evidence: DualLaneEvidence? = nil
    ) -> String {
        guard shouldEnableDualLane(
            sourceLanguageID: configuredSourceLanguageID,
            targetLanguageID: configuredTargetLanguageID
        ) else {
            if LanguageIdentity.areEquivalent(heardLanguageID, configuredTargetLanguageID) {
                return configuredSourceLanguageID
            }
            return configuredTargetLanguageID
        }

        if shouldReverse(
            configuredSourceLanguageID: configuredSourceLanguageID,
            configuredTargetLanguageID: configuredTargetLanguageID,
            heardLanguageID: heardLanguageID,
            heardText: heardText,
            evidence: evidence
        ) {
            return configuredSourceLanguageID
        }
        return configuredTargetLanguageID
    }
}
