#if os(macOS)
import AppKit
#endif
import AVFoundation
import Foundation

#if os(iOS)
/// Shared audio-session category setup for every iOS capture path.
///
/// The category options decide which route inputs exist at all: without
/// `.allowBluetoothHFP`, Bluetooth hands-free microphones (car kits, headsets)
/// never appear in `availableInputs`, so both the source list and
/// `setPreferredInput` must run against a session configured here.
enum IOSAudioSessionConfigurator {
    static func applyRecordCategory() throws {
        let session = AVAudioSession.sharedInstance()
        guard session.category != .record
            || session.mode != .measurement
            || session.categoryOptions.contains(.allowBluetoothHFP) == false else {
            return
        }
        try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
    }
}
#endif

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

        return deduplicated(devices)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
#elseif os(iOS)
        // Route ports, not capture devices: CarPlay and Bluetooth microphones are
        // AVAudioSession inputs and never surface through AVCaptureDevice discovery.
        try? IOSAudioSessionConfigurator.applyRecordCategory()
        let audioSession = AVAudioSession.sharedInstance()
        var devices = (audioSession.availableInputs ?? []).map { port in
            InputSource(
                id: port.uid,
                name: port.portName,
                detail: port.uid,
                category: .microphone
            )
        }
        if devices.isEmpty {
            devices = microphoneDiscoverySession.devices.map { device in
                InputSource(
                    id: device.uniqueID,
                    name: device.localizedName,
                    detail: device.uniqueID,
                    category: .microphone
                )
            }
        }

        return Self.orderedForDisplay(
            deduplicated(devices),
            currentInputUID: audioSession.currentRoute.inputs.first?.uid
        )
#endif
    }

    /// Alphabetical, except the input the system is currently routing from leads the
    /// list so the untouched default selection always mirrors the live route.
    static func orderedForDisplay(
        _ sources: [InputSource],
        currentInputUID: String?
    ) -> [InputSource] {
        var ordered = sources.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        if let currentInputUID,
           let currentIndex = ordered.firstIndex(where: { $0.id == currentInputUID }),
           currentIndex != 0 {
            ordered.insert(ordered.remove(at: currentIndex), at: 0)
        }
        return ordered
    }

    private func deduplicated(_ sources: [InputSource]) -> [InputSource] {
        var seen = Set<String>()

        return sources.filter { source in
            seen.insert(source.id).inserted
        }
    }
}
