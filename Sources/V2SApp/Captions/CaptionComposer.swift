import Foundation

/// One display row: a sentence (or sentence fragment) with its settled prefix
/// and the audio time its latest character arrived.
struct ComposedRow: Equatable, Sendable {
    /// 0-based position in the session's row sequence.
    var ordinal: Int
    /// Heard language of this row.
    var languageID: String
    /// Text after trimming and speech corrections.
    var text: String
    /// Characters of `text` considered settled.
    var stableLength: Int
    /// Ends with a sentence terminator.
    var isTerminated: Bool
    /// Entirely inside finalized recognizer text.
    var isFinal: Bool
    /// Latest arrival stamp of the row's characters (audio ms).
    var lastArrivalMs: Int
    var speakerIndex: Int?
    /// Character range this row covers in the primary lane's text. For
    /// secondary-routed English rows this is the Latin span they replace.
    var primaryRange: Range<Int>
}

struct ComposerConfig {
    var primaryLanguageID: String
    var secondaryLanguageID = ""
    /// Speech corrections applied to each row text with its languageID.
    var correct: @Sendable (String, String) -> String = { text, _ in text }
}

/// Pure: lane states → sentence rows. No state is kept between calls; a
/// recomposition of unchanged inputs yields identical output.
enum CaptionComposer {
    static func compose(
        primary: CaptionLaneState,
        secondary: CaptionLaneState?,
        config: ComposerConfig
    ) -> [ComposedRow] {
        var rows: [Row]
        if let secondary, config.secondaryLanguageID.isEmpty == false {
            rows = dualRows(primary: primary, secondary: secondary, config: config)
        } else {
            let material = LaneMaterial(lane: primary)
            rows = rowsFrom(
                material,
                in: 0..<primary.text.count,
                languageID: config.primaryLanguageID,
                isFinalGate: true,
                extraBoundaries: material.finalEnds
            )
        }
        return rows.enumerated().map { index, row in
            let text = config.correct(row.text, row.languageID)
            var stableLength = row.stableLength
            if index == rows.count - 1, row.isFinal == false {
                stableLength = liveStableLength(of: text)
            }
            stableLength = min(stableLength, text.count)
            return ComposedRow(
                ordinal: index,
                languageID: row.languageID,
                text: text,
                stableLength: stableLength,
                isTerminated: row.isTerminated,
                isFinal: row.isFinal,
                lastArrivalMs: row.lastArrivalMs,
                speakerIndex: row.speakerIndex,
                primaryRange: row.primaryRange
            )
        }
    }

    // MARK: - Row construction

    /// A row before corrections and the last-row stable rule are applied.
    private struct Row {
        var languageID: String
        var text: String
        var stableLength: Int
        var isTerminated: Bool
        var isFinal: Bool
        var lastArrivalMs: Int
        var speakerIndex: Int?
        var primaryRange: Range<Int>
    }

    /// Lane text exploded into per-character arrays so segments can be sliced.
    private struct LaneMaterial {
        var characters: [Character]
        var arrivals: [Int]
        /// Chapters backed by finals form the prefix [0, finalCount).
        var finalCount: Int
        /// Character index → index into `finals`, -1 for volatile characters.
        var finalIndexOfChar: [Int]
        var finals: [CaptionLaneState.FinalizedSegment]

        init(lane: CaptionLaneState) {
            characters = Array(lane.text)
            arrivals = lane.arrivalMs
            while arrivals.count < characters.count {
                arrivals.append(arrivals.last ?? 0)
            }
            finalCount = lane.finalCharacterCount
            finals = lane.finals
            var map = [Int](repeating: -1, count: characters.count)
            var offset = 0
            for (index, final) in lane.finals.enumerated() {
                for position in offset..<min(offset + final.text.count, characters.count) {
                    map[position] = index
                }
                offset += final.text.count
            }
            finalIndexOfChar = map
        }

