import Foundation
@preconcurrency import MusicKit
import SwiftData

enum PlaylistMutationError: LocalizedError {
    case oneTruePlaylistMissing
    case sourcePlaylistMissing
    case sourcePlaylistNotTriage
    case trackMissing
    case musicItemMissing
    case playlistIncomingOnly
    case songUnknownToAppleMusic

    var errorDescription: String? {
        switch self {
        case .oneTruePlaylistMissing:
            "Overplay hasn’t made your One True Playlist yet."
        case .sourcePlaylistMissing:
            "The source playlist is no longer linked."
        case .sourcePlaylistNotTriage:
            "Only tracks in the Inbox can be Overplayed."
        case .trackMissing:
            "The track is no longer available locally."
        case .musicItemMissing:
            "This track does not have an Apple Music identifier Overplay can add."
        case .playlistIncomingOnly:
            "This playlist is incoming only, so Overplay will not write changes back to Apple Music."
        case .songUnknownToAppleMusic:
            "Apple Music doesn't recognise this song, so Overplay can't save it."
        }
    }
}

@MainActor
struct PlaylistMutationService {
    // Inject only the remote boundary; durable movement remains shared.
    var addRemotely: (@MainActor (TrackRecord, PlaylistRecord, ModelContext) async throws -> Void)?
    var remoteMembership = OneTruePlaylistRemoteMembership()
    /// The library song for an ID, and the write. Injected so tests need no MusicKit.
    var librarySong: @MainActor (String) async throws -> Song = PlaylistMutationService.liveLibrarySong
    var writeSong: (@MainActor (Song, PlaylistRecord, ModelContext) async throws -> Void)?
    /// MusicKit has no playlist writes on a Mac.
    var canWritePlaylists: @MainActor () -> Bool = { !ProcessInfo.processInfo.isMacCatalystApp }

    /// Whether a song joining `playlist` is recorded here only, for an iPhone
    /// or iPad to add in Apple Music after its next sync: on a Mac, or while
    /// the One True Playlist has no Apple Music playlist yet (`PLAYLIST-008`).
    func addsLocally(to playlist: PlaylistRecord) -> Bool {
        !canWritePlaylists() || playlist.awaitsAppleMusicPlaylist
    }

    @discardableResult
    func promote(
        item sourceItem: PlaylistItemRecord,
        beforeMove: () -> Void = {},
        in context: ModelContext
    ) async throws -> PlaylistItemRecord {
        guard let playlist = try PlaylistRepository.oneTruePlaylist(in: context) else {
            throw PlaylistMutationError.oneTruePlaylistMissing
        }
        let itemID = sourceItem.id
        let locationChangedAt = sourceItem.locationChangedAt
        let playlistID = playlist.id
        return try await PlaylistRemoteMutationCoordinator.shared.perform(
            playlistID: playlist.musicPlaylistID, addingTrack: sourceItem.trackID
        ) {
            guard let liveItem = try PlaylistItemRepository.item(id: itemID, in: context),
                  liveItem.locationChangedAt == locationChangedAt,
                  try PlaylistRepository.oneTruePlaylist(in: context)?.id == playlistID else {
                throw PlaylistMutationError.trackMissing
            }
            return try await promoteSerially(item: sourceItem, beforeMove: beforeMove, in: context)
        }
    }

