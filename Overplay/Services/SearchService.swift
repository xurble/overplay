import Foundation
@preconcurrency import MusicKit
import Observation

@MainActor
@Observable
final class SearchService {
    var results: [SearchSongResult] = []
    var message: String?
    var isSearching = false

    @ObservationIgnored private var songsByID: [String: Song] = [:]
    @ObservationIgnored private var playlistsByID: [String: Playlist] = [:]

    func search(_ term: String) async {
        let trimmedTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTerm.isEmpty else {
            results = []
            message = nil
            songsByID = [:]
            return
        }

        isSearching = true
        defer { isSearching = false }

        do {
            var request = MusicCatalogSearchRequest(term: trimmedTerm, types: [Song.self])
            request.limit = 20
            let response = try await request.response()
            let songs = Array(response.songs)
            songsByID = Dictionary(uniqueKeysWithValues: songs.map { ($0.id.rawValue, $0) })
            results = songs.map {
                SearchSongResult(
                    id: $0.id.rawValue,
                    title: $0.title,
                    artistName: $0.artistName,
                    albumTitle: $0.albumTitle,
                    artworkURL: $0.artwork?.url(width: 160, height: 160)?.absoluteString
                )
            }
            message = results.isEmpty ? "No songs found." : nil
        } catch {
            results = []
            songsByID = [:]
            message = searchFailureMessage(for: error)
        }
    }

    func addSong(id songID: String, toPlaylistID playlistID: String) async {
        guard let song = songsByID[songID] else {
            message = "Search result is no longer available."
            return
        }

        do {
            let playlist = try await playlist(for: playlistID)
            try await MusicLibrary.shared.add(song, to: playlist)
            message = "Added to \(playlist.name). Sync the playlist to update local tracking."
        } catch {
            message = "Could not add this song to the playlist: \(error.localizedDescription)"
        }
    }

    private func searchFailureMessage(for error: Error) -> String {
        let description = error.localizedDescription
        if description.localizedCaseInsensitiveContains("developer token") {
            return "Apple Music search needs the MusicKit App Service enabled for this app's bundle ID, then a refreshed signing profile."
        }
        return description
    }

    private func playlist(for playlistID: String) async throws -> Playlist {
        if let playlist = playlistsByID[playlistID] {
            return playlist
        }

        let playlist = try await PlaylistSyncService().loadPlaylist(id: playlistID)
        playlistsByID[playlistID] = playlist
        return playlist
    }
}
