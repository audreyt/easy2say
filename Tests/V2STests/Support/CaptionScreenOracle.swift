import Foundation

/// Test-owned description of what one caption pane showed, top to bottom.
/// Shares no types or classifiers with production: adapters in the harnesses
/// translate whatever the views drew into these values.
struct ObservedLine: Equatable {
    var text: String
    /// Characters from the start of the line drawn in the settled (stable) style.
    var stableCount: Int
    /// True when this line begins a new caption row (utterance).
    var startsRow: Bool

    init(_ text: String, stable: Int? = nil, startsRow: Bool = false) {
        self.text = text
        self.stableCount = min(max(0, stable ?? text.count), text.count)
        self.startsRow = startsRow
    }
}

struct ObservedScreen {
    var time: TimeInterval
    /// Pane name → lines. A pane absent from a frame is treated as empty.
    var panes: [String: [ObservedLine]]
}

struct CaptionViolation: Equatable, CustomStringConvertible {
    enum Kind: String, CaseIterable {
        /// A line visible in both frames moved to a lower position.
        case movedDown
        /// Words drawn in the settled style changed or disappeared.
        case stableRetraction
        /// A row disappeared without scrolling off the top and came back.
        case vanish
        /// A line that scrolled off the top came back into the pane.
        case resurrect
        /// One frame shows the same utterance twice.
        case duplicateRow
        /// A pane went blank and filled again shortly after.
        case blink
    }

    let kind: Kind
    let pane: String
    let time: TimeInterval
    let detail: String

    var description: String {
        String(format: "%@ %@ t=%.3fs %@", kind.rawValue, pane, time, detail)
    }
}

struct CaptionPaneMetrics: Equatable {
    var changedFrames = 0
    /// Characters removed or replaced after the common prefix (raw text).
    var retractedCharacters = 0
    var appendedCharacters = 0
    /// Frames in which one or more lines scrolled off the top.
    var scrollEvents = 0
    /// Lines wholly inside unchanged text whose line break nevertheless moved.
    var settledReflows = 0
    /// Most changed frames inside any one-second window.
    var peakChangesPerSecond = 0
    /// Settled words corrected in place by a same-length substitution of at
    /// most `maximumInPlaceCorrection` characters.
    var inPlaceCorrections = 0
}

struct CaptionOracleReport {
    var violations: [CaptionViolation]
    var metrics: [String: CaptionPaneMetrics]

    var summary: String {
        var lines: [String] = []
        for (pane, m) in metrics.sorted(by: { $0.key < $1.key }) {
            lines.append(
                "  \(pane): changes=\(m.changedFrames) retracted=\(m.retractedCharacters) appended=\(m.appendedCharacters) "
                    + "scrolls=\(m.scrollEvents) reflows=\(m.settledReflows) peak/s=\(m.peakChangesPerSecond) "
                    + "corrections=\(m.inPlaceCorrections)"
            )
        }
        let counts = Dictionary(grouping: violations, by: \.kind).mapValues(\.count)
        for kind in CaptionViolation.Kind.allCases {
            if let count = counts[kind] { lines.append("  \(kind.rawValue): \(count)") }
        }
        return lines.joined(separator: "\n")
    }
}

/// The caption flicker oracle. Hard violations are defects; metrics quantify
/// residual motion so policies can be compared.
enum CaptionScreenOracle {
    static let vanishWindow: TimeInterval = 2.0
    static let resurrectWindow: TimeInterval = 3.0
    static let blinkWindow: TimeInterval = 1.0
    /// Rows or lines shorter than this (in lexical characters) are too generic to
    /// identify an utterance, so they never trigger identity-based checks.
    static let minimumIdentityLength = 4
    static let minimumResurrectLength = 8
    static let maximumInPlaceCorrection = 2

    static func evaluate(_ screens: [ObservedScreen]) -> CaptionOracleReport {
        let paneNames = Set(screens.flatMap { $0.panes.keys }).sorted()
        var violations: [CaptionViolation] = []
        var metrics: [String: CaptionPaneMetrics] = [:]
        for pane in paneNames {
            let frames = screens.map { (time: $0.time, lines: $0.panes[pane] ?? []) }
            let result = evaluatePane(pane, frames)
            violations += result.violations
            metrics[pane] = result.metrics
        }
        violations.sort { ($0.time, $0.pane) < ($1.time, $1.pane) }
        return CaptionOracleReport(violations: violations, metrics: metrics)
    }

    // MARK: Per pane

    private struct Pending {
        let key: [Unicode.Scalar]
        let text: String
        let time: TimeInterval
    }

