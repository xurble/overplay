import SwiftData
import SwiftUI

struct AppRouter: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppRuntime.self) private var runtime
    @Environment(MusicAuthorizationService.self) private var authorizationService
    @Environment(PlaybackController.self) private var playbackController

    @AppStorage("overplay.hasPresentedAuthorizedUI") private var hasPresentedAuthorizedUI = false

    @Query(sort: \OverplaySettings.createdAt) private var settingsRecords: [OverplaySettings]
    @State private var playerSheetDetent: PresentationDetent = .height(96)

    private let playerSheetCollapsedHeight = MiniPlayerLayout.collapsedHeight

    var body: some View {
        Group {
            if shouldShowPermissionView {
                NavigationStack {
                    PermissionView()
                }
            } else if let settings {
                PlatformShell(settings: settings)
                    .onAppear {
                        hasPresentedAuthorizedUI = true
                    }
            } else {
                NavigationStack {
                    ProgressView("Preparing Overplay")
                }
            }
        }
        .sheet(isPresented: playerSheetPresentation) {
            if let settings {
                PlayerSheetView(settings: settings, collapsedHeight: playerSheetCollapsedHeight)
                    .presentationDetents([.height(playerSheetCollapsedHeight), .large], selection: $playerSheetDetent)
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.clear)
                    .presentationBackgroundInteraction(.enabled(upThrough: .height(playerSheetCollapsedHeight)))
                    .presentationContentInteraction(.resizes)
                    .interactiveDismissDisabled()
            } else {
                EmptyView()
            }
        }
        .task {
            do {
                _ = try StartupProfiler.measure("Startup settings load") {
                    try SettingsRepository.settings(in: modelContext)
                }
            } catch {
                StartupProfiler.mark("Startup settings load failed: \(error.localizedDescription)")
            }

            await StartupProfiler.measure("Apple Music authorization refresh") {
                await authorizationService.refresh()
            }

            StartupProfiler.measure("Remote command startup") {
                runtime.remoteCommandService.install(playbackController: playbackController, context: modelContext)
            }

            if authorizationService.readiness.isReady {
                await StartupProfiler.measure("Local playback restore") {
                    await playbackController.restoreLocalPlaybackState(context: modelContext)
                }

                StartupProfiler.measure("Playback warm-up scheduling") {
                    playbackController.schedulePostLaunchWarmUp()
                }
            }
        }
    }

    private var settings: OverplaySettings? {
        settingsRecords.first
    }

    private var shouldShowPermissionView: Bool {
        StartupAuthorizationGate.shouldShowPermissionView(
            readiness: authorizationService.readiness,
            hasCheckedReadiness: authorizationService.hasCheckedReadiness,
            hasPresentedAuthorizedUI: hasPresentedAuthorizedUI
        )
    }

    private var playerSheetPresentation: Binding<Bool> {
        Binding {
            authorizationService.readiness.isReady && settings != nil
        } set: { _ in
            playerSheetDetent = .height(playerSheetCollapsedHeight)
        }
    }
}

private struct PlatformShell: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var settings: OverplaySettings

    var body: some View {
        if horizontalSizeClass == .compact {
            CompactAppShell(settings: settings)
        } else {
            SplitAppShell(settings: settings)
        }
    }
}

private struct CompactAppShell: View {
    var settings: OverplaySettings

    var body: some View {
        NavigationStack {
            DashboardView(settings: settings)
        }
    }
}

private enum AppShellDestination: Hashable {
    case dashboard
    case playlist(UUID)
    case search
    case history
    case settings
    case linkedPlaylists

    init?(storageValue: String) {
        if storageValue.hasPrefix("playlist:") {
            let uuidString = String(storageValue.dropFirst("playlist:".count))
            guard let id = UUID(uuidString: uuidString) else { return nil }
            self = .playlist(id)
            return
        }

        switch storageValue {
        case Self.dashboard.storageValue:
            self = .dashboard
        case Self.search.storageValue:
            self = .search
        case Self.history.storageValue:
            self = .history
        case Self.settings.storageValue:
            self = .settings
        case Self.linkedPlaylists.storageValue:
            self = .linkedPlaylists
        default:
            return nil
        }
    }

    var storageValue: String {
        switch self {
        case .dashboard:
            "dashboard"
        case let .playlist(id):
            "playlist:\(id.uuidString)"
        case .search:
            "search"
        case .history:
            "history"
        case .settings:
            "settings"
        case .linkedPlaylists:
            "linkedPlaylists"
        }
    }
}

private struct SplitAppShell: View {
    @Query(sort: \PlaylistRecord.name) private var playlists: [PlaylistRecord]

    var settings: OverplaySettings

