import CoreGraphics
import CoreText
import Foundation

#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum CaptionFontWeight: Sendable {
    case regular
    case medium
    case semibold
    case bold
}

/// Per-pane font metrics. CTFont equality via CFEqual.
struct CaptionTypography: Equatable {
    var font: CTFont
    var lineHeight: CGFloat

    init(font: CTFont) {
        self.font = font
        self.lineHeight = CaptionLineBreaker.lineHeight(font)
    }

    init(font: CTFont, lineHeight: CGFloat) {
        self.font = font
        self.lineHeight = lineHeight
    }

    /// The shared system-font helper so views and tests lay out identically.
    static func system(size: CGFloat, weight: CaptionFontWeight) -> CaptionTypography {
        #if os(macOS)
        let nsWeight: NSFont.Weight
        switch weight {
        case .regular: nsWeight = .regular
        case .medium: nsWeight = .medium
        case .semibold: nsWeight = .semibold
        case .bold: nsWeight = .bold
        }
        return CaptionTypography(font: NSFont.systemFont(ofSize: size, weight: nsWeight) as CTFont)
        #else
        let uiWeight: UIFont.Weight
        switch weight {
        case .regular: uiWeight = .regular
        case .medium: uiWeight = .medium
        case .semibold: uiWeight = .semibold
        case .bold: uiWeight = .bold
        }
        return CaptionTypography(font: UIFont.systemFont(ofSize: size, weight: uiWeight) as CTFont)
        #endif
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        CFEqual(lhs.font as CFTypeRef, rhs.font as CFTypeRef) && lhs.lineHeight == rhs.lineHeight
    }
}

struct CaptionViewportConfig: Equatable {
    enum Arrangement: Equatable {
        case stacked(leading: CaptionPane)
        case columns(leading: CaptionPane)
    }
    enum Anchoring: Equatable {
        case bottom
        case top
    }
    var width: CGFloat
    var height: CGFloat
    var columnSpacing: CGFloat = 24
    var pairSpacing: CGFloat = 4
    var rowSpacing: CGFloat = 10
    var arrangement: Arrangement
    var anchoring: Anchoring
    var panes: CaptionPaneConfig
    var typography: [CaptionPane: CaptionTypography]
    var showsSpeakerBadges: Bool
    var badgeHeight: CGFloat

    var leadingPane: CaptionPane {
        switch arrangement {
        case .stacked(let pane), .columns(let pane): return pane
        }
    }

    var trailingPane: CaptionPane {
        leadingPane == .original ? .translated : .original
    }
}

struct CaptionScreenLine: Identifiable, Equatable {
    struct ID: Hashable {
        var row: CaptionRowID
        var pane: CaptionPane
        var index: Int
    }
    var id: ID
    var text: String
    var stableCount: Int
    var isDraft: Bool
    /// Column origin and column width (stacked: 0 / full width).
    var x: CGFloat
    var width: CGFloat
    /// Top of the line in viewport coordinates.
    var y: CGFloat
    var height: CGFloat
    /// First line of this pane in its row.
    var startsRow: Bool
}

struct CaptionScreenBadge: Identifiable, Equatable {
    var id: CaptionRowID
    var speakerIndex: Int
    var y: CGFloat
}

struct CaptionScreen: Equatable {
    var lines: [CaptionScreenLine]
    var badges: [CaptionScreenBadge]
    var contentTop: CGFloat
    /// True once scrolled content sits above the visible window — the top
    /// fade should draw only then, so nothing dims an un-scrolled first row.
    var hasContentAbove = false
}

/// Projects a `CaptionDocument` into an absolutely-positioned
/// `CaptionScreen`: high-water line reservations mean content only ever
/// grows, and the only motion is upward scrolling.
struct CaptionViewport {
    init() {}

    // MARK: State

    /// A row's break results for the pane text last seen, plus its reserved
    /// (high-water) geometry in absolute content coordinates.
    private struct RowState {
        var panes: [CaptionPane: PaneLayout] = [:]
        var reservedLines: [CaptionPane: Int] = [:]
        var badgeReserved = false
        var top: CGFloat = 0
        var height: CGFloat = 0
    }

    private struct PaneLayout {
        var text: CaptionPaneText
        var ranges: [Range<String.Index>]
    }

    private var states: [CaptionRowID: RowState] = [:]
    private var top: CGFloat = 0
    private var initialized = false
    private var pinnedRows = 0
    private var wasPinned = false
    private var layoutKey: LayoutKey?

    /// Any change here re-derives all geometry from scratch.
    private struct LayoutKey: Equatable {
        var width: CGFloat
        var columnSpacing: CGFloat
        var pairSpacing: CGFloat
        var rowSpacing: CGFloat
        var arrangement: CaptionViewportConfig.Arrangement
        var panes: CaptionPaneConfig
        var typography: [CaptionPane: CaptionTypography]
        var showsSpeakerBadges: Bool
        var badgeHeight: CGFloat
    }

