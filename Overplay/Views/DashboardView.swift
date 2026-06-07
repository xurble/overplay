import SwiftData
import SwiftUI

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \PlaylistRecord.name) private var playlists: [PlaylistRecord]
    @Query(sort: \PlaylistItemRecord.createdAt) private var playlistItems: [PlaylistItemRecord]
    @Query(sort: \TrackRecord.title) private var tracks: [TrackRecord]

    var settings: OverplaySettings

    var body: some View {
        List {
            Section {
                if let oneTruePlaylist {
                    NavigationLink {
                        PlaylistManagementView(settings: settings, playlist: oneTruePlaylist)
                    } label: {
                        PlaylistHomeRowView(
                            title: oneTruePlaylist.name,
                            detail: presentation(for: oneTruePlaylist).dashboardDetailText,
                            artworkURLString: representativeArtworkURL(for: oneTruePlaylist),
                            playlistID: oneTruePlaylist.musicPlaylistID,
                            systemImage: presentation(for: oneTruePlaylist).iconIntent.systemImage,
                            tint: .pink
                        )
                    }
                } else {
                    NavigationLink {
                        PlaylistSelectionView()
                    } label: {
                        PlaylistHomeRowView(
                            title: "Link One True Playlist",
                            detail: "Choose the main playlist Overplay manages.",
                            artworkURLString: nil,
                            playlistID: nil,
                            systemImage: "star",
                            tint: .pink
                        )
                    }
                }
            }

            Section("Triage Playlists") {
                ForEach(triagePlaylists) { playlist in
                    NavigationLink {
                        PlaylistManagementView(settings: settings, playlist: playlist)
                    } label: {
                        PlaylistHomeRowView(
                            title: playlist.name,
                            detail: presentation(for: playlist).dashboardDetailText,
                            artworkURLString: representativeArtworkURL(for: playlist),
                            playlistID: playlist.musicPlaylistID,
                            systemImage: presentation(for: playlist).iconIntent.systemImage,
                            tint: .teal
                        )
                    }
                }
                .onDelete(perform: deleteTriagePlaylists)

                NavigationLink {
                    PlaylistSelectionView()
                } label: {
                    Label(
                        triagePlaylists.isEmpty ? "Link Triage Playlist" : "Link Another Triage Playlist",
                        systemImage: "plus.circle"
                    )
                }
            }
        }
        .miniPlayerScrollContentInset()
        .navigationTitle("Overplay")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    SettingsView(settings: settings)
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
    }

    private var oneTruePlaylist: PlaylistRecord? {
        if let playlistID = settings.selectedPlaylistID,
           let playlist = playlists.first(where: { $0.musicPlaylistID == playlistID && $0.role == .oneTruePlaylist && $0.isActive }) {
            return playlist
        }

        return playlists.first { $0.role == .oneTruePlaylist && $0.isActive }
    }

    private var triagePlaylists: [PlaylistRecord] {
        playlists.filter { $0.role == .triage && $0.isActive }
    }

    private func presentation(for playlist: PlaylistRecord) -> PlaylistSummaryPresentation {
        let activeCount = playlistItems.filter { $0.playlistID == playlist.id }.count
        let playableCount = playlistItems.filter { $0.playlistID == playlist.id && $0.isPlayable }.count
        return PlaylistSummaryPresentation(
            id: playlist.id,
            title: playlist.name,
            role: playlist.role,
            writePolicy: playlist.writePolicy,
            activeTrackCount: activeCount,
            playableTrackCount: playableCount,
            lastSyncedAt: playlist.lastSyncedAt,
            isCurrentPlaybackPlaylist: false
        )
    }

    private var tracksByID: [UUID: TrackRecord] {
        Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
    }

    private func representativeArtworkURL(for playlist: PlaylistRecord) -> String? {
        PlaylistArtworkSelector.representativeArtworkURL(
            for: playlist,
            items: playlistItems,
            tracksByID: tracksByID
        )
    }

    private func deleteTriagePlaylists(at offsets: IndexSet) {
        for index in offsets {
            let playlist = triagePlaylists[index]
            try? PlaylistRepository.deactivateTriagePlaylist(playlist, in: modelContext)
        }
    }
}

private struct PlaylistHomeRowView: View {
    var title: String
    var detail: String
    var artworkURLString: String?
    var playlistID: String?
    var systemImage: String
    var tint: Color

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                ArtworkView(
                    urlString: artworkURLString,
                    pixelSize: 96,
                    playlistID: playlistID,
                    cornerRadius: 8
                )
                .frame(width: 48, height: 48)

                Image(systemName: systemImage)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(tint, in: Circle())
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 6)
    }
}

