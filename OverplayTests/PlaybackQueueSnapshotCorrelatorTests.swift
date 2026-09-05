import Foundation
import Testing
@testable import Overplay

@Suite("Correlating queue entries Overplay did not build")
struct PlaybackQueueSnapshotCorrelatorTests {
    private func member(_ localTrackID: String, _ musicItemID: String) -> PendingQueueCorrelation {
        PendingQueueCorrelation(
            playlistItemID: UUID(),
            localTrackID: localTrackID,
            queuedMusicItemID: musicItemID
        )
    }

    @Test("an appended batch takes the entry IDs the player reports")
    func appendedBatchTakesReportedEntryIDs() {
        let expected = [member("local-b", "music-b"), member("local-c", "music-c")]
        let realized = PlaybackQueueSnapshotCorrelator.realizedEntries(
            expected: expected,
            snapshots: [
                PlayerQueueEntrySnapshot(id: "entry-a", musicItemID: "music-a"),
                PlayerQueueEntrySnapshot(id: "entry-b", musicItemID: "music-b"),
                PlayerQueueEntrySnapshot(id: "entry-c", musicItemID: "music-c")
            ],
            reservedEntryIDs: ["entry-a"]
        )

        #expect(realized.map(\.queueEntryID) == ["entry-b", "entry-c"])
        #expect(realized.map(\.localTrackID) == ["local-b", "local-c"])
    }

    @Test("entries already correlated are never handed out twice")
    func reservedEntriesAreNotReused() {
        let realized = PlaybackQueueSnapshotCorrelator.realizedEntries(
            expected: [member("local-a", "music-a")],
            snapshots: [PlayerQueueEntrySnapshot(id: "entry-a", musicItemID: "music-a")],
            reservedEntryIDs: ["entry-a"]
        )

        #expect(realized.isEmpty)
    }

    @Test("a queue member the player never materialized is dropped, not guessed")
    func unmaterializedMembersAreDropped() {
        let realized = PlaybackQueueSnapshotCorrelator.realizedEntries(
            expected: [member("local-a", "music-a"), member("local-b", "music-b")],
            snapshots: [
                PlayerQueueEntrySnapshot(id: "entry-b", musicItemID: "music-b"),
                PlayerQueueEntrySnapshot(id: "entry-x", musicItemID: nil)
            ]
        )

        #expect(realized.map(\.localTrackID) == ["local-b"])
    }

    @Test("the mirror queue follows the player's order, not the local order")
    func mirrorQueueFollowsPlayerOrder() {
        let expected = [
            member("local-a", "music-a"),
            member("local-b", "music-b"),
            member("local-c", "music-c")
        ]
        let realized = PlaybackQueueSnapshotCorrelator.realizedEntriesInPlayerOrder(
            expected: expected,
            snapshots: [
                PlayerQueueEntrySnapshot(id: "entry-c", musicItemID: "music-c"),
                PlayerQueueEntrySnapshot(id: "entry-a", musicItemID: "music-a"),
                PlayerQueueEntrySnapshot(id: "entry-b", musicItemID: "music-b")
            ]
        )

        #expect(realized.map(\.localTrackID) == ["local-c", "local-a", "local-b"])
        #expect(realized.map(\.queueEntryID) == ["entry-c", "entry-a", "entry-b"])
    }

    @Test("a player queue holding tracks Overplay does not know is filtered out")
    func unknownPlayerEntriesAreFilteredOut() {
        let realized = PlaybackQueueSnapshotCorrelator.realizedEntriesInPlayerOrder(
            expected: [member("local-a", "music-a")],
            snapshots: [
                PlayerQueueEntrySnapshot(id: "entry-z", musicItemID: "music-z"),
                PlayerQueueEntrySnapshot(id: "entry-a", musicItemID: "music-a")
            ]
        )

        #expect(realized.map(\.localTrackID) == ["local-a"])
    }
}
