import Foundation
@preconcurrency import MusicKit
import SwiftData

/// Keeps the managed One True Playlist in Apple Music free of songs Overplay
/// holds outside it: retired, or merged into Triage (`PLAYLIST-008`).
///
/// MusicKit can only remove a song by rewriting the whole playlist from this
/// device's copy. A device whose library lags iCloud would resurrect songs
/// deleted elsewhere or drop songs added elsewhere, so a rewrite only runs
/// when this device's copy matches iCloud's apart from the songs removed.
@MainActor
struct OneTruePlaylistRemoteMembership {
    struct Outcome: Equatable {
        /// Removed from the Apple Music playlist by this call.
        var removedItemIDs: Set<UUID> = []
        /// Not in iCloud's copy, so nothing to remove.
        var absentItemIDs: Set<UUID> = []
        /// Still in Apple Music; this device's copy did not match iCloud's.
        var deferredItemIDs: Set<UUID> = []
    }

    var cloudEntries: @MainActor (String) async throws -> [AppleMusicLibraryPlaylistResources.Entry] = {
        try await AppleMusicLibraryPlaylistResources.fetchEntries(playlistID: $0)
    }
    var loadDeviceCopy: @MainActor (String) async throws -> (Playlist, [Track]) = { playlistID in
        let playlist = try await PlaylistSyncService().loadPlaylist(id: playlistID)
        return (playlist, try await AppleMusicPlaylistTrackLoader.loadTracks(for: playlist))
    }
    var resolve: @MainActor (Song) async throws -> MusicLibrarySongResolver.Resolution = MusicLibrarySongResolver.resolve
    var write: @MainActor (Playlist, [Track]) async throws -> Void = { playlist, items in
        _ = try await MusicKitActivityLog.shared.measure(
            .libraryPlaylistEdit,
            magnitude: Double(items.count),
            detail: "rewrote playlist to remove songs held outside it"
        ) {
            try await MusicLibrary.shared.edit(playlist, items: items)
        }
    }

    init() {}

    static func managesRemoteMembership(of playlist: PlaylistRecord) -> Bool {
        playlist.isActive && playlist.source == .appleMusic && playlist.role == .oneTruePlaylist && playlist.allowsRemoteWrites
    }

    /// Removes every song that carries this playlist's stale-OTP suppression.
    /// Removed or already absent songs release the suppression; a retired one
    /// then gets the retention rule, so an unwanted 0/0 row is deleted at once.
    @discardableResult
    func removeSongsHeldOutside(_ playlist: PlaylistRecord, in context: ModelContext) async throws -> Outcome {
        guard Self.managesRemoteMembership(of: playlist) else { return Outcome() }
        let musicPlaylistID = playlist.musicPlaylistID
        let playlistID = playlist.id
        var referencesByItemID: [UUID: Set<MusicResourceReference>] = [:]
        for item in try PlaylistItemRepository.allItems(in: context)
        where item.playlistID != playlistID && item.suppressedOTPMusicPlaylistIDs.contains(musicPlaylistID) {
            guard let track = try TrackRecordRepository.track(id: item.trackID, in: context) else { continue }
            referencesByItemID[item.id] = track.identityReferences
        }
        guard !referencesByItemID.isEmpty else { return Outcome() }

        var outcome = Outcome()
        try await PlaylistRemoteMutationCoordinator.shared.perform(playlistID: musicPlaylistID) {
            let cloud = try await cloudEntries(musicPlaylistID)
            let cloudReferences = Set(cloud.compactMap(\.reference))
            var presentReferences = Set<MusicResourceReference>()
            var presentItemIDs = Set<UUID>()
            for (itemID, references) in referencesByItemID {
                let present = references.intersection(cloudReferences)
                if present.isEmpty {
                    outcome.absentItemIDs.insert(itemID)
                } else {
                    presentReferences.formUnion(present)
                    presentItemIDs.insert(itemID)
                }
            }
            guard !presentItemIDs.isEmpty else { return }

            let (remotePlaylist, tracks) = try await loadDeviceCopy(musicPlaylistID)
            guard let deviceReferences = try await references(for: tracks, matching: cloud) else {
                outcome.deferredItemIDs = presentItemIDs
                TrackMetadataDiagnostics.log("remote removal deferred playlist=\(musicPlaylistID): device copy differs from iCloud")
                return
            }
            let remaining = zip(tracks, deviceReferences).filter { !presentReferences.contains($0.1) }.map(\.0)
            try await write(remotePlaylist, remaining)
            outcome.removedItemIDs = presentItemIDs
        }

        for itemID in outcome.removedItemIDs.union(outcome.absentItemIDs) {
            guard let item = try PlaylistItemRepository.item(id: itemID, in: context),
                  item.playlistID != playlistID,
                  item.suppressedOTPMusicPlaylistIDs.contains(musicPlaylistID) else { continue }
            item.suppressedOTPMusicPlaylistIDs.removeAll { $0 == musicPlaylistID }
            item.updatedAt = .now
            // Retired rows only: an active Triage row keeps its usual triggers.
            if item.evictedAt != nil { try TrackRetentionPolicy.deleteIfUnowned(item, in: context) }
        }
        try context.save()
        return outcome
    }

    /// Whether iCloud's copy already holds this song, so adding it again
    /// would duplicate it.
    func contains(_ track: TrackRecord, in playlist: PlaylistRecord) async throws -> Bool {
        let cloud = try await cloudEntries(playlist.musicPlaylistID)
        return !track.identityReferences.isDisjoint(with: cloud.compactMap(\.reference))
    }

    /// This device's entries as references, or nil when they are not exactly
    /// iCloud's entries. Raw IDs match directly where the device reports web
    /// library IDs (iPhone); otherwise each song resolves through the shared
    /// intake boundary (native IDs on a Mac). Domain always comes from a
    /// response, never from ID syntax.
    private func references(
        for tracks: [Track],
        matching cloud: [AppleMusicLibraryPlaylistResources.Entry]
    ) async throws -> [MusicResourceReference]? {
        let cloudReferences = cloud.compactMap(\.reference)
        guard cloudReferences.count == cloud.count else { return nil }

        if Self.occurrences(of: tracks.map(\.id.rawValue)) == Self.occurrences(of: cloud.map(\.id)) {
            var referenceByID: [String: MusicResourceReference] = [:]
            for entry in cloud {
                guard let reference = entry.reference else { return nil }
                if let existing = referenceByID[entry.id], existing != reference { return nil }
                referenceByID[entry.id] = reference
            }
            return tracks.compactMap { referenceByID[$0.id.rawValue] }
        }

        var resolved: [MusicItemID: MusicResourceReference] = [:]
        var references: [MusicResourceReference] = []
        for track in tracks {
            guard case .song(let song) = track else { return nil }
            if let known = resolved[song.id] {
                references.append(known)
                continue
            }
            let resolution: MusicLibrarySongResolver.Resolution
            do { resolution = try await resolve(song) } catch is MusicLibrarySongResolver.ResolutionError { return nil }
            try Task.checkCancellation()
            let reference: MusicResourceReference = switch resolution {
            case .library(let song): .library(song.id.rawValue)
            case .catalog(let song): .catalog(song.id.rawValue)
            }
            resolved[song.id] = reference
            references.append(reference)
        }
        return Self.occurrences(of: references) == Self.occurrences(of: cloudReferences) ? references : nil
    }

    private static func occurrences<T: Hashable>(of values: [T]) -> [T: Int] {
        values.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }
}
