import XCTest
@testable import v2s

@MainActor
final class SourceCatalogServiceTests: XCTestCase {
    private func microphone(_ id: String, name: String) -> InputSource {
        InputSource(id: id, name: name, detail: id, category: .microphone)
    }

    func testOrderedForDisplaySortsAlphabeticallyWithoutCurrentInput() {
        let sources = [
            microphone("wired", name: "Wired Headset"),
            microphone("builtin", name: "iPhone Microphone"),
            microphone("carplay", name: "CarPlay"),
        ]

        let ordered = SourceCatalogService.orderedForDisplay(sources, currentInputUID: nil)

        XCTAssertEqual(ordered.map(\.id), ["carplay", "builtin", "wired"])
    }

    func testOrderedForDisplayLeadsWithCurrentRouteInput() {
        let sources = [
            microphone("builtin", name: "iPhone Microphone"),
            microphone("carplay", name: "CarPlay"),
            microphone("wired", name: "Wired Headset"),
        ]

        let ordered = SourceCatalogService.orderedForDisplay(sources, currentInputUID: "wired")

        XCTAssertEqual(ordered.map(\.id), ["wired", "carplay", "builtin"])
    }

    func testOrderedForDisplayIgnoresUnknownCurrentInput() {
        let sources = [
            microphone("builtin", name: "iPhone Microphone"),
            microphone("carplay", name: "CarPlay"),
        ]

        let ordered = SourceCatalogService.orderedForDisplay(sources, currentInputUID: "missing")

        XCTAssertEqual(ordered.map(\.id), ["carplay", "builtin"])
    }
}
