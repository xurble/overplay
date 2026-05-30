import Testing
@testable import Overplay

struct StartupAuthorizationGateTests {
    @Test func firstRunShowsPermissionBeforeReadinessCheck() {
        #expect(StartupAuthorizationGate.shouldShowPermissionView(
            readiness: .notDetermined,
            hasCheckedReadiness: false,
            hasPresentedAuthorizedUI: false
        ))
    }

    @Test func repeatLaunchSuppressesPermissionUntilReadinessCheckCompletes() {
        #expect(!StartupAuthorizationGate.shouldShowPermissionView(
            readiness: .notDetermined,
            hasCheckedReadiness: false,
            hasPresentedAuthorizedUI: true
        ))
    }

    @Test func repeatLaunchShowsPermissionAfterFailedReadinessCheck() {
        #expect(StartupAuthorizationGate.shouldShowPermissionView(
            readiness: .denied,
            hasCheckedReadiness: true,
            hasPresentedAuthorizedUI: true
        ))
    }

    @Test func readyStateNeverShowsPermission() {
        #expect(!StartupAuthorizationGate.shouldShowPermissionView(
            readiness: .authorized(canPlayCatalogContent: true, hasCloudLibraryEnabled: true),
            hasCheckedReadiness: true,
            hasPresentedAuthorizedUI: false
        ))
    }
}
