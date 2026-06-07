import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("Search music view model")
struct SearchMusicViewModelTests {
    @Test("default selection prefers initial playlist then settings")
    func defaultSelectionPrefersInitialPlaylistThenSettings() {
        let viewModel = SearchMusicViewModel()
        let main = PlaylistRecord(musicPlaylistID: "main", name: "Main", role: .oneTruePlaylist)
        let triage = PlaylistRecord(musicPlaylistID: "triage", name: "Inbox", role: .triage)
        let incoming = PlaylistRecord(
            musicPlaylistID: "incoming",
            name: "Incoming",
            role: .triage,
            writePolicy: .incomingOnly
        )
        let settings = OverplaySettings(selectedPlaylistID: "main", selectedPlaylistName: "Main")

        viewModel.selectDefaultPlaylistIfNeeded(
            playlists: [main, triage, incoming],
            settings: settings,
            initialPlaylistID: "triage"
        )

        #expect(viewModel.selectedPlaylistRecordID == triage.id)
        #expect(viewModel.activePlaylists(from: [main, triage, incoming]).map(\.id) == [main.id, triage.id])
    }

    @Test("add records success syncs and reports destination")
    func addRecordsSuccessSyncsAndReportsDestination() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let viewModel = SearchMusicViewModel()
        let playlist = PlaylistRecord(musicPlaylistID: "main", name: "Main", role: .oneTruePlaylist)
        context.insert(playlist)
        viewModel.selectedPlaylistRecordID = playlist.id
        var addedSongIDs: [String] = []
        var didRecordSuccess = false
        var didSync = false
        let dependencies = makeDependencies(
            addSong: { songID, _ in
                addedSongIDs.append(songID)
                return "Main"
            },
            recordSuccessfulManualAdd: { _, _, _ in
                didRecordSuccess = true
            },
            syncPlaylist: { _, _ in
                didSync = true
            }
        )
        let result = SearchSongResult(id: "song-1", title: "Song", artistName: "Artist")

        await viewModel.add(result, playlists: [playlist], context: context, dependencies: dependencies)

        #expect(addedSongIDs == ["song-1"])
        #expect(didRecordSuccess)
        #expect(didSync)
        #expect(viewModel.addingSongIDs.isEmpty)
        #expect(viewModel.searchService.message == "Added Song to Main.")
    }

    @Test("add reports sync failure after successful remote add")
    func addReportsSyncFailureAfterSuccessfulRemoteAdd() async throws {
        struct SyncFailure: LocalizedError {
            var errorDescription: String? { "Sync failed." }
        }

        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let viewModel = SearchMusicViewModel()
        let playlist = PlaylistRecord(musicPlaylistID: "main", name: "Main", role: .oneTruePlaylist)
        context.insert(playlist)
        viewModel.selectedPlaylistRecordID = playlist.id
        let dependencies = makeDependencies(
            syncPlaylist: { _, _ in
                throw SyncFailure()
            }
        )
        let result = SearchSongResult(id: "song-1", title: "Song", artistName: "Artist")

        await viewModel.add(result, playlists: [playlist], context: context, dependencies: dependencies)

        #expect(viewModel.searchService.message == "Added to Main, but sync failed: Sync failed.")
    }

    private func makeDependencies(
        addSong: @escaping (String, String) async throws -> String = { _, _ in "Playlist" },
        recordSuccessfulManualAdd: @escaping (SearchSongResult, PlaylistRecord, ModelContext) throws -> Void = { _, _, _ in },
        recordFailedManualAdd: @escaping (SearchSongResult, PlaylistRecord, String, ModelContext) -> Void = { _, _, _, _ in },
        syncPlaylist: @escaping (PlaylistRecord, ModelContext) async throws -> Void = { _, _ in },
        reconcileStoredOrder: @escaping (PlaylistRecord, ModelContext) -> Void = { _, _ in }
    ) -> SearchMusicViewModel.Dependencies {
        SearchMusicViewModel.Dependencies(
            addSong: addSong,
            recordSuccessfulManualAdd: recordSuccessfulManualAdd,
            recordFailedManualAdd: recordFailedManualAdd,
            syncPlaylist: syncPlaylist,
            reconcileStoredOrder: reconcileStoredOrder
        )
    }
}
