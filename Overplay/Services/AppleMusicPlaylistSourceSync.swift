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
    private let songResolver: AppleMusicPlaylistTrackLoader.SongBatchResolver
    private let identityResolver: MusicIdentityResolver
    private let entryItem: (Playlist.Entry) -> Playlist.Entry.Item?

    init(
        playlistFetcher: any MusicLibraryPlaylistFetching = CachingMusicLibraryPlaylistFetcher.shared,
        entryLoader: @escaping (Playlist) async throws -> [Playlist.Entry] = AppleMusicPlaylistTrackLoader.loadEntries,
        songResolver: @escaping AppleMusicPlaylistTrackLoader.SongBatchResolver = AppleMusicPlaylistTrackLoader.liveResolver,
        identityResolver: MusicIdentityResolver = .shared,
        entryItem: @escaping (Playlist.Entry) -> Playlist.Entry.Item? = { $0.item }
    ) {
        self.playlistFetcher = playlistFetcher
        self.entryLoader = entryLoader
        self.songResolver = songResolver
        self.identityResolver = identityResolver
        self.entryItem = entryItem
    }

    /// Up to a fifth of a playlist's distinct songs may be skipped.
    static let maximumUnresolvedShare = 0.2

    static func allowsSkipping(_ unresolved: Int, of distinct: Int) -> Bool {
        unresolved == 0 || Double(unresolved) <= Double(distinct) * maximumUnresolvedShare
    }

    func fetchLibraryPlaylists() async throws -> [RemotePlaylistLink] {
        let links = try await playlistFetcher.fetchLibraryLinks()
        let playlists = links.map { AppleMusicPlaylist(id: $0.id, name: $0.name, trackCount: $0.trackCount) }
        return AppleMusicPlaylistDisplayOrder.sorted(playlists).map(RemotePlaylistLink.init)
    }

    func canonicalLink(for created: Playlist) async throws -> RemotePlaylistLink {
        let links = try await playlistFetcher.fetchLibraryLinks()
        if let exact = links.first(where: { $0.id == created.id.rawValue }) { return exact }
        // A canonical resource resolved through the native endpoint is the
        // evidence tying the new native object to its durable library ID.
        for link in links {
            if let native = try await playlistFetcher.fetchPlaylist(id: link.id), native.id == created.id { return link }
        }
        throw PlaylistSyncError.playlistNotFound
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
        let items = entries.map(entryItem)
        let tracks = try AppleMusicPlaylistTrackLoader.completeTracks(from: items)
        let resolved = try await AppleMusicPlaylistTrackLoader.resolveSongs(
            from: tracks, playlistID: playlistID, resolveAll: songResolver
        )
        // A few unidentifiable songs are skipped (`PLAYLIST-010`); many mean
        // something wider is wrong, so the fetch stops as before.
        guard Self.allowsSkipping(resolved.unresolvedIDs.count, of: resolved.distinctSongCount) else {
            throw MusicLibrarySongResolver.ResolutionError.unresolved(resolved.unresolvedIDs[0])
        }
        // Keep entry occurrence/count evidence separate from song identity.
        let songEntries = zip(entries, items).compactMap { entry, item in
            if case .song = item { entry } else { nil as Playlist.Entry? }
        }
        var snapshots: [TrackSnapshot] = []
        for (entry, snapshot) in zip(songEntries, resolved.snapshots) {
            guard var snapshot else { continue }
            snapshot.playlistEntryID = entry.id.rawValue.isEmpty ? nil : entry.id.rawValue
            snapshot.remotePosition = entry.position
            snapshot.entryPlayCount = entry.playCount
            snapshot.entryLastPlayedDate = entry.lastPlayedDate
            snapshots.append(snapshot)
        }
        // Identity is required for import, not optional metadata enrichment.
        // A failed or incomplete lookup must not create a new shared track.
        snapshots = try await identityResolver.enrich(snapshots, includeCandidates: false)
        return PlaylistSourceFetchResult(
            snapshots: snapshots,
            skippedCount: entries.count - snapshots.count,
            skippedReason: !resolved.unresolvedIDs.isEmpty ? "unresolvedSongs"
                : entries.count == snapshots.count ? nil : "nonSongEntries",
            remoteLastModifiedAt: playlist.lastModifiedDate,
            didFetchTracks: true,
            didFetchEntries: true,
            videoMusicItemIDs: AppleMusicPlaylistTrackLoader.videoMusicItemIDs(from: tracks),
            unresolvedSongIDs: resolved.unresolvedIDs
        )
    }

    func loadPlaylist(
        id playlistID: String,
        name: String? = nil,
        playlistRecord: PlaylistRecord? = nil,
        in context: ModelContext? = nil
    ) async throws -> Playlist {
        guard let playlist = try await playlistFetcher.fetchPlaylist(id: playlistID) else {
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

        AppRuntime.shared.playbackController.rekeyIntentPlaylist(from: oldID, to: newID)
        try context.save()
    }
}

