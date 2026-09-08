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

    @Test("an entry reported under the other ID domain is still correlated")
    func entryReportedUnderTheOtherIDDomainIsStillCorrelated() {
        // Apple Music owns the entries a queue insert creates and can report a
        // library ID for a track queued by catalog ID. Matching on the queued
        // ID alone would silently drop it.
        let expected = [
            PendingQueueCorrelation(
                playlistItemID: UUID(),
                localTrackID: "local-a",
                queuedMusicItemID: "1234567890",
                matchableMusicItemIDs: ["1234567890", "i.abc123"]
            )
        ]
        let realized = PlaybackQueueSnapshotCorrelator.realizedEntries(
            expected: expected,
            snapshots: [PlayerQueueEntrySnapshot(id: "entry-a", musicItemID: "i.abc123")]
        )

        #expect(realized.map(\.localTrackID) == ["local-a"])
        // The reported ID is what later lookups will see, so record that one.
        #expect(realized.map(\.queuedMusicItemID) == ["i.abc123"])
    }

    @Test("a re-materialized queue is correlated in the order the player holds it")
    func rematerializedQueueIsCorrelatedInPlayerOrder() {
        // A mode change reorders the queue and hands back entry IDs Overplay
        // never minted. The player's order is now the playback order, so the
        // rebuilt correlation has to follow the snapshots, not the members.
        let members = [
            member("local-a", "music-a"),
            member("local-b", "music-b"),
            member("local-c", "music-c")
        ]
        let realized = PlaybackQueueSnapshotCorrelator.realizedEntriesInPlayerOrder(
            snapshots: [
                PlayerQueueEntrySnapshot(id: "reissued-c", musicItemID: "music-c"),
                PlayerQueueEntrySnapshot(id: "reissued-a", musicItemID: "music-a"),
                PlayerQueueEntrySnapshot(id: "reissued-b", musicItemID: "music-b")
            ],
            members: members
        )

        #expect(realized.map(\.queueEntryID) == ["reissued-c", "reissued-a", "reissued-b"])
        #expect(realized.map(\.localTrackID) == ["local-c", "local-a", "local-b"])
        #expect(realized.map(\.playlistItemID) == [
            members[2].playlistItemID,
            members[0].playlistItemID,
            members[1].playlistItemID
        ])
    }

    @Test("a live entry belonging to no known member is left uncorrelated")
    func liveEntryOutsideTheKnownMembersIsLeftUncorrelated() {
        let realized = PlaybackQueueSnapshotCorrelator.realizedEntriesInPlayerOrder(
            snapshots: [
                PlayerQueueEntrySnapshot(id: "reissued-a", musicItemID: "music-a"),
                PlayerQueueEntrySnapshot(id: "foreign", musicItemID: "music-elsewhere"),
                PlayerQueueEntrySnapshot(id: "unhydrated", musicItemID: nil)
            ],
            members: [member("local-a", "music-a")]
        )

        #expect(realized.map(\.queueEntryID) == ["reissued-a"])
    }

    @Test("one member cannot correlate two live entries")
    func oneMemberCannotCorrelateTwoLiveEntries() {
        let realized = PlaybackQueueSnapshotCorrelator.realizedEntriesInPlayerOrder(
            snapshots: [
                PlayerQueueEntrySnapshot(id: "first", musicItemID: "music-a"),
                PlayerQueueEntrySnapshot(id: "second", musicItemID: "music-a")
            ],
            members: [member("local-a", "music-a")]
        )

        #expect(realized.map(\.queueEntryID) == ["first"])
    }

    @Test("a member with no alternate IDs still matches only its queued ID")
    func memberWithoutAlternateIDsMatchesOnlyItsQueuedID() {
        let realized = PlaybackQueueSnapshotCorrelator.realizedEntries(
            expected: [member("local-a", "music-a")],
            snapshots: [PlayerQueueEntrySnapshot(id: "entry-z", musicItemID: "music-z")]
        )

        #expect(realized.isEmpty)
    }
}
