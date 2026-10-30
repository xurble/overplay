import SwiftData
import SwiftUI

/// A Recents entry's saved songs, played like a playlist (`PLAY-019`).
struct RecentCollectionView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PlaybackController.self) private var playbackController
    @Environment(\.shellPlace) private var shellPlace

    var recent: RecentCollectionRecord

    @State private var songs: [RecentCollectionPresentation.Song] = []

    var body: some View {
        CollectionSongListView(
            title: recent.title,
            subtitle: RecentCollectionPresentation.subtitle(for: recent),
            systemImage: recent.collection.kind == .album ? "square.stack" : "music.mic",
            groupKey: recent.groupKey,
            reservedPlaylistID: recent.collection.reservedPlaylistID,
            songs: songs,
            filterFields: recent.collection.kind == .album ? .title : .titleOrAlbum,
            showsRowArtwork: recent.collection.kind != .album
        ) {
            ArtworkView(urlString: recent.artworkURLTemplate, pixelSize: 512,
                        playlistID: recent.collection.reservedPlaylistID, cornerRadius: 16)
        } onPlay: { song in
            await playbackController.playRecent(recent, startingAt: song?.catalogID, context: modelContext)
        } onMove: { song, toOneTruePlaylist in
            await move(song, toOneTruePlaylist: toOneTruePlaylist)
        }
        .onAppear { shellPlace?.destination = .recent(recent.id) }
        .task(id: reloadKey) {
            songs = RecentCollectionPresentation.songs(for: recent, in: modelContext)
        }
    }

    private func move(_ song: RecentCollectionPresentation.Song, toOneTruePlaylist: Bool) async {
        await playbackController.moveRecentSong(catalogID: song.catalogID, in: recent,
                                                toOneTruePlaylist: toOneTruePlaylist, context: modelContext)
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
