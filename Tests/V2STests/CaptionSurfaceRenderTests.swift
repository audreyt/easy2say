import AppKit
import SwiftUI
import XCTest
@testable import v2s

/// Hosts the real `OverlayView` and `AudienceDisplayView` in off-screen
/// windows, replays the analyzer traces through `CaptionCore`, pushes each
/// document through `setCaptionDocumentForTesting`, and evaluates every
/// screen each surface controller emitted with the caption oracle.
@MainActor
final class CaptionSurfaceRenderTests: XCTestCase {
    func testEnglishNaturalSurfacesStayClean() throws {
        try run(
            "english-natural",
            config: CaptionSessionConfig(
                sessionID: 1, primaryLanguageID: "en", targetLanguageID: "zh-Hant", translates: true
            ),
            inputLanguageID: "en", outputLanguageID: "zh-Hant"
        )
    }

    func testMandarinNaturalSurfacesStayClean() throws {
        try run(
            "mandarin-natural",
            config: CaptionSessionConfig(
                sessionID: 1, primaryLanguageID: "zh-Hant", secondaryLanguageID: "en",
                targetLanguageID: "en", translates: true
            ),
            inputLanguageID: "zh-Hant", outputLanguageID: "en"
        )
    }

    private func run(
        _ traceName: String,
        config: CaptionSessionConfig,
        inputLanguageID: String,
        outputLanguageID: String
    ) throws {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-surface-render-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: SourceCatalogService()
        )
        model.inputLanguageID = inputLanguageID
        model.outputLanguageID = outputLanguageID
        model.subtitleDisplayMode = .both
        model.setOverlayStateForTesting(
            OverlayPreviewState(
                translatedText: "",
                sourceText: "",
                sourceName: "Trace replay"
            )
        )

        let overlayHost = SurfaceHost(
            rootView: AnyView(OverlayView(model: model, interactionState: OverlayInteractionState())),
            size: NSSize(width: 1_100, height: 240)
        )
        let audienceState = AudienceDisplayState()
        let audienceHost = SurfaceHost(
            rootView: AnyView(AudienceDisplayView(model: model, displayState: audienceState) {}),
            size: NSSize(width: 1_280, height: 720)
        )
        // A bare surface at exactly its viewport size, so screen coordinates
        // map 1:1 onto the captured bitmap for the pixel check.
        let bareController = CaptionSurfaceController()
        let bareHost = SurfaceHost(
            rootView: AnyView(
                CaptionSurfaceView(model: model, controller: bareController, role: .overlay)
            ),
            size: NSSize(width: 1_060, height: 190)
        )
        let bareAudienceController = CaptionSurfaceController()
        let bareAudienceHost = SurfaceHost(
            rootView: AnyView(
                CaptionSurfaceView(model: model, controller: bareAudienceController, role: .audience)
            ),
            size: NSSize(width: 1_150, height: 640)
        )
        defer {
            overlayHost.close()
            audienceHost.close()
            bareHost.close()
            bareAudienceHost.close()
        }

        let trace = try AnalyzerTraceFixture.load(traceName, sessionID: config.sessionID)
        try? FileManager.default.createDirectory(
            atPath: Self.shotsDirectory,
            withIntermediateDirectories: true
        )
        let (frames, _) = CaptionTraceReplayDriver.run(trace, config: config)
        XCTAssertFalse(frames.isEmpty)

        var screens: [(name: String, screens: [ObservedScreen])] = [
            ("overlay", []),
            ("audience", []),
        ]

        var sampledOverlayBitmap: NSBitmapImageRep?
        var sampledOverlayScreen: CaptionScreen?
        var sampledAudienceBitmap: NSBitmapImageRep?
        var sampledAudienceScreen: CaptionScreen?
        var overlayScreensSeen = 0

        for frame in frames {
            model.setCaptionDocumentForTesting(frame.document)
            // The standalone bare-surface controllers aren't the model's own —
            // push the same document directly (same-turn semantics live in
            // the controller's cached config).
            bareController.update(document: model.displayedCaptionDocument)
            bareAudienceController.update(document: model.displayedCaptionDocument)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            let time = frame.wallMs / 1_000
            let overlayScreen = model.overlayCaptionSurface.screen
            let audienceScreen = model.audienceCaptionSurface.screen
            screens[0].screens.append(
                ObservedScreen(time: time, panes: Self.panes(of: overlayScreen, prefix: "overlay"))
            )
            screens[1].screens.append(
                ObservedScreen(time: time, panes: Self.panes(of: audienceScreen, prefix: "audience"))
            )
            // Sample a mid-replay frame with real content for the paint check:
            // spin the loop so SwiftUI has painted, then bitmap + screen pair.
            if bareController.screen.lines.count >= 4, sampledOverlayBitmap == nil {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                sampledOverlayBitmap = bareHost.bitmap()
                sampledOverlayScreen = bareController.screen
                saveShot(overlayHost.bitmap(), name: "render-\(traceName)-overlay-mid")
            }
            if bareAudienceController.screen.lines.count >= 4, sampledAudienceBitmap == nil {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                sampledAudienceBitmap = bareAudienceHost.bitmap()
                sampledAudienceScreen = bareAudienceController.screen
                saveShot(audienceHost.bitmap(), name: "render-\(traceName)-audience-mid")
            }
            overlayScreensSeen += 1
        }

