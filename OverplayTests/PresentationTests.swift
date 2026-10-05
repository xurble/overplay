import Foundation
import SwiftData
import Testing
@testable import Overplay

@Suite("Playlist summary presentation")
struct PlaylistSummaryPresentationTests {
    @Test("role titles icons write labels and priorities match playlist roles")
    func roleTitlesIconsWriteLabelsAndPriorities() {
        let oneTrue = PlaylistSummaryPresentation(
            id: UUID(),
            title: "Overplay",
            role: .oneTruePlaylist,
            source: .appleMusic,
            writePolicy: .managed,
            activeTrackCount: 12,
            playableTrackCount: 11,
            lastSyncedAt: nil,
            isCurrentPlaybackPlaylist: false
        )
        let triageBucket = PlaylistSummaryPresentation(
            id: UUID(),
            title: "Inbox",
            role: .triageBucket,
            source: .appleMusic,
            writePolicy: .incomingOnly,
            activeTrackCount: 1,
            playableTrackCount: 1,
            lastSyncedAt: nil,
            isCurrentPlaybackPlaylist: true
        )
        let triageSource = PlaylistSummaryPresentation(
            id: UUID(),
            title: "Weekly Finds",
            role: .triageSource,
            source: .appleMusic,
            writePolicy: .managed,
            activeTrackCount: 30,
            playableTrackCount: 30,
            lastSyncedAt: nil,
            isCurrentPlaybackPlaylist: false
        )

        #expect(oneTrue.roleTitle == "One True Playlist")
        #expect(oneTrue.shortRoleTitle == "Main")
        #expect(oneTrue.iconIntent.systemImage == "arrow.up.circle")
        #expect(oneTrue.displayPriority == 0)
        #expect(oneTrue.writePolicyTitle == "Managed")

        #expect(triageBucket.roleTitle == "Triage")
        #expect(triageBucket.shortRoleTitle == "Triage")
        #expect(triageBucket.iconIntent.systemImage == "play.fill")
        #expect(triageBucket.displayPriority == 1)
        #expect(triageBucket.writePolicyTitle == "Incoming only")
        #expect(triageBucket.sourceTitle == "Apple Music")

        // Contributing playlists sort below the bucket they feed and read as
        // sources, so the sources screen never looks like another playlist.
        #expect(triageSource.roleTitle == "Triage Source")
        #expect(triageSource.shortRoleTitle == "Source")
        #expect(triageSource.iconIntent.systemImage == "music.note.list")
        #expect(triageSource.displayPriority == 2)
    }

    @Test("display ordering puts main playlists first then sorts names case-insensitively")
    func displayOrdering() {
        let summaries = [
            summary(title: "zeta", role: .triageSource),
            summary(title: "beta", role: .oneTruePlaylist),
            summary(title: "Alpha", role: .triageSource)
        ]

        let orderedTitles = summaries.sorted(by: PlaylistSummaryPresentation.areInDisplayOrder).map(\.title)

        #expect(orderedTitles == ["beta", "Alpha", "zeta"])
    }

    private func summary(title: String, role: PlaylistRole) -> PlaylistSummaryPresentation {
        PlaylistSummaryPresentation(
            id: UUID(),
            title: title,
            role: role,
            source: .appleMusic,
            writePolicy: .managed,
            activeTrackCount: 0,
            playableTrackCount: 0,
            lastSyncedAt: nil,
            isCurrentPlaybackPlaylist: false
        )
    }
}

@Suite("Track summary presentation")
struct TrackSummaryPresentationTests {
    @Test("subtitle includes non-empty album title")
    func subtitleIncludesAlbumTitle() {
        let presentation = TrackSummaryPresentation(
            id: UUID(),
            title: "Go",
            artistName: "Artist",
            albumTitle: "Album",
            skipCount: 0
        )

        #expect(presentation.subtitle == "Artist - Album")
    }

    @Test("subtitle falls back to artist for missing or empty album")
    func subtitleFallsBackToArtist() {
        #expect(track(albumTitle: nil).subtitle == "Artist")
        #expect(track(albumTitle: "").subtitle == "Artist")
    }

    @Test("skip labels are singular plural and hidden at zero")
    func skipLabels() {
        #expect(track(skipCount: 0).skipCountLabel == nil)
        #expect(track(skipCount: 1).skipCountLabel == "1 skip")
        #expect(track(skipCount: 2).skipCountLabel == "2 skips")
        #expect(track(skipCount: 2).playSkipMetricLabel == "0/— plays · 2 skips")
        #expect(track(skipCount: 2).detailText == "Artist - 0/— plays · 2 skips")
    }

    private func track(albumTitle: String? = nil, skipCount: Int = 0) -> TrackSummaryPresentation {
        TrackSummaryPresentation(
            id: UUID(),
            title: "Go",
            artistName: "Artist",
            albumTitle: albumTitle,
            skipCount: skipCount
        )
    }
}

@Suite("Track state badge presentation")
struct TrackStateBadgePresentationTests {
}

