import Foundation
import Testing
@testable import Overplay

@MainActor
@Suite("Dashboard summary")
struct DashboardSummaryTests {
    @Test("counts known playable retired and skipped playlist items")
    func countsKnownPlayableRetiredAndSkippedPlaylistItems() {
        let playlistID = UUID()
        let activeTrackID = UUID()
        let skippedTrackID = UUID()
        let evictedTrackID = UUID()

        let summary = DashboardSummary(
            items: [
                PlaylistItemRecord(playlistID: playlistID, trackID: activeTrackID, skipCount: 0),
                PlaylistItemRecord(playlistID: playlistID, trackID: skippedTrackID, skipCount: 2),
                PlaylistItemRecord(
                    playlistID: playlistID,
                    trackID: evictedTrackID,
                    skipCount: 3,
                    evictedAt: .now,
                    evictionReason: .skipCount,
                    evictionSource: .playbackRule
                )
            ]
        )

        #expect(summary.knownCount == 3)
        #expect(summary.playableCount == 2)
        #expect(summary.evictedCount == 1)
        #expect(summary.skippedCount == 1)
    }

    @Test("empty summary has zero counts")
    func emptySummaryHasZeroCounts() {
        #expect(DashboardSummary.empty.knownCount == 0)
        #expect(DashboardSummary.empty.playableCount == 0)
        #expect(DashboardSummary.empty.evictedCount == 0)
        #expect(DashboardSummary.empty.skippedCount == 0)
    }
}
