enum PlaylistRemoteMutationPolicy {
    static func shouldDeleteRemotelyAfterEviction(
        item: PlaylistItemRecord,
        playlist: PlaylistRecord
    ) -> Bool {
        item.evictedAt != nil && shouldDeleteRemotelyAfterLeaving(playlist)
    }

    /// A song moved out of the One True Playlist, retired or to the Inbox.
    static func shouldDeleteRemotelyAfterLeaving(_ playlist: PlaylistRecord) -> Bool {
        playlist.source == .appleMusic
            && playlist.role == .oneTruePlaylist
            && playlist.allowsRemoteWrites
    }
}
