import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("Playback session evaluation service")
struct PlaybackSessionEvaluationServiceTests {
    @Test("skip transition increments skip count")
    func skipTransitionIncrementsSkipCount() throws {
        let fixture = try makeFixture(skipCount: 0)
        let settings = OverplaySettings(
            evictAfterSkips: 3,
            skipThresholdPercentage: 50,
            minimumSkipListeningSeconds: 0
        )

        let outcome = try PlaybackSessionEvaluationService.evaluateActiveSession(
            activeSession: nil,
            currentTrackID: "library-1",
            elapsedSeconds: 15,
            durationSeconds: 180,
            currentPlaylistItem: fixture.item,
            playlist: fixture.playlist,
            settings: settings,
            naturalCompletion: false,
            context: fixture.context
        )

        let history = try fixture.context.fetch(FetchDescriptor<HistoryEvent>())
        #expect(outcome?.session.hasEvaluated == true)
        #expect(outcome?.evictedDuringEvaluation == false)
        #expect(fixture.item.skipCount == 1)
        #expect(history.first?.eventType == .skipCounted)
    }

    @Test("natural completion counts playthrough and resets skip count when configured")
    func naturalCompletionCountsPlaythrough() throws {
        let fixture = try makeFixture(skipCount: 2)
        let settings = OverplaySettings(
            playthroughThresholdPercentage: 80,
            playthroughResetsSkipCount: true
        )

        let outcome = try PlaybackSessionEvaluationService.evaluateActiveSession(
            activeSession: nil,
            currentTrackID: "library-1",
            elapsedSeconds: 180,
            durationSeconds: 180,
            currentPlaylistItem: fixture.item,
            playlist: fixture.playlist,
            settings: settings,
            naturalCompletion: true,
            context: fixture.context
        )

        let history = try fixture.context.fetch(FetchDescriptor<HistoryEvent>())
        #expect(outcome?.session.hasEvaluated == true)
        #expect(fixture.item.playthroughCount == 1)
        #expect(fixture.item.skipCount == 0)
        #expect(history.first?.eventType == .playthrough)
    }

    @Test("playthrough threshold evaluates observed active session")
    func playthroughThresholdEvaluatesObservedActiveSession() throws {
        let fixture = try makeFixture(skipCount: 2)
        let settings = OverplaySettings(
            playthroughThresholdPercentage: 80,
            playthroughResetsSkipCount: true
        )
        let session = TrackPlaySession(
            trackID: "library-1",
            sessionStartDate: Date(timeIntervalSince1970: 0),
            lastObservedPlaybackTime: 170,
            durationSeconds: 180,
            hasEvaluated: false
        )

        let outcome = try PlaybackSessionEvaluationService.evaluatePlaythroughIfNeeded(
            session: session,
            currentPlaylistItem: fixture.item,
            playlist: fixture.playlist,
            settings: settings,
            context: fixture.context
        )

        let history = try fixture.context.fetch(FetchDescriptor<HistoryEvent>())
        #expect(outcome?.session.hasEvaluated == true)
        #expect(fixture.item.playthroughCount == 1)
        #expect(fixture.item.skipCount == 0)
        #expect(history.first?.eventType == .playthrough)
    }

    @Test("manual next after playthrough threshold resets skip count")
    func manualNextAfterPlaythroughThresholdResetsSkipCount() throws {
        let fixture = try makeFixture(skipCount: 2)
        let settings = OverplaySettings(
            playthroughThresholdPercentage: 80,
            playthroughResetsSkipCount: true
        )

        let outcome = try PlaybackSessionEvaluationService.evaluateActiveSession(
            activeSession: nil,
            currentTrackID: "library-1",
            elapsedSeconds: 170,
            durationSeconds: 180,
            currentPlaylistItem: fixture.item,
            playlist: fixture.playlist,
            settings: settings,
            naturalCompletion: false,
            context: fixture.context
        )

        let history = try fixture.context.fetch(FetchDescriptor<HistoryEvent>())
        #expect(outcome?.session.hasEvaluated == true)
        #expect(fixture.item.playthroughCount == 1)
        #expect(fixture.item.skipCount == 0)
        #expect(history.first?.eventType == .playthrough)
    }

