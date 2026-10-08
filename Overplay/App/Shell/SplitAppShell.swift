import SwiftData
import SwiftUI

struct SplitAppShell: View {
    @Environment(PlaybackController.self) private var playbackController
    @Query(sort: \PlaylistRecord.name) private var playlists: [PlaylistRecord]

    var settings: OverplaySettings

    @SceneStorage("overplay.splitSelection") private var storedSelection = AppShellDestination.dashboard.storageValue
    @SceneStorage("overplay.showsNowPlayingColumn") private var showsNowPlaying = true
    @SceneStorage("overplay.nowPlayingColumnWidth") private var nowPlayingWidth = 380.0
    @State private var detailWidth: CGFloat = 0
    @State private var detailPath = NavigationPath()

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                Section {
                    Label("Dashboard", systemImage: "rectangle.grid.2x2")
                        .tag(AppShellDestination.dashboard)
                    Label("Search", systemImage: "magnifyingglass")
                        .tag(AppShellDestination.search)
                    Label("History", systemImage: "clock.arrow.circlepath")
                        .tag(AppShellDestination.history)
                    Label("Settings", systemImage: "gearshape")
                        .tag(AppShellDestination.settings)
                }

                Section("Playlists") {
                    ForEach(activePlaylists) { playlist in
                        Label(playlist.name, systemImage: playlistIcon(for: playlist))
                            .tag(AppShellDestination.playlist(playlist.id))
                    }

                    Label("Retired", systemImage: "archivebox.fill")
                        .tag(AppShellDestination.retired)
                }
            }
            .miniPlayerScrollContentInset()
            .listStyle(.sidebar)
            .navigationTitle("Overplay")
        } detail: {
            // The player beside the list, never over it: one row, resized
            // by dragging the divider between them.
            HStack(spacing: 0) {
                NavigationStack(path: $detailPath) {
                    detailView
                        .toolbar {
                            ToolbarItem(placement: .primaryAction) {
                                Button {
                                    withAnimation(.smooth) { showsNowPlaying.toggle() }
                                } label: {
                                    Label(showsNowPlaying ? "Hide Now Playing" : "Show Now Playing", systemImage: "sidebar.trailing")
                                }
                                .help(showsNowPlaying ? "Hide Now Playing" : "Show Now Playing")
                            }
                        }
                }
                if showsNowPlaying {
                    NowPlayingColumnDivider(width: $nowPlayingWidth, range: nowPlayingWidthRange)
                    NowPlayingColumnView(settings: settings)
                        .frame(width: clampedNowPlayingWidth)
                        .transition(.move(edge: .trailing))
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { detailWidth = $0 }
        }
        .onChange(of: storedSelection) { _, _ in
            detailPath = NavigationPath()
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedDestination {
        case .dashboard:
            DashboardView(settings: settings)
        case let .playlist(playlistID):
            if let playlist = resolvedActivePlaylist(for: playlistID) {
                PlaylistManagementView(settings: settings, playlist: playlist)
                    .task(id: playlist.id) {
                        guard playlist.id != playlistID else { return }
                        storedSelection = AppShellDestination.playlist(playlist.id).storageValue
                    }
            } else {
                ContentUnavailableView(
                    "Playlist Unavailable",
                    systemImage: "music.note.list",
                    description: Text("Choose another linked playlist from the sidebar.")
                )
            }
        case .retired:
            if let bucket = activePlaylists.first(where: \.isTriageBucket) {
                PlaylistManagementView(settings: settings, playlist: bucket, scope: .retired)
            } else {
                ContentUnavailableView("No Retired Tracks", systemImage: "archivebox")
            }
        case .search:
            SearchMusicView(settings: settings)
        case .history:
            HistoryView()
        case .settings:
            SettingsView(settings: settings)
        }
    }

    /// The column never squeezes the list below a usable width.
    private var nowPlayingWidthRange: ClosedRange<CGFloat> {
        let minimum: CGFloat = 280
        let maximum = max(minimum, detailWidth - NowPlayingColumnDivider.minimumListWidth)
        return minimum...maximum
    }

    private var clampedNowPlayingWidth: CGFloat {
        min(max(CGFloat(nowPlayingWidth), nowPlayingWidthRange.lowerBound), nowPlayingWidthRange.upperBound)
    }

    private var activePlaylists: [PlaylistRecord] {
        playlists
            .filter { $0.isActive && $0.role.isPlaybackContext }
            .sorted { left, right in
                if left.role != right.role {
                    return left.role == .oneTruePlaylist
                }
                return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
            }
    }

    private func resolvedActivePlaylist(for playlistID: UUID) -> PlaylistRecord? {
        guard let requestedPlaylist = playlists.first(where: { $0.id == playlistID }) else {
            return nil
        }
        let resolvedPlaylist = PlaylistRepository.canonicalPlaylist(
            for: requestedPlaylist,
            among: playlists
        )
        guard resolvedPlaylist.isActive, resolvedPlaylist.role.isPlaybackContext else {
            return nil
        }
        return resolvedPlaylist
    }

    private func playlistIcon(for playlist: PlaylistRecord) -> String {
        if playbackController.isCurrentPlaylist(playlist) {
            return "play.fill"
        }

        switch playlist.role {
        case .oneTruePlaylist:
            return "arrow.up.circle"
        case .triageBucket:
            return "tray.fill"
        case .triageSource:
            return "music.note.list"
        }
    }

    private var selectedDestination: AppShellDestination {
        AppShellDestination(storageValue: storedSelection) ?? .dashboard
    }

    private var selection: Binding<AppShellDestination?> {
        Binding {
            selectedDestination
        } set: { newSelection in
            detailPath = NavigationPath()
            storedSelection = (newSelection ?? .dashboard).storageValue
        }
    }
}