/// One complete entry boundary for sync, copies, and destructive rewrites.
@MainActor
enum AppleMusicPlaylistTrackLoader {
    typealias SongBatchResolver = @MainActor ([Song]) async throws -> MusicLibrarySongResolver.BatchResolution

    /// Songs observed in one playlist fetch, in order.
    struct ResolvedSongs {
        /// One per song track, in order; nil where nothing could identify it.
        var snapshots: [TrackSnapshot?]
        var unresolvedIDs: [String]
        var distinctSongCount: Int

        /// Copies and rewrites need every song: a partial result could look
        /// like remote absence.
        func requireAll() throws -> [TrackSnapshot] {
            if let first = unresolvedIDs.first { throw MusicLibrarySongResolver.ResolutionError.unresolved(first) }
            return snapshots.compactMap { $0 }
        }
    }

    /// The batched resolver, with its web-library requests in the activity log.
    static let liveResolver: SongBatchResolver = { songs in
        try await MusicLibrarySongResolver.resolveAll(songs, webLibrary: { ids in
            try await MusicKitActivityLog.shared.measure(
                .catalogResourceFetch, magnitude: Double(ids.count), detail: "resolver web library batch"
            ) {
                try await MusicLibrarySongResolver.webLibrarySongIDs(ids)
            }
        })
    }

    /// One intake boundary used by ordinary sync and playlist-copy creation.
    /// Resolve each distinct observed ID once per fetch; retain occurrences.
    /// Mappings remain scoped to this operation, never persisted as global aliases.
    static func resolveSongs(
        from tracks: [Track], playlistID: String,
        resolveAll: SongBatchResolver = liveResolver
    ) async throws -> ResolvedSongs {
        let observed = tracks.compactMap { track -> Song? in
            if case .song(let song) = track { song } else { nil }
        }
        try Task.checkCancellation()
        let batch = try await resolveAll(observed)
        try Task.checkCancellation()
        var snapshots: [TrackSnapshot?] = []
        for song in observed {
            guard let resolution = batch.resolutions[song.id] else {
                snapshots.append(nil)
                continue
            }
            // The request establishes the domain. Do not decode play parameters
            // or classify the raw identifier to choose persistent identity.
            let resolved = resolution.song
            snapshots.append(TrackSnapshot(
                id: resolved.id.rawValue,
                catalogID: resolution.identity.catalogID,
                libraryID: resolution.identity.libraryID,
                playlistEntryID: nil, playlistID: playlistID,
                title: resolved.title, artistName: resolved.artistName, albumTitle: resolved.albumTitle,
                artworkURLTemplate: resolved.artwork?.url(width: 512, height: 512)?.absoluteString,
                durationSeconds: resolved.duration,
                musicKitPlaybackData: try JSONEncoder().encode(Track.song(resolved)),
                isrc: resolved.isrc
            ))
        }
        return ResolvedSongs(
            snapshots: snapshots,
            unresolvedIDs: batch.unresolved.map(\.rawValue),
            distinctSongCount: Set(observed.map(\.id)).count
        )
    }

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

    static func videoMusicItemIDs(from tracks: [Track]) -> Set<String> {
        Set(tracks.filter { !VideoTrackPolicy.isSong($0) }.flatMap { track in
            let identity = MusicTrackIdentity.ids(for: track)
            return [track.id.rawValue, identity.catalogID, identity.libraryID].compactMap { $0 }
        })
    }

    /// Local intake is always song-only.
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
