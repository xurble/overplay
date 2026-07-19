import Observation
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

    private init() {}

    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
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
