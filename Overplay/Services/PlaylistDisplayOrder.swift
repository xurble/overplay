import Foundation

/// Browsing order is independent of the live playback queue and shuffle mode.
enum PlaylistDisplayOrder {
    static func recencyDate(for item: PlaylistItemRecord, scope: PlaylistPlaybackScope) -> Date {
        switch scope {
        case .active: item.locationChangedAt ?? item.createdAt
        case .retired: item.evictedAt ?? item.createdAt
        }
    }

    static func orderedItems(
        _ items: [PlaylistItemRecord],
        scope: PlaylistPlaybackScope = .active
    ) -> [PlaylistItemRecord] {
        items.sorted { left, right in
            let leftDate = recencyDate(for: left, scope: scope)
            let rightDate = recencyDate(for: right, scope: scope)
            if leftDate != rightDate { return leftDate > rightDate }
            return left.id.uuidString < right.id.uuidString
        }
    }
}
