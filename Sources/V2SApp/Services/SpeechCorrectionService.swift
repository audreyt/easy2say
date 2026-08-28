import Foundation

/// Language-scoped ASR typo corrections, separate from the translation glossary.
///
/// Load only from a user-owned Application Support file. Nothing in this type is
/// bundled, synced, or shipped with event-specific terms. Malformed or unsupported
/// input fails closed: the caller sees the error and gets an empty table rather than
/// a partial lexicon.
///
/// File: `~/Library/Application Support/v2s/speech-corrections.json`
///
/// ```json
/// {
///   "version": 1,
///   "languages": {
///     "zh-Hant": {
///       "hints": ["HintOnlyTerm"],
///       "corrections": [
///         { "canonical": "term", "aliases": ["asr-typo"] }
///       ]
///     },
///     "en": {
///       "hints": ["Riverton"],
///       "corrections": [
///         { "canonical": "Riverton", "aliases": ["rivertin"], "status": "safe" }
///       ]
///     }
///   }
/// }
/// ```
struct SpeechCorrectionDocument: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let languages: [String: SpeechCorrectionLanguageSection]

    init(version: Int, languages: [String: SpeechCorrectionLanguageSection]) {
        self.version = version
        self.languages = languages
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try SpeechCorrectionJSON.rejectUnknownKeys(in: decoder, allowed: CodingKeys.self, location: "document")
        version = try container.decode(Int.self, forKey: .version)
        languages = try container.decode([String: SpeechCorrectionLanguageSection].self, forKey: .languages)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(languages, forKey: .languages)
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case languages
    }
}

struct SpeechCorrectionLanguageSection: Codable, Equatable, Sendable {
    let hints: [String]?
    let corrections: [SpeechCorrectionEntry]?

    init(hints: [String]? = nil, corrections: [SpeechCorrectionEntry]? = nil) {
        self.hints = hints
        self.corrections = corrections
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try SpeechCorrectionJSON.rejectUnknownKeys(in: decoder, allowed: CodingKeys.self, location: "section")
        hints = try container.decodeIfPresent([String].self, forKey: .hints)
        corrections = try container.decodeIfPresent([SpeechCorrectionEntry].self, forKey: .corrections)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(hints, forKey: .hints)
        try container.encodeIfPresent(corrections, forKey: .corrections)
    }

    private enum CodingKeys: String, CodingKey {
        case hints
        case corrections
    }
}

struct SpeechCorrectionEntry: Codable, Equatable, Sendable {
    let canonical: String
    let aliases: [String]?
    /// `safe` (default) is applied. `review` and `unsafe` are validated out.
    let status: String?

    init(canonical: String, aliases: [String]? = nil, status: String? = nil) {
        self.canonical = canonical
        self.aliases = aliases
        self.status = status
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try SpeechCorrectionJSON.rejectUnknownKeys(in: decoder, allowed: CodingKeys.self, location: "entry")
        canonical = try container.decode(String.self, forKey: .canonical)
        aliases = try container.decodeIfPresent([String].self, forKey: .aliases)
        status = try container.decodeIfPresent(String.self, forKey: .status)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(canonical, forKey: .canonical)
        try container.encodeIfPresent(aliases, forKey: .aliases)
        try container.encodeIfPresent(status, forKey: .status)
    }

    var isSafeToApply: Bool {
        let normalized = (status ?? "safe")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized == "safe" || normalized.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case canonical
        case aliases
        case status
    }
}

private enum SpeechCorrectionJSON {
    struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    static func rejectUnknownKeys<Keys: CodingKey>(
        in decoder: Decoder,
        allowed: Keys.Type,
        location: String
    ) throws {
        let extras = try decoder.container(keyedBy: AnyKey.self)
        for key in extras.allKeys {
            guard Keys(stringValue: key.stringValue) != nil else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: extras.codingPath,
                        debugDescription: "unknown \(location) key '\(key.stringValue)'"
                    )
                )
            }
        }
    }
}
enum SpeechCorrectionLoadError: Error, Equatable, CustomStringConvertible {
    case unsupportedVersion(Int)
    case malformed(String)
    case conflictingAlias(language: String, alias: String, first: String, second: String)

    var description: String {
        switch self {
        case .unsupportedVersion(let version):
            return "speech-corrections.json version \(version) is unsupported (expected \(SpeechCorrectionDocument.currentVersion))."
        case .malformed(let detail):
            return "speech-corrections.json is malformed: \(detail)"
        case .conflictingAlias(let language, let alias, let first, let second):
            return "speech-corrections.json conflict in \(language): alias \(alias) maps to both \(first) and \(second)."
        }
    }
}

