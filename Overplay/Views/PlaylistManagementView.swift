import SwiftData
import SwiftUI

struct PlaylistManagementView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PlaybackController.self) private var playbackController

    @Query(sort: \PlaylistItemRecord.createdAt) private var playlistItems: [PlaylistItemRecord]
    @Query(sort: \TrackRecord.title) private var tracks: [TrackRecord]

    var settings: OverplaySettings
    var playlist: PlaylistRecord

    @State private var viewModel = PlaylistManagementViewModel()

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label(playlistPresentation.roleTitle, systemImage: playlistPresentation.iconIntent.systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(roleTint)
                    Text(playlist.name)
                        .font(.title2.bold())
                }
                .padding(.vertical, 4)
            }

            Section {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    StatCardView(title: "Known", value: "\(summary.knownCount)", systemImage: "music.note.list", tint: .pink)
                    StatCardView(title: "Playable", value: "\(summary.playableCount)", systemImage: "play.circle.fill", tint: .green)
                    StatCardView(title: "Evicted", value: "\(summary.evictedCount)", systemImage: "trash.fill", tint: .red)
                    StatCardView(title: "At risk", value: "\(summary.atRiskCount)", systemImage: "exclamationmark.triangle.fill", tint: .orange)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }

            Section("Tracks") {
                if orderedItems.isEmpty {
                    ContentUnavailableView(
                        "No Tracks",
                        systemImage: "music.note.list",
                        description: Text("Sync this playlist to load its tracks.")
                    )
                }

                ForEach(orderedItems) { item in
                    if let track = track(for: item) {
                        Button {
                            Task { await play(item, track: track) }
                        } label: {
                            PlaylistTrackRowView(
                                track: track,
                                item: item,
                                playlistID: playlist.musicPlaylistID,
                                isCurrent: viewModel.isCurrentItem(
                                    item,
                                    track: track,
                                    playlist: playlist,
                                    currentPlaylistID: playbackController.currentPlaylistID,
                                    currentPlaylistItem: playbackController.currentPlaylistItem,
                                    currentTrack: playbackController.currentTrack
                                )
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!item.isPlayable)
                        .swipeActions(edge: .trailing) {
                            if playlist.role == .triage, item.isPlayable {
                                Button {
                                    Task { await promote(item, track: track) }
                                } label: {
                                    Label("Promote", systemImage: "star.fill")
                                }
                                .tint(.pink)
                                .disabled(viewModel.promotingItemIDs.contains(item.id))
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

    private var orderedItems: [PlaylistItemRecord] {
        viewModel.orderedItems(
            for: playlist,
            playlistItems: playlistItems,
            playbackModeState: playbackController.playbackModeState(for: playlist.musicPlaylistID)
        )
    }

    private func track(for item: PlaylistItemRecord) -> TrackRecord? {
        viewModel.track(for: item, tracks: tracks)
    }

    private var summary: DashboardSummary {
        viewModel.summary(
            for: playlist,
            playlistItems: playlistItems,
            tracks: tracks,
            currentPlaylistID: playbackController.currentPlaylistID,
            evictAfterSkips: settings.evictAfterSkips
        )
    }

    private var playlistPresentation: PlaylistSummaryPresentation {
        viewModel.playlistPresentation(
            for: playlist,
            playlistItems: playlistItems,
            tracks: tracks,
            currentPlaylistID: playbackController.currentTrack != nil ? playbackController.currentPlaylistID : nil,
            evictAfterSkips: settings.evictAfterSkips
        )
    }

    private var roleTint: Color {
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