        /// Cumulative character ends of the finals, ascending — the row
        /// boundaries the analyzer itself committed to.
        var finalEnds: [Int] {
            var ends: [Int] = []
            var offset = 0
            for final in finals {
                offset += final.text.count
                ends.append(offset)
            }
            return ends
        }

        init(characters: [Character], arrivals: [Int], finalCount: Int, finalIndexOfChar: [Int], finals: [CaptionLaneState.FinalizedSegment]) {
            self.characters = characters
            var padded = arrivals
            while padded.count < characters.count {
                padded.append(arrivals.last ?? 0)
            }
            self.arrivals = padded
            self.finalCount = finalCount
            var indexMap = finalIndexOfChar
            while indexMap.count < characters.count {
                indexMap.append(-1)
            }
            self.finalIndexOfChar = indexMap
            self.finals = finals
        }

        /// The material restricted to a range of the source lane's characters.
        /// `finalCount` still counts from position 0 of the source text, so
        /// `isFinal` checks stay in source coordinates.
        var isEmpty: Bool { characters.isEmpty }
    }

    /// Splits `material[range]` into sentence fragments, merges whitespace- or
    /// punctuation-only fragments into their neighbours, and builds one row
    /// per fragment. `isFinalGate` additionally requires the row to sit inside
    /// finalized source characters.
    private static func rowsFrom(
        _ material: LaneMaterial,
        in range: Range<Int>,
        languageID: String,
        isFinalGate: Bool,
        extraBoundaries: [Int] = []
    ) -> [Row] {
        // A boundary position always ends a row, even mid-sentence.
        var fragments: [Range<Int>] = []
        for piece in splitRange(range, at: extraBoundaries) {
            fragments += sentenceFragments(in: material.characters, range: piece)
        }
        fragments = mergeNonLexicalFragments(fragments, into: material.characters)
        return fragments.compactMap { fragment in
            guard let display = trimmedRange(fragment, in: material.characters) else {
                return nil
            }
            let text = String(material.characters[display])
            let firstFinal = material.finalIndexOfChar[display.lowerBound]
            return Row(
                languageID: languageID,
                text: text,
                stableLength: text.count,
                isTerminated: isTerminated(material.characters, in: display),
                isFinal: isFinalGate && fragment.upperBound <= material.finalCount,
                lastArrivalMs: material.arrivals[display].max() ?? 0,
                speakerIndex: firstFinal >= 0 ? material.finals[firstFinal].speakerIndex : nil,
                primaryRange: fragment
            )
        }
    }

    /// Splits `range` at each boundary strictly inside it.
    private static func splitRange(_ range: Range<Int>, at boundaries: [Int]) -> [Range<Int>] {
        var pieces: [Range<Int>] = []
        var start = range.lowerBound
        for boundary in boundaries where boundary > start && boundary < range.upperBound {
            pieces.append(start..<boundary)
            start = boundary
        }
        pieces.append(start..<range.upperBound)
        return pieces
    }

    // MARK: - Sentence splitting

    private static func sentenceFragments(
        in characters: [Character],
        range: Range<Int>
    ) -> [Range<Int>] {
        var fragments: [Range<Int>] = []
        var start = range.lowerBound
        var index = range.lowerBound
        while index < range.upperBound {
            if terminates(characters, at: index, within: range) {
                fragments.append(start..<(index + 1))
                start = index + 1
            }
            index += 1
        }
        if start < range.upperBound {
            fragments.append(start..<range.upperBound)
        }
        return fragments
    }

