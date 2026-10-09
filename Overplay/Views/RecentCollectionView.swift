import SwiftData
import SwiftUI

/// A Recents entry's saved songs, played like a playlist (`PLAY-019`).
struct RecentCollectionView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PlaybackController.self) private var playbackController

    var recent: RecentCollectionRecord

    @State private var songs: [RecentCollectionPresentation.Song] = []

    var body: some View {
        List {
            Section {
                Button {
                    Task { await playbackController.playRecent(recent, startingAt: nil, context: modelContext) }
                } label: {
                    Label("Shuffle and Play", systemImage: "shuffle")
                        .font(.headline)
                }
                .disabled(songs.isEmpty)
                .accessibilityIdentifier("recent-shuffle-and-play")
            }

            Section(RecentCollectionPresentation.subtitle(for: recent)) {
                ForEach(songs) { song in
                    Button {
                        Task { await playbackController.playRecent(recent, startingAt: song.catalogID, context: modelContext) }
                    } label: {
                        PlaylistTrackRowView(
                            summary: song.summary,
                            playlistID: recent.collection.reservedPlaylistID,
                            isCurrent: RecentCollectionPresentation.isCurrent(song, in: recent, controller: playbackController)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            if let statusMessage = playbackController.statusMessage {
                Section {
                    Text(statusMessage)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.plain)
        .miniPlayerScrollContentInset()
        .navigationTitle(recent.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: reloadKey) {
            songs = RecentCollectionPresentation.songs(for: recent, in: modelContext)
        }
    }

    /// Reloads when the saved songs or anyone's counts change.
    private var reloadKey: String {
        "\(recent.songsData.hashValue)-\(playbackController.playbackItemMetadataVersion)"
    }
}

#Preview {
    let container = PreviewContainer.make()
    let recent = try? RecentCollectionRepository.record(
        PlaybackCollection(kind: .album, catalogID: "1", title: "Laid"),
        songs: [PlaybackCollectionSong(catalogID: "a", title: "Laid", artistName: "James", albumTitle: "Laid"),
                PlaybackCollectionSong(catalogID: "b", title: "Sometimes", artistName: "James", albumTitle: "Laid")],
        artworkURLTemplate: nil, in: container.mainContext
    )
    return NavigationStack {
        if let recent { RecentCollectionView(recent: recent) }
    }
    .environment(PlaybackController())
    .modelContainer(container)
}
