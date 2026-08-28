import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let openAdvancedSettings: () -> Void
    private let showTranscript: () -> Void
    private let quitApp: () -> Void
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let outsideClickMonitor = PopoverOutsideClickMonitor()
    private var cancellables = Set<AnyCancellable>()

    init(
        model: AppModel,
        openAdvancedSettings: @escaping () -> Void,
        showTranscript: @escaping () -> Void,
        quitApp: @escaping () -> Void
    ) {
        self.model = model
        self.openAdvancedSettings = openAdvancedSettings
        self.showTranscript = showTranscript
        self.quitApp = quitApp
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureStatusItem()
        configurePopover()
        bindModel()
        updateStatusIcon(for: model.sessionState)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }

        button.action = #selector(togglePopover(_:))
        button.target = self
        button.imagePosition = .imageOnly
        button.toolTip = "Easy2Say"
    }

    private func configurePopover() {
        popover.delegate = self
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 340, height: 500)
        applySystemAppearance()
    }

    /// Pins the popover to the system light/dark appearance.
    ///
    /// Left unset, the popover's glass backdrop derives its appearance from
    /// whatever sits behind it, so a bright wallpaper makes the content draw in
    /// light mode while the system is in dark mode.
    private func applySystemAppearance() {
        popover.appearance = NSApp.effectiveAppearance
    }

    private func bindModel() {
        Publishers.CombineLatest(model.$sessionState, model.$interfaceLanguageID)
            .sink { [weak self] state, _ in
                self?.updateStatusIcon(for: state)
            }
            .store(in: &cancellables)
    }

    /// The menu-bar glyph is the brand mark itself, not an SF bubble, so the tray,
    /// the Dock icon and the in-app marks are one drawing. Each state remains a
    /// system-tinted template for contrast: live adds a round badge and error adds
    /// a diamond badge without changing the underlying bubble.
    private func updateStatusIcon(for state: SessionState) {
        guard let button = statusItem.button else { return }
        let stateDescription = state.displayName(in: model.resolvedInterfaceLanguageID)
        let description = "Easy2Say — \(stateDescription)"

        button.image = Self.statusGlyph(for: state)
        button.contentTintColor = nil
        button.toolTip = description
        button.setAccessibilityLabel(description)
    }

    private enum StatusBadge {
        case none
        case live
        case error
    }

    private static func statusGlyph(for state: SessionState) -> NSImage {
        switch state {
        case .idle:
            return idleStatusGlyph
        case .running:
            return liveStatusGlyph
        case .error:
            return errorStatusGlyph
        }
    }

    private static let idleStatusGlyph = makeStatusGlyph(badge: .none)
    private static let liveStatusGlyph = makeStatusGlyph(badge: .live)
    private static let errorStatusGlyph = makeStatusGlyph(badge: .error)

    private static func makeStatusGlyph(badge: StatusBadge) -> NSImage {
        let mark = Easy2sayMark()
        let height: CGFloat = 19
        let size = NSSize(width: (height * mark.aspectRatio).rounded(), height: height)

        let image = NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(.black)
            context.addPath(mark.path(in: rect).cgPath)
            context.fillPath()

            switch badge {
            case .none:
                break
            case .live:
                context.fillEllipse(
                    in: CGRect(x: rect.maxX - 4.5, y: 0.5, width: 4, height: 4)
                )
            case .error:
                let badgeRect = CGRect(x: rect.maxX - 4.8, y: 0.4, width: 4.2, height: 4.2)
                context.saveGState()
                context.translateBy(x: badgeRect.midX, y: badgeRect.midY)
                context.rotate(by: .pi / 4)
                context.fill(
                    CGRect(
                        x: -badgeRect.width / 2,
                        y: -badgeRect.height / 2,
                        width: badgeRect.width,
                        height: badgeRect.height
                    )
                )
                context.restoreGState()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Easy2Say status icon"
        return image
    }

    /// Screen rect of the status bar button, for animation targeting.
    var statusItemScreenRect: NSRect? {
        guard let button = statusItem.button,
              let window = button.window else { return nil }
        let rect = button.convert(button.bounds, to: nil)
        return window.convertToScreen(rect)
    }

    @objc
    private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else {
            return
        }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            model.refreshSources()
            applySystemAppearance()
            popover.contentViewController = NSHostingController(
                rootView: StatusBarPopoverView(
                    model: model,
                    closePopover: { [weak self] in
                        self?.popover.performClose(nil)
                    },
                    openAdvancedSettings: { [weak self] in
                        self?.popover.performClose(nil)
                        self?.openAdvancedSettings()
                    },
                    showTranscript: { [weak self] in
                        self?.popover.performClose(nil)
                        self?.showTranscript()
                    },
                    quitApp: { [weak self] in
                        self?.popover.performClose(nil)
                        self?.quitApp()
                    }
                )
            )
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func popoverWillShow(_ notification: Notification) {
        outsideClickMonitor.start(
            shouldIgnoreClick: { [weak self] screenPoint in
                self?.clickShouldKeepPopoverOpen(at: screenPoint) ?? true
            },
            onOutsideClick: { [weak self] in
                guard let self, self.popover.isShown else {
                    return
                }

                self.popover.performClose(nil)
            }
        )
    }

    func popoverDidClose(_ notification: Notification) {
        outsideClickMonitor.stop()
        popover.contentViewController = nil
    }

    private func clickShouldKeepPopoverOpen(at screenPoint: NSPoint) -> Bool {
        statusItemScreenRect?.contains(screenPoint) == true
            || popover.contentViewController?.view.window?.frame.contains(screenPoint) == true
    }
}