    /// True when `characters[index]` ends a sentence. `.` terminates only when
    /// not part of "..." and not a known non-terminal abbreviation; CJK
    /// terminators terminate immediately.
    private static func terminates(
        _ characters: [Character],
        at index: Int,
        within range: Range<Int>
    ) -> Bool {
        switch characters[index] {
        case "。", "！", "？", "!", "?":
            return true
        case ".":
            if index > range.lowerBound, characters[index - 1] == "." {
                return false
            }
            let next = index + 1
            guard next >= range.upperBound || characters[next].isWhitespace else {
                return false
            }
            let preceding = String(characters[range.lowerBound...index].suffix(64))
            let following = next < range.upperBound
                ? String(characters[next..<range.upperBound].prefix(64))
                : nil
            return SentenceBoundaryHeuristics.endsWithLikelyNonTerminalAbbreviation(
                in: preceding,
                followedBy: following
            ) == false
        default:
            return false
        }
    }

    /// A fragment with no letter or digit attaches to the previous row; a
    /// leading one attaches forward. Rows never start punctuation-only.
    private static func mergeNonLexicalFragments(
        _ fragments: [Range<Int>],
        into characters: [Character]
    ) -> [Range<Int>] {
        var merged: [Range<Int>] = []
        var pendingLead: Range<Int>?
        for fragment in fragments {
            if hasLexicalContent(characters[fragment]) {
                let start = pendingLead?.lowerBound ?? fragment.lowerBound
                pendingLead = nil
                merged.append(start..<fragment.upperBound)
            } else if merged.isEmpty == false {
                merged[merged.count - 1] = merged[merged.count - 1].lowerBound..<fragment.upperBound
            } else {
                pendingLead = fragment
            }
        }
        return merged
    }

    private static func hasLexicalContent(_ characters: ArraySlice<Character>) -> Bool {
        characters.contains { character in
            character.unicodeScalars.contains {
                CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
            }
        }
    }

    private static func trimmedRange(
        _ range: Range<Int>,
        in characters: [Character]
    ) -> Range<Int>? {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper, characters[lower].isWhitespace { lower += 1 }
        while upper > lower, characters[upper - 1].isWhitespace { upper -= 1 }
        return lower < upper ? lower..<upper : nil
    }

    private static func isTerminated(_ characters: [Character], in range: Range<Int>) -> Bool {
        guard let last = range.last else { return false }
        switch characters[last] {
        case "。", "！", "？", "!", "?":
            return true
        case ".":
            guard range.lowerBound == last || characters[last - 1] != "." else {
                return false
            }
            return SentenceBoundaryHeuristics.endsWithLikelyNonTerminalAbbreviation(
                in: String(characters[range.lowerBound...last].suffix(64)),
                followedBy: nil
            ) == false
        default:
            return false
        }
    }

    /// The live row's settled prefix: for Latin text everything before the
    /// trailing partial token, for CJK everything but the final character.
    private static func liveStableLength(of text: String) -> Int {
        let characters = Array(text)
        guard characters.isEmpty == false else { return 0 }
        if text.unicodeScalars.contains(where: LanguageIdentity.isCJKScalar) {
            return characters.count - 1
        }
        if let whitespace = characters.lastIndex(where: \.isWhitespace) {
            return whitespace
        }
        return 0
    }

    // MARK: - Dual lane

    private enum Script {
        case han, latin, neutral
    }

    private struct ScriptSegment {
        var range: Range<Int>
        var isLatin: Bool
    }

