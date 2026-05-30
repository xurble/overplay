import SwiftData
import SwiftUI

struct SearchMusicView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PlaylistRecord.name) private var playlists: [PlaylistRecord]

    var settings: OverplaySettings
    var initialPlaylistID: String?

    @State private var searchText = ""
    @State private var searchService = SearchService()
    @State private var selectedPlaylistRecordID: UUID?
    @State private var addingSongIDs = Set<String>()

    init(settings: OverplaySettings, playlistID: String? = nil) {
        self.settings = settings
        self.initialPlaylistID = playlistID
    }

    var body: some View {
        List {
            Section {
                if activePlaylists.isEmpty {
                    ContentUnavailableView(
                        "No Linked Playlists",
                        systemImage: "music.note.list",
                        description: Text("Link a One True Playlist or triage playlist before adding songs.")
                    )
                } else {
                    Picker("Destination", selection: $selectedPlaylistRecordID) {
                        ForEach(activePlaylists) { playlist in
                            Label(destinationTitle(for: playlist), systemImage: destinationImage(for: playlist))
                                .tag(Optional(playlist.id))
                        }
                    }
                }
            }

            if searchService.isSearching {
                ProgressView("Searching Apple Music")
            }

            if let message = searchService.message {
                Text(message)
                    .foregroundStyle(.secondary)
            }

            ForEach(searchService.results) { result in
                HStack(spacing: 12) {
                    ArtworkView(urlString: result.artworkURL, cornerRadius: 8)
                        .frame(width: 56, height: 56)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.title)
                            .font(.headline)
                        Text(result.artistName)
                            .foregroundStyle(.secondary)
                        if let albumTitle = result.albumTitle {
                            Text(albumTitle)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer()

                    Button {
                        Task { await add(result) }
                    } label: {
                        Image(systemName: addingSongIDs.contains(result.id) ? "hourglass.circle.fill" : "plus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Add \(result.title)")
                    .disabled(selectedPlaylist == nil || addingSongIDs.contains(result.id))
                }
                .padding(.vertical, 6)
            }
        }
        .miniPlayerScrollContentInset()
        .navigationTitle("Search Apple Music")
        .searchable(text: $searchText, prompt: "Search songs")
        .onSubmit(of: .search) {
            Task { await searchService.search(searchText) }
        }
        .onChange(of: searchText) { _, newValue in
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Task { await searchService.search("") }
            }
        }
        .onChange(of: playlists.count) { _, _ in
            selectDefaultPlaylistIfNeeded()
        }
        .task {
            selectDefaultPlaylistIfNeeded()
        }
    }

    private func add(_ result: SearchSongResult) async {
        guard let playlist = selectedPlaylist else {
            searchService.message = "Choose a monitored playlist before adding songs."
            return
        }

        guard !addingSongIDs.contains(result.id) else {
            return
        }

        addingSongIDs.insert(result.id)
        defer { addingSongIDs.remove(result.id) }

        do {
            _ = try await searchService.addSong(id: result.id, toPlaylistID: playlist.musicPlaylistID)
            try PlaylistMutationService().recordSuccessfulManualAdd(result, to: playlist, in: modelContext)
            if let syncMessage = await syncPlaylistIfPossible(playlist) {
                searchService.message = syncMessage
            } else {
                searchService.message = "Added \(result.title) to \(playlist.name)."
            }
        } catch {
            PlaylistMutationService().recordFailedManualAdd(
                result,
                to: playlist,
                message: error.localizedDescription,
                in: modelContext
            )
            searchService.message = "Could not add \(result.title) to \(playlist.name): \(error.localizedDescription)"
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

    private var selectedPlaylist: PlaylistRecord? {
        guard let selectedPlaylistRecordID else { return nil }
        return activePlaylists.first { $0.id == selectedPlaylistRecordID }
    }

    private func selectDefaultPlaylistIfNeeded() {
        if let selectedPlaylistRecordID,
           activePlaylists.contains(where: { $0.id == selectedPlaylistRecordID }) {
            return
        }

        selectedPlaylistRecordID = defaultPlaylist?.id
    }

    private var defaultPlaylist: PlaylistRecord? {
        if let initialPlaylistID,
           let playlist = activePlaylists.first(where: { $0.musicPlaylistID == initialPlaylistID }) {
            return playlist
        }

        if let settingsPlaylistID = settings.selectedPlaylistID,
           let playlist = activePlaylists.first(where: { $0.musicPlaylistID == settingsPlaylistID }) {
            return playlist
        }

        return activePlaylists.first { $0.role == .oneTruePlaylist } ?? activePlaylists.first
    }

    private func destinationTitle(for playlist: PlaylistRecord) -> String {
        switch playlist.role {
        case .oneTruePlaylist:
            "\(playlist.name) - Main"
        case .triage:
            "\(playlist.name) - Triage"
        }
    }

    private func destinationImage(for playlist: PlaylistRecord) -> String {
        switch playlist.role {
        case .oneTruePlaylist:
            "star.fill"
        case .triage:
            "tray.fill"
        }
    }

    private func syncPlaylistIfPossible(_ playlist: PlaylistRecord) async -> String? {
        do {
            _ = try await PlaylistSyncService().syncPlaylist(playlist, in: modelContext)
            return nil
        } catch {
            return "Added to \(playlist.name), but sync failed: \(error.localizedDescription)"
        }
    }
}

#Preview {
    NavigationStack {
        SearchMusicView(settings: OverplaySettings(selectedPlaylistID: "preview-playlist", selectedPlaylistName: "Overplay"))
    }
    .modelContainer(PreviewContainer.make())
}
