import SwiftData
import SwiftUI

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \PlaylistRecord.name) private var playlists: [PlaylistRecord]
    @Query(sort: \PlaylistItemRecord.createdAt) private var playlistItems: [PlaylistItemRecord]
    @Query(sort: \TrackRecord.title) private var tracks: [TrackRecord]

    var settings: OverplaySettings

    var body: some View {
        List {
            Section {
                if let oneTruePlaylist {
                    NavigationLink {
                        PlaylistManagementView(settings: settings, playlist: oneTruePlaylist)
                    } label: {
                        PlaylistHomeRowView(
                            title: oneTruePlaylist.name,
                            detail: presentation(for: oneTruePlaylist).dashboardDetailText,
                            artworkURLString: presentation(for: oneTruePlaylist).artworkURLString,
                            playlistID: oneTruePlaylist.musicPlaylistID
                        )
                    }
                } else {
                    NavigationLink {
                        PlaylistSelectionView()
                    } label: {
                        PlaylistHomeRowView(
                            title: "Link One True Playlist",
                            detail: "Choose the main playlist Overplay manages.",
                            artworkURLString: nil,
                            playlistID: nil
                        )
                    }
                }
            }

            Section("Triage Playlists") {
                ForEach(triagePlaylists) { playlist in
                    NavigationLink {
                        PlaylistManagementView(settings: settings, playlist: playlist)
                    } label: {
                        PlaylistHomeRowView(
                            title: playlist.name,
                            detail: presentation(for: playlist).dashboardDetailText,
                            artworkURLString: presentation(for: playlist).artworkURLString,
                            playlistID: playlist.musicPlaylistID
                        )
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
            evictAfterSkips: settings.evictAfterSkips
        )
    }

    private func deleteTriagePlaylists(at offsets: IndexSet) {
        for index in offsets {
            let playlist = triagePlaylists[index]
            try? PlaylistRepository.deactivateTriagePlaylist(playlist, in: modelContext)
        }
    }
}

private struct PlaylistHomeRowView: View {
    var title: String
    var detail: String
    var artworkURLString: String?
    var playlistID: String?

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(
                urlString: artworkURLString,
                pixelSize: 96,
                playlistID: playlistID,
                cornerRadius: 8
            )
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 6)
    }
}

#Preview {
    NavigationStack {
        DashboardView(settings: OverplaySettings(selectedPlaylistID: "preview-playlist", selectedPlaylistName: "Overplay"))
    }
    .environment(PlaybackController())
    .modelContainer(PreviewContainer.make())
}
