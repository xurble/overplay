@preconcurrency import MusicKit
import SwiftUI

/// The user's library playlists, albums or artists, as the Music app lists
/// them. Each opens its songs, played like a deep dive.
struct LibraryCategoryView: View {
    var category: LibraryBrowser.Category

    @State private var items: [LibraryBrowser.Item] = []
    @State private var message: String?

    var body: some View {
        List {
            if let message, items.isEmpty {
                Text(message)
                    .foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                NavigationLink {
                    LibraryCollectionView(item: item)
                        .nowPlayingColumnToggle()
                } label: {
                    LibraryItemRowView(item: item)
                }
            }
        }
        .listStyle(.plain)
        .miniPlayerScrollContentInset()
        .navigationTitle(category.rawValue)
        .task {
            guard items.isEmpty else { return }
            message = "Loading…"
            do {
                items = try await LibraryBrowser.items(category)
                message = items.isEmpty ? "No \(category.rawValue.lowercased()) in your library." : nil
            } catch {
                message = "Couldn't load your \(category.rawValue.lowercased()): \(error.localizedDescription)"
            }
        }
    }
}

struct LibraryItemRowView: View {
    var item: LibraryBrowser.Item

    var body: some View {
        HStack(spacing: 12) {
            LibraryArtworkView(artwork: item.artwork, side: 52, isRound: isArtist)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var isArtist: Bool { item.kind == .artist }
}

/// Library artwork through MusicKit, which loads library images the app's
/// URL cache cannot; a placeholder when there is none.
struct LibraryArtworkView: View {
    var artwork: Artwork?
    var side: CGFloat
    var isRound = false

    var body: some View {
        Group {
            if let artwork {
                ArtworkImage(artwork, width: side, height: side)
            } else {
                Image(systemName: isRound ? "music.mic" : "music.note")
                    .font(.system(size: side * 0.4))
                    .foregroundStyle(.secondary)
                    .frame(width: side, height: side)
                    .background(.quaternary)
            }
        }
        .clipShape(isRound ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: side * 0.12)))
    }
}

#Preview {
    NavigationStack {
        LibraryCategoryView(category: .albums)
    }
    .environment(PlaybackController())
}
