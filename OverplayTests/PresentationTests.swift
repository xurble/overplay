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
        let triage = PlaylistSummaryPresentation(
            id: UUID(),
            title: "Inbox",
            role: .triage,
            source: .appleMusic,
            writePolicy: .incomingOnly,
            activeTrackCount: 1,
            playableTrackCount: 1,
            lastSyncedAt: nil,
            isCurrentPlaybackPlaylist: true
        )

        #expect(oneTrue.roleTitle == "One True Playlist")
        #expect(oneTrue.shortRoleTitle == "Main")
        #expect(oneTrue.iconIntent.systemImage == "star.fill")
        #expect(oneTrue.displayPriority == 0)
        #expect(oneTrue.writePolicyTitle == "Managed")

        #expect(triage.roleTitle == "Triage Playlist")
        #expect(triage.shortRoleTitle == "Triage")
        #expect(triage.iconIntent.systemImage == "play.fill")
        #expect(triage.displayPriority == 1)
        #expect(triage.writePolicyTitle == "Incoming only")
        #expect(triage.sourceTitle == "Apple Music")
    }

    @Test("display ordering puts main playlists first then sorts names case-insensitively")
    func displayOrdering() {
        let summaries = [
            summary(title: "zeta", role: .triage),
            summary(title: "beta", role: .oneTruePlaylist),
            summary(title: "Alpha", role: .triage)
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
        #expect(track(skipCount: 2).playSkipMetricLabel == "0 plays / 2 skips")
        #expect(track(skipCount: 2).detailText == "Artist - 0 plays / 2 skips")
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
    @Test("labels and icons prioritize protected and retired state")
    func labelsAndIcons() {
        let protected = TrackStateBadgePresentation(isEvicted: true, isProtected: true)
        let evicted = TrackStateBadgePresentation(isEvicted: true, isProtected: false)
        let active = TrackStateBadgePresentation(isEvicted: false, isProtected: false)

        #expect(protected.title == "Protected")
        #expect(protected.systemImage == "shield.fill")
        #expect(evicted.title == "Retired")
        #expect(evicted.systemImage == "trash.fill")
        #expect(active.title == "Active")
        #expect(active.systemImage == "music.note")
    }
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
            isEvicted: false,
            isProtected: false
        )

        #expect(presentation.title == "Nothing playing")
        #expect(presentation.artistName == "Choose Play Overplay from the dashboard.")
        #expect(presentation.elapsedText == "2:05")
        #expect(presentation.durationText == "0:00")
        #expect(presentation.skipCountText == "2 skips")
        #expect(presentation.playSkipMetricText == "1 play / 2 skips")
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

@Suite("Now playing presentation factory")
struct NowPlayingPresentationFactoryTests {
    @Test("factory resolves protected retired and active badge states")
    @MainActor
    func factoryBadgeStates() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let settings = try SettingsRepository.settings(in: context)
        let controller = PlaybackController()
        controller.currentTrack = CurrentPlaybackTrack(id: "music-1", title: "Track", artistName: "Artist")
        let track = TrackRecord(title: "Track", artistName: "Artist")
        context.insert(track)
        let playlistID = UUID()

        controller.currentPlaylistItem = PlaylistItemRecord(playlistID: playlistID, trackID: track.id, skipCount: 0)
        let active = NowPlayingPresentationFactory.trackStateBadgePresentation(
            playbackController: controller,
            settings: settings
        )
        #expect(active.title == "Active")

        controller.currentPlaylistItem = PlaylistItemRecord(
            playlistID: playlistID,
            trackID: track.id,
            skipCount: 0,
            protected: true
        )
        let protected = NowPlayingPresentationFactory.trackStateBadgePresentation(
            playbackController: controller,
            settings: settings
        )
        #expect(protected.title == "Protected")

        controller.currentPlaylistItem = PlaylistItemRecord(
            playlistID: playlistID,
            trackID: track.id,
            skipCount: 2,
            evictedAt: .now
        )
        let retired = NowPlayingPresentationFactory.trackStateBadgePresentation(
            playbackController: controller,
            settings: settings
        )
        #expect(retired.title == "Retired")
    }

    @Test("factory handles missing current track")
    @MainActor
    func factoryMissingTrack() {
        let controller = PlaybackController()
        let settings = OverplaySettings()

        let presentation = NowPlayingPresentationFactory.presentation(
            playbackController: controller,
            settings: settings
        )
        #expect(presentation.trackID == nil)
        #expect(presentation.title == "Nothing playing")
    }

    @Test("factory includes playback timing state")
    @MainActor
    func factoryIncludesPlaybackTimingState() {
        let controller = PlaybackController()
        controller.elapsedSeconds = 30
        controller.durationSeconds = 120
        controller.isPlaying = true
        let settings = OverplaySettings()

        let presentation = NowPlayingPresentationFactory.presentation(
            playbackController: controller,
            settings: settings
        )

        #expect(presentation.elapsedSeconds == 30)
        #expect(presentation.durationSeconds == 120)
        #expect(presentation.isPlaying)
    }

    @Test("factory prefers MusicKit now-playing track for visible metadata")
    @MainActor
    func factoryPrefersMusicKitNowPlayingTrackForVisibleMetadata() {
        let controller = PlaybackController()
        controller.currentTrack = CurrentPlaybackTrack(
            id: "local-guess",
            title: "Local Guess",
            artistName: "Guessed Artist",
            durationSeconds: 300,
            skipCount: 2
        )
        controller.musicKitNowPlayingTrack = CurrentPlaybackTrack(
            id: "musickit-current",
            title: "MusicKit Current",
            artistName: "Actual Artist",
            albumTitle: "Actual Album",
            durationSeconds: 100
        )
        controller.elapsedSeconds = 25
        let settings = OverplaySettings()

        let presentation = NowPlayingPresentationFactory.presentation(
            playbackController: controller,
            settings: settings
        )

        #expect(presentation.trackID == "musickit-current")
        #expect(presentation.title == "MusicKit Current")
        #expect(presentation.artistName == "Actual Artist")
        #expect(presentation.albumTitle == "Actual Album")
        #expect(presentation.durationSeconds == 100)
        #expect(presentation.progress == 0.25)
        #expect(presentation.skipCount == 2)
    }

    @Test("factory avoids local queue guess while MusicKit item is pending")
    @MainActor
    func factoryAvoidsLocalQueueGuessWhileMusicKitItemIsPending() {
        let controller = PlaybackController()
        controller.currentTrack = CurrentPlaybackTrack(
            id: "local-guess",
            title: "Local Guess",
            artistName: "Guessed Artist",
            durationSeconds: 300
        )
        controller.musicKitNowPlayingTrack = CurrentPlaybackTrack(
            id: "previous-musickit",
            title: "Previous MusicKit",
            artistName: "Actual Artist",
            durationSeconds: 100
        )
        controller.isMusicKitNowPlayingTrackPending = true
        let settings = OverplaySettings()

        let presentation = NowPlayingPresentationFactory.presentation(
            playbackController: controller,
            settings: settings
        )

        #expect(presentation.trackID == "previous-musickit")
        #expect(presentation.title == "Previous MusicKit")
        #expect(presentation.durationSeconds == 100)
    }

    @Test("context factory uses live playlist item skip count")
    @MainActor
    func contextFactoryUsesLivePlaylistItemSkipCount() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let settings = try SettingsRepository.settings(in: context)
        let controller = PlaybackController()
        let playlist = PlaylistRecord(
            musicPlaylistID: "playlist-1",
            name: "Main",
            role: .oneTruePlaylist
        )
        let track = TrackRecord(
            catalogID: "music-1",
            libraryID: "music-1",
            title: "Track",
            artistName: "Artist"
        )
        let item = PlaylistItemRecord(playlistID: playlist.id, trackID: track.id, skipCount: 1)
        context.insert(playlist)
        context.insert(track)
        context.insert(item)
        controller.currentPlaylistID = playlist.musicPlaylistID
        controller.currentTrack = CurrentPlaybackTrack(
            id: "music-1",
            title: "Track",
            artistName: "Artist",
            skipCount: 0
        )

        let presentation = NowPlayingPresentationFactory.presentation(
            playbackController: controller,
            settings: settings,
            context: context
        )

        #expect(presentation.skipCount == 1)
        #expect(presentation.skipCountText == "1 skip")
        #expect(presentation.playSkipMetricText == "0 plays / 1 skip")
    }

    @Test("context factory refreshes stale cached playlist item before presenting skip count")
    @MainActor
    func contextFactoryRefreshesStaleCachedPlaylistItemBeforePresentingSkipCount() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let settings = try SettingsRepository.settings(in: context)
        let controller = PlaybackController()
        let playlist = PlaylistRecord(
            musicPlaylistID: "playlist-1",
            name: "Main",
            role: .oneTruePlaylist
        )
        let track = TrackRecord(
            catalogID: "music-1",
            libraryID: "music-1",
            title: "Track",
            artistName: "Artist"
        )
        let liveItem = PlaylistItemRecord(playlistID: playlist.id, trackID: track.id, skipCount: 1)
        let staleCachedItem = PlaylistItemRecord(
            id: liveItem.id,
            playlistID: playlist.id,
            trackID: track.id,
            skipCount: 0
        )
        context.insert(playlist)
        context.insert(track)
        context.insert(liveItem)
        controller.currentPlaylistID = playlist.musicPlaylistID
        controller.currentPlaylistItem = staleCachedItem
        controller.currentTrack = CurrentPlaybackTrack(
            id: "music-1",
            title: "Track",
            artistName: "Artist",
            skipCount: 0
        )

        let presentation = NowPlayingPresentationFactory.presentation(
            playbackController: controller,
            settings: settings,
            context: context
        )

        #expect(presentation.skipCount == 1)
        #expect(presentation.skipCountText == "1 skip")
        #expect(presentation.playSkipMetricText == "0 plays / 1 skip")
    }
}