/// Compiled, language-scoped replacement table. Patterns are built once per load,
/// not per recognition result.
struct SpeechCorrectionTable: Equatable, Sendable {
    static let empty = SpeechCorrectionTable(languages: [:])

    fileprivate struct Pattern: Equatable, Sendable {
        let alias: String
        let foldedAlias: String
        let canonical: String
        let aliasCharacterCount: Int
        let isCaseInsensitive: Bool
        let isASCII: Bool
        let asciiLowercasedBytes: [UInt8]
        let needsLeadingBoundary: Bool
        let needsTrailingBoundary: Bool
    }

    fileprivate struct LanguageTable: Equatable, Sendable {
        let patternsByFirstCharacter: [Character: [Pattern]]
        let canonicalTerms: [String]
    }

    fileprivate let languages: [String: LanguageTable]

    var isEmpty: Bool { languages.isEmpty }

    func canonicalTerms(for languageID: String) -> [String] {
        table(for: languageID)?.canonicalTerms ?? []
    }

    func apply(_ text: String, languageID: String) -> String {
        guard text.isEmpty == false,
              let table = table(for: languageID),
              table.patternsByFirstCharacter.isEmpty == false else {
            return text
        }

        var output = ""
        output.reserveCapacity(text.utf8.count)
        var index = text.startIndex

        while index < text.endIndex {
            let first = text[index]
            var matched = false

            if let candidates = table.patternsByFirstCharacter[first] {
                for pattern in candidates {
                    guard let aliasEnd = text.index(
                        index,
                        offsetBy: pattern.aliasCharacterCount,
                        limitedBy: text.endIndex
                    ) else {
                        continue
                    }
                    let slice = text[index..<aliasEnd]
                    if pattern.isCaseInsensitive {
                        if pattern.isASCII {
                            var isSliceASCII = true
                            let asciiMatch = slice.utf8.elementsEqual(pattern.asciiLowercasedBytes, by: { byte, expected in
                                if byte >= 128 {
                                    isSliceASCII = false
                                    return false
                                }
                                let lower = (byte >= 65 && byte <= 90) ? (byte + 32) : byte
                                return lower == expected
                            })
                            if isSliceASCII {
                                guard asciiMatch else { continue }
                            } else {
                                guard foldLatin(slice) == pattern.foldedAlias else {
                                    continue
                                }
                            }
                        } else {
                            guard foldLatin(slice) == pattern.foldedAlias else {
                                continue
                            }
                        }
                    } else if slice != pattern.alias[...] {
                        continue
                    }
                    if pattern.needsLeadingBoundary,
                       hasNonCJKWordCharacter(before: index, in: text) {
                        continue
                    }
                    if pattern.needsTrailingBoundary,
                       hasNonCJKWordCharacter(at: aliasEnd, in: text) {
                        continue
                    }
                    output.append(pattern.canonical)
                    index = aliasEnd
                    matched = true
                    break
                }
            }

            if matched == false {
                output.append(first)
                index = text.index(after: index)
            }
        }

        return output
    }

    private func table(for languageID: String) -> LanguageTable? {
        let canonical = LanguageIdentity.canonicalLanguageID(languageID)
        if let table = languages[canonical] {
            return table
        }
        return languages[languageID]
    }
}

enum SpeechCorrectionService {
    static let fileName = "speech-corrections.json"
    static let maximumRecognitionPhrases = 100
    static let maximumRecognitionPhraseLength = 40
    static let maximumCorrectionLength = 80

