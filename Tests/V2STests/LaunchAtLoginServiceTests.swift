import Foundation
import ServiceManagement
import XCTest
@testable import v2s

@MainActor
final class LaunchAtLoginServiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "LaunchAtLoginServiceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testV2RecaseReregistersEnabledLoginWithoutTouchingV1Keys() {
        defaults.set(true, forKey: LaunchAtLoginService.pathMigrationDefaultsKey)
        let appService = FakeLaunchAtLoginAppService(status: .enabled)

        _ = LaunchAtLoginService(userDefaults: defaults, appService: appService)

        XCTAssertEqual(appService.unregisterCount, 1)
        XCTAssertEqual(appService.registerCount, 1)
        XCTAssertTrue(defaults.bool(forKey: LaunchAtLoginService.pathMigrationDefaultsKeyV2))
        XCTAssertNil(defaults.object(forKey: LaunchAtLoginService.pathMigrationPendingKeyV2))
        XCTAssertTrue(defaults.bool(forKey: LaunchAtLoginService.pathMigrationDefaultsKey))
        XCTAssertNil(defaults.object(forKey: LaunchAtLoginService.pathMigrationPendingKey))
        XCTAssertEqual(defaults.object(forKey: LaunchAtLoginService.pathMigrationDefaultsKey) as? Bool, true)
    }

    func testV2DoesNotReregisterWhenAlreadyComplete() {
        defaults.set(true, forKey: LaunchAtLoginService.pathMigrationDefaultsKey)
        defaults.set(true, forKey: LaunchAtLoginService.pathMigrationDefaultsKeyV2)
        let appService = FakeLaunchAtLoginAppService(status: .enabled)

        _ = LaunchAtLoginService(userDefaults: defaults, appService: appService)

        XCTAssertEqual(appService.unregisterCount, 0)
        XCTAssertEqual(appService.registerCount, 0)
        XCTAssertTrue(defaults.bool(forKey: LaunchAtLoginService.pathMigrationDefaultsKey))
        XCTAssertTrue(defaults.bool(forKey: LaunchAtLoginService.pathMigrationDefaultsKeyV2))
    }

    func testV2MarksCompleteWithoutRegisteringWhenLoginIsOff() {
        defaults.set(true, forKey: LaunchAtLoginService.pathMigrationDefaultsKey)
        let appService = FakeLaunchAtLoginAppService(status: .notRegistered)

        _ = LaunchAtLoginService(userDefaults: defaults, appService: appService)

        XCTAssertEqual(appService.unregisterCount, 0)
        XCTAssertEqual(appService.registerCount, 0)
        XCTAssertTrue(defaults.bool(forKey: LaunchAtLoginService.pathMigrationDefaultsKeyV2))
        XCTAssertTrue(defaults.bool(forKey: LaunchAtLoginService.pathMigrationDefaultsKey))
        XCTAssertNil(defaults.object(forKey: LaunchAtLoginService.pathMigrationPendingKeyV2))
    }

    func testV2PendingReregistersEvenIfStatusIsNotRegistered() {
        defaults.set(true, forKey: LaunchAtLoginService.pathMigrationDefaultsKey)
        defaults.set(true, forKey: LaunchAtLoginService.pathMigrationPendingKeyV2)
        let appService = FakeLaunchAtLoginAppService(status: .notRegistered)

        _ = LaunchAtLoginService(userDefaults: defaults, appService: appService)

        XCTAssertEqual(appService.unregisterCount, 0)
        XCTAssertEqual(appService.registerCount, 1)
        XCTAssertTrue(defaults.bool(forKey: LaunchAtLoginService.pathMigrationDefaultsKeyV2))
        XCTAssertNil(defaults.object(forKey: LaunchAtLoginService.pathMigrationPendingKeyV2))
        XCTAssertTrue(defaults.bool(forKey: LaunchAtLoginService.pathMigrationDefaultsKey))
    }

    func testV2KeepsPendingWhenReregistrationFails() {
        defaults.set(true, forKey: LaunchAtLoginService.pathMigrationDefaultsKey)
        let appService = FakeLaunchAtLoginAppService(status: .enabled)
        appService.registerError = TestError.registrationFailed

        _ = LaunchAtLoginService(userDefaults: defaults, appService: appService)

        XCTAssertEqual(appService.unregisterCount, 1)
        XCTAssertEqual(appService.registerCount, 1)
        XCTAssertFalse(defaults.bool(forKey: LaunchAtLoginService.pathMigrationDefaultsKeyV2))
        XCTAssertEqual(defaults.bool(forKey: LaunchAtLoginService.pathMigrationPendingKeyV2), true)
        XCTAssertTrue(defaults.bool(forKey: LaunchAtLoginService.pathMigrationDefaultsKey))
        XCTAssertNil(defaults.object(forKey: LaunchAtLoginService.pathMigrationPendingKey))
    }

    func testHistoricalV1KeyNamesAreUnchanged() {
        XCTAssertEqual(LaunchAtLoginService.pathMigrationDefaultsKey, "easy2sayLaunchAtLoginPathMigrationV1")
        XCTAssertEqual(LaunchAtLoginService.pathMigrationPendingKey, "easy2sayLaunchAtLoginPathMigrationPendingV1")
        XCTAssertEqual(LaunchAtLoginService.pathMigrationDefaultsKeyV2, "easy2sayLaunchAtLoginPathMigrationV2")
        XCTAssertEqual(LaunchAtLoginService.pathMigrationPendingKeyV2, "easy2sayLaunchAtLoginPathMigrationPendingV2")
    }
}

private enum TestError: Error {
    case registrationFailed
}

private final class FakeLaunchAtLoginAppService: LaunchAtLoginRegistering {
    var status: SMAppService.Status
    var registerCount = 0
    var unregisterCount = 0
    var registerError: Error?
    var unregisterError: Error?

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        registerCount += 1
        if let registerError {
            throw registerError
        }
        status = .enabled
    }

    func unregister() throws {
        unregisterCount += 1
        if let unregisterError {
            throw unregisterError
        }
        status = .notRegistered
    }
}
