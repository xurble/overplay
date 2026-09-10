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

    var body: some View {
        List {
            Section("Contributing Playlists") {
                if triageSources.isEmpty {
                    ContentUnavailableView(
                        "No Contributing Playlists",
                        systemImage: "tray",
                        description: Text("Add an Apple Music playlist below to feed the triage bucket.")
                    )
                }

                ForEach(triageSources) { playlist in
                    triageSourceRow(playlist)
                }
                .onDelete(perform: removeTriageSources)
            }

            Section("Apple Music Playlists") {
                if viewModel.isLoading {
                    ProgressView("Loading playlists")
                }

                ForEach(availablePlaylists) { playlist in
                    availablePlaylistRow(playlist)
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
        .navigationTitle("Triage Sources")
        .searchable(text: $viewModel.searchText, prompt: "Filter playlists")
        .refreshable {
            await viewModel.loadPlaylists(dependencies: dependencies)
        }
        .task {
            await viewModel.loadPlaylists(dependencies: dependencies)
        }
    }

    private func triageSourceRow(_ playlist: PlaylistRecord) -> some View {
        HStack(spacing: 12) {
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
            .accessibilityLabel("Add \(playlist.name) to triage")
        }
        .padding(.vertical, 4)
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
        .live(playbackController: playbackController) {}
    }
}

#Preview {
    NavigationStack {
        TriageSourcesView()
    }
    .environment(PlaybackController())
    .modelContainer(PreviewContainer.make())
}
