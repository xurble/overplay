import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("Playlist selection view model")
struct PlaylistSelectionViewModelTests {
    @Test("loading playlists updates filtered results and empty message")
    func loadingPlaylistsUpdatesFilteredResultsAndEmptyMessage() async throws {
        let viewModel = PlaylistSelectionViewModel()
        let dependencies = makeDependencies(
            fetchedPlaylists: [
                AppleMusicPlaylist(id: "one", name: "Road Songs", trackCount: 12),
                AppleMusicPlaylist(id: "two", name: "Quiet Library", trackCount: 4)
            ]
        )

        await viewModel.loadPlaylists(dependencies: dependencies)
        viewModel.searchText = "road"

        #expect(!viewModel.isLoading)
        #expect(viewModel.message == nil)
        #expect(viewModel.filteredPlaylists.map(\.id) == ["one"])
    }

    @Test("track count resolves from the matching Apple Music playlist")
    func trackCountResolvesFromMatchingAppleMusicPlaylist() async {
        let viewModel = PlaylistSelectionViewModel()
        let source = PlaylistRecord(
            musicPlaylistID: "source",
            name: "Source",
            role: .triageSource
        )
        let missingSource = PlaylistRecord(
            musicPlaylistID: "missing",
            name: "Missing",
            role: .triageSource
        )
        let dependencies = makeDependencies(
            fetchedPlaylists: [
                AppleMusicPlaylist(id: "source", name: "Source", trackCount: 42)
            ]
        )
        let locallyAttributedItem = PlaylistItemRecord(
            playlistID: UUID(),
            trackID: UUID(),
            sourceMusicPlaylistIDs: ["missing"]
        )

        await viewModel.loadPlaylists(dependencies: dependencies)

        #expect(viewModel.trackCount(for: source, playlistItems: [locallyAttributedItem]) == 42)
        #expect(viewModel.trackCount(for: missingSource, playlistItems: [locallyAttributedItem]) == 1)
    }

    @Test("adding a triage source links it and creates the bucket")
    func addingTriageSourceLinksItAndCreatesTheBucket() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let viewModel = PlaylistSelectionViewModel()
        let playlist = AppleMusicPlaylist(id: "triage", name: "Inbox", trackCount: 3)

        viewModel.addTriageSource(playlist, context: context)

        let stored = try #require(try PlaylistRepository.playlist(musicPlaylistID: "triage", in: context))
        #expect(stored.role == .triageSource)
        #expect(viewModel.message == "Inbox now feeds the triage bucket.")
        let bucket = try #require(try PlaylistRepository.existingTriageBucket(in: context))
        #expect(bucket.musicPlaylistID == PlaylistRecord.triageBucketMusicPlaylistID)
    }

    @Test("an unlinked source is not synced")
    func unlinkedSourceIsNotSynced() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let viewModel = PlaylistSelectionViewModel()
        let source = try PlaylistRepository.addTriageSource(
            AppleMusicPlaylist(id: "source", name: "Source", trackCount: 1),
            in: context
        )
        try PlaylistRepository.removeTriageSource(source, in: context)
        var syncedIDs: [String] = []
        let dependencies = makeDependencies(syncPlaylist: { playlist, _ in
            syncedIDs.append(playlist.musicPlaylistID)
            return 0
        })

        await viewModel.sync(source, context: context, dependencies: dependencies)

        #expect(syncedIDs.isEmpty)
        #expect(viewModel.message == "Source is no longer linked.")
    }

    private func makeDependencies(
        fetchedPlaylists: [AppleMusicPlaylist] = [],
        syncPlaylist: ((_ playlist: PlaylistRecord, _ context: ModelContext) async throws -> Int)? = nil,
        reconcileStoredOrder: @escaping (PlaylistRecord, ModelContext) -> Void = { _, _ in }
    ) -> PlaylistSelectionViewModel.Dependencies {
        PlaylistSelectionViewModel.Dependencies {
            fetchedPlaylists
        } syncPlaylist: { playlist, context in
            if let syncPlaylist {
                return try await syncPlaylist(playlist, context)
            }
            return 0
        } reconcileStoredOrder: { playlist, context in
            reconcileStoredOrder(playlist, context)
        }
    }
}
