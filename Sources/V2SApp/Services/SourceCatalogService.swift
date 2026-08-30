#if os(macOS)
import AppKit
#endif
import AVFoundation
import Foundation

struct SourceCatalogSnapshot: Equatable {
    let applications: [InputSource]
    let microphones: [InputSource]
}

@MainActor
protocol SourceCatalogProviding {
    func loadSnapshot() -> SourceCatalogSnapshot
}

@MainActor
final class SourceCatalogService: SourceCatalogProviding {
#if os(macOS)
    private let microphoneDiscoverySession = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.microphone, .external],
        mediaType: .audio,
        position: .unspecified
    )
#elseif os(iOS)
    private let microphoneDiscoverySession = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.microphone, .external],
        mediaType: .audio,
        position: .unspecified
    )
#endif

    func loadSnapshot() -> SourceCatalogSnapshot {
        SourceCatalogSnapshot(
            applications: loadApplications(),
            microphones: loadMicrophones()
        )
    }

    private func loadApplications() -> [InputSource] {
#if os(macOS)
        let runningApps = NSWorkspace.shared.runningApplications
            .filter { app in
                app.activationPolicy == .regular
                    && app.localizedName?.isEmpty == false
                    && app.bundleIdentifier != Bundle.main.bundleIdentifier
            }
            .map { app in
                InputSource(
                    id: "app:\(app.bundleIdentifier ?? "pid-\(app.processIdentifier)")",
                    name: app.localizedName ?? "Unknown App",
                    detail: app.bundleIdentifier ?? "pid-\(app.processIdentifier)",
                    category: .application
                )
            }

        return deduplicated(runningApps)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
#elseif os(iOS)
        return []
#endif
    }

    private func loadMicrophones() -> [InputSource] {
#if os(macOS)
        let devices = microphoneDiscoverySession.devices.map { device in
            InputSource(
                id: "mic:\(device.uniqueID)",
                name: device.localizedName,
                detail: device.uniqueID,
                category: .microphone
            )
        }
#elseif os(iOS)
        let devices = microphoneDiscoverySession.devices.map { device in
            InputSource(
                id: device.uniqueID,
                name: device.localizedName,
                detail: device.uniqueID,
                category: .microphone
            )
        }
#endif

        return deduplicated(devices)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func deduplicated(_ sources: [InputSource]) -> [InputSource] {
        var seen = Set<String>()

        return sources.filter { source in
            seen.insert(source.id).inserted
        }
    }
}
