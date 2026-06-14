import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("Playlist mutation service")
struct PlaylistMutationServiceTests {
    @Test("successful promotion creates active one true playlist item and evicts source")
    func successfulPromotionCreatesActiveOneTruePlaylistItemAndEvictsSource() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let sourcePlaylist = PlaylistRecord(
            musicPlaylistID: "triage-playlist",
            name: "Triage",
            role: .triage
        )
        let oneTruePlaylist = PlaylistRecord(
            musicPlaylistID: "main-playlist",
            name: "Main",
            role: .oneTruePlaylist
        )
        let track = TrackRecord(
            catalogID: "catalog-1",
            libraryID: "library-1",
            title: "Keeper",
            artistName: "Sample Artist"
        )
        let sourceItem = PlaylistItemRecord(
            playlistID: sourcePlaylist.id,
            trackID: track.id,
            skipCount: 2,
            playthroughCount: 1
        )
        context.insert(sourcePlaylist)
        context.insert(oneTruePlaylist)
        context.insert(track)
        context.insert(sourceItem)

        let promotedItem = try PlaylistMutationService().recordSuccessfulPromotion(
            sourceItem: sourceItem,
            sourcePlaylist: sourcePlaylist,
            oneTruePlaylist: oneTruePlaylist,
            track: track,
            promotedAt: Date(timeIntervalSince1970: 100),
            in: context
        )
        try context.save()

        let oneTrueItems = try PlaylistItemRepository.items(forPlaylistID: oneTruePlaylist.id, in: context)
        let history = try context.fetch(FetchDescriptor<HistoryEvent>())

