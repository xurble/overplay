import Foundation
@preconcurrency import MusicKit
import SwiftData

@MainActor
struct AppleMusicPlaylistSourceSync: PlaylistSourceSyncing {
    let source: PlaylistSource = .appleMusic

    private let playlistFetcher: any MusicLibraryPlaylistFetching

    init(playlistFetcher: any MusicLibraryPlaylistFetching = MusicKitLibraryPlaylistFetcher()) {
        self.playlistFetcher = playlistFetcher
    }

    func fetchLibraryPlaylists(in context: ModelContext) async throws -> [RemotePlaylistLink] {
        let playlists = try await playlistFetcher.fetchAllPlaylists(pageLimit: 100)
        let appleMusicPlaylists = playlists.map {
            AppleMusicPlaylist(
                id: $0.id.rawValue,
                name: $0.name,
                trackCount: $0.tracks?.count
            )
        }
        return AppleMusicPlaylistDisplayOrder.sorted(appleMusicPlaylists).map(RemotePlaylistLink.init)
    }

    func fetchTrackSnapshots(
        playlistID: String,
        playlistName: String?,
        playlistRecord: PlaylistRecord?,
        in context: ModelContext
    ) async throws -> PlaylistSourceFetchResult {
        let playlist = try await loadPlaylist(
            id: playlistID,
            name: playlistName,
            playlistRecord: playlistRecord,
            in: context
        )
        let tracks = try await loadTracks(for: playlist)
        let snapshots = tracks.map { snapshot(from: $0, playlistID: playlistID) }
        return PlaylistSourceFetchResult(snapshots: snapshots, skippedCount: 0, skippedReason: nil)
    }

    func loadPlaylist(
        id playlistID: String,
        name: String? = nil,
        playlistRecord: PlaylistRecord? = nil,
        in context: ModelContext? = nil
    ) async throws -> Playlist {
        let libraryPlaylists = try await playlistFetcher.fetchAllPlaylists(pageLimit: 100)
        let candidates = libraryPlaylists.map {
            PlaylistLibraryIDResolver.Candidate(id: $0.id.rawValue, name: $0.name)
        }

        guard let resolvedID = PlaylistLibraryIDResolver.resolvedMusicPlaylistID(
            storedID: playlistID,
            name: name,
            libraryPlaylists: candidates
        ) else {
            throw PlaylistSyncError.playlistNotFound
        }

        if resolvedID != playlistID,
           let playlistRecord,
           let context {
            try applyHealedMusicPlaylistID(
                from: playlistID,
                to: resolvedID,
                playlistRecord: playlistRecord,
                in: context
            )
        }

        guard let playlist = libraryPlaylists.first(where: { $0.id.rawValue == resolvedID }) else {
            throw PlaylistSyncError.playlistNotFound
        }

        return playlist
    }

    private func applyHealedMusicPlaylistID(
        from oldID: String,
        to newID: String,
        playlistRecord: PlaylistRecord,
        in context: ModelContext
    ) throws {
        playlistRecord.musicPlaylistID = newID
        playlistRecord.updatedAt = .now

        let settings = try SettingsRepository.settings(in: context)
        if settings.selectedPlaylistID == oldID {
            settings.selectedPlaylistID = newID
            settings.updatedAt = .now
        }

        PlaybackModeStore.rekeyMusicPlaylistID(from: oldID, to: newID, flushImmediately: true)
        LocalPlaybackStateStore.rekeyMusicPlaylistID(from: oldID, to: newID, flushImmediately: true)
        PlaybackIdentityStore.rekeyMusicPlaylistID(from: oldID, to: newID, flushImmediately: true)
        try context.save()
    }

    private func loadTracks(for playlist: Playlist) async throws -> [Track] {
        let detailedPlaylist = try await playlist.with(.tracks)
        return Array(detailedPlaylist.tracks ?? [])
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
            durationSeconds: track.duration,
            musicKitPlaybackData: try? JSONEncoder().encode(track)
        )
    }
}
