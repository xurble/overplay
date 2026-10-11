import SwiftData
import SwiftUI

/// A collection's songs, played like a playlist: a Recents entry
/// (`PLAY-019`), or a playlist, album, artist or the songs in the library.
/// The same header as a playlist (artwork, kind, title, Shuffle and Play),
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
    @ViewBuilder var artwork: () -> Artwork
    /// Shuffle and Play when the song is nil.
    var onPlay: (RecentCollectionPresentation.Song?) async -> Void
    var onMove: (RecentCollectionPresentation.Song, _ toOneTruePlaylist: Bool) async -> Void

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    artwork()
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: 420)

                    VStack(alignment: .leading, spacing: 8) {
                        Label(subtitle, systemImage: systemImage)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(title)
                            .font(.title2.bold())
                    }

                    Button {
                        Task { await onPlay(nil) }
                    } label: {
                        Label("Shuffle and Play", systemImage: "shuffle")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .disabled(songs.isEmpty)
                    .accessibilityIdentifier("recent-shuffle-and-play")

                    if let statusMessage = playbackController.statusMessage {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Songs") {
                if let placeholder, songs.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.secondary)
                }
                ForEach(songs) { song in
                    Button {
                        Task { await onPlay(song) }
                    } label: {
                        PlaylistTrackRowView(
                            summary: song.summary,
                            playlistID: reservedPlaylistID,
                            isCurrent: RecentCollectionPresentation.isCurrent(song, groupKey: groupKey, controller: playbackController)
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 16))
                    .swipeActions(edge: .leading) {
                        if song.canMoveToOneTruePlaylist {
                            Button {
                                Task { await onMove(song, true) }
                            } label: {
                                Label("Overplay", systemImage: "arrow.up.circle")
                            }
                            .tint(.pink)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        if song.canMoveToTriage {
                            Button {
                                Task { await onMove(song, false) }
                            } label: {
                                Label("Triage", systemImage: "tray.fill")
                            }
                            .tint(.green)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
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
