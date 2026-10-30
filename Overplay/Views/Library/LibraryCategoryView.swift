@preconcurrency import MusicKit
import SwiftUI

/// The user's library playlists, albums or artists, as the Music app lists
/// them. Each opens its songs, played like a deep dive.
struct LibraryCategoryView: View {
    var category: LibraryBrowser.Category

    private let cache = LibraryCache.shared
    @State private var filterText = ""
    @State private var isFiltering = false

    var body: some View {
        let items = cache.items[category] ?? []
        let shownItems = items.filter { item in
            // An album matches its artist too.
            category == .albums
                ? ListFilter.matches(filterText, item.title, item.subtitle)
                : ListFilter.matches(filterText, item.title)
        }
        List {
            if items.isEmpty, let message {
                Text(message)
                    .foregroundStyle(.secondary)
            }
            if shownItems.isEmpty, !items.isEmpty {
                ListFilterNoMatchesView()
            }
            ForEach(shownItems) { item in
                NavigationLink {
                    LibraryCollectionView(item: item)
                        .nowPlayingColumnToggle()
                } label: {
                    LibraryItemRowView(item: item)
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 16))
            }
        }
        .listStyle(.plain)
        .listFilter(text: $filterText, isPresented: $isFiltering, prompt: category == .albums ? "Albums or artists" : category.rawValue)
        .miniPlayerScrollContentInset()
        .navigationTitle(category.rawValue)
        .task { await cache.prepare(category) }
    }

    private var message: String? {
        if let failure = cache.failures[category] {
            return "Couldn't load your \(category.rawValue.lowercased()): \(failure)"
        }
        if !cache.hasContent(category) || cache.refreshing.contains(category) { return "Loading…" }
        return "No \(category.rawValue.lowercased()) in your library."
    }
}

/// Drawn as a playlist's track rows are: full-height square artwork flush
/// to the edge, a headline title and a caption subtitle.
struct LibraryItemRowView: View {
    var item: LibraryBrowser.Item

    var body: some View {
        HStack(spacing: 12) {
            LibraryArtworkView(artwork: item.artwork, side: 72, cornerRadius: 0)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(1)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
    }
}

/// Library artwork through Overplay's artwork cache, as Library's: under
/// pressure it goes before Overplay's own. A known background colour shows
/// until the image does.
struct LibraryArtworkView: View {
    var artwork: Artwork?
    var side: CGFloat
    var isRound = false
    var cornerRadius: CGFloat?

    var body: some View {
        // A thumbnail-sized image for rows: a tenth of the download.
        let pixels = side <= 96 ? 160 : 512
        ArtworkView(
            urlString: artwork?.url(width: pixels, height: pixels)?.absoluteString,
            pixelSize: side <= 96 ? 128 : 512,
            playlistID: ArtworkCacheService.libraryPlaylistID,
            cornerRadius: isRound ? side / 2 : (cornerRadius ?? side * 0.12)
        )
        .frame(width: side, height: side)
    }
}

#Preview {
    NavigationStack {
        LibraryCategoryView(category: .albums)
    }
    .environment(PlaybackController())
}
