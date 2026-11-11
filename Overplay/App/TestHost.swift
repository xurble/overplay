import Foundation

/// Whether this process is the app hosting the unit-test bundle.
///
/// XCTest sets `XCTestConfigurationFilePath` in the host's environment and
/// loads XCTest into it. A UI test launches the app as a separate process
/// with neither, so the app under a UI test runs normally (its store comes
/// from `AppPersistence.uiTestingArgument`).
nonisolated enum TestHost {
    static let isHostingUnitTests: Bool =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
}
