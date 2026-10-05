import Foundation
import SwiftData
import Testing
@testable import Overplay

/// `COUNT-002`: counts are derived from immutable events, so merges, resets and
/// concurrent devices can only ever add evidence.
@MainActor
struct ListenLedgerTests {
    private struct Store {
        let container: ModelContainer
        let context: ModelContext
        let track: TrackRecord
        let item: PlaylistItemRecord
    }

    private func makeStore(trackID: UUID = UUID(), skips: Int = 0, plays: Int = 0) throws -> Store {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = ModelContext(container)
        let playlist = PlaylistRecord(musicPlaylistID: "p.otp", name: "Overplay", role: .oneTruePlaylist, writePolicy: .managed)
        let track = TrackRecord(id: trackID, catalogID: "1", title: "Song", artistName: "Artist")
        let item = PlaylistItemRecord(playlistID: playlist.id, trackID: trackID, skipCount: skips, playthroughCount: plays)
        context.insert(playlist)
        context.insert(track)
        context.insert(item)
        try context.save()
        return Store(container: container, context: context, track: track, item: item)
    }

    private func events(in context: ModelContext) throws -> [ListenEvent] {
        try context.fetch(FetchDescriptor<ListenEvent>())
    }

    /// Simulates CloudKit delivering another device's immutable records.
    private func deliver(_ source: ModelContext, into destination: ModelContext) throws {
        let known = Set(try events(in: destination).map(\.id))
        for event in try events(in: source) where !known.contains(event.id) {
            let copy = ListenEvent(trackID: event.trackID, kind: event.kind ?? .playthrough, sessionID: event.sessionID,
                                   deviceID: event.deviceID, source: .playback, playthroughDelta: event.playthroughDelta,
                                   skipDelta: event.skipDelta, occurredAt: event.occurredAt)
            copy.id = event.id
            destination.insert(copy)
        }
        try destination.save()
    }

    @Test func recordingTheSameSessionTwiceCountsOnce() throws {
        let store = try makeStore()
        #expect(try ListenLedger.record(.playthrough, trackID: store.track.id, sessionID: "s1", source: .playback, in: store.context))
        #expect(try !ListenLedger.record(.playthrough, trackID: store.track.id, sessionID: "s1", source: .playback, in: store.context))
        try ListenLedger.refreshCounts(forTrackIDs: [store.track.id], in: store.context)
        #expect(store.item.playthroughCount == 1)
    }

    @Test func firstEventCarriesLegacyCountsForward() throws {
        let store = try makeStore(skips: 2, plays: 5)
        try ListenLedger.record(.playthrough, trackID: store.track.id, sessionID: "s1", source: .playback, in: store.context)
        try ListenLedger.refreshCounts(forTrackIDs: [store.track.id], in: store.context)
        #expect(store.item.playthroughCount == 6)
        #expect(store.item.skipCount == 2)
        #expect(try events(in: store.context).filter { $0.kind == .baseline }.count == 1)
    }

    @Test func skipResetRestartsOnlySkips() throws {
        let store = try makeStore(skips: 4, plays: 3)
        try ListenLedger.resetSkips(trackID: store.track.id, in: store.context)
        #expect(store.item.skipCount == 0)
        #expect(store.item.playthroughCount == 3)
        try ListenLedger.record(.skip, trackID: store.track.id, sessionID: "after", source: .playback, in: store.context)
        try ListenLedger.refreshCounts(forTrackIDs: [store.track.id], in: store.context)
        #expect(store.item.skipCount == 1)
    }

    @Test func statsResetRestartsEverythingAndLaterPlaysCount() throws {
        let store = try makeStore(skips: 4, plays: 3)
        try PlaylistItemRepository.resetAllStats(in: store.context)
        #expect(store.item.skipCount == 0 && store.item.playthroughCount == 0)
        try ListenLedger.record(.playthrough, trackID: store.track.id, sessionID: "after", source: .playback,
                                at: .now.addingTimeInterval(1), in: store.context)
        try ListenLedger.refreshCounts(forTrackIDs: [store.track.id], in: store.context)
        #expect(store.item.playthroughCount == 1)
    }

    @Test func twoDevicesCountingConcurrentlyConvergeOnTheSum() throws {
        let trackID = UUID()
        let phone = try makeStore(trackID: trackID)
        let pad = try makeStore(trackID: trackID)
        for session in ["a", "b", "c"] {
            try ListenLedger.record(.playthrough, trackID: trackID, sessionID: "phone-\(session)", source: .playback, in: phone.context)
        }
        try ListenLedger.record(.playthrough, trackID: trackID, sessionID: "pad-1", source: .playback, in: pad.context)
        try ListenLedger.record(.skip, trackID: trackID, sessionID: "pad-2", source: .playback, in: pad.context)
        try phone.context.save()
        try pad.context.save()

        try deliver(phone.context, into: pad.context)
        try deliver(pad.context, into: phone.context)
        try ListenLedger.reconcile(in: phone.context)
        try ListenLedger.reconcile(in: pad.context)

        #expect(phone.item.playthroughCount == 4 && pad.item.playthroughCount == 4)
        #expect(phone.item.skipCount == 1 && pad.item.skipCount == 1)
    }

