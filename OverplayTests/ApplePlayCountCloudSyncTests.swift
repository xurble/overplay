import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("Apple play count convergence")
struct ApplePlayCountCloudSyncTests {
    let start = Date(timeIntervalSince1970: 1_000)

    private func state(origin: UUID, seed: Int = 1, baseline: Int = 10, latest: Int = 10,
                       at date: Date? = nil, counter: String = "i.song") -> ApplePlayCountState {
        var state = ApplePlayCountState(initialCount: seed, originID: origin)
        state.observe(musicItemID: counter, count: baseline, at: date ?? start)
        state.observe(musicItemID: counter, count: latest, at: (date ?? start).addingTimeInterval(10))
        return state
    }

    private func item(in context: ModelContext, id: UUID, libraryID: String = "i.song") throws -> PlaylistItemRecord {
        let bucket = try PlaylistRepository.triageBucket(in: context)
        let track = TrackRecord(libraryID: libraryID, title: "Song", artistName: "Artist")
        context.insert(track)
        let item = PlaylistItemRecord(id: id, playlistID: bucket.id, trackID: track.id, playthroughCount: 1)
        context.insert(item)
        try context.save()
        return item
    }

    private func publish(_ state: ApplePlayCountState, itemID: UUID, device: String,
                         in context: ModelContext) throws {
        context.insert(ApplePlayCountRecord(itemID: itemID, state: state, deviceID: device))
        try context.save()
    }

    // Simulate independent CloudKit record delivery into a separate database.
    // No common ModelContext, shared mutable state, or live CloudKit is involved.
    private func deliver(from source: ModelContext, to destination: ModelContext, reversed: Bool = false) throws {
        let records = try source.fetch(FetchDescriptor<ApplePlayCountRecord>())
        let existingIDs = Set(try destination.fetch(FetchDescriptor<ApplePlayCountRecord>()).map(\.id))
        for record in reversed ? Array(records.reversed()) : records where !existingIDs.contains(record.id) {
            let copy: ApplePlayCountRecord
            if let snapshot = record.state {
                copy = ApplePlayCountRecord(itemID: record.itemID, state: snapshot, deviceID: record.deviceID)
            } else {
                copy = ApplePlayCountRecord(itemID: record.itemID, mergedItemID: try #require(record.lineageIDs.first), deviceID: record.deviceID)
            }
            copy.id = record.id
            destination.insert(copy)
        }
        try destination.save()
    }

    @Test("Different device totals converge to the highest value, never their sum", arguments: [false, true])
    func differentTotals(reverse: Bool) throws {
        let phone = try OverplayTestSupport.makeModelContainer()
        let tablet = try OverplayTestSupport.makeModelContainer()
        let id = UUID()
        let phoneItem = try item(in: phone.mainContext, id: id)
        let tabletItem = try item(in: tablet.mainContext, id: id)
        let baseline = state(origin: id)
        var high = baseline
        high.observe(musicItemID: "i.song", count: 13, at: start.addingTimeInterval(20))
        var low = baseline
        low.observe(musicItemID: "i.song", count: 11, at: start.addingTimeInterval(30))
        try publish(high, itemID: id, device: "phone", in: phone.mainContext)
        try publish(low, itemID: id, device: "tablet", in: tablet.mainContext)
        #expect(phoneItem.applePlayCount == 4)
        #expect(tabletItem.applePlayCount == 2)
        try deliver(from: phone.mainContext, to: tablet.mainContext, reversed: reverse)
        try deliver(from: tablet.mainContext, to: phone.mainContext, reversed: reverse)
        #expect(phoneItem.applePlayCount == 4 && tabletItem.applePlayCount == 4)
        try publish(low, itemID: id, device: "tablet-late-copy", in: phone.mainContext)
        #expect(phoneItem.applePlayCount == 4)
        try ApplePlayCountSyncService.apply([], startedAt: .now, in: phone.mainContext)
        #expect(phoneItem.applePlayCount == 4)
        let reloaded = ModelContext(phone)
        #expect(try PlaylistItemRepository.item(id: id, in: reloaded)?.applePlayCount == 4)
    }

    @Test("Conflicting initialization picks one baseline and never sums shared initial credit")
    func concurrentInitialization() throws {
        let origin = UUID()
        let first = state(origin: origin, seed: 1, baseline: 10, latest: 13, at: start)
        let second = state(origin: origin, seed: 3, baseline: 12, latest: 14, at: start.addingTimeInterval(1))
        var forward = try #require(ApplePlayCountState.joined([first, second]))
        var backward = try #require(ApplePlayCountState.joined([second, first, first, second]))
        #expect(forward == backward)
        #expect(forward.counters.first?.baseline == 10)
        #expect(forward.seeds.count == 1)
        forward.advance()
        backward.advance()
        #expect(forward == backward)
        #expect(forward.count == 5) // Original credit 1 + (14 - original baseline 10).
    }

    @Test("A late canonical baseline cannot lower a published count; playback eventually catches up")
    func baselineChangePreservesFloor() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let id = UUID()
        let track = try item(in: context, id: id)
        let local = state(origin: id, baseline: 10, latest: 15)
        try publish(local, itemID: id, device: "phone", in: context)
        #expect(track.applePlayCount == 6)
        let earlier = state(origin: id, baseline: 20, latest: 20, at: start.addingTimeInterval(-1))
        try publish(earlier, itemID: id, device: "tablet", in: context)
        #expect(track.applePlayCount == 6)
        try ApplePlayCountSyncService.apply([], startedAt: .now, in: context)
        #expect(track.applePlayCount == 6)
        for raw in [12, 20, 21, 24, 25, 26] {
            let observation = MusicLibraryPlaybackObservation(aliases: ["i.song"], snapshot:
                MusicLibraryPlaybackSnapshot(musicItemID: "i.song", playCount: raw, lastPlayedDate: nil))
            try ApplePlayCountSyncService.apply([observation], startedAt: .now, in: context)
            #expect(track.applePlayCount == (raw == 26 ? 7 : 6))
        }
    }

