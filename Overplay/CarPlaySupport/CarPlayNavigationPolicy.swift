import Foundation

/// What a CarPlay track row does when it is tapped.
enum CarPlayTrackIntent: Equatable {
    /// Already the live track — never restart it.
    case showPlayer
    /// The playlist is already the live queue, so jump inside it and keep the
    /// order after the tapped track.
    case skipInLiveQueue
    /// A different playlist, or no queue at all: build one from this track.
    case startPlaylist
}

/// CarPlay navigation rules, kept free of CarPlay types so both the root menu
/// and the track lists can be tested without an interface controller.
enum CarPlayNavigationPolicy {
    static func trackIntent(
        isCurrentTrack: Bool,
        isInLiveQueue: Bool
    ) -> CarPlayTrackIntent {
        if isCurrentTrack {
            return .showPlayer
        }

        return isInLiveQueue ? .skipInLiveQueue : .startPlaylist
    }
}
