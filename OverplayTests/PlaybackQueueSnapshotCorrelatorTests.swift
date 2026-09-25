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
    private func submitted(_ local: String, title: String = "Punk Guy", artist: String = "NOFX") -> PendingQueueCorrelation {
        var value = member(local, "known-" + local)
        value.wasSubmitted = true
        value.metadata = .init(title: title, artist: artist, duration: 180)
        return value
    }

    @Test("unique title and artist recover unfamiliar IDs even in a partial shuffled queue")
    func uniqueMetadataRecoversShuffledEntry() {
        let members = [submitted("a"), submitted("b", title: "Other")]
        let snapshots = [PlayerQueueEntrySnapshot(id: "new", musicItemID: "unfamiliar", metadata: .init(title: " PUNK   GUY ", artist: "nofx", duration: 181))]
        let entries = PlaybackQueueSnapshotCorrelator.realizedEntriesInPlayerOrder(snapshots: snapshots, members: members)
        #expect(entries.map(\.localTrackID) == ["a"])
        #expect(entries.first?.matchSource == .metadata)
    }

    @Test("title alone, incompatible duration and unknown metadata are insufficient", arguments: ["artist", "duration", "title", "missing"])
    func mismatchesAreRejected(field: String) {
        var metadata = PlaybackTrackMatchMetadata(title: "Punk Guy", artist: "NOFX", duration: 180)
        if field == "artist" { metadata.artist = "another band" }
        if field == "duration" { metadata.duration = 240 }
        if field == "title" { metadata.title = "punk guy (live)" }
        let snapshots = [PlayerQueueEntrySnapshot(id: "new", musicItemID: "unfamiliar", metadata: field == "missing" ? nil : metadata)]
        #expect(PlaybackQueueSnapshotCorrelator.realizedEntriesInPlayerOrder(snapshots: snapshots, members: [submitted("a")]).isEmpty)
    }

    @Test("duplicates require a complete ordered manifest with an agreeing ID anchor")
    func duplicateMetadataNeedsPositionProof() {
        let members = [submitted("anchor", title: "Anchor"), submitted("a"), submitted("b")]
        let snapshots = [
            PlayerQueueEntrySnapshot(id: "0", musicItemID: "known-anchor", metadata: members[0].metadata),
            PlayerQueueEntrySnapshot(id: "1", musicItemID: "new-a", metadata: members[1].metadata),
            PlayerQueueEntrySnapshot(id: "2", musicItemID: "new-b", metadata: members[2].metadata)
        ]
        let ordered = PlaybackQueueSnapshotCorrelator.realizedEntriesInPlayerOrder(snapshots: snapshots, members: members, allowPositionMatching: true, submittedLocalTrackIDs: members.map(\.localTrackID))
        #expect(ordered.map(\.localTrackID) == ["anchor", "a", "b"])
        #expect(ordered.last?.matchSource == .positionAndMetadata)
        let shuffled = PlaybackQueueSnapshotCorrelator.realizedEntriesInPlayerOrder(snapshots: snapshots, members: members)
        #expect(shuffled.map(\.localTrackID) == ["anchor"])
        let partial = PlaybackQueueSnapshotCorrelator.realizedEntriesInPlayerOrder(snapshots: Array(snapshots.prefix(2)), members: members, allowPositionMatching: true, submittedLocalTrackIDs: members.map(\.localTrackID))
        #expect(partial.map(\.localTrackID) == ["anchor"])
        let reordered = PlaybackQueueSnapshotCorrelator.realizedEntriesInPlayerOrder(snapshots: Array(snapshots.reversed()), members: members, allowPositionMatching: true, submittedLocalTrackIDs: members.map(\.localTrackID))
        #expect(reordered.map(\.localTrackID) == ["anchor"])
    }

    @Test("positional recovery uses the submitted order independently of other playlist rows")
    func positionProofExcludesNonqueuedRows() {
        let submittedMembers = [submitted("anchor", title: "Anchor"), submitted("a"), submitted("b")]
        var nonqueued = submitted("retired")
        nonqueued.wasSubmitted = false
        let snapshots = [
            PlayerQueueEntrySnapshot(id: "0", musicItemID: "known-anchor", metadata: submittedMembers[0].metadata),
            PlayerQueueEntrySnapshot(id: "1", musicItemID: "new-a", metadata: submittedMembers[1].metadata),
            PlayerQueueEntrySnapshot(id: "2", musicItemID: "new-b", metadata: submittedMembers[2].metadata)
        ]
        let submittedIDs = submittedMembers.map(\.localTrackID)
        // Neither database order nor a nonqueued metadata duplicate is position evidence.
        var members = [nonqueued] + submittedMembers.reversed()
        let recovered = PlaybackQueueSnapshotCorrelator.realizedEntriesInPlayerOrder(
            snapshots: snapshots, members: members, allowPositionMatching: true,
            submittedLocalTrackIDs: submittedIDs
        )
        #expect(recovered.map(\.localTrackID) == submittedIDs)
        #expect(recovered.last?.matchSource == .positionAndMetadata)
        members.removeAll { $0.localTrackID == "b" }
        let missing = PlaybackQueueSnapshotCorrelator.realizedEntriesInPlayerOrder(
            snapshots: Array(snapshots.prefix(2)), members: members, allowPositionMatching: true,
            submittedLocalTrackIDs: submittedIDs
        )
        #expect(missing.map(\.localTrackID) == ["anchor"])
        // Nonqueued known IDs must still block a metadata guess for another row.
        nonqueued.matchableMusicItemIDs.insert("new-a")
        let conflicting = PlaybackQueueSnapshotCorrelator.realizedEntriesInPlayerOrder(
            snapshots: snapshots, members: submittedMembers + [nonqueued], allowPositionMatching: true,
            submittedLocalTrackIDs: submittedIDs
        )
        #expect(conflicting.map(\.localTrackID) == ["anchor", "retired"])
    }

    @Test("metadata cannot steal documented IDs or resolve conflicting ID claims")
    func documentedIdentityTakesPriority() {
        var a = submitted("a")
        let b = submitted("b", title: "Different")
        let snapshots = [PlayerQueueEntrySnapshot(id: "entry", musicItemID: "known-b", metadata: a.metadata)]
        #expect(PlaybackQueueSnapshotCorrelator.realizedEntriesInPlayerOrder(snapshots: snapshots, members: [a, b]).first?.localTrackID == "b")
        a.matchableMusicItemIDs.insert("known-b")
        #expect(PlaybackQueueSnapshotCorrelator.realizedEntriesInPlayerOrder(snapshots: snapshots, members: [a, b]).isEmpty)
    }

    @Test("cache evidence is rechecked against reported metadata")
    func cacheMustMatchMetadata() {
        var a = submitted("a")
        a.wasSubmitted = false
        a.cachedAssociations["saved-id"] = a.metadata
        let matching = PlayerQueueEntrySnapshot(id: "1", musicItemID: "saved-id", metadata: a.metadata)
        #expect(PlaybackQueueSnapshotCorrelator.realizedEntriesInPlayerOrder(snapshots: [matching], members: [a]).first?.matchSource == .cachedAssociation)
        let wrongArtist = PlayerQueueEntrySnapshot(id: "1", musicItemID: "saved-id", metadata: .init(title: "Punk Guy", artist: "Wrong"))
        #expect(PlaybackQueueSnapshotCorrelator.realizedEntriesInPlayerOrder(snapshots: [wrongArtist], members: [a]).isEmpty)
    }

}
