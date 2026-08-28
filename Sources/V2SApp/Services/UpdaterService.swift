import AppKit
import Combine
import Foundation
import ServiceManagement
import os.log
import Sparkle

@MainActor
final class UpdaterService: ObservableObject {
    private let updaterController: SPUStandardUpdaterController
    private var observation: AnyCancellable?
    private(set) var isStarted = false

    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            guard isStarted, automaticallyChecksForUpdates != updaterController.updater.automaticallyChecksForUpdates else { return }
            updaterController.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    init() {
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.automaticallyChecksForUpdates = false
        start()
    }

    func checkForUpdates() {
        guard isStarted else { return }
        updaterController.checkForUpdates(nil)
    }

    private func start() {
        do {
            try updaterController.updater.start()
            isStarted = true
            automaticallyChecksForUpdates = updaterController.updater.automaticallyChecksForUpdates
            observation = updaterController.updater.publisher(for: \.automaticallyChecksForUpdates)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] newValue in
                    guard let self, self.automaticallyChecksForUpdates != newValue else { return }
                    self.automaticallyChecksForUpdates = newValue
                }
        } catch {
            Logger.updater.warning("Sparkle updater failed to start: \(error.localizedDescription)")
        }
    }
}

@MainActor
final class LaunchAtLoginService: ObservableObject {
    private static let pathMigrationDefaultsKey = "easy2sayLaunchAtLoginPathMigrationV1"
    private static let pathMigrationPendingKey = "easy2sayLaunchAtLoginPathMigrationPendingV1"

    private let appService = SMAppService.mainApp
    private var cancellables = Set<AnyCancellable>()
    private let userDefaults: UserDefaults

    @Published private(set) var launchesAtLogin = false
    @Published private(set) var requiresApproval = false
    @Published private(set) var updateErrorMessage: String?

    init(
        notificationCenter: NotificationCenter = .default,
        userDefaults: UserDefaults = .standard
    ) {
        self.userDefaults = userDefaults
        migrateLegacyRegistrationIfNeeded()
        refreshStatus()

        notificationCenter.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshStatus()
            }
            .store(in: &cancellables)
    }

    private func migrateLegacyRegistrationIfNeeded() {
        guard userDefaults.bool(forKey: Self.pathMigrationDefaultsKey) == false else {
            return
        }

        let registrationWasEnabled = userDefaults.bool(forKey: Self.pathMigrationPendingKey)
        if registrationWasEnabled {
            refreshMigratedRegistration()
            return
        }

        switch appService.status {
        case .enabled, .requiresApproval:
            userDefaults.set(true, forKey: Self.pathMigrationPendingKey)
            refreshMigratedRegistration()
        case .notRegistered, .notFound:
            userDefaults.set(true, forKey: Self.pathMigrationDefaultsKey)
        @unknown default:
            break
        }
    }

    private func refreshMigratedRegistration() {
        switch appService.status {
        case .enabled, .requiresApproval:
            do {
                try appService.unregister()
            } catch {
                Logger.launchAtLogin.warning(
                    "Could not remove the legacy launch-at-login registration: \(error.localizedDescription, privacy: .public)"
                )
            }
        case .notRegistered, .notFound:
            break
        @unknown default:
            return
        }

        do {
            try appService.register()
            userDefaults.set(true, forKey: Self.pathMigrationDefaultsKey)
            userDefaults.removeObject(forKey: Self.pathMigrationPendingKey)
        } catch {
            Logger.launchAtLogin.warning(
                "Could not register Easy2say at its new application path: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func setLaunchesAtLogin(_ shouldLaunchAtLogin: Bool) {
        updateErrorMessage = nil

        do {
            if shouldLaunchAtLogin {
                try appService.register()
            } else {
                try appService.unregister()
            }
        } catch {
            Logger.launchAtLogin.error(
                "Failed to update launch-at-login setting: \(error.localizedDescription, privacy: .public)"
            )
            updateErrorMessage = error.localizedDescription
        }

        refreshStatus()
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func refreshStatus() {
        switch appService.status {
        case .enabled:
            launchesAtLogin = true
            requiresApproval = false
            updateErrorMessage = nil
        case .requiresApproval:
            launchesAtLogin = true
            requiresApproval = true
            updateErrorMessage = nil
        case .notRegistered:
            launchesAtLogin = false
            requiresApproval = false
        case .notFound:
            launchesAtLogin = false
            requiresApproval = false
        @unknown default:
            launchesAtLogin = false
            requiresApproval = false
        }
    }
}

private extension Logger {
    static let updater = Logger(subsystem: "com.franklioxygen.v2s", category: "updater")
    static let launchAtLogin = Logger(subsystem: "com.franklioxygen.v2s", category: "launchAtLogin")
}
