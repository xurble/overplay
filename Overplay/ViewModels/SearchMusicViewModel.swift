import Foundation
import Observation

/// Search state and the one action that is search's own: adding a result to
/// another Apple Music playlist. Sending a song to the One True Playlist or
/// Triage, and playing it, use the shared playback actions.
@MainActor
@Observable
final class SearchMusicViewModel {
    var searchText = ""
    var searchService: SearchService
    var addingSongIDs = Set<String>()

    /// Adds a search result to an Apple Music playlist; returns the
    /// playlist's name. Injected for tests.
    @ObservationIgnored
    var addSong: (_ songID: String, _ playlistID: String) async throws -> String

    init(
        searchService: SearchService = SearchService(),
        addSong: ((_ songID: String, _ playlistID: String) async throws -> String)? = nil
    ) {
        self.searchService = searchService
        self.addSong = addSong ?? { songID, playlistID in
            try await searchService.addSong(id: songID, toPlaylistID: playlistID)
        }
    }

    /// Adds a result to any Apple Music playlist, as the Music app does.
    /// MusicKit can add to a playlist Overplay didn't create.
    func add(_ result: SearchSongResult, toLibraryPlaylistID playlistID: String, named name: String) async {
        guard addingSongIDs.insert(result.id).inserted else { return }
        defer { addingSongIDs.remove(result.id) }
        do {
            _ = try await addSong(result.id, playlistID)
            searchService.message = "Added \(result.title) to \(name)."
        } catch {
            searchService.message = "Could not add \(result.title) to \(name): \(UserFacingError.message(for: error))"
        }
    }

    func clearSearchIfNeeded(_ newValue: String) async {
        if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await searchService.search("")
        }
    }
}
