import SwiftData
import SwiftUI

struct AppRouter: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(MusicAuthorizationService.self) private var authorizationService
    @Environment(PlaybackController.self) private var playbackController

    @Query private var settingsRecords: [OverplaySettings]
    @State private var remoteCommandService = RemoteCommandService()

    var body: some View {
        NavigationStack {
            Group {
                if !authorizationService.readiness.isReady {
                    PermissionView()
                } else if let settings {
                    if settings.selectedPlaylistID == nil {
                        PlaylistSelectionView()
                    } else {
                        DashboardView(settings: settings)
                    }
                } else {
                    ProgressView("Preparing Overplay")
                }
            }
        }
        .task {
            _ = try? SettingsRepository.settings(in: modelContext)
            await authorizationService.refresh()
            playbackController.startMonitoring(context: modelContext)
            remoteCommandService.install(playbackController: playbackController, context: modelContext)
        }
    }

    private var settings: OverplaySettings? {
        settingsRecords.first
    }
}

#Preview {
    AppRouter()
        .environment(MusicAuthorizationService())
        .environment(PlaybackController())
        .modelContainer(PreviewContainer.make())
}