    private static func dualRows(
        primary: CaptionLaneState,
        secondary: CaptionLaneState,
        config: ComposerConfig
    ) -> [Row] {
        let material = LaneMaterial(lane: primary)
        var segments = scriptSegments(of: material.characters)
        mergeShortLatinSegments(&segments, characters: material.characters)

        // boundary_i: min arrival of the first non-Latin segment after a Latin
        // script segment — the audio point where the heard lane switched back.
        var lastLatinSegment = -1
        var boundaryAfter: [Int: Int] = [:]
        for (index, segment) in segments.enumerated() where segment.isLatin {
            lastLatinSegment = index
            var boundary = Int.max
            for later in segments[(index + 1)...] where later.isLatin == false {
                boundary = material.arrivals[later.range].min() ?? Int.max
                break
            }
            boundaryAfter[index] = boundary
        }

        // Each final-end-split subRange is one Latin unit L_i, in primary order.
        var unitFirstArrival: [Int] = []
        var unitNextBoundary: [Int] = []
        var unitPreviousBoundary: [Int] = []
        var previousLatinSegment = -1
        for (index, segment) in segments.enumerated() where segment.isLatin {
            for subRange in splitRange(segment.range, at: material.finalEnds) {
                unitFirstArrival.append(material.arrivals[subRange].min() ?? 0)
                unitNextBoundary.append(boundaryAfter[index] ?? Int.max)
                // boundary_{i-1}: the Han boundary after the previous Latin
                // script segment; units inside one script segment share it.
                unitPreviousBoundary.append(
                    previousLatinSegment >= 0
                        ? (boundaryAfter[previousLatinSegment] ?? Int.max)
                        : Int.max
                )
            }
            previousLatinSegment = index
        }

        // Exclusive, greedy, in-order assignment of English islands.
        let islands = englishIslands(in: secondary)
        var assigned: [[SecondaryIsland]] = Array(
            repeating: [], count: unitFirstArrival.count
        )
        for island in islands {
            for unit in 0..<unitFirstArrival.count {
                let nextBoundary = unitNextBoundary[unit]
                let previousBoundary = unitPreviousBoundary[unit]
                let eligible = (nextBoundary == Int.max
                        || island.endMs <= nextBoundary + 300)
                    && island.startMs >= unitFirstArrival[unit] - 8_000
                    && (unit == 0
                        || (previousBoundary != Int.max
                            && island.startMs >= previousBoundary - 1_500))
                if eligible {
                    assigned[unit].append(island)
                    break
                }
            }
        }

        // The secondary volatile joins only the last Latin unit, and only when
        // the last Latin segment is also the primary's last segment.
        var volatileUnit: Int? = nil
        if let volatileStart = secondary.volatileRangeStartMs,
           unitFirstArrival.isEmpty == false,
           lastLatinSegment == segments.count - 1 {
            let last = unitFirstArrival.count - 1
            if last == 0 || volatileStart >= unitPreviousBoundary[last] - 1_500 {
                volatileUnit = last
            }
        }

        var rows: [Row] = []
        var unit = 0
        for segment in segments {
            if segment.isLatin == false {
                rows += rowsFrom(
                    material,
                    in: segment.range,
                    languageID: config.primaryLanguageID,
                    isFinalGate: true,
                    extraBoundaries: material.finalEnds
                )
                continue
            }

            // A primary final boundary splits a Latin segment too.
            for subRange in splitRange(segment.range, at: material.finalEnds) {
                let english = englishMaterial(
                    from: assigned[unit],
                    includeVolatile: volatileUnit == unit,
                    secondary: secondary
                )
                let primaryFinalizedPastSegment = subRange.upperBound <= material.finalCount
                if english.isEmpty || trimmedText(english.characters).isEmpty {
                    // No usable English coverage: keep the primary lane's Latin text.
                    rows += rowsFrom(
                        material,
                        in: subRange,
                        languageID: config.secondaryLanguageID,
                        isFinalGate: true
                    )
                } else {
                    // An English row is final only when its text came wholly from
                    // secondary finals and the primary finalized past the segment.
                    var segmentRows = rowsFrom(
                        english,
                        in: 0..<english.characters.count,
                        languageID: config.secondaryLanguageID,
                        isFinalGate: primaryFinalizedPastSegment
                    )
                    for rowIndex in segmentRows.indices {
                        segmentRows[rowIndex].primaryRange = subRange
                    }
                    rows += segmentRows
                }
                unit += 1
            }
        }
        return rows
    }

