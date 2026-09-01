import AppKit
import Combine
import SwiftUI

@MainActor
final class AudienceDisplayWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let window: AudienceDisplayWindow
    private let presentationState: AudienceDisplayPresentationState
    private var cancellables = Set<AnyCancellable>()
    private var localKeyMonitor: Any?
    private var selectedDisplayID: String?
    private var hidesAfterExitingFullScreen = false
    private var repositionsAfterExitingFullScreen = false
    private var repositionsOnNextShow = false

#if DEBUG
    private var exitFullScreenOverrideForTesting: (() -> Void)?
#endif

    init(model: AppModel) {
        self.model = model
        self.presentationState = AudienceDisplayPresentationState(
            initialOverlayState: model.overlayState
        )
        self.selectedDisplayID = Self.targetDisplaySelection(for: model.overlayStyle)

        let initialScreen = Self.targetScreen(for: model)
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let initialFrame = Self.defaultWindowFrame(for: initialScreen)
        self.window = AudienceDisplayWindow(
            contentRect: NSWindow.contentRect(forFrameRect: initialFrame, styleMask: styleMask),
            styleMask: styleMask,
            backing: .buffered,
            defer: false,
            screen: initialScreen
        )

        super.init()
        configureWindow()
        bindModel()
    }

    deinit {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }
    }

    private func configureWindow() {
        window.delegate = self
        window.title = model.localized(.audienceDisplay)
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = true
        window.level = .normal
        window.collectionBehavior = [.managed, .fullScreenPrimary]
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentMinSize = NSSize(width: 480, height: 270)
        window.sharingType = Self.sharingType(invisibleInRecording: model.overlayStyle.invisibleInRecording)

        let rootView = AudienceDisplayView(
            model: model,
            presentationState: presentationState
        ) { [weak self] in
            self?.handleEscape()
        }
        window.contentView = NSHostingView(rootView: rootView)

        window.onEscapePressed = { [weak self] in
            self?.handleEscape()
        }
    }

    private func bindModel() {
        model.$overlayState
            .sink { [weak self] overlayState in
                self?.presentationState.consume(overlayState)
            }
            .store(in: &cancellables)

        model.$isAudienceDisplayVisible
            .removeDuplicates()
            .sink { [weak self] isVisible in
                guard let self else { return }
                if isVisible {
                    self.showWindow()
                } else {
                    self.hideWindow()
                }
            }
            .store(in: &cancellables)

        model.$overlayStyle
            .sink { [weak self] newStyle in
                guard let self else { return }
                self.window.sharingType = Self.sharingType(invisibleInRecording: newStyle.invisibleInRecording)

                let newDisplayID = Self.targetDisplaySelection(for: newStyle)
                let targetChanged = newDisplayID != self.selectedDisplayID
                self.selectedDisplayID = newDisplayID
                guard targetChanged else { return }

                guard self.model.isAudienceDisplayVisible else {
                    self.repositionsOnNextShow = true
                    return
                }

                if self.presentationState.isFullScreen {
                    self.repositionsAfterExitingFullScreen = true
                } else {
                    self.moveWindowToTargetScreen()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                guard let self, self.model.isAudienceDisplayVisible else { return }
                self.ensureWindowIsVisible()
            }
            .store(in: &cancellables)
    }

    private func showWindow() {
        hidesAfterExitingFullScreen = false
        if repositionsOnNextShow {
            if presentationState.isFullScreen || window.styleMask.contains(.fullScreen) {
                repositionsAfterExitingFullScreen = true
            } else {
                repositionsOnNextShow = false
                moveWindowToTargetScreen()
            }
        } else {
            ensureWindowIsVisible()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installKeyMonitor()
    }

    private func hideWindow() {
        removeKeyMonitor()
        if presentationState.isFullScreen || window.styleMask.contains(.fullScreen) {
            hidesAfterExitingFullScreen = true
            exitFullScreen()
        } else {
            window.orderOut(nil)
        }
    }

    func dismissAudienceDisplay() {
        model.hideAudienceDisplay()
    }

    private func handleEscape() {
        if presentationState.isFullScreen || window.styleMask.contains(.fullScreen) {
            exitFullScreen()
        } else {
            dismissAudienceDisplay()
        }
    }

    private func exitFullScreen() {
#if DEBUG
        if let exitFullScreenOverrideForTesting {
            exitFullScreenOverrideForTesting()
            return
        }
#endif
        window.toggleFullScreen(nil)
    }

    private func moveWindowToTargetScreen() {
        guard presentationState.isFullScreen == false,
              let screen = Self.targetScreen(for: model) else {
            return
        }
        window.setFrame(Self.defaultWindowFrame(for: screen), display: true, animate: false)
    }

    private func ensureWindowIsVisible() {
        guard presentationState.isFullScreen == false else { return }
        let intersectsVisibleScreen = NSScreen.screens.contains { screen in
            screen.visibleFrame.intersects(window.frame)
        }
        if intersectsVisibleScreen == false {
            moveWindowToTargetScreen()
        }
    }

    private func installKeyMonitor() {
        guard localKeyMonitor == nil else { return }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.model.isAudienceDisplayVisible else { return event }
            if event.keyCode == 53 { // Escape
                self.handleEscape()
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismissAudienceDisplay()
        return false
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        presentationState.setFullScreen(true)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        presentationState.setFullScreen(true)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        presentationState.setFullScreen(false)

        if hidesAfterExitingFullScreen {
            hidesAfterExitingFullScreen = false
            if repositionsAfterExitingFullScreen {
                repositionsAfterExitingFullScreen = false
                repositionsOnNextShow = true
            }
            window.orderOut(nil)
            return
        }
        if repositionsAfterExitingFullScreen {
            repositionsAfterExitingFullScreen = false
            repositionsOnNextShow = false
            moveWindowToTargetScreen()
        }
    }

    static func targetScreen(for model: AppModel) -> NSScreen? {
        if let targetDisplayID = targetDisplaySelection(for: model.overlayStyle),
           let matchedScreen = NSScreen.screens.first(where: { $0.displayIDString == targetDisplayID }) {
            return matchedScreen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    static func defaultWindowFrame(for screen: NSScreen?) -> NSRect {
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 960, height: 540)
        let maximumWidth = visibleFrame.width * 0.78
        let maximumHeight = visibleFrame.height * 0.78
        let width = min(1_280, maximumWidth, maximumHeight * (16.0 / 9.0))
        let height = width * (9.0 / 16.0)
        return NSRect(
            x: (visibleFrame.midX - (width / 2)).rounded(),
            y: (visibleFrame.midY - (height / 2)).rounded(),
            width: width.rounded(),
            height: height.rounded()
        )
    }

    private static func targetDisplaySelection(for style: OverlayStyle) -> String? {
        style.audienceTargetDisplayID ?? style.targetDisplayID
    }

    private static func sharingType(invisibleInRecording: Bool) -> NSWindow.SharingType {
        invisibleInRecording ? .none : .readOnly
    }

#if DEBUG
    var isWindowVisibleForTesting: Bool {
        window.isVisible
    }

    var windowSharingTypeForTesting: NSWindow.SharingType {
        window.sharingType
    }

    var windowFrameForTesting: NSRect {
        window.frame
    }

    func setWindowFrameForTesting(_ frame: NSRect) {
        window.setFrame(frame, display: false)
    }

    var windowLevelForTesting: NSWindow.Level {
        window.level
    }

    var windowStyleMaskForTesting: NSWindow.StyleMask {
        window.styleMask
    }

    var windowCollectionBehaviorForTesting: NSWindow.CollectionBehavior {
        window.collectionBehavior
    }

    var windowIsOpaqueForTesting: Bool {
        window.isOpaque
    }

    var windowHasShadowForTesting: Bool {
        window.hasShadow
    }

    var presentationIsFullScreenForTesting: Bool {
        presentationState.isFullScreen
    }

    func setFullScreenStateForTesting(
        _ isFullScreen: Bool,
        onExitFullScreen: (() -> Void)? = nil
    ) {
        presentationState.setFullScreen(isFullScreen)
        exitFullScreenOverrideForTesting = onExitFullScreen
    }

    func completeFullScreenExitForTesting() {
        exitFullScreenOverrideForTesting = nil
        windowDidExitFullScreen(
            Notification(name: NSWindow.didExitFullScreenNotification, object: window)
        )
    }

    func sendEscapeForTesting() {
        window.cancelOperation(nil)
    }

    func performCloseForTesting() {
        window.performClose(nil)
    }
#endif
}

// MARK: - Audience Window

private final class AudienceDisplayWindow: NSWindow {
    var onEscapePressed: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onEscapePressed?()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onEscapePressed?()
    }
}

// MARK: - NSScreen Helper

extension NSScreen {
    var displayIDString: String? {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return screenNumber.stringValue
    }

    var displayName: String {
        let name = localizedName
        if name.isEmpty == false {
            return name
        }
        if self == NSScreen.main {
            return "Main Display"
        }
        return "Display"
    }
}
