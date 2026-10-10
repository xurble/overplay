import Foundation

/// What Overplay is playing from: a playlist and the scope within it.
///
/// Triage and Retired are two scopes of the one bucket record
/// (`PLAYLIST-007`), so a playlist ID alone cannot say which of them is
/// playing. Compare whole contexts when asking "is this what's playing?".
struct PlaylistPlaybackContext: Hashable, Sendable {
    var musicPlaylistID: String
    var scope: PlaylistPlaybackScope
}

extension PlaylistRecord {
    func playbackContext(_ scope: PlaylistPlaybackScope = .active) -> PlaylistPlaybackContext {
        PlaylistPlaybackContext(musicPlaylistID: musicPlaylistID, scope: scope)
    }
}
