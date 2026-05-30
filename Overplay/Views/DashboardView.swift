import SwiftData
import SwiftUI

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \PlaylistRecord.name) private var playlists: [PlaylistRecord]
    @Query(sort: \PlaylistItemRecord.createdAt) private var playlistItems: [PlaylistItemRecord]

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
                            detail: detailText(for: oneTruePlaylist),
                            systemImage: "star.fill",
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
                            detail: detailText(for: playlist),
                            systemImage: "tray.fill",
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

    private func detailText(for playlist: PlaylistRecord) -> String {
        let activeCount = playlistItems.filter { $0.playlistID == playlist.id && $0.removedFromRemoteAt == nil }.count
        let syncStatus = playlist.lastSyncedAt.map { "Synced \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Not synced"
        return "\(activeCount) tracks - \(syncStatus)"
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
    var systemImage: String
    var tint: Color

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
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
                    Label(roleTitle, systemImage: roleImage)
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
        visibleItems.sorted { $0.createdAt < $1.createdAt }
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

    private var roleTitle: String {
        switch playlist.role {
        case .oneTruePlaylist:
            "One True Playlist"
        case .triage:
            "Triage Playlist"
        }
    }

    private var roleImage: String {
        switch playlist.role {
        case .oneTruePlaylist:
            "star.fill"
        case .triage:
            "tray.fill"
        }
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
    var isCurrent: Bool

    var body: some View {
        Label {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(.headline)
                        .foregroundStyle(item.isPlayable ? .primary : .secondary)
                    Text(trackSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if item.skipCount > 0 {
                    Text("\(item.skipCount) skips")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: rowImage)
                .foregroundStyle(rowTint)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }

    private var trackSubtitle: String {
        if let albumTitle = track.albumTitle, !albumTitle.isEmpty {
            return "\(track.artistName) - \(albumTitle)"
        }

        return track.artistName
    }

    private var rowImage: String {
        if isCurrent {
            return "play.fill"
        }
        if item.evictedAt != nil {
            return "trash.fill"
        }
        if item.removedFromRemoteAt != nil {
            return "xmark.circle.fill"
        }
        return "music.note"
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
