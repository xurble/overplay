import Foundation

/// What the CarPlay root "Overplay" row does when it is tapped.
enum CarPlayOverplayIntent: Equatable {
    /// The One True Playlist is already the live queue and playing.
    case showPlayer
    /// The One True Playlist is the live queue but paused.
    case resumeAndShowPlayer
    /// Something else, or nothing, is playing.
    case shuffleAndPlay
}

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
    static func overplayIntent(
        oneTruePlaylistMusicID: String?,
        currentPlaylistID: String?,
        hasCurrentTrack: Bool,
        isPlaying: Bool
    ) -> CarPlayOverplayIntent {
        guard let oneTruePlaylistMusicID,
              currentPlaylistID == oneTruePlaylistMusicID,
              hasCurrentTrack else {
            return .shuffleAndPlay
        }

        // A retired context still counts as the One True Playlist being live,
        // so the row never reshuffles what the user started on the phone.
        return isPlaying ? .showPlayer : .resumeAndShowPlayer
    }

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
