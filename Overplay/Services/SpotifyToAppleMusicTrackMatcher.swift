import Foundation
@preconcurrency import MusicKit

enum SpotifyTrackMatchError: LocalizedError {
    case noMatch

    var errorDescription: String? {
        switch self {
        case .noMatch:
            "No Apple Music match was found for this Spotify track."
        }
    }
}

struct SpotifyToAppleMusicTrackMatcher {
    func match(_ spotifyTrack: SpotifyTrack, playlistID: String) async throws -> TrackSnapshot {
        if let isrc = spotifyTrack.isrc,
           let snapshot = try await matchByISRC(isrc, spotifyTrack: spotifyTrack, playlistID: playlistID) {
            return snapshot
        }

        if let snapshot = try await matchBySearch(spotifyTrack, playlistID: playlistID) {
            return snapshot
        }

        throw SpotifyTrackMatchError.noMatch
    }

    private func matchByISRC(
        _ isrc: String,
        spotifyTrack: SpotifyTrack,
        playlistID: String
    ) async throws -> TrackSnapshot? {
        var request = MusicCatalogResourceRequest<Song>(matching: \.isrc, equalTo: isrc)
        request.limit = 1
        let response = try await request.response()
        guard let song = response.items.first else {
            return nil
        }
        return snapshot(from: song, spotifyTrack: spotifyTrack, playlistID: playlistID)
    }

    private func matchBySearch(
        _ spotifyTrack: SpotifyTrack,
        playlistID: String
    ) async throws -> TrackSnapshot? {
        let term = "\(spotifyTrack.name) \(spotifyTrack.artistName)"
        var request = MusicCatalogSearchRequest(term: term, types: [Song.self])
        request.limit = 10
        let response = try await request.response()

        let normalizedTitle = spotifyTrack.name.normalizedForTrackMatching
        let normalizedArtist = spotifyTrack.artistName.normalizedForTrackMatching

        guard let song = response.songs.first(where: { candidate in
            candidate.title.normalizedForTrackMatching == normalizedTitle
                && candidate.artistName.normalizedForTrackMatching == normalizedArtist
        }) ?? response.songs.first(where: { candidate in
            candidate.title.normalizedForTrackMatching == normalizedTitle
        }) else {
            return nil
        }

        return snapshot(from: song, spotifyTrack: spotifyTrack, playlistID: playlistID)
    }

    private func snapshot(from song: Song, spotifyTrack: SpotifyTrack, playlistID: String) -> TrackSnapshot {
        let musicItemID = song.id.rawValue
        return TrackSnapshot(
            id: musicItemID,
            catalogID: musicItemID,
            libraryID: musicItemID,
            playlistEntryID: spotifyTrack.id,
            playlistID: playlistID,
            title: song.title,
            artistName: song.artistName,
            albumTitle: song.albumTitle,
            artworkURLTemplate: song.artwork?.url(width: 512, height: 512)?.absoluteString ?? spotifyTrack.artworkURL,
            durationSeconds: song.duration ?? spotifyTrack.duration_ms.map { Double($0) / 1000 },
            musicKitPlaybackData: try? JSONEncoder().encode(song)
        )
    }
}

private extension String {
    var normalizedForTrackMatching: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
