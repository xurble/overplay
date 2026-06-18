import Foundation
@preconcurrency import MusicKit
import SwiftData

enum PlaybackTrackResolver {
    static func currentPlaylist(musicPlaylistID: String?, in context: ModelContext) throws -> PlaylistRecord? {
        guard let musicPlaylistID else { return nil }
        return try PlaylistRepository.playlist(musicPlaylistID: musicPlaylistID, in: context)
    }

    static func playlistItem(
        matching musicItemID: String,
        musicPlaylistID: String?,
        currentPlaylistItem: PlaylistItemRecord?,
        in context: ModelContext
    ) throws -> PlaylistItemRecord? {
        guard let playlist = try currentPlaylist(musicPlaylistID: musicPlaylistID, in: context) else { return nil }
        return try PlaybackSessionSupport.resolvePlaylistItem(
            forMusicItemID: musicItemID,
            currentPlaylistItem: currentPlaylistItem,
            playlist: playlist,
            in: context
        )
    }

    static func playlistItem(
        localTrackID: String,
        musicPlaylistID: String?,
        in context: ModelContext
    ) throws -> PlaylistItemRecord? {
        guard let playlist = try currentPlaylist(musicPlaylistID: musicPlaylistID, in: context),
              let trackID = UUID(uuidString: localTrackID) else {
            return nil
        }

        return try PlaylistItemRepository.items(forPlaylistID: playlist.id, in: context).first {
            $0.trackID == trackID
        }
    }

    static func restoredTrackAndItem(
        from state: LocalPlaybackState,
        playlist: PlaylistRecord,
        in context: ModelContext
    ) throws -> (track: TrackRecord, item: PlaylistItemRecord?)? {
        if let localTrackID = state.localTrackID,
           let trackID = UUID(uuidString: localTrackID),
           let track = try TrackRecordRepository.track(id: trackID, in: context) {
            let item = try PlaylistItemRepository.item(
                playlistID: playlist.id,
                trackID: track.id,
                in: context
            )
            return (track, item)
        }

        guard let track = try TrackRecordRepository.track(musicItemID: state.musicItemID, in: context) else {
            return nil
        }

        let item = try PlaylistItemRepository.item(
            playlistID: playlist.id,
            trackID: track.id,
            in: context
        )
        return (track, item)
    }

    static func restoredPlaybackTarget(
        currentPlaylistID: String?,
        currentPlaylistItem: PlaylistItemRecord?,
        currentTrack: CurrentPlaybackTrack?,
        in context: ModelContext
    ) throws -> (playlist: PlaylistRecord, track: TrackRecord)? {
        guard let playlist = try currentPlaylist(musicPlaylistID: currentPlaylistID, in: context),
              playlist.isActive else {
            return nil
        }

        if let currentPlaylistItem,
           currentPlaylistItem.playlistID == playlist.id,
           let track = try TrackRecordRepository.track(id: currentPlaylistItem.trackID, in: context) {
            return (playlist, track)
        }

        if let musicItemID = currentTrack?.id,
           let item = try PlaybackSessionSupport.resolvePlaylistItem(
               forMusicItemID: musicItemID,
               currentPlaylistItem: currentPlaylistItem,
               playlist: playlist,
               in: context
           ),
           let track = try TrackRecordRepository.track(id: item.trackID, in: context) {
            return (playlist, track)
        }

        return nil
    }

    static func defaultPlaybackPlaylist(
        settings: OverplaySettings,
        in context: ModelContext
    ) throws -> PlaylistRecord? {
        if let selectedPlaylistID = settings.selectedPlaylistID,
           let playlist = try PlaylistRepository.playlist(musicPlaylistID: selectedPlaylistID, in: context),
           playlist.isActive {
            return playlist
        }

        let playlists = try PlaylistRepository.activePlaylists(in: context)
        return playlists.first { $0.role == .oneTruePlaylist } ?? playlists.first
    }

    static func currentPlaybackTrack(
        musicItemID: String,
        playlistItem: PlaylistItemRecord?,
        musicPlaylistID: String?,
        queueItem: MusicPlayer.Queue.Entry.Item?,
        trustPlaylistItem: Bool = false,
        in context: ModelContext
    ) -> CurrentPlaybackTrack? {
        if let playlistItem,
           (
               trustPlaylistItem ||
               (try? PlaybackSessionSupport.itemMatchesMusicItemID(
                   playlistItem,
                   musicItemID: musicItemID,
                   in: context
               )) == true
           ),
           let trackRecord = try? TrackRecordRepository.track(id: playlistItem.trackID, in: context) {
            return CurrentPlaybackTrack(trackRecord, musicItemID: musicItemID, item: playlistItem)
        }

        if let trackRecord = try? TrackRecordRepository.track(musicItemID: musicItemID, in: context) {
            return CurrentPlaybackTrack(trackRecord, musicItemID: musicItemID, item: nil)
        }

        guard let snapshot = snapshot(from: queueItem, playlistID: musicPlaylistID) else {
            return nil
        }

        return CurrentPlaybackTrack(snapshot)
    }

    static func snapshot(from track: Track, playlistID: String?) -> TrackSnapshot {
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
            durationSeconds: track.duration,
            musicKitPlaybackData: try? JSONEncoder().encode(track)
        )
    }

    private static func snapshot(from item: MusicPlayer.Queue.Entry.Item?, playlistID: String?) -> TrackSnapshot? {
        guard let item else { return nil }

        switch item {
        case let .song(song):
            return TrackSnapshot(
                id: song.id.rawValue,
                catalogID: song.id.rawValue,
                libraryID: song.id.rawValue,
                playlistEntryID: nil,
                playlistID: playlistID,
                title: song.title,
                artistName: song.artistName,
                albumTitle: song.albumTitle,
                artworkURLTemplate: song.artwork?.url(width: 512, height: 512)?.absoluteString,
                durationSeconds: song.duration
            )
        case let .musicVideo(musicVideo):
            return TrackSnapshot(
                id: musicVideo.id.rawValue,
                catalogID: musicVideo.id.rawValue,
                libraryID: musicVideo.id.rawValue,
                playlistEntryID: nil,
                playlistID: playlistID,
                title: musicVideo.title,
                artistName: musicVideo.artistName,
                albumTitle: nil,
                artworkURLTemplate: musicVideo.artwork?.url(width: 512, height: 512)?.absoluteString,
                durationSeconds: musicVideo.duration
            )
        @unknown default:
            return nil
        }
    }
}
