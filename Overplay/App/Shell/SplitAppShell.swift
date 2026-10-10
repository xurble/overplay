import OSLog
import SwiftData
import SwiftUI

struct SplitAppShell: View {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Overplay", category: "Layout")
    @Environment(PlaybackController.self) private var playbackController
    @Environment(\.shellPlace) private var shellPlace
    @Query(sort: \PlaylistRecord.name) private var playlists: [PlaylistRecord]

    var settings: OverplaySettings
    /// The compact shell's screen when this one replaced it, opened on appear.
    @State private var placeOnOpen: AppShellDestination?

    @SceneStorage("overplay.splitSelection") private var storedSelection = AppShellDestination.dashboard.storageValue
    @SceneStorage("overplay.showsNowPlayingColumn") private var showsNowPlaying = true
    @State private var totalWidth: CGFloat = 0
    @State private var totalHeight: CGFloat = 0
    /// Where a vertical fold crosses this view, on a folding phone.
    @State private var foldX: CGFloat?
    /// Where a horizontal fold crosses this view, from its top.
    @State private var foldY: CGFloat?
    /// Narrow: whether the sidebar has been slid over the list. Wide: the
    /// split view's own choice. Visibility is derived from the width each
    /// time it is read, so a rotation never leaves a stale value behind.
    @State private var narrowSidebarShown = false
    @State private var wideVisibility: NavigationSplitViewVisibility = .all
    @State private var detailPath = NavigationPath()

    init(settings: OverplaySettings, place: AppShellDestination?) {
        self.settings = settings
        _placeOnOpen = State(initialValue: place)
    }

    var body: some View {
        // The split view stays the window's root container, which navigation
        // needs; it is inset by the player's width and the player is drawn in
        // that space, beside the sidebar and list, never over them.
        splitView
            .padding(.trailing, showsPlayerColumn && !isStackedAtFold ? nowPlayingWidth + 1 : 0)
            .padding(.top, isStackedAtFold ? (foldY ?? 0) + 1 : 0)
            .overlay(alignment: isStackedAtFold ? .top : .trailing) {
                if isStackedAtFold, let foldY {
                    // Open in portrait: the player fills the half above the
                    // fold (its art background under the status bar) and the
                    // list the half below.
                    VStack(spacing: 0) {
                        NowPlayingColumnView(
                            settings: settings,
                            isSideBySide: true,
                            artworkOnTrailing: PhoneTurn.shared.isClockwise
                        )
                            .frame(height: foldY)
                        Divider()
                    }
                } else if showsPlayerColumn {
                    HStack(spacing: 0) {
                        Divider()
                        if isSplitAtFold {
                            // Open as a book, laid out exactly as the closed
                            // phone's full-screen player: centred on its half
                            // across the vertical bar, inside the safe area,
                            // with the same spacing. Never animated, so it is
                            // in place as the unfolded screen activates.
                            NowPlayingColumnView(
                                settings: settings,
                                bottomPadding: FullScreenPlayerView.bottomPadding,
                                transportPillGap: FullScreenPlayerView.transportPillGap
                            )
                            .modifier(UnderVerticalBar())
                            .frame(width: nowPlayingWidth)
                            .transaction { $0.animation = nil }
                        } else {
                            NowPlayingColumnView(settings: settings)
                                .frame(width: nowPlayingWidth)
                        }
                    }
                    // Top and bottom only: a vertical bar (iPhone Duo) can
                    // take the trailing edge, and the controls must clear it.
                    // Open as a book the bars are at the side and the bottom
                    // is kept, as when closed; the top inset changes as the
                    // screen activates, which settled the art into place.
                    .ignoresSafeArea(edges: isSplitAtFold ? .top : .vertical)
                    .transition(.move(edge: .trailing))
                }
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { totalWidth = $0.width; totalHeight = $0.height }
            .onGeometryChange(for: CGFloat?.self) { Self.foldX(in: $0) } action: { foldX = $0 }
            .onGeometryChange(for: CGFloat?.self) { Self.foldY(in: $0) } action: { foldY = $0 }
            .onChange(of: "\(showsPlayerColumn) \(isStackedAtFold) \(Int(totalWidth)) \(Int(nowPlayingWidth))", initial: true) { _, state in
                Self.logger.info("Now Playing column shown/stacked/total/column: \(state, privacy: .public)")
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
                        if !isPinnedAtFold {
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
        }
        .onChange(of: storedSelection) { _, newValue in
            Self.logger.info("Sidebar selection: \(newValue, privacy: .public)")
            detailPath = NavigationPath()
            shellPlace?.destination = selectedDestination
        }
        .onAppear {
            guard let placeOnOpen else { return }
            self.placeOnOpen = nil
            storedSelection = placeOnOpen.storageValue
        }
        .onChange(of: detailPath.count) { _, count in
            Self.logger.info("Detail navigation depth: \(count, privacy: .public)")
        }
        .modifier(SplitStyle(sidebarOverlaysList: isNarrow))
    }

    private var detailView: some View {
        AppShellDestinationView(destination: selectedDestination, settings: settings) { resolvedID in
            storedSelection = AppShellDestination.playlist(resolvedID).storageValue
        }
    }

    private var isNarrow: Bool { SplitLayoutPolicy.isNarrow(totalWidth) }

    private var isSplitAtFold: Bool { SplitLayoutPolicy.splitsAtFold(totalWidth, foldX: foldX) }

    private var isStackedAtFold: Bool { SplitLayoutPolicy.stacksAtFold(totalHeight, foldY: foldY) }

    /// Open on a fold, the player keeps its half and cannot be hidden.
    private var isPinnedAtFold: Bool { isSplitAtFold || isStackedAtFold }

    private var showsPlayerColumn: Bool { showsNowPlaying || isPinnedAtFold }

    private var nowPlayingWidth: CGFloat { SplitLayoutPolicy.playerWidth(for: totalWidth, foldX: foldX) }

    /// The fold of an open folding phone, also while it lies flat, so the
    /// columns stay put as the hinge moves.
    nonisolated private static func foldX(in proxy: GeometryProxy) -> CGFloat? {
        foldFrame(in: proxy) { $0.height > $0.width }?.midX
    }

    nonisolated private static func foldY(in proxy: GeometryProxy) -> CGFloat? {
        foldFrame(in: proxy) { $0.width > $0.height }?.midY
    }

    nonisolated private static func foldFrame(in proxy: GeometryProxy, where matches: (CGRect) -> Bool) -> CGRect? {
        guard #available(iOS 27.1, *) else { return nil }
        return proxy.reservedRegions(kind: .division, options: .includeInactive)
            .map(\.frame).first(where: matches)
    }

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
