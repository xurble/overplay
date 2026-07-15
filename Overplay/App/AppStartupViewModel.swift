import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class AppStartupViewModel {
    struct Dependencies {
        var loadSettings: () throws -> Void
        var refreshAuthorization: () async -> Void
        var installRemoteCommands: () -> Void
        var mergeDuplicateTrackIdentities: () async -> Void
        var restoreLocalPlaybackDisplay: () -> Void
        var startPlaybackMonitoring: () -> Void
        var startPeriodicPlaylistSync: () -> Void
        var stopPeriodicPlaylistSync: () -> Void
    }

    private(set) var hasStartedAuthorizedServices = false
    @ObservationIgnored private(set) var authorizedServicesTask: Task<Void, Never>?

    func shouldShowPermissionView(
        readiness: AppleMusicReadiness,
        hasCheckedReadiness: Bool,
        hasPresentedAuthorizedUI: Bool
    ) -> Bool {
        StartupAuthorizationGate.shouldShowPermissionView(
            readiness: readiness,
            hasCheckedReadiness: hasCheckedReadiness,
            hasPresentedAuthorizedUI: hasPresentedAuthorizedUI
        )
    }

    func bootstrap(isReady: Bool, dependencies: Dependencies) async {
        do {
            _ = try StartupProfiler.measure("Startup settings load") {
                try dependencies.loadSettings()
            }
        } catch {
            StartupProfiler.mark("Startup settings load failed: \(error.localizedDescription)")
        }

        await StartupProfiler.measure("Apple Music authorization refresh") {
            await dependencies.refreshAuthorization()
        }

        StartupProfiler.measure("Remote command startup") {
            dependencies.installRemoteCommands()
        }

        if isReady {
            startAuthorizedServices(dependencies: dependencies)
        }
    }

    func authorizationReadinessChanged(isReady: Bool, dependencies: Dependencies) {
        if isReady {
            startAuthorizedServices(dependencies: dependencies)
        } else {
            hasStartedAuthorizedServices = false
            dependencies.stopPeriodicPlaylistSync()
        }
    }

    func dependencies(
        modelContext: ModelContext,
        runtime: AppRuntime,
        authorizationService: MusicAuthorizationService,
        playbackController: PlaybackController
    ) -> Dependencies {
        Dependencies {
            _ = try SettingsRepository.settings(in: modelContext)
        } refreshAuthorization: {
            await authorizationService.refresh()
        } installRemoteCommands: {
            runtime.remoteCommandService.activate(playbackController: playbackController, context: modelContext)
        } mergeDuplicateTrackIdentities: {
            do {
                try await TrackIdentityMergeService.mergeDuplicates(in: modelContext)
            } catch {
                StartupProfiler.mark("Track identity merge failed: \(error.localizedDescription)")
            }
        } restoreLocalPlaybackDisplay: {
            playbackController.restoreLocalPlaybackDisplay(context: modelContext)
        } startPlaybackMonitoring: {
            playbackController.startMonitoring(context: modelContext)
        } startPeriodicPlaylistSync: {
            runtime.periodicPlaylistSyncService.start(
                context: modelContext,
                playbackController: playbackController
            )
        } stopPeriodicPlaylistSync: {
            runtime.periodicPlaylistSyncService.stop()
        }
    }

    private func startAuthorizedServices(dependencies: Dependencies) {
        guard !hasStartedAuthorizedServices else { return }
        hasStartedAuthorizedServices = true

        // The launch UI presents immediately; authorized services start
        // behind it in main-actor slices. Ordering still matters: the merge
        // rekeys the device-local stores that display restore reads.
        authorizedServicesTask = Task { @MainActor in
            await StartupProfiler.measure("Track identity merge") {
                await dependencies.mergeDuplicateTrackIdentities()
            }

            StartupProfiler.measure("Local playback display restore") {
                dependencies.restoreLocalPlaybackDisplay()
            }

            StartupProfiler.measure("Playback monitoring startup") {
                dependencies.startPlaybackMonitoring()
            }

            StartupProfiler.measure("Periodic playlist sync startup") {
                dependencies.startPeriodicPlaylistSync()
            }
        }
    }
}