    // MARK: Update

    mutating func update(
        _ document: CaptionDocument,
        config: CaptionViewportConfig
    ) -> CaptionScreen {
        let key = LayoutKey(
            width: config.width,
            columnSpacing: config.columnSpacing,
            pairSpacing: config.pairSpacing,
            rowSpacing: config.rowSpacing,
            arrangement: config.arrangement,
            panes: config.panes,
            typography: config.typography,
            showsSpeakerBadges: config.showsSpeakerBadges,
            badgeHeight: config.badgeHeight
        )
        if key != layoutKey || document.rows.isEmpty {
            reset()
            layoutKey = key
        }
        guard document.rows.isEmpty == false else {
            return CaptionScreen(lines: [], badges: [], contentTop: 0, hasContentAbove: false)
        }

        let paneOrder = [config.leadingPane, config.trailingPane]
        let columnWidth = columnsWidth(config)
        let isStacked: Bool = {
            if case .stacked = config.arrangement { return true }
            return false
        }()

        // 1. Block layout per row in document order.
        var previousSpeaker: Int? = nil
        var contentBottom: CGFloat = 0
        for (rowIndex, row) in document.rows.enumerated() {
            var state = states[row.id] ?? RowState()
            let texts = CaptionPaneProjection.suppressingDuplicatePanes(
                CaptionPaneProjection.paneTexts(for: row, config: config.panes),
                leadingPane: config.leadingPane
            )

            for pane in paneOrder {
                guard let paneText = texts[pane] else { continue }
                let typography = typography(for: pane, config: config)
                let width = isStacked ? config.width : columnWidth
                if state.panes[pane]?.text != paneText {
                    state.panes[pane] = PaneLayout(
                        text: paneText,
                        ranges: CaptionLineBreaker.lines(
                            paneText.text,
                            font: typography.font,
                            width: width
                        )
                    )
                }
                let lineCount = state.panes[pane]?.ranges.count ?? 0
                if lineCount > (state.reservedLines[pane] ?? 0) {
                    state.reservedLines[pane] = lineCount
                }
            }

            // Badge: speaker index present and different from the row above;
            // once shown, the height is reserved forever.
            let wantsBadge = config.showsSpeakerBadges
                && row.speakerIndex != nil
                && (rowIndex == 0 || row.speakerIndex != previousSpeaker)
            if wantsBadge { state.badgeReserved = true }

            // Block height from reserved line counts.
            let badgeArea = state.badgeReserved ? config.badgeHeight + config.pairSpacing : 0
            let leadingPresent = panePresent(texts[config.leadingPane], reserved: state.reservedLines[config.leadingPane] ?? 0)
            let trailingPresent = panePresent(texts[config.trailingPane], reserved: state.reservedLines[config.trailingPane] ?? 0)
            let leadingHeight = paneHeight(
                reserved: state.reservedLines[config.leadingPane] ?? 0,
                typography: typography(for: config.leadingPane, config: config)
            )
            let trailingHeight = paneHeight(
                reserved: state.reservedLines[config.trailingPane] ?? 0,
                typography: typography(for: config.trailingPane, config: config)
            )
            let bodyHeight: CGFloat
            if isStacked {
                bodyHeight = leadingHeight
                    + (leadingPresent && trailingPresent ? config.pairSpacing + trailingHeight : 0)
            } else {
                bodyHeight = max(leadingHeight, trailingHeight)
            }
            state.height = badgeArea + bodyHeight

            // Absolute content coordinate: the first remaining row keeps the
            // top it was assigned (dropped rows never renumber the rest).
            if rowIndex == 0 {
                if let existing = states[row.id] {
                    state.top = existing.top
                }
            } else {
                state.top = contentBottom + config.rowSpacing
            }
            contentBottom = state.top + state.height

            states[row.id] = state
            previousSpeaker = row.speakerIndex
        }

        // Forget rows that left the document (their geometry is unreachable).
        let liveIDs = Set(document.rows.map(\.id))
        states = states.filter { liveIDs.contains($0.key) }

        let firstRowTop = states[document.rows[0].id]?.top ?? 0
        let firstRowHeight = states[document.rows[0].id]?.height ?? 0

        // 2. Viewport top.
        if pinnedRows > 0 {
            let targetIndex = max(0, document.rows.count - pinnedRows)
            let target = states[document.rows[targetIndex].id]!
            let desired = target.top + target.height - config.height
            let floor = firstRowTop + firstRowHeight - config.height
            top = max(desired, floor)
            wasPinned = true
        } else {
            let followTop: CGFloat
            switch config.anchoring {
            case .bottom:
                followTop = contentBottom - config.height
            case .top:
                followTop = max(contentBottom - config.height, firstRowTop)
            }
            if initialized == false {
                // First frame: bottom anchor pins the content bottom; top
                // anchor fills from the first row's top.
                top = config.anchoring == .top ? firstRowTop : followTop
            } else if wasPinned {
                top = followTop          // resume may move down only here
            } else {
                top = max(top, followTop)
            }
            wasPinned = false
        }
        initialized = true

        // 3. Emit visible lines and badges.
        var lines: [CaptionScreenLine] = []
        var badges: [CaptionScreenBadge] = []
        for row in document.rows {
            guard let state = states[row.id] else { continue }
            let texts = CaptionPaneProjection.suppressingDuplicatePanes(
                CaptionPaneProjection.paneTexts(for: row, config: config.panes),
                leadingPane: config.leadingPane
            )

            let badgeArea = state.badgeReserved ? config.badgeHeight + config.pairSpacing : 0
            if state.badgeReserved, let speaker = row.speakerIndex {
                let badgeY = state.top - top
                if badgeY + config.badgeHeight > 0, badgeY < config.height {
                    badges.append(CaptionScreenBadge(id: row.id, speakerIndex: speaker, y: badgeY))
                }
            }

            // Pane origins within the block.
            let leadingReserved = state.reservedLines[config.leadingPane] ?? 0
            let leadingBlockHeight = paneHeight(
                reserved: leadingReserved,
                typography: typography(for: config.leadingPane, config: config)
            )
            var paneTops: [CaptionPane: CGFloat] = [:]
            if isStacked {
                let leadingPresent = panePresent(texts[config.leadingPane], reserved: leadingReserved)
                let trailingPresent = panePresent(
                    texts[config.trailingPane],
                    reserved: state.reservedLines[config.trailingPane] ?? 0
                )
                paneTops[config.leadingPane] = state.top + badgeArea
                paneTops[config.trailingPane] = state.top + badgeArea + leadingBlockHeight
                    + (leadingPresent && trailingPresent ? config.pairSpacing : 0)
            } else {
                paneTops[config.leadingPane] = state.top + badgeArea
                paneTops[config.trailingPane] = state.top + badgeArea
            }

            for pane in paneOrder {
                guard let layout = state.panes[pane], texts[pane] != nil,
                      let paneTop = paneTops[pane] else { continue }
                let typography = typography(for: pane, config: config)
                let x: CGFloat
                let width: CGFloat
                if isStacked {
                    x = 0
                    width = config.width
                } else {
                    width = columnWidth
                    x = pane == config.leadingPane ? 0 : columnWidth + config.columnSpacing
                }

                var characterOffset = 0
                for (lineIndex, range) in layout.ranges.enumerated() {
                    let lineText = String(layout.text.text[range])
                    let lineLength = lineText.count
                    let lineY = paneTop + typography.lineHeight * CGFloat(lineIndex)
                    if lineY + typography.lineHeight > top, lineY < top + config.height {
                        let stable = min(
                            max(layout.text.stableLength - characterOffset, 0),
                            lineLength
                        )
                        lines.append(
                            CaptionScreenLine(
                                id: .init(row: row.id, pane: pane, index: lineIndex),
                                text: lineText,
                                stableCount: stable,
                                isDraft: layout.text.isDraft,
                                x: x,
                                width: width,
                                y: lineY - top,
                                height: typography.lineHeight,
                                startsRow: lineIndex == 0
                            )
                        )
                    }
                    characterOffset += lineLength
                }
            }
        }

        return CaptionScreen(
            lines: lines,
            badges: badges,
            contentTop: firstRowTop - top,
            hasContentAbove: top > firstRowTop + 0.5
        )
    }

    /// Pin the viewport so the `rows`-th most recent row sits at the bottom of
    /// the viewport. `rows == 0` resumes following.
    mutating func scrollBack(rows: Int) {
        pinnedRows = max(0, rows)
    }

    // MARK: Helpers

    private mutating func reset() {
        states = [:]
        top = 0
        initialized = false
        pinnedRows = 0
        wasPinned = false
    }

    private func columnsWidth(_ config: CaptionViewportConfig) -> CGFloat {
        max(0, (config.width - config.columnSpacing) / 2)
    }

    private func typography(
        for pane: CaptionPane,
        config: CaptionViewportConfig
    ) -> CaptionTypography {
        config.typography[pane] ?? .system(size: 17, weight: .regular)
    }

    private func panePresent(_ text: CaptionPaneText?, reserved: Int) -> Bool {
        guard let text else { return reserved > 0 }
        return text.text.isEmpty == false || reserved > 0
    }

    private func paneHeight(reserved: Int, typography: CaptionTypography) -> CGFloat {
        CGFloat(reserved) * typography.lineHeight
    }
}