    private static func evaluatePane(
        _ pane: String,
        _ frames: [(time: TimeInterval, lines: [ObservedLine])]
    ) -> (violations: [CaptionViolation], metrics: CaptionPaneMetrics) {
        var violations: [CaptionViolation] = []
        var metrics = CaptionPaneMetrics()
        var changeTimes: [TimeInterval] = []
        var missingRows: [Pending] = []
        var evictedLines: [Pending] = []
        var lastNonEmptyTime: TimeInterval?
        var blankSince: TimeInterval?

        func flag(_ kind: CaptionViolation.Kind, _ time: TimeInterval, _ detail: String) {
            violations.append(CaptionViolation(kind: kind, pane: pane, time: time, detail: detail))
        }

        for index in frames.indices {
            let (time, lines) = frames[index]
            let currentKey = lexical(lines.map(\.text).joined())

            // Identity-based checks against earlier disappearances.
            missingRows.removeAll { time - $0.time > vanishWindow }
            evictedLines.removeAll { time - $0.time > resurrectWindow }
            missingRows.removeAll { missing in
                guard contains(currentKey, missing.key) else { return false }
                flag(.vanish, time, "row returned after \(ms(time - missing.time)): \(missing.text)")
                return true
            }
            let currentLineKeys = lines.map { lexical($0.text) }
            evictedLines.removeAll { evicted in
                guard currentLineKeys.contains(evicted.key) else { return false }
                flag(.resurrect, time, "line scrolled off and returned: \(evicted.text)")
                return true
            }

            // Duplicate rows within one frame.
            let rowKeys = rows(of: lines).map { (text: $0, key: lexical($0)) }
            for (a, b) in zip(rowKeys, rowKeys.dropFirst()) {
                guard a.key.count >= minimumIdentityLength, b.key.count >= minimumIdentityLength else { continue }
                if a.key.starts(with: b.key) || b.key.starts(with: a.key) {
                    flag(.duplicateRow, time, "\(a.text) | \(b.text)")
                }
            }

            // Blink: blank between two non-empty frames.
            if currentKey.isEmpty {
                if blankSince == nil, lastNonEmptyTime != nil { blankSince = time }
            } else {
                if let blankSince, time - blankSince <= blinkWindow {
                    flag(.blink, blankSince, "pane blank for \(ms(time - blankSince))")
                }
                blankSince = nil
                lastNonEmptyTime = time
            }

            guard index > 0 else { continue }
            let old = frames[index - 1].lines
            guard old != lines else { continue }
            metrics.changedFrames += 1
            changeTimes.append(time)

            let k = scrollOffset(old: old, new: lines)
            if k > 0 {
                metrics.scrollEvents += 1
                for line in old[0..<k] {
                    let key = lexical(line.text)
                    if key.count >= minimumResurrectLength {
                        evictedLines.append(Pending(key: key, text: line.text, time: time))
                    }
                }
            }

            // Lines that moved down.
            let oldIndex = uniqueIndices(old.map(\.text))
            let newIndex = uniqueIndices(lines.map(\.text))
            for (text, i) in oldIndex where lexical(text).count >= minimumIdentityLength {
                if let j = newIndex[text], j > i {
                    flag(.movedDown, time, "line \(i)→\(j): \(text)")
                }
            }

            // Everything below compares lexical keys (letters and digits, case- and
            // diacritic-folded), so spacing, punctuation and case settling at
            // finalization are not motion.
            let kept = Array(old[k...])
            let keptKeys = kept.map { lexical($0.text) }
            let newKeys = lines.map { lexical($0.text) }
            let oldText = keptKeys.flatMap { $0 }
            let newText = newKeys.flatMap { $0 }
            let common = commonPrefixLength(oldText, newText)
            metrics.retractedCharacters += oldText.count - common
            metrics.appendedCharacters += newText.count - common

            // Stable words changed. A pane going wholly blank is judged by the
            // vanish and blink checks instead.
            let oldStable = stableText(kept)
            let oldStableKey = lexical(oldStable)
            if newText.isEmpty == false, oldStableKey.isEmpty == false, newText.starts(with: oldStableKey) == false {
                // A recognizer correcting one or two characters in place (他 → 它,
                // 之前會 → 之前都會) keeps everything else where it was; count it,
                // do not fail on it. Losing or rewriting more is a violation.
                if isSmallCorrection(of: oldStableKey, in: newText) {
                    metrics.inPlaceCorrections += 1
                } else {
                    let keep = commonPrefixLength(oldStableKey, newText)
                    flag(
                        .stableRetraction, time,
                        "stable \"\(oldStable)\" → \"\(lines.map(\.text).joined(separator: "⏎"))\" (kept \(keep)/\(oldStableKey.count))"
                    )
                }
            }

            // Settled reflow: a line entirely inside the common prefix, and not the
            // last such line, must break exactly where it did.
            var consumed = 0
            for (offset, key) in keptKeys.enumerated() {
                consumed += key.count
                guard consumed < common, offset + 1 < keptKeys.count else { break }
                if offset >= newKeys.count || newKeys[offset] != key {
                    metrics.settledReflows += 1
                }
            }

            // Rows that left without scrolling off the top.
            let scrolledOff = Set(old[0..<k].map(\.text))
            let newKey = lexical(lines.map(\.text).joined())
            for row in rows(of: old) {
                let key = lexical(row)
                guard key.count >= minimumIdentityLength, contains(newKey, key) == false else { continue }
                // A row that only lost its tail to a revision, or merged into its
                // neighbour, still has its opening on screen.
                let opening = Array(key.prefix(minimumIdentityLength))
                if contains(newKey, opening) { continue }
                if rowLines(row, in: old).allSatisfy({ scrolledOff.contains($0) }) { continue }
                missingRows.append(Pending(key: key, text: row, time: time))
            }
        }

        var peak = 0
        var start = 0
        for end in changeTimes.indices {
            while changeTimes[end] - changeTimes[start] >= 1.0 { start += 1 }
            peak = max(peak, end - start + 1)
        }
        metrics.peakChangesPerSecond = peak
        return (violations, metrics)
    }

