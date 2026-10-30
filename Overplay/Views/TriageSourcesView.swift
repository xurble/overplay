import SwiftData
import SwiftUI

/// Manages which Apple Music playlists feed the single triage bucket.
///
/// Unlinking removes unowned, untouched intake while preserving listening
/// data and explicitly kept active songs through the shared controller.
struct TriageSourcesView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PlaybackController.self) private var playbackController

    @Query(sort: \PlaylistRecord.name) private var linkedPlaylists: [PlaylistRecord]
    @Query private var playlistItems: [PlaylistItemRecord]

    @State private var viewModel = PlaylistSelectionViewModel()
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        List {
            Section("Contributing Playlists") {
                if triageSources.isEmpty {
                    ContentUnavailableView(
                        "No Contributing Playlists",
                        systemImage: "tray",
                        description: Text("Add an Apple Music playlist below to feed the Inbox.")
                    )
                }

                ForEach(triageSources) { playlist in
                    triageSourceRow(playlist)
                }
                .onDelete(perform: removeTriageSources)
            }

            let mixes = madeForYouCandidates
            if !mixes.isEmpty {
                Section {
                    ForEach(mixes) { availablePlaylistRow($0.sourcePlaylist) }
                } header: {
                    Text("Made For You")
                } footer: {
                    Text("Mixes stay live: each sync brings in Apple Music's latest songs.")
                }
            }

            Section("Apple Music Playlists") {
                if viewModel.isLoading {
                    ProgressView("Loading playlists")
                }

                ForEach(availablePlaylists) { playlist in
                    availablePlaylistRow(playlist)
                }
            }

        }
        .listStyle(.plain)
        .miniPlayerScrollContentInset()
        .onChange(of: viewModel.message) { _, message in
            guard let message else { return }
            StatusToast.shared.show(message)
            viewModel.message = nil
        }
        .navigationTitle("Inbox Sources")
        .searchable(text: $viewModel.searchText, prompt: "Filter playlists")
        .searchFocused($isSearchFocused)
        .focusedSceneValue(\.isEditingText, isSearchFocused)
        .refreshable {
            await viewModel.loadPlaylists(dependencies: dependencies)
        }
        .task {
            await viewModel.loadPlaylists(dependencies: dependencies)
        }
        .task { await MadeForYouLibrary.shared.refresh() }
        .task { await LibraryCache.shared.prepare(.playlists) }
    }

    /// A library playlist's artwork from Library's cache, or a Made For You
    /// mix's; the no-artwork image otherwise.
    @ViewBuilder private func artwork(forPlaylistID playlistID: String) -> some View {
        if let item = LibraryCache.shared.items[.playlists]?.first(where: { $0.libraryID == playlistID }) {
            LibraryArtworkView(artwork: item.artwork, side: Self.artworkSide, cornerRadius: 8)
        } else {
            ArtworkView(urlString: MadeForYouLibrary.shared.items.first { $0.id == playlistID }?.artworkURL,
                        pixelSize: 128, cornerRadius: 8)
                .frame(width: Self.artworkSide, height: Self.artworkSide)
        }
    }

    private static let artworkSide: CGFloat = 44

    private func triageSourceRow(_ playlist: PlaylistRecord) -> some View {
        HStack(spacing: 12) {
            artwork(forPlaylistID: playlist.musicPlaylistID)
            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.name)
                    .font(.headline)
                Text(sourceDetail(for: playlist))
                    .font(.caption)
                    .foregroundStyle(playlist.lastSyncError == nil ? Color.secondary : Color.red)
            }

            Spacer()

            Button {
                Task { await viewModel.sync(playlist, context: modelContext, dependencies: dependencies) }
            } label: {
                Label(
                    viewModel.syncingPlaylistIDs.contains(playlist.id) ? "Syncing" : "Sync",
                    systemImage: "arrow.triangle.2.circlepath"
                )
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.syncingPlaylistIDs.contains(playlist.id))
            .accessibilityLabel("Sync \(playlist.name)")
        }
        .padding(.vertical, 4)
    }

    private func availablePlaylistRow(_ playlist: AppleMusicPlaylist) -> some View {
        HStack(spacing: 12) {
            artwork(forPlaylistID: playlist.id)
            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.name)
                    .font(.headline)
                if let trackCount = playlist.trackCount {
                    Text(trackCountLabel(trackCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                viewModel.addTriageSource(playlist, context: modelContext)
            } label: {
                Label("Add", systemImage: "plus.circle.fill")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Add \(playlist.name) to the Inbox")
        }
        .padding(.vertical, 4)
    }

    private var madeForYouCandidates: [MadeForYouLibrary.Item] {
        let mixes = MadeForYouLibrary.shared.sourceCandidates(
            excludingIDs: Set(linkedPlaylists.filter(\.isActive).map(\.musicPlaylistID))
        )
        guard !viewModel.searchText.isEmpty else { return mixes }
        return mixes.filter { $0.name.localizedCaseInsensitiveContains(viewModel.searchText) }
    }

    private func syncDetail(for playlist: PlaylistRecord) -> String {
        if let error = playlist.lastSyncError {
            return error
        }

        guard let lastSyncedAt = playlist.lastSyncedAt else {
            return "Not synced"
        }

        return "Synced \(lastSyncedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private func sourceDetail(for playlist: PlaylistRecord) -> String {
        let trackCount = viewModel.trackCount(for: playlist, playlistItems: playlistItems)
        return "\(trackCountLabel(trackCount)) · \(syncDetail(for: playlist))"
    }

    private func trackCountLabel(_ trackCount: Int) -> String {
        trackCount == 1 ? "1 track" : "\(trackCount) tracks"
    }

    private var triageSources: [PlaylistRecord] {
        linkedPlaylists.filter { $0.role == .triageSource && $0.isActive }
    }

    /// Apple Music playlists that are not already contributing, and not the
    /// One True Playlist — that one is tracked in its own right.
    private var availablePlaylists: [AppleMusicPlaylist] {
        let linkedIDs = Set(
            linkedPlaylists
                .filter { $0.isActive && ($0.role == .triageSource || $0.role == .oneTruePlaylist) }
                .map(\.musicPlaylistID)
        )
        return viewModel.filteredPlaylists.filter { !linkedIDs.contains($0.id) }
    }

    private func removeTriageSources(at offsets: IndexSet) {
        for index in offsets {
            viewModel.removeTriageSource(triageSources[index], context: modelContext, playbackController: playbackController)
        }
    }

    private var dependencies: PlaylistSelectionViewModel.Dependencies {
        .live(playbackController: playbackController)
    }
}

#Preview {
    NavigationStack {
        TriageSourcesView()
    }
    .environment(PlaybackController())
    .modelContainer(PreviewContainer.make())
}
