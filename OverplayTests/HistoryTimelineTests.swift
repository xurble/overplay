import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("History timeline")
struct HistoryTimelineTests {
    @Test("history rows sort newest first and include playlist and track context")
    func historyRowsSortNewestFirstAndIncludeContext() throws {
        let playlist = PlaylistRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            musicPlaylistID: "playlist-1",
            name: "Main",
            role: .oneTruePlaylist
        )
        let track = TrackRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            catalogID: "catalog-1",
            title: "First Song",
            artistName: "Sample Artist"
        )
        let olderEvent = HistoryEvent(
            playlistID: playlist.id,
            trackID: track.id,
            eventType: .evicted,
            source: .playback,
            skipCountAtEvent: 3,
            message: "3 skips before 50%",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let newerEvent = HistoryEvent(
            playlistID: playlist.id,
            trackID: track.id,
            eventType: .promoted,
            source: .user,
            remoteMutationStatus: .succeeded,
            message: "Promoted to Main",
            createdAt: Date(timeIntervalSince1970: 20)
        )

        let rows = HistoryTimeline.rows(
            events: [olderEvent, newerEvent],
            playlists: [playlist],
            tracks: [track]
        )

        #expect(rows.map(\.eventType) == [.promoted, .evicted])
        #expect(rows.first?.trackTitle == "First Song")
        #expect(rows.first?.subtitle == "Sample Artist - Main")
        #expect(rows.first?.sourceTitle == "Manual")
        #expect(rows.first?.remoteMutationStatusText == "Remote succeeded")
        #expect(rows.last?.skipCountText == "3 skips")
    }

    @Test("history filters include expected event groups")
    func historyFiltersIncludeExpectedEventGroups() throws {
        let playlistID = UUID()
        let trackID = UUID()
        let events = [
            HistoryEvent(playlistID: playlistID, trackID: trackID, eventType: .evicted, source: .playback),
            HistoryEvent(playlistID: playlistID, trackID: trackID, eventType: .trackRemoved, source: .appleMusic),
            HistoryEvent(playlistID: playlistID, trackID: trackID, eventType: .promoted, source: .user),
            HistoryEvent(playlistID: playlistID, trackID: trackID, eventType: .restored, source: .user),
            HistoryEvent(playlistID: playlistID, trackID: trackID, eventType: .remoteMutation, source: .user, remoteMutationStatus: .failed)
        ]

        #expect(HistoryTimeline.rows(events: events, playlists: [], tracks: [], filter: .evictions).map(\.eventType) == [.evicted])
        #expect(HistoryTimeline.rows(events: events, playlists: [], tracks: [], filter: .removals).map(\.eventType) == [.trackRemoved])
        #expect(HistoryTimeline.rows(events: events, playlists: [], tracks: [], filter: .promotions).map(\.eventType) == [.promoted])
        #expect(HistoryTimeline.rows(events: events, playlists: [], tracks: [], filter: .restores).map(\.eventType) == [.restored])
        #expect(HistoryTimeline.rows(events: events, playlists: [], tracks: [], filter: .remoteMutations).map(\.eventType) == [.remoteMutation])
    }

    @Test("restoring playlist item clears eviction state")
    func restoringPlaylistItemClearsEvictionState() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(
            musicPlaylistID: "playlist-1",
            name: "Main",
            role: .oneTruePlaylist
        )
        let item = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: UUID(),
            skipCount: 3,
            evictedAt: Date(timeIntervalSince1970: 10),
            evictionReason: .manual,
            evictionSource: .user
        )
        context.insert(playlist)
        context.insert(item)

        EvictionEngine.restore(item, playlist: playlist, context: context)
        try context.save()

        let history = try context.fetch(FetchDescriptor<HistoryEvent>())
        #expect(item.evictedAt == nil)
        #expect(item.evictionReason == nil)
        #expect(item.evictionSource == nil)
        #expect(history.count == 1)
        #expect(history.first?.eventType == .restored)
        #expect(history.first?.source == .user)
        #expect(history.first?.skipCountAtEvent == 3)
    }
}
