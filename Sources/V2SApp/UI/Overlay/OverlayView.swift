import AppKit
import SwiftUI

enum OverlayPanelMetrics {
    static let cornerRadius: CGFloat = 16
}

struct OverlayView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var interactionState: OverlayInteractionState
    @State private var renderedPassThroughBubble: OverlayPassThroughBubble?
    @State private var passThroughRevealProgress: Double = 0.0

    var body: some View {
        ZStack {
            subtitleContent
                .mask(passThroughMask)

            passThroughBubble
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            syncPassThroughBubble(interactionState.passThroughBubble)
        }
        .onChange(of: interactionState.passThroughBubble) { _, bubble in
            syncPassThroughBubble(bubble)
        }
        .modifier(OverlayTranslationHostModifier(model: model, role: .presenterOverlay))
    }

    @ViewBuilder
    private var subtitleContent: some View {
        CaptionFlowContentView(
            model: model,
            showsScrollbarPadding: true,
            updatesModelHistoryVisibleCount: true
        )
        .background(backgroundView)
        .overlay(
            RoundedRectangle(cornerRadius: OverlayPanelMetrics.cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .padding(.horizontal, OverlayControlsLayout.outerPadding)
        .padding(.vertical, OverlayControlsLayout.outerPadding)
    }

    private var backgroundView: some View {
        RoundedRectangle(cornerRadius: OverlayPanelMetrics.cornerRadius, style: .continuous)
            .fill(model.overlayStyle.backgroundColor.color.opacity(model.overlayStyle.backgroundOpacity))
    }

    @ViewBuilder
    private var passThroughBubble: some View {
        if let hint = renderedPassThroughBubble {
            OverlayPassThroughBubbleView()
                .frame(width: hint.diameter, height: hint.diameter)
                .position(x: hint.center.x, y: hint.center.y)
                .scaleEffect(0.92 + (0.08 * passThroughRevealProgress))
                .opacity(passThroughRevealProgress)
                .allowsHitTesting(false)
        }
    }

    private var passThroughMask: some View {
        Rectangle()
            .fill(Color.white)
            .overlay {
                if let hint = renderedPassThroughBubble {
                    Circle()
                        .fill(
                            RadialGradient(
                                stops: [
                                    .init(color: .black, location: 0.0),
                                    .init(color: .black, location: 0.38),
                                    .init(color: .black.opacity(0.68), location: 0.58),
                                    .init(color: .black.opacity(0.28), location: 0.76),
                                    .init(color: .clear, location: 1.0)
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: hint.diameter * 0.5
                            )
                        )
                        .frame(width: hint.diameter, height: hint.diameter)
                        .position(x: hint.center.x, y: hint.center.y)
                        .scaleEffect(0.92 + (0.08 * passThroughRevealProgress))
                        .opacity(passThroughRevealProgress)
                        .blendMode(.destinationOut)
                }
            }
            .compositingGroup()
    }

    private func syncPassThroughBubble(_ bubble: OverlayPassThroughBubble?) {
        if let bubble {
            renderedPassThroughBubble = bubble

            guard passThroughRevealProgress < 1.0 else { return }
            withAnimation(Self.passThroughTransitionAnimation) {
                passThroughRevealProgress = 1.0
            }
            return
        }

        guard renderedPassThroughBubble != nil else { return }
        withAnimation(Self.passThroughTransitionAnimation) {
            passThroughRevealProgress = 0.0
        }
    }
}


struct OverlayControlsChromeView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: OverlayPanelMetrics.cornerRadius, style: .continuous)
            .fill(Color.black.opacity(0.28))
            .overlay(
                RoundedRectangle(cornerRadius: OverlayPanelMetrics.cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            )
            .frame(width: OverlayControlsLayout.stripSize.width, height: OverlayControlsLayout.stripSize.height)
    }
}

struct OverlayMoveButtonView: View {
    let onMoveDragStart: () -> Void
    let onMoveDragChanged: (CGSize) -> Void
    let onMoveDragEnded: () -> Void

    @State private var isMoveDragging = false

