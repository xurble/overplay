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
        }

        await viewModel.bootstrap(isReady: true, dependencies: dependencies)

        #expect(viewModel.hasStartedAuthorizedServices)
        #expect(events == ["settings", "authorization", "remote", "merge", "restore", "monitor", "sync-start"])
    }

    @Test("repeated authorized startup does not restart services")
    func repeatedAuthorizedStartupDoesNotRestartServices() async {
        let viewModel = AppStartupViewModel()
        var startCount = 0
        let dependencies = AppStartupViewModel.Dependencies {
        } refreshAuthorization: {
        } installRemoteCommands: {
        } mergeDuplicateTrackIdentities: {
        } restoreLocalPlaybackDisplay: {
        } startPlaybackMonitoring: {
        } startPeriodicPlaylistSync: {
            startCount += 1
        } stopPeriodicPlaylistSync: {
        }

        await viewModel.bootstrap(isReady: true, dependencies: dependencies)
        viewModel.authorizationReadinessChanged(isReady: true, dependencies: dependencies)

        #expect(viewModel.hasStartedAuthorizedServices)
        #expect(startCount == 1)
    }

    @Test("transition back to unauthorized stops periodic sync")
    func transitionBackToUnauthorizedStopsPeriodicSync() async {
        let viewModel = AppStartupViewModel()
        var startCount = 0
        var stopCount = 0
        let dependencies = AppStartupViewModel.Dependencies {
        } refreshAuthorization: {
        } installRemoteCommands: {
        } mergeDuplicateTrackIdentities: {
        } restoreLocalPlaybackDisplay: {
        } startPlaybackMonitoring: {
        } startPeriodicPlaylistSync: {
            startCount += 1
        } stopPeriodicPlaylistSync: {
            stopCount += 1
        }

        await viewModel.bootstrap(isReady: true, dependencies: dependencies)
        viewModel.authorizationReadinessChanged(isReady: false, dependencies: dependencies)

        #expect(!viewModel.hasStartedAuthorizedServices)
        #expect(startCount == 1)
        #expect(stopCount == 1)
    }
}
