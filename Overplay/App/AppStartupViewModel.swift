import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class AppStartupViewModel {
    struct Dependencies {
        var loadSettings: () throws -> Void
        var migrateTriageBucket: () -> Void
        var refreshAuthorization: () async -> Void
        var installRemoteCommands: () -> Void
        var mergeDuplicateTrackIdentities: () async -> Void
        var restoreLocalPlaybackDisplay: () -> Void
        var startPlaybackMonitoring: () -> Void
        var startPeriodicPlaylistSync: () -> Void
        var stopPeriodicPlaylistSync: () -> Void
        var compactHistory: () -> Void
        var removeVideoTracks: () -> Void = {}
        var prepareLibrary: () async throws -> Void = {}
        var authorizationIsReady: (() -> Bool)? = nil
    }

    private(set) var hasStartedAuthorizedServices = false
    private(set) var isPreparingLibrary = false
    private(set) var libraryPreparationError: String?
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
        await StartupProfiler.measure("Apple Music authorization refresh") {
            await dependencies.refreshAuthorization()
        }

        if dependencies.authorizationIsReady?() ?? isReady {
            startAuthorizedServices(dependencies: dependencies)
        }
    }

    func authorizationReadinessChanged(isReady: Bool, dependencies: Dependencies) {
        if isReady {
            startAuthorizedServices(dependencies: dependencies)
        } else {
            authorizedServicesTask?.cancel()
            authorizedServicesTask = nil
            isPreparingLibrary = false
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
            // Restoration supplies settings; startup must never synthesize them.
        } migrateTriageBucket: {
            // Generation 2 has no legacy ownership or role migration. The
            // rebuild creates its bucket with the rest of the graph atomically.
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
        } compactHistory: {
            do {
                try HistoryRetentionService.compact(in: modelContext)
            } catch {
                StartupProfiler.mark("History retention failed: \(error.localizedDescription)")
            }
        } removeVideoTracks: {
            do {
                try VideoTrackCleanupService.removeVideos(in: modelContext)
            } catch {
                StartupProfiler.mark("Video cleanup failed: \(error.localizedDescription)")
            }
        } prepareLibrary: {
            try await LibraryRebuildService.performIfNeeded(in: modelContext)
            try await runtime.libraryRestoration.prepare(in: modelContext, cloudEnabled: AppPersistence.cloudEnabled)
            // Before any merge: merges re-derive counts from the ledger, so
            // pre-ledger counts must be carried forward as baselines first.
            try ListenLedger.reconcile(in: modelContext)
            runtime.startLibraryMaintenance()
        } authorizationIsReady: {
            authorizationService.readiness.isReady
        }
    }

    func retryLibraryPreparation(dependencies: Dependencies) {
        startAuthorizedServices(dependencies: dependencies)
    }

    private func startAuthorizedServices(dependencies: Dependencies) {
        guard !hasStartedAuthorizedServices else { return }
        hasStartedAuthorizedServices = true
        isPreparingLibrary = true
        libraryPreparationError = nil

        // The launch UI presents immediately; authorized services start
        // behind it in main-actor slices. Ordering still matters: the merge
        // rekeys the device-local stores that display restore reads.
        authorizedServicesTask = Task { @MainActor in
            do {
                try await dependencies.prepareLibrary()
                try Task.checkCancellation()
                try dependencies.loadSettings()
                dependencies.removeVideoTracks()
                dependencies.migrateTriageBucket()
                dependencies.installRemoteCommands()
            } catch {
                guard !Task.isCancelled else { return }
                libraryPreparationError = error.localizedDescription
                isPreparingLibrary = false
                hasStartedAuthorizedServices = false
                return
            }
            guard !Task.isCancelled else { return }
            await StartupProfiler.measure("Track identity merge") {
                await dependencies.mergeDuplicateTrackIdentities()
            }

            guard !Task.isCancelled else { return }
            isPreparingLibrary = false
            StartupProfiler.measure("Local playback display restore") {
                dependencies.restoreLocalPlaybackDisplay()
            }

            StartupProfiler.measure("Playback monitoring startup") {
                dependencies.startPlaybackMonitoring()
            }

            StartupProfiler.measure("Periodic playlist sync startup") {
                dependencies.startPeriodicPlaylistSync()
            }

            StartupProfiler.measure("History retention") {
                dependencies.compactHistory()
            }
        }
    }
}
