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
    let playbackController = PlaybackController()
    let nowPlayingBridge = SystemNowPlayingBridge()
    let periodicPlaylistSyncService = PeriodicPlaylistSyncService()

    @ObservationIgnored private var modelContainer: ModelContainer?
    @ObservationIgnored private var cloudImportObserver: NSObjectProtocol?

    private init() {
        // Counting and item reads wait for restoration; playback does not.
        playbackController.isLibraryReady = { [weak self] in self?.libraryRestoration.isReady ?? false }
    }

    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
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
                ApplePlayCountSyncService.shared.reconcile(in: context, playbackController: self.playbackController)
            }
        }
    }

    func startLibraryMaintenance() {
        guard libraryRestoration.isReady, let modelContainer else { return }
        PlaylistCollageService.shared.maintainSnapshots(in: modelContainer)
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
