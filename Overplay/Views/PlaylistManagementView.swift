import SwiftData
import SwiftUI

struct PlaylistManagementView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PlaybackController.self) private var playbackController

    @Query private var playlistItems: [PlaylistItemRecord]

    var settings: OverplaySettings
    var playlist: PlaylistRecord

    @State private var viewModel = PlaylistManagementViewModel()
    @State private var tracks: [TrackRecord] = []
    @State private var isScrolling = false

    init(settings: OverplaySettings, playlist: PlaylistRecord) {
        self.settings = settings
        self.playlist = playlist

        let playlistID = playlist.id
        _playlistItems = Query(
            filter: #Predicate<PlaylistItemRecord> { item in
                item.playlistID == playlistID
            },
            sort: [
                SortDescriptor(\PlaylistItemRecord.createdAt)
            ]
        )
    }

    var body: some View {
        let detail = detailPresentation

        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label(detail.playlist.roleTitle, systemImage: detail.playlist.iconIntent.systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(roleTint(for: detail.playlist))
                    Text(playlist.name)
                        .font(.title2.bold())
                }
                .padding(.vertical, 4)
            }

            Section {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    StatCardView(title: "Known", value: "\(detail.summary.knownCount)", systemImage: "music.note.list", tint: .pink)
                    StatCardView(title: "Playable", value: "\(detail.summary.playableCount)", systemImage: "play.circle.fill", tint: .green)
                    StatCardView(title: "Evicted", value: "\(detail.summary.evictedCount)", systemImage: "trash.fill", tint: .red)
                    StatCardView(title: "Skipped", value: "\(detail.summary.atRiskCount)", systemImage: "forward.end.fill", tint: .orange)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }

            Section("Tracks") {
                if detail.rows.isEmpty {
                    ContentUnavailableView(
                        "No Tracks",
                        systemImage: "music.note.list",
                        description: Text("Sync this playlist to load its tracks.")
                    )
                }

                ForEach(detail.rows) { row in
                    playlistTrackButton(for: row)
                        .swipeActions(edge: .trailing) {
                            if row.isPlayable {
                                Button(role: .destructive) {
                                    Task { await evict(row) }
                                } label: {
                                    Label("Evict Now", systemImage: "trash.fill")
                                }
                                .disabled(viewModel.evictingItemIDs.contains(row.id))

                                if playlist.role == .triage {
                                    Button {
                                        Task { await promote(row) }
                                    } label: {
                                        Label("Promote", systemImage: "star.fill")
                                    }
                                    .tint(.pink)
                                    .disabled(viewModel.promotingItemIDs.contains(row.id))
                                }
                            }
                        }
                }
            }

            if let message = viewModel.message {
                Section {
                    Text(message)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .miniPlayerScrollContentInset()
        .onScrollPhaseChange { _, phase in
            isScrolling = phase.isScrolling
        }
        .navigationTitle("Playlist")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: playlist.musicPlaylistID) {
            await ArtworkCacheService.shared.touchPlaylistUsage(playlist.musicPlaylistID)
        }
        .task(id: playlistTrackIDsKey) {
            reloadPlaylistTracks()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task { await playPlaylist() }
                    } label: {
                        Label(viewModel.playButtonTitle(isCurrentPlaylist: playbackController.isCurrentPlaylist(playlist)), systemImage: "play.fill")
                    }

                    Button {
                        Task { await syncPlaylist() }
                    } label: {
                        Label(viewModel.isSyncing ? "Syncing" : "Sync", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(viewModel.isSyncing)

                    Divider()

                    NavigationLink {
                        SearchMusicView(settings: settings, playlistID: playlist.musicPlaylistID)
                    } label: {
                        Label("Search Apple Music", systemImage: "magnifyingglass")
                    }

                    NavigationLink {
                        HistoryView()
                    } label: {
                        Label("History", systemImage: "clock.arrow.circlepath")
                    }

                    NavigationLink {
                        PlaylistSelectionView()
                    } label: {
                        Label("Manage Links", systemImage: "music.note.list")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Playlist Controls")
            }
        }
    }

    private var detailPresentation: PlaylistManagementViewModel.DetailPresentation {
        viewModel.detailPresentation(
            for: playlist,
            playlistItems: playlistItems,
            tracks: tracks,
            playbackOrderState: playbackController.playbackOrderState(for: playlist.musicPlaylistID),
            currentPlaylistID: playbackController.currentPlaylistID,
            currentPlaylistItem: playbackController.currentPlaylistItem,
            currentLocalTrackID: playbackController.nowPlayingDisplayLocalTrackID,
            currentTrack: playbackController.nowPlayingDisplayTrack,
            playbackItemMetadataVersion: playbackController.playbackItemMetadataVersion,
            activePlaylistSnapshot: playbackController.activePlaylistSnapshot,
            evictAfterSkips: settings.evictAfterSkips
        )
    }

    private var playlistTrackIDsKey: String {
        playlistItems
            .map(\.trackID.uuidString)
            .sorted()
            .joined(separator: "|")
    }

    private func reloadPlaylistTracks() {
        tracks = (try? TrackRecordRepository.tracks(ids: playlistItems.map(\.trackID), in: modelContext)) ?? []
    }

    private func roleTint(for playlistPresentation: PlaylistSummaryPresentation) -> Color {
        if playlistPresentation.isCurrentPlaybackPlaylist {
            return .green
        }

        switch playlist.role {
        case .oneTruePlaylist:
            return .pink
        case .triage:
            return .teal
        }
    }

    private func playlistTrackButton(for row: PlaylistManagementViewModel.TrackRowPresentation) -> some View {
        Button {
            Task { await play(row) }
        } label: {
            PlaylistTrackRowView(
                summary: row.summary,
                playlistID: playlist.musicPlaylistID,
                isCurrent: row.isCurrent,
                loadsArtworkImmediately: !isScrolling
            )
        }
        .buttonStyle(.plain)
        .disabled(!row.isPlayable)
    }

    private func resolvedItemAndTrack(
        for row: PlaylistManagementViewModel.TrackRowPresentation
    ) -> (item: PlaylistItemRecord, track: TrackRecord)? {
        if let item = row.item, let track = row.track {
            return (item, track)
        }

        guard let item = try? PlaylistItemRepository.item(id: row.id, in: modelContext),
              item.playlistID == playlist.id,
              let track = try? TrackRecordRepository.track(id: item.trackID, in: modelContext) else {
            return nil
        }

        return (item, track)
    }

    private func play(_ row: PlaylistManagementViewModel.TrackRowPresentation) async {
        guard let resolved = resolvedItemAndTrack(for: row) else { return }
        await play(resolved.item, track: resolved.track)
    }

    private func play(_ item: PlaylistItemRecord, track: TrackRecord) async {
        await viewModel.play(
            item,
            track: track,
            playlist: playlist,
            settings: settings,
            context: modelContext,
            dependencies: dependencies
        )
    }

    private func playPlaylist() async {
        await viewModel.playPlaylist(
            playlist: playlist,
            settings: settings,
            isCurrentPlaylist: playbackController.isCurrentPlaylist(playlist),
            context: modelContext,
            dependencies: dependencies
        )
    }

    private func syncPlaylist() async {
        await viewModel.syncPlaylist(playlist, context: modelContext, dependencies: dependencies)
        reloadPlaylistTracks()
    }

    private func promote(_ row: PlaylistManagementViewModel.TrackRowPresentation) async {
        guard let resolved = resolvedItemAndTrack(for: row) else { return }
        await promote(resolved.item, track: resolved.track)
    }

    private func promote(_ item: PlaylistItemRecord, track: TrackRecord) async {
        await viewModel.promote(
            item,
            track: track,
            playlist: playlist,
            context: modelContext,
            dependencies: dependencies
        )
    }

    private func evict(_ row: PlaylistManagementViewModel.TrackRowPresentation) async {
        guard let resolved = resolvedItemAndTrack(for: row) else { return }
        await evict(resolved.item, track: resolved.track)
    }

    private func evict(_ item: PlaylistItemRecord, track: TrackRecord) async {
        await viewModel.evict(
            item,
            track: track,
            playlist: playlist,
            context: modelContext,
            dependencies: dependencies
        )
    }

    private var dependencies: PlaylistManagementViewModel.Dependencies {
        .live(playbackController: playbackController)
    }
}

#Preview {
    let fixture = PreviewContainer.makeFixture()

    NavigationStack {
        PlaylistManagementView(
            settings: fixture.settings,
            playlist: fixture.playlist
        )
    }
    .environment(PlaybackController())
    .modelContainer(fixture.container)
}
