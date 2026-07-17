import Foundation

enum PlaylistDisplayOrder {
    static func orderedItems(
        _ items: [PlaylistItemRecord],
        state: PlaybackOrderState,
        scope: PlaylistPlaybackScope = .active
    ) -> [PlaylistItemRecord] {
        let displayOrder = PlaybackOrderEngine.displayOrder(
            for: PlaybackQueueBuilder.playbackOrderTracks(items: items, scope: scope),
            storedOrder: state.orderedTrackIDs
        )
        let displayIndex = displayOrder.enumerated().firstValueDictionary(
            keyedBy: \.element,
            value: \.offset
        )

        return items.sorted { left, right in
            switch (displayIndex[left.trackID.uuidString], displayIndex[right.trackID.uuidString]) {
            case let (leftIndex?, rightIndex?):
                return leftIndex < rightIndex
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                if left.createdAt != right.createdAt {
                    return left.createdAt < right.createdAt
                }
                return left.id.uuidString < right.id.uuidString
            }
        }
    }
}
