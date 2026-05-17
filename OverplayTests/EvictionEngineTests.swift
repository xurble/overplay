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
        let track = TrackedTrack(
            id: "track-1",
            playlistID: "playlist-1",
            title: "Skip Candidate",
            artistName: "Sample Artist",
            skipCount: 2
        )
        context.insert(settings)
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
}
