import SwiftData
import SwiftUI

struct PlaylistSelectionView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(PlaybackController.self) private var playbackController

    @Query(sort: \PlaylistRecord.name) private var linkedPlaylists: [PlaylistRecord]
    @Query(sort: \PlaylistItemRecord.createdAt) private var playlistItems: [PlaylistItemRecord]
    @Query(sort: \TrackRecord.title) private var tracks: [TrackRecord]

    @State private var playlists: [AppleMusicPlaylist] = []
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var isSyncingAll = false
    @State private var isCreatingOneTruePlaylist = false
    @State private var syncingPlaylistIDs = Set<UUID>()
    @State private var newPlaylistName = "Overplay"
    @State private var message: String?

    var body: some View {
        List {
            if oneTruePlaylist == nil {
                Section("One True Playlist") {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Playlist name", text: $newPlaylistName)

                        Button {
                            Task { await createManagedOneTruePlaylist() }
                        } label: {
                            Label(
                                isCreatingOneTruePlaylist ? "Creating" : "Start New Playlist",
                                systemImage: "plus.circle.fill"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isCreatingOneTruePlaylist)
                    }
                    .padding(.vertical, 6)
                }
            }

            Section("Linked Playlists") {
                if linkedPlaylists.isEmpty {
                    ContentUnavailableView(
                        "No Linked Playlists",
                        systemImage: "music.note.list",
                        description: Text("Choose a One True Playlist to start tracking.")
                    )
                }

                ForEach(sortedLinkedPlaylists) { playlist in
                    linkedPlaylistRow(playlist)
                }

                Button {
                    Task { await syncAllLinkedPlaylists() }
                } label: {
                    Label(isSyncingAll ? "Syncing All" : "Sync All", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(linkedPlaylists.isEmpty || isSyncingAll)
            }

            Section("Apple Music Playlists") {
                if isLoading {
                    ProgressView("Loading playlists")
                }

                if let message {
                    Text(message)
                        .foregroundStyle(.secondary)
                }

                ForEach(filteredPlaylists) { playlist in
                    appleMusicPlaylistRow(playlist)
                }
            }
        }
        .miniPlayerScrollContentInset()
        .navigationTitle("Linked Playlists")
        .searchable(text: $searchText, prompt: "Filter playlists")
        .refreshable {
            await loadPlaylists()
        }
        .task {
            await loadPlaylists()
        }
    }

    private var sortedLinkedPlaylists: [PlaylistRecord] {
        linkedPlaylists.sorted { left, right in
            if left.role != right.role {
                return left.role == .oneTruePlaylist
            }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
    }

    private var oneTruePlaylist: PlaylistRecord? {
        linkedPlaylists.first { $0.role == .oneTruePlaylist && $0.isActive }
    }

    private var filteredPlaylists: [AppleMusicPlaylist] {
        guard !searchText.isEmpty else { return playlists }
        return playlists.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
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

    private func linkedPlaylistRow(_ playlist: PlaylistRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                ArtworkView(
                    urlString: representativeArtworkURL(for: playlist),
                    pixelSize: 96,
                    playlistID: playlist.musicPlaylistID,
                    cornerRadius: 8
                )
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 4) {
                    Text(playlist.name)
                        .font(.headline)
                    Text(linkedPlaylistDetail(for: playlist))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(roleTitle(for: playlist.role), systemImage: roleImage(for: playlist))
                    .font(.caption)
                    .foregroundStyle(playlist.role == .oneTruePlaylist ? .pink : .secondary)
            }

            HStack {
                Button {
                    Task { await sync(playlist) }
                } label: {
                    Label(syncingPlaylistIDs.contains(playlist.id) ? "Syncing" : "Sync", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .disabled(syncingPlaylistIDs.contains(playlist.id))

                if playlist.role != .oneTruePlaylist {
                    Button {
                        makeOneTrue(playlist)
                    } label: {
                        Label("Make Main", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func appleMusicPlaylistRow(_ playlist: AppleMusicPlaylist) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(playlist.name)
                        .font(.headline)
                    if let trackCount = playlist.trackCount {
                        Text("\(trackCount) tracks")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if playlist.isPreferredOverplayPlaylist {
                    Label("Pinned", systemImage: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(.pink)
                }
            }

            HStack {
                Button {
                    select(playlist)
                } label: {
                    Label(oneTruePlaylist == nil ? "Copy to Overplay" : "Set Main", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isCreatingOneTruePlaylist)

                if oneTruePlaylist == nil {
                    Button {
                        useIncomingOnly(playlist)
                    } label: {
                        Label("Use Incoming Only", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isCreatingOneTruePlaylist)
                }

                Button {
                    addTriage(playlist)
                } label: {
                    Label("Add Triage", systemImage: "tray.and.arrow.down.fill")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 6)
    }

    private func linkedPlaylistDetail(for playlist: PlaylistRecord) -> String {
        let activeCount = playlistItems.filter { $0.playlistID == playlist.id && $0.removedFromRemoteAt == nil }.count
        let syncStatus = playlist.lastSyncedAt.map { "Synced \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Not synced"
        return "\(activeCount) tracks - \(syncStatus) - \(writePolicyTitle(for: playlist))"
    }

    private func roleTitle(for role: PlaylistRole) -> String {
        switch role {
        case .oneTruePlaylist:
            "Main"
        case .triage:
            "Triage"
        }
    }

    private func roleImage(for playlist: PlaylistRecord) -> String {
        if playbackController.isCurrentPlaylist(playlist) {
            return "play.fill"
        }

        return switch playlist.role {
        case .oneTruePlaylist:
            "star.fill"
        case .triage:
            "tray.fill"
        }
    }

    private func writePolicyTitle(for playlist: PlaylistRecord) -> String {
        switch playlist.writePolicy {
        case .managed:
            "Managed"
        case .incomingOnly:
            "Incoming only"
        }
    }

    private func loadPlaylists() async {
        isLoading = true
        defer { isLoading = false }

        do {
            playlists = try await PlaylistSyncService().fetchLibraryPlaylists()
            message = playlists.isEmpty ? "No Apple Music library playlists were found." : nil
        } catch {
            message = error.localizedDescription
        }
    }

    private func select(_ playlist: AppleMusicPlaylist) {
        if oneTruePlaylist == nil {
            Task { await copyToManagedOneTruePlaylist(from: playlist) }
            return
        }

        do {
            try SettingsRepository.selectPlaylist(playlist, in: modelContext)
            refreshPlaylistInBackground(id: playlist.id)
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }

    private func useIncomingOnly(_ playlist: AppleMusicPlaylist) {
        do {
            try SettingsRepository.selectPlaylist(playlist, writePolicy: .incomingOnly, in: modelContext)
            refreshPlaylistInBackground(id: playlist.id)
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }

    private func addTriage(_ playlist: AppleMusicPlaylist) {
        do {
            try PlaylistRepository.addTriagePlaylist(playlist, in: modelContext)
            try modelContext.save()
            message = "Added \(playlist.name) as a triage playlist."
        } catch {
            message = error.localizedDescription
        }
    }

    private func makeOneTrue(_ playlist: PlaylistRecord) {
        do {
            try SettingsRepository.selectPlaylist(
                AppleMusicPlaylist(id: playlist.musicPlaylistID, name: playlist.name, trackCount: nil),
                writePolicy: playlist.writePolicy,
                in: modelContext
            )
            refreshPlaylistInBackground(playlist)
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }

    private func createManagedOneTruePlaylist() async {
        isCreatingOneTruePlaylist = true
        defer { isCreatingOneTruePlaylist = false }

        do {
            let playlist = try await PlaylistSyncService().createManagedOneTruePlaylist(
                named: newPlaylistName,
                in: modelContext
            )
            try SettingsRepository.selectPlaylist(
                AppleMusicPlaylist(id: playlist.musicPlaylistID, name: playlist.name, trackCount: 0),
                writePolicy: .managed,
                in: modelContext
            )
            message = "Created \(playlist.name) in Apple Music."
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }

    private func copyToManagedOneTruePlaylist(from sourcePlaylist: AppleMusicPlaylist) async {
        isCreatingOneTruePlaylist = true
        defer { isCreatingOneTruePlaylist = false }

        do {
            let playlist = try await PlaylistSyncService().createManagedOneTruePlaylist(
                named: newPlaylistName,
                copyingTracksFrom: sourcePlaylist.id,
                in: modelContext
            )
            try SettingsRepository.selectPlaylist(
                AppleMusicPlaylist(id: playlist.musicPlaylistID, name: playlist.name, trackCount: sourcePlaylist.trackCount),
                writePolicy: .managed,
                in: modelContext
            )
            message = "Copied \(sourcePlaylist.name) to \(playlist.name)."
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }

    private func sync(_ playlist: PlaylistRecord) async {
        syncingPlaylistIDs.insert(playlist.id)
        defer { syncingPlaylistIDs.remove(playlist.id) }

        do {
            let count = try await PlaylistSyncService().syncPlaylist(playlist, in: modelContext)
            message = "Synced \(count) tracks from \(playlist.name)."
        } catch {
            message = error.localizedDescription
        }
    }

    private func syncAllLinkedPlaylists() async {
        isSyncingAll = true
        defer { isSyncingAll = false }

        do {
            let count = try await PlaylistSyncService().syncAllLinkedPlaylists(in: modelContext)
            message = "Synced \(count) tracks across linked playlists."
        } catch {
            message = error.localizedDescription
        }
    }

    private func refreshPlaylistInBackground(_ playlist: PlaylistRecord) {
        Task(priority: .background) {
            do {
                _ = try await PlaylistSyncService().syncPlaylist(playlist, in: modelContext)
            } catch {
                playlist.lastSyncError = error.localizedDescription
                playlist.updatedAt = .now
                try? modelContext.save()
            }
        }
    }

    private func refreshPlaylistInBackground(id playlistID: String) {
        Task(priority: .background) {
            do {
                _ = try await PlaylistSyncService().syncPlaylist(id: playlistID, in: modelContext)
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

#Preview {
    NavigationStack {
        PlaylistSelectionView()
    }
    .modelContainer(PreviewContainer.make())
    .environment(PlaybackController())
}
