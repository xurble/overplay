@preconcurrency import MusicKit
import SwiftData
import SwiftUI

/// Every song in the library by title. Tapping one plays the library from
/// there, as the Music app does, in a window of `windowSize` songs so a large
/// library is never queued whole. A plain list, like Library's other
/// categories: no header and no Shuffle and Play.
/// Not added to Recents.
struct LibrarySongsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PlaybackController.self) private var playbackController

    static let windowSize = 100

    private let cache = LibraryCache.shared
    @State private var songs: [RecentCollectionPresentation.Song] = []

    var body: some View {
        let collection = LibraryBrowser.allSongs
        CollectionSongListView(
            title: "Songs",
            subtitle: "Library · \(savedSongs.count == 1 ? "1 song" : "\(savedSongs.count) songs")",
            systemImage: "music.note",
            groupKey: collection.groupKey,
            reservedPlaylistID: collection.reservedPlaylistID,
            songs: songs,
            placeholder: placeholder,
            showsHeader: false
        ) {
            EmptyView()
        } onPlay: { song in
            let window = window(from: song?.catalogID)
            let windowIDs = Set(window.map(\.catalogID))
            let windowTracks = await LibraryBrowser.playableTracks(for: entries.filter { windowIDs.contains($0.song.catalogID) })
            await playbackController.playCollection(collection, songs: window, startingAt: song?.catalogID,
                                                    recordsRecent: false, tracks: windowTracks, context: modelContext)
        } onMove: { song, toOneTruePlaylist in
            guard let saved = savedSongs.first(where: { $0.catalogID == song.catalogID }) else { return }
            await playbackController.moveCollectionSong(saved, toOneTruePlaylist: toOneTruePlaylist, context: modelContext)
        }
        .task { await cache.prepare(.songs) }
        .task(id: reloadKey) {
            songs = RecentCollectionPresentation.songs(savedSongs, rowID: rowID, in: modelContext)
        }
    }

    /// The songs from the tapped one onwards, or a random set to shuffle.
    private func window(from catalogID: String?) -> [PlaybackCollectionSong] {
        guard let catalogID, let index = savedSongs.firstIndex(where: { $0.catalogID == catalogID }) else {
            return Array(savedSongs.shuffled().prefix(Self.windowSize))
        }
        return Array(savedSongs[index...].prefix(Self.windowSize))
    }

    private var entries: [LibraryBrowser.Entry] { cache.songs ?? [] }

    private var savedSongs: [PlaybackCollectionSong] { entries.map(\.song) }

    private var placeholder: String? {
        if let failure = cache.failures[.songs] { return "Couldn't load your songs: \(failure)" }
        if cache.songs == nil { return "Loading…" }
        return entries.isEmpty ? "No songs Overplay can play." : nil
    }

    private var reloadKey: String {
        "\(entries.count)-\(playbackController.playbackItemMetadataVersion)"
    }

    private var rowID: UUID {
        UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    }
}

#Preview {
    NavigationStack {
        LibrarySongsView()
    }
    .environment(PlaybackController())
    .modelContainer(PreviewContainer.make())
}