    private func promoteSerially(
        item sourceItem: PlaylistItemRecord,
        beforeMove: () -> Void,
        in context: ModelContext
    ) async throws -> PlaylistItemRecord {
        guard let oneTruePlaylist = try PlaylistRepository.oneTruePlaylist(in: context) else {
            throw PlaylistMutationError.oneTruePlaylistMissing
        }
        guard let sourcePlaylist = try PlaylistRepository.playlist(id: sourceItem.playlistID, in: context) else {
            throw PlaylistMutationError.sourcePlaylistMissing
        }
        guard sourcePlaylist.role == .triageBucket else {
            throw PlaylistMutationError.sourcePlaylistNotTriage
        }
        guard let track = try TrackRecordRepository.track(id: sourceItem.trackID, in: context) else {
            throw PlaylistMutationError.trackMissing
        }
        guard oneTruePlaylist.allowsRemoteWrites else {
            throw PlaylistMutationError.playlistIncomingOnly
        }

        let addsLocally = addsLocally(to: oneTruePlaylist)
        let sourceItemID = sourceItem.id
        let previousRetiredAt = sourceItem.evictedAt
        let previousLocationChange = sourceItem.locationChangedAt
        let sourceTrackID = sourceItem.trackID
        let previousSkipCount = sourceItem.skipCount
        // Protect this identity while the remote request is in flight. If a
        // later retirement wins, remote completion must not recreate it.
        if !sourceItem.suppressedOTPMusicPlaylistIDs.contains(oneTruePlaylist.musicPlaylistID) {
            sourceItem.suppressedOTPMusicPlaylistIDs.append(oneTruePlaylist.musicPlaylistID)
        }
        try context.save()
        do {
            if !addsLocally { try await addUnlessPresent(track, to: oneTruePlaylist, in: context) }
            guard let liveItem = try PlaylistItemRepository.item(id: sourceItemID, in: context),
                  liveItem.playlistID == sourcePlaylist.id,
                  liveItem.evictedAt == previousRetiredAt,
                  liveItem.locationChangedAt == previousLocationChange else {
                throw PlaylistMutationError.trackMissing
            }
            beforeMove()
            let promotedItem = try recordSuccessfulPromotion(
                sourceItem: sourceItem,
                sourcePlaylist: sourcePlaylist,
                oneTruePlaylist: oneTruePlaylist,
                track: track,
                appleMusicAddPending: addsLocally,
                in: context
            )
            try context.save()
            return promotedItem
        } catch {
            EventRepository.logHistory(
                playlistID: sourcePlaylist.id,
                trackID: sourceTrackID,
                eventType: .remoteMutation,
                source: .user,
                skipCountAtEvent: previousSkipCount,
                remoteMutationStatus: .failed,
                message: "Overplay failed: \(UserFacingError.message(for: error))",
                in: context
            )
            try? context.save()
            throw error
        }
    }

    @discardableResult
    func recordSuccessfulPromotion(
        sourceItem: PlaylistItemRecord,
        sourcePlaylist: PlaylistRecord,
        oneTruePlaylist: PlaylistRecord,
        track: TrackRecord,
        promotedAt: Date = .now,
        appleMusicAddPending: Bool = false,
        in context: ModelContext
    ) throws -> PlaylistItemRecord {
        guard sourcePlaylist.role == .triageBucket else {
            throw PlaylistMutationError.sourcePlaylistNotTriage
        }

        guard !sourceItem.isDeleted,
              try PlaylistItemRepository.item(id: sourceItem.id, in: context) != nil else {
            throw PlaylistMutationError.trackMissing
        }
        let promotedItem = sourceItem
        try PlaylistItemRepository.mergeOtherItems(into: promotedItem, in: context)
        TrackLocationService.moveToOTP(
            promotedItem, playlist: oneTruePlaylist, source: .user,
            appleMusicAddPending: appleMusicAddPending, at: promotedAt, in: context
        )
        promotedItem.lastSeenInPlaylistAt = promotedAt
        promotedItem.updatedAt = promotedAt

        return promotedItem
    }

    @discardableResult
    func recordSuccessfulManualAdd(
        _ result: SearchSongResult,
        identity: MusicTrackIdentity.IDs? = nil,
        to playlist: PlaylistRecord,
        addedAt: Date = .now,
        appleMusicAddPending: Bool = false,
        in context: ModelContext
    ) throws -> PlaylistItemRecord {
        // SearchService requests catalog songs, so its endpoint establishes
        // the domain. Other callers pass the domain Apple Music confirmed.
        // No raw-ID syntax inference enters persistence.
        let identity = identity ?? MusicTrackIdentity.IDs(catalogID: result.id)
        let track = try TrackRecordRepository.upsert(
            catalogID: identity.catalogID,
            libraryID: identity.libraryID,
            title: result.title,
            artistName: result.artistName,
            albumTitle: result.albumTitle,
            artworkURLTemplate: result.artworkURL,
            updatedAt: addedAt,
            in: context
        )
        let item = try PlaylistItemRepository.upsert(
            playlistID: playlist.id,
            trackID: track.id,
            in: context
        )
        item.isExplicitlyKept = true
        try PlaylistItemRepository.mergeOtherItems(into: item, in: context)
        if playlist.role == .oneTruePlaylist {
            TrackLocationService.moveToOTP(
                item, playlist: playlist, source: .user, logEvent: false,
                appleMusicAddPending: appleMusicAddPending, at: addedAt, in: context
            )
        } else if item.playlistID == playlist.id {
            try TrackLocationService.moveToTriage(item, explicitKeep: true, logEvent: false, at: addedAt, in: context)
        }
        item.lastSeenInPlaylistAt = addedAt
        item.updatedAt = addedAt

        EventRepository.logHistory(
            playlistID: playlist.id,
            trackID: track.id,
            eventType: .trackAdded,
            source: .user,
            remoteMutationStatus: appleMusicAddPending ? .pending : .succeeded,
            message: "Added to \(playlist.name)",
            in: context
        )

        try context.save()
        return item
    }

