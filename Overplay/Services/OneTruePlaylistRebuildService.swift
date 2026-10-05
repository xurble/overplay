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

        var errorDescription: String? {
            switch self {
            case .noOneTruePlaylist: "Choose a One True Playlist before rebuilding it."
            case .notOnThisDevice: "Rebuild the Apple Music playlist from your iPhone or iPad."
            case .nothingToAdd: "None of the playlist's active songs could be prepared for Apple Music, so nothing was changed."
            }
        }
    }

    /// An iPad app on a Mac has no MusicKit playlist creation.
    var canCreatePlaylists: @MainActor () -> Bool = { !ProcessInfo.processInfo.isiOSAppOnMac }
    /// The same per-device tracks playback queues.
    var playableTracks: @MainActor ([TrackRecord]) async -> [UUID: Track] = { records in
        do { try await DevicePlaybackCache.prepare(records) } catch {
            TrackMetadataDiagnostics.log("rebuild preparation incomplete: \(error.localizedDescription)")
        }
        var tracks: [UUID: Track] = [:]
        for record in records {
            guard let data = DevicePlaybackCache.shared.data(for: record.id),
                  let track = try? JSONDecoder().decode(Track.self, from: data),
                  VideoTrackPolicy.isSong(track) else { continue }
            tracks[record.id] = track
        }
        return tracks
    }
    /// Creates the playlist and returns its durable web library identifier.
    var createPlaylist: @MainActor (String, [Track]) async throws -> String = { name, items in
        let created = try await MusicKitActivityLog.shared.measure(.libraryPlaylistCreate, magnitude: Double(items.count)) {
            try await MusicLibrary.shared.createPlaylist(name: name, description: "Managed by Overplay", items: items)
        }
        CachingMusicLibraryPlaylistFetcher.shared.invalidate()
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
            let tracksByID = await playableTracks(records)
            let items = records.compactMap { tracksByID[$0.id] }
            guard !items.isEmpty else { throw RebuildError.nothingToAdd }

            let newID = try await createPlaylist(playlist.name, items)
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