    @SceneStorage("overplay.splitSelection") private var storedSelection = AppShellDestination.dashboard.storageValue

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

                    Label("Manage Links", systemImage: "music.note.list")
                        .tag(AppShellDestination.linkedPlaylists)
                }
            }
            .miniPlayerScrollContentInset()
            .listStyle(.sidebar)
            .navigationTitle("Overplay")
        } detail: {
            detailView
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedDestination {
        case .dashboard:
            DashboardView(settings: settings)
        case let .playlist(playlistID):
            if let playlist = activePlaylists.first(where: { $0.id == playlistID }) {
                PlaylistManagementView(settings: settings, playlist: playlist)
            } else {
                ContentUnavailableView(
                    "Playlist Unavailable",
                    systemImage: "music.note.list",
                    description: Text("Choose another linked playlist from the sidebar.")
                )
            }
        case .search:
            SearchMusicView(settings: settings)
        case .history:
            HistoryView()
        case .settings:
            SettingsView(settings: settings)
        case .linkedPlaylists:
            PlaylistSelectionView()
        }
    }

    private var activePlaylists: [PlaylistRecord] {
        playlists
            .filter(\.isActive)
            .sorted { left, right in
                if left.role != right.role {
                    return left.role == .oneTruePlaylist
                }
                return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
            }
    }

    private func playlistIcon(for playlist: PlaylistRecord) -> String {
        switch playlist.role {
        case .oneTruePlaylist:
            "star.fill"
        case .triage:
            "tray.fill"
        }
    }

    private var selectedDestination: AppShellDestination {
        AppShellDestination(storageValue: storedSelection) ?? .dashboard
    }

    private var selection: Binding<AppShellDestination?> {
        Binding {
            selectedDestination
        } set: { newSelection in
            storedSelection = (newSelection ?? .dashboard).storageValue
        }
    }
}

private struct PlayerSheetView: View {
    var settings: OverplaySettings
    var collapsedHeight: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let contentOpacity = expandedContentOpacity(for: proxy.size.height)
            let backgroundOpacity = expandedBackgroundOpacity(for: proxy.size.height)

            ZStack(alignment: .bottom) {
                PlayerSheetBackground(opaqueProgress: backgroundOpacity)

                NowPlayingPaneView(settings: settings)
                    .padding(.bottom, collapsedHeight + proxy.safeAreaInsets.bottom)
                    .opacity(contentOpacity)
                    .allowsHitTesting(contentOpacity > 0.5)

                MiniPlayerLozengeView(settings: settings, expandedProgress: backgroundOpacity)
                    .frame(height: collapsedHeight)
                    .padding(.bottom, proxy.safeAreaInsets.bottom)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea(edges: .bottom)
        }
    }

    private func expandedBackgroundOpacity(for sheetHeight: CGFloat) -> Double {
        let fadeStart = collapsedHeight + 96
        let fadeDistance: CGFloat = 320
        let progress = min(max((sheetHeight - fadeStart) / fadeDistance, 0), 1)
        let easedProgress = progress * progress * (3 - 2 * progress)
        return Double(easedProgress)
    }

    private func expandedContentOpacity(for sheetHeight: CGFloat) -> Double {
        let fadeStart = collapsedHeight + 56
        let fadeDistance: CGFloat = 180
        let progress = min(max((sheetHeight - fadeStart) / fadeDistance, 0), 1)
        let easedProgress = progress * progress * (3 - 2 * progress)
        return Double(easedProgress)
    }
}

private struct PlayerSheetBackground: View {
    var opaqueProgress: Double

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.42 + (0.58 * opaqueProgress))

            LinearGradient(
                colors: [
                    .white.opacity(0.12),
                    .white.opacity(0.04),
                    .clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .opacity(1 - opaqueProgress)

            Rectangle()
                .fill(.background)
                .opacity(opaqueProgress)
        }
    }
}

private struct MiniPlayerLozengeView: View {
    @Environment(PlaybackController.self) private var playbackController

    var settings: OverplaySettings
    var expandedProgress: Double

