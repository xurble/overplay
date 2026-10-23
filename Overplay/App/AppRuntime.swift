import Observation
import CoreData
import SwiftData

@MainActor
@Observable
final class AppRuntime {
    static let shared = AppRuntime()

    let libraryRestoration = LibraryRestorationService()
    let startupViewModel = AppStartupViewModel()

    let authorizationService = MusicAuthorizationService()
    let playbackController = AppRuntime.makePlaybackController()
    let nowPlayingBridge = SystemNowPlayingBridge()
    let periodicPlaylistSyncService = PeriodicPlaylistSyncService()

    @ObservationIgnored private var modelContainer: ModelContainer?
    /// The iCloud container the library is mirrored to; nil when it is not.
    @ObservationIgnored private(set) var cloudKitContainerIdentifier: String?
    @ObservationIgnored private var cloudImportObserver: NSObjectProtocol?

    private static func makePlaybackController() -> PlaybackController {
        #if targetEnvironment(simulator)
        // No Apple Music in the simulator: play the library on a clock.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            return PlaybackController(player: SimulatorPlaybackPlayer(), preparePlaybackTracks: SimulatorPlaybackPlayer.prepare)
        }
        #endif
        return PlaybackController()
    }

    private init() {
        // Counting and item reads wait for restoration; playback does not.
        playbackController.isLibraryReady = { [weak self] in self?.libraryRestoration.isReady ?? false }
    }

    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        cloudKitContainerIdentifier = modelContainer.configurations.lazy.compactMap(\.cloudKitContainerIdentifier).first
        if let cloudImportObserver { NotificationCenter.default.removeObserver(cloudImportObserver) }
        let cloudStoreIDs = Set(modelContainer.configurations.compactMap { configuration -> String? in
            guard configuration.cloudKitContainerIdentifier != nil else { return nil }
            return (try? NSPersistentStoreCoordinator.metadataForPersistentStore(
                ofType: NSSQLiteStoreType, at: configuration.url, options: nil
            ))?[NSStoreUUIDKey] as? String
        })
        cloudImportObserver = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event,
                  cloudStoreIDs.contains(event.storeIdentifier),
                  event.type == .import, event.endDate != nil else { return }
            let error = event.succeeded ? nil : (event.error?.localizedDescription ?? "Cloud import failed.")
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.libraryRestoration.cloudImportFinished(error: error)
                guard error == nil, let context = self.makeModelContext() else { return }
                // Imported listen events from other devices change derived
                // counts; the cache is recomputed rather than synced.
                do {
                    if try ListenLedger.reconcile(in: context) > 0 {
                        self.playbackController.refreshPlayCountMetadata(context: context)
                    }
                } catch {
                    StartupProfiler.mark("Listen ledger reconcile after import failed: \(error.localizedDescription)")
                }
                self.repairTrackLocations(in: context)
                ApplePlayCountSyncService.shared.reconcile(in: context, playbackController: self.playbackController)
                // A Mac may have asked for the One True Playlist (`SETUP-002`).
                await self.checkOneTruePlaylist(in: context)
            }
        }
    }

    /// An import can carry another device's stale row over a newer local
    /// retirement or restore; the history events put it back (`LOC-001`).
    func repairTrackLocations(in context: ModelContext) {
        do {
            guard try TrackLocationService.repairRetirementState(in: context) > 0 else { return }
            try context.save()
            playbackController.reconcileTrackMembership(context: context)
        } catch {
            StartupProfiler.mark("Track location repair failed: \(error.localizedDescription)")
        }
    }

    /// Asked before the One True Playlist's Apple Music playlist is made
    /// (`SETUP-002`, `SETUP-003`); the app presents it as an alert.
    private(set) var oneTruePlaylistPrompt: OneTruePlaylistPrompt?
    /// "Not Now" holds until the next launch.
    @ObservationIgnored private var declinedOneTruePlaylistPrompt = false
    @ObservationIgnored private var isMakingOneTruePlaylist = false

    /// `checksPresence`: a sync could not find the playlist, so look it up.
    func checkOneTruePlaylist(in context: ModelContext, checksPresence: Bool = false) async {
        guard !declinedOneTruePlaylistPrompt, !isMakingOneTruePlaylist, oneTruePlaylistPrompt == nil else { return }
        oneTruePlaylistPrompt = await OneTruePlaylistPresenceService().prompt(in: context, checksPresence: checksPresence)
    }

    func declineOneTruePlaylistPrompt() {
        oneTruePlaylistPrompt = nil
        declinedOneTruePlaylistPrompt = true
    }

    /// The user agreed: make the playlist the prompt described.
    func makeOneTruePlaylist(for prompt: OneTruePlaylistPrompt, in context: ModelContext) async {
        oneTruePlaylistPrompt = nil
        isMakingOneTruePlaylist = true
        defer { isMakingOneTruePlaylist = false }
        switch prompt {
        case .requestedByMac:
            await fulfilPendingOneTruePlaylist(in: context)
            if (try? context.fetch(FetchDescriptor<OverplaySettings>()).first?.selectedPlaylistID) == nil {
                StatusToast.shared.show("Overplay couldn’t make the playlist. It will ask again next time it starts.")
            }
        case .missing:
            do {
                let result = try await OneTruePlaylistRebuildService().rebuild(in: context)
                playbackController.reconcilePlaylistSelection(context: context)
                StatusToast.shared.show("Made “\(result.name)” again in Apple Music with \(result.addedCount) songs.")
            } catch {
                StatusToast.shared.show(UserFacingError.message(for: error))
            }
        }
    }

    /// Makes the One True Playlist a Mac asked for, on a device that can
    /// (`SETUP-002`), and points playback at it.
    func fulfilPendingOneTruePlaylist(in context: ModelContext) async {
        guard let playlist = await PendingOneTruePlaylistService().fulfilIfNeeded(in: context) else { return }
        playbackController.reconcilePlaylistSelection(context: context)
        playbackController.reconcileStoredOrder(for: playlist, context: context)
    }

    func startLibraryMaintenance() {
        guard libraryRestoration.isReady, let modelContainer else { return }
        PlaylistCollageService.shared.maintainSnapshots(in: modelContainer)
    }

    /// Siri and Shortcuts can launch Overplay with no window, so nothing has
    /// started the library. Start it as CarPlay does and wait a bounded time
    /// (`SIRI-002`). Nil when it is not ready in time; nothing changes then.
    func prepareForBackgroundAction(timeout: Duration = .seconds(8)) async -> ModelContext? {
        guard let context = mainModelContext else { return nil }
        if !libraryRestoration.isReady {
            await startupViewModel.bootstrap(
                isReady: authorizationService.readiness.isReady,
                dependencies: startupViewModel.dependencies(modelContext: context, runtime: self,
                    authorizationService: authorizationService, playbackController: playbackController)
            )
        }
        let deadline = ContinuousClock.now + timeout
        while !libraryRestoration.isReady, startupViewModel.libraryPreparationError == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return libraryRestoration.isReady ? context : nil
    }

    func makeModelContext() -> ModelContext? {
        guard libraryRestoration.isReady, let modelContainer else { return nil }
        return ModelContext(modelContainer)
    }

    /// The container's main-actor context — the one app startup hands to
    /// long-lived services. Secondary contexts (e.g. CarPlay's) should be
    /// swapped back to this when their surface goes away.
    var mainModelContext: ModelContext? {
        modelContainer?.mainContext
    }
}
