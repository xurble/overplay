import Foundation

enum PlaylistPlaybackScope: String, CaseIterable, Identifiable, Sendable {
    case active
    case retired

    var id: Self { self }

    var title: String {
        switch self {
        case .active:
            "Active"
        case .retired:
            "Retired"
        }
    }

    func includes(_ item: PlaylistItemRecord) -> Bool {
        switch self {
        case .active:
            item.isPlayable
        case .retired:
            item.evictedAt != nil
        }
    }

    func playbackOrderPlaylistID(for musicPlaylistID: String) -> String {
        switch self {
        case .active:
            musicPlaylistID
        case .retired:
            "\(musicPlaylistID)#retired"
        }
    }
}
