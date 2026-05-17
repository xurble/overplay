import Foundation
@preconcurrency import MusicKit
import SwiftData

enum PlaylistSyncError: LocalizedError {
    case playlistNotFound
    case playlistHasNoTracks
    case trackNotFoundInPlaylist

    var errorDescription: String? {
        switch self {
        case .playlistNotFound:
            "The selected Apple Music playlist could not be found."
        case .playlistHasNoTracks:
            "The selected playlist did not return any playable tracks."
        case .trackNotFoundInPlaylist:
            "The evicted track was not found in the selected Apple Music playlist."
        }
    }
}

@MainActor
struct PlaylistSyncService {
    func fetchLibraryPlaylists() async throws -> [AppleMusicPlaylist] {
        var request = MusicLibraryRequest<Playlist>()
        request.limit = 100
        request.sort(by: \.name, ascending: true)
        let response = try await request.response()

        return response.items
            .map { playlist in
                AppleMusicPlaylist(
                    id: playlist.id.rawValue,
                    name: playlist.name,
                    trackCount: playlist.tracks?.count
                )
            }
            .sorted { left, right in
                if left.isPreferredOverplayPlaylist != right.isPreferredOverplayPlaylist {
                    return left.isPreferredOverplayPlaylist
                }
                return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
            }
    }

    func syncPlaylist(id playlistID: String, in context: ModelContext) async throws -> Int {
        let playlist = try await loadPlaylist(id: playlistID)
        let tracks = try await loadTracks(for: playlist)

        for snapshot in tracks.map({ snapshot(from: $0, playlistID: playlistID) }) {
            try TrackRepository.upsert(snapshot, in: context)
        }

        try context.save()
        return tracks.count
    }

    func playableMusicTracks(for playlistID: String, in context: ModelContext) async throws -> [Track] {
        let playlist = try await loadPlaylist(id: playlistID)
        let tracks = try await loadTracks(for: playlist)
        let localTracks = try TrackRepository.tracks(forPlaylistID: playlistID, in: context)
        let evictedIDs = Set(localTracks.filter(\.isEvicted).map(\.id))
        return tracks.filter { !evictedIDs.contains($0.id.rawValue) }
    }

    func removeTrackFromPlaylist(trackID: String, playlistID: String) async throws {
        let playlist = try await loadPlaylist(id: playlistID)
        let tracks = try await loadTracks(for: playlist)
        let remainingTracks = tracks.filter { $0.id.rawValue != trackID }

        guard remainingTracks.count < tracks.count else {
            throw PlaylistSyncError.trackNotFoundInPlaylist
        }

        try await MusicLibrary.shared.edit(playlist, items: remainingTracks)
    }

    func loadPlaylist(id playlistID: String) async throws -> Playlist {
        var request = MusicLibraryRequest<Playlist>()
        request.filter(matching: \.id, equalTo: MusicItemID(playlistID))
        request.limit = 1
        guard let playlist = try await request.response().items.first else {
            throw PlaylistSyncError.playlistNotFound
        }
        return playlist
    }

    private func loadTracks(for playlist: Playlist) async throws -> [Track] {
        let detailedPlaylist = try await playlist.with(.tracks)
        guard let tracks = detailedPlaylist.tracks else {
            throw PlaylistSyncError.playlistHasNoTracks
        }
        return Array(tracks)
    }

    private func snapshot(from track: Track, playlistID: String) -> TrackSnapshot {
        TrackSnapshot(
            id: track.id.rawValue,
            catalogID: track.id.rawValue,
            libraryID: track.id.rawValue,
            playlistEntryID: nil,
            playlistID: playlistID,
            title: track.title,
            artistName: track.artistName,
            albumTitle: track.albumTitle,
            artworkURLTemplate: track.artwork?.url(width: 512, height: 512)?.absoluteString,
            durationSeconds: track.duration
        )
    }
}