    // MARK: Helpers

    /// Lines dropped from the top: the offset whose remaining lines share the
    /// longest lexical prefix with the new frame (smallest offset on ties).
    static func scrollOffset(old: [ObservedLine], new: [ObservedLine]) -> Int {
        let newText = new.flatMap { lexical($0.text) }
        let oldKeys = old.map { lexical($0.text) }
        var best = 0
        var bestCommon = -1
        for k in 0...old.count {
            let common = commonPrefixLength(oldKeys[k...].flatMap { $0 }, newText)
            if common > bestCommon {
                bestCommon = common
                best = k
            }
        }
        return bestCommon == 0 && newText.isEmpty == false ? scrollOffsetWithoutOverlap(old: old, new: new) : best
    }

    /// No shared prefix at all. If the new first line was already on screen,
    /// everything above it scrolled off. If it opens a new row that is not a
    /// rewrite of an old line, the whole old window scrolled off above it.
    /// Otherwise the content was replaced in place.
    private static func scrollOffsetWithoutOverlap(old: [ObservedLine], new: [ObservedLine]) -> Int {
        guard let first = new.first else { return 0 }
        let firstKey = lexical(first.text)
        if let index = old.firstIndex(where: { lexical($0.text) == firstKey }) { return index }
        let rewritesOldLine = old.contains { similarity(lexical($0.text), firstKey) >= 0.5 }
        return first.startsRow && rewritesOldLine == false ? old.count : 0
    }

    /// True when `stable` becomes a prefix of `new` after at most
    /// `maximumInPlaceCorrection` single-character edits.
    static func isSmallCorrection(of stable: [Unicode.Scalar], in new: [Unicode.Scalar]) -> Bool {
        let keep = commonPrefixLength(stable, new)
        let oldTail = Array(stable[keep...])
        let limit = maximumInPlaceCorrection
        let lower = max(keep, keep + oldTail.count - limit)
        let upper = min(new.count, keep + oldTail.count + limit)
        guard lower <= upper else { return false }
        for end in lower...upper {
            let newTail = Array(new[keep..<end])
            if editDistance(oldTail, newTail) <= limit { return true }
        }
        return false
    }

    static func editDistance(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    /// 1 − normalized edit distance.
    static func similarity(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Double {
        guard a.isEmpty == false || b.isEmpty == false else { return 1 }
        var previous = Array(0...b.count)
        for i in 1...max(1, a.count) where a.isEmpty == false {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in stride(from: 1, through: b.count, by: 1) {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        let distance = a.isEmpty ? b.count : previous[b.count]
        return 1 - Double(distance) / Double(max(a.count, b.count))
    }

    static func lexical(_ text: String) -> [Unicode.Scalar] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars
            .filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
    }

    private static func stableText(_ lines: [ObservedLine]) -> String {
        // Stable styling is a prefix property of the pane's newest row; settled
        // rows are stable in full. Everything up to the first mutable character.
        var result = ""
        for line in lines {
            result += line.text.prefix(line.stableCount)
            if line.stableCount < line.text.count { break }
        }
        return result
    }

    private static func rows(of lines: [ObservedLine]) -> [String] {
        var rows: [String] = []
        for line in lines {
            if line.startsRow || rows.isEmpty {
                rows.append(line.text)
            } else {
                rows[rows.count - 1] += line.text
            }
        }
        return rows
    }

    private static func rowLines(_ row: String, in lines: [ObservedLine]) -> [String] {
        var groups: [[String]] = []
        for line in lines {
            if line.startsRow || groups.isEmpty { groups.append([line.text]) } else { groups[groups.count - 1].append(line.text) }
        }
        return groups.first(where: { $0.joined() == row }) ?? []
    }

    private static func uniqueIndices(_ texts: [String]) -> [String: Int] {
        var seen: [String: Int] = [:]
        var duplicated: Set<String> = []
        for (index, text) in texts.enumerated() {
            if seen[text] != nil { duplicated.insert(text) } else { seen[text] = index }
        }
        return seen.filter { duplicated.contains($0.key) == false }
    }

    private static func commonPrefixLength<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        var n = 0
        while n < a.count, n < b.count, a[n] == b[n] { n += 1 }
        return n
    }

    private static func contains(_ haystack: [Unicode.Scalar], _ needle: [Unicode.Scalar]) -> Bool {
        guard needle.isEmpty == false else { return true }
        guard needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count) where haystack[start] == needle[0] {
            if haystack[start..<(start + needle.count)].elementsEqual(needle) { return true }
        }
        return false
    }

    private static func ms(_ seconds: TimeInterval) -> String {
        "\(Int((seconds * 1000).rounded()))ms"
    }
}
