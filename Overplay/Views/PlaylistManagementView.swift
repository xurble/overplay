import SwiftData
import SwiftUI

struct PlaylistManagementView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PlaybackController.self) private var playbackController

    @Query private var playlistItems: [PlaylistItemRecord]
    @Query(sort: \TrackRecord.title) private var tracks: [TrackRecord]

    var settings: OverplaySettings
    var playlist: PlaylistRecord

    @State private var viewModel = PlaylistManagementViewModel()

    init(settings: OverplaySettings, playlist: PlaylistRecord) {
        self.settings = settings
        self.playlist = playlist

        let playlistID = playlist.id
        _playlistItems = Query(
            filter: #Predicate<PlaylistItemRecord> { item in
                item.playlistID == playlistID
            },
            sort: [
                SortDescriptor(\PlaylistItemRecord.sortOrder),
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
                    StatCardView(title: "At risk", value: "\(detail.summary.atRiskCount)", systemImage: "exclamationmark.triangle.fill", tint: .orange)
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
                    Button {
                        Task { await play(row.item, track: row.track) }
                    } label: {
                        PlaylistTrackRowView(
                            summary: row.summary,
                            playlistID: playlist.musicPlaylistID,
                            isCurrent: row.isCurrent
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!row.item.isPlayable)
                    .swipeActions(edge: .trailing) {
                        if playlist.role == .triage, row.item.isPlayable {
                            Button(role: .destructive) {
                                Task { await evict(row.item, track: row.track) }
                            } label: {
                                Label("Evict Now", systemImage: "trash.fill")
                            }
                            .disabled(viewModel.evictingItemIDs.contains(row.id))

                            Button {
                                Task { await promote(row.item, track: row.track) }
                            } label: {
                                Label("Promote", systemImage: "star.fill")
                            }
                            .tint(.pink)
                            .disabled(viewModel.promotingItemIDs.contains(row.id))
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
        .navigationTitle("Playlist")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: playlist.musicPlaylistID) {
            await ArtworkCacheService.shared.touchPlaylistUsage(playlist.musicPlaylistID)
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
            playbackModeState: playbackController.playbackModeState(for: playlist.musicPlaylistID),
            currentPlaylistID: playbackController.currentPlaylistID,
            currentPlaylistItem: playbackController.currentPlaylistItem,
            currentTrack: playbackController.currentTrack,
            evictAfterSkips: settings.evictAfterSkips
        )
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
    NavigationStack {
        PlaylistManagementView(
            settings: OverplaySettings(selectedPlaylistID: "preview-playlist", selectedPlaylistName: "Overplay"),
            playlist: PlaylistRecord(musicPlaylistID: "preview-playlist", name: "Overplay", role: .oneTruePlaylist)
        )
    }
    .environment(PlaybackController())
    .modelContainer(PreviewContainer.make())
}
