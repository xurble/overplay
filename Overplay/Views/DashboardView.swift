import SwiftData
import SwiftUI

struct DashboardView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.modelContext) private var modelContext
    @Environment(PlaybackController.self) private var playbackController

    @Query(filter: #Predicate<PlaylistRecord> { $0.isActive }, sort: \PlaylistRecord.name) private var playlists: [PlaylistRecord]
    @Query(sort: \RecentCollectionRecord.lastPlayedAt, order: .reverse) private var recentRecords: [RecentCollectionRecord]
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.shellPlace) private var shellPlace

    var settings: OverplaySettings

    var body: some View {
        let builder = presentationBuilder
        List {
            Section {
                if let oneTruePlaylist {
                    NavigationLink {
                        PlaylistManagementView(settings: settings, playlist: oneTruePlaylist)
                            .nowPlayingColumnToggle()
                    } label: {
                        oneTruePlaylistArtwork(for: oneTruePlaylist, summary: builder.summary(for: oneTruePlaylist))
                    }
                    .navigationLinkIndicatorVisibility(.hidden)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: DashboardLayout.leadArtworkTopInset, leading: 16,
                                              bottom: DashboardLayout.blockSpacing, trailing: 16))
                } else {
                    NavigationLink {
                        OneTruePlaylistCreationView()
                            .nowPlayingColumnToggle()
                    } label: {
                        PlaylistHomeRowView(
                            title: "Make Your One True Playlist",
                            detail: settings.pendingOneTruePlaylistRequestedAt != nil
                                ? "Your iPhone or iPad makes it the next time Overplay opens there."
                                : "Overplay creates it in Apple Music, empty or as a copy of a playlist.",
                            systemImage: "arrow.up.circle",
                            badgeTint: .pink
                        )
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                }
            }

            if let triageBucket {
                let retiredSummary = builder.summary(for: triageBucket, scope: .retired)
                Section {
                    NavigationLink {
                        PlaylistManagementView(settings: settings, playlist: triageBucket)
                            .nowPlayingColumnToggle()
                    } label: {
                        TriageHomeRowView(bucket: triageBucket, summary: builder.summary(for: triageBucket),
                                          sourceCount: triageSourceCount)
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))

                    NavigationLink {
                        PlaylistManagementView(settings: settings, playlist: triageBucket, scope: .retired)
                            .nowPlayingColumnToggle()
                    } label: {
                        Label {
                            Text("Retired")
                        } icon: {
                            Image(systemName: retiredSummary.iconIntent.systemImage)
                                .foregroundStyle(retiredSummary.isCurrentPlaybackPlaylist ? .green : .gray)
                        }
                        // Green says it is playing; VoiceOver hears it.
                        .accessibilityValue(retiredSummary.isCurrentPlaybackPlaylist ? "Now playing" : "")
                    }
                }
            }

            let recents = RecentCollectionRepository.distinct(recentRecords)
            if !recents.isEmpty {
                Section {
                    Text("Recent Deep Dives")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: DashboardLayout.blockSpacing, leading: 16, bottom: 6, trailing: 16))
                    RecentsRowView(recents: recents)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 0, trailing: 0))
                }
            }

            // The library by category, as the Music app shows it: played like
            // a deep dive, never added to Recent Deep Dives.
            Section {
                Text("Library")
                    .font(.headline)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: DashboardLayout.blockSpacing, leading: 16, bottom: 6, trailing: 16))
                ForEach(LibraryBrowser.Category.allCases) { category in
                    NavigationLink {
                        Group {
                            if category == .songs {
                                LibrarySongsView()
                            } else {
                                LibraryCategoryView(category: category)
                            }
                        }
                        .nowPlayingColumnToggle()
                    } label: {
                        Label(category.rawValue, systemImage: category.systemImage)
                    }
                    .accessibilityIdentifier("library-\(category.rawValue)")
                }
            }
        }
        .listStyle(.plain)
        .miniPlayerScrollContentInset()
        .onAppear { shellPlace?.destination = .dashboard }
        .navigationTitle("Overplay")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                // A title as well as a symbol: a vertical bar's overflow menu
                // (iPhone Duo) lists items by title. A Mac opens its own window.
                if ProcessInfo.processInfo.isMacCatalystApp {
                    Button {
                        SettingsWindowView.open(with: openWindow)
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                } else {
                    NavigationLink {
                        SettingsView(settings: settings)
                            .nowPlayingColumnToggle()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SearchMusicView()
                        .nowPlayingColumnToggle()
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .accessibilityIdentifier("dashboard-search")
            }
        }
    }

    /// The One True Playlist leads the screen as artwork over its track count,
    /// at a fixed size.
    private var leadArtworkSide: CGFloat {
        PlayerPlacement(horizontalSizeClass, verticalSizeClass) == .sheet
            ? DashboardLayout.compactLeadArtworkSide
            : DashboardLayout.regularLeadArtworkSide
    }

    private func oneTruePlaylistArtwork(for playlist: PlaylistRecord, summary: PlaylistSummaryPresentation) -> some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                PlaylistCollageThumbnailView(playlist: playlist)
                    .frame(width: leadArtworkSide, height: leadArtworkSide)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                if isPlaying(summary) {
                    NowPlayingBadgeView(diameter: 30)
                        .padding(6)
                }
            }
            .overlay {
                if !isPlaying(summary) {
                    playButton(for: playlist, summary: summary)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(playlist.name)

            OneTruePlaylistTrackCountView(playlist: playlist)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isPlaying(summary) ? "Now playing" : "")
    }

    /// The One True Playlist is what is audible now.
    private func isPlaying(_ summary: PlaylistSummaryPresentation) -> Bool {
        summary.isCurrentPlaybackPlaylist && playbackController.isPlaying
    }

    /// A glass Play over the artwork while the One True Playlist is not
    /// playing: it resumes the playlist when it is the paused context, and
    /// otherwise starts it, through the shared playback actions.
    private func playButton(for playlist: PlaylistRecord, summary: PlaylistSummaryPresentation) -> some View {
        Button {
            Task {
                if summary.isCurrentPlaybackPlaylist {
                    await playbackController.play(context: modelContext)
                } else {
                    await playbackController.playPlaylist(playlist, scope: .active, settings: settings, context: modelContext)
                }
            }
        } label: {
            Image(systemName: "play.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 59, height: 59)
                .glassEffect(.clear.interactive(), in: Circle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Play \(playlist.name)")
    }

    private func badgeTint(for summary: PlaylistSummaryPresentation, role: PlaylistRole) -> Color {
        DashboardBadge.tint(for: summary, role: role)
    }

    private var oneTruePlaylist: PlaylistRecord? {
        if let playlistID = settings.selectedPlaylistID,
           let playlist = playlists.first(where: { $0.musicPlaylistID == playlistID && $0.role == .oneTruePlaylist && $0.isActive }) {
            return playlist
        }

        return playlists.first { $0.role == .oneTruePlaylist && $0.isActive }
    }

    private var triageBucket: PlaylistRecord? {
        return playlists.first { $0.isTriageBucket }
    }

    private var triageSourceCount: Int {
        playlists.filter { $0.role == .triageSource && $0.isActive }.count
    }

    private var presentationBuilder: PlaylistPresentationBuilder {
        PlaylistPresentationBuilder(
            playlists: playlists,
            // No items: the dashboard shows only the Triage count, which its
            // row queries itself, so a redraw never fetches every item.
            items: [],
            tracks: [],
            playingContext: playbackController.playingPlaylistContext,
            // Nothing here shows a track's artwork, so skip the track lookups.
            includesArtwork: false
        )
    }

}

#Preview {
    NavigationStack {
        DashboardView(settings: OverplaySettings(selectedPlaylistID: "preview-playlist", selectedPlaylistName: "Overplay"))
    }
    .environment(PlaybackController())
    .modelContainer(PreviewContainer.make())
}

private enum DashboardLayout {
    /// The gap under the lead artwork, above Recent Deep Dives, and between
    /// the last row and the mini player.
    static let blockSpacing: CGFloat = 14
    static let leadArtworkTopInset: CGFloat = 8
    /// The lead artwork's side where the player is a sheet (iPhone), and
    /// everywhere else.
    static let compactLeadArtworkSide: CGFloat = 180
    static let regularLeadArtworkSide: CGFloat = 288
}

private enum DashboardBadge {
    static func tint(for summary: PlaylistSummaryPresentation, role: PlaylistRole) -> Color {
        if summary.isCurrentPlaybackPlaylist { return .green }
        return role == .oneTruePlaylist ? .pink : .teal
    }
}

/// The count under the lead artwork. Like the Triage row, it queries only the
/// playlist's active items, so the count stays live without the dashboard
/// fetching every playlist item.
private struct OneTruePlaylistTrackCountView: View {
    @Query private var activeItems: [PlaylistItemRecord]

    init(playlist: PlaylistRecord) {
        let playlistID = playlist.id
        _activeItems = Query(filter: #Predicate<PlaylistItemRecord> { $0.playlistID == playlistID && $0.evictedAt == nil })
    }

    var body: some View {
        Text(PlaylistSummaryPresentation.trackCountLabel(activeItems.count))
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }
}

/// The Triage row. It queries only the bucket's active items, so the count
/// stays live without the dashboard fetching every playlist item.
private struct TriageHomeRowView: View {
    @Query private var activeItems: [PlaylistItemRecord]
    var bucket: PlaylistRecord
    var summary: PlaylistSummaryPresentation
    var sourceCount: Int

    init(bucket: PlaylistRecord, summary: PlaylistSummaryPresentation, sourceCount: Int) {
        self.bucket = bucket
        self.summary = summary
        self.sourceCount = sourceCount
        let bucketID = bucket.id
        _activeItems = Query(filter: #Predicate<PlaylistItemRecord> { $0.playlistID == bucketID && $0.evictedAt == nil })
    }

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(bucket.name)
                Text(PlaylistSummaryPresentation.triageDetail(trackCount: activeItems.count, sourceCount: sourceCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            // The inbox, not the collage; green while Triage plays, as Retired.
            Image(systemName: "tray.fill")
                .foregroundStyle(summary.isCurrentPlaybackPlaylist ? .green : .teal)
        }
        .accessibilityValue(summary.isCurrentPlaybackPlaylist ? "Now playing" : "")
    }
}