    var body: some View {
        OverlayDragHandle(
            onDragStart: {
                isMoveDragging = true
                onMoveDragStart()
            },
            onDragChanged: { translation in
                onMoveDragChanged(translation)
            },
            onDragEnded: {
                if isMoveDragging {
                    onMoveDragEnded()
                }
                isMoveDragging = false
            }
        )
        .frame(width: OverlayControlsLayout.controlSize, height: OverlayControlsLayout.controlSize)
        .background(Circle().fill(Color.white.opacity(0.12)))
        .overlay(
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.white.opacity(0.65))
                .allowsHitTesting(false)
        )
    }
}

struct OverlayCloseButtonView: View {
    @ObservedObject var model: AppModel
    var onClose: () -> Void = {}

    var body: some View {
        Button { onClose() } label: {
            ZStack {
                Circle().fill(Color.white.opacity(0.12))
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.65))
            }
        }
        .buttonStyle(.plain)
        .frame(width: OverlayControlsLayout.controlSize, height: OverlayControlsLayout.controlSize)
    }
}

struct OverlayResizeButtonView: View {
    let onResizeDragStart: () -> Void
    let onResizeDragChanged: (CGSize) -> Void
    let onResizeDragEnded: () -> Void

    var body: some View {
        OverlayDragHandle(
            onDragStart: onResizeDragStart,
            onDragChanged: onResizeDragChanged,
            onDragEnded: onResizeDragEnded
        )
        .frame(width: OverlayControlsLayout.controlSize, height: OverlayControlsLayout.controlSize)
        .background(Circle().fill(Color.white.opacity(0.12)))
        .overlay(
            OverlayResizeGlyph()
                .frame(width: 10, height: 10)
                .allowsHitTesting(false)
        )
    }
}

struct OverlayResetSizeButtonView: View {
    @ObservedObject var model: AppModel
    let onReset: () -> Void

    var body: some View {
        Button { onReset() } label: {
            ZStack {
                Circle().fill(Color.white.opacity(0.12))
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.65))
            }
        }
        .buttonStyle(.plain)
        .frame(width: OverlayControlsLayout.controlSize, height: OverlayControlsLayout.controlSize)
        .accessibilityLabel(model.localized(.resetOverlaySize))
    }
}

struct OverlayHistoryScrollbarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var interactionState: OverlayInteractionState
    var showTranscript: () -> Void = {}

    var body: some View {
        let revealProgress = interactionState.scrollbarRevealProgress
        let latestButtonRevealProgress = latestButtonRevealProgress(for: revealProgress)

        VStack(spacing: 0) {
            transcriptButton(revealProgress: revealProgress)
                .padding(.top, OverlayHistoryScrollbarLayout.verticalPadding)
                .padding(.bottom, OverlayHistoryScrollbarLayout.buttonSpacing)

            GeometryReader { proxy in
                let trackHeight = resolvedTrackHeight(
                    in: proxy.size.height,
                    latestButtonRevealProgress: latestButtonRevealProgress
                )
                let metrics = scrollbarMetrics(trackHeight: trackHeight)
                let trackWidth = resolvedTrackWidth(for: revealProgress)

                ZStack(alignment: .bottom) {
                    ZStack(alignment: .top) {
                        Capsule()
                            .fill(Color.white.opacity(0.035 + (0.055 * revealProgress)))
                            .frame(width: trackWidth)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                        Capsule()
                            .fill(
                                Color.white.opacity(
                                    metrics.canScroll
                                        ? (0.28 + (0.32 * revealProgress))
                                        : (0.12 + (0.10 * revealProgress))
                                )
                            )
                            .frame(
                                width: trackWidth,
                                height: metrics.thumbHeight
                            )
                            .frame(maxWidth: .infinity, alignment: .top)
                            .offset(y: metrics.thumbTop)

                        OverlayHistoryScrollbarInputLayer(
                            currentOffset: model.overlayHistoryScrollOffset,
                            maxScrollOffset: metrics.maxScrollOffset,
                            thumbHeight: metrics.thumbHeight,
                            onOffsetChange: { model.setOverlayHistoryScrollOffset($0) },
                            onStepScroll: { model.scrollOverlayHistory(by: $0) }
                        )
                    }
                    .frame(height: trackHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                    latestButton(revealProgress: latestButtonRevealProgress)
                }
                .animation(.easeOut(duration: 0.16), value: revealProgress)
                .animation(.easeOut(duration: 0.18), value: latestButtonRevealProgress)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, OverlayHistoryScrollbarLayout.verticalPadding)
        }
    }

    private func scrollbarMetrics(trackHeight: CGFloat) -> OverlayHistoryScrollbarMetrics {
        let totalCount = max(model.overlayState?.history.count ?? 0, 0)
        let visibleCount = max(0, model.overlayHistoryVisibleCount)
        let maxScrollOffset = max(0, totalCount - visibleCount)
        let clampedTrackHeight = max(trackHeight, OverlayHistoryScrollbarLayout.minimumThumbHeight)
        let visibilityRatio = totalCount > 0
            ? min(1.0, CGFloat(visibleCount) / CGFloat(max(totalCount, max(visibleCount, 1))))
            : 1.0
        let thumbHeight = max(
            OverlayHistoryScrollbarLayout.minimumThumbHeight,
            clampedTrackHeight * visibilityRatio
        )
        let travel = max(clampedTrackHeight - thumbHeight, 0)
        let progressFromTop: CGFloat

        if maxScrollOffset > 0 {
            progressFromTop = 1.0 - (CGFloat(model.overlayHistoryScrollOffset) / CGFloat(maxScrollOffset))
        } else {
            progressFromTop = 1.0
        }

        return OverlayHistoryScrollbarMetrics(
            maxScrollOffset: maxScrollOffset,
            thumbHeight: min(thumbHeight, clampedTrackHeight),
            thumbTop: travel * progressFromTop,
            canScroll: maxScrollOffset > 0
        )
    }

    private func resolvedTrackWidth(for revealProgress: CGFloat) -> CGFloat {
        OverlayHistoryScrollbarLayout.trackWidth
            + ((OverlayHistoryScrollbarLayout.expandedTrackWidth - OverlayHistoryScrollbarLayout.trackWidth) * revealProgress)
    }

    private func resolvedTrackHeight(in totalHeight: CGFloat, latestButtonRevealProgress: CGFloat) -> CGFloat {
        let reservedHeight = latestButtonReservedHeight(for: latestButtonRevealProgress)
        return max(totalHeight - reservedHeight, OverlayHistoryScrollbarLayout.minimumThumbHeight)
    }

    private func latestButtonReservedHeight(for revealProgress: CGFloat) -> CGFloat {
        let fullHeight = OverlayControlsLayout.controlSize + OverlayHistoryScrollbarLayout.buttonSpacing
        return fullHeight * revealProgress
    }

    private func latestButtonRevealProgress(for revealProgress: CGFloat) -> CGFloat {
        guard model.overlayHistoryScrollOffset > 0 else { return 0.0 }
        return revealProgress
    }

    private func latestButton(revealProgress: CGFloat) -> some View {
        Button {
            model.setOverlayHistoryScrollOffset(0)
        } label: {
            ZStack {
                Circle().fill(Color.white.opacity(0.12))
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.65))
            }
        }
        .buttonStyle(.plain)
        .frame(width: OverlayControlsLayout.controlSize, height: OverlayControlsLayout.controlSize)
        .opacity(revealProgress)
        .scaleEffect(0.9 + (0.1 * revealProgress))
        .allowsHitTesting(revealProgress > 0.05)
        .animation(.easeOut(duration: 0.16), value: revealProgress)
        .accessibilityLabel(model.localized(.scrollToLatestSubtitle))
    }

    private func transcriptButton(revealProgress: CGFloat) -> some View {
        Button {
            showTranscript()
        } label: {
            ZStack {
                Circle().fill(Color.white.opacity(0.12))
                Image(systemName: "doc.text")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.65))
            }
        }
        .buttonStyle(.plain)
        .frame(width: OverlayControlsLayout.controlSize, height: OverlayControlsLayout.controlSize)
        .opacity(revealProgress)
        .scaleEffect(0.9 + (0.1 * revealProgress))
        .allowsHitTesting(revealProgress > 0.05)
        .animation(.easeOut(duration: 0.16), value: revealProgress)
        .accessibilityLabel(model.localized(.transcript))
    }
}

enum OverlayControlsLayout {
    static let outerPadding: CGFloat = 4
    static let leadingInset: CGFloat = 10
    static let controlPaddingX: CGFloat = 5
    static let controlPaddingY: CGFloat = 7
    static let controlSize: CGFloat = 22
    static let controlSpacing: CGFloat = 6

    static let controlCount = 4

    static var stripSize: CGSize {
        let controlStackHeight = (controlSize * CGFloat(controlCount))
            + (controlSpacing * CGFloat(controlCount - 1))
        return CGSize(
            width: controlSize + (controlPaddingX * 2),
            height: controlStackHeight + (controlPaddingY * 2)
        )
    }

