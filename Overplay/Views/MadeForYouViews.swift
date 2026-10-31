@preconcurrency import MusicKit
import SwiftData
import SwiftUI

/// Apple Music's Made For You playlists as one horizontally scrolling row of
/// artwork, as Recent Deep Dives are (`MFY-001`).
struct MadeForYouRowView: View {
    var items: [MadeForYouLibrary.Item]

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(items) { item in
                    NavigationLink(value: AppShellDestination.madeForYou(item.id)) {
                        MadeForYouTileView(item: item)
                    }
                    .buttonStyle(.plain)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
    }
}

struct MadeForYouTileView: View {
    @Environment(PlaybackController.self) private var playbackController

    var item: MadeForYouLibrary.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                ArtworkView(urlString: item.artworkURL, pixelSize: 256,
                            playlistID: item.collection.reservedPlaylistID, cornerRadius: 10)
                    .frame(width: RecentTileView.side, height: RecentTileView.side)

                if isPlaying {
                    NowPlayingBadgeView(diameter: 28)
                        .padding(4)
                }
            }

            // The section's heading already says Made For You.
            Text(item.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .frame(width: RecentTileView.side)
        .accessibilityElement(children: .combine)
    }

    private var isPlaying: Bool {
        playbackController.currentTrack != nil && playbackController.playingCollectionGroupKey == item.collection.groupKey
    }
}

/// A Made For You playlist's songs, played like a deep dive but never added
/// to Recent Deep Dives.
struct MadeForYouPlaylistView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PlaybackController.self) private var playbackController
    @Environment(\.shellPlace) private var shellPlace

    var item: MadeForYouLibrary.Item

    @State private var entries: [LibraryBrowser.Entry] = []
    @State private var songs: [RecentCollectionPresentation.Song] = []
    @State private var placeholder: String? = "Loading…"

    var body: some View {
        let collection = item.collection
        CollectionSongListView(
            title: item.name,
            subtitle: "Made For You · \(savedSongs.count == 1 ? "1 song" : "\(savedSongs.count) songs")",
            systemImage: "person.crop.square",
            groupKey: collection.groupKey,
            reservedPlaylistID: collection.reservedPlaylistID,
            songs: songs,
            placeholder: placeholder
        ) {
            ArtworkView(urlString: item.artworkURL, pixelSize: 512,
                        playlistID: collection.reservedPlaylistID, cornerRadius: 16)
        } onPlay: { song in
            await MadeForYouLibrary.play(item, entries: entries, startingAt: song?.catalogID,
                                         controller: playbackController, context: modelContext)
        } onMove: { song, toOneTruePlaylist in
            guard let saved = savedSongs.first(where: { $0.catalogID == song.catalogID }) else { return }
            await playbackController.moveCollectionSong(saved, toOneTruePlaylist: toOneTruePlaylist, context: modelContext)
        }
        .onAppear { shellPlace?.destination = .madeForYou(item.id) }
        .task {
            guard entries.isEmpty else { return }
            do {
                entries = try await MadeForYouLibrary.songs(in: item)
                placeholder = entries.isEmpty ? "No songs Overplay can play." : nil
            } catch {
                placeholder = "Couldn't load the songs: \(UserFacingError.message(for: error))"
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

    private var rowID: UUID {
        UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    }
}

#Preview {
    NavigationStack {
        MadeForYouRowView(items: [
            .init(id: "pl.pm-1", name: "Favourites Mix"),
            .init(id: "pl.pm-2", name: "New Music Mix"),
        ])
    }
    .environment(PlaybackController())
    .modelContainer(PreviewContainer.make())
}

/// Every Made For You mix as a grid of artwork, as Deep Dives shows Recent
/// Deep Dives (`MFY-001`): the sidebar's way to them.
struct MadeForYouGridView: View {
    @Environment(\.shellPlace) private var shellPlace

    var body: some View {
        let items = MadeForYouLibrary.shared.items
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: RecentTileView.side), spacing: 18)], alignment: .leading, spacing: 22) {
                ForEach(items) { item in
                    NavigationLink(value: AppShellDestination.madeForYou(item.id)) {
                        MadeForYouTileView(item: item)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView("No Mixes Yet", systemImage: "person.crop.square",
                    description: Text("Apple Music's mixes for you appear here."))
            }
        }
        .miniPlayerScrollContentInset()
        .navigationTitle("Made For You")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { shellPlace?.destination = .madeForYouAll }
        .task { await MadeForYouLibrary.shared.refresh() }
    }
}
