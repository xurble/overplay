import SwiftData

/// Values that require replacing CarPlay's Now Playing button array.
/// Shuffle and repeat state are published separately through the remote
/// command center and do not change the array's composition.
struct CarPlayNowPlayingButtonSignature: Equatable {
    var hasCurrentTrack: Bool
    var playlistRole: PlaylistRole? = nil
    var isEvicted: Bool

    func resolvingLayout(previous: Self?, samePlaylist: Bool) -> Self {
        guard samePlaylist, playlistRole == nil, let previous else { return self }
        var layout = self
        layout.playlistRole = previous.playlistRole
        layout.isEvicted = previous.isEvicted
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
