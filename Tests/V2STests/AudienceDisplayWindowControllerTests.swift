import AppKit
import XCTest
@testable import v2s

final class AudienceDisplayWindowControllerTests: XCTestCase {
    @MainActor
    func testAudienceDisplayVisibilityLifecycle() {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-audience-display-tests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: SourceCatalogService()
        )
        let controller = AudienceDisplayWindowController(model: model)

        XCTAssertFalse(model.isAudienceDisplayVisible)
        XCTAssertFalse(controller.isWindowVisibleForTesting)

        model.showAudienceDisplay()
        XCTAssertTrue(model.isAudienceDisplayVisible)
        XCTAssertNotNil(model.overlayState)
        XCTAssertTrue(controller.isWindowVisibleForTesting)

        model.hideAudienceDisplay()
        XCTAssertFalse(model.isAudienceDisplayVisible)
        XCTAssertFalse(controller.isWindowVisibleForTesting)
        XCTAssertNil(model.overlayState)
    }

    @MainActor
    func testDismissAudienceDisplaySyncsModel() {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-audience-display-dismiss-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: SourceCatalogService()
        )
        let controller = AudienceDisplayWindowController(model: model)

        model.showAudienceDisplay()
        XCTAssertTrue(model.isAudienceDisplayVisible)
        XCTAssertTrue(controller.isWindowVisibleForTesting)

        controller.dismissAudienceDisplay()
        XCTAssertFalse(model.isAudienceDisplayVisible)
        XCTAssertFalse(controller.isWindowVisibleForTesting)
    }

    @MainActor
    func testRecordingVisibilitySyncsSharingType() {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-audience-display-sharing-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: SourceCatalogService()
        )
        let controller = AudienceDisplayWindowController(model: model)

        XCTAssertEqual(controller.windowSharingTypeForTesting, .readOnly)

        model.updateOverlayStyle { $0.invisibleInRecording = true }
        XCTAssertEqual(controller.windowSharingTypeForTesting, .none)

        model.updateOverlayStyle { $0.invisibleInRecording = false }
        XCTAssertEqual(controller.windowSharingTypeForTesting, .readOnly)
    }

    @MainActor
    func testStopSessionPreservesAudienceDisplayVisible() {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-audience-display-stop-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: SourceCatalogService()
        )
        let controller = AudienceDisplayWindowController(model: model)

        model.showAudienceDisplay()
        XCTAssertTrue(model.isAudienceDisplayVisible)
        XCTAssertTrue(controller.isWindowVisibleForTesting)

        // Stopping captioning clears overlayState (showing presentation black)
        // but keeps the audience window visible so desktop content is not exposed.
        model.stopSession()
        XCTAssertTrue(model.isAudienceDisplayVisible)
        XCTAssertTrue(controller.isWindowVisibleForTesting)
        XCTAssertNil(model.overlayState)

        // Explicit exit dismisses the window
        model.hideAudienceDisplay()
        XCTAssertFalse(model.isAudienceDisplayVisible)
        XCTAssertFalse(controller.isWindowVisibleForTesting)
    }

    @MainActor
    func testTargetScreenResolution() {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-audience-display-screen-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: SourceCatalogService()
        )
        _ = AudienceDisplayWindowController(model: model)

        let defaultScreen = AudienceDisplayWindowController.targetScreen(for: model)
        XCTAssertNotNil(defaultScreen)

        if let firstScreen = NSScreen.screens.first, let displayID = firstScreen.displayIDString {
            model.updateOverlayStyle { $0.audienceTargetDisplayID = displayID }
            let resolvedScreen = AudienceDisplayWindowController.targetScreen(for: model)
            XCTAssertEqual(resolvedScreen?.displayIDString, displayID)
        }
    }

    @MainActor
    func testConcurrentOverlayAndAudienceDisplayToggle() {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-audience-concurrent-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: SourceCatalogService()
        )
        let audienceController = AudienceDisplayWindowController(model: model)
        _ = OverlayWindowController(model: model, showTranscript: {})

        // Show audience display
        model.showAudienceDisplay()
        XCTAssertTrue(model.isAudienceDisplayVisible)
        XCTAssertFalse(model.isOverlayVisible)
        XCTAssertNotNil(model.overlayState)
        XCTAssertTrue(audienceController.isWindowVisibleForTesting)

        // Show presenter overlay as well
        model.showOverlayPreview()
        XCTAssertTrue(model.isAudienceDisplayVisible)
        XCTAssertTrue(model.isOverlayVisible)
        XCTAssertNotNil(model.overlayState)

        // Hide presenter overlay while audience display is still active -> overlayState remains intact
        model.toggleOverlayVisibility()
        XCTAssertFalse(model.isOverlayVisible)
        XCTAssertTrue(model.isAudienceDisplayVisible)
        XCTAssertNotNil(model.overlayState)
        XCTAssertTrue(audienceController.isWindowVisibleForTesting)

        // Hide audience display -> overlayState becomes nil
        model.hideAudienceDisplay()
        XCTAssertFalse(model.isAudienceDisplayVisible)
        XCTAssertNil(model.overlayState)
        XCTAssertFalse(audienceController.isWindowVisibleForTesting)
    }

    @MainActor
    func testAudienceDisplayStartsWindowedAndSupportsNativeFullscreen() {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-audience-windowed-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: SourceCatalogService()
        )
        let controller = AudienceDisplayWindowController(model: model)

        model.showAudienceDisplay()
        guard let targetScreen = AudienceDisplayWindowController.targetScreen(for: model) else {
            XCTFail("Target screen should be available")
            return
        }

        let frame = controller.windowFrameForTesting
        let visibleFrame = targetScreen.visibleFrame
        XCTAssertGreaterThanOrEqual(frame.minX, visibleFrame.minX)
        XCTAssertGreaterThanOrEqual(frame.minY, visibleFrame.minY)
        XCTAssertLessThanOrEqual(frame.maxX, visibleFrame.maxX)
        XCTAssertLessThanOrEqual(frame.maxY, visibleFrame.maxY)
        XCTAssertNotEqual(frame, targetScreen.frame)
        XCTAssertEqual(controller.windowLevelForTesting, .normal)
        XCTAssertTrue(controller.windowStyleMaskForTesting.contains(.titled))
        XCTAssertTrue(controller.windowStyleMaskForTesting.contains(.closable))
        XCTAssertTrue(controller.windowStyleMaskForTesting.contains(.miniaturizable))
        XCTAssertTrue(controller.windowStyleMaskForTesting.contains(.resizable))
        XCTAssertNotEqual(controller.windowStyleMaskForTesting, .borderless)
        XCTAssertTrue(controller.windowCollectionBehaviorForTesting.contains(.fullScreenPrimary))
        XCTAssertTrue(controller.windowIsOpaqueForTesting)
        XCTAssertTrue(controller.windowHasShadowForTesting)
        XCTAssertFalse(controller.presentationIsFullScreenForTesting)
    }

    @MainActor
    func testEscapeFromWindowedAudienceDisplayDismissesWindow() {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-audience-windowed-escape-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: SourceCatalogService()
        )
        let controller = AudienceDisplayWindowController(model: model)

        model.showAudienceDisplay()
        XCTAssertTrue(model.isAudienceDisplayVisible)
        XCTAssertTrue(controller.isWindowVisibleForTesting)

        controller.sendEscapeForTesting()
        XCTAssertFalse(model.isAudienceDisplayVisible)
        XCTAssertFalse(controller.isWindowVisibleForTesting)
    }

    @MainActor
    func testEscapeFromFullscreenAudienceDisplayReturnsToWindowedMode() {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-audience-fullscreen-escape-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: SourceCatalogService()
        )
        let controller = AudienceDisplayWindowController(model: model)
        var exitFullScreenCount = 0

        model.showAudienceDisplay()
        controller.setFullScreenStateForTesting(true) {
            exitFullScreenCount += 1
        }
        controller.sendEscapeForTesting()

        XCTAssertEqual(exitFullScreenCount, 1)
        XCTAssertTrue(model.isAudienceDisplayVisible)
        XCTAssertTrue(controller.isWindowVisibleForTesting)

        controller.setFullScreenStateForTesting(false)
        model.hideAudienceDisplay()
    }

    @MainActor
    func testNativeCloseButtonDismissesAudienceDisplay() {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-audience-window-close-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: SourceCatalogService()
        )
        let controller = AudienceDisplayWindowController(model: model)

        model.showAudienceDisplay()
        controller.performCloseForTesting()

        XCTAssertFalse(model.isAudienceDisplayVisible)
        XCTAssertFalse(controller.isWindowVisibleForTesting)
    }

    @MainActor
    func testAudienceTargetDisplayPreferenceOverOverlayDisplay() {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-audience-target-priority-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: SourceCatalogService()
        )
        _ = AudienceDisplayWindowController(model: model)

        let screens = NSScreen.screens
        guard screens.count >= 1, let firstID = screens.first?.displayIDString else { return }

        // When only targetDisplayID is set, audience display uses it
        model.updateOverlayStyle {
            $0.targetDisplayID = firstID
            $0.audienceTargetDisplayID = nil
        }
        XCTAssertEqual(AudienceDisplayWindowController.targetScreen(for: model)?.displayIDString, firstID)

        // When audienceTargetDisplayID is set to something else, audience display prefers audienceTargetDisplayID
        model.updateOverlayStyle {
            $0.targetDisplayID = "other-display"
            $0.audienceTargetDisplayID = firstID
        }
        XCTAssertEqual(AudienceDisplayWindowController.targetScreen(for: model)?.displayIDString, firstID)
    }

    @MainActor
    func testHiddenTargetDisplayChangeRepositionsOnNextShow() {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-audience-hidden-target-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: SourceCatalogService()
        )
        model.updateOverlayStyle {
            $0.targetDisplayID = nil
            $0.audienceTargetDisplayID = nil
        }
        let controller = AudienceDisplayWindowController(model: model)

        guard let targetScreen = AudienceDisplayWindowController.targetScreen(for: model),
              let targetDisplayID = targetScreen.displayIDString else {
            XCTFail("Target screen should expose a display ID")
            return
        }

        let defaultFrame = AudienceDisplayWindowController.defaultWindowFrame(for: targetScreen)
        let userMovedFrame = defaultFrame.insetBy(dx: 40, dy: 30)
        controller.setWindowFrameForTesting(userMovedFrame)
        model.showAudienceDisplay()
        XCTAssertEqual(
            controller.windowFrameForTesting,
            userMovedFrame,
            "showing without a target change must preserve a user-moved frame"
        )

        model.hideAudienceDisplay()
        let staleFrame = userMovedFrame.offsetBy(dx: 12, dy: 12)
        controller.setWindowFrameForTesting(staleFrame)
        model.updateOverlayStyle {
            $0.audienceTargetDisplayID = targetDisplayID
        }
        XCTAssertFalse(controller.isWindowVisibleForTesting)

        model.showAudienceDisplay()
        XCTAssertEqual(
            controller.windowFrameForTesting,
            defaultFrame,
            "a target display selected while hidden must apply on the next show"
        )
        model.hideAudienceDisplay()
    }

    @MainActor
    func testFullscreenTargetChangeSurvivesHideDuringExit() {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-audience-fullscreen-hidden-target-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: SourceCatalogService()
        )
        model.updateOverlayStyle {
            $0.targetDisplayID = nil
            $0.audienceTargetDisplayID = nil
        }
        let controller = AudienceDisplayWindowController(model: model)

        guard let targetScreen = AudienceDisplayWindowController.targetScreen(for: model),
              let targetDisplayID = targetScreen.displayIDString else {
            XCTFail("Target screen should expose a display ID")
            return
        }

        let defaultFrame = AudienceDisplayWindowController.defaultWindowFrame(for: targetScreen)
        controller.setWindowFrameForTesting(defaultFrame.insetBy(dx: 40, dy: 30))
        model.showAudienceDisplay()
        controller.setFullScreenStateForTesting(true) {}

        model.updateOverlayStyle {
            $0.audienceTargetDisplayID = targetDisplayID
        }
        model.hideAudienceDisplay()
        controller.completeFullScreenExitForTesting()
        XCTAssertFalse(controller.isWindowVisibleForTesting)

        model.showAudienceDisplay()
        XCTAssertEqual(
            controller.windowFrameForTesting,
            defaultFrame,
            "a fullscreen target change must survive hiding during the exit transition"
        )
        model.hideAudienceDisplay()
    }

    func testTranslationHostRoleArbitrationTruthTable() {
        let combinations: [(isOverlayVisible: Bool, isAudienceVisible: Bool, expectedRole: TranslationHostRole)] = [
            (isOverlayVisible: true, isAudienceVisible: false, expectedRole: .presenterOverlay),
            (isOverlayVisible: true, isAudienceVisible: true, expectedRole: .presenterOverlay),
            (isOverlayVisible: false, isAudienceVisible: true, expectedRole: .audienceDisplay),
            (isOverlayVisible: false, isAudienceVisible: false, expectedRole: .presenterOverlay)
        ]

        for combo in combinations {
            let presenterHosts = TranslationHostRole.presenterOverlay.shouldHost(
                isOverlayVisible: combo.isOverlayVisible,
                isAudienceVisible: combo.isAudienceVisible
            )
            let audienceHosts = TranslationHostRole.audienceDisplay.shouldHost(
                isOverlayVisible: combo.isOverlayVisible,
                isAudienceVisible: combo.isAudienceVisible
            )

            let totalActiveHosts = (presenterHosts ? 1 : 0) + (audienceHosts ? 1 : 0)
            XCTAssertEqual(
                totalActiveHosts,
                1,
                "State (overlay: \(combo.isOverlayVisible), audience: \(combo.isAudienceVisible)) must have exactly 1 active host"
            )

            switch combo.expectedRole {
            case .presenterOverlay:
                XCTAssertTrue(presenterHosts, "Presenter should host when overlay: \(combo.isOverlayVisible), audience: \(combo.isAudienceVisible)")
                XCTAssertFalse(audienceHosts, "Audience should not host when overlay: \(combo.isOverlayVisible), audience: \(combo.isAudienceVisible)")
            case .audienceDisplay:
                XCTAssertFalse(presenterHosts, "Presenter should not host when overlay: \(combo.isOverlayVisible), audience: \(combo.isAudienceVisible)")
                XCTAssertTrue(audienceHosts, "Audience should host when overlay: \(combo.isOverlayVisible), audience: \(combo.isAudienceVisible)")
            }
        }
    }
}