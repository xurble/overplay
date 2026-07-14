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

    @Test("natural completion counts playthrough without resetting skip count")
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
        #expect(fixture.item.skipCount == 2)
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
        #expect(fixture.item.skipCount == 2)
        #expect(history.first?.eventType == .playthrough)
    }

    @Test("manual next after playthrough threshold counts playthrough without resetting skip count")
    func manualNextAfterPlaythroughThresholdCountsPlaythroughWithoutResettingSkipCount() throws {
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
        #expect(fixture.item.skipCount == 2)
        #expect(history.first?.eventType == .playthrough)
    }

    @Test("stale observation below skip threshold counts nothing")
    func staleObservationBelowSkipThresholdCountsNothing() throws {
        let fixture = try makeFixture(skipCount: 1)
        let settings = OverplaySettings(
            skipThresholdPercentage: 50,
            minimumSkipListeningSeconds: 0
        )
        let now = Date(timeIntervalSince1970: 1_000)
        let staleSession = TrackPlaySession(
            trackID: "library-1",
            sessionStartDate: now.addingTimeInterval(-400),
            lastObservedPlaybackTime: 54,
            lastObservedAt: now.addingTimeInterval(-300),
            durationSeconds: 180,
            hasEvaluated: false
        )

        let outcome = try PlaybackSessionEvaluationService.evaluateActiveSession(
            activeSession: staleSession,
            currentTrackID: "library-1",
            elapsedSeconds: 54,
            durationSeconds: 180,
            currentPlaylistItem: fixture.item,
            playlist: fixture.playlist,
            settings: settings,
            naturalCompletion: false,
            context: fixture.context,
            now: now
        )

        let history = try fixture.context.fetch(FetchDescriptor<HistoryEvent>())
        #expect(outcome?.session.hasEvaluated == true)
        #expect(fixture.item.skipCount == 1)
        #expect(fixture.item.playthroughCount == 0)
        #expect(history.count == 1)
        #expect(history.first?.eventType == .skipIgnored)
        #expect(history.first?.message == "Stale observation")
    }

    @Test("stale observation past playthrough threshold still counts playthrough")
    func staleObservationPastPlaythroughThresholdStillCountsPlaythrough() throws {
        let fixture = try makeFixture(skipCount: 2)
        let settings = OverplaySettings(playthroughThresholdPercentage: 90)
        let now = Date(timeIntervalSince1970: 1_000)
        let staleSession = TrackPlaySession(
            trackID: "library-1",
            sessionStartDate: now.addingTimeInterval(-400),
            lastObservedPlaybackTime: 170,
            lastObservedAt: now.addingTimeInterval(-300),
            durationSeconds: 180,
            hasEvaluated: false
        )

        let outcome = try PlaybackSessionEvaluationService.evaluateActiveSession(
            activeSession: staleSession,
            currentTrackID: "library-1",
            elapsedSeconds: 170,
            durationSeconds: 180,
            currentPlaylistItem: fixture.item,
            playlist: fixture.playlist,
            settings: settings,
            naturalCompletion: false,
            context: fixture.context,
            now: now
        )

        let history = try fixture.context.fetch(FetchDescriptor<HistoryEvent>())
        #expect(outcome?.session.hasEvaluated == true)
        #expect(fixture.item.playthroughCount == 1)
        #expect(fixture.item.skipCount == 2)
        #expect(history.first?.eventType == .playthrough)
    }

    @Test("fresh observation within the staleness threshold still counts a skip")
    func freshObservationWithinTheStalenessThresholdStillCountsASkip() throws {
        let fixture = try makeFixture(skipCount: 0)
        let settings = OverplaySettings(
            skipThresholdPercentage: 50,
            minimumSkipListeningSeconds: 0
        )
        let now = Date(timeIntervalSince1970: 1_000)
        let freshSession = TrackPlaySession(
            trackID: "library-1",
            sessionStartDate: now.addingTimeInterval(-60),
            lastObservedPlaybackTime: 54,
            lastObservedAt: now.addingTimeInterval(-PlaybackSessionEvaluationService.observationStalenessThresholdSeconds),
            durationSeconds: 180,
            hasEvaluated: false
        )

        let outcome = try PlaybackSessionEvaluationService.evaluateActiveSession(
            activeSession: freshSession,
            currentTrackID: "library-1",
            elapsedSeconds: 54,
            durationSeconds: 180,
            currentPlaylistItem: fixture.item,
            playlist: fixture.playlist,
            settings: settings,
            naturalCompletion: false,
            context: fixture.context,
            now: now
        )

        let history = try fixture.context.fetch(FetchDescriptor<HistoryEvent>())
        #expect(outcome?.session.hasEvaluated == true)
        #expect(fixture.item.skipCount == 1)
        #expect(history.first?.eventType == .skipCounted)
    }

    @Test("restored session observation dates make relaunch evaluation stale")
    func restoredSessionObservationDatesMakeRelaunchEvaluationStale() throws {
        let fixture = try makeFixture(skipCount: 0)
        let settings = OverplaySettings(
            skipThresholdPercentage: 50,
            minimumSkipListeningSeconds: 0
        )
        let persistedAt = Date(timeIntervalSince1970: 1_000)
        let restoredSession = PlaybackSessionSupport.makeSession(
            trackID: "library-1",
            elapsedSeconds: 54,
            durationSeconds: 180,
            sessionStartDate: persistedAt
        )

        let outcome = try PlaybackSessionEvaluationService.evaluateActiveSession(
            activeSession: restoredSession,
            currentTrackID: "library-1",
            elapsedSeconds: 54,
            durationSeconds: 180,
            currentPlaylistItem: fixture.item,
            playlist: fixture.playlist,
            settings: settings,
            naturalCompletion: false,
            context: fixture.context,
            now: persistedAt.addingTimeInterval(3_600)
        )

        let history = try fixture.context.fetch(FetchDescriptor<HistoryEvent>())
        #expect(outcome?.session.hasEvaluated == true)
        #expect(fixture.item.skipCount == 0)
        #expect(history.first?.eventType == .skipIgnored)
        #expect(history.first?.message == "Stale observation")
    }

    @Test("natural completion is inferred near the end of a track")
    func naturalCompletionIsInferredNearTheEndOfATrack() {
        #expect(PlaybackSessionEvaluationService.inferredNaturalCompletion(
            session: session(elapsedSeconds: 178, durationSeconds: 180)
        ))
        #expect(PlaybackSessionEvaluationService.inferredNaturalCompletion(
            session: session(elapsedSeconds: 177, durationSeconds: 180)
        ))
        #expect(!PlaybackSessionEvaluationService.inferredNaturalCompletion(
            session: session(elapsedSeconds: 176, durationSeconds: 180)
        ))
        #expect(!PlaybackSessionEvaluationService.inferredNaturalCompletion(
            session: session(elapsedSeconds: 90, durationSeconds: 180)
        ))
        #expect(!PlaybackSessionEvaluationService.inferredNaturalCompletion(
            session: TrackPlaySession(
                trackID: "library-1",
                sessionStartDate: .now,
                lastObservedPlaybackTime: 178,
                durationSeconds: nil,
                hasEvaluated: false
            )
        ))
    }

    @Test("track change observed near the end counts a playthrough below the threshold")
    func trackChangeObservedNearTheEndCountsAPlaythroughBelowTheThreshold() throws {
        let fixture = try makeFixture(skipCount: 1)
        let settings = OverplaySettings(playthroughThresholdPercentage: 99.9)

        let outcome = try PlaybackSessionEvaluationService.evaluateActiveSession(
            activeSession: nil,
            currentTrackID: "library-1",
            elapsedSeconds: 178,
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
        #expect(fixture.item.skipCount == 1)
        #expect(history.first?.eventType == .playthrough)
    }

    @Test("stale observation near the end still counts a playthrough")
    func staleObservationNearTheEndStillCountsAPlaythrough() throws {
        let fixture = try makeFixture(skipCount: 0)
        let settings = OverplaySettings(playthroughThresholdPercentage: 99.9)
        let now = Date(timeIntervalSince1970: 1_000)
        let staleSession = TrackPlaySession(
            trackID: "library-1",
            sessionStartDate: now.addingTimeInterval(-400),
            lastObservedPlaybackTime: 178,
            lastObservedAt: now.addingTimeInterval(-300),
            durationSeconds: 180,
            hasEvaluated: false
        )

        let outcome = try PlaybackSessionEvaluationService.evaluateActiveSession(
            activeSession: staleSession,
            currentTrackID: "library-1",
            elapsedSeconds: 178,
            durationSeconds: 180,
            currentPlaylistItem: fixture.item,
            playlist: fixture.playlist,
            settings: settings,
            naturalCompletion: false,
            context: fixture.context,
            now: now
        )

        let history = try fixture.context.fetch(FetchDescriptor<HistoryEvent>())
        #expect(outcome?.session.hasEvaluated == true)
        #expect(fixture.item.playthroughCount == 1)
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

    @Test("already evaluated session does not mutate newly current item")
    func alreadyEvaluatedSessionDoesNotMutateNewlyCurrentItem() throws {
        let fixture = try makeTwoTrackFixture()
        let settings = OverplaySettings(
            evictAfterSkips: 3,
            skipThresholdPercentage: 50,
            minimumSkipListeningSeconds: 0
        )
        let evaluatedPreviousSession = TrackPlaySession(
            trackID: "previous-library",
            sessionStartDate: .now,
            lastObservedPlaybackTime: 15,
            durationSeconds: 180,
            hasEvaluated: true
        )

        let outcome = try PlaybackSessionEvaluationService.evaluateActiveSession(
            activeSession: evaluatedPreviousSession,
            currentTrackID: "previous-library",
            elapsedSeconds: 15,
            durationSeconds: 180,
            currentPlaylistItem: fixture.nextItem,
            playlist: fixture.playlist,
            settings: settings,
            naturalCompletion: false,
            context: fixture.context,
            fallbackLocalTrackID: fixture.nextTrack.id.uuidString
        )

        #expect(outcome?.session.hasEvaluated == true)
        #expect(outcome?.item == nil)
        #expect(fixture.previousItem.skipCount == 0)
        #expect(fixture.nextItem.skipCount == 0)
    }

    @Test("manual skip evaluates outgoing fallback local track instead of current item")
    func manualSkipEvaluatesOutgoingFallbackLocalTrackInsteadOfCurrentItem() throws {
        let fixture = try makeTwoTrackFixture()
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
            currentPlaylistItem: fixture.nextItem,
            playlist: fixture.playlist,
            settings: settings,
            naturalCompletion: false,
            context: fixture.context,
            fallbackLocalTrackID: fixture.previousTrack.id.uuidString
        )

        #expect(outcome?.item?.id == fixture.previousItem.id)
        #expect(fixture.previousItem.skipCount == 1)
        #expect(fixture.nextItem.skipCount == 0)
    }

    @Test("skip transition does not use current item when session identity mismatches")
    func skipTransitionDoesNotUseCurrentItemWhenSessionIdentityMismatches() throws {
        let fixture = try makeTwoTrackFixture()
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
            currentPlaylistItem: fixture.nextItem,
            playlist: fixture.playlist,
            settings: settings,
            naturalCompletion: false,
            context: fixture.context
        )

        #expect(outcome?.item == nil)
        #expect(outcome?.shouldSyncPlaybackMetadata == false)
        #expect(fixture.previousItem.skipCount == 0)
        #expect(fixture.nextItem.skipCount == 0)
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

    @Test("skip transition prefers session local track id over music item id")
    func skipTransitionPrefersSessionLocalTrackIDOverMusicItemID() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(
            musicPlaylistID: "playlist-1",
            name: "Main",
            role: .oneTruePlaylist
        )
        let localTrack = TrackRecord(
            catalogID: "catalog-local",
            libraryID: "library-local",
            title: "Local Track",
            artistName: "Artist"
        )
        let musicIDTrack = TrackRecord(
            catalogID: "music-id-track",
            libraryID: "music-id-track",
            title: "Music ID Track",
            artistName: "Artist"
        )
        let localItem = PlaylistItemRecord(playlistID: playlist.id, trackID: localTrack.id, skipCount: 0)
        let musicIDItem = PlaylistItemRecord(playlistID: playlist.id, trackID: musicIDTrack.id, skipCount: 0)
        context.insert(playlist)
        context.insert(localTrack)
        context.insert(musicIDTrack)
        context.insert(localItem)
        context.insert(musicIDItem)
        let settings = OverplaySettings(
            evictAfterSkips: 3,
            skipThresholdPercentage: 50,
            minimumSkipListeningSeconds: 0
        )

        let outcome = try PlaybackSessionEvaluationService.evaluateActiveSession(
            activeSession: TrackPlaySession(
                trackID: "music-id-track",
                localTrackID: localTrack.id.uuidString,
                sessionStartDate: .now,
                lastObservedPlaybackTime: 15,
                durationSeconds: 180,
                hasEvaluated: false
            ),
            currentTrackID: "music-id-track",
            elapsedSeconds: 15,
            durationSeconds: 180,
            currentPlaylistItem: nil,
            playlist: playlist,
            settings: settings,
            naturalCompletion: false,
            context: context
        )

        #expect(outcome?.item?.id == localItem.id)
        #expect(localItem.skipCount == 1)
        #expect(musicIDItem.skipCount == 0)
    }

    @Test("protected track skips are counted")
    func protectedTrackSkipsAreCounted() throws {
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
        #expect(fixture.item.skipCount == 3)
        #expect(fixture.item.evictedAt == nil)
        #expect(history.first?.eventType == .skipCounted)
    }

    @Test("skip forward intent stays standard")
    func skipForwardIntentStaysStandard() throws {
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

        #expect(intent == .standard)
        #expect(intent.systemImage == "forward.fill")

        fixture.item.skipCount = 1
        #expect(PlaybackSessionEvaluationService.skipForwardIntent(
            session: session(elapsedSeconds: 15, durationSeconds: 100),
            item: fixture.item,
            playlist: fixture.playlist,
            settings: settings
        ) == .standard)

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

    private func makeTwoTrackFixture() throws -> (
        container: ModelContainer,
        context: ModelContext,
        playlist: PlaylistRecord,
        previousTrack: TrackRecord,
        previousItem: PlaylistItemRecord,
        nextTrack: TrackRecord,
        nextItem: PlaylistItemRecord
    ) {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(
            musicPlaylistID: "playlist-1",
            name: "Main",
            role: .oneTruePlaylist
        )
        let previousTrack = TrackRecord(
            catalogID: "previous-catalog",
            libraryID: "previous-library",
            title: "Previous Track",
            artistName: "Artist",
            durationSeconds: 180
        )
        let nextTrack = TrackRecord(
            catalogID: "next-catalog",
            libraryID: "next-library",
            title: "Next Track",
            artistName: "Artist",
            durationSeconds: 180
        )
        let previousItem = PlaylistItemRecord(playlistID: playlist.id, trackID: previousTrack.id, skipCount: 0)
        let nextItem = PlaylistItemRecord(playlistID: playlist.id, trackID: nextTrack.id, skipCount: 0)
        context.insert(playlist)
        context.insert(previousTrack)
        context.insert(nextTrack)
        context.insert(previousItem)
        context.insert(nextItem)
        return (container, context, playlist, previousTrack, previousItem, nextTrack, nextItem)
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
