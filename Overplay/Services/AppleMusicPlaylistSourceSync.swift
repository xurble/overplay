import Foundation
@preconcurrency import MusicKit
import SwiftData

@MainActor
struct AppleMusicPlaylistSourceSync: PlaylistSourceSyncing {
    let source: PlaylistSource = .appleMusic

    /// Tracks requested per batch when paging a playlist's tracks.
    static let trackPageLimit = 100

    private let playlistFetcher: any MusicLibraryPlaylistFetching

    init(playlistFetcher: any MusicLibraryPlaylistFetching = CachingMusicLibraryPlaylistFetcher.shared) {
        self.playlistFetcher = playlistFetcher
    }

    func fetchLibraryPlaylists() async throws -> [RemotePlaylistLink] {
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
        skipWhenRemoteUnchanged: Bool,
        in context: ModelContext
    ) async throws -> PlaylistSourceFetchResult {
        let playlist = try await loadPlaylist(
            id: playlistID,
            name: playlistName,
            playlistRecord: playlistRecord,
            in: context
        )

        // Paging a playlist's tracks is by far the most expensive part of a
        // sync. Apple Music already tells us when the playlist last changed,
        // so an automatic cycle can stop here when nothing has.
        if skipWhenRemoteUnchanged,
           PlaylistRemoteChangePolicy.isUnchanged(
            remoteLastModifiedAt: playlist.lastModifiedDate,
            storedLastModifiedAt: playlistRecord?.remoteLastModifiedAt,
            hasSyncedSuccessfully: playlistRecord?.lastSyncedAt != nil
                && playlistRecord?.lastSyncError == nil
           ) {
            return PlaylistSourceFetchResult(
                snapshots: [],
                skippedCount: 0,
                skippedReason: "remoteUnchanged",
                remoteLastModifiedAt: playlist.lastModifiedDate,
                didFetchTracks: false
            )
        }

        let tracks = try await loadTracks(for: playlist)
        // Snapshot mapping JSON-encodes every track's playback data on the
        // main actor; yield periodically so large playlists don't stall UI.
        var snapshots: [TrackSnapshot] = []
        snapshots.reserveCapacity(tracks.count)
        for (index, track) in tracks.enumerated() {
            if index > 0, index.isMultiple(of: PlaylistSyncService.syncYieldStride) {
                await Task.yield()
            }
            snapshots.append(snapshot(from: track, playlistID: playlistID))
        }
        do { snapshots = try await MusicIdentityResolver.shared.enrich(snapshots) }
        catch is CancellationError { throw CancellationError() }
        catch { TrackMetadataDiagnostics.log("Documented identity enrichment unavailable: \(error.localizedDescription)") }
        return PlaylistSourceFetchResult(
            snapshots: snapshots,
            skippedCount: 0,
            skippedReason: nil,
            remoteLastModifiedAt: playlist.lastModifiedDate,
            didFetchTracks: true
        )
    }