struct PlaylistManagementView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PlaybackController.self) private var playbackController

    @Query(sort: \PlaylistItemRecord.createdAt) private var playlistItems: [PlaylistItemRecord]
    @Query(sort: \TrackRecord.title) private var tracks: [TrackRecord]

    var settings: OverplaySettings
    var playlist: PlaylistRecord

    @State private var isSyncing = false
    @State private var promotingItemIDs = Set<UUID>()
    @State private var message: String?

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
                                isCurrent: isCurrentTrack(track)
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
                                .disabled(promotingItemIDs.contains(item.id))
                            }
                        }
                    }
                }
            }

            if let message {
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
                        Label(playButtonTitle, systemImage: "play.fill")
                    }

                    Button {
                        Task { await syncPlaylist() }
                    } label: {
                        Label(isSyncing ? "Syncing" : "Sync", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(isSyncing)

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

    private var visibleItems: [PlaylistItemRecord] {
        playlistItems.filter { $0.playlistID == playlist.id }
    }

    private var orderedItems: [PlaylistItemRecord] {
        let state = playbackController.playbackModeState(for: playlist.musicPlaylistID)
        return PlaylistDisplayOrder.orderedItems(visibleItems, state: state)
    }

    private var tracksByID: [UUID: TrackRecord] {
        Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
    }

    private func track(for item: PlaylistItemRecord) -> TrackRecord? {
        tracksByID[item.trackID]
    }

    private var summary: DashboardSummary {
        DashboardSummary(items: visibleItems, evictAfterSkips: settings.evictAfterSkips)
    }

    private var playlistPresentation: PlaylistSummaryPresentation {
        PlaylistSummaryPresentation(
            id: playlist.id,
            title: playlist.name,
            role: playlist.role,
            writePolicy: playlist.writePolicy,
            activeTrackCount: visibleItems.count,
            playableTrackCount: visibleItems.filter(\.isPlayable).count,
            lastSyncedAt: playlist.lastSyncedAt,
            isCurrentPlaybackPlaylist: playbackController.isCurrentPlaylist(playlist)
        )
    }

    private var roleTint: Color {
        switch playlist.role {
        case .oneTruePlaylist:
            .pink
        case .triage:
            .teal
        }
    }

    private var playButtonTitle: String {
        playbackController.isCurrentPlaylist(playlist) ? "Playing" : "Play"
    }

    private func isCurrentTrack(_ track: TrackRecord) -> Bool {
        playbackController.currentTrack?.id == track.catalogID || playbackController.currentTrack?.id == track.libraryID
    }

    private func play(_ item: PlaylistItemRecord, track: TrackRecord) async {
        guard item.isPlayable else { return }
        await playbackController.playPlaylist(playlist, startingAt: track, settings: settings, context: modelContext)
    }

    private func playPlaylist() async {
        if playbackController.isCurrentPlaylist(playlist) {
            return
        }

        await playbackController.playPlaylist(playlist, settings: settings, context: modelContext)
    }

    private func syncPlaylist() async {
        isSyncing = true
        defer { isSyncing = false }

        do {
            let count = try await PlaylistSyncService().syncPlaylist(playlist, in: modelContext)
            playbackController.reconcileStoredOrder(for: playlist, context: modelContext)
            message = "Synced \(count) tracks from \(playlist.name)."
        } catch {
            message = error.localizedDescription
        }
    }

    private func promote(_ item: PlaylistItemRecord, track: TrackRecord) async {
        guard playlist.role == .triage else { return }
        promotingItemIDs.insert(item.id)
        defer { promotingItemIDs.remove(item.id) }

        do {
            _ = try await PlaylistMutationService().promote(item: item, in: modelContext)
            message = "Promoted \(track.title)."
        } catch {
            message = error.localizedDescription
        }
    }
}

private struct PlaylistTrackRowView: View {
    var track: TrackRecord
    var item: PlaylistItemRecord
    var playlistID: String
    var isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                ArtworkView(
                    urlString: track.artworkURLTemplate,
                    pixelSize: 96,
                    playlistID: playlistID,
                    cornerRadius: 8
                )
                .frame(width: 48, height: 48)

                if let rowImage {
                    Image(systemName: rowImage)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(rowTint, in: Circle())
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.headline)
                    .foregroundStyle(item.isPlayable ? .primary : .secondary)
                Text(presentation.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let skipCountLabel = presentation.skipCountLabel {
                Text(skipCountLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }

    private var presentation: TrackSummaryPresentation {
        TrackSummaryPresentation(
            id: item.id,
            title: track.title,
            artistName: track.artistName,
            albumTitle: track.albumTitle,
            skipCount: item.skipCount
        )
    }

    private var rowImage: String? {
        if isCurrent {
            return "play.fill"
        }
        if item.evictedAt != nil {
            return "trash.fill"
        }
        return nil
    }

    private var rowTint: Color {
        if isCurrent {
            return .green
        }
        if item.isPlayable {
            return .pink
        }
        return .secondary
    }
}

#Preview {
    NavigationStack {
        DashboardView(settings: OverplaySettings(selectedPlaylistID: "preview-playlist", selectedPlaylistName: "Overplay"))
    }
    .environment(PlaybackController())
    .modelContainer(PreviewContainer.make())
}