    /// Maximal script runs; neutral characters stay inside the open segment,
    /// so a run of them between scripts belongs to the preceding segment.
    private static func scriptSegments(of characters: [Character]) -> [ScriptSegment] {
        var segments: [ScriptSegment] = []
        var openScript: Script?
        var segmentStart = 0
        for index in characters.indices {
            let script = classify(characters[index])
            guard script != .neutral else { continue }
            if script == openScript { continue }
            if let openScript {
                segments.append(ScriptSegment(range: segmentStart..<index, isLatin: openScript == .latin))
            }
            openScript = script
            segmentStart = index
        }
        if let openScript, segmentStart < characters.count {
            segments.append(ScriptSegment(range: segmentStart..<characters.count, isLatin: openScript == .latin))
        }
        return segments
    }

    private static func classify(_ character: Character) -> Script {
        for scalar in character.unicodeScalars {
            if LanguageIdentity.isCJKScalar(scalar) { return .han }
            if LanguageIdentity.isLatinScalar(scalar) { return .latin }
        }
        return .neutral
    }

    /// A Latin span counts as its own segment when it has at least two Latin
    /// words or eight Latin letters; shorter spans merge into the surrounding
    /// Han segment so inline words like "demo" stay in a zh row.
    private static func qualifiesAsLatin(_ characters: ArraySlice<Character>) -> Bool {
        var words = 0
        var letters = 0
        var inWord = false
        for character in characters {
            let latin = character.unicodeScalars.contains(where: LanguageIdentity.isLatinScalar)
            if latin {
                letters += 1
                inWord = true
            } else if inWord {
                words += 1
                inWord = false
            }
        }
        if inWord { words += 1 }
        return words >= 2 || letters >= 8
    }

    private static func mergeShortLatinSegments(
        _ segments: inout [ScriptSegment],
        characters: [Character]
    ) {
        var index = 0
        while index < segments.count {
            let segment = segments[index]
            guard segment.isLatin,
                  qualifiesAsLatin(characters[segment.range]) == false,
                  segments.count > 1 else {
                index += 1
                continue
            }
            let hasPrevious = index > 0
            let hasNext = index + 1 < segments.count
            if hasPrevious, hasNext, segments[index - 1].isLatin == false, segments[index + 1].isLatin == false {
                segments[index - 1].range = segments[index - 1].range.lowerBound..<segments[index + 1].range.upperBound
                segments.removeSubrange(index...(index + 1))
            } else if hasPrevious {
                segments[index - 1].range = segments[index - 1].range.lowerBound..<segment.range.upperBound
                segments[index - 1].isLatin = false
                segments.remove(at: index)
            } else if hasNext {
                segments[index + 1].range = segment.range.lowerBound..<segments[index + 1].range.upperBound
                segments.remove(at: index)
            } else {
                index += 1
            }
        }
    }

    /// One confident Latin sentence inside a secondary final — the
    /// analyzer's own run boundaries, so a mixed pinyin+English final
    /// contributes only its English sentences.
    private struct SecondaryIsland {
        var finalIndex: Int
        /// Character range inside the final's text.
        var charRange: Range<Int>
        var startMs: Int
        var endMs: Int
    }

    /// Every assignment-eligible island from the secondary lane's finals,
    /// in start order.
    private static func englishIslands(
        in secondary: CaptionLaneState
    ) -> [SecondaryIsland] {
        var islands: [SecondaryIsland] = []
        for (index, final) in secondary.finals.enumerated() {
            islands += islandsInFinal(of: final, index: index, secondary: secondary)
        }
        return islands.sorted { $0.startMs < $1.startMs }
    }

