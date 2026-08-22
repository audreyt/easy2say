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
            HomeView(model: model)
                .v2sTranslationHost(model: model)
                .preferredColorScheme(.dark)
        }
    }
}
