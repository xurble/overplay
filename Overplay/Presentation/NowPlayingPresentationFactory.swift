import Foundation
import SwiftData

enum NowPlayingPresentationFactory {
    static func presentation(
        playbackController: PlaybackController
    ) -> NowPlayingPresentation {
        let displayTrack = playbackController.nowPlayingDisplayTrack
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
            skipCount: playbackController.displayedSkipCount,
            playthroughCount: playbackController.displayedPlaythroughCount,
            applePlayCount: playbackController.displayedApplePlayCount,
            isEvicted: playbackController.displayedIsEvicted,
            isTracked: playbackController.isCurrentTracked
        )
    }

    /// The song and its counts, read fresh from `context` in one fetch. A
    /// view re-evaluates when the controller publishes a change or when the
    /// item read here changes; never because the playback position moved.
    static func presentation(
        playbackController: PlaybackController,
        context: ModelContext
    ) -> NowPlayingPresentation {
        let displayTrack = playbackController.nowPlayingDisplayTrack
        let item = playbackController.displayedPlaylistItem(context: context)
        let displayedSkipCount = item?.skipCount ?? playbackController.displayedSkipCount
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
            skipCount: displayedSkipCount,
            playthroughCount: item?.playthroughCount ?? playbackController.displayedPlaythroughCount,
            applePlayCount: item?.applePlayCount ?? playbackController.displayedApplePlayCount,
            isEvicted: item.map { $0.evictedAt != nil } ?? playbackController.displayedIsEvicted,
            isTracked: playbackController.isCurrentTracked
        )
    }

    /// Reads the playback position: for the small views that draw progress.
    static func progressPresentation(
        playbackController: PlaybackController,
        settings: OverplaySettings
    ) -> NowPlayingProgressPresentation {
        let displayTrack = playbackController.nowPlayingDisplayTrack
        let displayDurationSeconds = durationSeconds(
            for: displayTrack,
            playbackController: playbackController
        )
        return NowPlayingProgressPresentation(
            trackID: displayTrack?.id,
            progress: progress(
                elapsedSeconds: playbackController.elapsedSeconds,
                durationSeconds: displayDurationSeconds
            ),
            elapsedSeconds: playbackController.elapsedSeconds,
            durationSeconds: displayDurationSeconds,
            isPlaying: playbackController.isPlaying,
            skipThresholdPercentage: settings.skipThresholdPercentage,
            minimumSkipListeningSeconds: settings.minimumSkipListeningSeconds,
            playthroughThresholdPercentage: settings.playthroughThresholdPercentage
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
            // During a failure the primary control is Retry (`PLAY-014`).
            isPlaying: playbackController.isPlaying && playbackController.playbackFailure == nil,
            isShuffling: playbackController.shuffleEnabled,
            isRepeatingAll: playbackController.repeatAllEnabled
        )
    }

    static func carPlayButtonSignature(
        playbackController: PlaybackController,
        context: ModelContext
    ) -> CarPlayNowPlayingButtonSignature {
        return CarPlayNowPlayingButtonSignature(
            hasCurrentTrack: playbackController.currentTrack != nil,
            playlistRole: playbackController.currentPlaylistRole(context: context),
            isEvicted: playbackController.displayedIsEvicted(context: context),
            canAddToOverplay: playbackController.canAddCurrentToOverplay,
            canAddToOneTruePlaylist: playbackController.canAddCurrentToOneTruePlaylist(context: context)
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