    func recordFailedManualAdd(
        _ result: SearchSongResult,
        to playlist: PlaylistRecord?,
        message: String,
        in context: ModelContext
    ) {
        EventRepository.logHistory(
            playlistID: playlist?.id,
            eventType: .remoteMutation,
            source: .user,
            remoteMutationStatus: .failed,
            message: "Add failed for \(result.title): \(message)",
            in: context
        )
        try? context.save()
    }

    func ensureRemoteMembership<Committed>(
        track: TrackRecord, playlist: PlaylistRecord,
        isCurrent: () throws -> Bool, beforeAdd: () throws -> Void,
        commit: () throws -> Committed,
        in context: ModelContext
    ) async throws -> Committed {
        guard playlist.allowsRemoteWrites else { throw PlaylistMutationError.playlistIncomingOnly }
        let addsLocally = addsLocally(to: playlist)
        return try await PlaylistRemoteMutationCoordinator.shared.perform(
            playlistID: playlist.musicPlaylistID, addingTrack: track.id
        ) {
            guard try isCurrent(), playlist.allowsRemoteWrites else { throw PlaylistMutationError.trackMissing }
            if addsLocally {
                let committed = try commit()
                if let item = try PlaylistItemRepository.item(trackID: track.id, in: context),
                   item.playlistID == playlist.id, item.evictedAt == nil {
                    item.appleMusicAddPendingAt = .now
                    try context.save()
                }
                return committed
            }
            try beforeAdd()
            try await addUnlessPresent(track, to: playlist, in: context)
            guard try isCurrent() else { throw PlaylistMutationError.trackMissing }
            // Inside the gate: a queued removal must find the song already moved.
            return try commit()
        }
    }

    /// `PLAYLIST-008`: adds to the One True Playlist's Apple Music playlist
    /// the songs a Mac moved into it, unless iCloud's copy already holds
    /// them, and clears their marks. A failed add keeps its mark for the next
    /// sync. Runs only where playlists can be written. Returns how many it added.
    @discardableResult
    func addSongsAwaitingAppleMusic(to playlist: PlaylistRecord, in context: ModelContext) async throws -> Int {
        guard canWritePlaylists(), OneTruePlaylistRemoteMembership.managesRemoteMembership(of: playlist),
              playlist.remoteEditsRefusedAt == nil,
              try !Self.itemsAwaitingAppleMusic(in: playlist, context).isEmpty else { return 0 }
        return try await PlaylistRemoteMutationCoordinator.shared.perform(playlistID: playlist.musicPlaylistID) {
            var cloud = try await remoteMembership.cloudReferences(of: playlist)
            var addedCount = 0
            for item in try Self.itemsAwaitingAppleMusic(in: playlist, context) {
                guard let track = try TrackRecordRepository.track(id: item.trackID, in: context) else { continue }
                if track.identityReferences.isDisjoint(with: cloud) {
                    do {
                        if let addRemotely { try await addRemotely(track, playlist, context) }
                        else { try await add(track: track, to: playlist, in: context) }
                    } catch {
                        TrackMetadataDiagnostics.log("pending add failed playlist=\(playlist.musicPlaylistID) track=\(track.id): \(error.localizedDescription)")
                        continue
                    }
                    cloud.formUnion(track.identityReferences)
                    addedCount += 1
                }
                // A move during the add already cleared or replaced the mark.
                guard !item.isDeleted, item.playlistID == playlist.id, item.evictedAt == nil else { continue }
                item.appleMusicAddPendingAt = nil
                item.updatedAt = .now
                try context.save()
            }
            return addedCount
        }
    }

