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

    @Test("sync linked playlists reconciles each playlist once")
    func syncLinkedPlaylistsReconcilesEachPlaylistOnce() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let viewModel = PlaylistSelectionViewModel()
        let first = PlaylistRecord(musicPlaylistID: "first", name: "First", role: .oneTruePlaylist)
        let second = PlaylistRecord(musicPlaylistID: "second", name: "Second", role: .triage)
        context.insert(first)
        context.insert(second)
        var reconciledIDs: [String] = []
        let dependencies = makeDependencies(
            syncAllCount: 7,
            reconcileStoredOrder: { playlist, _ in
                reconciledIDs.append(playlist.musicPlaylistID)
            }
        )

        await viewModel.syncAllLinkedPlaylists([first, second], context: context, dependencies: dependencies)

        #expect(!viewModel.isSyncingAll)
        #expect(viewModel.message == "Synced 7 tracks across linked playlists.")
        #expect(reconciledIDs == ["first", "second"])
    }

    @Test("adding triage playlist stores local link and message")
    func addingTriagePlaylistStoresLocalLinkAndMessage() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let viewModel = PlaylistSelectionViewModel()
        let playlist = AppleMusicPlaylist(id: "triage", name: "Inbox", trackCount: 3)

        viewModel.addTriage(playlist, context: context)

        let stored = try #require(try PlaylistRepository.playlist(musicPlaylistID: "triage", in: context))
        #expect(stored.role == .triage)
        #expect(viewModel.message == "Added Inbox as a triage playlist.")
    }

    private func makeDependencies(
        fetchedPlaylists: [AppleMusicPlaylist] = [],
        syncAllCount: Int = 0,
        reconcileStoredOrder: @escaping (PlaylistRecord, ModelContext) -> Void = { _, _ in }
    ) -> PlaylistSelectionViewModel.Dependencies {
        PlaylistSelectionViewModel.Dependencies {
            fetchedPlaylists
        } createManagedOneTruePlaylist: { name, _, _ in
            PlaylistRecord(musicPlaylistID: "created", name: name, role: .oneTruePlaylist)
        } syncPlaylist: { _, _ in
            0
        } syncPlaylistID: { _, _ in
            0
        } syncAllLinkedPlaylists: { _ in
            syncAllCount
        } reconcileStoredOrder: { playlist, context in
            reconcileStoredOrder(playlist, context)
        } dismiss: {
        }
    }
}
