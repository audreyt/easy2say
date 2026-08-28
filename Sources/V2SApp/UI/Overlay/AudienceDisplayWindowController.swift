import AppKit
import Combine
import SwiftUI

@MainActor
final class AudienceDisplayWindowController {
    private let model: AppModel
    private let window: AudienceDisplayWindow
    private var cancellables = Set<AnyCancellable>()
    private var localKeyMonitor: Any?

    init(model: AppModel) {
        self.model = model
        let initialScreen = Self.targetScreen(for: model)
        let initialFrame = initialScreen?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        self.window = AudienceDisplayWindow(
            contentRect: initialFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: initialScreen
        )

        configureWindow()
        bindModel()
    }

    deinit {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }
    }

    private func configureWindow() {
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.level = .screenSaver
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.sharingType = Self.sharingType(invisibleInRecording: model.overlayStyle.invisibleInRecording)

        let rootView = AudienceDisplayView(model: model) { [weak self] in
            self?.dismissAudienceDisplay()
        }
        window.contentView = NSHostingView(rootView: rootView)

        window.onEscapePressed = { [weak self] in
            self?.dismissAudienceDisplay()
        }
    }

    private func bindModel() {
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
                if self.model.isAudienceDisplayVisible {
                    self.syncWindowPosition()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                guard let self, self.model.isAudienceDisplayVisible else { return }
                self.syncWindowPosition()
            }
            .store(in: &cancellables)
    }

    private func showWindow() {
        syncWindowPosition()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installKeyMonitor()
    }

    private func hideWindow() {
        removeKeyMonitor()
        window.orderOut(nil)
    }

    func dismissAudienceDisplay() {
        model.hideAudienceDisplay()
    }

    private func syncWindowPosition() {
        guard let screen = Self.targetScreen(for: model) else { return }
        window.setFrame(screen.frame, display: true, animate: false)
    }

    private func installKeyMonitor() {
        guard localKeyMonitor == nil else { return }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.model.isAudienceDisplayVisible else { return event }
            if event.keyCode == 53 { // Escape
                self.dismissAudienceDisplay()
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

    static func targetScreen(for model: AppModel) -> NSScreen? {
        if let targetDisplayID = model.overlayStyle.audienceTargetDisplayID ?? model.overlayStyle.targetDisplayID,
           let matchedScreen = NSScreen.screens.first(where: { $0.displayIDString == targetDisplayID }) {
            return matchedScreen
        }
        return NSScreen.main ?? NSScreen.screens.first
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

    var windowLevelForTesting: NSWindow.Level {
        window.level
    }

    var windowStyleMaskForTesting: NSWindow.StyleMask {
        window.styleMask
    }

    var windowIsOpaqueForTesting: Bool {
        window.isOpaque
    }

    func sendEscapeForTesting() {
        window.cancelOperation(nil)
    }
#endif
}

// MARK: - Custom Fullscreen Window

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
