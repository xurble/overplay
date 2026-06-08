import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("Track health action service")
struct TrackHealthActionServiceTests {
    @Test("keep current track resets skip count and optionally protects")
    func keepCurrentTrackResetsSkipCountAndOptionallyProtects() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(musicPlaylistID: "playlist-1", name: "Main", role: .oneTruePlaylist)
        let item = PlaylistItemRecord(playlistID: playlist.id, trackID: UUID(), skipCount: 3)
        context.insert(playlist)
        context.insert(item)

        try TrackHealthActionService.keepCurrentTrack(
            item,
            playlist: playlist,
            protect: true,
            message: "Kept by user",
            in: context
        )

        let history = try context.fetch(FetchDescriptor<HistoryEvent>())
        #expect(item.skipCount == 0)
        #expect(item.protected)
        #expect(history.count == 1)
        #expect(history.first?.eventType == .skipIgnored)
        #expect(history.first?.message == "Kept by user")
        #expect(history.first?.skipCountAtEvent == 0)
    }

    @Test("reset skip count logs history")
    func resetSkipCountLogsHistory() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(musicPlaylistID: "playlist-1", name: "Main", role: .oneTruePlaylist)
        let item = PlaylistItemRecord(playlistID: playlist.id, trackID: UUID(), skipCount: 2)
        context.insert(playlist)
        context.insert(item)

        try TrackHealthActionService.resetSkipCount(
            item,
            playlist: playlist,
            message: "Skip count reset in CarPlay",
            in: context
        )

        let history = try context.fetch(FetchDescriptor<HistoryEvent>())
        let persistedItem = try #require(try PlaylistItemRepository.item(id: item.id, in: context))
        #expect(item.skipCount == 0)
        #expect(persistedItem.skipCount == 0)
        #expect(history.first?.eventType == .skipIgnored)
        #expect(history.first?.message == "Skip count reset in CarPlay")
        #expect(history.first?.skipCountAtEvent == 0)
    }

    @Test("protect track logs history without resetting skip count")
    func protectTrackLogsHistoryWithoutResettingSkipCount() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(musicPlaylistID: "playlist-1", name: "Main", role: .oneTruePlaylist)
        let item = PlaylistItemRecord(playlistID: playlist.id, trackID: UUID(), skipCount: 2)
        context.insert(playlist)
        context.insert(item)

        try TrackHealthActionService.protectTrack(
            item,
            playlist: playlist,
            message: "Protected in CarPlay",
            in: context
        )

        let history = try context.fetch(FetchDescriptor<HistoryEvent>())
        #expect(item.skipCount == 2)
        #expect(item.protected)
        #expect(history.first?.eventType == .skipIgnored)
        #expect(history.first?.message == "Protected in CarPlay")
        #expect(history.first?.skipCountAtEvent == 2)
    }

    @Test("evict track updates local state and remote mutation policy")
    func evictTrackUpdatesLocalStateAndRemoteMutationPolicy() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(
            musicPlaylistID: "playlist-1",
            name: "Main",
            role: .oneTruePlaylist,
            writePolicy: .managed
        )
        let item = PlaylistItemRecord(playlistID: playlist.id, trackID: UUID(), skipCount: 2)
        context.insert(playlist)
        context.insert(item)

        try TrackHealthActionService.evictTrack(
            item,
            playlist: playlist,
            message: "Evicted manually",
            in: context
        )

        let history = try context.fetch(FetchDescriptor<HistoryEvent>())
        #expect(item.evictedAt != nil)
        #expect(item.evictionReason == .manual)
        #expect(item.evictionSource == .user)
        #expect(PlaylistRemoteMutationPolicy.shouldDeleteRemotelyAfterEviction(item: item, playlist: playlist))
        #expect(history.first?.eventType == .evicted)
        #expect(history.first?.message == "Evicted manually")
    }

    @Test("restore track clears eviction state and logs history")
    func restoreTrackClearsEvictionStateAndLogsHistory() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(musicPlaylistID: "playlist-1", name: "Main", role: .oneTruePlaylist)
        let item = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: UUID(),
            skipCount: 2,
            evictedAt: Date(timeIntervalSince1970: 100),
            evictionReason: .skipCount,
            evictionSource: .playbackRule
        )
        context.insert(playlist)
        context.insert(item)

        try TrackHealthActionService.restoreTrack(item, playlist: playlist, in: context)

        let history = try context.fetch(FetchDescriptor<HistoryEvent>())
        #expect(item.evictedAt == nil)
        #expect(item.evictionReason == nil)
        #expect(item.evictionSource == nil)
        #expect(history.first?.eventType == .restored)
        #expect(history.first?.message == "Restored locally")
        #expect(history.first?.skipCountAtEvent == 2)
    }
}