@Suite("Now playing presentation")
struct NowPlayingPresentationTests {
    @Test("progress text formats finite invalid and nil durations")
    func progressTextFormatting() {
        #expect(NowPlayingPresentation.formatTime(0) == "0:00")
        #expect(NowPlayingPresentation.formatTime(65.9) == "1:05")
        #expect(NowPlayingPresentation.formatTime(.infinity) == "0:00")

        let presentation = NowPlayingPresentation(
            title: nil,
            artistName: nil,
            albumTitle: nil,
            progress: 0.5,
            elapsedSeconds: 125,
            durationSeconds: nil,
            skipCount: 2,
            playthroughCount: 1,
            isEvicted: false
        )

        #expect(presentation.title == "Nothing playing")
        #expect(presentation.artistName == "Choose Play Overplay from the dashboard.")
        #expect(presentation.elapsedText == "2:05")
        #expect(presentation.durationText == "0:00")
        #expect(presentation.skipCountText == "2 skips")
        #expect(presentation.playSkipMetricText == "1/— plays · 2 skips")
    }

    @Test("progress phase follows skip and playthrough thresholds")
    func progressPhaseFollowsSkipAndPlaythroughThresholds() {
        #expect(NowPlayingPresentation.progressPhase(
            elapsedSeconds: 4,
            durationSeconds: 100,
            skipThresholdPercentage: 50,
            minimumSkipListeningSeconds: 10,
            playthroughThresholdPercentage: 90
        ) == .normal)

        #expect(NowPlayingPresentation.progressPhase(
            elapsedSeconds: 12,
            durationSeconds: 100,
            skipThresholdPercentage: 50,
            minimumSkipListeningSeconds: 10,
            playthroughThresholdPercentage: 90
        ) == .danger)

        #expect(NowPlayingPresentation.progressPhase(
            elapsedSeconds: 55,
            durationSeconds: 100,
            skipThresholdPercentage: 50,
            minimumSkipListeningSeconds: 10,
            playthroughThresholdPercentage: 90
        ) == .normal)

        #expect(NowPlayingPresentation.progressPhase(
            elapsedSeconds: 92,
            durationSeconds: 100,
            skipThresholdPercentage: 50,
            minimumSkipListeningSeconds: 10,
            playthroughThresholdPercentage: 90
        ) == .safe)

        #expect(NowPlayingPresentation.progressPhase(
            elapsedSeconds: 92,
            durationSeconds: 100,
            skipThresholdPercentage: 50,
            minimumSkipListeningSeconds: 10,
            playthroughThresholdPercentage: 90
        ) == .safe)
    }
}

@Suite("Now playing presentation factory", .serialized)
@MainActor
struct NowPlayingPresentationFactoryTests {
    @Test("factory handles missing current track")
    func factoryMissingTrack() throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        let presentation = NowPlayingPresentationFactory.presentation(
            playbackController: fixture.controller, settings: fixture.settings
        )
        #expect(presentation.trackID == nil)
        #expect(presentation.title == "Nothing playing")
    }

    @Test("factory includes playback timing state")
    func factoryIncludesPlaybackTimingState() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[0],
                                              settings: fixture.settings, context: fixture.context)
        await fixture.listen(seconds: 30)
        let presentation = NowPlayingPresentationFactory.presentation(
            playbackController: fixture.controller, settings: fixture.settings
        )
        #expect(presentation.elapsedSeconds == 30)
        #expect(presentation.durationSeconds == 180)
        #expect(presentation.isPlaying)
    }

    @Test("factory shows the player-reported track even when unattributed")
    func factoryShowsPlayerReportedTrack() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[0],
                                              settings: fixture.settings, context: fixture.context)
        fixture.player.replaceCurrentItem(with: PlayerItemSnapshot(
            id: "musickit-current", identifiers: ["musickit-current"], title: "MusicKit Current",
            artistName: "Actual Artist", albumTitle: "Actual Album", artworkURLTemplate: nil, durationSeconds: 100))
        fixture.player.reissueEntryIDs()
        await fixture.player.notify()
        let presentation = NowPlayingPresentationFactory.presentation(
            playbackController: fixture.controller, settings: fixture.settings
        )
        #expect(presentation.trackID == "musickit-current")
        #expect(presentation.title == "MusicKit Current")
        #expect(presentation.albumTitle == "Actual Album")
        #expect(presentation.durationSeconds == 100)
    }

    @Test("factory never shows the previous track while the next one hydrates")
    func factoryAvoidsPreviousTrackWhileHydrating() async throws {
        let player = FakePlaybackPlayer()
        player.hydratesOnSubmit = false
        let fixture = try PlaybackFixture(player: player)
        defer { fixture.cleanUp() }
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[0],
                                              settings: fixture.settings, context: fixture.context)
        await fixture.player.externallyAdvance()
        let presentation = NowPlayingPresentationFactory.presentation(
            playbackController: fixture.controller, settings: fixture.settings
        )
        #expect(presentation.title != "Song 0")
    }

    @Test("context factory uses the live playlist item skip count")
    func contextFactoryUsesLivePlaylistItemSkipCount() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[0],
                                              settings: fixture.settings, context: fixture.context)
        try ListenLedger.record(.skip, trackID: fixture.tracks[0].id, sessionID: "earlier", source: .playback, in: fixture.context)
        try ListenLedger.refreshCounts(forTrackIDs: [fixture.tracks[0].id], in: fixture.context)

        let presentation = NowPlayingPresentationFactory.presentation(
            playbackController: fixture.controller, settings: fixture.settings, context: fixture.context
        )
        #expect(presentation.skipCount == 1)
        #expect(presentation.skipCountText == "1 skip")
        #expect(presentation.playSkipMetricText == "0/— plays · 1 skip")
    }
}
