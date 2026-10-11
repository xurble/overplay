@preconcurrency import MusicKit
import SwiftData
import SwiftUI

/// Every song in the library by title. Tapping one plays the library from
/// there, as the Music app does, in a window of `windowSize` songs so a large
/// library is never queued whole; Shuffle and Play shuffles a random window.
/// Not added to Recents.
struct LibrarySongsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PlaybackController.self) private var playbackController

    static let windowSize = 100

    @State private var entries: [LibraryBrowser.Entry] = []
    @State private var songs: [RecentCollectionPresentation.Song] = []
    @State private var placeholder: String? = "Loading…"

    var body: some View {
        let collection = LibraryBrowser.allSongs
        CollectionSongListView(
            title: "Songs",
            subtitle: "Library · \(savedSongs.count == 1 ? "1 song" : "\(savedSongs.count) songs")",
            systemImage: "music.note",
            groupKey: collection.groupKey,
            reservedPlaylistID: collection.reservedPlaylistID,
            songs: songs,
            placeholder: placeholder
        ) {
            Image(systemName: "music.note")
                .font(.system(size: 120))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary, in: .rect(cornerRadius: 16))
        } onPlay: { song in
            let window = window(from: song?.catalogID)
            let windowTracks = tracks.filter { id, _ in window.contains { $0.catalogID == id } }
            await playbackController.playCollection(collection, songs: window, startingAt: song?.catalogID,
                                                    recordsRecent: false, tracks: windowTracks, context: modelContext)
        } onMove: { song, toOneTruePlaylist in
            guard let saved = savedSongs.first(where: { $0.catalogID == song.catalogID }) else { return }
            await playbackController.moveCollectionSong(saved, toOneTruePlaylist: toOneTruePlaylist, context: modelContext)
        }
        .task {
            guard entries.isEmpty else { return }
            do {
                entries = try await LibraryBrowser.allLibrarySongs()
                placeholder = entries.isEmpty ? "No songs Overplay can play." : nil
            } catch {
                placeholder = "Couldn't load your songs: \(error.localizedDescription)"
            }
        }
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

    private var savedSongs: [PlaybackCollectionSong] { entries.map(\.song) }

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

#Preview {
    NavigationStack {
        LibrarySongsView()
    }
    .environment(PlaybackController())
    .modelContainer(PreviewContainer.make())
}
