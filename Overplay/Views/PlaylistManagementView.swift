import SwiftData
import SwiftUI

struct PlaylistManagementView: View {
    @Query(sort: \PlaylistRecord.createdAt) private var playlists: [PlaylistRecord]

    var settings: OverplaySettings
    var playlist: PlaylistRecord
    var scope: PlaylistPlaybackScope = .active

    var body: some View {
        let canonicalPlaylist = PlaylistRepository.canonicalPlaylist(
            for: playlist,
            among: playlists
        )
        PlaylistManagementContentView(
            settings: settings,
            playlist: canonicalPlaylist,
            scope: scope
        )
        .id(scope.playbackOrderPlaylistID(for: canonicalPlaylist.id.uuidString))
    }
}

private struct PlaylistManagementContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PlaybackController.self) private var playbackController

    @Query private var playlistItems: [PlaylistItemRecord]
    @Query(sort: \PlaylistRecord.name) private var linkedPlaylists: [PlaylistRecord]

    var settings: OverplaySettings
    var playlist: PlaylistRecord

    @State private var viewModel = PlaylistManagementViewModel()
    @State private var tracks: [TrackRecord] = []
    let selectedScope: PlaylistPlaybackScope
    // Memoized row build: body re-runs for reasons that don't change the
    // rows (scroll phase, messages), and rebuilding every presentation
    // model per pass was measurable churn. detailPresentationKey names
    // every input the rows depend on.
    @State private var cachedDetail: PlaylistManagementViewModel.DetailPresentation?

    init(settings: OverplaySettings, playlist: PlaylistRecord, scope: PlaylistPlaybackScope) {
        self.settings = settings
        self.playlist = playlist
        self.selectedScope = scope

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
        let detail = cachedDetail ?? detailPresentation

        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    PlaylistCollageView(playlist: playlist, scope: selectedScope)

                    VStack(alignment: .leading, spacing: 8) {
                        Label(detail.playlist.roleTitle, systemImage: detail.playlist.iconIntent.systemImage)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(roleTint(for: detail.playlist))
                        Text(detail.playlist.title)
                            .font(.title2.bold())
                    }

                    Button {
                        Task { await playPlaylist() }
                    } label: {
                        Label(
                            viewModel.playButtonTitle,
                            systemImage: "shuffle"
                        )
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!detail.rows.contains { $0.isPlayable })
                }
                .padding(.vertical, 4)
            }

            Section(selectedScope.title) {
                if detail.rows.isEmpty {
                    ContentUnavailableView(
                        "No \(selectedScope.title) Tracks",
                        systemImage: "music.note.list",
                        description: Text(selectedScope == .active ? "Sync this playlist to load its tracks." : "Retired tracks will appear here.")
                    )
                }

                ForEach(detail.rows) { row in
                    playlistTrackButton(for: row)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 16))
                        .swipeActions(edge: .trailing) {
                            if row.isRetired {
                                Button {
                                    Task { await restore(row) }
                                } label: {
                                    Label("Move to Triage", systemImage: "tray.fill")
                                }
                                .tint(.green)
                                .disabled(viewModel.restoringItemIDs.contains(row.id))
                                Button {
                                    Task { await promote(row) }
                                } label: {
                                    Label("Overplay", systemImage: "arrow.up.circle")
                                }
                                .tint(.pink)
                                .disabled(viewModel.promotingItemIDs.contains(row.id))
                            } else if row.isPlayable {
                                Button(role: .destructive) {
                                    Task { await evict(row) }
                                } label: {
                                    Label("Retire", systemImage: "archivebox.fill")
                                }
                                .disabled(viewModel.evictingItemIDs.contains(row.id))

                                if playlist.role == .triageBucket {
                                    Button {
                                        Task { await promote(row) }
                                    } label: {
                                        Label("Overplay", systemImage: "arrow.up.circle")
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
        .listStyle(.plain)
        .miniPlayerScrollContentInset()
        .navigationTitle(selectedScope == .retired ? "Retired" : playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: playlist.musicPlaylistID) {
            await ArtworkCacheService.shared.touchPlaylistUsage(playlist.musicPlaylistID)
        }
        .task(id: playlistTrackIDsKey) {
            reloadPlaylistTracks()
        }
        .task(id: detailPresentationKey) {
            cachedDetail = detailPresentation
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task { await playPlaylist() }
                    } label: {
                        Label(
                            viewModel.playButtonTitle,
                            systemImage: "shuffle"
                        )
                    }
                    .disabled(!detail.rows.contains { $0.isPlayable })

                    if selectedScope == .active {
                        Button {
                            Task { await syncPlaylist() }
                        } label: {
                            Label(viewModel.isSyncing ? "Syncing" : "Sync", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(viewModel.isSyncing)
                    }

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

                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Playlist Controls")
            }
        }
    }

    // Read-only on purpose: the persisting reconcile
    // (playbackOrderState(for:scope:items:)) used to run inside body, which
    // meant a UserDefaults write as a view-update side effect.
    private var selectedPlaybackOrderState: PlaybackOrderState {
        playbackController.previewedPlaybackOrderState(
            for: playlist.musicPlaylistID,
            scope: selectedScope,
            items: playlistItems
        )
    }

    private var detailPresentation: PlaylistManagementViewModel.DetailPresentation {
        viewModel.detailPresentation(
            for: playlist,
            playlistItems: playlistItems,
            tracks: tracks,
            playbackOrderState: selectedPlaybackOrderState,
            currentPlaylistID: playbackController.currentPlaylistID,
            currentPlaylistItem: playbackController.currentPlaylistItem,
            currentLocalTrackID: playbackController.nowPlayingDisplayLocalTrackID,
            currentTrack: playbackController.nowPlayingDisplayTrack,
            playbackItemMetadataVersion: playbackController.playbackItemMetadataVersion,
            activePlaylistSnapshot: playbackController.activePlaylistSnapshot,
            sourcePlaylists: linkedPlaylists,
            scope: selectedScope
        )
    }

    private var playlistTrackIDsKey: Set<UUID> { Set(playlistItems.map(\.trackID)) }

    private struct ItemRevision: Equatable {
        var id: UUID
        var updatedAt: Date
        var evictedAt: Date?
        var sources: [String]
    }
    private struct SourceRevision: Equatable {
        var id: UUID
        var musicID: String
        var name: String
        var role: String
    }
    private struct TrackRevision: Equatable {
        var id: UUID
        var updatedAt: Date
        var title: String
        var artist: String
        var album: String?
        var artwork: String?
    }
    private struct DetailRevision: Equatable {
        var playlistID: UUID
        var playlistUpdatedAt: Date
        var scope: PlaylistPlaybackScope
        var items: [ItemRevision]
        var sources: [SourceRevision]
        var tracks: [TrackRevision]
        var metadataVersion: Int
        var modeVersion: Int
        var currentPlaylist: String?
        var currentTrack: String?
        var snapshotDate: Date?
    }

    /// Typed revisions avoid sorting and formatting a playlist-sized string on
    /// every body evaluation. Counter changes rebuild rows without refetching tracks.
    private var detailPresentationKey: DetailRevision {
        DetailRevision(playlistID: playlist.id, playlistUpdatedAt: playlist.updatedAt, scope: selectedScope,
            items: playlistItems.map { ItemRevision(id: $0.id, updatedAt: $0.updatedAt, evictedAt: $0.evictedAt, sources: $0.sourceMusicPlaylistIDs) },
            sources: linkedPlaylists.map { SourceRevision(id: $0.id, musicID: $0.musicPlaylistID, name: $0.name, role: $0.roleRawValue) },
            tracks: tracks.map { TrackRevision(id: $0.id, updatedAt: $0.updatedAt, title: $0.title, artist: $0.artistName, album: $0.albumTitle, artwork: $0.artworkURLTemplate) },
            metadataVersion: playbackController.playbackItemMetadataVersion,
            modeVersion: playbackController.playbackModeVersion,
            currentPlaylist: playbackController.currentPlaylistID,
            currentTrack: playbackController.nowPlayingDisplayLocalTrackID,
            snapshotDate: playbackController.activePlaylistSnapshot?.updatedAt)
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
        case .triageBucket:
            return .teal
        case .triageSource:
            return .gray
        }
    }

    private func playlistTrackButton(for row: PlaylistManagementViewModel.TrackRowPresentation) -> some View {
        Button {
            Task { await play(row) }
        } label: {
            PlaylistTrackRowView(
                summary: row.summary,
                playlistID: playlist.musicPlaylistID,
                isCurrent: row.isCurrent
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
            scope: selectedScope,
            context: modelContext,
            dependencies: dependencies
        )
    }

    private func playPlaylist() async {
        await viewModel.playPlaylist(
            playlist: playlist,
            settings: settings,
            scope: selectedScope,
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

    private func restore(_ row: PlaylistManagementViewModel.TrackRowPresentation) async {
        guard let resolved = resolvedItemAndTrack(for: row) else { return }
        await restore(resolved.item, track: resolved.track)
    }

    private func restore(_ item: PlaylistItemRecord, track: TrackRecord) async {
        await viewModel.restore(
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
    .environment(PlaylistArtworkPresentation())
    .modelContainer(fixture.container)
}
