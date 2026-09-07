import Foundation

/// What the Now Playing screen offers for the current track.
enum CarPlayNowPlayingAction: Equatable, Sendable {
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
        guard let playlistRole else { return [] }

        switch (playlistRole, isRetired) {
        case (.triage, false):
            // The whole loop of a triage playlist: hear it, then decide.
            return [.promote, .retire]
        case (.triage, true):
            // Retiring a triage track must not take promotion away with it.
            // Retirement there is local and reversible, and deciding to keep a
            // track you had set aside is the point of listening again.
            return [.promote, .restore]
        case (.oneTruePlaylist, false):
            return [.retire]
        case (.oneTruePlaylist, true):
            return [.restore]
        }
    }
}
