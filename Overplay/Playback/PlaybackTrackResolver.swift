import Foundation
@preconcurrency import MusicKit
import SwiftData

enum PlaybackTrackResolver {
    static func currentPlaylist(musicPlaylistID: String?, in context: ModelContext) throws -> PlaylistRecord? {
        guard let musicPlaylistID else { return nil }
        return try PlaylistRepository.playlist(musicPlaylistID: musicPlaylistID, in: context)
    }

    static func defaultPlaybackPlaylist(
        settings: OverplaySettings,
        in context: ModelContext
    ) throws -> PlaylistRecord? {
        if let selectedPlaylistID = settings.selectedPlaylistID,
           let playlist = try PlaylistRepository.playlist(musicPlaylistID: selectedPlaylistID, in: context),
           playlist.isActive,
           playlist.role.isPlaybackContext {
            return playlist
        }

        let playbackPlaylists = try PlaylistRepository.activePlaylists(in: context)
            .filter { $0.role.isPlaybackContext }
        return playbackPlaylists.first { $0.role == .oneTruePlaylist } ?? playbackPlaylists.first
    }

    static func snapshot(from track: Track, playlistID: String?) -> TrackSnapshot {
        let identity = MusicTrackIdentity.ids(for: track)
        return TrackSnapshot(
            id: track.id.rawValue,
            catalogID: identity.catalogID,
            libraryID: identity.libraryID,
            playlistEntryID: nil,
            playlistID: playlistID,
            title: track.title,
            artistName: track.artistName,
            albumTitle: track.albumTitle,
            artworkURLTemplate: track.artwork?.url(width: 512, height: 512)?.absoluteString,
            durationSeconds: track.duration,
            musicKitPlaybackData: try? JSONEncoder().encode(track),
            isrc: track.isrc
        )
    }
}
