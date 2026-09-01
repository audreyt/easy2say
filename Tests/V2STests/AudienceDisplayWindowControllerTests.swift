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

    @MainActor
    func testAudiencePresentationKeepsLatestTwoUtterancesAcrossPauses() {
        let presentationState = AudienceDisplayPresentationState()
        let oldHistoryID = UUID()
        let firstPromotionID = UUID()
        let firstCaptionID = UUID()
        let secondPromotionID = UUID()
        let thirdPromotionID = UUID()

        var twoActiveUtterances = OverlayPreviewState(
            translatedText: "甲",
            sourceText: "A",
            sourceName: "Test"
        )
        twoActiveUtterances.history = [
            OverlayHistoryEntry(
                id: oldHistoryID,
                translatedText: "舊",
                sourceText: "X"
            )
        ]
        twoActiveUtterances.committedPromotionID = firstPromotionID
        twoActiveUtterances.committedCaptionID = firstCaptionID
        twoActiveUtterances.draftPromotionID = secondPromotionID
        twoActiveUtterances.draftSourceText = "B"
        twoActiveUtterances.draftSourceStablePrefixLength = 1
        twoActiveUtterances.draftTranslatedText = "乙"
        twoActiveUtterances.draftTranslatedStablePrefixLength = 1
        twoActiveUtterances.draftTranslationSourceText = "B"
        twoActiveUtterances.draftTranslationPromotionID = secondPromotionID

        presentationState.consume(twoActiveUtterances)
        assertAudienceSources(presentationState, preceding: "A", current: "B")

        var draftExpired = twoActiveUtterances
        draftExpired.draftPromotionID = nil
        draftExpired.draftSourceText = nil
        draftExpired.draftSourceStablePrefixLength = 0
        draftExpired.clearDraftTranslation()
        presentationState.consume(draftExpired)
        assertAudienceSources(
            presentationState,
            preceding: "A",
            current: "B",
            message: "a pause must freeze the newest draft instead of revealing older overlay text"
        )

        var firstArchived = draftExpired
        firstArchived.history.append(
            OverlayHistoryEntry(
                id: firstCaptionID,
                translatedText: "甲",
                sourceText: "A"
            )
        )
        firstArchived.translatedText = ""
        firstArchived.sourceText = ""
        firstArchived.committedPromotionID = nil
        firstArchived.committedCaptionID = nil
        presentationState.consume(firstArchived)
        assertAudienceSources(
            presentationState,
            preceding: "A",
            current: "B",
            message: "archiving A must not resurrect the previously seen X/A pair"
        )

        var thirdUtterance = firstArchived
        thirdUtterance.draftPromotionID = thirdPromotionID
        thirdUtterance.draftSourceText = "C"
        thirdUtterance.draftSourceStablePrefixLength = 1
        thirdUtterance.draftTranslatedText = "丙"
        thirdUtterance.draftTranslatedStablePrefixLength = 1
        thirdUtterance.draftTranslationSourceText = "C"
        thirdUtterance.draftTranslationPromotionID = thirdPromotionID
        presentationState.consume(thirdUtterance)
        assertAudienceSources(
            presentationState,
            preceding: "B",
            current: "C",
            message: "the next utterance must evict only the oldest retained utterance"
        )

        presentationState.consume(firstArchived)
        assertAudienceSources(
            presentationState,
            preceding: "B",
            current: "C",
            message: "the newest pair must remain visible through the next pause"
        )

        presentationState.consume(nil)
        assertAudienceSources(
            presentationState,
            preceding: nil,
            current: nil,
            message: "session teardown must clear the audience projection"
        )
    }

    @MainActor
    func testAudiencePresentationDoesNotDuplicateCommittedRowBeforeHistoryIDArrives() {
        let presentationState = AudienceDisplayPresentationState()
        let priorEntry = OverlayHistoryEntry(
            id: UUID(),
            translatedText: "Previous",
            sourceText: "上一句"
        )
        let livePromotionID = UUID()
        let archivedHistoryID = UUID()

        var liveCommitted = OverlayPreviewState(
            translatedText: "Current provisional translation",
            sourceText: "現在這句",
            sourceName: "Test"
        )
        liveCommitted.history = [priorEntry]
        liveCommitted.committedPromotionID = livePromotionID
        liveCommitted.committedCaptionID = nil
        presentationState.consume(liveCommitted)

        assertAudienceSources(
            presentationState,
            preceding: "上一句",
            current: "現在這句"
        )

        var archived = OverlayPreviewState(
            translatedText: "",
            sourceText: "",
            sourceName: "Test"
        )
        archived.history = [
            priorEntry,
            OverlayHistoryEntry(
                id: archivedHistoryID,
                translatedText: "Current final translation",
                sourceText: "現在這句"
            ),
        ]
        presentationState.consume(archived)

        assertAudienceSources(
            presentationState,
            preceding: "上一句",
            current: "現在這句",
            message: "archiving a committed live row under its first history ID must update it in place"
        )
        XCTAssertEqual(
            presentationState.liveCaptionPresentation.precedingCommittedCaption?.translatedText,
            "Previous"
        )
        XCTAssertEqual(
            presentationState.liveCaptionPresentation.currentCaption?.translatedText,
            "Current final translation"
        )
    }

    @MainActor
    func testAudiencePresentationPromotionArchiveLifecycleMatrixKeepsExactlyTwoPairedUtterances() {
        struct LifecycleCase {
            let name: String
            let phase: OverlayLiveCaptionPresentation.Phase
            let liveSource: String
            let archivedSource: String
            let bindsHistoryBeforeArchive: Bool
        }

        let cases = [
            LifecycleCase(
                name: "tentative exact",
                phase: .tentative,
                liveSource: "你好世界",
                archivedSource: "你好世界",
                bindsHistoryBeforeArchive: false
            ),
            LifecycleCase(
                name: "tentative revised",
                phase: .tentative,
                liveSource: "你好世",
                archivedSource: "你好世界。",
                bindsHistoryBeforeArchive: false
            ),
            LifecycleCase(
                name: "tentative punctuation",
                phase: .tentative,
                liveSource: "Hello world",
                archivedSource: "Hello, world!",
                bindsHistoryBeforeArchive: false
            ),
            LifecycleCase(
                name: "committed exact",
                phase: .committed,
                liveSource: "現在這句",
                archivedSource: "現在這句",
                bindsHistoryBeforeArchive: false
            ),
            LifecycleCase(
                name: "committed revised",
                phase: .committed,
                liveSource: "現在這",
                archivedSource: "現在這句。",
                bindsHistoryBeforeArchive: false
            ),
            LifecycleCase(
                name: "committed punctuation",
                phase: .committed,
                liveSource: "Second line",
                archivedSource: "Second line.",
                bindsHistoryBeforeArchive: false
            ),
            LifecycleCase(
                name: "committed exact already bound",
                phase: .committed,
                liveSource: "Bound line",
                archivedSource: "Bound line",
                bindsHistoryBeforeArchive: true
            ),
            LifecycleCase(
                name: "committed revised already bound",
                phase: .committed,
                liveSource: "Bound revis",
                archivedSource: "Bound revised.",
                bindsHistoryBeforeArchive: true
            ),
        ]

        for testCase in cases {
            let presentationState = AudienceDisplayPresentationState()
            let priorEntry = OverlayHistoryEntry(
                id: UUID(),
                translatedText: "Previous translation",
                sourceText: "Previous source"
            )
            let livePromotionID = UUID()
            let archivedHistoryID = UUID()
            let liveTranslation = "Live translation: \(testCase.name)"

            var live = OverlayPreviewState(
                translatedText: testCase.phase == .committed ? liveTranslation : "",
                sourceText: testCase.phase == .committed ? testCase.liveSource : "",
                sourceName: "Test"
            )
            live.history = [priorEntry]
            if testCase.phase == .tentative {
                live.draftPromotionID = livePromotionID
                live.draftSourceText = testCase.liveSource
                live.draftSourceStablePrefixLength = testCase.liveSource.count
                live.draftTranslatedText = liveTranslation
                live.draftTranslatedStablePrefixLength = liveTranslation.count
                live.draftTranslationSourceText = testCase.liveSource
                live.draftTranslationPromotionID = livePromotionID
            } else {
                live.committedPromotionID = livePromotionID
                live.committedCaptionID = testCase.bindsHistoryBeforeArchive
                    ? archivedHistoryID
                    : nil
            }
            presentationState.consume(live)

            assertAudienceSources(
                presentationState,
                preceding: "Previous source",
                current: testCase.liveSource,
                message: "\(testCase.name): live state"
            )

            var archived = OverlayPreviewState(
                translatedText: "",
                sourceText: "",
                sourceName: "Test"
            )
            archived.history = [
                priorEntry,
                OverlayHistoryEntry(
                    id: archivedHistoryID,
                    translatedText: "",
                    sourceText: testCase.archivedSource
                ),
            ]
            presentationState.consume(archived)

            assertAudienceSources(
                presentationState,
                preceding: "Previous source",
                current: testCase.archivedSource,
                message: "\(testCase.name): archive must replace the live row"
            )
            let expectedArchivedTranslation = testCase.liveSource == testCase.archivedSource
                ? liveTranslation
                : ""
            XCTAssertEqual(
                presentationState.liveCaptionPresentation.currentCaption?.translatedText,
                expectedArchivedTranslation,
                "\(testCase.name): an unchanged source keeps its translation; a revised source drops stale translation"
            )
            XCTAssertEqual(
                presentationState.liveCaptionPresentation.currentCaption?.representedHistoryEntryIDs,
                [archivedHistoryID],
                "\(testCase.name): the retained row must represent exactly the archived utterance"
            )

            let lateTranslation = "Late translation: \(testCase.name)"
            archived.history[1].translatedText = lateTranslation
            presentationState.consume(archived)

            assertAudienceSources(
                presentationState,
                preceding: "Previous source",
                current: testCase.archivedSource,
                message: "\(testCase.name): late translation must not duplicate or reorder the row"
            )
            XCTAssertEqual(
                presentationState.liveCaptionPresentation.currentCaption?.translatedText,
                lateTranslation,
                "\(testCase.name): late translation"
            )
        }
    }

    @MainActor
    func testAudiencePresentationKeepsIndependentUnboundCommitAndArchiveSeparate() {
        let presentationState = AudienceDisplayPresentationState()
        let priorEntry = OverlayHistoryEntry(
            id: UUID(),
            translatedText: "Previous translation",
            sourceText: "Previous source."
        )

        var liveCommitted = OverlayPreviewState(
            translatedText: "Live translation",
            sourceText: "Complete live sentence.",
            sourceName: "Test"
        )
        liveCommitted.history = [priorEntry]
        liveCommitted.committedPromotionID = UUID()
        liveCommitted.committedCaptionID = nil
        presentationState.consume(liveCommitted)

        var independentArchive = OverlayPreviewState(
            translatedText: "",
            sourceText: "",
            sourceName: "Test"
        )
        independentArchive.history = [
            priorEntry,
            OverlayHistoryEntry(
                id: UUID(),
                translatedText: "Independent translation",
                sourceText: "Independent archived sentence."
            ),
        ]
        presentationState.consume(independentArchive)

        assertAudienceSources(
            presentationState,
            preceding: "Complete live sentence.",
            current: "Independent archived sentence.",
            message: "an unrelated archive must not be folded into the newest unbound live row"
        )
        XCTAssertEqual(
            presentationState.liveCaptionPresentation.precedingCommittedCaption?.translatedText,
            "Live translation"
        )
        XCTAssertEqual(
            presentationState.liveCaptionPresentation.currentCaption?.translatedText,
            "Independent translation"
        )
    }

    @MainActor
    func testAudiencePresentationReconcilesRevisedTentativeIntoFinalArchive() {
        let presentationState = AudienceDisplayPresentationState()
        let priorHistoryID = UUID()
        let draftPromotionID = UUID()
        let finalHistoryID = UUID()
        let priorEntry = OverlayHistoryEntry(
            id: priorHistoryID,
            translatedText: "甲",
            sourceText: "A"
        )

        var tentative = OverlayPreviewState(
            translatedText: "",
            sourceText: "",
            sourceName: "Test"
        )
        tentative.history = [priorEntry]
        tentative.draftPromotionID = draftPromotionID
        tentative.draftSourceText = "Hello worl"
        tentative.draftSourceStablePrefixLength = 10
        tentative.draftTranslatedText = "你好世"
        tentative.draftTranslatedStablePrefixLength = 3
        tentative.draftTranslationSourceText = "Hello worl"
        tentative.draftTranslationPromotionID = draftPromotionID
        presentationState.consume(tentative)

        assertAudienceSources(
            presentationState,
            preceding: "A",
            current: "Hello worl"
        )

        var archived = OverlayPreviewState(
            translatedText: "",
            sourceText: "",
            sourceName: "Test"
        )
        archived.history = [
            priorEntry,
            OverlayHistoryEntry(
                id: finalHistoryID,
                translatedText: "你好世界",
                sourceText: "Hello world."
            ),
        ]
        presentationState.consume(archived)

        assertAudienceSources(
            presentationState,
            preceding: "A",
            current: "Hello world.",
            message: "a revised final must replace its tentative row without evicting the prior utterance"
        )
        XCTAssertEqual(
            presentationState.liveCaptionPresentation.currentCaption?.translatedText,
            "你好世界"
        )
        XCTAssertEqual(
            presentationState.liveCaptionPresentation.currentCaption?.phase,
            .committed
        )
    }

    @MainActor
    func testAudiencePresentationReconcilesArchiveAndLateTranslation() {
        let presentationState = AudienceDisplayPresentationState()
        let promotionID = UUID()
        let historyID = UUID()

        var tentative = OverlayPreviewState(
            translatedText: "",
            sourceText: "",
            sourceName: "Test"
        )
        tentative.draftPromotionID = promotionID
        tentative.draftSourceText = "Hello"
        tentative.draftSourceStablePrefixLength = 5
        tentative.draftTranslatedText = "你好"
        tentative.draftTranslatedStablePrefixLength = 2
        tentative.draftTranslationSourceText = "Hello"
        tentative.draftTranslationPromotionID = promotionID
        presentationState.consume(tentative)

        var archived = OverlayPreviewState(
            translatedText: "",
            sourceText: "",
            sourceName: "Test"
        )
        archived.history = [
            OverlayHistoryEntry(
                id: historyID,
                translatedText: "",
                sourceText: "Hello"
            )
        ]
        presentationState.consume(archived)
        XCTAssertNil(presentationState.liveCaptionPresentation.precedingCommittedCaption)
        XCTAssertEqual(
            presentationState.liveCaptionPresentation.currentCaption?.sourceText,
            "Hello"
        )
        XCTAssertEqual(
            presentationState.liveCaptionPresentation.currentCaption?.translatedText,
            "你好",
            "an archive lane clear must not blank a translation for unchanged source text"
        )

        archived.history[0].translatedText = "您好"
        presentationState.consume(archived)
        XCTAssertNil(presentationState.liveCaptionPresentation.precedingCommittedCaption)
        XCTAssertEqual(
            presentationState.liveCaptionPresentation.currentCaption?.translatedText,
            "您好",
            "a late archived translation must update the retained utterance without duplicating it"
        )

        archived.history[0].sourceText = "Hello everyone"
        archived.history[0].translatedText = ""
        presentationState.consume(archived)
        XCTAssertEqual(
            presentationState.liveCaptionPresentation.currentCaption?.sourceText,
            "Hello everyone"
        )
        XCTAssertEqual(
            presentationState.liveCaptionPresentation.currentCaption?.translatedText,
            "",
            "a source revision must blank translation text that belongs to the older source"
        )

        archived.history[0].translatedText = "大家好"
        presentationState.consume(archived)
        XCTAssertEqual(
            presentationState.liveCaptionPresentation.currentCaption?.translatedText,
            "大家好"
        )
        XCTAssertNil(
            presentationState.liveCaptionPresentation.precedingCommittedCaption,
            "promotion and archive identities must remain one semantic utterance"
        )
    }

    @MainActor
    func testAudiencePresentationRejectsOlderArchiveAfterLiveRowDisappears() {
        let presentationState = AudienceDisplayPresentationState()
        let olderHistoryID = UUID()
        let currentPromotionID = UUID()
        let currentHistoryID = UUID()

        var live = OverlayPreviewState(
            translatedText: "世界您好",
            sourceText: "Hello world",
            sourceName: "Test"
        )
        live.history = [
            OverlayHistoryEntry(
                id: olderHistoryID,
                translatedText: "甲",
                sourceText: "A"
            )
        ]
        live.committedPromotionID = currentPromotionID
        live.committedCaptionID = currentHistoryID
        presentationState.consume(live)
        assertAudienceSources(
            presentationState,
            preceding: "A",
            current: "Hello world"
        )

        var noLiveRow = OverlayPreviewState(
            translatedText: "",
            sourceText: "",
            sourceName: "Test"
        )
        noLiveRow.history = [
            live.history[0],
            OverlayHistoryEntry(
                id: currentHistoryID,
                translatedText: "你好",
                sourceText: "Hello"
            )
        ]
        presentationState.consume(noLiveRow)
        assertAudienceSources(
            presentationState,
            preceding: "A",
            current: "Hello world",
            message: "an older archive revision must not rewind the retained live utterance"
        )
        XCTAssertEqual(
            presentationState.liveCaptionPresentation.currentCaption?.translatedText,
            "世界您好",
            "translation from the older source revision must not replace the retained translation"
        )

        noLiveRow.history[1].sourceText = "Hello world"
        noLiveRow.history[1].translatedText = "大家好"
        presentationState.consume(noLiveRow)
        XCTAssertEqual(
            presentationState.liveCaptionPresentation.currentCaption?.translatedText,
            "大家好",
            "the matching archived source may still deliver its late translation"
        )
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

    @MainActor
    private func assertAudienceSources(
        _ presentationState: AudienceDisplayPresentationState,
        preceding: String?,
        current: String?,
        message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            presentationState.liveCaptionPresentation.precedingCommittedCaption?.sourceText,
            preceding,
            message,
            file: file,
            line: line
        )
        XCTAssertEqual(
            presentationState.liveCaptionPresentation.currentCaption?.sourceText,
            current,
            message,
            file: file,
            line: line
        )
    }

}