        // The controller log is the honest record of what the view drew.
        XCTAssertFalse(model.overlayCaptionSurface.screensForTesting.isEmpty)
        XCTAssertFalse(model.audienceCaptionSurface.screensForTesting.isEmpty)

        for (name, observed) in screens {
            let report = CaptionScreenOracle.evaluate(observed)
            XCTAssertEqual(
                report.violations, [],
                "\(name) violations:\n\(report.violations.map(\.description).joined(separator: "\n"))"
            )
            for (pane, metrics) in report.metrics {
                XCTAssertEqual(metrics.settledReflows, 0, "\(name)/\(pane)")
            }
            print("[surface-render] \(traceName)/\(name):\n\(report.summary)")
        }

        // Real paint check: a sampled frame's accessibility text equals the
        // screen's line texts, and the bitmap has caption ink.
        try assertRendered(
            screen: sampledOverlayScreen,
            bitmap: sampledOverlayBitmap,
            viewportWidth: 1_060,
            viewportHeight: 190,
            label: "overlay"
        )
        try assertRendered(
            screen: sampledAudienceScreen,
            bitmap: sampledAudienceBitmap,
            viewportWidth: 1_150,
            viewportHeight: 640,
            label: "audience"
        )
    }

    static let shotsDirectory = "/tmp/e2s-v2/shots"

    private func saveShot(_ bitmap: NSBitmapImageRep?, name: String) {
        guard let data = bitmap?.representation(using: .png, properties: [:]) else { return }
        try? data.write(
            to: URL(fileURLWithPath: Self.shotsDirectory).appendingPathComponent("\(name).png")
        )
    }

    // MARK: - Conversion + paint checks

    static func panes(of screen: CaptionScreen, prefix: String) -> [String: [ObservedLine]] {
        var panes: [String: [ObservedLine]] = [:]
        for pane in [CaptionPane.original, .translated] {
            panes["\(prefix).\(pane == .original ? "original" : "translated")"] = screen.lines
                .filter { $0.id.pane == pane }
                .sorted { $0.y < $1.y }
                .map {
                    ObservedLine(
                        $0.text,
                        stable: $0.isDraft ? 0 : $0.stableCount,
                        startsRow: $0.startsRow
                    )
                }
        }
        return panes
    }

    /// The rendered-check: every line the screen emits is in the view's
    /// accessibility tree, and the bitmap carries caption ink.
    private func assertRendered(
        screen: CaptionScreen?,
        bitmap: NSBitmapImageRep?,
        viewportWidth: CGFloat,
        viewportHeight: CGFloat,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let screen = try XCTUnwrap(screen, "\(label): no frame sampled", file: file, line: line)
        let bitmap = try XCTUnwrap(bitmap, "\(label): no bitmap sampled", file: file, line: line)

        // Real paint check: every emitted line leaves bright pixels inside its
        // laid-out band. `cacheDisplay` bitmaps are stored top-down here, so
        // pixel y = screen y × backing scale; the fade mask dims the top of
        // the viewport, so the threshold is low.
        let scale = CGFloat(bitmap.pixelsWide) / viewportWidth
        func bandHasInk(_ emitted: CaptionScreenLine) -> Bool {
            let top = Int(emitted.y * scale)
            let bottom = Int((emitted.y + emitted.height) * scale)
            let left = Int(emitted.x * scale), right = Int((emitted.x + emitted.width) * scale)
            for py in stride(from: max(top, 0), to: min(bottom, bitmap.pixelsHigh), by: 1) {
                for px in stride(from: max(left, 0), to: min(right, bitmap.pixelsWide), by: 2) {
                    if let color = bitmap.colorAt(x: px, y: py),
                       max(color.redComponent, color.greenComponent, color.blueComponent) > 0.07 {
                        return true
                    }
                }
            }
            return false
        }
        for emitted in screen.lines
        where emitted.text.isEmpty == false
            && emitted.y + emitted.height > 0 && emitted.y < viewportHeight {
            XCTAssertTrue(
                bandHasInk(emitted),
                "\(label): no ink at line band (\(emitted.x),\(emitted.y),\(emitted.width)x\(emitted.height)): \(emitted.text)",
                file: file, line: line
            )
        }
    }
}

// MARK: - Offscreen host

@MainActor
private final class SurfaceHost {
    let view: NSView
    private let window: NSWindow

    init(rootView: AnyView, size: NSSize) {
        let hostingView = NSHostingView(rootView: rootView.background(Color.black))
        hostingView.frame = NSRect(origin: .zero, size: size)
        window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.setFrameOrigin(NSPoint(x: -4_000, y: -4_000))
        window.orderFront(nil)
        view = hostingView
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
    }

    func bitmap() -> NSBitmapImageRep? {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

}
