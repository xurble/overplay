import OSLog
import SwiftData
import SwiftUI

struct SplitAppShell: View {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Overplay", category: "Layout")
    @Environment(PlaybackController.self) private var playbackController
    @Query(sort: \PlaylistRecord.name) private var playlists: [PlaylistRecord]

    var settings: OverplaySettings

    @SceneStorage("overplay.splitSelection") private var storedSelection = AppShellDestination.dashboard.storageValue
    @SceneStorage("overplay.showsNowPlayingColumn") private var showsNowPlaying = true
    @State private var totalWidth: CGFloat = 0
    /// Narrow: whether the sidebar has been slid over the list. Wide: the
    /// split view's own choice. Visibility is derived from the width each
    /// time it is read, so a rotation never leaves a stale value behind.
    @State private var narrowSidebarShown = false
    @State private var wideVisibility: NavigationSplitViewVisibility = .all
    @State private var detailPath = NavigationPath()

    var body: some View {
        // The split view stays the window's root container, which navigation
        // needs; it is inset by the player's width and the player is drawn in
        // that space, beside the sidebar and list, never over them.
        splitView
            .padding(.trailing, showsNowPlaying ? nowPlayingWidth + 1 : 0)
            .overlay(alignment: .trailing) {
                if showsNowPlaying {
                    HStack(spacing: 0) {
                        Divider()
                        NowPlayingColumnView(settings: settings)
                            .frame(width: nowPlayingWidth)
                    }
                    .ignoresSafeArea()
                    .transition(.move(edge: .trailing))
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { totalWidth = $0 }
            .onChange(of: "\(showsNowPlaying) \(Int(totalWidth)) \(Int(nowPlayingWidth))", initial: true) { _, state in
                Self.logger.info("Now Playing column shown/total/column: \(state, privacy: .public)")
            }
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            List(selection: selection) {
                Section {
                    Label("Dashboard", systemImage: "rectangle.grid.2x2")
                        .tag(AppShellDestination.dashboard)
                        .accessibilityIdentifier("sidebar-dashboard")
                    Label("Search", systemImage: "magnifyingglass")
                        .tag(AppShellDestination.search)
                        .accessibilityIdentifier("sidebar-search")
                    Label("History", systemImage: "clock.arrow.circlepath")
                        .tag(AppShellDestination.history)
                        .accessibilityIdentifier("sidebar-history")
                    Label("Settings", systemImage: "gearshape")
                        .tag(AppShellDestination.settings)
                        .accessibilityIdentifier("sidebar-settings")
                }

                Section("Playlists") {
                    ForEach(activePlaylists) { playlist in
                        Label(playlist.name, systemImage: playlistIcon(for: playlist))
                            .tag(AppShellDestination.playlist(playlist.id))
                            .accessibilityIdentifier("sidebar-playlist-\(playlist.name)")
                    }

                    Label("Retired", systemImage: retiredIcon)
                        .tag(AppShellDestination.retired)
                        .accessibilityIdentifier("sidebar-retired")
                }
            }
            .miniPlayerScrollContentInset()
            .listStyle(.sidebar)
            .navigationTitle("Overplay")
        } detail: {
            NavigationStack(path: $detailPath) {
                detailView
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("detail-\(selectedDestination.storageValue)")
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
        }
        .onChange(of: storedSelection) { _, newValue in
            Self.logger.info("Sidebar selection: \(newValue, privacy: .public)")
            detailPath = NavigationPath()
        }
        .onChange(of: detailPath.count) { _, count in
            Self.logger.info("Detail navigation depth: \(count, privacy: .public)")
        }
        .modifier(SplitStyle(sidebarOverlaysList: isNarrow))
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

    private var isNarrow: Bool { SplitLayoutPolicy.isNarrow(totalWidth) }

    private var nowPlayingWidth: CGFloat { SplitLayoutPolicy.playerWidth(for: totalWidth) }

    /// Narrow: list and player share the width and the sidebar slides in
    /// over the list when asked for. Wide: sidebar, list and player.
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding {
            SplitLayoutPolicy.visibility(isNarrow: isNarrow, narrowSidebarShown: narrowSidebarShown, wideVisibility: wideVisibility)
        } set: { newValue in
            if isNarrow {
                narrowSidebarShown = newValue != .detailOnly
            } else {
                wideVisibility = newValue
            }
        }
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

    private var retiredIcon: String {
        let bucket = activePlaylists.first(where: \.isTriageBucket)
        return playbackController.isPlaying(bucket?.playbackContext(.retired)) ? "play.fill" : "archivebox.fill"
    }

    private func playlistIcon(for playlist: PlaylistRecord) -> String {
        if playbackController.isPlaying(playlist.playbackContext()) {
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
            // Narrow: the sidebar was slid over the list to choose; close it.
            if isNarrow { narrowSidebarShown = false }
        }
    }
}

/// Overlays the sidebar on the list in narrow widths; side by side otherwise.
private struct SplitStyle: ViewModifier {
    var sidebarOverlaysList: Bool

    func body(content: Content) -> some View {
        if sidebarOverlaysList {
            content.navigationSplitViewStyle(.prominentDetail)
        } else {
            content.navigationSplitViewStyle(.automatic)
        }
    }
}
