import SwiftData
import SwiftUI

struct PlaylistSelectionView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \PlaylistRecord.name) private var linkedPlaylists: [PlaylistRecord]
    @Query(sort: \PlaylistItemRecord.createdAt) private var playlistItems: [PlaylistItemRecord]

    @State private var playlists: [AppleMusicPlaylist] = []
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var isSyncingAll = false
    @State private var syncingPlaylistIDs = Set<UUID>()
    @State private var message: String?

    var body: some View {
        List {
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

    private var filteredPlaylists: [AppleMusicPlaylist] {
        guard !searchText.isEmpty else { return playlists }
        return playlists.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private func linkedPlaylistRow(_ playlist: PlaylistRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(playlist.name)
                        .font(.headline)
                    Text(linkedPlaylistDetail(for: playlist))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(roleTitle(for: playlist.role), systemImage: roleImage(for: playlist.role))
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
                    Label("Set Main", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)

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
        return "\(activeCount) tracks - \(syncStatus)"
    }

    private func roleTitle(for role: PlaylistRole) -> String {
        switch role {
        case .oneTruePlaylist:
            "Main"
        case .triage:
            "Triage"
        }
    }

    private func roleImage(for role: PlaylistRole) -> String {
        switch role {
        case .oneTruePlaylist:
            "star.fill"
        case .triage:
            "tray.fill"
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
        do {
            try SettingsRepository.selectPlaylist(playlist, in: modelContext)
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
                in: modelContext
            )
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
}

#Preview {
    NavigationStack {
        PlaylistSelectionView()
    }
    .modelContainer(PreviewContainer.make())
}
