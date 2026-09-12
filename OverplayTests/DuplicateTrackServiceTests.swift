import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
struct DuplicateTrackServiceTests {
    func fixture(_ context: ModelContext, mixed: Bool = false) throws -> [DuplicateTrackService.Candidate] {
        let bucket = try PlaylistRepository.triageBucket(in: context)
        let otp = PlaylistRecord(musicPlaylistID: "otp", name: "OTP", role: .oneTruePlaylist)
        context.insert(otp)
        for index in 1...2 {
            let track = TrackRecord(catalogID: String(index), title: "Song", artistName: "Artist")
            track.isrc = "SAME-RECORDING"
            context.insert(track)
            context.insert(PlaylistItemRecord(playlistID: mixed && index == 1 ? otp.id : bucket.id,
                trackID: track.id, sourceMusicPlaylistIDs: ["source-\(index)"], skipCount: index, playthroughCount: index * 2))
            context.insert(HistoryEvent(trackID: track.id, eventType: .skipCounted, source: .playback))
        }
        try context.save()
        return try DuplicateTrackService.candidates(in: context)
    }

    @Test func scanIsOnlyASuggestionAndCancellationDoesNothing() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let candidates = try fixture(container.mainContext)
        #expect(DuplicateTrackService.groups(candidates).count == 1)
        #expect(try TrackRecordRepository.allTracks(in: container.mainContext).count == 2)
        #expect(try PlaylistItemRepository.allItems(in: container.mainContext).count == 2)
        var distinct = candidates
        distinct[0].isrc = "OTHER"
        #expect(DuplicateTrackService.groups(distinct).isEmpty)
    }

    @Test func sameCollectionMergeSumsLiveCountsAndPreservesHistory() throws {
        let container = try OverplayTestSupport.makeModelContainer(); let context = container.mainContext
        let candidates = try fixture(context)
        let first = try #require(try PlaylistItemRepository.item(id: candidates[0].itemID, in: context))
        first.skipCount += 10 // Playback while review was open must not be lost.
        let result = try DuplicateTrackService.merge(candidates, destination: nil, in: context)
        let item = try #require(try PlaylistItemRepository.item(id: result.itemID, in: context))
        #expect(item.skipCount == 13 && item.playthroughCount == 6)
        #expect(Set(item.sourceMusicPlaylistIDs) == ["source-1", "source-2"])
        #expect(try TrackRecordRepository.allTracks(in: context).count == 1)
        #expect(try PlaylistItemRepository.allItems(in: context).count == 1)
        let history = try context.fetch(FetchDescriptor<HistoryEvent>())
        #expect(history.allSatisfy { $0.trackID == result.trackID })
        #expect(throws: DuplicateTrackService.MergeError.self) { try DuplicateTrackService.merge(candidates, destination: nil, in: context) }
        #expect(item.skipCount == 13)
        #expect(try TrackRecordRepository.track(catalogID: "1", libraryID: nil, in: context)?.id == result.trackID)
        #expect(try TrackRecordRepository.track(catalogID: "2", libraryID: nil, in: context)?.id == result.trackID)
    }

    @Test(arguments: DuplicateTrackService.Destination.allCases)
    func mixedCollectionsRequireChoice(_ destination: DuplicateTrackService.Destination) throws {
        let container = try OverplayTestSupport.makeModelContainer(); let context = container.mainContext
        let candidates = try fixture(context, mixed: true)
        #expect(throws: DuplicateTrackService.MergeError.self) { try DuplicateTrackService.merge(candidates, destination: nil, in: context) }
        let result = try DuplicateTrackService.merge(candidates, destination: destination, in: context)
        let item = try #require(try PlaylistItemRepository.item(id: result.itemID, in: context))
        #expect(item.skipCount == 3 && item.playthroughCount == 6)
        let remaining = try DuplicateTrackService.candidates(in: context)
        #expect(remaining.count == 1 && remaining[0].destination == destination)
        #expect(item.suppressedOTPMusicPlaylistIDs.contains("otp") == (destination != .otp))
    }

    @Test func changedLocationRejectsBeforeMutation() throws {
        let container = try OverplayTestSupport.makeModelContainer(); let context = container.mainContext
        let candidates = try fixture(context)
        let item = try #require(try PlaylistItemRepository.item(id: candidates[0].itemID, in: context))
        item.locationChangedAt = .now
        #expect(throws: DuplicateTrackService.MergeError.self) { try DuplicateTrackService.merge(candidates, destination: nil, in: context) }
        #expect(try TrackRecordRepository.allTracks(in: context).count == 2)
    }

    @Test func isrcAloneNeverAutomaticallyMerges() async throws {
        let container = try OverplayTestSupport.makeModelContainer(); let context = container.mainContext
        _ = try fixture(context)
        let summary = try await TrackIdentityMergeService.mergeDuplicates(in: context)
        #expect(summary.mergedTrackCount == 0)
    }

    @Test func documentedEmptyMappingPersistsAndOverridesOpaqueHints() throws {
        let container = try OverplayTestSupport.makeModelContainer(); let context = container.mainContext
        var snapshot = TrackSnapshot(id: "i.upload", catalogID: "opaque", libraryID: "i.upload",
            playlistEntryID: nil, playlistID: nil, title: "Upload", artistName: "Artist", albumTitle: nil,
            artworkURLTemplate: nil, durationSeconds: nil)
        let track = try TrackRecordRepository.upsert(snapshot, in: context)
        snapshot.catalogID = nil; snapshot.hasDocumentedIdentity = true; snapshot.isrc = "ISRC"
        let result = try TrackRecordRepository.upsertWithResult(snapshot, in: context)
        #expect(result.mutation == .updated)
        #expect(track.catalogID == nil && track.isrc == "ISRC")
        snapshot.catalogID = "opaque"; snapshot.hasDocumentedIdentity = false
        _ = try TrackRecordRepository.upsert(snapshot, in: context)
        #expect(track.catalogID == nil)
        try context.save()
        let fresh = ModelContext(container)
        #expect(try TrackRecordRepository.track(id: track.id, in: fresh)?.isrc == "ISRC")
    }
    @Test func playbackDisplayFollowsMergedDonorImmediately() throws {
        let container = try OverplayTestSupport.makeModelContainer(); let context = container.mainContext
        let candidates = try fixture(context)
        let donor = candidates[1]
        let defaults = PlaybackTestDefaults()
        defer { defaults.cleanUp() }
        let controller = PlaybackController(localPlaybackDefaults: defaults.defaults)
        controller.currentPlaylistID = PlaylistRecord.triageBucketMusicPlaylistID
        controller.currentPlaylistItem = try PlaylistItemRepository.item(id: donor.itemID, in: context)
        controller.currentTrack = CurrentPlaybackTrack(id: donor.catalogID!, title: donor.title, artistName: donor.artist)
        let result = try DuplicateTrackService.merge(candidates, destination: nil, in: context, defaults: defaults.defaults)
        controller.applyDuplicateMerge(result, previousCurrentID: donor.id, context: context)
        #expect(controller.currentPlaylistItem?.id == result.itemID)
        #expect(controller.currentPlaylistItem?.trackID == result.trackID)
        #expect(controller.currentTrack?.skipCount == 3)
        #expect(controller.currentTrack?.playthroughCount == 6)
    }

    @Test func retiredMergePreservesNewestRetirementAgainstOlderSourceLink() throws {
        let container = try OverplayTestSupport.makeModelContainer(); let context = container.mainContext
        let candidates = try fixture(context)
        for (index, candidate) in candidates.enumerated() {
            let item = try #require(try PlaylistItemRepository.item(id: candidate.itemID, in: context))
            item.evictedAt = Date(timeIntervalSince1970: Double(index + 1) * 100)
            item.locationChangedAt = item.evictedAt
        }
        let selected = try DuplicateTrackService.candidates(in: context)
        let result = try DuplicateTrackService.merge(selected, destination: nil, in: context)
        let item = try #require(try PlaylistItemRepository.item(id: result.itemID, in: context))
        let bucket = try PlaylistRepository.triageBucket(in: context)
        let source = PlaylistRecord(musicPlaylistID: "linked", name: "Source", role: .triageSource)
        source.triageLinkedAt = Date(timeIntervalSince1970: 150)
        context.insert(source)
        try TrackLocationService.reconcileIntake(item, owner: bucket, sourcePlaylist: source, entryID: nil, at: .now, in: context)
        #expect(item.evictedAt == Date(timeIntervalSince1970: 200))
    }

    @Test func remotePreflightRejectsChangedRowsBeforeAdding() async throws {
        let container = try OverplayTestSupport.makeModelContainer(); let context = container.mainContext
        let selected = try fixture(context)
        let item = try #require(try PlaylistItemRepository.item(id: selected[0].itemID, in: context))
        item.locationChangedAt = .now
        var adds = 0
        let mutation = PlaylistMutationService(addRemotely: { _, _, _ in adds += 1 })
        await #expect(throws: (any Error).self) {
            try await DuplicateTrackService.prepareOTPMembership(selected, in: context, mutation: mutation)
        }
        #expect(adds == 0)
        #expect(try TrackRecordRepository.allTracks(in: context).count == 2)
    }

    @Test func newerLocationDuringAddRemainsSuppressed() async throws {
        let container = try OverplayTestSupport.makeModelContainer(); let context = container.mainContext
        let selected = try fixture(context)
        let item = try #require(try PlaylistItemRepository.item(id: selected[0].itemID, in: context))
        let mutation = PlaylistMutationService(addRemotely: { _, _, _ in
            #expect(item.suppressedOTPMusicPlaylistIDs.contains("otp"))
            item.locationChangedAt = .now
            try context.save()
        })
        await #expect(throws: (any Error).self) {
            try await DuplicateTrackService.prepareOTPMembership(selected, in: context, mutation: mutation)
        }
        let otp = try #require(try PlaylistRepository.oneTruePlaylist(in: context))
        try TrackLocationService.reconcileIntake(item, owner: otp, sourcePlaylist: otp, entryID: nil, at: .now, in: context)
        #expect(item.playlistID != otp.id)
    }

    @Test func changingOTPDuringAddRejectsLocalMerge() async throws {
        let container = try OverplayTestSupport.makeModelContainer(); let context = container.mainContext
        let selected = try fixture(context)
        let mutation = PlaylistMutationService(addRemotely: { _, oldOTP, _ in
            oldOTP.role = .triageSource
            context.insert(PlaylistRecord(musicPlaylistID: "new-otp", name: "New", role: .oneTruePlaylist))
            try context.save()
        })
        await #expect(throws: (any Error).self) {
            try await DuplicateTrackService.prepareOTPMembership(selected, in: context, mutation: mutation)
        }
        #expect(try TrackRecordRepository.allTracks(in: context).count == 2)
        #expect(try DuplicateTrackService.candidates(in: context).allSatisfy { $0.destination == .triage })
    }

    @Test(arguments: [false, true])
    func newlyArrivedStatisticsRowRejectsMergeWithoutLosingCounts(hiddenOwner: Bool) throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let selected = try fixture(context)
        let donor = selected[1]
        let incomingContext = ModelContext(container)
        let playlistID: UUID
        if hiddenOwner {
            let source = PlaylistRecord(musicPlaylistID: "inactive-source", name: "Source", role: .triageSource, isActive: false)
            incomingContext.insert(source)
            playlistID = source.id
        } else { playlistID = donor.playlistID }
        let incoming = PlaylistItemRecord(playlistID: playlistID, trackID: donor.id,
            skipCount: 11, playthroughCount: 13, createdAt: .now.addingTimeInterval(1))
        incomingContext.insert(incoming)
        try incomingContext.save()

        #expect(throws: DuplicateTrackService.MergeError.self) {
            try DuplicateTrackService.merge(selected, destination: nil, in: context)
        }
        let persisted = ModelContext(container)
        #expect(try TrackRecordRepository.allTracks(in: persisted).count == 2)
        let items = try PlaylistItemRepository.allItems(in: persisted)
        #expect(items.count == 3)
        #expect(items.reduce(0) { $0 + $1.skipCount } == 14)
        #expect(items.reduce(0) { $0 + $1.playthroughCount } == 19)
        #expect(items.allSatisfy { item in selected.contains { $0.id == item.trackID } })
    }
}
