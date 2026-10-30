import OSLog
import SwiftData
import SwiftUI

struct SplitAppShell: View {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Overplay", category: "Layout")
    @Environment(PlaybackController.self) private var playbackController
    @Environment(\.modelContext) private var modelContext
    @Environment(\.shellPlace) private var shellPlace
    @Environment(\.shellNavigator) private var shellNavigator
    @Query(sort: \PlaylistRecord.name) private var playlists: [PlaylistRecord]

    var settings: OverplaySettings
    /// The compact shell's screen when this one replaced it, opened on appear.
    @State private var placeOnOpen: AppShellDestination?

    @SceneStorage("overplay.splitSelection") private var storedSelection = AppShellDestination.dashboard.storageValue
    /// Remembered across launches; the big player shows by default.
    @AppStorage("overplay.showsNowPlayingColumn") private var showsNowPlaying = true
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
            .padding(.leading, sidebarPanelIsColumn ? sidebarPanelInset : 0)
            .padding(.trailing, showsPlayerColumn && !isStackedAtFold ? nowPlayingWidth + 1 : 0)
            .padding(.bottom, isStackedAtFold ? stackedPlayerHeight + 1 : 0)
            .overlay(alignment: isStackedAtFold ? .bottom : .trailing) {
                if isStackedAtFold {
                    // Open in portrait, or an iPad taller than wide: the list
                    // fills the top half and the player the half below, its
                    // art background under the home indicator (owner request,
                    // 2026-10-30).
                    VStack(spacing: 0) {
                        Divider()
                        NowPlayingColumnView(
                            settings: settings,
                            isSideBySide: true,
                            artworkOnTrailing: foldY != nil && PhoneTurn.shared.isClockwise,
                            isBesideSidebar: showsSidebarPanel
                        )
                            .frame(height: stackedPlayerHeight)
                    }
                } else if showsPlayerColumn {
                    HStack(spacing: 0) {
                        Divider()
                        if isSplitAtFold {
                            // Open as a book (or an iPad wider than tall),
                            // laid out exactly as the closed
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
            // Stacked (portrait), the panel pushes the list and the player
            // aside together, as the column does side by side (owner
            // request, 2026-10-30).
            .padding(.leading, sidebarPanelIsColumn ? 0 : sidebarPanelInset)
            .overlay(alignment: .leading) {
                if showsSidebarPanel {
                    // Halves with the sidebar shown: a column just wide
                    // enough for its choices, sliding in and out; the list
                    // takes the rest beside the player (owner request,
                    // 2026-10-30).
                    HStack(spacing: 0) {
                        Group {
                            if sidebarPanelIsColumn {
                                sidebarList(isPanel: true)
                                    // Clear of the screen's rounded corner.
                                    .contentMargins(.top, 16, for: .scrollContent)
                            } else {
                                // Stacked, the panel carries the sidebar button
                                // at its top right, in a bar of its own so it is
                                // level with the list's (owner request,
                                // 2026-10-30).
                                NavigationStack {
                                    sidebarList(isPanel: true)
                                        .toolbar {
                                            ToolbarItem(placement: .topBarTrailing) {
                                                Button("Hide Sidebar", systemImage: "sidebar.leading") {
                                                    withAnimation(.smooth) { sidebarPanelShown = false }
                                                }
                                                .untinted()
                                            }
                                        }
                                        .navigationBarTitleDisplayMode(.inline)
                                        .containerBackground(.clear, for: .navigation)
                                }
                            }
                        }
                        .frame(width: sidebarPanelWidth)
                        // Glass washed with the playing album's colour, as
                        // the split view's own sidebar is.
                        .background { SidebarPanelBackground() }
                        Divider()
                    }
                    // Follows a leftward swipe and closes past a third.
                    .offset(x: sidebarPanelOffset)
                    .simultaneousGesture(sidebarPanelSwipe)
                    .transition(.move(edge: .leading))
                }
            }
            // Stacked, the keyboard covers the player rather than shortening
            // the shell, which made it side by side for the keyboard's stay
            // (owner request, 2026-10-30).
            .ignoresSafeArea(isStackedAtFold ? .keyboard : [], edges: .bottom)
            .background(alignment: .topLeading) { sidebarLabelMeasure }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { totalWidth = $0.width; totalHeight = $0.height }
            .onGeometryChange(for: CGFloat?.self) { Self.foldX(in: $0) } action: { foldX = $0 }
            .onGeometryChange(for: CGFloat?.self) { Self.foldY(in: $0) } action: { foldY = $0 }
            .onChange(of: "\(showsPlayerColumn) \(isStackedAtFold) \(Int(totalWidth)) \(Int(nowPlayingWidth))", initial: true) { _, state in
                Self.logger.info("Now Playing column shown/stacked/total/column: \(state, privacy: .public)")
            }
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            sidebarList()
                // The panel has its own button (`SidebarPanelToggle`).
                .toolbar(removing: usesSidebarPanel ? .sidebarToggle : nil)
        } detail: {
            // The dashboard is always the root; a sidebar choice is pushed
            // on it, so Back leads home as when the dashboard opened it, with
            // the sidebar shown or hidden.
            NavigationStack(path: $detailPath) {
                destinationView(.dashboard)
                    .navigationDestination(for: AppShellDestination.self) { destination in
                        destinationView(destination)
                    }
            }
            .background { SplitViewSwipeSwitch(presentsWithGesture: !usesSidebarPanel) }
        }
        .onChange(of: shellNavigator?.request) { _, request in
            if let request { show(request.destination) }
        }
        .onChange(of: storedSelection, initial: true) { _, newValue in
            Self.logger.info("Sidebar selection: \(newValue, privacy: .public)")
            showSelectedDestination()
        }
        .onAppear {
            guard let placeOnOpen else { return }
            self.placeOnOpen = nil
            storedSelection = placeOnOpen.storageValue
        }
        .onChange(of: detailPath.count) { _, count in
            Self.logger.info("Detail navigation depth: \(count, privacy: .public)")
            // Back to the root: the sidebar shows the dashboard again. Not
            // while a choice replaces the path, which can pass through empty.
            if count == 0, !isSwitchingDestination, selectedDestination != .dashboard {
                storedSelection = AppShellDestination.dashboard.storageValue
            }
        }
        .modifier(SplitStyle(sidebarOverlaysList: sidebarOverlaysList))
        // On the split view, not the detail stack: pushed screens take their
        // environment from here.
        .environment(\.nowPlayingColumnToggle, columnToggle)
        .environment(\.sidebarPanelToggle, usesSidebarPanel ? SidebarPanelToggle(
            isShown: sidebarPanelShown,
            // Stacked, the panel carries the button while it shows.
            showsButton: sidebarPanelIsColumn || !sidebarPanelShown
        ) {
            withAnimation(.smooth) { sidebarPanelShown.toggle() }
        } : nil)
        .focusedSceneValue(\.shellCommands, shellCommands)
    }

    /// The sidebar's choices: the split view's own sidebar, or the panel
    /// beside the list in halves.
    private func sidebarList(isPanel: Bool = false) -> some View {
        List(selection: selection) {
            Section {
                Label("Dashboard", systemImage: "rectangle.grid.2x2")
                    .tag(AppShellDestination.dashboard)
                    .listRowBackground(isPanel ? Color.clear : nil)
                    .accessibilityIdentifier("sidebar-dashboard")
                Label("Search", systemImage: "magnifyingglass")
                    .tag(AppShellDestination.search)
                    .listRowBackground(isPanel ? Color.clear : nil)
                    .accessibilityIdentifier("sidebar-search")
                // A Mac reaches these from its menus (`OverplayCommands`)
                // and its Settings window.
                if !SplitLayoutPolicy.keepsColumns {
                    Label("History", systemImage: "clock.arrow.circlepath")
                        .tag(AppShellDestination.history)
                        .listRowBackground(isPanel ? Color.clear : nil)
                        .accessibilityIdentifier("sidebar-history")
                    Label("Settings", systemImage: "gearshape")
                        .tag(AppShellDestination.settings)
                        .listRowBackground(isPanel ? Color.clear : nil)
                        .accessibilityIdentifier("sidebar-settings")
                }
            }

            Section("Overplaying") {
                ForEach(activePlaylists) { playlist in
                    Label(playlist.name, systemImage: playlistIcon(for: playlist))
                        .accessibilityValue(playbackController.isPlaying(playlist.playbackContext()) ? "Now playing" : "")
                        .tag(AppShellDestination.playlist(playlist.id))
                        .listRowBackground(isPanel ? Color.clear : nil)
                        .accessibilityIdentifier("sidebar-playlist-\(playlist.name)")
                }

                Label("Retired", systemImage: retiredIcon)
                    .accessibilityValue(isRetiredPlaying ? "Now playing" : "")
                    .tag(AppShellDestination.retired)
                    .listRowBackground(isPanel ? Color.clear : nil)
                    .accessibilityIdentifier("sidebar-retired")

                Label("Deep Dives", systemImage: "square.stack.3d.up")
                    .tag(AppShellDestination.deepDives)
                    .listRowBackground(isPanel ? Color.clear : nil)
                    .accessibilityIdentifier("sidebar-deep-dives")

                // Apple Music's mixes for this account (`MFY-001`), as a grid.
                Label("Made For You", systemImage: "person.crop.square")
                    .tag(AppShellDestination.madeForYouAll)
                    .listRowBackground(isPanel ? Color.clear : nil)
                    .accessibilityIdentifier("sidebar-made-for-you")
            }

            // The Apple Music library by category, as on the phone's
            // dashboard (`LIB-001`).
            Section("Library") {
                ForEach(LibraryBrowser.Category.allCases) { category in
                    Label(category.rawValue, systemImage: category.systemImage)
                        .tag(AppShellDestination.library(category))
                        .listRowBackground(isPanel ? Color.clear : nil)
                        .accessibilityIdentifier("sidebar-library-\(category.rawValue)")
                }
            }
        }
        .miniPlayerScrollContentInset()
        // The panel's list is plain: as a sidebar list outside the split
        // view it drew each section as a card with rounded ends.
        .modifier(SidebarListStyle(isPanel: isPanel))
        .modifier(SidebarArtworkTint())
            // The Mac window has no title bar to fill; its sidebar shows none.
        .navigationTitle(SplitLayoutPolicy.keepsColumns ? "" : "Overplay")
    }

    private func destinationView(_ destination: AppShellDestination) -> some View {
        AppShellDestinationView(destination: destination, settings: settings) { resolvedID in
            storedSelection = AppShellDestination.playlist(resolvedID).storageValue
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail-\(destination.storageValue)")
        .nowPlayingColumnToggle()
    }

    private var isNarrow: Bool { SplitLayoutPolicy.isNarrow(totalWidth) }

    /// The sidebar slides over the list, closing after a choice, unless a
    /// wide Mac window shows it as a column.
    private var sidebarOverlaysList: Bool { isNarrow || isPinnedAtFold }

    /// Side by side in halves, the sidebar is a panel of Overplay's own
    /// beside the list rather than the split view's sidebar over it.
    private var usesSidebarPanel: Bool { (isSplitAtFold || isStackedAtFold) && !SplitLayoutPolicy.keepsColumns }
    /// Side by side, the panel is a column the list makes room for; stacked
    /// (portrait), it runs the full height and pushes the list and the player
    /// aside. Either stays open after a choice.
    private var sidebarPanelIsColumn: Bool { isSplitAtFold }
    /// Side by side, the panel stays as it was left, open at first; stacked
    /// over the player, it starts closed. The stored value is copied into
    /// state, because a stored value's change doesn't animate.
    @AppStorage("overplay.sidebarColumnShown") private var storedSidebarColumnShown = true
    @State private var sidebarColumnShown: Bool?
    @State private var sidebarOverlayShown = false
    @GestureState private var sidebarPanelDrag: CGFloat = 0
    /// The drag at release, held while the panel animates away or back:
    /// the gesture's own value is reset without animation, which popped the
    /// panel back before it slid off.
    @State private var sidebarPanelReleasedDrag: CGFloat = 0
    private var sidebarPanelOffset: CGFloat { min(0, sidebarPanelDrag + sidebarPanelReleasedDrag) }
    /// The room the panel takes from the list, following a swipe.
    private var sidebarPanelInset: CGFloat {
        showsSidebarPanel ? max(0, sidebarPanelWidth + 1 + sidebarPanelOffset) : 0
    }
    private var sidebarPanelShown: Bool {
        get { sidebarPanelIsColumn ? (sidebarColumnShown ?? storedSidebarColumnShown) : sidebarOverlayShown }
        nonmutating set {
            if sidebarPanelIsColumn {
                sidebarColumnShown = newValue
                storedSidebarColumnShown = newValue
            } else {
                sidebarOverlayShown = newValue
            }
        }
    }

    private var sidebarPanelSwipe: some Gesture {
        DragGesture(minimumDistance: 20)
            .updating($sidebarPanelDrag) { value, drag, _ in
                if abs(value.translation.width) > abs(value.translation.height) { drag = value.translation.width }
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                sidebarPanelReleasedDrag = value.translation.width
                let closes = min(value.translation.width, value.predictedEndTranslation.width) < -sidebarPanelWidth / 3
                withAnimation(.smooth) {
                    sidebarPanelReleasedDrag = 0
                    if closes { sidebarPanelShown = false }
                }
            }
    }
    @State private var isSwitchingDestination = false
    @State private var sidebarLabelWidth: CGFloat = 0
    private var showsSidebarPanel: Bool { usesSidebarPanel && sidebarPanelShown }

    /// The widest choice, with the sidebar list's card and row insets on both
    /// sides; 64 wrapped "Deep Dives".
    private var sidebarPanelWidth: CGFloat { (sidebarLabelWidth + 104).rounded() }

    /// Every choice's label at its natural width, unseen, to size the panel.
    private var sidebarLabelMeasure: some View {
        VStack(alignment: .leading) {
            ForEach(sidebarLabelTitles, id: \.self) { title in
                Label(title, systemImage: "music.note.list").fixedSize()
            }
        }
        .font(.body)
        .hidden()
        .accessibilityHidden(true)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { sidebarLabelWidth = $0 }
    }

    private var sidebarLabelTitles: [String] {
        ["Dashboard", "Search", "History", "Settings", "Retired", "Deep Dives", "Overplaying", "Library", "Made For You"]
            + activePlaylists.map(\.name) + LibraryBrowser.Category.allCases.map(\.rawValue)
    }

    private var thirdWidth: CGFloat { (totalWidth / 3).rounded() }

    /// The fold of an open folding phone or, without one, the middle of the
    /// window on iPad; nil on a Mac, which keeps columns.
    private var dividerX: CGFloat? {
        SplitLayoutPolicy.dividingX(width: totalWidth, height: totalHeight, foldX: foldX, foldY: foldY, keepsColumns: SplitLayoutPolicy.keepsColumns)
    }

    private var dividerY: CGFloat? {
        SplitLayoutPolicy.dividingY(width: totalWidth, height: totalHeight, foldX: foldX, foldY: foldY, keepsColumns: SplitLayoutPolicy.keepsColumns)
    }

    private var isSplitAtFold: Bool { SplitLayoutPolicy.splitsAtFold(totalWidth, foldX: dividerX) }

    private var isStackedAtFold: Bool { SplitLayoutPolicy.stacksAtFold(totalHeight, foldY: dividerY) }

    /// Stacked, the player takes everything below the dividing line.
    private var stackedPlayerHeight: CGFloat { max(totalHeight - (dividerY ?? totalHeight), 0) }

    /// Divided in halves, the player keeps its half and cannot be hidden.
    private var isPinnedAtFold: Bool { isSplitAtFold || isStackedAtFold }

    private var showsPlayerColumn: Bool { showsNowPlaying || isPinnedAtFold }

    /// The menu bar's view of this window.
    private var shellCommands: ShellCommands {
        ShellCommands(
            navigate: { selection.wrappedValue = $0 },
            oneTruePlaylist: activePlaylists.first { $0.role == .oneTruePlaylist }.map { .playlist($0.id) },
            triage: activePlaylists.first(where: \.isTriageBucket).map { .playlist($0.id) },
            nowPlaying: columnToggle,
            playPause: { Task { await playbackController.performPrimaryPlaybackAction(settings: settings, context: modelContext) } },
            next: { Task { await playbackController.next(settings: settings, context: modelContext) } },
            previous: { Task { await playbackController.previous(context: modelContext) } }
        )
    }

    /// Divided in halves the player cannot be hidden, so there is no toggle.
    private var columnToggle: NowPlayingColumnToggle? {
        guard !isPinnedAtFold else { return nil }
        return NowPlayingColumnToggle(isShown: showsNowPlaying, settings: settings) {
            withAnimation(.smooth) { showsNowPlaying.toggle() }
        }
    }

    private var nowPlayingWidth: CGFloat {
        showsSidebarPanel && sidebarPanelIsColumn ? thirdWidth : SplitLayoutPolicy.playerWidth(for: totalWidth, foldX: dividerX)
    }

    /// The fold of an open folding phone, also while it lies flat, so the
    /// columns stay put as the hinge moves.
    nonisolated private static func foldX(in proxy: GeometryProxy) -> CGFloat? {
        foldFrame(in: proxy) { $0.height > $0.width }?.midX
    }

    nonisolated private static func foldY(in proxy: GeometryProxy) -> CGFloat? {
        foldFrame(in: proxy) { $0.width > $0.height }?.midY
    }

    nonisolated private static func foldFrame(in proxy: GeometryProxy, where matches: (CGRect) -> Bool) -> CGRect? {
#if targetEnvironment(macCatalyst)
        return nil
#else
        guard #available(iOS 27.1, *) else { return nil }
        return proxy.reservedRegions(kind: .division, options: .includeInactive)
            .map(\.frame).first(where: matches)
#endif
    }

    /// Halves or narrow: list and player share the width and the sidebar
    /// slides in over the list when asked for. Wide Mac: sidebar, list and
    /// player.
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding {
            // The panel stands in for the sidebar: the split view shows only
            // the list, and its sidebar button opens and closes the panel.
            if usesSidebarPanel { return .detailOnly }
            return SplitLayoutPolicy.visibility(isNarrow: sidebarOverlaysList, narrowSidebarShown: narrowSidebarShown, wideVisibility: wideVisibility)
        } set: { newValue in
            if usesSidebarPanel {
                // An edge swipe that asks for the sidebar opens the panel.
                if newValue != .detailOnly { withAnimation(.smooth) { sidebarPanelShown = true } }
            } else if sidebarOverlaysList {
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

    private var isRetiredPlaying: Bool {
        playbackController.isPlaying(activePlaylists.first(where: \.isTriageBucket)?.playbackContext(.retired))
    }

    private var retiredIcon: String {
        isRetiredPlaying ? "arrow.right.circle.fill" : "archivebox"
    }

    private func playlistIcon(for playlist: PlaylistRecord) -> String {
        if playbackController.isPlaying(playlist.playbackContext()) {
            return "arrow.right.circle.fill"
        }

        switch playlist.role {
        case .oneTruePlaylist:
            return "arrow.up.circle"
        case .triageBucket:
            return "tray"
        case .triageSource:
            return "music.note.list"
        }
    }

    private var selectedDestination: AppShellDestination {
        AppShellDestination(storageValue: storedSelection) ?? .dashboard
    }

    /// One sidebar screen at a time: a new choice replaces the last.
    /// Opened from Now Playing: chosen in the sidebar where it has a row,
    /// otherwise pushed on the dashboard.
    private func show(_ destination: AppShellDestination) {
        switch destination {
        case .recent, .madeForYou:
            detailPath = NavigationPath([destination])
            shellPlace?.destination = destination
        default:
            if destination.storageValue == storedSelection {
                showSelectedDestination()
            } else {
                storedSelection = destination.storageValue
            }
        }
    }

    private func showSelectedDestination() {
        let destination = selectedDestination
        isSwitchingDestination = true
        detailPath = destination == .dashboard ? NavigationPath() : NavigationPath([destination])
        shellPlace?.destination = destination
        // A screen pushed by view, not by value, can make the stack drop the
        // new path on the way; put it back once the stack has settled.
        Task { @MainActor in
            if detailPath.isEmpty, destination != .dashboard {
                detailPath = NavigationPath([destination])
            }
            isSwitchingDestination = false
        }
    }

    private var selection: Binding<AppShellDestination?> {
        Binding {
            selectedDestination
        } set: { newSelection in
            let storageValue = (newSelection ?? .dashboard).storageValue
            // Choosing the screen already selected still leaves anything
            // pushed on it, such as a playlist opened from the dashboard.
            if storageValue == storedSelection {
                showSelectedDestination()
            } else {
                storedSelection = storageValue
            }
            // The sidebar was slid over the list to choose; close it. The
            // panel pushes the list aside, so it stays until closed.
            if sidebarOverlaysList, !usesSidebarPanel { narrowSidebarShown = false }
        }
    }
}

/// A faint wash of the playing song's artwork colour behind the sidebar's
/// glass, fainter than the title-bar mini player's; plain glass when nothing
/// is playing.
struct SidebarArtworkTint: ViewModifier {
    /// The Mac's sidebar material swallows a fainter wash.
    static let opacity = ProcessInfo.processInfo.isMacCatalystApp ? 0.32 : 0.16

    func body(content: Content) -> some View {
        ThemedPlayerHost { artworkTheme, _ in
            let wash = artworkTheme.isFallback ? Color.clear : artworkTheme.background.opacity(Self.opacity)
            content
                .scrollContentBackground(.hidden)
                .background { wash.ignoresSafeArea() }
                // The split view's own column background, which a Mac's
                // sidebar draws in place of the list's.
                .containerBackground(wash, for: .navigation)
                // Over a song's colour the app's purple can lose contrast:
                // icons take the text colour, and a Mac's selection grey.
                .tint(artworkTheme.isFallback ? nil : (ProcessInfo.processInfo.isMacCatalystApp ? Color.gray : Color.primary))
        }
    }
}

/// The split view's sidebar list, or a plain one for the panel.
private struct SidebarListStyle: ViewModifier {
    var isPanel: Bool

    func body(content: Content) -> some View {
        if isPanel {
            // Transparent over the panel's tinted glass.
            content.listStyle(.plain).scrollContentBackground(.hidden)
        } else {
            content.listStyle(.sidebar)
        }
    }
}

/// The sidebar panel's backdrop: glass, tinted with the playing song's
/// artwork colour, plain while nothing plays.
private struct SidebarPanelBackground: View {
    var body: some View {
        ThemedPlayerHost { artworkTheme, _ in
            Rectangle()
                .fill(.clear)
                .glassEffect(.regular.tint(artworkTheme.isFallback ? nil : artworkTheme.background.opacity(0.35)), in: .rect)
                .ignoresSafeArea()
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

/// Turns off the split view's own edge swipe while the sidebar panel stands
/// in for its sidebar: the swipe opened the system sidebar beside the panel.
/// SwiftUI has no setting for it, so this reaches the hosting split view
/// controller; if UIKit changes, the swipe simply stays on.
private struct SplitViewSwipeSwitch: UIViewRepresentable {
    var presentsWithGesture: Bool

    func makeUIView(context: Context) -> SwitchView {
        let view = SwitchView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: SwitchView, context: Context) {
        uiView.presentsWithGesture = presentsWithGesture
    }

    final class SwitchView: UIView {
        var presentsWithGesture = true {
            didSet { apply() }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        private func apply() {
            var responder: UIResponder? = next
            while let current = responder {
                if let split = current as? UISplitViewController {
                    if split.presentsWithGesture != presentsWithGesture { split.presentsWithGesture = presentsWithGesture }
                    return
                }
                responder = current.next
            }
        }
    }
}
