import Foundation
@preconcurrency import MusicKit
import SwiftData

/// Replaces the Apple Music playlist behind the One True Playlist with a new,
/// Overplay-created one (`PLAYLIST-009`). MusicKit lets an app edit only the
/// playlists it created, and Apple Music can stop recognising Overplay as the
/// creator of an older playlist; a rebuilt playlist can be edited again.
///
/// The One True Playlist itself does not change: its songs, order, counts,
/// retirements and history stay with Overplay's records, and only its Apple
/// Music identifier moves to the new playlist. Nothing is deleted from Apple
/// Music; the user removes the old playlist in the Music app.
@MainActor
struct OneTruePlaylistRebuildService {
    struct Result: Equatable {
        var name: String
        var addedCount: Int
        /// Active songs with no playable Apple Music item on this device.
        var skippedCount: Int
    }

    enum RebuildError: LocalizedError {
        case noOneTruePlaylist
        case notOnThisDevice
        case nothingToAdd
        case creationFailed(String)
        case linkFailed(name: String, songCount: Int)

        var errorDescription: String? {
            switch self {
            case .noOneTruePlaylist: "Choose a One True Playlist before rebuilding it."
            case .notOnThisDevice: "Rebuild the Apple Music playlist from your iPhone or iPad."
            case .nothingToAdd: "None of the playlist's active songs could be prepared for Apple Music, so nothing was changed."
            case .linkFailed(let name, let songCount): "Created a new “\(name)” in Apple Music with \(songCount) songs, but couldn't confirm it, so Overplay still uses your current playlist. Delete the new one (\(songCount) songs) in the Music app and try again."
            case .creationFailed(let reason): "Apple Music couldn't create the playlist (\(reason)). Overplay still uses your current playlist. If an empty playlist appeared in the Music app, delete it."
            }
        }
    }

    /// A Mac (Catalyst, or the iPad app there) has no MusicKit playlist creation.
    var canCreatePlaylists: @MainActor () -> Bool = { !ProcessInfo.processInfo.isMacCatalystApp }
    /// Live MusicKit items for the given songs. Apple Music adds only live
    /// items to a playlist: tracks decoded from saved playback data are
    /// refused (`MPPlaylistUpdateErrorDomain` -1, observed 2026-10-06). The
    /// current playlist's own entries come first; any other song is fetched
    /// from the catalog, as promotion adds it.
    var addableTracks: @MainActor ([TrackRecord], String) async -> [UUID: Track] = { records, playlistID in
        var tracks: [UUID: Track] = [:]
        do {
            let playlist = try await PlaylistSyncService().loadPlaylist(id: playlistID)
            let entries = try await AppleMusicPlaylistTrackLoader.loadTracks(for: playlist).filter(VideoTrackPolicy.isSong)
            let entriesByID = Dictionary(entries.map { ($0.id.rawValue, $0) }, uniquingKeysWith: { first, _ in first })
            // On iPhone and iPad, entries report web library IDs.
            for record in records {
                if let match = record.identityReferences.lazy
                    .filter({ $0.domain == .librarySong }).compactMap({ entriesByID[$0.value] }).first {
                    tracks[record.id] = match
                }
            }
        } catch {
            TrackMetadataDiagnostics.log("rebuild could not load the current playlist: \(error.localizedDescription)")
        }
        let missing = records.filter { tracks[$0.id] == nil && $0.catalogID != nil }
        if !missing.isEmpty {
            do {
                let request = MusicCatalogResourceRequest<Song>(
                    matching: \.id, memberOf: missing.compactMap { $0.catalogID.map { MusicItemID($0) } }
                )
                let songs = try await MusicKitActivityLog.shared.measure(.catalogResourceFetch, detail: "rebuild songs") {
                    try await request.response().items
                }
                let songsByID = Dictionary(songs.map { ($0.id.rawValue, $0) }, uniquingKeysWith: { first, _ in first })
                for record in missing {
                    if let catalogID = record.catalogID, let song = songsByID[catalogID] { tracks[record.id] = .song(song) }
                }
            } catch {
                TrackMetadataDiagnostics.log("rebuild catalog lookup failed: \(error.localizedDescription)")
            }
        }
        return tracks
    }
    var createPlaylist: @MainActor (String, [Track]) async throws -> Playlist = { name, items in
        let created = try await MusicKitActivityLog.shared.measure(.libraryPlaylistCreate, magnitude: Double(items.count)) {
            try await AppleMusicPlaylistWrites.createPlaylist(name: name, description: "Managed by Overplay", items: items)
        }
        CachingMusicLibraryPlaylistFetcher.shared.invalidate()
        return created
    }
    /// The created playlist's durable identifier. On iPhone and iPad its
    /// MusicKit ID is the web library ID, which a native lookup confirms at
    /// once. Apple's library list can lag a new playlist (2026-10-06: the
    /// first rebuild created its playlist but could not find it there).
    var durableID: @MainActor (Playlist) async throws -> String = { created in
        if let native = try await CachingMusicLibraryPlaylistFetcher.shared.fetchPlaylist(id: created.id.rawValue),
           native.id == created.id {
            return created.id.rawValue
        }
        return try await AppleMusicPlaylistSourceSync().canonicalLink(for: created).id
    }
    var sync: @MainActor (PlaylistRecord, ModelContext) async throws -> Void = { playlist, context in
        _ = try await PlaylistSyncService().syncPlaylist(playlist, in: context)
    }

