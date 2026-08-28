import Foundation

/// Applies a user-defined glossary table to a translated string.
/// Source terms are matched case-insensitively and replaced with the target term.
struct GlossaryService: Sendable {
    /// Builds a collision-safe inverse glossary (target -> source) for reverse translations.
    ///
    /// - Normalizes target values using a stable `en_US_POSIX` locale to detect collisions.
    /// - Groups all entries by normalized target first, then omits ambiguous multi-source groups.
    /// - Omits identity mappings (source == target).
    static func buildInverseGlossary(
        _ glossary: [String: String],
        locale: Locale = Locale(identifier: "en_US_POSIX")
    ) -> [String: String] {
        guard glossary.isEmpty == false else { return [:] }

        // Collect unique (normSource, normTarget) pairs, keeping the first original
        // target string encountered for each normalized pair. Distinct dictionary keys
        // that normalize to the same source→target pair (e.g. "AI" and "ai" → same
        // target) are a single inverse entry, not a target-ambiguity collision.
        var seenPairs = Set<String>()
        var deduped: [(source: String, trimmedTarget: String, normSource: String, normTarget: String)] = []
        for (source, target) in glossary {
            let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedSource.isEmpty == false, trimmedTarget.isEmpty == false else { continue }
            let normSource = trimmedSource.folding(options: [.caseInsensitive], locale: locale)
            let normTarget = trimmedTarget.folding(options: [.caseInsensitive], locale: locale)
            let pairKey = normSource + "\u{0}" + normTarget
            guard seenPairs.insert(pairKey).inserted else { continue }
            deduped.append((source: trimmedSource, trimmedTarget: trimmedTarget, normSource: normSource, normTarget: normTarget))
        }

        // Group by normalized target; keep only entries whose target maps to a single
        // normalized source (no ambiguity) and is not an identity mapping.
        var grouped: [String: [(source: String, originalTarget: String, normSource: String)]] = [:]
        for entry in deduped {
            grouped[entry.normTarget, default: []].append(
                (source: entry.source, originalTarget: entry.trimmedTarget, normSource: entry.normSource)
            )
        }

        var inverse: [String: String] = [:]
        for (normTarget, entries) in grouped {
            guard entries.count == 1, let unique = entries.first else { continue }
            guard unique.normSource != normTarget else { continue }
            inverse[unique.originalTarget] = unique.source
        }
        return inverse
    }

    func apply(to text: String, glossary: [String: String]) -> String {
        guard !glossary.isEmpty else { return text }

        let entries = glossary
            .map { (source: $0.key.trimmingCharacters(in: .whitespacesAndNewlines), target: $0.value) }
            .filter { !$0.source.isEmpty }
            .sorted { lhs, rhs in
                let lhsCount = lhs.source.count
                let rhsCount = rhs.source.count
                if lhsCount == rhsCount {
                    return lhs.source < rhs.source
                }
                return lhsCount > rhsCount
            }

        guard !entries.isEmpty else { return text }

        let pattern = entries
            .map { Self.boundaryAwarePattern(for: $0.source) }
            .joined(separator: "|")

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }

        let locale = Locale(identifier: "en_US_POSIX")
        let replacements = entries.reduce(into: [String: String]()) { replacements, entry in
            let key = normalizedKey(entry.source, locale: locale)
            if replacements[key] == nil {
                replacements[key] = entry.target
            }
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }

        var result = ""
        var currentLocation = 0

        for match in matches {
            guard match.range.location >= currentLocation else {
                continue
            }

            if match.range.location > currentLocation {
                result += nsText.substring(with: NSRange(location: currentLocation, length: match.range.location - currentLocation))
            }

            let matchedText = nsText.substring(with: match.range)
            let normalizedMatch = normalizedKey(matchedText, locale: locale)
            result += replacements[normalizedMatch] ?? matchedText
            currentLocation = match.range.location + match.range.length
        }

        if currentLocation < nsText.length {
            result += nsText.substring(from: currentLocation)
        }

        return result
    }

    /// Applies the direction-effective glossary before translation, then applies the
    /// same map to the translated output as a fallback. The caller's source text is
    /// returned verbatim so display and transcript storage never see the prepared input.
    func translating(
        sourceText: String,
        glossary: [String: String],
        with translate: (String) async throws -> String
    ) async rethrows -> (sourceText: String, translatedText: String) {
        let preparedInput = apply(to: sourceText, glossary: glossary)
        let rawTranslation = try await translate(preparedInput)
        return (
            sourceText: sourceText,
            translatedText: apply(to: rawTranslation, glossary: glossary)
        )
    }

    private func normalizedKey(_ text: String, locale: Locale) -> String {
        text.folding(options: [.caseInsensitive], locale: locale)
    }

    /// Wraps a term in word-boundary lookarounds when its edges are letters or
    /// digits from a script with word boundaries, so entries like "AI" and
    /// "тест" cannot match inside larger words. CJK edges stay unwrapped, and
    /// the boundary class excludes CJK characters so Latin terms still match
    /// when directly adjacent to CJK characters (e.g. "使用AI模型").
    private static func boundaryAwarePattern(for source: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: source)
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.unicodeScalars.first,
              let last = trimmed.unicodeScalars.last else {
            return escaped
        }

        let leadingBoundary = isBoundaryRelevantScalar(first)
            ? "(?<!\(nonCJKWordCharacterClass))"
            : ""
        let trailingBoundary = isBoundaryRelevantScalar(last)
            ? "(?!\(nonCJKWordCharacterClass))"
            : ""

        return "\(leadingBoundary)\(escaped)\(trailingBoundary)"
    }

    private static let nonCJKWordCharacterClass =
        "[\\p{L}\\p{N}&&[^\\p{Han}\\p{Hiragana}\\p{Katakana}\\p{Hangul}]]"

    private static func isBoundaryRelevantScalar(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar) && !isCJKScalar(scalar)
    }

    private static func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
        LanguageIdentity.isCJKScalar(scalar)
    }
}
