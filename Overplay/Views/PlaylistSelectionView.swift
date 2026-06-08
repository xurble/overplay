import SwiftData
import SwiftUI

struct PlaylistSelectionView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(PlaybackController.self) private var playbackController

    @Query(sort: \PlaylistRecord.name) private var linkedPlaylists: [PlaylistRecord]
    @Query(sort: \PlaylistItemRecord.createdAt) private var playlistItems: [PlaylistItemRecord]
    @Query(sort: \TrackRecord.title) private var tracks: [TrackRecord]

    @State private var viewModel = PlaylistSelectionViewModel()

    var body: some View {
        List {
            if oneTruePlaylist == nil {
                Section("One True Playlist") {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Playlist name", text: $viewModel.newPlaylistName)

                        Button {
                            Task {
                                await viewModel.createManagedOneTruePlaylist(
                                    context: modelContext,
                                    dependencies: dependencies
                                )
                            }
                        } label: {
                            Label(
                                viewModel.isCreatingOneTruePlaylist ? "Creating" : "Start New Playlist",
                                systemImage: "plus.circle.fill"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.isCreatingOneTruePlaylist)
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
                    Task {
                        await viewModel.syncAllLinkedPlaylists(
                            linkedPlaylists,
                            context: modelContext,
                            dependencies: dependencies
                        )
                    }
                } label: {
                    Label(viewModel.isSyncingAll ? "Syncing All" : "Sync All", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(linkedPlaylists.isEmpty || viewModel.isSyncingAll)
            }

            Section("Apple Music Playlists") {
                if viewModel.isLoading {
                    ProgressView("Loading playlists")
                }

                if let message = viewModel.message {
                    Text(message)
                        .foregroundStyle(.secondary)
                }

                ForEach(viewModel.filteredPlaylists) { playlist in
                    appleMusicPlaylistRow(playlist)
                }
            }
        }
        .miniPlayerScrollContentInset()
        .navigationTitle("Linked Playlists")
        .searchable(text: $viewModel.searchText, prompt: "Filter playlists")
        .refreshable {
            await viewModel.loadPlaylists(dependencies: dependencies)
        }
        .task {
            await viewModel.loadPlaylists(dependencies: dependencies)
        }
    }

    private var sortedLinkedPlaylists: [PlaylistRecord] {
        linkedPlaylists.sorted { left, right in
            let leftSummary = presentation(for: left)
            let rightSummary = presentation(for: right)
            if leftSummary.displayPriority != rightSummary.displayPriority {
                return leftSummary.displayPriority < rightSummary.displayPriority
            }
            return leftSummary.title.localizedCaseInsensitiveCompare(rightSummary.title) == .orderedAscending
        }
    }

    private var oneTruePlaylist: PlaylistRecord? {
        linkedPlaylists.first { $0.role == .oneTruePlaylist && $0.isActive }
    }

    private func representativeArtworkURL(for playlist: PlaylistRecord) -> String? {
        presentation(for: playlist).artworkURLString
    }

    private func linkedPlaylistRow(_ playlist: PlaylistRecord) -> some View {
        let presentation = presentation(for: playlist)

        return VStack(alignment: .leading, spacing: 10) {
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
                    Text(presentation.dashboardDetailText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(presentation.shortRoleTitle, systemImage: presentation.iconIntent.systemImage)
                    .font(.caption)
                    .foregroundStyle(playlist.role == .oneTruePlaylist ? .pink : .secondary)
            }

            HStack {
                Button {
                    Task { await viewModel.sync(playlist, context: modelContext, dependencies: dependencies) }
                } label: {
                    Label(viewModel.syncingPlaylistIDs.contains(playlist.id) ? "Syncing" : "Sync", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.syncingPlaylistIDs.contains(playlist.id))

                if playlist.role != .oneTruePlaylist {
                    Button {
                        viewModel.makeOneTrue(playlist, context: modelContext, dependencies: dependencies)
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
                    viewModel.select(
                        playlist,
                        oneTruePlaylist: oneTruePlaylist,
                        context: modelContext,
                        dependencies: dependencies
                    )
                } label: {
                    Label(oneTruePlaylist == nil ? "Copy to Overplay" : "Set Main", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isCreatingOneTruePlaylist)

                if oneTruePlaylist == nil {
                    Button {
                        viewModel.useIncomingOnly(playlist, context: modelContext, dependencies: dependencies)
                    } label: {
                        Label("Use Incoming Only", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isCreatingOneTruePlaylist)
                }

                Button {
                    viewModel.addTriage(playlist, context: modelContext)
                } label: {
                    Label("Add Triage", systemImage: "tray.and.arrow.down.fill")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 6)
    }

    private func presentation(for playlist: PlaylistRecord) -> PlaylistSummaryPresentation {
        presentationBuilder.summary(for: playlist)
    }

    private var presentationBuilder: PlaylistPresentationBuilder {
        PlaylistPresentationBuilder(
            playlists: linkedPlaylists,
            items: playlistItems,
            tracks: tracks,
            currentPlaylistID: playbackController.currentTrack != nil ? playbackController.currentPlaylistID : nil,
            evictAfterSkips: OverplaySettings().evictAfterSkips
        )
    }

    private var dependencies: PlaylistSelectionViewModel.Dependencies {
        PlaylistSelectionViewModel.Dependencies.live(
            playbackController: playbackController,
            dismiss: { dismiss() }
        )
    }
}

#Preview {
    NavigationStack {
        PlaylistSelectionView()
    }
    .modelContainer(PreviewContainer.make())
    .environment(PlaybackController())
}
