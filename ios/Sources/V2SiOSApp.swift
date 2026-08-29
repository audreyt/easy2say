import Foundation
import SwiftUI

@main
struct V2SiOSApp: App {
    @StateObject private var model: AppModel

    init() {
        _model = StateObject(
            wrappedValue: AppModel(
                settingsStore: SettingsStore(),
                sourceCatalogService: SourceCatalogService()
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            Group {
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-test-live-caption-promotion") {
                    LiveCaptionPromotionUITestHarness(model: model)
                } else {
                    HomeView(model: model)
                }
#else
                HomeView(model: model)
#endif
            }
            .v2sTranslationHost(model: model)
            .preferredColorScheme(.dark)
        }
    }
}

#if DEBUG
private struct LiveCaptionPromotionUITestHarness: View {
    @ObservedObject var model: AppModel
    @State private var promotionID = UUID()
    @State private var precedingPromotionID = UUID()

    private static let tentativeSourceText = "Stable live caption"
    private static let committedSourceText = "Stable live caption."
    private static let tentativeTranslatedText = "穩定即時字幕"
    private static let committedTranslatedText = "穩定即時字幕。"

    var body: some View {
        VStack(spacing: 0) {
            CaptionHalves(model: model, isHorizontal: false)

            Button("Commit caption") {
                model.setOverlayStateForTesting(captionState(isCommitted: true))
            }
            .accessibilityIdentifier("commit-live-caption")
            .padding()
        }
        .background(IOSTheme.canvas)
        .onAppear {
            model.subtitleDisplayMode = .both
            model.setOverlayStateForTesting(captionState(isCommitted: false))
        }
    }

    private func captionState(isCommitted: Bool) -> OverlayPreviewState {
        var state = OverlayPreviewState(
            translatedText: isCommitted ? Self.committedTranslatedText : "先前字幕",
            sourceText: isCommitted ? Self.committedSourceText : "Previous caption",
            sourceName: "UI Test"
        )
        state.captionEpoch = isCommitted ? 2 : 1
        state.committedPromotionID = isCommitted ? promotionID : precedingPromotionID

        if isCommitted == false {
            state.draftSourceText = Self.tentativeSourceText
            state.draftPromotionID = promotionID
            state.setDraftTranslation(
                Self.tentativeTranslatedText,
                sourceText: Self.tentativeSourceText,
                promotionID: promotionID
            )
        }

        return state
    }
}
#endif
