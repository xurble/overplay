import SwiftData
import SwiftUI

struct PlaylistManagementView: View {
    @Query(sort: \PlaylistRecord.createdAt) private var playlists: [PlaylistRecord]
    @Environment(\.shellPlace) private var shellPlace

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
        .onAppear {
            if scope == .retired {
                shellPlace?.destination = .retired
            } else if canonicalPlaylist.role.isPlaybackContext {
                shellPlace?.destination = .playlist(canonicalPlaylist.id)
            }
        }
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
    @State private var filterText = ""
    @State private var isFiltering = false
    /// The row tapped while its start runs (`RowStartFeedback`).
    @State private var startingRowID: PlaylistManagementViewModel.TrackRowPresentation.ID?

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
            if !isFiltering {
                Section {
                    // The title is the screen's own (owner request, 2026-10-30).
                    ListHeaderView(
                        shuffleTitle: viewModel.playButtonTitle,
                        canShuffle: detail.rows.contains { $0.isPlayable }
                    ) {
                        await playPlaylist()
                    } details: {
                        // The coloured caption of the One True Playlist, the
                        // Inbox or Retired, then the track count.
                        HStack(spacing: 6) {
                            Label(detail.playlist.roleTitle, systemImage: detail.playlist.iconIntent.systemImage)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(roleTint(for: detail.playlist))
                                .accessibilityValue(detail.playlist.isCurrentPlaybackPlaylist ? "Now playing" : "")
                            Text("· " + PlaylistSummaryPresentation.trackCountLabel(detail.rows.count))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } artwork: {
                        PlaylistCollageView(playlist: playlist, scope: selectedScope)
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 10)
                    // No lines around the header, and little room before
                    // the songs' heading (owner request, 2026-10-30).
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .id(ListFilter.headerID)
                }
            }

            Section {
                if detail.rows.isEmpty {
                    ContentUnavailableView(
                        "No \(selectedScope.title) Tracks",
                        systemImage: "music.note.list",
                        description: Text(selectedScope == .active ? "Sync this playlist to load its tracks." : "Retired tracks will appear here.")
                    )
                }

                let rows = detail.rows.filter { ListFilter.SongFields.titleOrArtist.matches(filterText, $0.summary) }
                if rows.isEmpty, !detail.rows.isEmpty {
                    ListFilterNoMatchesView()
                }
                ForEach(rows) { row in
                    playlistTrackButton(for: row)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 16))
                        // Right promotes to the One True Playlist; left
                        // retires, or moves a retired track to Triage.
                        .swipeActions(edge: .leading) {
                            if row.isRetired || (row.isPlayable && playlist.role == .triageBucket) {
                                Button {
                                    Task { await promote(row) }
                                } label: {
                                    SwipeLabel(title: "Overplay", systemImage: "arrow.up.circle")
                                }
                                .accessibilityLabel("Promote to One True Playlist")
                                .tint(.pink)
                                .disabled(viewModel.promotingItemIDs.contains(row.id))
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            if row.isRetired {
                                Button {
                                    Task { await restore(row) }
                                } label: {
                                    SwipeLabel(title: "Move to the Inbox", systemImage: "tray.and.arrow.down")
                                }
                                .tint(.green)
                                .disabled(viewModel.restoringItemIDs.contains(row.id))
                            } else if row.isPlayable {
                                Button(role: .destructive) {
                                    Task { await evict(row) }
                                } label: {
                                    SwipeLabel(title: "Retire", systemImage: "archivebox")
                                }
                                .disabled(viewModel.evictingItemIDs.contains(row.id))
                                // A One True Playlist song can also go back to the Inbox.
                                if playlist.role == .oneTruePlaylist {
                                    Button {
                                        Task { await moveToInbox(row) }
                                    } label: {
                                        SwipeLabel(title: "Move to the Inbox", systemImage: "tray.and.arrow.down")
                                    }
                                    .tint(.green)
                                    .disabled(viewModel.restoringItemIDs.contains(row.id))
                                }
                            }
                        }
                }
            }

        }
        .listStyle(.plain)
        .listSectionSpacing(0)
        .listFilter(text: $filterText, isPresented: $isFiltering, prompt: "Songs or artists")
        .miniPlayerScrollContentInset()
        .onChange(of: viewModel.message) { _, message in
            guard let message else { return }
            StatusToast.shared.show(message)
            viewModel.message = nil
        }
        .navigationTitle(selectedScope == .retired ? "Retired" : playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: playlist.musicPlaylistID) {
            await ArtworkCacheService.shared.touchPlaylistUsage(playlist.musicPlaylistID)
        }
        .task(id: playlistTrackIDsKey) {
            reloadPlaylistTracks()
        }
        .task(id: detailPresentationKey) {
            let next = detailPresentation
            if cachedDetail != next { cachedDetail = next }
        }
        .toolbar {
            // Retired has nothing to sync.
            if selectedScope == .active {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await syncPlaylist() }
                    } label: {
                        Label(viewModel.isSyncing ? "Syncing" : "Sync", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(viewModel.isSyncing)
                    .untinted()
                }
            }
        }
    }

    private var detailPresentation: PlaylistManagementViewModel.DetailPresentation {
        viewModel.detailPresentation(
            for: playlist,
            playlistItems: playlistItems,
            tracks: tracks,
            currentContext: playbackController.currentPlaylistContext,
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
        var currentContext: PlaylistPlaybackContext?
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
            currentContext: playbackController.currentPlaylistContext,
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
        if playlistPresentation.playbackScope == .retired {
            return .gray
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
            startingRowID = row.id
            Task {
                await play(row)
                startingRowID = nil
            }
        } label: {
            PlaylistTrackRowView(
                summary: row.summary,
                playlistID: playlist.musicPlaylistID,
                isCurrent: RowStartFeedback.isCurrent(row.id, starting: startingRowID, playing: row.isCurrent)
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

    private func moveToInbox(_ row: PlaylistManagementViewModel.TrackRowPresentation) async {
        guard let resolved = resolvedItemAndTrack(for: row) else { return }
        await viewModel.moveToInbox(
            resolved.item,
            track: resolved.track,
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
