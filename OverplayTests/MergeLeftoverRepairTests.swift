import Foundation
import SwiftData
import Testing
@testable import Overplay

/// `LOC-002`: a membership of a track a merge absorbed, delivered after the
/// merge or written again by a device that had not heard of it, joins the
/// surviving track instead of pointing at a deleted one (2026-10-23).
@MainActor
struct MergeLeftoverRepairTests {
    struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let bucket: PlaylistRecord
        let otp: PlaylistRecord
    }

    private func fixture() throws -> Fixture {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let bucket = try PlaylistRepository.triageBucket(in: context)
        let otp = PlaylistRecord(musicPlaylistID: "otp", name: "OTP", role: .oneTruePlaylist)
        context.insert(otp)
        try context.save()
        return Fixture(container: container, context: context, bucket: bucket, otp: otp)
    }

    private func track(_ id: String, in context: ModelContext) -> TrackRecord {
        let track = TrackRecord(libraryID: id, title: "Song", artistName: "Artist")
        context.insert(track)
        return track
    }

    private func items(_ f: Fixture) throws -> [PlaylistItemRecord] {
        try PlaylistItemRepository.allItems(in: f.context).filter { !$0.isDeleted }
    }

    /// The automatic merge moves a donor's memberships, but CloudKit may
    /// deliver one only after this device has merged the donor away.
    @Test func aMembershipDeliveredAfterAnAutomaticMergeJoinsTheSurvivingTrack() async throws {
        let f = try fixture()
        let keeper = TrackRecord(catalogID: "1", title: "Song", artistName: "Artist", createdAt: Date(timeIntervalSince1970: 10))
        let donor = TrackRecord(catalogID: "1", libraryID: "i.donor", title: "Song", artistName: "Artist",
                                createdAt: Date(timeIntervalSince1970: 20))
        f.context.insert(keeper)
        f.context.insert(donor)
        let donorID = donor.id
        try await TrackIdentityMergeService.mergeDuplicates(in: f.context)
        try f.context.save()
        #expect(try TrackRecordRepository.allTracks(in: f.context).map(\.id) == [keeper.id])

        // The keeper has no membership of its own: deleting this one would
        // leave the song in no collection at all.
        f.context.insert(PlaylistItemRecord(playlistID: f.otp.id, trackID: donorID))
        try f.context.save()

        #expect(try TrackLocationService.repairLocations(in: f.context).mergeLeftovers == 1)
        let remaining = try items(f)
        #expect(remaining.map(\.trackID) == [keeper.id])
        #expect(remaining.first?.playlistID == f.otp.id)
    }

    @Test func aNewerRetirementOnTheLeftoverWinsOverTheSurvivorsRow() throws {
        let f = try fixture()
        let keeper = track("i.keeper", in: f.context)
        let donorID = UUID()
        try ListenLedger.recordLineage(keeper: keeper.id, donor: donorID, in: f.context)
        let active = PlaylistItemRecord(playlistID: f.otp.id, trackID: keeper.id)
        active.locationChangedAt = Date(timeIntervalSince1970: 100)
        f.context.insert(active)
        // Retired on another device before it heard of the merge.
        let retired = PlaylistItemRecord(playlistID: f.bucket.id, trackID: donorID)
        retired.evictedAt = Date(timeIntervalSince1970: 200)
        retired.locationChangedAt = Date(timeIntervalSince1970: 200)
        retired.evictionSource = .user
        f.context.insert(retired)
        try f.context.save()

        #expect(try TrackLocationService.repairLocations(in: f.context).mergeLeftovers == 1)
        let remaining = try items(f)
        #expect(remaining.count == 1)
        #expect(remaining.first?.trackID == keeper.id)
        #expect(remaining.first?.playlistID == f.bucket.id)
        #expect(remaining.first?.evictedAt == Date(timeIntervalSince1970: 200))
    }

    @Test func anOlderLeftoverDoesNotUndoTheSurvivorsNewerMove() throws {
        let f = try fixture()
        let keeper = track("i.keeper", in: f.context)
        let donorID = UUID()
        try ListenLedger.recordLineage(keeper: keeper.id, donor: donorID, in: f.context)
        let promoted = PlaylistItemRecord(playlistID: f.otp.id, trackID: keeper.id)
        promoted.locationChangedAt = Date(timeIntervalSince1970: 300)
        f.context.insert(promoted)
        let stale = PlaylistItemRecord(playlistID: f.bucket.id, trackID: donorID)
        stale.locationChangedAt = Date(timeIntervalSince1970: 200)
        f.context.insert(stale)
        try f.context.save()

        _ = try TrackLocationService.repairLocations(in: f.context)
        let remaining = try items(f)
        #expect(remaining.count == 1)
        #expect(remaining.first?.trackID == keeper.id)
        #expect(remaining.first?.playlistID == f.otp.id)
    }

    /// The decision may arrive only as the other device's history event: it
    /// moves with the membership, so `LOC-001` re-applies it.
    @Test func aRetirementEventForTheMergedAwayTrackIsReappliedToTheSurvivor() throws {
        let f = try fixture()
        let keeper = track("i.keeper", in: f.context)
        let donorID = UUID()
        try ListenLedger.recordLineage(keeper: keeper.id, donor: donorID, in: f.context)
        f.context.insert(PlaylistItemRecord(playlistID: f.otp.id, trackID: donorID))
        let retiredAt = Date.now
        f.context.insert(HistoryEvent(playlistID: f.otp.id, trackID: donorID, eventType: .evicted, source: .user,
                                      createdAt: retiredAt))
        try f.context.save()

        let repaired = try TrackLocationService.repairLocations(in: f.context)
        #expect(repaired.mergeLeftovers == 2)
        #expect(repaired.retirements == 1)
        let remaining = try items(f)
        #expect(remaining.map(\.trackID) == [keeper.id])
        #expect(remaining.first?.playlistID == f.bucket.id)
        #expect(remaining.first?.evictedAt == retiredAt)
    }

    @Test func chainedMergesReachTheLastSurvivor() throws {
        let f = try fixture()
        let survivor = track("i.survivor", in: f.context)
        let donorID = UUID()
        let middleID = UUID()
        try ListenLedger.recordLineage(keeper: middleID, donor: donorID, in: f.context)
        try ListenLedger.recordLineage(keeper: survivor.id, donor: middleID, in: f.context)
        f.context.insert(PlaylistItemRecord(playlistID: f.otp.id, trackID: donorID))
        try f.context.save()

        #expect(try PlaylistItemRepository.repairMergeLeftovers(in: f.context) == 1)
        #expect(try items(f).map(\.trackID) == [survivor.id])
    }

    /// A survivor that is not here has usually not arrived yet: deleting the
    /// leftover could leave the song with no membership on every device.
    @Test func aLeftoverWaitsForItsSurvivorToArrive() throws {
        let f = try fixture()
        let donorID = UUID()
        let survivor = TrackRecord(libraryID: "i.survivor", title: "Song", artistName: "Artist")
        try ListenLedger.recordLineage(keeper: survivor.id, donor: donorID, in: f.context)
        f.context.insert(PlaylistItemRecord(playlistID: f.otp.id, trackID: donorID))
        try f.context.save()

        #expect(try PlaylistItemRepository.repairMergeLeftovers(in: f.context) == 0)
        #expect(try items(f).map(\.trackID) == [donorID])

        f.context.insert(survivor)
        try f.context.save()
        #expect(try PlaylistItemRepository.repairMergeLeftovers(in: f.context) == 1)
        #expect(try items(f).map(\.trackID) == [survivor.id])
    }

    /// The other device's decision may come only as a history event, in a
    /// later import than its membership, or with no membership at all.
    @Test func aRetirementEventArrivingAfterItsMembershipStillReachesTheSurvivor() throws {
        let f = try fixture()
        let keeper = track("i.keeper", in: f.context)
        let donorID = UUID()
        try ListenLedger.recordLineage(keeper: keeper.id, donor: donorID, in: f.context)
        f.context.insert(PlaylistItemRecord(playlistID: f.otp.id, trackID: donorID))
        try f.context.save()
        #expect(try TrackLocationService.repairLocations(in: f.context).mergeLeftovers == 1)
        try f.context.save()

        let retiredAt = Date.now
        f.context.insert(HistoryEvent(playlistID: f.otp.id, trackID: donorID, eventType: .evicted, source: .user,
                                      createdAt: retiredAt))
        try f.context.save()

        let repaired = try TrackLocationService.repairLocations(in: f.context)
        #expect(repaired.mergeLeftovers == 1)
        #expect(repaired.retirements == 1)
        let remaining = try items(f)
        #expect(remaining.map(\.trackID) == [keeper.id])
        #expect(remaining.first?.playlistID == f.bucket.id)
        #expect(remaining.first?.evictedAt == retiredAt)
    }

    /// Two devices merged the same song into different tracks.
    @Test func aTrackMergedIntoTwoJoinsTheSameSurvivorEverywhere() throws {
        let f = try fixture()
        let first = track("i.first", in: f.context)
        let second = track("i.second", in: f.context)
        let notHere = UUID()
        let donorID = UUID()
        try ListenLedger.recordLineage(keeper: notHere, donor: donorID, in: f.context)
        try ListenLedger.recordLineage(keeper: second.id, donor: donorID, in: f.context)
        try ListenLedger.recordLineage(keeper: first.id, donor: donorID, in: f.context)
        let lineage = ListenEventKind.lineage.rawValue
        for event in try f.context.fetch(FetchDescriptor<ListenEvent>(predicate: #Predicate { $0.kindRawValue == lineage })) {
            event.occurredAt = switch event.trackID {
            case notHere: Date(timeIntervalSince1970: 100)
            case second.id: Date(timeIntervalSince1970: 200)
            default: Date(timeIntervalSince1970: 300)
            }
        }
        f.context.insert(PlaylistItemRecord(playlistID: f.otp.id, trackID: donorID))
        try f.context.save()

        // The earliest merge whose survivor is here, whatever the fetch order.
        #expect(try ListenLedger.keeper(absorbing: donorID, in: f.context) == second.id)
        #expect(try PlaylistItemRepository.repairMergeLeftovers(in: f.context) == 1)
        #expect(try items(f).map(\.trackID) == [second.id])
    }

    /// A survivor reached in one merge is preferred to one reached through a
    /// chain, even when the chain began with an earlier merge.
    @Test func theNearerSurvivorWinsOverAnEarlierChain() throws {
        let f = try fixture()
        let near = track("i.near", in: f.context)
        let deep = track("i.deep", in: f.context)
        let middle = UUID()
        let donorID = UUID()
        try ListenLedger.recordLineage(keeper: middle, donor: donorID, in: f.context)
        try ListenLedger.recordLineage(keeper: deep.id, donor: middle, in: f.context)
        try ListenLedger.recordLineage(keeper: near.id, donor: donorID, in: f.context)
        let lineage = ListenEventKind.lineage.rawValue
        for event in try f.context.fetch(FetchDescriptor<ListenEvent>(predicate: #Predicate { $0.kindRawValue == lineage })) {
            event.occurredAt = event.trackID == near.id ? Date(timeIntervalSince1970: 300) : Date(timeIntervalSince1970: 100)
        }
        try f.context.save()

        #expect(try ListenLedger.keeper(absorbing: donorID, in: f.context) == near.id)
    }

    /// Merges recorded at the same moment are told apart by their record IDs,
    /// which every device shares.
    @Test func simultaneousMergesAreSettledByRecordID() throws {
        let f = try fixture()
        let first = track("i.first", in: f.context)
        let second = track("i.second", in: f.context)
        let donorID = UUID()
        try ListenLedger.recordLineage(keeper: first.id, donor: donorID, in: f.context)
        try ListenLedger.recordLineage(keeper: second.id, donor: donorID, in: f.context)
        let lineage = ListenEventKind.lineage.rawValue
        let events = try f.context.fetch(FetchDescriptor<ListenEvent>(predicate: #Predicate { $0.kindRawValue == lineage }))
        for event in events { event.occurredAt = Date(timeIntervalSince1970: 100) }
        try f.context.save()

        let expected = try #require(events.min { $0.id.uuidString < $1.id.uuidString }).trackID
        #expect(try ListenLedger.keeper(absorbing: donorID, in: f.context) == expected)
    }

    /// A user merge removes the donor's memberships; one written again by a
    /// device that had not heard of it joins the merged song.
    @Test func aMembershipWrittenAgainAfterAUserMergeJoinsTheMergedSong() throws {
        let f = try fixture()
        for index in 1...2 {
            let track = TrackRecord(catalogID: String(index), title: "Song", artistName: "Artist")
            track.isrc = "SAME-RECORDING"
            f.context.insert(track)
            f.context.insert(PlaylistItemRecord(playlistID: f.bucket.id, trackID: track.id,
                                                sourceMusicPlaylistIDs: ["source-\(index)"]))
        }
        try f.context.save()
        let candidates = try DuplicateTrackService.candidates(in: f.context)
        let result = try DuplicateTrackService.merge(candidates, destination: nil, in: f.context)
        try f.context.save()
        let donorID = try #require(candidates.map(\.id).first { $0 != result.trackID })
        #expect(try TrackRecordRepository.track(id: donorID, in: f.context) == nil)

        let rewritten = PlaylistItemRecord(playlistID: f.bucket.id, trackID: donorID, sourceMusicPlaylistIDs: ["source-late"])
        f.context.insert(rewritten)
        try f.context.save()

        #expect(try TrackLocationService.repairLocations(in: f.context).mergeLeftovers == 1)
        let remaining = try items(f)
        #expect(remaining.map(\.trackID) == [result.trackID])
        #expect(remaining.first?.sourceMusicPlaylistIDs.contains("source-late") == true)
    }

    /// A merge record alone is not enough: a donor track that exists again,
    /// or a track still arriving, keeps its membership as it is.
    @Test func onlyMembershipsOfMissingMergedAwayTracksAreTouched() throws {
        let f = try fixture()
        let keeper = track("i.keeper", in: f.context)
        let restoredDonor = track("i.donor", in: f.context)
        try ListenLedger.recordLineage(keeper: keeper.id, donor: restoredDonor.id, in: f.context)
        let donorItem = PlaylistItemRecord(playlistID: f.otp.id, trackID: restoredDonor.id)
        let arriving = PlaylistItemRecord(playlistID: f.otp.id, trackID: UUID())
        f.context.insert(donorItem)
        f.context.insert(arriving)
        try f.context.save()

        #expect(try PlaylistItemRepository.repairMergeLeftovers(in: f.context) == 0)
        #expect(Set(try items(f).map(\.trackID)) == [restoredDonor.id, arriving.trackID])
    }
}
