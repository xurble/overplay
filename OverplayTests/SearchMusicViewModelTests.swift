import Foundation
import Testing
@testable import Overplay

@MainActor
@Suite("Search music view model")
struct SearchMusicViewModelTests {
    private let result = SearchSongResult(id: "song-1", title: "Song", artistName: "Artist")

    @Test("add to playlist adds the song to the chosen Apple Music playlist and reports it")
    func addToPlaylistReportsSuccess() async {
        var added: [(String, String)] = []
        let viewModel = SearchMusicViewModel { songID, playlistID in
            added.append((songID, playlistID))
            return "Road Trip"
        }

        await viewModel.add(result, toLibraryPlaylistID: "p.road", named: "Road Trip")

        #expect(added.map(\.0) == ["song-1"])
        #expect(added.map(\.1) == ["p.road"])
        #expect(viewModel.addingSongIDs.isEmpty)
        #expect(viewModel.searchService.message == "Added Song to Road Trip.")
    }

    @Test("a failed add reports the playlist and why")
    func addToPlaylistReportsFailure() async {
        struct AddFailure: Error {}
        let viewModel = SearchMusicViewModel { _, _ in throw AddFailure() }

        await viewModel.add(result, toLibraryPlaylistID: "p.road", named: "Road Trip")

        #expect(viewModel.addingSongIDs.isEmpty)
        // An unrecognised error reads as UserFacingError's generic message.
        #expect(viewModel.searchService.message == "Could not add Song to Road Trip: \(UserFacingError.message(for: AddFailure()))")
    }

    @Test("a second add of the same song while the first is in flight does nothing")
    func addIgnoresDuplicateWhileInFlight() async {
        var calls = 0
        var release: CheckedContinuation<Void, Never>?
        let viewModel = SearchMusicViewModel { _, _ in
            calls += 1
            await withCheckedContinuation { release = $0 }
            return "Road Trip"
        }

        let first = Task { await viewModel.add(result, toLibraryPlaylistID: "p.road", named: "Road Trip") }
        while release == nil { await Task.yield() }
        #expect(viewModel.addingSongIDs == ["song-1"])
        await viewModel.add(result, toLibraryPlaylistID: "p.other", named: "Other")
        release?.resume()
        await first.value

        #expect(calls == 1)
        #expect(viewModel.addingSongIDs.isEmpty)
    }
}
