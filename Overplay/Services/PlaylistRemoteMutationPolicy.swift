enum PlaylistRemoteMutationPolicy {
    static func shouldDeleteRemotelyAfterEviction(
        item: PlaylistItemRecord,
        playlist: PlaylistRecord
    ) -> Bool {
        item.evictedAt != nil
            && playlist.role == .oneTruePlaylist
            && playlist.allowsRemoteWrites
    }
}
