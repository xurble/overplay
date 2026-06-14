import Foundation
import SwiftData

enum NowPlayingPresentationFactory {
    static func presentation(
        playbackController: PlaybackController,
        settings: OverplaySettings
    ) -> NowPlayingPresentation {
        NowPlayingPresentation(
            trackID: playbackController.currentTrack?.id,
            title: playbackController.currentTrack?.title,
            artistName: playbackController.currentTrack?.artistName,
            albumTitle: playbackController.currentTrack?.albumTitle,
            progress: playbackController.progress,
            elapsedSeconds: playbackController.elapsedSeconds,
            durationSeconds: playbackController.durationSeconds,
            isPlaying: playbackController.isPlaying,
            skipThresholdPercentage: settings.skipThresholdPercentage,
            minimumSkipListeningSeconds: settings.minimumSkipListeningSeconds,
            playthroughThresholdPercentage: settings.playthroughThresholdPercentage,
            playthroughResetsSkipCount: settings.playthroughResetsSkipCount,
            skipCount: playbackController.displayedSkipCount,
            evictAfterSkips: settings.evictAfterSkips,
            isEvicted: playbackController.displayedIsEvicted,
            isProtected: playbackController.displayedIsProtected
        )
    }

    static func presentation(
        playbackController: PlaybackController,
        settings: OverplaySettings,
        context: ModelContext
    ) -> NowPlayingPresentation {
        NowPlayingPresentation(
            trackID: playbackController.currentTrack?.id,
            title: playbackController.currentTrack?.title,
            artistName: playbackController.currentTrack?.artistName,
            albumTitle: playbackController.currentTrack?.albumTitle,
            progress: playbackController.progress,
            elapsedSeconds: playbackController.elapsedSeconds,
            durationSeconds: playbackController.durationSeconds,
            isPlaying: playbackController.isPlaying,
            skipThresholdPercentage: settings.skipThresholdPercentage,
            minimumSkipListeningSeconds: settings.minimumSkipListeningSeconds,
            playthroughThresholdPercentage: settings.playthroughThresholdPercentage,
            playthroughResetsSkipCount: settings.playthroughResetsSkipCount,
            skipCount: playbackController.displayedSkipCount(context: context),
            evictAfterSkips: settings.evictAfterSkips,
            isEvicted: playbackController.displayedIsEvicted(context: context),
            isProtected: playbackController.displayedIsProtected(context: context)
        )
    }

    static func trackHealthPresentation(
        playbackController: PlaybackController,
        settings: OverplaySettings
    ) -> TrackHealthPresentation {
        let status = TrackHealthStatus.resolve(
            skipCount: playbackController.displayedSkipCount,
            evictAfterSkips: settings.evictAfterSkips,
            isEvicted: playbackController.displayedIsEvicted,
            isProtected: playbackController.displayedIsProtected
        )
        return TrackHealthPresentation(
            status: status,
            isEvicted: playbackController.displayedIsEvicted,
            isProtected: playbackController.displayedIsProtected
        )
    }

    static func trackHealthPresentation(
        playbackController: PlaybackController,
        settings: OverplaySettings,
        context: ModelContext
    ) -> TrackHealthPresentation {
        let isEvicted = playbackController.displayedIsEvicted(context: context)
        let isProtected = playbackController.displayedIsProtected(context: context)
        let status = TrackHealthStatus.resolve(
            skipCount: playbackController.displayedSkipCount(context: context),
            evictAfterSkips: settings.evictAfterSkips,
            isEvicted: isEvicted,
            isProtected: isProtected
        )
        return TrackHealthPresentation(
            status: status,
            isEvicted: isEvicted,
            isProtected: isProtected
        )
    }

    static func playbackControlsPresentation(
        playbackController: PlaybackController
    ) -> PlaybackControlsPresentation {
        PlaybackControlsPresentation(
            isPlaying: playbackController.isPlaying,
            shuffleEnabled: playbackController.shuffleEnabled,
            repeatEnabled: playbackController.repeatEnabled
        )
    }

    static func playbackControlsPresentation(
        playbackController: PlaybackController,
        settings: OverplaySettings,
        context: ModelContext
    ) -> PlaybackControlsPresentation {
        PlaybackControlsPresentation(
            isPlaying: playbackController.isPlaying,
            shuffleEnabled: playbackController.shuffleEnabled,
            repeatEnabled: playbackController.repeatEnabled,
            skipForwardIntent: playbackController.skipForwardIntent(settings: settings, context: context)
        )
    }

    static func carPlayButtonSignature(
        playbackController: PlaybackController,
        settings: OverplaySettings,
        context: ModelContext
    ) -> CarPlayNowPlayingButtonSignature {
        let nowPlaying = presentation(playbackController: playbackController, settings: settings, context: context)
        let controls = playbackControlsPresentation(
            playbackController: playbackController,
            settings: settings,
            context: context
        )
        return CarPlayNowPlayingButtonSignature(
            trackID: nowPlaying.trackID,
            skipCount: nowPlaying.skipCount,
            isProtected: nowPlaying.isProtected,
            isEvicted: nowPlaying.isEvicted,
            shuffleEnabled: controls.shuffleEnabled,
            repeatEnabled: controls.repeatEnabled,
            skipForwardIntent: controls.skipForwardIntent
        )
    }
}
