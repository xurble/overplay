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

    var errorDescription: String? {
        switch self {
        case .oneTruePlaylistMissing:
            "Choose a One True Playlist before Overplaying tracks."
        case .sourcePlaylistMissing:
            "The source playlist is no longer linked."
        case .sourcePlaylistNotTriage:
            "Only tracks in the triage bucket can be Overplayed."
        case .trackMissing:
            "The track is no longer available locally."
        case .musicItemMissing:
            "This track does not have an Apple Music identifier Overplay can add."
        case .playlistIncomingOnly:
            "This playlist is incoming only, so Overplay will not write changes back to Apple Music."
        }
    }
}

@MainActor
struct PlaylistMutationService {
    // Inject only the remote boundary; durable movement remains shared.
    var addRemotely: (@MainActor (TrackRecord, PlaylistRecord, ModelContext) async throws -> Void)?

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
        return try await PlaylistRemoteMutationCoordinator.shared.perform(playlistID: playlist.musicPlaylistID) {
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
            if let addRemotely {
                try await addRemotely(track, oneTruePlaylist, context)
            } else {
                try await add(track: track, to: oneTruePlaylist, in: context)
            }
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
                message: "Overplay failed: \(error.localizedDescription)",
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
        TrackLocationService.moveToOTP(promotedItem, playlist: oneTruePlaylist, source: .user, at: promotedAt, in: context)
        promotedItem.lastSeenInPlaylistAt = promotedAt
        promotedItem.updatedAt = promotedAt
        try appendToLocalOrder(item: promotedItem, playlist: oneTruePlaylist, in: context)

        return promotedItem
    }

    @discardableResult
    func recordSuccessfulManualAdd(
        _ result: SearchSongResult,
        to playlist: PlaylistRecord,
        addedAt: Date = .now,
        in context: ModelContext
    ) throws -> PlaylistItemRecord {
        let identity = MusicTrackIdentity.ids(fromRawID: result.id)
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
            TrackLocationService.moveToOTP(item, playlist: playlist, source: .user, logEvent: false, at: addedAt, in: context)
        } else if item.playlistID == playlist.id {
            try TrackLocationService.moveToTriage(item, explicitKeep: true, logEvent: false, at: addedAt, in: context)
        }
        item.lastSeenInPlaylistAt = addedAt
        item.updatedAt = addedAt
        if item.playlistID == playlist.id {
            try appendToLocalOrder(item: item, playlist: playlist, in: context)
        }

        EventRepository.logHistory(
            playlistID: playlist.id,
            trackID: track.id,
            eventType: .trackAdded,
            source: .user,
            remoteMutationStatus: .succeeded,
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

    private func add(track: TrackRecord, to playlistRecord: PlaylistRecord, in context: ModelContext) async throws {
        guard let musicItemID = track.catalogID ?? track.libraryID else {
            throw PlaylistMutationError.musicItemMissing
        }

        let playlist = try await PlaylistSyncService().loadPlaylist(
            id: playlistRecord.musicPlaylistID,
            name: playlistRecord.name,
            playlistRecord: playlistRecord,
            in: context
        )
        let song = try await song(id: musicItemID)
        try await MusicKitActivityLog.shared.measure(.libraryPlaylistAddItem) {
            try await MusicLibrary.shared.add(song, to: playlist)
        }
    }

    private func song(id: String) async throws -> Song {
        var request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(id))
        request.limit = 1
        let items = try await MusicKitActivityLog.shared.measure(
            .catalogResourceFetch,
            detail: "song by id",
            resultMagnitude: { Double($0.count) }
        ) {
            try await request.response().items
        }
        guard let song = items.first else {
            throw PlaylistMutationError.musicItemMissing
        }
        return song
    }

    private func appendToLocalOrder(
        item: PlaylistItemRecord,
        playlist: PlaylistRecord,
        in context: ModelContext
    ) throws {
        let items = try PlaylistItemRepository.items(forPlaylistID: playlist.id, in: context)
        PlaybackOrderCoordinator.appendTrackIDs(
            [item.trackID.uuidString],
            playerID: "main",
            playlistID: playlist.musicPlaylistID,
            orderTracks: PlaybackQueueBuilder.playbackOrderTracks(items: items)
        )
    }
}
