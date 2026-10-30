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
    @Environment(\.miniPlayerTop) private var miniPlayerTop

    /// The lead artwork's side, fitted so the first heading under it shows
    /// above the mini player; nil until measured.
    @State private var fittedLeadArtworkSide: CGFloat?
    @State private var listFrame: CGRect = .zero
    @State private var listSafeBottom: CGFloat = 0
    @State private var isScrolledToTop = true
    @State private var firstHeadingBottom: CGFloat?
    @State private var hasVerticalBar = false

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
                            detail: OneTruePlaylistStatus.make(settings).waitsForAnotherDevice
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
                    // The same margins as the Inbox row above. With the system's
                    // own, Retired sat further left than the Inbox on an open
                    // iPhone Duo's left half (2026-10-26).
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                }
            }

            let recents = RecentCollectionRepository.distinct(recentRecords)
            if !recents.isEmpty {
                Section {
                    Text("Recent Deep Dives")
                        .font(.headline)
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: {
                            firstHeadingBottom = $0
                            fitLeadArtwork()
                        }
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
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { bottom in
                        guard RecentCollectionRepository.distinct(recentRecords).isEmpty else { return }
                        firstHeadingBottom = bottom
                        fitLeadArtwork()
                    }
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
                    // The same margins as the "Library" heading and the Inbox
                    // and Retired rows: mixed with the system's own, rows sat
                    // apart on an open iPhone Duo's left half.
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                }
            }
        }
        .listStyle(.plain)
        .onGeometryChange(for: [CGFloat].self) { proxy in
            let frame = proxy.frame(in: .global)
            return [frame.minX, frame.minY, frame.width, frame.height, frame.maxY - proxy.safeAreaInsets.bottom]
        } action: { values in
            listFrame = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
            listSafeBottom = values[4]
            fitLeadArtwork()
        }
        // Measured only at rest: scrolled, the heading has moved up.
        .onScrollGeometryChange(for: Bool.self) { abs($0.contentOffset.y + $0.contentInsets.top) < 1 } action: { _, atTop in
            isScrolledToTop = atTop
            fitLeadArtwork()
        }
        .onChange(of: miniPlayerTop) { fitLeadArtwork() }
        .miniPlayerScrollContentInset()
        .onAppear { shellPlace?.destination = .dashboard }
        .navigationTitle("Overplay")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(VerticalBarReader(hasVerticalBar: $hasVerticalBar))
        .toolbar {
            // Search heads a vertical bar (iPhone Duo), whose items run from
            // the leading ones; otherwise it is the trailing button.
            if hasVerticalBar {
                ToolbarItem(placement: .topBarLeading) { searchButton }
            }
            ToolbarItem(placement: .topBarLeading) {
                // A title as well as a symbol: a vertical bar's overflow menu
                // (iPhone Duo) lists items by title. A Mac opens its own window.
                if ProcessInfo.processInfo.isMacCatalystApp {
                    Button {
                        SettingsWindowView.open(with: openWindow)
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .untinted()
                } else {
                    NavigationLink {
                        SettingsView(settings: settings)
                            .nowPlayingColumnToggle()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .untinted()
                }
            }
            // A Mac reaches History from its Go menu.
            if !ProcessInfo.processInfo.isMacCatalystApp {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        HistoryView()
                            .nowPlayingColumnToggle()
                    } label: {
                        Label("History", systemImage: "clock.arrow.circlepath")
                    }
                    .untinted()
                }
            }
            if !hasVerticalBar {
                ToolbarItem(placement: .topBarTrailing) { searchButton }
            }
        }
    }

    private var searchButton: some View {
        NavigationLink {
            SearchMusicView()
                .nowPlayingColumnToggle()
        } label: {
            Label("Search", systemImage: "magnifyingglass")
        }
        .accessibilityIdentifier("dashboard-search")
        .buttonStyle(.glassProminent)
    }

    /// The One True Playlist leads the screen as artwork over its track count,
    /// as large as leaves the first heading under it readable above the mini
    /// player (or the screen's bottom), up to a collection's artwork size.
    private var leadArtworkSide: CGFloat {
        fittedLeadArtworkSide ?? (PlayerPlacement(horizontalSizeClass, verticalSizeClass) == .sheet
            ? DashboardLayout.compactLeadArtworkSide
            : DashboardLayout.regularLeadArtworkSide)
    }

    /// The heading moves with the artwork point for point, so one
    /// measurement finds the side that puts it at the limit.
    private func fitLeadArtwork() {
        guard isScrolledToTop, let firstHeadingBottom, listFrame.width > 0 else { return }
        let bottom = (miniPlayerTop ?? listSafeBottom) - DashboardLayout.headingMargin
        let widest = min(DashboardLayout.maxLeadArtworkSide, listFrame.width - 32)
        let side = min(max(leadArtworkSide + bottom - firstHeadingBottom, DashboardLayout.minLeadArtworkSide), widest).rounded(.down)
        guard abs(side - leadArtworkSide) >= 1 else { return }
        fittedLeadArtworkSide = side
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
    /// A collection's own artwork is no larger.
    static let maxLeadArtworkSide: CGFloat = 420
    static let minLeadArtworkSide: CGFloat = 120
    /// The gap between the first heading under the artwork and the mini
    /// player.
    static let headingMargin: CGFloat = 8
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
            // The inbox, not the collage; the green play arrow while Triage
            // plays, as Retired.
            Image(systemName: summary.isCurrentPlaybackPlaylist ? summary.iconIntent.systemImage : "tray")
                .foregroundStyle(summary.isCurrentPlaybackPlaylist ? .green : .teal)
        }
        .accessibilityValue(summary.isCurrentPlaybackPlaylist ? "Now playing" : "")
    }
}
