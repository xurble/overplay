import Foundation
import Testing
@testable import Overplay

@MainActor
@Suite("Dashboard summary")
struct DashboardSummaryTests {
    @Test("counts known playable evicted and at risk playlist items")
    func countsKnownPlayableEvictedAndAtRiskPlaylistItems() {
        let playlistID = UUID()
        let activeTrackID = UUID()
        let atRiskTrackID = UUID()
        let evictedTrackID = UUID()
        let removedTrackID = UUID()

        let summary = DashboardSummary(
            items: [
                PlaylistItemRecord(playlistID: playlistID, trackID: activeTrackID, skipCount: 0),
                PlaylistItemRecord(playlistID: playlistID, trackID: atRiskTrackID, skipCount: 2),
                PlaylistItemRecord(
                    playlistID: playlistID,
                    trackID: evictedTrackID,
                    skipCount: 3,
                    evictedAt: .now,
                    evictionReason: .skipCount,
                    evictionSource: .playbackRule
                ),
                PlaylistItemRecord(playlistID: playlistID, trackID: removedTrackID, skipCount: 2, removedFromRemoteAt: .now)
            ],
            evictAfterSkips: 3
        )

        #expect(summary.knownCount == 4)
        #expect(summary.playableCount == 2)
        #expect(summary.evictedCount == 1)
        #expect(summary.atRiskCount == 1)
    }

    @Test("empty summary has zero counts")
    func emptySummaryHasZeroCounts() {
        #expect(DashboardSummary.empty.knownCount == 0)
        #expect(DashboardSummary.empty.playableCount == 0)
        #expect(DashboardSummary.empty.evictedCount == 0)
        #expect(DashboardSummary.empty.atRiskCount == 0)
    }
}
