struct DashboardSummary: Equatable, Sendable {
    var knownCount: Int
    var playableCount: Int
    var evictedCount: Int
    var atRiskCount: Int

    init(items: [PlaylistItemRecord], evictAfterSkips: Int) {
        _ = evictAfterSkips
        knownCount = items.count
        playableCount = items.filter(\.isPlayable).count
        evictedCount = items.filter { $0.evictedAt != nil }.count
        atRiskCount = items.filter { item in
            item.isPlayable && item.skipCount > 0
        }.count
    }

    init(activeRows: [ActivePlaylistSnapshot.Row], evictAfterSkips: Int) {
        _ = evictAfterSkips
        knownCount = activeRows.count
        playableCount = activeRows.filter(\.isPlayable).count
        evictedCount = activeRows.filter(\.isEvicted).count
        atRiskCount = activeRows.filter { row in
            row.isPlayable && row.skipCount > 0
        }.count
    }

    static let empty = DashboardSummary(
        knownCount: 0,
        playableCount: 0,
        evictedCount: 0,
        atRiskCount: 0
    )

    private init(
        knownCount: Int,
        playableCount: Int,
        evictedCount: Int,
        atRiskCount: Int
    ) {
        self.knownCount = knownCount
        self.playableCount = playableCount
        self.evictedCount = evictedCount
        self.atRiskCount = atRiskCount
    }
}
