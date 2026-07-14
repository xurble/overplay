import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("EvictionEngine")
struct EvictionEngineTests {
    @Test("early skip increments count without auto eviction")
    func earlySkipIncrementsCountWithoutAutoEviction() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let settings = OverplaySettings(evictAfterSkips: 3)
        let playlist = PlaylistRecord(
            musicPlaylistID: "playlist-1",
            name: "Main",
            role: .oneTruePlaylist
        )
        let item = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: UUID(),
            skipCount: 2
        )
        context.insert(settings)
        context.insert(playlist)
        context.insert(item)

        let session = TrackPlaySession(
            trackID: "track-1",
            sessionStartDate: .now,
            lastObservedPlaybackTime: 20,
            durationSeconds: 100,
            hasEvaluated: false
        )

        EvictionEngine.evaluateSkip(
            item: item,
            playlist: playlist,
            session: session,
            transitionWasNaturalCompletion: false,
            settings: settings,
            context: context
        )

        let history = try context.fetch(FetchDescriptor<HistoryEvent>())
        #expect(item.skipCount == 3)
        #expect(item.evictedAt == nil)
        #expect(item.evictionReason == nil)
        #expect(history.contains { $0.eventType == .skipCounted })
        #expect(!history.contains { $0.eventType == .evicted })
    }

    @Test("protected playlist item still counts skip")
    func protectedPlaylistItemStillCountsSkip() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let settings = OverplaySettings(evictAfterSkips: 3)
        let playlist = PlaylistRecord(
            musicPlaylistID: "playlist-1",
            name: "Main",
            role: .oneTruePlaylist
        )
        let item = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: UUID(),
            skipCount: 2,
            protected: true
        )
        context.insert(settings)
        context.insert(playlist)
        context.insert(item)

        let session = TrackPlaySession(
            trackID: "track-1",
            sessionStartDate: .now,
            lastObservedPlaybackTime: 20,
            durationSeconds: 100,
            hasEvaluated: false
        )

        EvictionEngine.evaluateSkip(
            item: item,
            playlist: playlist,
            session: session,
            transitionWasNaturalCompletion: false,
            settings: settings,
            context: context
        )

        let history = try context.fetch(FetchDescriptor<HistoryEvent>())
        #expect(item.skipCount == 3)
        #expect(item.evictedAt == nil)
        #expect(history.contains { $0.eventType == .skipCounted })
    }

    @Test("skip before minimum listening time is ignored")
    func skipBeforeMinimumListeningTimeIsIgnored() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let settings = OverplaySettings(minimumSkipListeningSeconds: 10)
        let playlist = PlaylistRecord(
            musicPlaylistID: "playlist-1",
            name: "Main",
            role: .oneTruePlaylist
        )
        let item = PlaylistItemRecord(playlistID: playlist.id, trackID: UUID())
        context.insert(settings)
        context.insert(playlist)
        context.insert(item)

        let session = TrackPlaySession(
            trackID: "track-1",
            sessionStartDate: .now,
            lastObservedPlaybackTime: 4,
            durationSeconds: 100,
            hasEvaluated: false
        )

        EvictionEngine.evaluateSkip(
            item: item,
            playlist: playlist,
            session: session,
            transitionWasNaturalCompletion: false,
            settings: settings,
            context: context
        )

        let history = try context.fetch(FetchDescriptor<HistoryEvent>())
        #expect(item.skipCount == 0)
        #expect(item.evictedAt == nil)
        #expect(history.contains { $0.eventType == .skipIgnored && $0.message == "Below minimum listening time" })
    }

    @Test("playthrough increments count without resetting skips")
    func playthroughIncrementsCountWithoutResettingSkips() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let settings = OverplaySettings()
        let playlist = PlaylistRecord(
            musicPlaylistID: "playlist-1",
            name: "Main",
            role: .oneTruePlaylist
        )
        let item = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: UUID(),
            skipCount: 2
        )
        context.insert(settings)
        context.insert(playlist)
        context.insert(item)

        let session = TrackPlaySession(
            trackID: "track-1",
            sessionStartDate: .now,
            lastObservedPlaybackTime: 95,
            durationSeconds: 100,
            hasEvaluated: false
        )

        EvictionEngine.evaluateSkip(
            item: item,
            playlist: playlist,
            session: session,
            transitionWasNaturalCompletion: true,
            settings: settings,
            context: context
        )

        let history = try context.fetch(FetchDescriptor<HistoryEvent>())
        #expect(item.playthroughCount == 1)
        #expect(item.skipCount == 2)
        #expect(history.contains { $0.eventType == .playthrough })
    }

    @Test("triage playlist item counts skip but does not auto evict by default")
    func triagePlaylistItemCountsSkipButDoesNotAutoEvictByDefault() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let settings = OverplaySettings(evictAfterSkips: 3)
        let playlist = PlaylistRecord(
            musicPlaylistID: "playlist-2",
            name: "Triage",
            role: .triage
        )
        let item = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: UUID(),
            skipCount: 2
        )
        context.insert(settings)
        context.insert(playlist)
        context.insert(item)

        let session = TrackPlaySession(
            trackID: "track-1",
            sessionStartDate: .now,
            lastObservedPlaybackTime: 20,
            durationSeconds: 100,
            hasEvaluated: false
        )

        EvictionEngine.evaluateSkip(
            item: item,
            playlist: playlist,
            session: session,
            transitionWasNaturalCompletion: false,
            settings: settings,
            context: context
        )

        let history = try context.fetch(FetchDescriptor<HistoryEvent>())
        #expect(item.skipCount == 3)
        #expect(item.evictedAt == nil)
        #expect(history.contains { $0.eventType == .skipCounted })
        #expect(!history.contains { $0.eventType == .evicted })
    }

    @Test("triage playlist item does not auto evict when legacy setting is enabled")
    func triagePlaylistItemDoesNotAutoEvictWhenLegacySettingIsEnabled() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let settings = OverplaySettings(
            evictAfterSkips: 3,
            triageAutoEvictsOnSkipCount: true
        )
        let playlist = PlaylistRecord(
            musicPlaylistID: "playlist-2",
            name: "Triage",
            role: .triage
        )
        let item = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: UUID(),
            skipCount: 2
        )
        context.insert(settings)
        context.insert(playlist)
        context.insert(item)

        let session = TrackPlaySession(
            trackID: "track-1",
            sessionStartDate: .now,
            lastObservedPlaybackTime: 20,
            durationSeconds: 100,
            hasEvaluated: false
        )

        EvictionEngine.evaluateSkip(
            item: item,
            playlist: playlist,
            session: session,
            transitionWasNaturalCompletion: false,
            settings: settings,
            context: context
        )

        let history = try context.fetch(FetchDescriptor<HistoryEvent>())
        #expect(item.skipCount == 3)
        #expect(item.evictedAt == nil)
        #expect(item.evictionReason == nil)
        #expect(item.evictionSource == nil)
        #expect(history.contains { $0.eventType == .skipCounted })
        #expect(!history.contains { $0.eventType == .evicted })
    }

    @Test("manual eviction works for triage playlist item")
    func manualEvictionWorksForTriagePlaylistItem() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(
            musicPlaylistID: "playlist-2",
            name: "Triage",
            role: .triage
        )
        let item = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: UUID()
        )
        context.insert(playlist)
        context.insert(item)

        EvictionEngine.evict(
            item,
            playlist: playlist,
            reason: .manual,
            source: .user,
            message: "Evicted manually",
            context: context
        )

        let history = try context.fetch(FetchDescriptor<HistoryEvent>())
        #expect(item.evictedAt != nil)
        #expect(item.evictionReason == .manual)
        #expect(item.evictionSource == .user)
        #expect(history.first?.playlistID == playlist.id)
        #expect(history.first?.trackID == item.trackID)
        #expect(history.first?.eventType == .evicted)
        #expect(history.first?.source == .user)
    }
}