    /// Split the final's runs into sentences — a run ending a sentence
    /// (same terminator rules as the row splitter) closes it — and keep each
    /// sentence containing Latin whose mean run confidence reaches 0.6.
    private static func islandsInFinal(
        of final: CaptionLaneState.FinalizedSegment,
        index: Int,
        secondary: CaptionLaneState
    ) -> [SecondaryIsland] {
        let runs = final.runs
        let hasTiming = runs.contains { $0.startMs != nil }
        let hasConfidence = runs.contains { $0.confidence != nil }
        if runs.isEmpty || hasTiming == false || hasConfidence == false {
            // No run data to segment on: the whole final is one candidate.
            guard (secondary.meanConfidence(ofFinalAt: index) ?? 0) >= 0.6 else {
                return []
            }
            return [SecondaryIsland(
                finalIndex: index,
                charRange: 0..<final.text.count,
                startMs: final.rangeStartMs,
                endMs: final.rangeEndMs
            )]
        }

        var islands: [SecondaryIsland] = []
        var charOffset = 0
        var sentenceStart = 0
        var confidences: [Double] = []
        var timedStart: Int? = nil
        var timedEnd: Int? = nil

        func closeSentence(at end: Int) {
            defer {
                sentenceStart = end
                confidences = []
                timedStart = nil
                timedEnd = nil
            }
            guard end > sentenceStart else { return }
            let characters = Array(final.text)[sentenceStart..<end]
            let hasLatin = characters.contains {
                $0.unicodeScalars.contains(where: LanguageIdentity.isLatinScalar)
            }
            guard hasLatin, confidences.isEmpty == false else { return }
            let mean = confidences.reduce(0, +) / Double(confidences.count)
            guard mean >= 0.6, let start = timedStart, let endMs = timedEnd else {
                return
            }
            islands.append(SecondaryIsland(
                finalIndex: index,
                charRange: sentenceStart..<end,
                startMs: start,
                endMs: endMs
            ))
        }

        for (runIndex, run) in runs.enumerated() {
            if let confidence = run.confidence {
                confidences.append(confidence)
            }
            if let start = run.startMs {
                if timedStart == nil { timedStart = start }
                timedEnd = start + (run.durationMs ?? 0)
            }
            charOffset += run.text.count
            let nextText = runIndex + 1 < runs.count ? runs[runIndex + 1].text : nil
            if SentenceBoundaryHeuristics.endsWithLikelySentenceTerminator(
                in: run.text, followedBy: nextText
            ) {
                closeSentence(at: charOffset)
            }
        }
        closeSentence(at: charOffset)
        return islands
    }

    /// The secondary lane's text for one Latin unit: its assigned islands in
    /// order plus the volatile tail when assigned.
    private static func englishMaterial(
        from islands: [SecondaryIsland],
        includeVolatile: Bool,
        secondary: CaptionLaneState
    ) -> LaneMaterial {
        var characters: [Character] = []
        var arrivals: [Int] = []
        var finalIndexOfChar: [Int] = []
        var finalCount = 0
        var offset = 0
        var finalOffsets: [Int] = []
        for final in secondary.finals {
            finalOffsets.append(offset)
            offset += final.text.count
        }
        for island in islands {
            let final = secondary.finals[island.finalIndex]
            let base = finalOffsets[island.finalIndex]
            let count = island.charRange.count
            characters += Array(final.text)[island.charRange]
            let arrivalStart = min(base + island.charRange.lowerBound, secondary.arrivalMs.count)
            let arrivalEnd = min(base + island.charRange.upperBound, secondary.arrivalMs.count)
            arrivals += secondary.arrivalMs[arrivalStart..<arrivalEnd]
            finalIndexOfChar += [Int](repeating: island.finalIndex, count: count)
            finalCount += count
        }
        if includeVolatile, secondary.volatileRangeStartMs != nil {
            let volatileCharacters = Array(secondary.volatileText)
            characters += volatileCharacters
            let volatileOffset = secondary.finalCharacterCount
            arrivals += secondary.arrivalMs[
                volatileOffset..<min(volatileOffset + volatileCharacters.count, secondary.arrivalMs.count)
            ]
            finalIndexOfChar += [Int](repeating: -1, count: volatileCharacters.count)
        }
        return LaneMaterial(
            characters: characters,
            arrivals: arrivals,
            finalCount: finalCount,
            finalIndexOfChar: finalIndexOfChar,
            finals: secondary.finals
        )
    }

    private static func trimmedText(_ characters: [Character]) -> String {
        String(characters).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
