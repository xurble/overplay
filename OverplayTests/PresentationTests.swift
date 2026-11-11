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

        #expect(triageBucket.roleTitle == "Find the next big thing")
        #expect(triageBucket.shortRoleTitle == "Inbox")
        #expect(triageBucket.iconIntent.systemImage == "arrow.right.circle.fill")
        #expect(triageBucket.displayPriority == 1)
        #expect(triageBucket.writePolicyTitle == "Incoming only")
        #expect(triageBucket.sourceTitle == "Apple Music")

        // Contributing playlists sort below the bucket they feed and read as
        // sources, so the sources screen never looks like another playlist.
        #expect(triageSource.roleTitle == "Inbox Source")
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
        #expect(track(skipCount: 2).playSkipMetricLabel == "0 plays · 2 skips")
        #expect(track(skipCount: 2).detailText == "Artist - 0 plays · 2 skips")
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

        let progress = NowPlayingProgressPresentation(progress: 0.5, elapsedSeconds: 125, durationSeconds: nil)
        let presentation = NowPlayingPresentation(
            title: nil,
            artistName: nil,
            albumTitle: nil,
            skipCount: 2,
            playthroughCount: 1,
            isEvicted: false
        )

        #expect(presentation.title == "Nothing playing")
        #expect(presentation.artistName == "Choose Play Overplay from the dashboard.")
        #expect(progress.elapsedText == "2:05")
        #expect(progress.durationText == "0:00")
        #expect(presentation.skipCountText == "2 skips")
        #expect(presentation.playSkipMetricText == "1 play · 2 skips")
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
            playbackController: fixture.controller
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
        let presentation = NowPlayingPresentationFactory.progressPresentation(
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
            playbackController: fixture.controller
        )
        #expect(presentation.trackID == "musickit-current")
        #expect(presentation.title == "MusicKit Current")
        #expect(presentation.albumTitle == "Actual Album")
        #expect(NowPlayingPresentationFactory.progressPresentation(
            playbackController: fixture.controller, settings: fixture.settings
        ).durationSeconds == 100)
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
            playbackController: fixture.controller
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
            playbackController: fixture.controller, context: fixture.context
        )
        #expect(presentation.skipCount == 1)
        #expect(presentation.skipCountText == "1 skip")
        #expect(presentation.playSkipMetricText == "0 plays · 1 skip")
    }

    // MARK: - What re-evaluates a view (PF-4)

    /// Whether `change` invalidates what `read` observed, as it would the
    /// SwiftUI body that made the same reads.
    private func invalidates(_ read: () -> Void, after change: () async throws -> Void) async rethrows -> Bool {
        nonisolated final class Flag: @unchecked Sendable { var fired = false }
        let flag = Flag()
        withObservationTracking(read) { flag.fired = true }
        try await change()
        return flag.fired
    }

    private func read(_ fixture: PlaybackFixture) -> () -> Void {
        { _ = NowPlayingPresentationFactory.presentation(playbackController: fixture.controller, context: fixture.context) }
    }

    private func playFirst(_ fixture: PlaybackFixture) async {
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[0],
                                              settings: fixture.settings, context: fixture.context)
    }

    @Test("the song and its counts do not depend on the playback position")
    func presentationIgnoresThePlaybackPosition() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await playFirst(fixture)

        let invalidated = await invalidates(read(fixture)) { await fixture.listen(seconds: 3) }

        #expect(fixture.controller.elapsedSeconds == 3)
        #expect(!invalidated)
    }

    @Test("the progress presentation follows the playback position")
    func progressFollowsThePlaybackPosition() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await playFirst(fixture)
        let controller = fixture.controller, settings = fixture.settings

        let invalidated = await invalidates({
            _ = NowPlayingPresentationFactory.progressPresentation(playbackController: controller, settings: settings)
        }) { await fixture.listen(seconds: 90) }

        #expect(invalidated)
        let progress = NowPlayingPresentationFactory.progressPresentation(playbackController: controller, settings: settings)
        #expect(progress.elapsedText == "1:30")
        #expect(progress.durationText == "3:00")
        #expect(progress.progress == 0.5)
        #expect(progress.progressPhase == .normal)
        #expect(progress.isPlaying)
        #expect(progress.trackID == fixture.controller.currentTrack?.id)
    }

    @Test("a count written straight to the row re-evaluates the presentation")
    func aLedgerWriteInvalidatesThePresentation() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await playFirst(fixture)
        let trackID = fixture.tracks[0].id

        let invalidated = try await invalidates(read(fixture)) {
            try ListenLedger.record(.skip, trackID: trackID, sessionID: "earlier", source: .playback, in: fixture.context)
            try ListenLedger.refreshCounts(forTrackIDs: [trackID], in: fixture.context)
        }

        #expect(invalidated)
        #expect(NowPlayingPresentationFactory.presentation(playbackController: fixture.controller, context: fixture.context).skipCount == 1)
    }

    @Test("retiring the song re-evaluates the presentation and shows it retired")
    func retiringInvalidatesThePresentation() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await playFirst(fixture)
        let item = try fixture.item(0)
        #expect(!NowPlayingPresentationFactory.presentation(playbackController: fixture.controller, context: fixture.context).isEvicted)

        let invalidated = try await invalidates(read(fixture)) {
            try fixture.controller.retireTrack(item, playlist: fixture.playlist, message: "Retired", context: fixture.context)
        }

        #expect(invalidated)
        #expect(fixture.controller.currentTrack?.title == "Song 0")
        #expect(NowPlayingPresentationFactory.presentation(playbackController: fixture.controller, context: fixture.context).isEvicted)
    }

    @Test("promoting the song re-evaluates the presentation and it keeps its counts")
    func promotingInvalidatesThePresentation() async throws {
        let fixture = try PlaybackFixture(role: .triageBucket)
        defer { fixture.cleanUp() }
        let otp = PlaylistRecord(musicPlaylistID: "playlist-otp", name: "One True", role: .oneTruePlaylist)
        fixture.context.insert(otp)
        try fixture.context.save()
        var mutations = PlaylistMutationService(addRemotely: { _, _, _ in })
        mutations.remoteMembership.cloudEntries = { _ in [] }
        fixture.controller.playlistMutations = mutations
        fixture.controller.remoteMembership.cloudEntries = { _ in [] }
        fixture.controller.remoteMembership.canEditPlaylists = { false }
        await playFirst(fixture)
        let trackID = fixture.tracks[0].id
        try ListenLedger.record(.skip, trackID: trackID, sessionID: "earlier", source: .playback, in: fixture.context)
        try ListenLedger.refreshCounts(forTrackIDs: [trackID], in: fixture.context)

        let invalidated = await invalidates(read(fixture)) {
            await fixture.controller.promoteCurrent(settings: fixture.settings, context: fixture.context)
        }

        #expect(invalidated)
        #expect(try fixture.item(0).playlistID == otp.id)
        #expect(fixture.controller.currentTrack?.title == "Song 0")
        #expect(NowPlayingPresentationFactory.presentation(playbackController: fixture.controller, context: fixture.context).skipCount == 1)
    }

    @Test("a skip re-evaluates the presentation, and the song shows the skip when it plays again")
    func aSkipInvalidatesThePresentation() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await playFirst(fixture)
        await fixture.listen(seconds: 20)

        let invalidated = await invalidates(read(fixture)) {
            await fixture.player.externallyAdvance()
            await fixture.player.notify()
        }

        #expect(invalidated)
        #expect(try fixture.item(0).skipCount == 1)
        await playFirst(fixture)
        #expect(NowPlayingPresentationFactory.presentation(playbackController: fixture.controller, context: fixture.context).skipCount == 1)
    }

    @Test("a write from another context reaches the presentation once the controller publishes it")
    func anotherContextsWriteReachesThePresentation() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await playFirst(fixture)
        let trackID = fixture.tracks[0].id
        let other = ModelContext(fixture.container)

        let invalidated = try await invalidates(read(fixture)) {
            try ListenLedger.record(.skip, trackID: trackID, sessionID: "elsewhere", source: .playback, in: other)
            try ListenLedger.refreshCounts(forTrackIDs: [trackID], in: other)
            try other.save()
            fixture.controller.refreshPlayCountMetadata(context: other)
        }

        #expect(invalidated)
        #expect(NowPlayingPresentationFactory.presentation(playbackController: fixture.controller, context: fixture.context).skipCount == 1)
    }

    @Test("the counts come from a fresh read, not the controller's retained row")
    func aReplacedRowIsReadFresh() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await playFirst(fixture)
        fixture.context.delete(try fixture.item(0))
        fixture.context.insert(PlaylistItemRecord(playlistID: fixture.playlist.id, trackID: fixture.tracks[0].id, skipCount: 2))

        let presentation = NowPlayingPresentationFactory.presentation(playbackController: fixture.controller, context: fixture.context)

        #expect(presentation.skipCount == 2)
    }

    @Test("an unattributed song shows the player's track without Overplay counts")
    func anUnattributedSongHasNoCounts() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await playFirst(fixture)
        fixture.player.replaceCurrentItem(with: PlayerItemSnapshot(
            id: "musickit-current", identifiers: ["musickit-current"], title: "MusicKit Current",
            artistName: "Actual Artist", albumTitle: nil, artworkURLTemplate: nil, durationSeconds: 100))
        fixture.player.reissueEntryIDs()
        await fixture.player.notify()

        let presentation = NowPlayingPresentationFactory.presentation(playbackController: fixture.controller, context: fixture.context)

        #expect(presentation.title == "MusicKit Current")
        #expect(presentation.skipCount == 0)
        #expect(!presentation.isTracked)
    }
}
