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
        let record = try PlaylistRepository.upsert(
            musicPlaylistID: playlistID,
            name: playlist.name,
            role: try PlaylistRepository.playlist(musicPlaylistID: playlistID, in: context)?.role ?? .oneTruePlaylist,
            in: context
        )
        return try await syncPlaylist(record, in: context)
    }

    func syncPlaylist(_ playlistRecord: PlaylistRecord, in context: ModelContext) async throws -> Int {
        let playlist = try await loadPlaylist(id: playlistRecord.musicPlaylistID)
        let tracks = try await loadTracks(for: playlist)
        let snapshots = tracks.map { snapshot(from: $0, playlistID: playlistRecord.musicPlaylistID) }

        try reconcile(
            snapshots: snapshots,
            playlistRecord: playlistRecord,
            syncedAt: .now,
            in: context
        )
        try context.save()
        return tracks.count
    }

    func syncAllLinkedPlaylists(in context: ModelContext) async throws -> Int {
        let playlists = try PlaylistRepository.activePlaylists(in: context)
        var syncedCount = 0

        for playlist in playlists {
            syncedCount += try await syncPlaylist(playlist, in: context)
        }

        return syncedCount
    }

    @discardableResult
    func reconcile(
        snapshots: [TrackSnapshot],
        playlistRecord: PlaylistRecord,
        syncedAt: Date,
        in context: ModelContext
    ) throws -> Int {
        var seenTrackIDs = Set<UUID>()

        for (sortOrder, snapshot) in snapshots.enumerated() {
            let track = try TrackRecordRepository.upsert(snapshot, in: context)
            let item = try PlaylistItemRepository.upsert(
                playlistID: playlistRecord.id,
                trackID: track.id,
                musicPlaylistEntryID: snapshot.playlistEntryID,
                sortOrder: sortOrder,
                in: context
            )
            item.lastSeenInPlaylistAt = syncedAt
            item.removedFromRemoteAt = nil
            seenTrackIDs.insert(track.id)
        }

        try reconcileRemoteRemovals(
            playlistRecord: playlistRecord,
            seenTrackIDs: seenTrackIDs,
            removedAt: syncedAt,
            in: context
        )

        playlistRecord.lastSyncedAt = syncedAt
        playlistRecord.lastSyncError = nil
        playlistRecord.updatedAt = syncedAt
        return snapshots.count
    }

    func reconcileRemoteRemovals(
        playlistRecord: PlaylistRecord,
        seenTrackIDs: Set<UUID>,
        removedAt: Date,
        in context: ModelContext
    ) throws {
        let existingItems = try PlaylistItemRepository.items(forPlaylistID: playlistRecord.id, in: context)

        for item in existingItems where !seenTrackIDs.contains(item.trackID) && item.removedFromRemoteAt == nil {
            item.removedFromRemoteAt = removedAt
            item.updatedAt = removedAt

            if item.evictedAt == nil {
                item.evictedAt = removedAt
                item.evictionReason = .manual
                item.evictionSource = .appleMusicSync
            }

            EventRepository.logHistory(
                playlistID: playlistRecord.id,
                trackID: item.trackID,
                eventType: .trackRemoved,
                source: .appleMusic,
                skipCountAtEvent: item.skipCount,
                message: "Removed from Apple Music playlist",
                in: context
            )
        }
    }

    func playableMusicTracks(for playlistID: String, in context: ModelContext) async throws -> [Track] {
        if let playlistRecord = try PlaylistRepository.playlist(musicPlaylistID: playlistID, in: context) {
            return try await playableMusicTracks(for: playlistRecord, in: context)
        }

        let playlist = try await loadPlaylist(id: playlistID)
        return try await loadTracks(for: playlist)
    }

    func playableMusicTracks(for playlistRecord: PlaylistRecord, in context: ModelContext) async throws -> [Track] {
        let items = try PlaylistItemRepository.items(forPlaylistID: playlistRecord.id, in: context)
        let tracksByID = Dictionary(uniqueKeysWithValues: try TrackRecordRepository.allTracks(in: context).map { ($0.id, $0) })
        let playableMusicItemIDs = PlaybackQueueBuilder.playableMusicItemIDs(
            items: items,
            tracksByID: tracksByID
        )

        guard !playableMusicItemIDs.isEmpty else {
            return []
        }

        let playlist = try await loadPlaylist(id: playlistRecord.musicPlaylistID)
        let tracks = try await loadTracks(for: playlist)
        return tracks.filter { playableMusicItemIDs.contains($0.id.rawValue) }
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
            durationSeconds: track.duration,
            musicKitPlaybackData: try? JSONEncoder().encode(track)
        )
    }
}
