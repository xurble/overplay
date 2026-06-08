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
        var restoreLocalPlaybackDisplay: () -> Void
        var startPeriodicPlaylistSync: () -> Void
        var stopPeriodicPlaylistSync: () -> Void
    }

    private(set) var hasStartedAuthorizedServices = false

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
        } restoreLocalPlaybackDisplay: {
            playbackController.restoreLocalPlaybackDisplay(context: modelContext)
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

        StartupProfiler.measure("Local playback display restore") {
            dependencies.restoreLocalPlaybackDisplay()
        }

        StartupProfiler.measure("Periodic playlist sync startup") {
            dependencies.startPeriodicPlaylistSync()
        }
    }
}
