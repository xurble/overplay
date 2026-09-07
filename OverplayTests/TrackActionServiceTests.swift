import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("Track action service")
struct TrackActionServiceTests {
    @Test("reset skip count logs history")
    func resetSkipCountLogsHistory() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(musicPlaylistID: "playlist-1", name: "Main", role: .oneTruePlaylist)
        let item = PlaylistItemRecord(playlistID: playlist.id, trackID: UUID(), skipCount: 2)
        context.insert(playlist)
        context.insert(item)

        try TrackActionService.resetSkipCount(
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

        try TrackActionService.evictTrack(
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

}