    static func applicationSupportFileURL(
        fileManager: FileManager = .default
    ) -> URL {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root
            .appendingPathComponent("v2s", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// Missing file -> empty table. Any other failure throws and must not be applied.
    static func load(
        from fileURL: URL,
        fileManager: FileManager = .default
    ) throws -> SpeechCorrectionTable {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoSuchFileError {
                return .empty
            }
            throw SpeechCorrectionLoadError.malformed(error.localizedDescription)
        }
        return try compile(data)
    }

    static func loadDefault() throws -> SpeechCorrectionTable {
        try load(from: applicationSupportFileURL())
    }

    static func compile(_ data: Data) throws -> SpeechCorrectionTable {
        let document: SpeechCorrectionDocument
        do {
            document = try JSONDecoder().decode(SpeechCorrectionDocument.self, from: data)
        } catch {
            throw SpeechCorrectionLoadError.malformed(error.localizedDescription)
        }
        return try compile(document)
    }

    static func compile(_ document: SpeechCorrectionDocument) throws -> SpeechCorrectionTable {
        guard document.version == SpeechCorrectionDocument.currentVersion else {
            throw SpeechCorrectionLoadError.unsupportedVersion(document.version)
        }

        var compiled: [String: SpeechCorrectionTable.LanguageTable] = [:]
        var canonicalToRaw: [String: String] = [:]
        for (rawLanguage, section) in document.languages {
            let languageID = LanguageIdentity.canonicalLanguageID(rawLanguage)
            guard languageID.isEmpty == false else {
                throw SpeechCorrectionLoadError.malformed("empty language identifier")
            }
            if let existing = canonicalToRaw[languageID] {
                throw SpeechCorrectionLoadError.malformed("duplicate canonical language section \(languageID) ('\(existing)' and '\(rawLanguage)')")
            }
            canonicalToRaw[languageID] = rawLanguage
            compiled[languageID] = try compileLanguage(languageID, section: section)
        }
        return SpeechCorrectionTable(languages: compiled)
    }

    /// Canonical terms only — never raw ASR aliases — merged with glossary source keys.
    static func recognitionPhrases(
        corrections: SpeechCorrectionTable,
        languageIDs: [String],
        glossaryKeys: [String]
    ) -> [String] {
        var phrases: [String] = []
        var seen = Set<String>()

        func append(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false,
                  trimmed.count <= maximumRecognitionPhraseLength else {
                return
            }
            let normalized = trimmed.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard seen.insert(normalized).inserted else {
                return
            }
            phrases.append(trimmed)
        }

        for languageID in languageIDs {
            for term in corrections.canonicalTerms(for: languageID) {
                append(term)
            }
        }
        for key in glossaryKeys {
            append(key)
        }

        phrases.sort { lhs, rhs in
            if lhs.count == rhs.count {
                let lhsFolded = lhs.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                let rhsFolded = rhs.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                return lhsFolded == rhsFolded ? lhs < rhs : lhsFolded < rhsFolded
            }
            return lhs.count > rhs.count
        }
        if phrases.count > maximumRecognitionPhrases {
            phrases = Array(phrases.prefix(maximumRecognitionPhrases))
        }
        return phrases
    }

    /// Phrases that are safe to bias both transcribers in dual-lane mode (entirely Latin lexical terms).
    static func neutralRecognitionPhrases(
        corrections: SpeechCorrectionTable,
        languageIDs: [String],
        glossaryKeys: [String] = []
    ) -> [String] {
        let all = recognitionPhrases(corrections: corrections, languageIDs: languageIDs, glossaryKeys: glossaryKeys)
        return all.filter { phrase in
            CaptionLanguagePolicy.classifyHeardScript(phrase) == .entirelyLatin
        }
    }

    private static func compileLanguage(
        _ languageID: String,
        section: SpeechCorrectionLanguageSection
    ) throws -> SpeechCorrectionTable.LanguageTable {
        var aliasToCanonical: [String: String] = [:]
        var canonicalOrder: [String] = []
        var canonicalSeen = Set<String>()
        var patternsByFirstCharacter: [Character: [SpeechCorrectionTable.Pattern]] = [:]

        if let hints = section.hints {
            for rawHint in hints {
                let hint = rawHint.trimmingCharacters(in: .whitespacesAndNewlines)
                guard hint.isEmpty == false else {
                    throw SpeechCorrectionLoadError.malformed("empty hint in \(languageID)")
                }
                if hint.count > maximumRecognitionPhraseLength {
                    throw SpeechCorrectionLoadError.malformed("hint in \(languageID) exceeds \(maximumRecognitionPhraseLength) characters")
                }
                if canonicalSeen.insert(hint).inserted {
                    canonicalOrder.append(hint)
                }
            }
        }

        if let entries = section.corrections {
            for entry in entries {
                if let rawStatus = entry.status {
                    let status = rawStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if status != "safe" && status != "review" && status != "unsafe" && status.isEmpty == false {
                        throw SpeechCorrectionLoadError.malformed("unknown status '\(rawStatus)' in \(languageID)")
                    }
                }

                guard entry.isSafeToApply else {
                    continue
                }
                let canonical = entry.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
                guard canonical.isEmpty == false else {
                    throw SpeechCorrectionLoadError.malformed("empty canonical term in \(languageID)")
                }
                if canonical.count > maximumCorrectionLength {
                    throw SpeechCorrectionLoadError.malformed("canonical in \(languageID) exceeds \(maximumCorrectionLength) characters")
                }

                for rawAlias in (entry.aliases ?? []) {
                    let alias = rawAlias.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard alias.isEmpty == false else {
                        throw SpeechCorrectionLoadError.malformed("empty alias for \(canonical) in \(languageID)")
                    }
                    if alias.count > maximumCorrectionLength {
                        throw SpeechCorrectionLoadError.malformed("alias in \(languageID) exceeds \(maximumCorrectionLength) characters")
                    }
                    if alias == canonical {
                        continue
                    }
                    let aliasKey = foldLatin(alias[...])
                    if aliasKey == foldLatin(canonical[...]) {
                        continue
                    }
                    if let existing = aliasToCanonical[aliasKey], existing != canonical {
                        throw SpeechCorrectionLoadError.conflictingAlias(
                            language: languageID,
                            alias: alias,
                            first: existing,
                            second: canonical
                        )
                    }
                    aliasToCanonical[aliasKey] = canonical

                    let isCaseInsensitive = alias.contains(where: isLatinLetter)
                    let isASCII = alias.utf8.allSatisfy { $0 < 128 }
                    let asciiLowercasedBytes: [UInt8] = isASCII
                        ? alias.utf8.map { ($0 >= 65 && $0 <= 90) ? ($0 + 32) : $0 }
                        : []
                    let pattern = SpeechCorrectionTable.Pattern(
                        alias: alias,
                        foldedAlias: aliasKey,
                        canonical: canonical,
                        aliasCharacterCount: alias.count,
                        isCaseInsensitive: isCaseInsensitive,
                        isASCII: isASCII,
                        asciiLowercasedBytes: asciiLowercasedBytes,
                        needsLeadingBoundary: isBoundaryRelevant(alias.unicodeScalars.first),
                        needsTrailingBoundary: isBoundaryRelevant(alias.unicodeScalars.last)
                    )

                    var firstCharacters = Set<Character>()
                    if let first = alias.first {
                        firstCharacters.insert(first)
                        if isCaseInsensitive {
                            for char in String(first).lowercased() {
                                firstCharacters.insert(char)
                            }
                            for char in String(first).uppercased() {
                                firstCharacters.insert(char)
                            }
                        }
                    }

                    for first in firstCharacters {
                        patternsByFirstCharacter[first, default: []].append(pattern)
                    }
                }

                if canonicalSeen.insert(canonical).inserted {
                    canonicalOrder.append(canonical)
                }
            }
        }

        for key in patternsByFirstCharacter.keys {
            patternsByFirstCharacter[key]?.sort { lhs, rhs in
                if lhs.aliasCharacterCount == rhs.aliasCharacterCount {
                    return lhs.alias < rhs.alias
                }
                return lhs.aliasCharacterCount > rhs.aliasCharacterCount
            }
        }

        return SpeechCorrectionTable.LanguageTable(
            patternsByFirstCharacter: patternsByFirstCharacter,
            canonicalTerms: canonicalOrder
        )
    }

    private static func isBoundaryRelevant(_ scalar: Unicode.Scalar?) -> Bool {
        guard let scalar else { return false }
        return CharacterSet.alphanumerics.contains(scalar) && LanguageIdentity.isCJKScalar(scalar) == false
    }
}

private func hasNonCJKWordCharacter(before index: String.Index, in text: String) -> Bool {
    guard index > text.startIndex else { return false }
    let previous = text.index(before: index)
    return isNonCJKWordCharacter(text[previous])
}

private func hasNonCJKWordCharacter(at index: String.Index, in text: String) -> Bool {
    guard index < text.endIndex else { return false }
    return isNonCJKWordCharacter(text[index])
}

private func isNonCJKWordCharacter(_ character: Character) -> Bool {
    guard let scalar = character.unicodeScalars.first else { return false }
    return CharacterSet.alphanumerics.contains(scalar) && LanguageIdentity.isCJKScalar(scalar) == false
}

private func isLatinLetter(_ character: Character) -> Bool {
    character.unicodeScalars.contains { scalar in
        LanguageIdentity.isLatinScalar(scalar)
    }
}

private func foldLatin(_ text: Substring) -> String {
    var output = ""
    output.reserveCapacity(text.utf8.count)
    for character in text {
        if isLatinLetter(character) {
            output.append(contentsOf: character.lowercased())
        } else {
            output.append(character)
        }
    }
    return output
}
