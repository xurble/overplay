import SwiftData
import SwiftUI

/// Under an album or artist deep dive's header (`PLAY-021`): the artist, on
/// an album's page, then their full albums oldest first, as one
/// horizontally scrolling row like Recent Deep Dives. A tile plays it as a
/// deep dive and opens its page.
struct DeepDiveDiscographyView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PlaybackController.self) private var playbackController

    var collection: PlaybackCollection
    var discography: ArtistDiscography
    /// Shows the Recents page of the tile that started. The page navigates:
    /// a list row cannot hold a navigation destination.
    var onOpen: (RecentCollectionRecord) -> Void

    /// The tile tapped while its start runs.
    @State private var startingTileID: String?

    var body: some View {
        let tiles = DeepDiveDiscographyPresentation.tiles(
            for: collection, discography: discography,
            playingGroupKey: playbackController.currentTrack == nil ? nil : playbackController.playingCollectionGroupKey
        )
        if !tiles.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(DeepDiveDiscographyPresentation.heading(for: collection, discography: discography))
                    .font(.headline)
                    .padding(.horizontal, 16)
                strip(tiles)
            }
            .padding(.bottom, 12)
        }
    }

    private func strip(_ tiles: [DeepDiveDiscographyPresentation.Tile]) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(tiles) { tile in
                    Button {
                        open(tile)
                    } label: {
                        DiscographyTileView(tile: tile, isStarting: startingTileID == tile.id)
                    }
                    .buttonStyle(.plain)
                    .disabled(tile.isThisPage || startingTileID != nil)
                    .accessibilityIdentifier("discography-\(tile.title)")
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
    }

    /// Plays the tile through the shared action, then shows its Recents page.
    private func open(_ tile: DeepDiveDiscographyPresentation.Tile) {
        startingTileID = tile.id
        Task {
            defer { startingTileID = nil }
            guard await playbackController.playDiscographyItem(tile.item, context: modelContext) else { return }
            if let recent = (try? RecentCollectionRepository.recents(in: modelContext))?.first(where: { $0.groupKey == tile.id }) {
                onOpen(recent)
            }
        }
    }
}

private struct DiscographyTileView: View {
    var tile: DeepDiveDiscographyPresentation.Tile
    var isStarting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                ArtworkView(urlString: tile.artworkURL, pixelSize: 256,
                            playlistID: ArtworkCacheService.libraryPlaylistID,
                            cornerRadius: tile.isArtist ? RecentTileView.side / 2 : 10)
                    .frame(width: RecentTileView.side, height: RecentTileView.side)
                    .opacity(tile.isThisPage ? 0.5 : 1)
                    .overlay {
                        if isStarting { ProgressView() }
                    }

                if tile.isPlaying {
                    NowPlayingBadgeView(diameter: 28)
                        .padding(tile.isArtist ? 10 : 4)
                }
            }

            Text(tile.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(tile.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: RecentTileView.side)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    let discography = ArtistDiscography(artistID: "r1", artistName: "James", artistArtworkURL: nil, albums: [
        .init(id: "a1", title: "Gold Mother", releaseDate: Date(timeIntervalSince1970: 643_680_000)),
        .init(id: "a2", title: "Laid", releaseDate: Date(timeIntervalSince1970: 746_668_800)),
        .init(id: "a3", title: "Whiplash", releaseDate: Date(timeIntervalSince1970: 856_396_800))
    ])
    NavigationStack {
        DeepDiveDiscographyView(collection: PlaybackCollection(kind: .album, catalogID: "a2", title: "Laid"),
                                discography: discography) { _ in }
    }
    .environment(PlaybackController())
    .modelContainer(PreviewContainer.make())
}
