import SwiftData
import SwiftUI

struct SearchMusicView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PlaybackController.self) private var playbackController
    @Query(sort: \PlaylistRecord.name) private var playlists: [PlaylistRecord]

    var settings: OverplaySettings
    var initialPlaylistID: String?

    @State private var viewModel = SearchMusicViewModel()

    init(settings: OverplaySettings, playlistID: String? = nil) {
        self.settings = settings
        self.initialPlaylistID = playlistID
    }

    var body: some View {
        List {
            Section {
                if activePlaylists.isEmpty {
                    ContentUnavailableView(
                        "No Writable Playlists",
                        systemImage: "music.note.list",
                        description: Text("Create a managed playlist before adding songs from search.")
                    )
                } else {
                    Picker("Destination", selection: $viewModel.selectedPlaylistRecordID) {
                        ForEach(activePlaylists) { playlist in
                            Label(viewModel.destinationTitle(for: playlist), systemImage: viewModel.destinationImage(for: playlist))
                                .tag(Optional(playlist.id))
                        }
                    }
                }
            }

            if viewModel.searchService.isSearching {
                ProgressView("Searching Apple Music")
            }

            if let message = viewModel.searchService.message {
                Text(message)
                    .foregroundStyle(.secondary)
            }

            ForEach(viewModel.searchService.results) { result in
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
                        Task {
                            await viewModel.add(
                                result,
                                playlists: playlists,
                                context: modelContext,
                                dependencies: dependencies
                            )
                        }
                    } label: {
                        Image(systemName: viewModel.addingSongIDs.contains(result.id) ? "hourglass.circle.fill" : "plus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Add \(result.title)")
                    .disabled(selectedPlaylist == nil || viewModel.addingSongIDs.contains(result.id))
                }
                .padding(.vertical, 6)
            }
        }
        .miniPlayerScrollContentInset()
        .navigationTitle("Search Apple Music")
        .searchable(text: $viewModel.searchText, prompt: "Search songs")
        .onSubmit(of: .search) {
            Task { await viewModel.searchService.search(viewModel.searchText) }
        }
        .onChange(of: viewModel.searchText) { _, newValue in
            Task { await viewModel.clearSearchIfNeeded(newValue) }
        }
        .onChange(of: playlists.count) { _, _ in
            selectDefaultPlaylistIfNeeded()
        }
        .task {
            selectDefaultPlaylistIfNeeded()
        }
    }

    private var activePlaylists: [PlaylistRecord] {
        viewModel.activePlaylists(from: playlists)
    }

    private var selectedPlaylist: PlaylistRecord? {
        viewModel.selectedPlaylist(from: playlists)
    }

    private func selectDefaultPlaylistIfNeeded() {
        viewModel.selectDefaultPlaylistIfNeeded(
            playlists: playlists,
            settings: settings,
            initialPlaylistID: initialPlaylistID
        )
    }

    private var dependencies: SearchMusicViewModel.Dependencies {
        SearchMusicViewModel.Dependencies.live(
            searchService: viewModel.searchService,
            playbackController: playbackController
        )
    }
}

#Preview {
    NavigationStack {
        SearchMusicView(settings: OverplaySettings(selectedPlaylistID: "preview-playlist", selectedPlaylistName: "Overplay"))
    }
    .environment(PlaybackController())
    .modelContainer(PreviewContainer.make())
}
