enum PlaylistRemoteMutationPolicy {
    static func shouldDeleteRemotelyAfterEviction(
        item: PlaylistItemRecord,
        playlist: PlaylistRecord
    ) -> Bool {
        item.evictedAt != nil
            && playlist.source == .appleMusic
            && playlist.role == .oneTruePlaylist
            && playlist.allowsRemoteWrites
    }
}