    init() {}

    func rebuild(in context: ModelContext) async throws -> Result {
        guard canCreatePlaylists() else { throw RebuildError.notOnThisDevice }
        guard let playlist = try PlaylistRepository.oneTruePlaylist(in: context) else { throw RebuildError.noOneTruePlaylist }
        let previousID = playlist.musicPlaylistID

        let result = try await PlaylistRemoteMutationCoordinator.shared.perform(playlistID: previousID) {
            let inputs = try PlaybackQueueOrchestrator.playlistInputs(for: previousID, in: context)
            let active = PlaylistDisplayOrder.orderedItems(inputs.items.filter { PlaylistPlaybackScope.active.includes($0) }, scope: .active)
            let records = active.compactMap { inputs.tracksByID[$0.trackID] }
            let tracksByID = await addableTracks(records, previousID)
            let items = records.compactMap { tracksByID[$0.id] }
            guard !items.isEmpty else { throw RebuildError.nothingToAdd }

            let created: Playlist
            do {
                created = try await createPlaylist(playlist.name, items)
            } catch {
                // MusicKit creates the playlist before adding its songs, so a
                // failure can leave an empty one behind; it cannot delete it.
                throw RebuildError.creationFailed(error.localizedDescription)
            }
            let newID: String
            do {
                newID = try await durableID(created)
            } catch {
                TrackMetadataDiagnostics.log("rebuilt playlist could not be confirmed: \(error.localizedDescription)")
                throw RebuildError.linkFailed(name: playlist.name, songCount: items.count)
            }
            // The same logical playlist under a new identifier, exactly as when
            // MusicKit reissues one: provenance, suppression, selection and the
            // playback intent all follow it.
            try AppleMusicPlaylistSourceSync().applyHealedMusicPlaylistID(
                from: previousID, to: newID, playlistRecord: playlist, in: context
            )
            playlist.writePolicy = .managed
            playlist.remoteEditsRefusedAt = nil
            playlist.remoteLastModifiedAt = nil
            playlist.lastSyncError = nil
            try context.save()
            TrackMetadataDiagnostics.log("rebuilt one true playlist from=\(previousID) to=\(newID) added=\(items.count) skipped=\(records.count - items.count)")
            return Result(name: playlist.name, addedCount: items.count, skippedCount: records.count - items.count)
        }
        // A sync failure leaves the rebuilt playlist linked; the next sync repeats it.
        do { try await sync(playlist, context) } catch {
            TrackMetadataDiagnostics.log("sync after rebuild failed: \(error.localizedDescription)")
        }
        return result
    }
}
