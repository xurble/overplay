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
        /// Still in Apple Music; Apple Music refuses Overplay's edits to it.
        var refusedItemIDs: Set<UUID> = []
        /// Still in Apple Music; this device cannot edit playlists (a Mac).
        var notEditableHereItemIDs: Set<UUID> = []
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
            try await AppleMusicPlaylistWrites.edit(playlist, items: items)
        }
    }

    /// A Mac has no MusicKit playlist editing (the iPad app there crashes on
    /// any edit), so removals there always wait for an iPhone or iPad.
    var canEditPlaylists: @MainActor () -> Bool = { !ProcessInfo.processInfo.isMacCatalystApp }

    init() {}

    /// Apple Music's refusal to edit a playlist this app did not create.
    nonisolated static func isEditRefusal(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == "ICPlaylistUpdateErrorDomain" && error.code == -1
    }

    static func managesRemoteMembership(of playlist: PlaylistRecord) -> Bool {
        playlist.isActive && playlist.source == .appleMusic && playlist.role == .oneTruePlaylist && playlist.allowsRemoteWrites
    }

    /// Removes every song that carries this playlist's stale-OTP suppression,
    /// except one on its way in (see `songsHeldOutside`). Removed or already
    /// absent songs release the suppression; a retired one then gets the
    /// retention rule, so an unwanted 0/0 row is deleted at once.
    @discardableResult
    func removeSongsHeldOutside(_ playlist: PlaylistRecord, in context: ModelContext) async throws -> Outcome {
        guard Self.managesRemoteMembership(of: playlist),
              try !songsHeldOutside(playlist, in: context).isEmpty else { return Outcome() }
        let musicPlaylistID = playlist.musicPlaylistID
        // The whole pass holds the gate, so an add and its local move are
        // either finished or have not begun.
        return try await PlaylistRemoteMutationCoordinator.shared.perform(playlistID: musicPlaylistID) {
            var outcome = Outcome()
            do {
                try await removeFromAppleMusic(playlist, into: &outcome, in: context)
            } catch {
                // iCloud's read already proved these gone. This pass is the
                // only release for a managed playlist, so a failed load or
                // rewrite of the songs still there must not hold them too.
                try release(outcome.absentItemIDs, from: playlist, in: context)
                throw error
            }
            try release(outcome.removedItemIDs.union(outcome.absentItemIDs), from: playlist, in: context)
            return outcome
        }
    }

    /// Releases the suppression of rows still held; a retired one then gets
    /// the retention rule.
    private func release(_ itemIDs: Set<UUID>, from playlist: PlaylistRecord, in context: ModelContext) throws {
        let musicPlaylistID = playlist.musicPlaylistID
        let stillHeld = try songsHeldOutside(playlist, in: context)
        for itemID in itemIDs where stillHeld[itemID] != nil {
            guard let item = try PlaylistItemRepository.item(id: itemID, in: context) else { continue }
            item.suppressedOTPMusicPlaylistIDs.removeAll { $0 == musicPlaylistID }
            item.updatedAt = .now
            // Retired rows only: an active Triage row keeps its usual triggers.
            if item.evictedAt != nil { try TrackRetentionPolicy.deleteIfUnowned(item, in: context) }
        }
        try context.save()
    }

    /// The rows that must leave this playlist, with their songs' references,
    /// read live. A suppression also marks a promotion in flight, so a song
    /// being added is never one of them; the add settles it either way.
    private func songsHeldOutside(_ playlist: PlaylistRecord, in context: ModelContext) throws -> [UUID: Set<MusicResourceReference>] {
        let musicPlaylistID = playlist.musicPlaylistID
        let beingAdded = try TrackRecordRepository.tracks(
            ids: PlaylistRemoteMutationCoordinator.shared.tracksBeingAdded(to: musicPlaylistID), in: context
        ).reduce(into: Set<MusicResourceReference>()) { $0.formUnion($1.identityReferences) }
        var referencesByItemID: [UUID: Set<MusicResourceReference>] = [:]
        for item in try PlaylistItemRepository.allItems(in: context)
        where item.playlistID != playlist.id && item.suppressedOTPMusicPlaylistIDs.contains(musicPlaylistID) {
            guard let track = try TrackRecordRepository.track(id: item.trackID, in: context),
                  track.identityReferences.isDisjoint(with: beingAdded) else { continue }
            referencesByItemID[item.id] = track.identityReferences
        }
        return referencesByItemID
    }

    /// One read/modify/write. The caller holds the gate. `outcome` keeps what
    /// was proven before any later step throws.
    private func removeFromAppleMusic(_ playlist: PlaylistRecord, into outcome: inout Outcome, in context: ModelContext) async throws {
        let musicPlaylistID = playlist.musicPlaylistID
        let referencesByItemID = try songsHeldOutside(playlist, in: context)
        guard !referencesByItemID.isEmpty else { return }

        let cloud = try await cloudEntries(musicPlaylistID)
        let cloudReferences = Set(cloud.compactMap(\.reference))
        var presentItemIDs = Set<UUID>()
        for (itemID, references) in referencesByItemID {
            if references.isDisjoint(with: cloudReferences) {
                outcome.absentItemIDs.insert(itemID)
            } else {
                presentItemIDs.insert(itemID)
            }
        }
        guard !presentItemIDs.isEmpty else { return }
        guard playlist.remoteEditsRefusedAt == nil else {
            outcome.refusedItemIDs = presentItemIDs
            return
        }
        guard canEditPlaylists() else {
            outcome.notEditableHereItemIDs = presentItemIDs
            return
        }

        let (remotePlaylist, tracks) = try await loadDeviceCopy(musicPlaylistID)
        guard let deviceReferences = try await references(for: tracks, matching: cloud) else {
            outcome.deferredItemIDs = presentItemIDs
            TrackMetadataDiagnostics.log("remote removal deferred playlist=\(musicPlaylistID): device copy differs from iCloud")
            return
        }

        // A promotion may have started during those awaits, and the rewrite
        // cannot be undone. Re-read with no await before the write.
        let stillHeld = try songsHeldOutside(playlist, in: context)
        presentItemIDs.formIntersection(stillHeld.keys)
        guard !presentItemIDs.isEmpty else { return }
        let removedReferences = presentItemIDs.reduce(into: Set<MusicResourceReference>()) {
            $0.formUnion(stillHeld[$1, default: []].intersection(cloudReferences))
        }
        let remaining = zip(tracks, deviceReferences).filter { !removedReferences.contains($0.1) }.map(\.0)
        do {
            try await write(remotePlaylist, remaining)
        } catch where Self.isEditRefusal(error) {
            playlist.remoteEditsRefusedAt = .now
            outcome.refusedItemIDs = presentItemIDs
            TrackMetadataDiagnostics.log("remote edits refused playlist=\(musicPlaylistID): not created by this app")
            return
        }
        outcome.removedItemIDs = presentItemIDs
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
