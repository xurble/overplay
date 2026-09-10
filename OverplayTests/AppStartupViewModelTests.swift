import Testing
@testable import Overplay

@MainActor
@Suite("App startup view model")
struct AppStartupViewModelTests {
    @Test("first authorized bootstrap starts services once")
    func firstAuthorizedBootstrapStartsServicesOnce() async {
        let viewModel = AppStartupViewModel()
        var events: [String] = []
        let dependencies = AppStartupViewModel.Dependencies {
            events.append("settings")
        } migrateTriageBucket: {
            events.append("migrate-triage")
        } refreshAuthorization: {
            events.append("authorization")
        } installRemoteCommands: {
            events.append("remote")
        } mergeDuplicateTrackIdentities: {
            events.append("merge")
        } restoreLocalPlaybackDisplay: {
            events.append("restore")
        } startPlaybackMonitoring: {
            events.append("monitor")
        } startPeriodicPlaylistSync: {
            events.append("sync-start")
        } stopPeriodicPlaylistSync: {
            events.append("sync-stop")
        } compactHistory: {
            events.append("compact")
        }

        await viewModel.bootstrap(isReady: true, dependencies: dependencies)
        await viewModel.authorizedServicesTask?.value

        #expect(viewModel.hasStartedAuthorizedServices)
        // The triage migration runs before authorization, so nothing reads a
        // playlist role before the pre-bucket rows have moved.
        #expect(events == [
            "settings",
            "migrate-triage",
            "authorization",
            "remote",
            "merge",
            "restore",
            "monitor",
            "sync-start",
            "compact"
        ])
    }

    @Test("repeated authorized startup does not restart services")
    func repeatedAuthorizedStartupDoesNotRestartServices() async {
        let viewModel = AppStartupViewModel()
        var startCount = 0
        let dependencies = AppStartupViewModel.Dependencies {
        } migrateTriageBucket: {
        } refreshAuthorization: {
        } installRemoteCommands: {
        } mergeDuplicateTrackIdentities: {
        } restoreLocalPlaybackDisplay: {
        } startPlaybackMonitoring: {
        } startPeriodicPlaylistSync: {
            startCount += 1
        } stopPeriodicPlaylistSync: {
        } compactHistory: {
        }

        await viewModel.bootstrap(isReady: true, dependencies: dependencies)
        viewModel.authorizationReadinessChanged(isReady: true, dependencies: dependencies)
        await viewModel.authorizedServicesTask?.value

        #expect(viewModel.hasStartedAuthorizedServices)
        #expect(startCount == 1)
    }

    @Test("transition back to unauthorized stops periodic sync")
    func transitionBackToUnauthorizedStopsPeriodicSync() async {
        let viewModel = AppStartupViewModel()
        var startCount = 0
        var stopCount = 0
        let dependencies = AppStartupViewModel.Dependencies {
        } migrateTriageBucket: {
        } refreshAuthorization: {
        } installRemoteCommands: {
        } mergeDuplicateTrackIdentities: {
        } restoreLocalPlaybackDisplay: {
        } startPlaybackMonitoring: {
        } startPeriodicPlaylistSync: {
            startCount += 1
        } stopPeriodicPlaylistSync: {
            stopCount += 1
        } compactHistory: {
        }

        await viewModel.bootstrap(isReady: true, dependencies: dependencies)
        await viewModel.authorizedServicesTask?.value
        viewModel.authorizationReadinessChanged(isReady: false, dependencies: dependencies)

        #expect(!viewModel.hasStartedAuthorizedServices)
        #expect(startCount == 1)
        #expect(stopCount == 1)
    }
}
