import Foundation
import Testing
@testable import Overplay

@Suite("Playback reconciliation policy")
struct PlaybackReconciliationPolicyTests {
    private let threshold = 90.0
    private let start = Date(timeIntervalSince1970: 1_000_000)

    // MARK: Point-proof

    @Test("a position at or past the threshold point-proves the current track")
    func aPositionAtOrPastTheThresholdPointProvesTheCurrentTrack() {
        let outcome = PlaybackReconciliationPolicy.reconcile(
            waypoint: nil,
            observation: observation(track: "b", position: 181, duration: 200),
            orderedTracks: [],
            playthroughThresholdPercentage: threshold
        )

        #expect(outcome.pointProvenLocalTrackID == "b")
    }

    @Test("a position below the threshold or an unknown duration proves nothing")
    func aPositionBelowTheThresholdOrAnUnknownDurationProvesNothing() {
        #expect(PlaybackReconciliationPolicy.reconcile(
            waypoint: nil,
            observation: observation(track: "b", position: 179, duration: 200),
            orderedTracks: [],
            playthroughThresholdPercentage: threshold
        ).pointProvenLocalTrackID == nil)
        #expect(PlaybackReconciliationPolicy.reconcile(
            waypoint: nil,
            observation: observation(track: "b", position: 500, duration: nil),
            orderedTracks: [],
            playthroughThresholdPercentage: threshold
        ).pointProvenLocalTrackID == nil)
    }

    @Test("a play instance already counted by an earlier wake is not counted twice")
    func aPlayInstanceAlreadyCountedByAnEarlierWakeIsNotCountedTwice() {
        let waypoint = PlaybackWaypoint(
            playlistID: "p",
            localTrackID: "b",
            positionSeconds: 182,
            durationSeconds: 200,
            recordedAt: start,
            countedLocalTrackID: "b"
        )

        #expect(PlaybackReconciliationPolicy.reconcile(
            waypoint: waypoint,
            observation: observation(track: "b", position: 195, duration: 200, at: start.addingTimeInterval(13)),
            orderedTracks: [],
            playthroughThresholdPercentage: threshold
        ).pointProvenLocalTrackID == nil)

        // Position reset below the waypoint means a fresh play of the track.
        #expect(PlaybackReconciliationPolicy.reconcile(
            waypoint: waypoint,
            observation: observation(track: "b", position: 185, duration: 200, at: start.addingTimeInterval(400)),
            orderedTracks: [],
            playthroughThresholdPercentage: threshold
        ).pointProvenLocalTrackID == nil)
        #expect(PlaybackReconciliationPolicy.reconcile(
            waypoint: PlaybackWaypoint(
                playlistID: "p",
                localTrackID: "b",
                positionSeconds: 190,
                durationSeconds: 200,
                recordedAt: start,
                countedLocalTrackID: "b"
            ),
            observation: observation(track: "b", position: 185, duration: 200, at: start.addingTimeInterval(400)),
            orderedTracks: [],
            playthroughThresholdPercentage: threshold
        ).pointProvenLocalTrackID == "b")
    }

    // MARK: Continuity-proof

    @Test("a balanced wall-clock span proves every traversed track")
    func aBalancedWallClockSpanProvesEveryTraversedTrack() {
        // Waypoint: track a at 100/180. Then a finishes (80s), b (200s) and
        // c (120s) play through, and the observation catches d at 30s.
        let outcome = PlaybackReconciliationPolicy.reconcile(
            waypoint: waypoint(track: "a", position: 100, duration: 180),
            observation: observation(track: "d", position: 30, duration: 240, at: start.addingTimeInterval(80 + 200 + 120 + 30 + 2)),
            orderedTracks: order(),
            playthroughThresholdPercentage: threshold
        )

        #expect(outcome.continuityProvenLocalTrackIDs == ["a", "b", "c"])
    }

    @Test("a pause or skip in the span breaks the equation and proves nothing")
    func aPauseOrSkipInTheSpanBreaksTheEquationAndProvesNothing() {
        // 60 seconds of pause somewhere in the span.
        #expect(PlaybackReconciliationPolicy.reconcile(
            waypoint: waypoint(track: "a", position: 100, duration: 180),
            observation: observation(track: "d", position: 30, duration: 240, at: start.addingTimeInterval(80 + 200 + 120 + 30 + 60)),
            orderedTracks: order(),
            playthroughThresholdPercentage: threshold
        ).continuityProvenLocalTrackIDs.isEmpty)

        // b skipped at its midpoint: wall time is 100s short.
        #expect(PlaybackReconciliationPolicy.reconcile(
            waypoint: waypoint(track: "a", position: 100, duration: 180),
            observation: observation(track: "d", position: 30, duration: 240, at: start.addingTimeInterval(80 + 100 + 120 + 30)),
            orderedTracks: order(),
            playthroughThresholdPercentage: threshold
        ).continuityProvenLocalTrackIDs.isEmpty)
    }

    @Test("tolerance scales with the number of boundaries crossed")
    func toleranceScalesWithTheNumberOfBoundariesCrossed() {
        // Three boundaries: base 5 + 3×3 = 14s of slack allowed.
        let exact = 80.0 + 200 + 120 + 30
        #expect(!PlaybackReconciliationPolicy.reconcile(
            waypoint: waypoint(track: "a", position: 100, duration: 180),
            observation: observation(track: "d", position: 30, duration: 240, at: start.addingTimeInterval(exact + 13)),
            orderedTracks: order(),
            playthroughThresholdPercentage: threshold
        ).continuityProvenLocalTrackIDs.isEmpty)
        #expect(PlaybackReconciliationPolicy.reconcile(
            waypoint: waypoint(track: "a", position: 100, duration: 180),
            observation: observation(track: "d", position: 30, duration: 240, at: start.addingTimeInterval(exact + 15)),
            orderedTracks: order(),
            playthroughThresholdPercentage: threshold
        ).continuityProvenLocalTrackIDs.isEmpty)
    }

    @Test("unknown durations, changed playlists, and backwards traversal prove nothing")
    func unknownDurationsChangedPlaylistsAndBackwardsTraversalProveNothing() {
        var missingDuration = order()
        missingDuration[1].durationSeconds = nil
        #expect(PlaybackReconciliationPolicy.reconcile(
            waypoint: waypoint(track: "a", position: 100, duration: 180),
            observation: observation(track: "d", position: 30, duration: 240, at: start.addingTimeInterval(430)),
            orderedTracks: missingDuration,
            playthroughThresholdPercentage: threshold
        ).continuityProvenLocalTrackIDs.isEmpty)

        #expect(PlaybackReconciliationPolicy.reconcile(
            waypoint: PlaybackWaypoint(
                playlistID: "other",
                localTrackID: "a",
                positionSeconds: 100,
                durationSeconds: 180,
                recordedAt: start
            ),
            observation: observation(track: "d", position: 30, duration: 240, at: start.addingTimeInterval(430)),
            orderedTracks: order(),
            playthroughThresholdPercentage: threshold
        ).continuityProvenLocalTrackIDs.isEmpty)

        // Observation track precedes the waypoint track (reshuffle/restart).
        #expect(PlaybackReconciliationPolicy.reconcile(
            waypoint: waypoint(track: "d", position: 100, duration: 240),
            observation: observation(track: "a", position: 30, duration: 180, at: start.addingTimeInterval(430)),
            orderedTracks: order(),
            playthroughThresholdPercentage: threshold
        ).continuityProvenLocalTrackIDs.isEmpty)
    }

    @Test("a waypoint track already point-proven is excluded from the continuity result")
    func aWaypointTrackAlreadyPointProvenIsExcludedFromTheContinuityResult() {
        var provenWaypoint = waypoint(track: "a", position: 170, duration: 180)
        provenWaypoint.countedLocalTrackID = "a"

        let outcome = PlaybackReconciliationPolicy.reconcile(
            waypoint: provenWaypoint,
            observation: observation(track: "c", position: 50, duration: 120, at: start.addingTimeInterval(10 + 200 + 50)),
            orderedTracks: order(),
            playthroughThresholdPercentage: threshold
        )

        #expect(outcome.continuityProvenLocalTrackIDs == ["b"])
    }

    // MARK: Apple Music library proof

    @Test("an advanced play count and last-played date prove the waypoint track")
    func anAdvancedPlayCountAndLastPlayedDateProveTheWaypointTrack() {
        var baseline = waypoint(track: "a", position: 100, duration: 180)
        baseline.musicLibrarySnapshot = musicLibrarySnapshot(
            playCount: 7,
            lastPlayedAt: start.addingTimeInterval(-500)
        )
        let observedAt = start.addingTimeInterval(90)

        let outcome = PlaybackReconciliationPolicy.reconcile(
            waypoint: baseline,
            // Deliberately break continuity: MusicKit is an independent
            // proof source for the outgoing waypoint track.
            observation: observation(track: "c", position: 20, duration: 120, at: observedAt),
            orderedTracks: order(),
            playthroughThresholdPercentage: threshold,
            musicLibrarySnapshots: [
                "a": musicLibrarySnapshot(
                    playCount: 8,
                    lastPlayedAt: start.addingTimeInterval(80)
                )
            ]
        )

        #expect(outcome.continuityProvenLocalTrackIDs.isEmpty)
        #expect(outcome.musicLibraryProvenLocalTrackIDs == ["a"])
    }

    @Test("missing stale or mismatched library metadata proves nothing")
    func missingStaleOrMismatchedLibraryMetadataProvesNothing() {
        var baseline = waypoint(track: "a", position: 100, duration: 180)
        baseline.musicLibrarySnapshot = musicLibrarySnapshot(
            playCount: 7,
            lastPlayedAt: start.addingTimeInterval(-500)
        )
        let observation = observation(
            track: "c",
            position: 20,
            duration: 120,
            at: start.addingTimeInterval(90)
        )

        func proof(_ latest: MusicLibraryPlaybackSnapshot?) -> String? {
            PlaybackReconciliationPolicy.reconcile(
                waypoint: baseline,
                observation: observation,
                orderedTracks: [],
                playthroughThresholdPercentage: threshold,
                musicLibrarySnapshots: latest.map { ["a": $0] } ?? [:]
            ).musicLibraryProvenLocalTrackIDs.first
        }

        #expect(proof(nil) == nil)
        #expect(proof(musicLibrarySnapshot(
            playCount: 7,
            lastPlayedAt: start.addingTimeInterval(80)
        )) == nil)
        #expect(proof(musicLibrarySnapshot(
            playCount: 8,
            lastPlayedAt: nil
        )) == nil)
        #expect(proof(musicLibrarySnapshot(
            musicItemID: "different-library-item",
            playCount: 8,
            lastPlayedAt: start.addingTimeInterval(80)
        )) == nil)
        #expect(proof(musicLibrarySnapshot(
            playCount: 8,
            lastPlayedAt: start.addingTimeInterval(-100)
        )) == nil)
    }

    @Test("library metadata cannot recount a waypoint play instance")
    func libraryMetadataCannotRecountAWaypointPlayInstance() {
        var baseline = waypoint(track: "a", position: 170, duration: 180)
        baseline.countedLocalTrackID = "a"
        baseline.musicLibrarySnapshot = musicLibrarySnapshot(
            playCount: 7,
            lastPlayedAt: start.addingTimeInterval(-500)
        )

        let outcome = PlaybackReconciliationPolicy.reconcile(
            waypoint: baseline,
            observation: observation(
                track: "b",
                position: 10,
                duration: 200,
                at: start.addingTimeInterval(30)
            ),
            orderedTracks: order(),
            playthroughThresholdPercentage: threshold,
            musicLibrarySnapshots: [
                "a": musicLibrarySnapshot(
                    playCount: 8,
                    lastPlayedAt: start.addingTimeInterval(20)
                )
            ]
        )

        #expect(outcome.musicLibraryProvenLocalTrackIDs.isEmpty)
    }

    @Test("a delayed MusicKit update can prove an older retained baseline")
    func aDelayedMusicKitUpdateCanProveAnOlderRetainedBaseline() {
        var latestWaypoint = waypoint(track: "b", position: 40, duration: 200)
        latestWaypoint.recordedAt = start.addingTimeInterval(120)
        latestWaypoint.musicLibrarySnapshot = musicLibrarySnapshot(
            musicItemID: "library-b",
            playCount: 3,
            lastPlayedAt: start.addingTimeInterval(-300)
        )
        latestWaypoint.pendingMusicLibraryBaselines = [
            MusicLibraryPlaybackBaseline(
                playlistID: "p",
                localTrackID: "a",
                recordedAt: start,
                snapshot: musicLibrarySnapshot(
                    musicItemID: "library-a",
                    playCount: 7,
                    lastPlayedAt: start.addingTimeInterval(-500)
                )
            )
        ]

        let outcome = PlaybackReconciliationPolicy.reconcile(
            waypoint: latestWaypoint,
            observation: observation(
                track: "c",
                position: 10,
                duration: 120,
                at: start.addingTimeInterval(240)
            ),
            orderedTracks: [],
            playthroughThresholdPercentage: threshold,
            musicLibrarySnapshots: [
                "a": musicLibrarySnapshot(
                    musicItemID: "library-a",
                    playCount: 8,
                    lastPlayedAt: start.addingTimeInterval(80)
                ),
                "b": musicLibrarySnapshot(
                    musicItemID: "library-b",
                    playCount: 3,
                    lastPlayedAt: start.addingTimeInterval(-300)
                )
            ]
        )

        #expect(outcome.musicLibraryProvenLocalTrackIDs == ["a"])
    }

    // MARK: Wake aiming

    @Test("before the threshold crossing the wake aims at the crossing plus margin")
    func beforeTheThresholdCrossingTheWakeAimsAtTheCrossingPlusMargin() throws {
        let target = try #require(PlaybackReconciliationPolicy.nextWakeTarget(
            positionSeconds: 20,
            durationSeconds: 200,
            nextDurationSeconds: 240,
            playthroughThresholdPercentage: threshold,
            now: start
        ))

        #expect(target == start.addingTimeInterval((180 - 20) + 5))
    }

    @Test("past the crossing the wake aims at the next track's crossing")
    func pastTheCrossingTheWakeAimsAtTheNextTracksCrossing() throws {
        let target = try #require(PlaybackReconciliationPolicy.nextWakeTarget(
            positionSeconds: 190,
            durationSeconds: 200,
            nextDurationSeconds: 240,
            playthroughThresholdPercentage: threshold,
            now: start
        ))

        #expect(target == start.addingTimeInterval((200 - 190) + 216 + 5))
    }

    @Test("short leads clamp to the minimum and unknown durations degrade gracefully")
    func shortLeadsClampToTheMinimumAndUnknownDurationsDegradeGracefully() throws {
        let clamped = try #require(PlaybackReconciliationPolicy.nextWakeTarget(
            positionSeconds: 175,
            durationSeconds: 200,
            nextDurationSeconds: nil,
            playthroughThresholdPercentage: threshold,
            now: start
        ))
        #expect(clamped == start.addingTimeInterval(60))

        #expect(PlaybackReconciliationPolicy.nextWakeTarget(
            positionSeconds: 20,
            durationSeconds: nil,
            nextDurationSeconds: 240,
            playthroughThresholdPercentage: threshold,
            now: start
        ) == nil)

        // Past the crossing with the next duration unknown: aim just past
        // the boundary.
        let boundary = try #require(PlaybackReconciliationPolicy.nextWakeTarget(
            positionSeconds: 100,
            durationSeconds: 200,
            nextDurationSeconds: nil,
            playthroughThresholdPercentage: threshold,
            now: start
        ))
        #expect(boundary == start.addingTimeInterval((180 - 100) + 5))
    }

    // MARK: Helpers

    private func order() -> [PlaybackReconciliationPolicy.OrderedTrack] {
        [
            .init(localTrackID: "a", durationSeconds: 180),
            .init(localTrackID: "b", durationSeconds: 200),
            .init(localTrackID: "c", durationSeconds: 120),
            .init(localTrackID: "d", durationSeconds: 240)
        ]
    }

    private func waypoint(track: String, position: Double, duration: Double?) -> PlaybackWaypoint {
        PlaybackWaypoint(
            playlistID: "p",
            localTrackID: track,
            positionSeconds: position,
            durationSeconds: duration,
            recordedAt: start
        )
    }

    private func observation(
        track: String,
        position: Double,
        duration: Double?,
        at date: Date? = nil
    ) -> PlaybackReconciliationPolicy.Observation {
        PlaybackReconciliationPolicy.Observation(
            playlistID: "p",
            localTrackID: track,
            positionSeconds: position,
            durationSeconds: duration,
            observedAt: date ?? start
        )
    }

    private func musicLibrarySnapshot(
        musicItemID: String = "library-item",
        playCount: Int?,
        lastPlayedAt: Date?
    ) -> MusicLibraryPlaybackSnapshot {
        MusicLibraryPlaybackSnapshot(
            musicItemID: musicItemID,
            playCount: playCount,
            lastPlayedDate: lastPlayedAt
        )
    }
}
