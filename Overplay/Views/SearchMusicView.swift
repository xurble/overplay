import SwiftData
import SwiftUI

struct SearchMusicView: View {
    @Environment(\.modelContext) private var modelContext

    var settings: OverplaySettings
    var playlistID: String?
    @State private var searchText = ""
    @State private var searchService = SearchService()
    @State private var isSyncing = false

    var body: some View {
        List {
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
                        Image(systemName: "plus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Add \(result.title)")
                }
                .padding(.vertical, 6)
            }
        }
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
    }

    private func add(_ result: SearchSongResult) async {
        guard let playlistID = playlistID ?? settings.selectedPlaylistID else {
            searchService.message = "Choose a monitored playlist before adding songs."
            return
        }

        guard (try? PlaylistRepository.playlist(musicPlaylistID: playlistID, in: modelContext)?.role) != .triage else {
            searchService.message = "Add songs to the One True Playlist from search."
            return
        }

        await searchService.addSong(id: result.id, toPlaylistID: playlistID)
        await syncPlaylistIfPossible(playlistID: playlistID)
    }

    private func syncPlaylistIfPossible(playlistID: String) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        _ = try? await PlaylistSyncService().syncPlaylist(id: playlistID, in: modelContext)
    }
}

#Preview {
    NavigationStack {
        SearchMusicView(settings: OverplaySettings(selectedPlaylistID: "preview-playlist", selectedPlaylistName: "Overplay"))
    }
    .modelContainer(PreviewContainer.make())
}
