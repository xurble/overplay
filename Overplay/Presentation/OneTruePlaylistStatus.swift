import Foundation

/// What Settings and the dashboard say about the One True Playlist: made,
/// waiting for an iPhone (`SETUP-002`), or not made yet.
struct OneTruePlaylistStatus: Equatable {
    var title: String
    var note: String
    /// A Mac asked for it and only an iPhone or iPad can make it.
    var waitsForAnotherDevice = false

    static func make(selectedPlaylistID: String?, selectedPlaylistName: String?, isRequested: Bool,
                     canCreatePlaylists: Bool) -> OneTruePlaylistStatus {
        if selectedPlaylistID != nil {
            return OneTruePlaylistStatus(
                title: selectedPlaylistName ?? "One True Playlist",
                note: "Overplay made this playlist and keeps it up to date: songs join it when you promote them and leave it when you retire them."
            )
        }
        if isRequested && !canCreatePlaylists {
            return OneTruePlaylistStatus(
                title: "Waiting for your iPhone",
                note: "A Mac can’t create Apple Music playlists. Your iPhone or iPad makes it the next time Overplay opens there.",
                waitsForAnotherDevice: true
            )
        }
        if isRequested {
            return OneTruePlaylistStatus(
                title: "Not made yet",
                note: "Your Mac asked for it. Overplay asks to make it when it starts, or open Make Your One True Playlist on the dashboard to make it now."
            )
        }
        return OneTruePlaylistStatus(
            title: "Not made yet",
            note: canCreatePlaylists
                ? "Make it from the dashboard: Overplay creates it in Apple Music, empty or as a copy of a playlist."
                : "Make it from the dashboard, and your iPhone or iPad creates it in Apple Music."
        )
    }

    static func make(_ settings: OverplaySettings,
                     canCreatePlaylists: Bool = !ProcessInfo.processInfo.isMacCatalystApp) -> OneTruePlaylistStatus {
        make(selectedPlaylistID: settings.selectedPlaylistID, selectedPlaylistName: settings.selectedPlaylistName,
             isRequested: settings.pendingOneTruePlaylistRequestedAt != nil, canCreatePlaylists: canCreatePlaylists)
    }
}