    /// Control panel chrome height (four buttons + vertical padding inside the strip).
    static var controlPanelHeight: CGFloat {
        stripSize.height
    }

    /// Overlay must be at least this tall so the chrome strip (offset by `outerPadding` from the bottom) fits inside.
    static var minimumOverlayHeight: CGFloat {
        controlPanelHeight + (outerPadding * 2)
    }
}

enum OverlayHistoryScrollbarLayout {
    static let panelWidth: CGFloat = 28
    static let trackWidth: CGFloat = 4
    static let expandedTrackWidth: CGFloat = OverlayControlsLayout.controlSize
    static let contentSpacing: CGFloat = 10
    static let verticalPadding: CGFloat = 8
    static let buttonSpacing: CGFloat = 8
    static let minimumThumbHeight: CGFloat = 36

    static var panelSize: CGSize {
        CGSize(width: panelWidth, height: 120)
    }
}

private struct OverlayHistoryScrollbarMetrics {
    var maxScrollOffset: Int
    var thumbHeight: CGFloat
    var thumbTop: CGFloat
    var canScroll: Bool
}

private struct OverlayHistoryScrollbarInputLayer: NSViewRepresentable {
    let currentOffset: Int
    let maxScrollOffset: Int
    let thumbHeight: CGFloat
    let onOffsetChange: (Int) -> Void
    let onStepScroll: (Int) -> Void

    func makeNSView(context: Context) -> OverlayHistoryScrollbarInputView {
        let view = OverlayHistoryScrollbarInputView()
        view.currentOffset = currentOffset
        view.maxScrollOffset = maxScrollOffset
        view.thumbHeight = thumbHeight
        view.onOffsetChange = onOffsetChange
        view.onStepScroll = onStepScroll
        return view
    }

    func updateNSView(_ nsView: OverlayHistoryScrollbarInputView, context: Context) {
        nsView.currentOffset = currentOffset
        nsView.maxScrollOffset = maxScrollOffset
        nsView.thumbHeight = thumbHeight
        nsView.onOffsetChange = onOffsetChange
        nsView.onStepScroll = onStepScroll
    }
}

final class OverlayHistoryScrollbarInputView: NSView {
    var currentOffset = 0
    var maxScrollOffset = 0
    var thumbHeight: CGFloat = OverlayHistoryScrollbarLayout.minimumThumbHeight
    var onOffsetChange: ((Int) -> Void)?
    var onStepScroll: ((Int) -> Void)?

    private var isDraggingThumb = false

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        isDraggingThumb = true
        updateOffset(for: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggingThumb else { return }
        updateOffset(for: event)
    }

    override func mouseUp(with event: NSEvent) {
        if isDraggingThumb {
            updateOffset(for: event)
        }
        isDraggingThumb = false
    }

    override func scrollWheel(with event: NSEvent) {
        guard maxScrollOffset > 0 else { return }

        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }

        let divisor: CGFloat = event.hasPreciseScrollingDeltas ? 12.0 : 1.0
        let magnitude = max(1, Int((abs(delta) / divisor).rounded(.awayFromZero)))
        onStepScroll?(delta > 0 ? magnitude : -magnitude)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func updateOffset(for event: NSEvent) {
        guard maxScrollOffset > 0 else {
            onOffsetChange?(0)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        onOffsetChange?(resolvedOffset(forThumbCenterY: point.y))
    }

    private func resolvedOffset(forThumbCenterY thumbCenterY: CGFloat) -> Int {
        let clampedThumbHeight = min(max(thumbHeight, 0), bounds.height)
        let travel = max(bounds.height - clampedThumbHeight, 0)
        guard travel > 0 else { return 0 }

        let thumbTop = min(max(thumbCenterY - (clampedThumbHeight / 2), 0), travel)
        let progressFromBottom = 1.0 - (thumbTop / travel)
        return Int((progressFromBottom * CGFloat(maxScrollOffset)).rounded())
    }
}

private struct OverlayDragHandle: NSViewRepresentable {
    let onDragStart: () -> Void
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: () -> Void

    func makeNSView(context: Context) -> OverlayDragHandleView {
        let view = OverlayDragHandleView()
        view.onDragStart = onDragStart
        view.onDragChanged = onDragChanged
        view.onDragEnded = onDragEnded
        return view
    }

