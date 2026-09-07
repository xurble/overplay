import Foundation

/// What the Now Playing screen offers for the current track.
enum CarPlayNowPlayingAction: Equatable, Sendable {
    /// MusicKit's own shuffle, reflected and toggled.
    case shuffle
    /// MusicKit's own repeat-all mode, toggled on and off.
    case repeatMode
    /// Move this track into the One True Playlist. Triage only — that is what
    /// a triage playlist is for.
    case promote
    /// Retire it locally.
    case retire
    /// Undo a retirement.
    case restore
}

/// Chooses the Now Playing actions for CarPlay.
///
/// Pure so the choice is testable: CarPlay itself cannot be exercised in the
/// simulator, and this decision was previously spread across a presentation
/// factory, a cached signature and a role lookup, which is how promote came
/// to be missing from triage playback.
enum CarPlayNowPlayingActionPolicy {
    static func actions(playlistRole: PlaylistRole?, isRetired: Bool) -> [CarPlayNowPlayingAction] {
        // With nothing playing from a known playlist there is no track to act
        // on, but the playback modes still apply to whatever comes next.
        guard let playlistRole else { return [.shuffle, .repeatMode] }

        // Shuffle and repeat first: they belong to playback rather than to
        // this track, and a driver reaches for them without reading.
        switch (playlistRole, isRetired) {
        case (.triage, false):
            // The whole loop of a triage playlist: hear it, then decide.
            return [.shuffle, .repeatMode, .promote, .retire]
        case (.triage, true):
            // Retiring a triage track must not take promotion away with it.
            // Retirement there is local and reversible, and deciding to keep a
            // track you had set aside is the point of listening again.
            return [.shuffle, .repeatMode, .promote, .restore]
        case (.oneTruePlaylist, false):
            return [.shuffle, .repeatMode, .retire]
        case (.oneTruePlaylist, true):
            return [.shuffle, .repeatMode, .restore]
        }
    }
}
