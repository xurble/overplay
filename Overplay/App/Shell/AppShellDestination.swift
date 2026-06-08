import Foundation

enum AppShellDestination: Hashable {
    case dashboard
    case playlist(UUID)
    case search
    case history
    case settings
    case linkedPlaylists

    init?(storageValue: String) {
        if storageValue.hasPrefix("playlist:") {
            let uuidString = String(storageValue.dropFirst("playlist:".count))
            guard let id = UUID(uuidString: uuidString) else { return nil }
            self = .playlist(id)
            return
        }

        switch storageValue {
        case Self.dashboard.storageValue:
            self = .dashboard
        case Self.search.storageValue:
            self = .search
        case Self.history.storageValue:
            self = .history
        case Self.settings.storageValue:
            self = .settings
        case Self.linkedPlaylists.storageValue:
            self = .linkedPlaylists
        default:
            return nil
        }
    }

    var storageValue: String {
        switch self {
        case .dashboard:
            "dashboard"
        case let .playlist(id):
            "playlist:\(id.uuidString)"
        case .search:
            "search"
        case .history:
            "history"
        case .settings:
            "settings"
        case .linkedPlaylists:
            "linkedPlaylists"
        }
    }
}