    func updateNSView(_ nsView: OverlayDragHandleView, context: Context) {
        nsView.onDragStart = onDragStart
        nsView.onDragChanged = onDragChanged
        nsView.onDragEnded = onDragEnded
    }
}

final class OverlayDragHandleView: NSView {
    var onDragStart: (() -> Void)?
    var onDragChanged: ((CGSize) -> Void)?
    var onDragEnded: (() -> Void)?

    private var dragStartPointInScreen: NSPoint?

    override func mouseDown(with event: NSEvent) {
        guard let startPoint = screenPoint(for: event) else { return }
        dragStartPointInScreen = startPoint
        onDragStart?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartPointInScreen,
              let currentPoint = screenPoint(for: event) else {
            return
        }

        onDragChanged?(
            CGSize(
                width: currentPoint.x - dragStartPointInScreen.x,
                height: currentPoint.y - dragStartPointInScreen.y
            )
        )
    }

    override func mouseUp(with event: NSEvent) {
        if dragStartPointInScreen != nil {
            onDragEnded?()
        }
        dragStartPointInScreen = nil
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func screenPoint(for event: NSEvent) -> NSPoint? {
        guard let window else { return nil }
        return window.convertPoint(toScreen: event.locationInWindow)
    }
}

private struct OverlayResizeGlyph: View {
    var body: some View {
        Canvas { context, size in
            let stroke = StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round)
            let color = Color.white.opacity(0.65)
            let start = CGPoint(x: 2, y: size.height - 2)
            let end = CGPoint(x: size.width - 2, y: 2)

            var diagonal = Path()
            diagonal.move(to: start)
            diagonal.addLine(to: end)
            context.stroke(diagonal, with: .color(color), style: stroke)

            var startHead = Path()
            startHead.move(to: start)
            startHead.addLine(to: CGPoint(x: start.x + 2.6, y: start.y))
            startHead.move(to: start)
            startHead.addLine(to: CGPoint(x: start.x, y: start.y - 2.6))
            context.stroke(startHead, with: .color(color), style: stroke)

            var endHead = Path()
            endHead.move(to: end)
            endHead.addLine(to: CGPoint(x: end.x - 2.6, y: end.y))
            endHead.move(to: end)
            endHead.addLine(to: CGPoint(x: end.x, y: end.y + 2.6))
            context.stroke(endHead, with: .color(color), style: stroke)
        }
    }
}

@MainActor
final class OverlayInteractionState: ObservableObject {
    @Published private(set) var passThroughBubble: OverlayPassThroughBubble?
    @Published private(set) var scrollbarRevealProgress: CGFloat = 0.0

    func updatePassThroughBubble(_ bubble: OverlayPassThroughBubble?) {
        guard needsUpdate(from: passThroughBubble, to: bubble) else { return }
        passThroughBubble = bubble
    }

    func updateScrollbarRevealProgress(_ progress: CGFloat) {
        let clampedProgress = min(max(progress, 0.0), 1.0)
        guard abs(scrollbarRevealProgress - clampedProgress) > 0.01 else { return }
        scrollbarRevealProgress = clampedProgress
    }

    private func needsUpdate(from current: OverlayPassThroughBubble?, to next: OverlayPassThroughBubble?) -> Bool {
        switch (current, next) {
        case (nil, nil):
            return false
        case (nil, _), (_, nil):
            return true
        case let (.some(current), .some(next)):
            return abs(current.center.x - next.center.x) > 0.5
                || abs(current.center.y - next.center.y) > 0.5
                || abs(current.diameter - next.diameter) > 0.5
        }
    }
}

struct OverlayPassThroughBubble: Equatable {
    var center: CGPoint
    var diameter: CGFloat
}

private struct OverlayPassThroughBubbleView: View {
    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .clear, location: 0.42),
                        .init(color: Color.black.opacity(0.12), location: 0.68),
                        .init(color: Color.black.opacity(0.07), location: 0.84),
                        .init(color: .clear, location: 1.0)
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: 58
                )
            )
            .blur(radius: 1.6)
    }
}

private extension OverlayView {
    static let passThroughTransitionDuration: Double = 0.18
    static let passThroughTransitionAnimation = Animation.easeOut(duration: passThroughTransitionDuration)
}
