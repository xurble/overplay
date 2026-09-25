import Observation
import CoreData
import SwiftData

@MainActor
@Observable
final class AppRuntime {
    static let shared = AppRuntime()

    let authorizationService = MusicAuthorizationService()
    let playbackController = PlaybackController()
    let remoteCommandService = RemoteCommandService()
    let periodicPlaylistSyncService = PeriodicPlaylistSyncService()

    @ObservationIgnored private var modelContainer: ModelContainer?
    @ObservationIgnored private var cloudImportObserver: NSObjectProtocol?

    private init() {}

    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        if let cloudImportObserver { NotificationCenter.default.removeObserver(cloudImportObserver) }
        cloudImportObserver = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event,
                  event.type == .import, event.endDate != nil, event.succeeded else { return }
            Task { @MainActor [weak self] in
                guard let self, let context = self.makeModelContext() else { return }
                ApplePlayCountSyncService.shared.reconcile(in: context, playbackController: self.playbackController)
            }
        }
    }

    func makeModelContext() -> ModelContext? {
        guard let modelContainer else { return nil }
        return ModelContext(modelContainer)
    }

    /// The container's main-actor context — the one app startup hands to
    /// long-lived services. Secondary contexts (e.g. CarPlay's) should be
    /// swapped back to this when their surface goes away.
    var mainModelContext: ModelContext? {
        modelContainer?.mainContext
    }
}
