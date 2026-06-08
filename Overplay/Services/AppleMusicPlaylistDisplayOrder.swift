import Foundation

enum AppleMusicPlaylistDisplayOrder {
    static func sorted(_ playlists: [AppleMusicPlaylist]) -> [AppleMusicPlaylist] {
        playlists.sorted { left, right in
            if left.isPreferredOverplayPlaylist != right.isPreferredOverplayPlaylist {
                return left.isPreferredOverplayPlaylist
            }

            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
    }
}