    static func itemsAwaitingAppleMusic(in playlist: PlaylistRecord, _ context: ModelContext) throws -> [PlaylistItemRecord] {
        try PlaylistItemRepository.items(forPlaylistID: playlist.id, in: context)
            .filter { $0.evictedAt == nil && $0.appleMusicAddPendingAt != nil }
    }

    /// Adds a catalog song Overplay does not track yet to a writable Apple
    /// Music playlist, as Search does (`PLAY-018`).
    func addCatalogSong(id songID: String, to playlistRecord: PlaylistRecord, in context: ModelContext) async throws {
        guard playlistRecord.allowsRemoteWrites else { throw PlaylistMutationError.playlistIncomingOnly }
        try await PlaylistRemoteMutationCoordinator.shared.perform(playlistID: playlistRecord.musicPlaylistID) {
            let playlist = try await PlaylistSyncService().loadPlaylist(
                id: playlistRecord.musicPlaylistID,
                name: playlistRecord.name,
                playlistRecord: playlistRecord,
                in: context
            )
            let song = try await song(id: songID)
            try await MusicKitActivityLog.shared.measure(.libraryPlaylistAddItem) {
                try await AppleMusicPlaylistWrites.add(song, to: playlist)
            }
        }
    }

    /// Adds a song only the library knows, such as an upload, to a writable
    /// Apple Music playlist. It goes through the same "already there" check
    /// as a promotion, so it is added once (`PLAYLIST-008`).
    func addLibrarySong(id songID: String, to playlistRecord: PlaylistRecord, in context: ModelContext) async throws {
        guard playlistRecord.allowsRemoteWrites else { throw PlaylistMutationError.playlistIncomingOnly }
        try await PlaylistRemoteMutationCoordinator.shared.perform(playlistID: playlistRecord.musicPlaylistID) {
            // Never inserted: it only carries the ID to the shared add.
            let track = TrackRecord(libraryID: songID, title: "", artistName: "")
            try await addUnlessPresent(track, to: playlistRecord, in: context)
        }
    }

    /// A song already in iCloud's copy, for example one whose earlier
    /// removal could not run, is not added a second time (`PLAYLIST-008`).
    /// When iCloud cannot be checked, adding is the safe default.
    private func addUnlessPresent(_ track: TrackRecord, to playlist: PlaylistRecord, in context: ModelContext) async throws {
        if (try? await remoteMembership.contains(track, in: playlist)) == true {
            TrackMetadataDiagnostics.log("remote add skipped: already in playlist=\(playlist.musicPlaylistID) track=\(track.id)")
            return
        }
        if let addRemotely { try await addRemotely(track, playlist, context) }
        else { try await add(track: track, to: playlist, in: context) }
    }

    private func add(track: TrackRecord, to playlistRecord: PlaylistRecord, in context: ModelContext) async throws {
        // A catalog request cannot find a library ID, and uploaded and
        // matched songs legitimately have no catalog ID.
        let song: Song
        if let catalogID = track.catalogID {
            song = try await self.song(id: catalogID)
        } else if let libraryID = track.libraryID {
            song = try await librarySong(libraryID)
        } else {
            throw PlaylistMutationError.musicItemMissing
        }
        if let writeSong {
            try await writeSong(song, playlistRecord, context)
            return
        }
        let playlist = try await PlaylistSyncService().loadPlaylist(
            id: playlistRecord.musicPlaylistID,
            name: playlistRecord.name,
            playlistRecord: playlistRecord,
            in: context
        )
        try await MusicKitActivityLog.shared.measure(.libraryPlaylistAddItem) {
            try await AppleMusicPlaylistWrites.add(song, to: playlist)
        }
    }

    /// The device's library first, then the web library: a device's library
    /// can lag the account, and manual add confirms a song through the web.
    static func liveLibrarySong(id: String) async throws -> Song {
        do {
            return try await DevicePlaybackCache.loadLibrarySong(id)
        } catch is DevicePlaybackCache.PreparationError {
            throw PlaylistMutationError.musicItemMissing
        }
    }

    private func song(id: String) async throws -> Song {
        guard let song = try await AppleMusicSongLookup.catalogSong(id: id, detail: "song by id", limit: 1) else {
            throw PlaylistMutationError.musicItemMissing
        }
        return song
    }
}
