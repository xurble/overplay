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
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var detailPath = NavigationPath()

    var body: some View {
        // The player beside the whole split view, never over it. The detail
        // column's root stays its NavigationStack, so pushes stay in the list.
        HStack(spacing: 0) {
            splitView
            if showsNowPlaying {
                Divider()
                    .ignoresSafeArea()
                NowPlayingColumnView(settings: settings)
                    .frame(width: nowPlayingWidth)
                    .transition(.move(edge: .trailing))
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { totalWidth = $0 }
        .onChange(of: "\(showsNowPlaying) \(Int(totalWidth)) \(Int(nowPlayingWidth))", initial: true) { _, state in
            Self.logger.info("Now Playing column shown/total/column: \(state, privacy: .public)")
        }
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
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
        }
        .onChange(of: storedSelection) { _, _ in
            detailPath = NavigationPath()
        }
        .modifier(SplitStyle(sidebarOverlaysList: isNarrow))
        .onChange(of: isNarrow, initial: true) {
            // Narrow: list and player share the width; the sidebar slides
            // in over the list when asked for.
            columnVisibility = isNarrow ? .detailOnly : .all
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

    /// Below this width (portrait on any iPad, a narrower window, likely an
    /// unfolded phone) three side-by-side columns are too narrow to use.
    private static let narrowWidth: CGFloat = 1100

    private var isNarrow: Bool {
        totalWidth > 0 && totalWidth < Self.narrowWidth
    }

    /// Narrow: 40% of the width, the list taking the other 60%. Wide: a fixed
    /// 380 beside the sidebar and list, narrowed only when they would have
    /// less than 640, never below 280.
    private var nowPlayingWidth: CGFloat {
        isNarrow ? (totalWidth * 0.4).rounded() : min(380, max(280, totalWidth - 640))
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
