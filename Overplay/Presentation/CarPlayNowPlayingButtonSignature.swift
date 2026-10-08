import SwiftData

/// Values that require replacing CarPlay's Now Playing button array.
/// Shuffle and repeat state are published separately through the remote
/// command center and do not change the array's composition.
struct CarPlayNowPlayingButtonSignature: Equatable {
    var hasCurrentTrack: Bool
    var playlistRole: PlaylistRole? = nil
    var isEvicted: Bool
    /// The current song is from an album or artist and Overplay does not
    /// track it (`PLAY-018`).
    var canAddToOverplay = false
    var canAddToOneTruePlaylist = false

    func resolvingLayout(previous: Self?, samePlaylist: Bool) -> Self {
        guard samePlaylist, playlistRole == nil, !canAddToOverplay, let previous else { return self }
        var layout = self
        layout.playlistRole = previous.playlistRole
        layout.isEvicted = previous.isEvicted
        layout.canAddToOverplay = previous.canAddToOverplay
        layout.canAddToOneTruePlaylist = previous.canAddToOneTruePlaylist
        return layout
    }

    static func make(
        playbackController: PlaybackController,
        context: ModelContext
    ) -> Self {
        NowPlayingPresentationFactory.carPlayButtonSignature(
            playbackController: playbackController,
            context: context
        )
    }
}
