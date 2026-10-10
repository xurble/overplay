import SwiftUI

enum AppShellDestination: Hashable {
    case dashboard
    case playlist(UUID)
    case retired
    /// A Recent Deep Dive, by its record ID.
    case recent(UUID)
    case search
    case history
    case settings

    init?(storageValue: String) {
        if storageValue.hasPrefix("playlist:") {
            let uuidString = String(storageValue.dropFirst("playlist:".count))
            guard let id = UUID(uuidString: uuidString) else { return nil }
            self = .playlist(id)
            return
        }
        if storageValue.hasPrefix("recent:") {
            guard let id = UUID(uuidString: String(storageValue.dropFirst("recent:".count))) else { return nil }
            self = .recent(id)
            return
        }

        switch storageValue {
        case Self.dashboard.storageValue:
            self = .dashboard
        case Self.search.storageValue:
            self = .search
        case Self.retired.storageValue:
            self = .retired
        case Self.history.storageValue:
            self = .history
        case Self.settings.storageValue:
            self = .settings
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
        case .retired:
            "retired"
        case let .recent(id):
            "recent:\(id.uuidString)"
        case .history:
            "history"
        case .settings:
            "settings"
        }
    }
}

/// The screen the person is on, kept by `PlatformShell` across a switch
/// between the compact and regular shells (folding or unfolding an iPhone
/// Duo, resizing a window), so the new shell opens the same screen. Screens
/// report themselves as they appear. Nothing observes it, so a report never
/// redraws anything.
final class ShellPlace {
    var destination: AppShellDestination?
}

extension EnvironmentValues {
    @Entry var shellPlace: ShellPlace?
}
