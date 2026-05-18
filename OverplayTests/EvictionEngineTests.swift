import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("EvictionEngine")
struct EvictionEngineTests {
    @Test("early skip increments count and evicts at threshold")
    func earlySkipIncrementsCountAndEvictsAtThreshold() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let settings = OverplaySettings(evictAfterSkips: 3)
        let playlist = PlaylistRecord(
            musicPlaylistID: "playlist-1",
            name: "Main",
            role: .oneTruePlaylist
        )
        let track = TrackedTrack(
            id: "track-1",
            playlistID: "playlist-1",
            title: "Skip Candidate",
            artistName: "Sample Artist",
            skipCount: 2
        )
        context.insert(settings)
        context.insert(playlist)
        context.insert(track)

        let session = TrackPlaySession(
            trackID: track.id,
            sessionStartDate: .now,
            lastObservedPlaybackTime: 20,
            durationSeconds: 100,
            hasEvaluated: false
        )

        try EvictionEngine.evaluateSkip(
            session: session,
            transitionWasNaturalCompletion: false,
            settings: settings,
            context: context
        )

        let events = try OverplayTestSupport.playbackEvents(in: context)
        #expect(track.skipCount == 3)
        #expect(track.isEvicted)
        #expect(track.evictionReason == "3 skips before 50%")
        #expect(events.contains { $0.eventType == "skipCounted" })
        #expect(events.contains { $0.eventType == "evicted" })
    }

    @Test("triage legacy track counts skip but does not auto evict")
    func triageLegacyTrackCountsSkipButDoesNotAutoEvict() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let settings = OverplaySettings(evictAfterSkips: 3)
        let playlist = PlaylistRecord(
            musicPlaylistID: "playlist-2",
            name: "Triage",
            role: .triage
        )
        let track = TrackedTrack(
            id: "track-1",
            playlistID: "playlist-2",
            title: "Triage Candidate",
            artistName: "Sample Artist",
            skipCount: 2
        )
        context.insert(settings)
        context.insert(playlist)
        context.insert(track)

        let session = TrackPlaySession(
            trackID: track.id,
            sessionStartDate: .now,
            lastObservedPlaybackTime: 20,
            durationSeconds: 100,
            hasEvaluated: false
        )

        try EvictionEngine.evaluateSkip(
            session: session,
            transitionWasNaturalCompletion: false,
            settings: settings,
            context: context
        )

        let events = try OverplayTestSupport.playbackEvents(in: context)
        #expect(track.skipCount == 3)
        #expect(!track.isEvicted)
        #expect(events.contains { $0.eventType == "skipCounted" })
        #expect(events.contains {
            $0.eventType == "skipIgnored"
                && $0.reason == "Automatic eviction is limited to the One True Playlist"
        })
    }

    @Test("skip before minimum listening time is ignored")
    func skipBeforeMinimumListeningTimeIsIgnored() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let settings = OverplaySettings(minimumSkipListeningSeconds: 10)
        let track = TrackedTrack(
            id: "track-1",
            playlistID: "playlist-1",
            title: "Too Soon",
            artistName: "Sample Artist"
        )
        context.insert(settings)
        context.insert(track)

        let session = TrackPlaySession(
            trackID: track.id,
            sessionStartDate: .now,
            lastObservedPlaybackTime: 4,
            durationSeconds: 100,
            hasEvaluated: false
        )

        try EvictionEngine.evaluateSkip(
            session: session,
            transitionWasNaturalCompletion: false,
            settings: settings,
            context: context
        )

        let events = try OverplayTestSupport.playbackEvents(in: context)
        #expect(track.skipCount == 0)
        #expect(!track.isEvicted)
        #expect(events.contains { $0.eventType == "skipIgnored" && $0.reason == "Below minimum listening time" })
    }

    @Test("playthrough increments count and resets skips")
    func playthroughIncrementsCountAndResetsSkips() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let settings = OverplaySettings(playthroughResetsSkipCount: true)
        let track = TrackedTrack(
            id: "track-1",
            playlistID: "playlist-1",
            title: "Keeper",
            artistName: "Sample Artist",
            skipCount: 2
        )
        context.insert(settings)
        context.insert(track)

        let session = TrackPlaySession(
            trackID: track.id,
            sessionStartDate: .now,
            lastObservedPlaybackTime: 95,
            durationSeconds: 100,
            hasEvaluated: false
        )

        try EvictionEngine.evaluateSkip(
            session: session,
            transitionWasNaturalCompletion: true,
            settings: settings,
            context: context
        )

        let events = try OverplayTestSupport.playbackEvents(in: context)
        #expect(track.playthroughCount == 1)
        #expect(track.skipCount == 0)
        #expect(events.contains { $0.eventType == "playthrough" })
    }

    @Test("triage playlist item counts skip but does not auto evict")
    func triagePlaylistItemCountsSkipButDoesNotAutoEvict() throws {
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
        #expect(history.contains {
            $0.eventType == .skipIgnored
                && $0.message == "Automatic eviction is limited to the One True Playlist"
        })
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
