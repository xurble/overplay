import SwiftData
import SwiftUI

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PlaybackController.self) private var playbackController

    @Query(filter: #Predicate<PlaylistRecord> { $0.isActive }, sort: \PlaylistRecord.name) private var playlists: [PlaylistRecord]
    @Query private var playlistItems: [PlaylistItemRecord]
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

            Section("Triage") {
                if let triageBucket {
                    NavigationLink {
                        PlaylistManagementView(settings: settings, playlist: triageBucket)
                    } label: {
                        playlistHomeRow(for: triageBucket)
                    }
                }

                NavigationLink {
                    TriageSourcesView()
                } label: {
                    Label(
                        triageSourceCount == 0 ? "Add Triage Playlists" : triageSourcesLabel,
                        systemImage: triageSourceCount == 0 ? "plus.circle" : "slider.horizontal.3"
                    )
                }
            }

            if let triageBucket {
                Section {
                    NavigationLink {
                        PlaylistManagementView(settings: settings, playlist: triageBucket, scope: .retired)
                    } label: {
                        PlaylistHomeRowView(
                            title: "Retired",
                            detail: "\(playlistItems.filter { $0.evictedAt != nil }.count) tracks · Revisit songs you put aside",
                            artworkURLString: nil, playlistID: nil,
                            systemImage: "archivebox.fill", badgeTint: .secondary
                        )
                    }
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
            + playlistItems.map(\.trackID.uuidString).joined(separator: "-")
    }

    private var oneTruePlaylist: PlaylistRecord? {
        if let playlistID = settings.selectedPlaylistID,
           let playlist = playlists.first(where: { $0.musicPlaylistID == playlistID && $0.role == .oneTruePlaylist && $0.isActive }) {
            return playlist
        }

        return playlists.first { $0.role == .oneTruePlaylist && $0.isActive }
    }

    private var triageBucket: PlaylistRecord? {
        return playlists.first { $0.isTriageBucket }
    }

    private var triageSourceCount: Int {
        playlists.filter { $0.role == .triageSource && $0.isActive }.count
    }

    private var triageSourcesLabel: String {
        triageSourceCount == 1 ? "1 Contributing Playlist" : "\(triageSourceCount) Contributing Playlists"
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
        tracks = (try? TrackRecordRepository.tracks(ids: playlistItems.map(\.trackID), in: modelContext)) ?? []
    }

}

#Preview {
    NavigationStack {
        DashboardView(settings: OverplaySettings(selectedPlaylistID: "preview-playlist", selectedPlaylistName: "Overplay"))
    }
    .environment(PlaybackController())
    .modelContainer(PreviewContainer.make())
}
