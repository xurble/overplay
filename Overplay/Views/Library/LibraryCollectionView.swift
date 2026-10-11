@preconcurrency import MusicKit
import SwiftData
import SwiftUI

/// A library playlist's, album's or artist's songs, played like a deep dive
/// but never added to Recents.
struct LibraryCollectionView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PlaybackController.self) private var playbackController

    var item: LibraryBrowser.Item

    @State private var entries: [LibraryBrowser.Entry] = []
    @State private var songs: [RecentCollectionPresentation.Song] = []
    @State private var placeholder: String? = "Loading…"

    var body: some View {
        let collection = item.collection
        CollectionSongListView(
            title: item.title,
            subtitle: "\(item.kindName) · \(savedSongs.count == 1 ? "1 song" : "\(savedSongs.count) songs")",
            systemImage: LibraryBrowser.Category.allCases.first { $0.rawValue.hasPrefix(item.kindName) }?.systemImage ?? "music.note",
            groupKey: collection.groupKey,
            reservedPlaylistID: collection.reservedPlaylistID,
            songs: songs,
            placeholder: placeholder
        ) {
            LibraryArtworkView(artwork: item.artwork, side: 420, isRound: item.kind == .artist)
        } onPlay: { song in
            await playbackController.playCollection(collection, songs: savedSongs, startingAt: song?.catalogID,
                                                    recordsRecent: false, tracks: tracks, context: modelContext)
        } onMove: { song, toOneTruePlaylist in
            guard let saved = savedSongs.first(where: { $0.catalogID == song.catalogID }) else { return }
            await playbackController.moveCollectionSong(saved, toOneTruePlaylist: toOneTruePlaylist, context: modelContext)
        }
        .task {
            guard entries.isEmpty else { return }
            do {
                entries = try await LibraryBrowser.songs(in: item)
                placeholder = entries.isEmpty ? "No songs Overplay can play." : nil
            } catch {
                placeholder = "Couldn't load the songs: \(error.localizedDescription)"
            }
        }
        .task(id: reloadKey) {
            songs = RecentCollectionPresentation.songs(savedSongs, rowID: rowID, in: modelContext)
        }
    }

    private var savedSongs: [PlaybackCollectionSong] { entries.map(\.song) }

    /// Reloads when the songs or anyone's counts change.
    private var reloadKey: String {
        "\(entries.count)-\(playbackController.playbackItemMetadataVersion)"
    }

    private var tracks: [String: Track] {
        Dictionary(entries.map { ($0.song.catalogID, $0.track) }, uniquingKeysWith: { first, _ in first })
    }

    private var rowID: UUID {
        UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    }
}
