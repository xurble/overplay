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
}
