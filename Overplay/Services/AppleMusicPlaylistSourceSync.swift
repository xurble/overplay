import Foundation
@preconcurrency import MusicKit
import SwiftData

@MainActor
struct AppleMusicPlaylistSourceSync: PlaylistSourceSyncing {
    let source: PlaylistSource = .appleMusic

    /// Entries requested per batch when paging a playlist.
    static let entryPageLimit = 100

    private let playlistFetcher: any MusicLibraryPlaylistFetching
    private let entryLoader: (Playlist) async throws -> [Playlist.Entry]

    init(
        playlistFetcher: any MusicLibraryPlaylistFetching = CachingMusicLibraryPlaylistFetcher.shared,
        entryLoader: @escaping (Playlist) async throws -> [Playlist.Entry] = AppleMusicPlaylistTrackLoader.loadEntries
    ) {
        self.playlistFetcher = playlistFetcher
        self.entryLoader = entryLoader
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
           playlistRecord?.hasSyncedPlaylistEntries == true,
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

        let entries = try await entryLoader(playlist)
        _ = try AppleMusicPlaylistTrackLoader.completeTracks(from: entries)
        // Snapshot mapping JSON-encodes every track's playback data on the
        // main actor; yield periodically so large playlists don't stall UI.
        var snapshots: [TrackSnapshot] = []
        snapshots.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            if index > 0, index.isMultiple(of: PlaylistSyncService.syncYieldStride) {
                await Task.yield()
            }
            if let snapshot = AppleMusicPlaylistTrackLoader.snapshot(from: entry, playlistID: playlistID) {
                snapshots.append(snapshot)
            }
        }
        do { snapshots = try await MusicIdentityResolver.shared.enrich(snapshots) }
        catch is CancellationError { throw CancellationError() }
        catch { TrackMetadataDiagnostics.log("Documented identity enrichment unavailable: \(error.localizedDescription)") }
        return PlaylistSourceFetchResult(
            snapshots: snapshots,
            skippedCount: entries.count - snapshots.count,
            skippedReason: entries.count == snapshots.count ? nil : "nonSongEntries",
            remoteLastModifiedAt: playlist.lastModifiedDate,
            didFetchTracks: true,
            didFetchEntries: true
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
}

/// One complete entry boundary for sync, copies, and destructive rewrites.
@MainActor
enum AppleMusicPlaylistTrackLoader {
    static func loadEntries(for playlist: Playlist) async throws -> [Playlist.Entry] {
        let detailed = try await MusicKitActivityLog.shared.measure(
            .playlistTrackFetch, detail: "first entry batch",
            resultMagnitude: { Double($0.entries?.count ?? 0) }
        ) {
            try await playlist.with(.entries)
        }
        var collection = detailed.entries
        return try await collectCompleteEntries(
            firstBatch: collection.map(Array.init),
            hasNextBatch: collection?.hasNextBatch ?? false,
            identity: { $0.id.rawValue.isEmpty ? "position:\($0.position)" : $0.id.rawValue }
        ) {
            guard let current = collection else { throw PlaylistSyncError.incompletePlaylist }
            let batch = try await MusicKitActivityLog.shared.measure(
                .playlistTrackFetch, detail: "next entry batch",
                resultMagnitude: { $0.map { Double($0.count) } }
            ) {
                try await current.nextBatch(limit: AppleMusicPlaylistSourceSync.entryPageLimit)
            }
            collection = batch
            return batch.map { (entries: Array($0), hasNextBatch: $0.hasNextBatch) }
        }
    }

    static func loadTracks(for playlist: Playlist) async throws -> [Track] {
        try completeTracks(from: await loadEntries(for: playlist))
    }

    /// A rewrite must retain videos and duplicate songs. An unavailable item
    /// makes the whole operation unsafe, even when every page was fetched.
    static func completeTracks(from entries: [Playlist.Entry]) throws -> [Track] {
        try completeTracks(from: entries.map(\.item))
    }

    static func completeTracks(from items: [Playlist.Entry.Item?]) throws -> [Track] {
        try items.map { item in
            switch item {
            case .song(let song): return .song(song)
            case .musicVideo(let video): return .musicVideo(video)
            default: throw PlaylistSyncError.incompletePlaylist
            }
        }
    }

    /// Reject missing, repeated, overlapping, or empty promised pages before
    /// any caller can mistake a partial result for proof of remote absence.
    static func collectCompleteEntries<Entry>(
        firstBatch: [Entry]?, hasNextBatch: Bool,
        identity: (Entry) -> String,
        nextBatch: () async throws -> (entries: [Entry], hasNextBatch: Bool)?
    ) async throws -> [Entry] {
        try Task.checkCancellation()
        guard var entries = firstBatch else { throw PlaylistSyncError.incompletePlaylist }
        var seen = Set(entries.map(identity))
        guard seen.count == entries.count, !hasNextBatch || !entries.isEmpty else {
            throw PlaylistSyncError.incompletePlaylist
        }
        var more = hasNextBatch
        while more {
            try Task.checkCancellation()
            guard let batch = try await nextBatch(), !batch.entries.isEmpty else {
                MusicKitActivityLog.shared.record(
                    .playlistTrackFetch, magnitude: Double(entries.count),
                    detail: "entry page missing or empty after hasNextBatch",
                    notes: [.truncatedCollection]
                )
                throw PlaylistSyncError.incompletePlaylist
            }
            for entry in batch.entries {
                guard seen.insert(identity(entry)).inserted else { throw PlaylistSyncError.incompletePlaylist }
            }
            entries.append(contentsOf: batch.entries)
            more = batch.hasNextBatch
        }
        try Task.checkCancellation()
        return entries
    }

    static func snapshot(from entry: Playlist.Entry, playlistID: String) -> TrackSnapshot? {
        snapshot(from: entry, item: entry.item, playlistID: playlistID)
    }

    /// The item boundary is injectable because MusicKit owns Entry construction.
    static func snapshot(from entry: Playlist.Entry, item: Playlist.Entry.Item?, playlistID: String) -> TrackSnapshot? {
        guard case .song(let song) = item else { return nil }
        var snapshot = snapshot(from: Track.song(song), playlistID: playlistID)
        snapshot.playlistEntryID = entry.id.rawValue.isEmpty ? nil : entry.id.rawValue
        snapshot.remotePosition = entry.position
        snapshot.entryPlayCount = entry.playCount
        snapshot.entryLastPlayedDate = entry.lastPlayedDate
        snapshot.isrc = entry.isrc ?? snapshot.isrc
        snapshot.artworkURLTemplate = entry.artwork?.url(width: 512, height: 512)?.absoluteString
            ?? snapshot.artworkURLTemplate
        snapshot.durationSeconds = entry.duration ?? snapshot.durationSeconds
        return snapshot
    }

    /// Copies keep videos remotely, but local intake remains song-only.
    static func songSnapshots(from tracks: [Track], playlistID: String) -> [TrackSnapshot] {
        tracks.compactMap { track in
            guard case .song = track else { return nil }
            return snapshot(from: track, playlistID: playlistID)
        }
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
