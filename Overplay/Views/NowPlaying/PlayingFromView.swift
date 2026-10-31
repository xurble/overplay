import SwiftData
import SwiftUI

/// What is playing, under the progress bar: the playlist, the Inbox, Retired,
/// or the album, artist, mix or search it came from. Tapping it opens that
/// screen when there is one and it is not already showing.
struct PlayingFromView: View {
    @Environment(PlaybackController.self) private var playbackController
    @Environment(\.modelContext) private var modelContext
    @Environment(\.shellPlace) private var shellPlace
    @Environment(\.shellNavigator) private var shellNavigator

    var foreground: Color = .secondary

    var body: some View {
        if let source {
            Button {
                guard let destination = source.destination, shellPlace?.destination != destination else { return }
                shellNavigator?.show(destination)
            } label: {
                Text(source.title)
                    .font(.caption)
                    .foregroundStyle(foreground.opacity(0.8))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(source.destination == nil)
            .accessibilityLabel("Playing from \(source.title)")
            .accessibilityHint(source.destination == nil ? "" : "Opens it")
        }
    }

    private var source: (title: String, destination: AppShellDestination?)? {
        if let collection = playbackController.playbackCollection {
            return (collection.contextTitle, destination(for: collection))
        }
        guard let context = playbackController.currentPlaylistContext,
              let playlist = try? PlaylistRepository.playlist(musicPlaylistID: context.musicPlaylistID, in: modelContext)
        else { return nil }
        if context.scope == .retired { return ("Retired", .retired) }
        return (playlist.name, .playlist(playlist.id))
    }

    private func destination(for collection: PlaybackCollection) -> AppShellDestination? {
        switch collection.kind {
        case .album, .artistEssentials, .artistTopSongs:
            let key = collection.groupKey
            let recents = (try? modelContext.fetch(FetchDescriptor<RecentCollectionRecord>(
                predicate: #Predicate { $0.groupKey == key }
            ))) ?? []
            return recents.first.map { .recent($0.id) }
        case .madeForYou: return .madeForYou(collection.catalogID)
        case .librarySongs: return .library(.songs)
        case .libraryPlaylist, .libraryAlbum, .libraryArtist, .searchSong: return nil
        }
    }
}

#Preview {
    PlayingFromView()
        .environment(PlaybackController())
        .modelContainer(PreviewContainer.make())
}
