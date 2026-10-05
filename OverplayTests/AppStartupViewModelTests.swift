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
        } removeVideoTracks: {
            events.append("remove-videos")
        }

        await viewModel.bootstrap(isReady: true, dependencies: dependencies)
        await viewModel.authorizedServicesTask?.value

        #expect(viewModel.hasStartedAuthorizedServices)
        // No persistence-writing services run before library preparation.
        #expect(events == [
            "authorization",
            "settings",
            "remove-videos",
            "migrate-triage",
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
    @Test("failed preparation runs no mutating services and retry starts once")
    func failedPreparationStopsAllWriters() async {
        let model = AppStartupViewModel()
        var events: [String] = []
        var shouldFail = true
        let dependencies = AppStartupViewModel.Dependencies {
            events.append("settings")
        } migrateTriageBucket: {
            events.append("migrate")
        } refreshAuthorization: {
        } installRemoteCommands: {
            events.append("commands")
        } mergeDuplicateTrackIdentities: {
            events.append("merge")
        } restoreLocalPlaybackDisplay: {
            events.append("restore")
        } startPlaybackMonitoring: {
            events.append("monitor")
        } startPeriodicPlaylistSync: {
            events.append("sync")
        } stopPeriodicPlaylistSync: {
        } compactHistory: {
            events.append("compact")
        } removeVideoTracks: {
            events.append("cleanup")
        } prepareLibrary: {
            if shouldFail { throw LibraryRestorationService.RestorationError.waitingForCloud }
        } reconcileListenLedger: {
            events.append("ledger")
        } repairTrackLocations: {
            events.append("repair")
        }
        await model.bootstrap(isReady: true, dependencies: dependencies)
        await model.authorizedServicesTask?.value
        #expect(events.isEmpty)
        #expect(!model.hasStartedAuthorizedServices)
        #expect(model.libraryPreparationError != nil)
        shouldFail = false
        model.retryLibraryPreparation(dependencies: dependencies)
        model.retryLibraryPreparation(dependencies: dependencies)
        await model.authorizedServicesTask?.value
        // The ledger reconciles before any merge; it is non-throwing, so a
        // counting failure cannot stop startup (round 2, M5).
        #expect(events == ["ledger", "repair", "settings", "cleanup", "migrate", "commands", "merge", "restore", "monitor", "sync", "compact"])
        #expect(model.libraryPreparationError == nil)
    }

    @Test("authorization loss cancels pending restoration before writers start")
    func cancellationDuringRestoration() async {
        let model = AppStartupViewModel()
        var writes = 0
        let dependencies = AppStartupViewModel.Dependencies {
            writes += 1
        } migrateTriageBucket: {
            writes += 1
        } refreshAuthorization: {
        } installRemoteCommands: {
            writes += 1
        } mergeDuplicateTrackIdentities: {
            writes += 1
        } restoreLocalPlaybackDisplay: {
        } startPlaybackMonitoring: {
            writes += 1
        } startPeriodicPlaylistSync: {
            writes += 1
        } stopPeriodicPlaylistSync: {
        } compactHistory: {
            writes += 1
        } prepareLibrary: {
            try await Task.sleep(for: .seconds(60))
        }
        await model.bootstrap(isReady: true, dependencies: dependencies)
        let pending = model.authorizedServicesTask
        model.authorizationReadinessChanged(isReady: false, dependencies: dependencies)
        await pending?.value
        #expect(writes == 0)
        #expect(!model.hasStartedAuthorizedServices)
        #expect(!model.isPreparingLibrary)
    }

}
