struct DashboardSummary: Equatable, Sendable {
    var knownCount: Int
    var playableCount: Int
    var evictedCount: Int
    var skippedCount: Int

    init(items: [PlaylistItemRecord]) {
        knownCount = items.count
        playableCount = items.filter(\.isPlayable).count
        evictedCount = items.filter { $0.evictedAt != nil }.count
        skippedCount = items.filter { item in
            item.isPlayable && item.skipCount > 0
        }.count
    }

    init(activeRows: [ActivePlaylistSnapshot.Row]) {
        knownCount = activeRows.count
        playableCount = activeRows.filter(\.isPlayable).count
        evictedCount = activeRows.filter(\.isEvicted).count
        skippedCount = activeRows.filter { row in
            row.isPlayable && row.skipCount > 0
        }.count
    }

    static let empty = DashboardSummary(
        knownCount: 0,
        playableCount: 0,
        evictedCount: 0,
        skippedCount: 0
    )

    private init(
        knownCount: Int,
        playableCount: Int,
        evictedCount: Int,
        skippedCount: Int
    ) {
        self.knownCount = knownCount
        self.playableCount = playableCount
        self.evictedCount = evictedCount
        self.skippedCount = skippedCount
    }
}
