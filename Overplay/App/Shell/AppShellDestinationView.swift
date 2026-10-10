import SwiftData
import SwiftUI

/// One destination's screen, shared by the compact stack and the regular
/// detail column.
struct AppShellDestinationView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PlaylistRecord.name) private var playlists: [PlaylistRecord]

    var destination: AppShellDestination
    var settings: OverplaySettings
    /// A merged playlist opens as the playlist it was merged into.
    var onResolvedPlaylist: (UUID) -> Void = { _ in }

    var body: some View {
        switch destination {
        case .dashboard:
            DashboardView(settings: settings)
        case let .playlist(playlistID):
            if let playlist = resolvedActivePlaylist(for: playlistID) {
                PlaylistManagementView(settings: settings, playlist: playlist)
                    .task(id: playlist.id) {
                        guard playlist.id != playlistID else { return }
                        onResolvedPlaylist(playlist.id)
                    }
            } else {
                ContentUnavailableView(
                    "Playlist Unavailable",
                    systemImage: "music.note.list",
                    description: Text("Choose another linked playlist from the sidebar.")
                )
            }
        case .retired:
            if let bucket = playlists.first(where: { $0.isActive && $0.isTriageBucket }) {
                PlaylistManagementView(settings: settings, playlist: bucket, scope: .retired)
            } else {
                ContentUnavailableView("No Retired Tracks", systemImage: "archivebox")
            }
        case let .recent(id):
            if let recent = try? RecentCollectionRepository.recent(id: id, in: modelContext) {
                RecentCollectionView(recent: recent)
            } else {
                ContentUnavailableView("Deep Dive Unavailable", systemImage: "square.stack")
            }
        case .search:
            SearchMusicView(settings: settings)
        case .history:
            HistoryView()
        case .settings:
            SettingsView(settings: settings)
        }
    }

    private func resolvedActivePlaylist(for playlistID: UUID) -> PlaylistRecord? {
        guard let requestedPlaylist = playlists.first(where: { $0.id == playlistID }) else {
            return nil
        }
        let resolvedPlaylist = PlaylistRepository.canonicalPlaylist(
            for: requestedPlaylist,
            among: playlists
        )
        guard resolvedPlaylist.isActive, resolvedPlaylist.role.isPlaybackContext else {
            return nil
        }
        return resolvedPlaylist
    }
}

#Preview {
    NavigationStack {
        AppShellDestinationView(destination: .dashboard, settings: OverplaySettings(selectedPlaylistID: "preview-playlist", selectedPlaylistName: "Overplay"))
    }
    .environment(PlaybackController())
    .modelContainer(PreviewContainer.make())
}