    @Test func concurrentMigrationsOnTwoDevicesProduceOneBaseline() throws {
        let trackID = UUID()
        let phone = try makeStore(trackID: trackID, skips: 1, plays: 7)
        let pad = try makeStore(trackID: trackID, skips: 1, plays: 7)
        try ListenLedger.reconcile(in: phone.context)
        try ListenLedger.reconcile(in: pad.context)
        try deliver(phone.context, into: pad.context)
        try deliver(pad.context, into: phone.context)
        try ListenLedger.reconcile(in: phone.context)
        try ListenLedger.reconcile(in: pad.context)
        #expect(phone.item.playthroughCount == 7 && pad.item.playthroughCount == 7)
        #expect(phone.item.skipCount == 1 && pad.item.skipCount == 1)
    }

    @Test func competingBaselinesResolveToTheEarliest() {
        let trackID = UUID()
        let entries = [
            ListenLedger.Entry(id: UUID(), trackID: trackID, kind: .baseline, sessionID: "baseline:x",
                               occurredAt: Date(timeIntervalSince1970: 20), playthroughDelta: 5, skipDelta: 1),
            ListenLedger.Entry(id: UUID(), trackID: trackID, kind: .baseline, sessionID: "baseline:x",
                               occurredAt: Date(timeIntervalSince1970: 10), playthroughDelta: 3, skipDelta: 0)
        ]
        #expect(ListenLedger.counts(identities: [trackID], entries: entries) == .init(playthroughs: 3, skips: 0))
    }

    /// Review finding 1: CloudKit can deliver another device's derived count
    /// cache before its events. That cache must not be migrated again.
    @Test func derivedCacheSyncedAheadOfEventsIsNotMigratedAgain() throws {
        let trackID = UUID()
        let phone = try makeStore(trackID: trackID, plays: 5)
        let pad = try makeStore(trackID: trackID)
        try ListenLedger.record(.playthrough, trackID: trackID, sessionID: "phone-1", source: .playback, in: phone.context)
        try ListenLedger.refreshCounts(forTrackIDs: [trackID], in: phone.context)
        try phone.context.save()
        #expect(phone.item.playthroughCount == 6 && phone.item.countsDerivedFromLedger)

        // The item record arrives first.
        pad.item.playthroughCount = phone.item.playthroughCount
        pad.item.countsDerivedFromLedger = true
        try pad.context.save()
        try ListenLedger.reconcile(in: pad.context)
        try ListenLedger.record(.skip, trackID: trackID, sessionID: "pad-1", source: .playback, in: pad.context)
        try pad.context.save()
        #expect(try events(in: pad.context).filter { $0.kind == .baseline }.isEmpty)

        try deliver(phone.context, into: pad.context)
        try deliver(pad.context, into: phone.context)
        try ListenLedger.reconcile(in: phone.context)
        try ListenLedger.reconcile(in: pad.context)
        #expect(phone.item.playthroughCount == 6 && pad.item.playthroughCount == 6)
        #expect(phone.item.skipCount == 1 && pad.item.skipCount == 1)
    }

    /// Round 2, M4: a synced derived row whose events have not arrived keeps
    /// its counts, so the 0/0 retention rule cannot delete it.
    @Test func aDerivedRowAheadOfItsEventsIsNotLowered() throws {
        let trackID = UUID()
        let pad = try makeStore(trackID: trackID)
        let bucket = try PlaylistRepository.triageBucket(in: pad.context)
        pad.item.playlistID = bucket.id
        pad.item.evictedAt = .now
        pad.item.playthroughCount = 3
        pad.item.countsDerivedFromLedger = true
        try pad.context.save()

        try ListenLedger.reconcile(in: pad.context)
        try ListenLedger.refreshAllCounts(in: pad.context)
        #expect(pad.item.playthroughCount == 3)
        #expect(!TrackRetentionPolicy.shouldDelete(pad.item))
    }

