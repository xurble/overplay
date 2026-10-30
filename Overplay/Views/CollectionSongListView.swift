import SwiftData
import SwiftUI

/// A collection's songs, played like a playlist: a Recents entry
/// (`PLAY-019`), or a playlist, album, artist or the songs in the library.
/// The same header as a playlist (details, Shuffle and Play, artwork),
/// then the songs; swiping a song right sends it to the One True Playlist and
/// left to Triage.
struct CollectionSongListView<Artwork: View>: View {
    @Environment(PlaybackController.self) private var playbackController

    var title: String
    var subtitle: String
    var systemImage: String
    var groupKey: String
    var reservedPlaylistID: String
    var songs: [RecentCollectionPresentation.Song]
    /// Shown in place of the songs while they load or when none could be.
    var placeholder: String? = nil
    var filterFields: ListFilter.SongFields = .titleOrArtist
    /// Off for Library's Songs, a plain list like Library's other categories.
    var showsHeader = true
    /// Off for an album, whose songs share its artwork.
    var showsRowArtwork = true
    @ViewBuilder var artwork: () -> Artwork
    /// Shuffle and Play when the song is nil.
    var onPlay: (RecentCollectionPresentation.Song?) async -> Void
    var onMove: (RecentCollectionPresentation.Song, _ toOneTruePlaylist: Bool) async -> Void

    @State private var filterText = ""
    @State private var isFiltering = false
    /// The song tapped while its start runs (`RowStartFeedback`).
    @State private var startingSongID: RecentCollectionPresentation.Song.ID?

    var body: some View {
        let shownSongs = songs.filter { filterFields.matches(filterText, $0.summary) }
        List {
            if showsHeader, !isFiltering {
                Section {
                    // The title is the screen's own (owner request, 2026-10-30).
                    ListHeaderView(shuffleTitle: "Shuffle and Play", canShuffle: !songs.isEmpty,
                                   shuffleIdentifier: "recent-shuffle-and-play") {
                        await onPlay(nil)
                    } details: {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } artwork: {
                        artwork()
                            .aspectRatio(1, contentMode: .fit)
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 10)
                    // No lines around the header, and little room before
                    // the songs' heading (owner request, 2026-10-30).
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .id(ListFilter.headerID)
                }
            }

            Section {
                if let placeholder, songs.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.secondary)
                }
                if shownSongs.isEmpty, !songs.isEmpty {
                    ListFilterNoMatchesView()
                }
                ForEach(shownSongs) { song in
                    Button {
                        startingSongID = song.id
                        Task {
                            await onPlay(song)
                            startingSongID = nil
                        }
                    } label: {
                        PlaylistTrackRowView(
                            summary: song.summary,
                            playlistID: reservedPlaylistID,
                            isCurrent: RowStartFeedback.isCurrent(
                                song.id, starting: startingSongID,
                                playing: RecentCollectionPresentation.isCurrent(song, groupKey: groupKey, controller: playbackController)
                            ),
                            showsArtwork: showsRowArtwork
                        )
                        .padding(.vertical, showsRowArtwork ? 0 : 10)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 16))
                    .swipeActions(edge: .leading) {
                        if song.canMoveToOneTruePlaylist {
                            Button {
                                Task { await onMove(song, true) }
                            } label: {
                                SwipeLabel(title: "Overplay", systemImage: "arrow.up.circle")
                            }
                            .accessibilityLabel("Add to One True Playlist")
                            .tint(.pink)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        if song.canMoveToTriage {
                            Button {
                                Task { await onMove(song, false) }
                            } label: {
                                SwipeLabel(title: "Inbox", systemImage: "tray.and.arrow.down")
                            }
                            .accessibilityLabel("Add to the Inbox")
                            .tint(.green)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(0)
        .listFilter(text: $filterText, isPresented: $isFiltering, prompt: filterFields.prompt)
        .miniPlayerScrollContentInset()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        CollectionSongListView(
            title: "Laid", subtitle: "Album · 2 songs", systemImage: "square.stack",
            groupKey: "album:1", reservedPlaylistID: "overplay.collection.album.1", songs: []
        ) {
            Color.gray
        } onPlay: { _ in } onMove: { _, _ in }
    }
    .environment(PlaybackController())
    .modelContainer(PreviewContainer.make())
}
