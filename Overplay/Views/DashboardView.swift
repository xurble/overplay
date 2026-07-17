import SwiftData
import SwiftUI

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PlaybackController.self) private var playbackController

    @Query(filter: #Predicate<PlaylistRecord> { $0.isActive }, sort: \PlaylistRecord.name) private var playlists: [PlaylistRecord]
    @State private var playlistItems: [PlaylistItemRecord] = []
    @State private var tracks: [TrackRecord] = []

    var settings: OverplaySettings

    var body: some View {
        List {
            Section {
                if let oneTruePlaylist {
                    NavigationLink {
                        PlaylistManagementView(settings: settings, playlist: oneTruePlaylist)
                    } label: {
                        playlistHomeRow(for: oneTruePlaylist)
                    }
                } else {
                    NavigationLink {
                        PlaylistSelectionView()
                    } label: {
                        PlaylistHomeRowView(
                            title: "Link One True Playlist",
                            detail: "Choose the main playlist Overplay manages.",
                            artworkURLString: nil,
                            playlistID: nil,
                            systemImage: "star.fill",
                            badgeTint: .pink
                        )
                    }
                }
            }

            Section("Triage Playlists") {
                ForEach(triagePlaylists) { playlist in
                    NavigationLink {
                        PlaylistManagementView(settings: settings, playlist: playlist)
                    } label: {
                        playlistHomeRow(for: playlist)
                    }
                }
                .onDelete(perform: deleteTriagePlaylists)

                NavigationLink {
                    PlaylistSelectionView()
                } label: {
                    Label(
                        triagePlaylists.isEmpty ? "Link Triage Playlist" : "Link Another Triage Playlist",
                        systemImage: "plus.circle"
                    )
                }
            }
        }
        .miniPlayerScrollContentInset()
        .navigationTitle("Overplay")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    SettingsView(settings: settings)
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
        .task(id: dashboardDataKey) {
            reloadDashboardData()
        }
    }

    private func playlistHomeRow(for playlist: PlaylistRecord) -> some View {
        let summary = presentation(for: playlist)
        return PlaylistHomeRowView(
            title: playlist.name,
            detail: summary.dashboardDetailText,
            artworkURLString: summary.artworkURLString,
            playlistID: playlist.musicPlaylistID,
            systemImage: summary.iconIntent.systemImage,
            badgeTint: badgeTint(for: summary, role: playlist.role)
        )
    }

    private func badgeTint(for summary: PlaylistSummaryPresentation, role: PlaylistRole) -> Color {
        if summary.isCurrentPlaybackPlaylist {
            return .green
        }

        return role == .oneTruePlaylist ? .pink : .teal
    }

    private var dashboardDataKey: String {
        playlists.map(\.id.uuidString).joined(separator: "-")
    }

    private var oneTruePlaylist: PlaylistRecord? {
        if let playlistID = settings.selectedPlaylistID,
           let playlist = playlists.first(where: { $0.musicPlaylistID == playlistID && $0.role == .oneTruePlaylist && $0.isActive }) {
            return playlist
        }

        return playlists.first { $0.role == .oneTruePlaylist && $0.isActive }
    }

    private var triagePlaylists: [PlaylistRecord] {
        playlists.filter { $0.role == .triage && $0.isActive }
    }

    private func presentation(for playlist: PlaylistRecord) -> PlaylistSummaryPresentation {
        presentationBuilder.summary(for: playlist)
    }

    private var presentationBuilder: PlaylistPresentationBuilder {
        PlaylistPresentationBuilder(
            playlists: playlists,
            items: playlistItems,
            tracks: tracks,
            currentPlaylistID: playbackController.currentTrack != nil ? playbackController.currentPlaylistID : nil
        )
    }

    private func reloadDashboardData() {
        let playlistIDs = playlists.map(\.id)
        playlistItems = (try? PlaylistItemRepository.items(forPlaylistIDs: playlistIDs, in: modelContext)) ?? []
        tracks = (try? TrackRecordRepository.tracks(ids: playlistItems.map(\.trackID), in: modelContext)) ?? []
    }

    private func deleteTriagePlaylists(at offsets: IndexSet) {
        for index in offsets {
            let playlist = triagePlaylists[index]
            try? PlaylistRepository.deactivateTriagePlaylist(playlist, in: modelContext)
        }
    }
}

#Preview {
    NavigationStack {
        DashboardView(settings: OverplaySettings(selectedPlaylistID: "preview-playlist", selectedPlaylistName: "Overplay"))
    }
    .environment(PlaybackController())
    .modelContainer(PreviewContainer.make())
}