    /// Review finding 1: a baseline written after another device's reset must
    /// not bring the reset counts back.
    @Test func lateBaselineAfterAResetDoesNotResurrectCounts() throws {
        let trackID = UUID()
        let phone = try makeStore(trackID: trackID, plays: 4)
        let pad = try makeStore(trackID: trackID, plays: 4)
        try ListenLedger.resetAll(at: Date(timeIntervalSince1970: 1_000), in: phone.context)
        try phone.context.save()
        // The pad never saw the phone's reset and migrates its legacy counts later.
        try ListenLedger.writeBaselinesIfNeeded(in: pad.context, at: Date(timeIntervalSince1970: 2_000))
        try pad.context.save()

        try deliver(phone.context, into: pad.context)
        try deliver(pad.context, into: phone.context)
        try ListenLedger.reconcile(in: phone.context)
        try ListenLedger.reconcile(in: pad.context)
        #expect(phone.item.playthroughCount == 0 && pad.item.playthroughCount == 0)
    }

    /// Review finding 10: two devices absorbing different donors into one
    /// keeper keep both, even when the keeper's lineage list is last-writer-wins.
    @Test func concurrentMergesIntoOneKeeperKeepBothDonors() throws {
        let store = try makeStore()
        let firstDonor = UUID(), secondDonor = UUID()
        for donor in [firstDonor, secondDonor] {
            try ListenLedger.record(.playthrough, trackID: donor, sessionID: "play-\(donor)", source: .playback, in: store.context)
            try ListenLedger.recordLineage(keeper: store.track.id, donor: donor, in: store.context)
        }
        store.track.absorbedTrackIDs = [secondDonor.uuidString]
        try ListenLedger.refreshAllCounts(in: store.context)
        #expect(store.item.playthroughCount == 2)
    }

    @Test func lineageIsTransitive() throws {
        let store = try makeStore()
        let middle = UUID(), original = UUID()
        try ListenLedger.record(.playthrough, trackID: original, sessionID: "old", source: .playback, in: store.context)
        try ListenLedger.recordLineage(keeper: middle, donor: original, in: store.context)
        try ListenLedger.recordLineage(keeper: store.track.id, donor: middle, in: store.context)
        try ListenLedger.refreshCounts(forTrackIDs: [store.track.id], in: store.context)
        #expect(store.item.playthroughCount == 1)
    }

    @Test func absorbedTrackEventsCountIncludingLateArrivals() throws {
        let store = try makeStore()
        let donorID = UUID()
        let donor = TrackRecord(id: donorID, catalogID: "1", title: "Song", artistName: "Artist")
        store.context.insert(donor)
        try ListenLedger.record(.playthrough, trackID: donorID, sessionID: "early", source: .playback, in: store.context)
        try ListenLedger.record(.playthrough, trackID: store.track.id, sessionID: "own", source: .playback, in: store.context)

        TrackIdentityMergeService.absorb(donor, into: store.track)
        store.context.delete(donor)
        try ListenLedger.refreshCounts(forTrackIDs: [store.track.id], in: store.context)
        #expect(store.item.playthroughCount == 2)

        // Another device counted the donor before it saw the merge.
        try ListenLedger.record(.playthrough, trackID: donorID, sessionID: "late", source: .playback, in: store.context)
        try ListenLedger.refreshAllCounts(in: store.context)
        #expect(store.item.playthroughCount == 3)
    }

    @Test func mergingDuplicateRowsOfOneTrackNeitherLosesNorDoubles() throws {
        let store = try makeStore(skips: 1, plays: 2)
        let duplicate = PlaylistItemRecord(playlistID: store.item.playlistID, trackID: store.track.id,
                                           skipCount: 0, playthroughCount: 3)
        store.context.insert(duplicate)
        try store.context.save()

        let merged = try PlaylistItemRepository.mergeDuplicateItems(in: store.context)

        #expect(merged == 1)
        let survivor = try #require(try PlaylistItemRepository.allItems(in: store.context).first { !$0.isDeleted })
        #expect(survivor.playthroughCount == 5)
        #expect(survivor.skipCount == 1)
        try ListenLedger.reconcile(in: store.context)
        #expect(survivor.playthroughCount == 5)
    }

    @Test func evaluatedSkipAndPlaythroughWriteLedgerEvents() throws {
        let store = try makeStore(skips: 2)
        let settings = OverplaySettings()
        let playlist = try #require(try PlaylistRepository.playlist(id: store.item.playlistID, in: store.context))
        let skip = TrackPlaySession(trackID: "1", localTrackID: store.track.id.uuidString, sessionStartDate: .now,
                                    lastObservedPlaybackTime: 20, listenedSeconds: 20, durationSeconds: 200, hasEvaluated: false)
        EvictionEngine.evaluateSkip(item: store.item, playlist: playlist, session: skip,
                                    transitionWasNaturalCompletion: false, settings: settings, context: store.context)
        EvictionEngine.evaluateSkip(item: store.item, playlist: playlist, session: skip,
                                    transitionWasNaturalCompletion: false, settings: settings, context: store.context)
        #expect(store.item.skipCount == 3)
        let kinds = try events(in: store.context).compactMap(\.kind)
        #expect(kinds.filter { $0 == .skip }.count == 1)
    }
}