    @Test("mark evaluated without skip prevents skip increment")
    func markEvaluatedWithoutSkipPreventsSkipIncrement() throws {
        let fixture = try makeFixture(skipCount: 0)
        let settings = OverplaySettings(
            skipThresholdPercentage: 50,
            minimumSkipListeningSeconds: 0
        )
        let session = PlaybackSessionEvaluationService.markEvaluatedWithoutSkip(
            activeSession: nil,
            currentTrackID: "library-1",
            elapsedSeconds: 15,
            durationSeconds: 180
        )

        let outcome = try PlaybackSessionEvaluationService.evaluateActiveSession(
            activeSession: session,
            currentTrackID: "library-1",
            elapsedSeconds: 15,
            durationSeconds: 180,
            currentPlaylistItem: fixture.item,
            playlist: fixture.playlist,
            settings: settings,
            naturalCompletion: false,
            context: fixture.context
        )

        #expect(outcome?.session.hasEvaluated == true)
        #expect(fixture.item.skipCount == 0)
    }

    @Test("skip transition resolves playlist item from current item when music id mismatches")
    func skipTransitionResolvesPlaylistItemFromCurrentItemWhenMusicIDMismatches() throws {
        let fixture = try makeFixture(skipCount: 0)
        let settings = OverplaySettings(
            evictAfterSkips: 3,
            skipThresholdPercentage: 50,
            minimumSkipListeningSeconds: 0
        )

        let outcome = try PlaybackSessionEvaluationService.evaluateActiveSession(
            activeSession: TrackPlaySession(
                trackID: "queue-only-id",
                sessionStartDate: .now,
                lastObservedPlaybackTime: 15,
                durationSeconds: 180,
                hasEvaluated: false
            ),
            currentTrackID: "queue-only-id",
            elapsedSeconds: 15,
            durationSeconds: 180,
            currentPlaylistItem: fixture.item,
            playlist: fixture.playlist,
            settings: settings,
            naturalCompletion: false,
            context: fixture.context
        )

        #expect(outcome?.item?.id == fixture.item.id)
        #expect(fixture.item.skipCount == 1)
    }

    @Test("skip transition resolves playlist item from fallback local track id")
    func skipTransitionResolvesPlaylistItemFromFallbackLocalTrackID() throws {
        let fixture = try makeFixture(skipCount: 0)
        let settings = OverplaySettings(
            evictAfterSkips: 3,
            skipThresholdPercentage: 50,
            minimumSkipListeningSeconds: 0
        )

        let outcome = try PlaybackSessionEvaluationService.evaluateActiveSession(
            activeSession: TrackPlaySession(
                trackID: "queue-only-id",
                sessionStartDate: .now,
                lastObservedPlaybackTime: 15,
                durationSeconds: 180,
                hasEvaluated: false
            ),
            currentTrackID: "queue-only-id",
            elapsedSeconds: 15,
            durationSeconds: 180,
            currentPlaylistItem: nil,
            playlist: fixture.playlist,
            settings: settings,
            naturalCompletion: false,
            context: fixture.context,
            fallbackLocalTrackID: fixture.track.id.uuidString
        )

        #expect(outcome?.item?.id == fixture.item.id)
        #expect(fixture.item.skipCount == 1)
    }

    @Test("protected track skips are ignored")
    func protectedTrackSkipsAreIgnored() throws {
        let fixture = try makeFixture(skipCount: 2, protected: true)
        let settings = OverplaySettings(
            evictAfterSkips: 3,
            skipThresholdPercentage: 50,
            minimumSkipListeningSeconds: 0
        )

        let outcome = try PlaybackSessionEvaluationService.evaluateActiveSession(
            activeSession: nil,
            currentTrackID: "library-1",
            elapsedSeconds: 15,
            durationSeconds: 180,
            currentPlaylistItem: fixture.item,
            playlist: fixture.playlist,
            settings: settings,
            naturalCompletion: false,
            context: fixture.context
        )

        let history = try fixture.context.fetch(FetchDescriptor<HistoryEvent>())
        #expect(outcome?.session.hasEvaluated == true)
        #expect(outcome?.evictedDuringEvaluation == false)
        #expect(fixture.item.skipCount == 2)
        #expect(fixture.item.evictedAt == nil)
        #expect(history.first?.eventType == .skipIgnored)
        #expect(history.first?.message == "Protected")
    }