    @Test("Snapshot joins are associative, commutative and idempotent")
    func joinLaws() throws {
        let id = UUID()
        let a = state(origin: id, baseline: 10, latest: 13)
        let b = state(origin: id, seed: 2, baseline: 11, latest: 14, at: start.addingTimeInterval(1))
        let c = state(origin: UUID(), seed: 4, baseline: 20, latest: 22, counter: "i.other")
        let ab = try #require(ApplePlayCountState.joined([a, b]))
        let bc = try #require(ApplePlayCountState.joined([b, c]))
        #expect(ApplePlayCountState.joined([ab, c]) == ApplePlayCountState.joined([a, bc]))
        #expect(ApplePlayCountState.joined([a, b, c]) == ApplePlayCountState.joined([c, a, b]))
        #expect(ApplePlayCountState.joined([a, a]) == ApplePlayCountState.joined([a]))
    }

    @Test("Shared aliases seed once even when CloudKit created separate local track rows")
    func aliasCreditDeduplication() throws {
        var a = state(origin: UUID(), seed: 2, baseline: 10, latest: 12)
        let b = state(origin: UUID(), seed: 2, baseline: 10, latest: 12)
        a.merge(b)
        #expect(a.count == 4)
        a.merge(b)
        #expect(a.count == 4)
    }

    @Test("Late donor observations remain reachable after a merge deletes its item")
    func lateDonor() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let keeper = try item(in: context, id: UUID())
        let donor = try item(in: context, id: UUID(), libraryID: "i.other")
        let donorID = donor.id
        keeper.applePlayCountState = state(origin: keeper.id, baseline: 10, latest: 11)
        let donorState = state(origin: donorID, baseline: 20, latest: 21, counter: "i.other")
        donor.applePlayCountState = donorState
        PlaylistItemRepository.mergeStats(from: donor, into: keeper, adoptEvictionStateIfNewer: false)
        context.delete(donor)
        try context.save()
        #expect(keeper.applePlayCount == 4)
        var late = donorState
        late.observe(musicItemID: "i.other", count: 23, at: start.addingTimeInterval(30))
        try publish(late, itemID: donorID, device: "offline-tablet", in: context)
        #expect(keeper.applePlayCount == 4)
        try ApplePlayCountSyncService.apply([], startedAt: .now, in: context)
        #expect(keeper.applePlayCount == 6)
        try publish(donorState, itemID: donorID, device: "stale-tablet", in: context)
        try ApplePlayCountSyncService.apply([], startedAt: .now, in: context)
        #expect(keeper.applePlayCount == 6)
    }

    @Test("An explicit reset is an epoch; late pre-reset records cannot restore its old total")
    func resetEpoch() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let id = UUID()
        let item = try item(in: context, id: id)
        let old = state(origin: id, latest: 15)
        try publish(old, itemID: id, device: "phone", in: context)
        try PlaylistItemRepository.resetAllStats(in: context)
        #expect(item.applePlayCount == 0)
        var delayed = old
        delayed.observe(musicItemID: "i.song", count: 40, at: .now)
        try publish(delayed, itemID: id, device: "offline-tablet", in: context)
        try ApplePlayCountSyncService.apply([], startedAt: .now, in: context)
        #expect(item.applePlayCount == 0)
        var current = try #require(item.applePlayCountState)
        current.observe(musicItemID: "i.song", count: 16, at: .now)
        item.applePlayCountState = current
        #expect(item.applePlayCount == 1)
    }

    @Test("Merging before initialization retains a route for a late donor observation")
    func mergeBeforeInitialization() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let keeper = try item(in: context, id: UUID())
        let donor = try item(in: context, id: UUID())
        let donorID = donor.id
        PlaylistItemRepository.mergeStats(from: donor, into: keeper, adoptEvictionStateIfNewer: false)
        context.delete(donor)
        try context.save()
        #expect(keeper.applePlayCount == nil)
        try publish(state(origin: donorID, latest: 13), itemID: donorID, device: "offline-tablet", in: context)
        try ApplePlayCountSyncService.apply([], startedAt: .now, in: context)
        #expect(keeper.applePlayCount == 4)
    }

    @Test("Cloud observations reconcile and publish even when Apple cannot be queried")
    func cloudWithoutMusicKit() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let id = UUID()
        let item = try item(in: context, id: id)
        let first = state(origin: id, baseline: 10, latest: 10)
        let later = state(origin: id, baseline: 12, latest: 15, at: start.addingTimeInterval(1))
        try publish(first, itemID: id, device: "phone", in: context)
        try publish(later, itemID: id, device: "tablet", in: context)
        #expect(item.applePlayCount == 4)
        let service = ApplePlayCountSyncService(fetch: { _ in throw CancellationError() })
        _ = await service.refresh(in: context)
        #expect(item.applePlayCount == 6)
    }
}