    var body: some View {
        ZStack {
            compactContent
                .opacity(1 - expandedProgress)
                .allowsHitTesting(expandedProgress < 0.5)

            expandedContent
                .opacity(expandedProgress)
                .allowsHitTesting(expandedProgress >= 0.5)
        }
        .frame(maxHeight: .infinity, alignment: .center)
        .animation(.smooth(duration: 0.22), value: expandedProgress)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.white.opacity(0.18))
                .frame(height: 1)
                .opacity(1 - expandedProgress)
        }
    }

    private var compactContent: some View {
        HStack(spacing: 12) {
            ArtworkView(
                urlString: playbackController.currentTrack?.artworkURLTemplate,
                playlistID: playbackController.currentPlaylistID,
                cornerRadius: 10
            )
                .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 3) {
                Text(playbackController.currentTrack?.title ?? "Nothing playing")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(playbackController.currentTrack?.artistName ?? "Choose a playlist to start playback")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            PlaybackControlsView(settings: settings, controlSize: .compact)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var expandedContent: some View {
        PlaybackControlsView(settings: settings, controlSize: .regular)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

private struct NowPlayingPaneView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppRuntime.self) private var runtime
    @Environment(PlaybackController.self) private var playbackController

    var settings: OverplaySettings

    var body: some View {
        GeometryReader { proxy in
            let compactLayout = proxy.size.height < 620
            let artworkSize = min(
                proxy.size.width - 56,
                compactLayout ? 170 : 260,
                max(proxy.size.height * (compactLayout ? 0.26 : 0.34), 112)
            )

            VStack(spacing: compactLayout ? 12 : 18) {
                ArtworkView(
                    urlString: playbackController.currentTrack?.artworkURLTemplate,
                    playlistID: playbackController.currentPlaylistID
                )
                    .frame(width: artworkSize, height: artworkSize)
                    .shadow(color: .black.opacity(0.28), radius: 22, y: 16)

                trackText
                progressBlock
                skipStatus
                playbackModeControls
                triageControls

                if let statusMessage = playbackController.statusMessage {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, compactLayout ? 16 : 24)
            .padding(.bottom, compactLayout ? 12 : 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private var trackText: some View {
        VStack(spacing: 8) {
            Text(playbackController.currentTrack?.title ?? "Nothing playing")
                .font(.title.bold())
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.78)
            Text(playbackController.currentTrack?.artistName ?? "Choose a playlist to start playback.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
            if let albumTitle = playbackController.currentTrack?.albumTitle {
                Text(albumTitle)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
        }
    }

    private var progressBlock: some View {
        VStack(spacing: 6) {
            ProgressView(value: playbackController.progress)
            HStack {
                Text(formatTime(playbackController.elapsedSeconds))
                Spacer()
                Text(formatTime(playbackController.durationSeconds ?? 0))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var skipStatus: some View {
        HStack(spacing: 14) {
            Label(
                "Skips: \(playbackController.currentPlaylistItem?.skipCount ?? playbackController.currentTrack?.skipCount ?? 0) / \(settings.evictAfterSkips)",
                systemImage: "forward.end.fill"
            )
            if playbackController.currentPlaylistItem?.evictedAt != nil || playbackController.currentTrack?.isEvicted == true {
                Label("Evicted", systemImage: "trash.fill")
                    .foregroundStyle(.red)
            }
            if playbackController.currentPlaylistItem?.protected == true || playbackController.currentTrack?.protected == true {
                Label("Protected", systemImage: "shield.fill")
                    .foregroundStyle(.green)
            }
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: Capsule())
    }

    private var playbackModeControls: some View {
        HStack(spacing: 12) {
            Button {
                Task {
                    await playbackController.toggleShuffle(context: modelContext)
                    runtime.remoteCommandService.syncPlaybackModes(from: playbackController)
                }
            } label: {
                Label("Shuffle", systemImage: playbackController.shuffleEnabled ? "shuffle.circle.fill" : "shuffle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(playbackController.shuffleEnabled ? .accentColor : .secondary.opacity(0.24))

            Button {
                playbackController.toggleRepeat()
                runtime.remoteCommandService.syncPlaybackModes(from: playbackController)
            } label: {
                Label("Repeat \(playbackController.repeatModeTitle)", systemImage: repeatIconName)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(playbackController.repeatEnabled ? .accentColor : .secondary.opacity(0.24))
        }
    }

    private var triageControls: some View {
        HStack(spacing: 12) {
            Button {
                playbackController.keepCurrent(settings: settings, context: modelContext)
            } label: {
                Label("Keep", systemImage: "heart.fill")
                    .frame(maxWidth: .infinity)
            }
            .disabled(playbackController.currentTrack == nil)

            Button(role: .destructive) {
                Task { await playbackController.evictCurrent(settings: settings, context: modelContext) }
            } label: {
                Label("Evict Now", systemImage: "trash.fill")
                    .frame(maxWidth: .infinity)
            }
            .disabled(playbackController.currentTrack == nil)
        }
        .buttonStyle(.bordered)
    }

    private var repeatIconName: String {
        "repeat"
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let totalSeconds = max(Int(seconds), 0)
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }
}

#Preview {
    AppRouter()
        .environment(AppRuntime.shared)
        .environment(MusicAuthorizationService())
        .environment(PlaybackController())
        .modelContainer(PreviewContainer.make())
}
