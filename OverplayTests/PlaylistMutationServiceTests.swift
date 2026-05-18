import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("Playlist mutation service")
struct PlaylistMutationServiceTests {
    @Test("successful promotion creates active one true playlist item")
    func successfulPromotionCreatesActiveOneTruePlaylistItem() throws {
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
        #expect(promotedItem.removedFromRemoteAt == nil)
        #expect(promotedItem.evictedAt == nil)
        #expect(promotedItem.lastSeenInPlaylistAt == Date(timeIntervalSince1970: 100))
        #expect(sourceItem.skipCount == 2)
        #expect(sourceItem.playthroughCount == 1)
        #expect(history.count == 1)
        #expect(history.first?.playlistID == sourcePlaylist.id)
        #expect(history.first?.trackID == track.id)
        #expect(history.first?.eventType == .promoted)
        #expect(history.first?.remoteMutationStatus == .succeeded)
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
            removedFromRemoteAt: Date(timeIntervalSince1970: 50),
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
        #expect(existingMainItem.removedFromRemoteAt == nil)
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
}
