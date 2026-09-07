import Foundation
import SwiftData

enum NowPlayingPresentationFactory {
    static func presentation(
        playbackController: PlaybackController,
        settings: OverplaySettings
    ) -> NowPlayingPresentation {
        let displayTrack = playbackController.nowPlayingDisplayTrack
        let displayDurationSeconds = durationSeconds(
            for: displayTrack,
            playbackController: playbackController
        )
        if let item = playbackController.currentPlaylistItem,
           item.skipCount != playbackController.currentTrack?.skipCount {
            TrackMetadataDiagnostics.log(
                "now playing presentation without context has stale snapshot item=\(TrackMetadataDiagnostics.describe(item)) snapshot=\(TrackMetadataDiagnostics.describe(playbackController.currentTrack))"
            )
        }
        return NowPlayingPresentation(
            trackID: displayTrack?.id,
            title: displayTrack?.title,
            artistName: displayTrack?.artistName,
            albumTitle: displayTrack?.albumTitle,
            progress: progress(
                elapsedSeconds: playbackController.elapsedSeconds,
                durationSeconds: displayDurationSeconds
            ),
            elapsedSeconds: playbackController.elapsedSeconds,
            durationSeconds: displayDurationSeconds,
            isPlaying: playbackController.isPlaying,
            skipThresholdPercentage: settings.skipThresholdPercentage,
            minimumSkipListeningSeconds: settings.minimumSkipListeningSeconds,
            playthroughThresholdPercentage: settings.playthroughThresholdPercentage,
            skipCount: playbackController.displayedSkipCount,
            playthroughCount: playbackController.displayedPlaythroughCount,
            isEvicted: playbackController.displayedIsEvicted
        )
    }

    static func presentation(
        playbackController: PlaybackController,
        settings: OverplaySettings,
        context: ModelContext
    ) -> NowPlayingPresentation {
        let displayTrack = playbackController.nowPlayingDisplayTrack
        let displayDurationSeconds = durationSeconds(
            for: displayTrack,
            playbackController: playbackController
        )
        let displayedSkipCount = playbackController.displayedSkipCount(context: context)
        if displayedSkipCount == 0,
           let snapshotSkipCount = playbackController.currentTrack?.skipCount,
           snapshotSkipCount > 0 {
            TrackMetadataDiagnostics.log(
                "now playing context presentation resolved zero skips while snapshot has \(snapshotSkipCount) track=\(TrackMetadataDiagnostics.describe(playbackController.currentTrack)) item=\(TrackMetadataDiagnostics.describe(playbackController.currentPlaylistItem))"
            )
        }
        return NowPlayingPresentation(
            trackID: displayTrack?.id,
            title: displayTrack?.title,
            artistName: displayTrack?.artistName,
            albumTitle: displayTrack?.albumTitle,
            progress: progress(
                elapsedSeconds: playbackController.elapsedSeconds,
                durationSeconds: displayDurationSeconds
            ),
            elapsedSeconds: playbackController.elapsedSeconds,
            durationSeconds: displayDurationSeconds,
            isPlaying: playbackController.isPlaying,
            skipThresholdPercentage: settings.skipThresholdPercentage,
            minimumSkipListeningSeconds: settings.minimumSkipListeningSeconds,
            playthroughThresholdPercentage: settings.playthroughThresholdPercentage,
            skipCount: displayedSkipCount,
            playthroughCount: playbackController.displayedPlaythroughCount(context: context),
            isEvicted: playbackController.displayedIsEvicted(context: context)
        )
    }

    static func trackStateBadgePresentation(
        playbackController: PlaybackController,
        settings: OverplaySettings
    ) -> TrackStateBadgePresentation {
        _ = settings
        return TrackStateBadgePresentation(
            isEvicted: playbackController.displayedIsEvicted
        )
    }

    static func trackStateBadgePresentation(
        playbackController: PlaybackController,
        settings: OverplaySettings,
        context: ModelContext
    ) -> TrackStateBadgePresentation {
        _ = settings
        let isEvicted = playbackController.displayedIsEvicted(context: context)
        return TrackStateBadgePresentation(
            isEvicted: isEvicted
        )
    }

    static func playbackControlsPresentation(
        playbackController: PlaybackController
    ) -> PlaybackControlsPresentation {
        PlaybackControlsPresentation(
            isPlaying: playbackController.isPlaying,
            isShuffling: playbackController.shuffleEnabled,
            isRepeatingAll: playbackController.repeatAllEnabled
        )
    }

    static func carPlayButtonSignature(
        playbackController: PlaybackController,
        settings: OverplaySettings,
        context: ModelContext
    ) -> CarPlayNowPlayingButtonSignature {
        let nowPlaying = presentation(playbackController: playbackController, settings: settings, context: context)
        return CarPlayNowPlayingButtonSignature(
            trackID: nowPlaying.trackID,
            playlistRole: playbackController.currentPlaylistRole(context: context),
            skipCount: nowPlaying.skipCount,
            isEvicted: nowPlaying.isEvicted,
            isShuffling: playbackController.shuffleEnabled,
            repeatMode: playbackController.repeatMode
        )
    }

    private static func durationSeconds(
        for displayTrack: CurrentPlaybackTrack?,
        playbackController: PlaybackController
    ) -> Double? {
        if let durationSeconds = displayTrack?.durationSeconds {
            return durationSeconds
        }

        guard displayTrack?.id == playbackController.currentTrack?.id || displayTrack == nil else {
            return nil
        }

        return playbackController.durationSeconds
    }

    private static func progress(elapsedSeconds: Double, durationSeconds: Double?) -> Double {
        guard let durationSeconds, durationSeconds > 0 else { return 0 }
        return min(elapsedSeconds / durationSeconds, 1)
    }
}
