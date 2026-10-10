import SwiftData
import SwiftUI

/// The 10 most recent albums and artists as one horizontally scrolling row
/// of artwork (`PLAY-019`).
struct RecentsRowView: View {
    var recents: [RecentCollectionRecord]

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(recents) { recent in
                    NavigationLink {
                        RecentCollectionView(recent: recent)
                            .nowPlayingColumnToggle()
                    } label: {
                        RecentTileView(recent: recent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("recent-\(recent.title)")
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
    }
}

struct RecentTileView: View {
    @Environment(PlaybackController.self) private var playbackController

    var recent: RecentCollectionRecord

    static let side: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                ArtworkView(urlString: recent.artworkURLTemplate, pixelSize: 256,
                            playlistID: recent.collection.reservedPlaylistID,
                            cornerRadius: recent.collection.kind == .album ? 10 : Self.side / 2)
                    .frame(width: Self.side, height: Self.side)

                if RecentCollectionPresentation.isPlaying(recent, controller: playbackController) {
                    Image(systemName: "play.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(.green, in: Circle())
                }
            }

            Text(recent.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(recent.collection.kind == .album ? "Album" : "Artist")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: Self.side)
        .accessibilityElement(children: .combine)
    }
}

/// A tile's exact footprint without a recent, for layouts that reserve room
/// for the Recent Deep Dives row before it exists.
struct RecentTilePlaceholderView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear.frame(width: RecentTileView.side, height: RecentTileView.side)
            Text(verbatim: " ").font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(verbatim: " ").font(.caption)
        }
        .frame(width: RecentTileView.side)
    }
}

#Preview {
    let container = PreviewContainer.make()
    let context = container.mainContext
    for (index, title) in ["Laid", "James", "Whiplash"].enumerated() {
        try? RecentCollectionRepository.record(
            PlaybackCollection(kind: index == 1 ? .artistEssentials : .album, catalogID: "\(index)", title: title),
            songs: [PlaybackCollectionSong(catalogID: "s\(index)", title: "Song", artistName: "James")],
            artworkURLTemplate: nil, in: context
        )
    }
    return NavigationStack {
        RecentsRowView(recents: (try? RecentCollectionRepository.recents(in: context)) ?? [])
    }
    .environment(PlaybackController())
    .modelContainer(container)
}