    @Test("skip forward intent warns when skip would count")
    func skipForwardIntentWarnsWhenSkipWouldCount() throws {
        let fixture = try makeFixture(skipCount: 0)
        let settings = OverplaySettings(
            evictAfterSkips: 3,
            skipThresholdPercentage: 50,
            minimumSkipListeningSeconds: 10
        )

        let intent = PlaybackSessionEvaluationService.skipForwardIntent(
            session: session(elapsedSeconds: 15, durationSeconds: 100),
            item: fixture.item,
            playlist: fixture.playlist,
            settings: settings
        )

        #expect(intent == .countedSkip)

        fixture.item.skipCount = 1
        #expect(PlaybackSessionEvaluationService.skipForwardIntent(
            session: session(elapsedSeconds: 15, durationSeconds: 100),
            item: fixture.item,
            playlist: fixture.playlist,
            settings: settings
        ) == .countedSkip)
    }

    @Test("skip forward intent uses trash when skip would evict")
    func skipForwardIntentUsesTrashWhenSkipWouldEvict() throws {
        let fixture = try makeFixture(skipCount: 2)
        let settings = OverplaySettings(
            evictAfterSkips: 3,
            skipThresholdPercentage: 50,
            minimumSkipListeningSeconds: 10
        )

        let intent = PlaybackSessionEvaluationService.skipForwardIntent(
            session: session(elapsedSeconds: 15, durationSeconds: 100),
            item: fixture.item,
            playlist: fixture.playlist,
            settings: settings
        )

        #expect(intent == .eviction)
    }

    @Test("skip forward intent uses reset icon when skip would reset count")
    func skipForwardIntentUsesResetIconWhenSkipWouldResetCount() throws {
        let fixture = try makeFixture(skipCount: 2)
        let settings = OverplaySettings(
            skipThresholdPercentage: 50,
            minimumSkipListeningSeconds: 10,
            playthroughThresholdPercentage: 90,
            playthroughResetsSkipCount: true
        )

        let intent = PlaybackSessionEvaluationService.skipForwardIntent(
            session: session(elapsedSeconds: 92, durationSeconds: 100),
            item: fixture.item,
            playlist: fixture.playlist,
            settings: settings
        )

        #expect(intent == .skipCountReset)
        #expect(intent.systemImage == "cross.case.fill")
    }

    @Test("skip forward intent keeps standard icon for playthroughs without reset")
    func skipForwardIntentKeepsStandardIconForPlaythroughsWithoutReset() throws {
        let fixture = try makeFixture(skipCount: 0)
        let settings = OverplaySettings(
            skipThresholdPercentage: 50,
            minimumSkipListeningSeconds: 10,
            playthroughThresholdPercentage: 90,
            playthroughResetsSkipCount: true
        )

        #expect(PlaybackSessionEvaluationService.skipForwardIntent(
            session: session(elapsedSeconds: 92, durationSeconds: 100),
            item: fixture.item,
            playlist: fixture.playlist,
            settings: settings
        ) == .standard)

        fixture.item.skipCount = 2
        settings.playthroughResetsSkipCount = false
        #expect(PlaybackSessionEvaluationService.skipForwardIntent(
            session: session(elapsedSeconds: 92, durationSeconds: 100),
            item: fixture.item,
            playlist: fixture.playlist,
            settings: settings
        ) == .standard)
    }

    @Test("skip forward intent keeps standard icon for uncounted skips")
    func skipForwardIntentKeepsStandardIconForUncountedSkips() throws {
        let fixture = try makeFixture(skipCount: 2)
        let settings = OverplaySettings(
            evictAfterSkips: 3,
            skipThresholdPercentage: 50,
            minimumSkipListeningSeconds: 10
        )

        #expect(PlaybackSessionEvaluationService.skipForwardIntent(
            session: session(elapsedSeconds: 4, durationSeconds: 100),
            item: fixture.item,
            playlist: fixture.playlist,
            settings: settings
        ) == .standard)
        #expect(PlaybackSessionEvaluationService.skipForwardIntent(
            session: session(elapsedSeconds: 60, durationSeconds: 100),
            item: fixture.item,
            playlist: fixture.playlist,
            settings: settings
        ) == .standard)
        #expect(PlaybackSessionEvaluationService.skipForwardIntent(
            session: session(elapsedSeconds: 15, durationSeconds: 100, hasEvaluated: true),
            item: fixture.item,
            playlist: fixture.playlist,
            settings: settings
        ) == .standard)
        #expect(PlaybackSessionEvaluationService.skipForwardIntent(
            session: nil,
            item: fixture.item,
            playlist: fixture.playlist,
            settings: settings
        ) == .standard)

        fixture.item.protected = true
        #expect(PlaybackSessionEvaluationService.skipForwardIntent(
            session: session(elapsedSeconds: 15, durationSeconds: 100),
            item: fixture.item,
            playlist: fixture.playlist,
            settings: settings
        ) == .standard)

        fixture.item.protected = false
        fixture.item.evictedAt = .now
        #expect(PlaybackSessionEvaluationService.skipForwardIntent(
            session: session(elapsedSeconds: 15, durationSeconds: 100),
            item: fixture.item,
            playlist: fixture.playlist,
            settings: settings
        ) == .standard)
    }

    @Test("skip forward intent respects triage auto-eviction setting")
    func skipForwardIntentRespectsTriageAutoEvictionSetting() throws {
        let fixture = try makeFixture(skipCount: 2, role: .triage)
        let settings = OverplaySettings(
            evictAfterSkips: 3,
            skipThresholdPercentage: 50,
            minimumSkipListeningSeconds: 10,
            triageAutoEvictsOnSkipCount: false
        )

        #expect(PlaybackSessionEvaluationService.skipForwardIntent(
            session: session(elapsedSeconds: 15, durationSeconds: 100),
            item: fixture.item,
            playlist: fixture.playlist,
            settings: settings
        ) == .countedSkip)

        settings.triageAutoEvictsOnSkipCount = true
        #expect(PlaybackSessionEvaluationService.skipForwardIntent(
            session: session(elapsedSeconds: 15, durationSeconds: 100),
            item: fixture.item,
            playlist: fixture.playlist,
            settings: settings
        ) == .eviction)
    }

    private func makeFixture(
        skipCount: Int,
        protected: Bool = false,
        role: PlaylistRole = .oneTruePlaylist
    ) throws -> (
        container: ModelContainer,
        context: ModelContext,
        playlist: PlaylistRecord,
        track: TrackRecord,
        item: PlaylistItemRecord
    ) {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(
            musicPlaylistID: "playlist-1",
            name: "Main",
            role: role
        )
        let track = TrackRecord(
            catalogID: "catalog-1",
            libraryID: "library-1",
            title: "Target Track",
            artistName: "Artist",
            durationSeconds: 180
        )
        let item = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: track.id,
            skipCount: skipCount,
            protected: protected
        )
        context.insert(playlist)
        context.insert(track)
        context.insert(item)
        return (container, context, playlist, track, item)
    }

    private func session(
        elapsedSeconds: Double,
        durationSeconds: Double,
        hasEvaluated: Bool = false
    ) -> TrackPlaySession {
        TrackPlaySession(
            trackID: "library-1",
            sessionStartDate: Date(timeIntervalSince1970: 0),
            lastObservedPlaybackTime: elapsedSeconds,
            durationSeconds: durationSeconds,
            hasEvaluated: hasEvaluated
        )
    }
}