    func loadPlaylist(
        id playlistID: String,
        name: String? = nil,
        playlistRecord: PlaylistRecord? = nil,
        in context: ModelContext? = nil
    ) async throws -> Playlist {
        // The common case is a playlist whose stored ID is still correct, so
        // try the single filtered lookup before paging the whole library.
        if let playlist = try? await playlistFetcher.fetchPlaylist(id: playlistID) {
            return playlist
        }

        // The stored ID no longer resolves. Only now is the full enumeration
        // worth it, because name-based healing needs every candidate.
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

    func applyHealedMusicPlaylistID(
        from oldID: String,
        to newID: String,
        playlistRecord: PlaylistRecord,
        in context: ModelContext
    ) throws {
        // A former contributor can retain rows in the bucket after becoming
        // the One True Playlist. Heal every matching provenance reference,
        // not only those whose playlist is currently a triage source.
        for item in try PlaylistItemRepository.allItems(in: context) {
            var changed = item.replaceSourceMusicPlaylistID(from: oldID, to: newID)
            if item.suppressedOTPMusicPlaylistIDs.contains(oldID) {
                item.suppressedOTPMusicPlaylistIDs.removeAll { $0 == oldID }
                if !item.suppressedOTPMusicPlaylistIDs.contains(newID) {
                    item.suppressedOTPMusicPlaylistIDs.append(newID)
                }
                changed = true
            }
            if changed { item.updatedAt = .now }
        }

        playlistRecord.musicPlaylistID = newID
        playlistRecord.updatedAt = .now

        let settings = try SettingsRepository.settings(in: context)
        if settings.selectedPlaylistID == oldID {
            settings.selectedPlaylistID = newID
            settings.updatedAt = .now
        }

        PlaybackOrderStore.rekeyMusicPlaylistID(from: oldID, to: newID, flushImmediately: true)
        LocalPlaybackStateStore.rekeyMusicPlaylistID(from: oldID, to: newID, flushImmediately: true)
        PlaybackIdentityStore.rekeyMusicPlaylistID(from: oldID, to: newID, flushImmediately: true)
        try context.save()
    }

    private func loadTracks(for playlist: Playlist) async throws -> [Track] {
        try await AppleMusicPlaylistTrackLoader.loadTracks(for: playlist)
    }

    private func snapshot(from track: Track, playlistID: String) -> TrackSnapshot {
        AppleMusicPlaylistTrackLoader.snapshot(from: track, playlistID: playlistID)
    }
}

/// Loads a library playlist's complete track list.
///
/// Shared by every caller because the pagination matters: `with(.tracks)`
/// returns only the first batch, and treating that as the whole playlist
/// makes sync see phantom removals and makes a playlist rewrite drop the
/// tracks it never saw.
@MainActor
enum AppleMusicPlaylistTrackLoader {
    static func loadTracks(for playlist: Playlist) async throws -> [Track] {
        let detailedPlaylist = try await MusicKitActivityLog.shared.measure(
            .playlistTrackFetch,
            detail: "first batch",
            resultMagnitude: { Double($0.tracks?.count ?? 0) }
        ) {
            try await playlist.with(.tracks)
        }

        var collection = detailedPlaylist.tracks
        return try await collectCompleteTracks(
            firstBatch: collection.map(Array.init),
            hasNextBatch: collection?.hasNextBatch ?? false
        ) {
            guard let current = collection else { throw PlaylistSyncError.incompletePlaylist }
            let batch = try await MusicKitActivityLog.shared.measure(
                .playlistTrackFetch,
                detail: "next batch",
                resultMagnitude: { $0.map { Double($0.count) } }
            ) {
                try await current.nextBatch(limit: AppleMusicPlaylistSourceSync.trackPageLimit)
            }
            collection = batch
            return batch.map { (tracks: Array($0), hasNextBatch: $0.hasNextBatch) }
        }
    }

    /// Missing relationships/pages are not proof of remote absence. Keep the
    /// pagination boundary injectable without requiring live MusicKit tests.
    static func collectCompleteTracks(
        firstBatch: [Track]?,
        hasNextBatch: Bool,
        nextBatch: () async throws -> (tracks: [Track], hasNextBatch: Bool)?
    ) async throws -> [Track] {
        guard var tracks = firstBatch else { throw PlaylistSyncError.incompletePlaylist }
        var hasNextBatch = hasNextBatch
        while hasNextBatch {
            guard let batch = try await nextBatch() else {
                // MusicKit promised another batch and then declined to give
                // it. The result is an incomplete playlist, which callers
                // must not treat as the whole remote track list, so flag it
                // where the diagnostics report will surface it.
                MusicKitActivityLog.shared.record(
                    .playlistTrackFetch,
                    magnitude: Double(tracks.count),
                    detail: "next batch missing after hasNextBatch",
                    notes: [.truncatedCollection]
                )
                throw PlaylistSyncError.incompletePlaylist
            }
            tracks.append(contentsOf: batch.tracks)
            hasNextBatch = batch.hasNextBatch
        }

        return tracks
    }

    static func snapshot(from track: Track, playlistID: String) -> TrackSnapshot {
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