        #expect(oneTrueItems.count == 1)
        #expect(oneTrueItems.first?.id == promotedItem.id)
        #expect(promotedItem.trackID == track.id)
        #expect(promotedItem.evictedAt == nil)
        #expect(promotedItem.lastSeenInPlaylistAt == Date(timeIntervalSince1970: 100))
        #expect(sourceItem.skipCount == 2)
        #expect(sourceItem.playthroughCount == 1)
        #expect(sourceItem.evictedAt != nil)
        #expect(sourceItem.evictionReason == .manual)
        #expect(sourceItem.evictionSource == .user)
        #expect(history.count == 2)
        #expect(history.contains {
            $0.playlistID == sourcePlaylist.id
                && $0.trackID == track.id
                && $0.eventType == .promoted
                && $0.remoteMutationStatus == .succeeded
        })
        #expect(history.contains {
            $0.playlistID == sourcePlaylist.id
                && $0.trackID == track.id
                && $0.eventType == .evicted
                && $0.source == .user
        })
    }

    @Test("successful promotion reactivates existing one true playlist item")
    func successfulPromotionReactivatesExistingOneTruePlaylistItem() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let sourcePlaylist = PlaylistRecord(
            musicPlaylistID: "triage-playlist",
            name: "Triage",
            role: .triage
        )
        let oneTruePlaylist = PlaylistRecord(
            musicPlaylistID: "main-playlist",
            name: "Main",
            role: .oneTruePlaylist
        )
        let track = TrackRecord(
            catalogID: "catalog-1",
            libraryID: "library-1",
            title: "Keeper",
            artistName: "Sample Artist"
        )
        let sourceItem = PlaylistItemRecord(
            playlistID: sourcePlaylist.id,
            trackID: track.id,
            skipCount: 1
        )
        let existingMainItem = PlaylistItemRecord(
            playlistID: oneTruePlaylist.id,
            trackID: track.id,
            evictedAt: Date(timeIntervalSince1970: 60),
            evictionReason: .skipCount,
            evictionSource: .playbackRule
        )
        context.insert(sourcePlaylist)
        context.insert(oneTruePlaylist)
        context.insert(track)
        context.insert(sourceItem)
        context.insert(existingMainItem)

        let promotedItem = try PlaylistMutationService().recordSuccessfulPromotion(
            sourceItem: sourceItem,
            sourcePlaylist: sourcePlaylist,
            oneTruePlaylist: oneTruePlaylist,
            track: track,
            promotedAt: Date(timeIntervalSince1970: 100),
            in: context
        )
        try context.save()

        let oneTrueItems = try PlaylistItemRepository.items(forPlaylistID: oneTruePlaylist.id, in: context)

        #expect(oneTrueItems.count == 1)
        #expect(promotedItem.id == existingMainItem.id)
        #expect(existingMainItem.evictedAt == nil)
        #expect(existingMainItem.evictionReason == nil)
        #expect(existingMainItem.evictionSource == nil)
    }

    @Test("promotion without one true playlist leaves local state unchanged")
    func promotionWithoutOneTruePlaylistLeavesLocalStateUnchanged() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let sourcePlaylist = PlaylistRecord(
            musicPlaylistID: "triage-playlist",
            name: "Triage",
            role: .triage
        )
        let track = TrackRecord(
            catalogID: "catalog-1",
            libraryID: "library-1",
            title: "Keeper",
            artistName: "Sample Artist"
        )
        let sourceItem = PlaylistItemRecord(
            playlistID: sourcePlaylist.id,
            trackID: track.id,
            skipCount: 2
        )
        context.insert(sourcePlaylist)
        context.insert(track)
        context.insert(sourceItem)

        do {
            _ = try await PlaylistMutationService().promote(item: sourceItem, in: context)
            Issue.record("Promotion should fail when no One True Playlist is configured.")
        } catch PlaylistMutationError.oneTruePlaylistMissing {
            // Expected: the guard fails before any remote or local mutation.
        } catch {
            Issue.record("Unexpected promotion error: \(error)")
        }

        let allItems = try PlaylistItemRepository.allItems(in: context)
        let history = try context.fetch(FetchDescriptor<HistoryEvent>())
        #expect(allItems.count == 1)
        #expect(allItems.first?.id == sourceItem.id)
        #expect(sourceItem.skipCount == 2)
        #expect(history.isEmpty)
    }

    @Test("promotion to incoming only one true playlist is rejected without changing local state")
    func promotionToIncomingOnlyOneTruePlaylistIsRejectedWithoutChangingLocalState() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let sourcePlaylist = PlaylistRecord(
            musicPlaylistID: "triage-playlist",
            name: "Triage",
            role: .triage
        )
        let oneTruePlaylist = PlaylistRecord(
            musicPlaylistID: "source-playlist",
            name: "Source",
            role: .oneTruePlaylist,
            writePolicy: .incomingOnly
        )
        let track = TrackRecord(catalogID: "song-1", libraryID: "song-1", title: "Song", artistName: "Artist")
        let sourceItem = PlaylistItemRecord(
            playlistID: sourcePlaylist.id,
            trackID: track.id,
            skipCount: 1
        )
        context.insert(sourcePlaylist)
        context.insert(oneTruePlaylist)
        context.insert(track)
        context.insert(sourceItem)
        try context.save()

        do {
            _ = try await PlaylistMutationService().promote(item: sourceItem, in: context)
            Issue.record("Promotion should fail for incoming-only One True Playlists.")
        } catch PlaylistMutationError.playlistIncomingOnly {
            // Expected: incoming-only playlists never receive outbound writes.
        }

        let oneTrueItems = try PlaylistItemRepository.items(forPlaylistID: oneTruePlaylist.id, in: context)
        let history = try context.fetch(FetchDescriptor<HistoryEvent>())

        #expect(oneTrueItems.isEmpty)
        #expect(history.isEmpty)
    }

    @Test("promotion from one true playlist is rejected without changing local state")
    func promotionFromOneTruePlaylistIsRejectedWithoutChangingLocalState() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let oneTruePlaylist = PlaylistRecord(
            musicPlaylistID: "main-playlist",
            name: "Main",
            role: .oneTruePlaylist
        )
        let track = TrackRecord(
            catalogID: "catalog-1",
            libraryID: "library-1",
            title: "Already Main",
            artistName: "Sample Artist"
        )
        let sourceItem = PlaylistItemRecord(
            playlistID: oneTruePlaylist.id,
            trackID: track.id,
            skipCount: 2,
            playthroughCount: 1
        )
        context.insert(oneTruePlaylist)
        context.insert(track)
        context.insert(sourceItem)

        do {
            _ = try await PlaylistMutationService().promote(item: sourceItem, in: context)
            Issue.record("Promotion should fail for non-triage source playlists.")
        } catch PlaylistMutationError.sourcePlaylistNotTriage {
            // Expected: promotion is only valid from triage playlists.
        } catch {
            Issue.record("Unexpected promotion error: \(error)")
        }

        let allItems = try PlaylistItemRepository.allItems(in: context)
        let history = try context.fetch(FetchDescriptor<HistoryEvent>())
        #expect(allItems.count == 1)
        #expect(allItems.first?.id == sourceItem.id)
        #expect(sourceItem.skipCount == 2)
        #expect(sourceItem.playthroughCount == 1)
        #expect(history.isEmpty)
    }

    @Test("promotion without music identifier records failure without creating one true item")
    func promotionWithoutMusicIdentifierRecordsFailureWithoutCreatingOneTrueItem() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let sourcePlaylist = PlaylistRecord(
            musicPlaylistID: "triage-playlist",
            name: "Triage",
            role: .triage
        )
        let oneTruePlaylist = PlaylistRecord(
            musicPlaylistID: "main-playlist",
            name: "Main",
            role: .oneTruePlaylist
        )
        let track = TrackRecord(
            title: "Local Only",
            artistName: "Sample Artist"
        )
        let sourceItem = PlaylistItemRecord(
            playlistID: sourcePlaylist.id,
            trackID: track.id,
            skipCount: 2,
            playthroughCount: 1
        )
        context.insert(sourcePlaylist)
        context.insert(oneTruePlaylist)
        context.insert(track)
        context.insert(sourceItem)

        do {
            _ = try await PlaylistMutationService().promote(item: sourceItem, in: context)
            Issue.record("Promotion should fail when the track has no Apple Music identifier.")
        } catch PlaylistMutationError.musicItemMissing {
            // Expected: no remote mutation can be attempted for a local-only track.
        } catch {
            Issue.record("Unexpected promotion error: \(error)")
        }

        let oneTrueItems = try PlaylistItemRepository.items(forPlaylistID: oneTruePlaylist.id, in: context)
        let history = try context.fetch(FetchDescriptor<HistoryEvent>())
        #expect(oneTrueItems.isEmpty)
        #expect(sourceItem.skipCount == 2)
        #expect(sourceItem.playthroughCount == 1)
        #expect(history.count == 1)
        #expect(history.first?.playlistID == sourcePlaylist.id)
        #expect(history.first?.trackID == track.id)
        #expect(history.first?.eventType == .remoteMutation)
        #expect(history.first?.remoteMutationStatus == .failed)
    }

    @Test("successful manual add creates active item for one true playlist")
    func successfulManualAddCreatesActiveItemForOneTruePlaylist() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(
            musicPlaylistID: "main-playlist",
            name: "Main",
            role: .oneTruePlaylist
        )
        let result = SearchSongResult(
            id: "catalog-1",
            title: "New Main Track",
            artistName: "Sample Artist",
            albumTitle: "Samples",
            artworkURL: "https://example.com/artwork.jpg"
        )
        context.insert(playlist)

        let item = try PlaylistMutationService().recordSuccessfulManualAdd(
            result,
            to: playlist,
            addedAt: Date(timeIntervalSince1970: 100),
            in: context
        )

        let tracks = try TrackRecordRepository.allTracks(in: context)
        let items = try PlaylistItemRepository.items(forPlaylistID: playlist.id, in: context)
        let history = try context.fetch(FetchDescriptor<HistoryEvent>())
        #expect(tracks.count == 1)
        #expect(tracks.first?.catalogID == "catalog-1")
        #expect(tracks.first?.title == "New Main Track")
        #expect(items.count == 1)
        #expect(items.first?.id == item.id)
        #expect(item.evictedAt == nil)
        #expect(item.lastSeenInPlaylistAt == Date(timeIntervalSince1970: 100))
        #expect(history.count == 1)
        #expect(history.first?.playlistID == playlist.id)
        #expect(history.first?.trackID == tracks.first?.id)
        #expect(history.first?.eventType == .trackAdded)
        #expect(history.first?.remoteMutationStatus == .succeeded)
    }

    @Test("successful manual add reactivates existing triage item")
    func successfulManualAddReactivatesExistingTriageItem() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(
            musicPlaylistID: "triage-playlist",
            name: "Triage",
            role: .triage
        )
        let track = TrackRecord(
            catalogID: "catalog-1",
            libraryID: "catalog-1",
            title: "Old Triage Track",
            artistName: "Sample Artist"
        )
        let existingItem = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: track.id,
            evictedAt: Date(timeIntervalSince1970: 60),
            evictionReason: .manual,
            evictionSource: .user
        )
        let result = SearchSongResult(
            id: "catalog-1",
            title: "Updated Triage Track",
            artistName: "Sample Artist",
            albumTitle: nil,
            artworkURL: nil
        )
        context.insert(playlist)
        context.insert(track)
        context.insert(existingItem)

        let item = try PlaylistMutationService().recordSuccessfulManualAdd(
            result,
            to: playlist,
            addedAt: Date(timeIntervalSince1970: 100),
            in: context
        )

        let items = try PlaylistItemRepository.items(forPlaylistID: playlist.id, in: context)
        #expect(items.count == 1)
        #expect(item.id == existingItem.id)
        #expect(track.title == "Updated Triage Track")
        #expect(existingItem.evictedAt == nil)
        #expect(existingItem.evictionReason == nil)
        #expect(existingItem.evictionSource == nil)
    }

    @Test("failed manual add records remote mutation without local item")
    func failedManualAddRecordsRemoteMutationWithoutLocalItem() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(
            musicPlaylistID: "triage-playlist",
            name: "Triage",
            role: .triage
        )
        let result = SearchSongResult(
            id: "catalog-1",
            title: "Rejected Track",
            artistName: "Sample Artist",
            albumTitle: nil,
            artworkURL: nil
        )
        context.insert(playlist)

        PlaylistMutationService().recordFailedManualAdd(
            result,
            to: playlist,
            message: "Library mutation failed.",
            in: context
        )

        let tracks = try TrackRecordRepository.allTracks(in: context)
        let items = try PlaylistItemRepository.items(forPlaylistID: playlist.id, in: context)
        let history = try context.fetch(FetchDescriptor<HistoryEvent>())
        #expect(tracks.isEmpty)
        #expect(items.isEmpty)
        #expect(history.count == 1)
        #expect(history.first?.playlistID == playlist.id)
        #expect(history.first?.trackID == nil)
        #expect(history.first?.eventType == .remoteMutation)
        #expect(history.first?.remoteMutationStatus == .failed)
    }
}
