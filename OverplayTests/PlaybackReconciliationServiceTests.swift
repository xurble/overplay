import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("Playback reconciliation service")
struct PlaybackReconciliationServiceTests {
    @Test("background waypoint survives cancellation before metadata returns")
    func durableBeforeMetadata() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let observation = f.observation(0, position: 12)
        let fetcher = Fetcher { _ in
            let stored = try #require(PlaybackWaypointStore.load(from: f.defaults))
            #expect(stored.localTrackID == observation.localTrackID)
            #expect(stored.positionSeconds == 12)
            #expect(stored.recordedAt == observation.observedAt)
            throw CancellationError()
        }
        let result = await f.run(observation, capture: true, fetcher: fetcher)
        #expect(result.countedLocalTrackIDs.isEmpty)
        #expect(PlaybackWaypointStore.load(from: f.defaults)?.recordedAt == observation.observedAt)
    }

    @Test("background capture retains uncommitted continuity across cancellation, rollback and relaunch", arguments: [false, true])
    func backgroundCaptureRetainsContinuity(saveFails: Bool) async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        PlaybackWaypointStore.save(f.waypoint(0, position: 10), to: f.defaults)
        let incoming = f.observation(1, position: 10, offset: 100)
        let result = await PlaybackReconciliationService.reconcileAndCaptureWaypoint(
            observation: incoming, orderedTracks: f.order, context: f.context,
            captureBeforeFetching: true, defaults: f.defaults,
            musicLibraryFetcher: Fetcher { _ in
                if !saveFails { throw CancellationError() }
                return [:]
            },
            now: { incoming.observedAt },
            saveChanges: { _ in throw TestError.failed }
        )
        #expect(result.countedLocalTrackIDs.isEmpty)
        #expect(try ModelContext(f.container).fetch(FetchDescriptor<PlaylistItemRecord>()).allSatisfy { $0.playthroughCount == 0 })
        #expect(try ModelContext(f.container).fetch(FetchDescriptor<HistoryEvent>()).isEmpty)
        let captured = try #require(PlaybackWaypointStore.load(from: f.defaults))
        #expect(captured.localTrackID == f.ids[1])
        #expect(captured.pendingLocalPlaythroughs?.map(\.localTrackID) == [f.ids[0]])

        let reloaded = try #require(UserDefaults(suiteName: f.suite))
        let next = f.observation(2, position: 10, offset: 200)
        let recovered = await PlaybackReconciliationService.reconcileAndCaptureWaypoint(
            observation: next, orderedTracks: f.order, context: ModelContext(f.container),
            defaults: reloaded, musicLibraryFetcher: Fetcher.empty, now: { next.observedAt }
        )
        #expect(Set(recovered.countedLocalTrackIDs) == Set(f.ids.prefix(2)))
        #expect(try ModelContext(f.container).fetch(FetchDescriptor<HistoryEvent>()).count == 2)
        #expect(PlaybackWaypointStore.load(from: reloaded)?.pendingLocalPlaythroughs == nil)

        // Simulate termination after committing SwiftData but before clearing
        // pending proofs from defaults. Retrying must not duplicate credits.
        PlaybackWaypointStore.save(captured, to: reloaded)
        let replayed = await PlaybackReconciliationService.reconcileAndCaptureWaypoint(
            observation: next, orderedTracks: f.order, context: ModelContext(f.container),
            defaults: reloaded, musicLibraryFetcher: Fetcher.empty, now: { next.observedAt }
        )
        #expect(replayed.countedLocalTrackIDs.isEmpty)
        #expect(try ModelContext(f.container).fetch(FetchDescriptor<HistoryEvent>()).count == 2)
    }

    @Test("repeated interrupted captures preserve frozen proofs when later continuity is broken")
    func interruptedCapturesAccumulateProofs() async throws {
        let f = try Fixture(count: 4)
        defer { f.cleanUp() }
        PlaybackWaypointStore.save(f.waypoint(0, position: 10), to: f.defaults)
        let cancelled = Fetcher { _ in throw CancellationError() }
        await f.run(f.observation(1, position: 10, offset: 100), capture: true, fetcher: cancelled)
        await f.run(f.observation(2, position: 10, offset: 200), capture: true, fetcher: cancelled)
        let result = await f.run(f.observation(3, position: 10, offset: 2000))
        #expect(Set(result.countedLocalTrackIDs) == Set(f.ids.prefix(2)))
        #expect(try f.history().count == 2)
        #expect(PlaybackWaypointStore.load(from: f.defaults)?.pendingLocalPlaythroughs == nil)
    }

    @Test("an interrupted background point proof survives a later unprovable transition")
    func interruptedPointProof() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        await f.run(f.observation(0, position: 95), capture: true, fetcher: Fetcher { _ in throw CancellationError() })
        let result = await f.run(f.observation(1, position: 10, offset: 2000))
        #expect(result.countedLocalTrackIDs == [f.ids[0]])
        #expect(f.items[0].playthroughCount == 1)
        #expect(try f.history().first?.reconciliationMechanism == .pointObservation)
    }

    @Test("bounded pre-seeding recovers several tracks without a wake grant")
    func recoversWindow() async throws {
        let f = try Fixture(count: 25)
        defer { f.cleanUp() }
        let fetcher = Fetcher { candidates in
            #expect(Set(candidates.map(\.localTrackID)) == Set(f.ids.prefix(21)))
            return Dictionary(uniqueKeysWithValues: candidates.map { ($0.localTrackID, f.snapshot($0.localTrackID, count: 10)) })
        }
        await f.run(f.observation(0, position: 5), capture: true, fetcher: fetcher)
        #expect(PlaybackWaypointStore.load(from: f.defaults)?.allMusicLibraryBaselines.count == 21)
        let wake = f.observation(4, position: 20, offset: 2000) // deliberately breaks continuity
        let advanced = Fetcher { _ in
            Dictionary(uniqueKeysWithValues: f.ids.prefix(4).map {
                ($0, f.snapshot($0, count: 13, played: f.time.addingTimeInterval(100)))
            })
        }
        let result = await f.run(wake, fetcher: advanced)
        #expect(Set(result.countedLocalTrackIDs) == Set(f.ids.prefix(4)))
        #expect(f.items.prefix(4).allSatisfy { $0.playthroughCount == 1 }) // delta > 1 credits one
        #expect(try f.history().count == 4)
        await f.run(f.observation(4, position: 25, offset: 2005), fetcher: advanced)
        #expect(try f.history().count == 4)
    }

    @Test("point ledger survives repeated wakes and reloading defaults after process death")
    func pointLedgerAcrossRelaunch() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        await f.run(f.observation(0, position: 92))
        #expect(f.items[0].playthroughCount == 1)
        #expect(PlaybackWaypointStore.load(from: f.defaults)?.countedLocalTrackID == f.ids[0])
        let reloaded = try #require(UserDefaults(suiteName: f.suite))
        // Remove the secondary recency guard to specifically exercise the durable ledger.
        f.items[0].lastPlayedAt = nil
        try f.context.save()
        await PlaybackReconciliationService.reconcileAndCaptureWaypoint(
            observation: f.observation(0, position: 97, offset: 5),
            orderedTracks: f.order, context: f.context, defaults: reloaded,
            musicLibraryFetcher: Fetcher.empty
        )
        #expect(f.items[0].playthroughCount == 1)
        #expect(PlaybackWaypointStore.load(from: reloaded)?.countedLocalTrackID == f.ids[0])
    }

    @Test("library credit for the current track also carries the durable point ledger")
    func libraryCreditLedger() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        var baseline = f.waypoint(0, position: 1, offset: -100)
        baseline.musicLibrarySnapshot = f.snapshot(f.ids[0], count: 1)
        PlaybackWaypointStore.save(baseline, to: f.defaults)
        await f.run(f.observation(0, position: 10), fetcher: Fetcher { _ in
            [f.ids[0]: f.snapshot(f.ids[0], count: 2, played: f.time.addingTimeInterval(-10))]
        })
        #expect(f.items[0].playthroughCount == 1)
        #expect(PlaybackWaypointStore.load(from: f.defaults)?.countedLocalTrackID == f.ids[0])
        f.items[0].lastPlayedAt = nil
        try f.context.save()
        await f.run(f.observation(0, position: 95, offset: 85))
        #expect(f.items[0].playthroughCount == 1)
    }

    @Test("pending baselines accumulate without rebasing delayed evidence and expire before proof")
    func retainsAndExpiresBaselines() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let baselineFetcher = Fetcher { candidates in
            Dictionary(uniqueKeysWithValues: candidates.map { ($0.localTrackID, f.snapshot($0.localTrackID, count: 1)) })
        }
        await f.run(f.observation(0, position: 1), fetcher: baselineFetcher)
        await f.run(f.observation(1, position: 1, offset: 1000), fetcher: baselineFetcher)
        let stored = try #require(PlaybackWaypointStore.load(from: f.defaults))
        #expect(stored.allMusicLibraryBaselines.count == 2)
        #expect(stored.allMusicLibraryBaselines.first { $0.localTrackID == f.ids[0] }?.recordedAt == f.time)
        let expiredWake = f.observation(2, position: 1, offset: 90_000)
        let result = await f.run(expiredWake, fetcher: Fetcher { _ in
            [f.ids[0]: f.snapshot(f.ids[0], count: 2, played: f.time.addingTimeInterval(89_000))]
        })
        #expect(result.countedLocalTrackIDs.isEmpty)
        #expect(PlaybackWaypointStore.load(from: f.defaults)?.allMusicLibraryBaselines.isEmpty == true)
    }

    @Test("retention cap keeps the newly seeded window")
    func capsBaselines() async throws {
        let f = try Fixture(count: 65)
        defer { f.cleanUp() }
        let fetcher = Fetcher { candidates in
            Dictionary(uniqueKeysWithValues: candidates.map { ($0.localTrackID, f.snapshot($0.localTrackID, count: 1)) })
        }
        for index in [0, 21, 42] {
            await f.run(f.observation(index, position: 1, offset: Double(index * 1000)), capture: true, fetcher: fetcher)
        }
        let stored = try #require(PlaybackWaypointStore.load(from: f.defaults))
        #expect(stored.allMusicLibraryBaselines.count == PlaybackReconciliationService.maxPendingMusicLibraryBaselines)
        #expect(Set(f.ids[42...62]).isSubset(of: Set(stored.allMusicLibraryBaselines.map(\.localTrackID))))
    }

    @Test("overlapping reordered windows retain the current sample and its original evidence")
    func overlappingWindowsKeepCurrentBaseline() async throws {
        let f = try Fixture(count: 61)
        defer { f.cleanUp() }
        var waypoint = f.waypoint(40, position: 1)
        waypoint.pendingMusicLibraryBaselines = f.ids.prefix(41).map {
            .init(playlistID: f.playlist.musicPlaylistID, localTrackID: $0, recordedAt: f.time,
                  snapshot: f.snapshot($0, count: 1))
        }
        PlaybackWaypointStore.save(waypoint, to: f.defaults)
        let incoming = f.observation(0, position: 1, offset: 1000)
        let reordered = [f.order[0]] + Array(f.order[41...60]) + Array(f.order[1...40])
        await PlaybackReconciliationService.reconcileAndCaptureWaypoint(
            observation: incoming, orderedTracks: reordered, context: f.context,
            captureBeforeFetching: true, defaults: f.defaults,
            musicLibraryFetcher: Fetcher { candidates in
                Dictionary(uniqueKeysWithValues: candidates.map { ($0.localTrackID, f.snapshot($0.localTrackID, count: 1)) })
            }, now: { incoming.observedAt }
        )
        let stored = try #require(PlaybackWaypointStore.load(from: f.defaults))
        #expect(stored.allMusicLibraryBaselines.count == PlaybackReconciliationService.maxPendingMusicLibraryBaselines)
        #expect(Set([f.ids[0]] + Array(f.ids[41...60])).isSubset(of: Set(stored.allMusicLibraryBaselines.map(\.localTrackID))))
        let current = try #require(stored.allMusicLibraryBaselines.first { $0.localTrackID == f.ids[0] })
        #expect(current.recordedAt == f.time)
        #expect(current.snapshot.playCount == 1)
        let result = await f.run(f.observation(42, position: 1, offset: 5000), fetcher: Fetcher { _ in
            [f.ids[0]: f.snapshot(f.ids[0], count: 2, played: f.time.addingTimeInterval(2000))]
        })
        #expect(result.countedLocalTrackIDs == [f.ids[0]])
    }

    @Test("older async completion cannot regress waypoint or write counters")
    func rejectsOlderCompletion() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let newer = f.waypoint(1, position: 1, offset: 10)
        let result = await f.run(f.observation(0, position: 95), fetcher: Fetcher { _ in
            PlaybackWaypointStore.save(newer, to: f.defaults)
            return [:]
        })
        #expect(result.countedLocalTrackIDs.isEmpty)
        #expect(PlaybackWaypointStore.load(from: f.defaults) == newer)
        #expect(try f.history().isEmpty)
    }

    @Test("each durable recency guard prevents a duplicate credit")
    func recencyGuards() async throws {
        for proof in 0..<3 {
            let f = try Fixture()
            defer { f.cleanUp() }
            f.items[0].lastPlayedAt = f.time.addingTimeInterval(1)
            f.items[0].playthroughCount = 1
            try f.context.save()
            var baseline = f.waypoint(0, position: 10)
            if proof == 1 {
                baseline.musicLibrarySnapshot = f.snapshot(f.ids[0], count: 1)
            }
            PlaybackWaypointStore.save(baseline, to: f.defaults)
            let observation = proof == 2
                ? f.observation(0, position: 95, offset: 85)
                : f.observation(1, position: 10, offset: proof == 0 ? 100 : 1000)
            let result = await f.run(observation, fetcher: Fetcher { _ in
                [f.ids[0]: f.snapshot(f.ids[0], count: 2, played: f.time.addingTimeInterval(50))]
            })
            #expect(result.countedLocalTrackIDs.isEmpty)
            #expect(f.items[0].playthroughCount == 1)
            #expect(try f.history().isEmpty)
        }
    }

    @Test("live evaluated session suppresses point credit and persists its ledger")
    func liveSessionGuard() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let result = await PlaybackReconciliationService.reconcileAndCaptureWaypoint(
            observation: f.observation(0, position: 95), orderedTracks: f.order,
            context: f.context, defaults: f.defaults, musicLibraryFetcher: Fetcher.empty,
            activeSessionHasEvaluated: { $0 == f.ids[0] }
        )
        #expect(result.countedLocalTrackIDs.isEmpty)
        #expect(PlaybackWaypointStore.load(from: f.defaults)?.countedLocalTrackID == f.ids[0])
    }

    @Test("save failure rolls back counters and history and preserves retry evidence")
    func persistenceFailure() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let baseline = f.waypoint(0, position: 1, offset: -90)
        PlaybackWaypointStore.save(baseline, to: f.defaults)
        let result = await PlaybackReconciliationService.reconcileAndCaptureWaypoint(
            observation: f.observation(0, position: 95), orderedTracks: f.order,
            context: f.context, defaults: f.defaults, musicLibraryFetcher: Fetcher.empty,
            saveChanges: { _ in throw TestError.failed }
        )
        #expect(result.countedLocalTrackIDs.isEmpty)
        let persisted = try ModelContext(f.container).fetch(FetchDescriptor<PlaylistItemRecord>())
        #expect(persisted.allSatisfy { $0.playthroughCount == 0 })
        // Rollback invalidates previously registered model references. Check
        // the store and refetched models, as a new wake/process would.
        #expect(try f.context.fetch(FetchDescriptor<PlaylistItemRecord>()).allSatisfy { $0.playthroughCount == 0 })
        #expect(try f.history().isEmpty)
        #expect(PlaybackWaypointStore.load(from: f.defaults) == baseline)
        await f.run(f.observation(0, position: 96, offset: 1))
        let retried = try ModelContext(f.container).fetch(FetchDescriptor<PlaylistItemRecord>())
        #expect(retried.first { $0.trackID.uuidString == f.ids[0] }?.playthroughCount == 1)
        #expect(try f.history().count == 1)
    }

    @Test("unavailable metadata still allows local point proof")
    func failedMetadata() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        await f.run(f.observation(0, position: 95), fetcher: Fetcher { _ in throw TestError.failed })
        #expect(f.items[0].playthroughCount == 1)
    }

    @Test("unknown shuffled order cannot produce continuity credits")
    func shuffledOrder() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        PlaybackWaypointStore.save(f.waypoint(0, position: 10), to: f.defaults)
        let result = await PlaybackReconciliationService.reconcileAndCaptureWaypoint(
            observation: f.observation(1, position: 10, offset: 100), orderedTracks: f.order,
            context: f.context, continuityAllowed: false, defaults: f.defaults,
            musicLibraryFetcher: Fetcher.empty
        )
        #expect(result.countedLocalTrackIDs.isEmpty)
    }

    @Test("stale evaluation followed by recovery produces only the proven outcome")
    func staleHistory() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        EvictionEngine.evaluateSkip(
            item: f.items[0], playlist: f.playlist,
            session: TrackPlaySession(trackID: f.ids[0], sessionStartDate: f.time,
                                      lastObservedPlaybackTime: 20, durationSeconds: 100, hasEvaluated: false),
            transitionWasNaturalCompletion: false, observationIsStale: true,
            settings: f.settings, context: f.context
        )
        await f.run(f.observation(0, position: 95))
        let history = try f.history()
        #expect(history.count == 1)
        #expect(history.first?.eventType == .playthrough)
        #expect(history.first?.source == .reconciled)
    }

    private enum TestError: Error { case failed }

    @MainActor
    private struct Fetcher: MusicLibraryPlaybackHistoryFetching {
        var fetch: ([MusicLibraryPlaybackCandidate]) async throws -> [String: MusicLibraryPlaybackSnapshot]
        func snapshots(for candidates: [MusicLibraryPlaybackCandidate]) async throws -> [String: MusicLibraryPlaybackSnapshot] {
            try await fetch(candidates)
        }
        static var empty: Self { Self { _ in [:] } }
    }

    @MainActor
    private final class Fixture {
        let container: ModelContainer
        var context: ModelContext { container.mainContext }
        let suite = "reconciliation-tests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let time = Date().addingTimeInterval(-100_000)
        let playlist = PlaylistRecord(musicPlaylistID: "reconciliation-playlist", name: "Test", role: .oneTruePlaylist)
        let settings = OverplaySettings()
        var tracks: [TrackRecord] = []
        var items: [PlaylistItemRecord] = []
        var ids: [String] { tracks.map { $0.id.uuidString } }
        var order: [PlaybackReconciliationPolicy.OrderedTrack] {
            ids.map { .init(localTrackID: $0, durationSeconds: 100) }
        }
        init(count: Int = 3) throws {
            defaults = UserDefaults(suiteName: suite)!
            container = try OverplayTestSupport.makeModelContainer()
            context.insert(playlist)
            context.insert(settings)
            for index in 0..<count {
                let track = TrackRecord(libraryID: "library-\(index)", title: "Track \(index)", artistName: "Artist", durationSeconds: 100)
                let item = PlaylistItemRecord(playlistID: playlist.id, trackID: track.id)
                context.insert(track)
                context.insert(item)
                tracks.append(track)
                items.append(item)
            }
            try context.save()
        }
        func cleanUp() { defaults.removePersistentDomain(forName: suite) }
        func observation(_ index: Int, position: Double, offset: Double = 0) -> PlaybackReconciliationPolicy.Observation {
            .init(playlistID: playlist.musicPlaylistID, localTrackID: ids[index], positionSeconds: position,
                  durationSeconds: 100, observedAt: time.addingTimeInterval(offset))
        }
        func waypoint(_ index: Int, position: Double, offset: Double = 0) -> PlaybackWaypoint {
            .init(playlistID: playlist.musicPlaylistID, localTrackID: ids[index], positionSeconds: position,
                  durationSeconds: 100, recordedAt: time.addingTimeInterval(offset))
        }
        func snapshot(_ id: String, count: Int, played: Date? = nil) -> MusicLibraryPlaybackSnapshot {
            .init(musicItemID: id, playCount: count, lastPlayedDate: played)
        }
        func history() throws -> [HistoryEvent] { try context.fetch(FetchDescriptor<HistoryEvent>()) }
        @discardableResult
        func run(_ observation: PlaybackReconciliationPolicy.Observation, capture: Bool = false,
                 fetcher: Fetcher = .empty) async -> PlaybackReconciliationService.Result {
            await PlaybackReconciliationService.reconcileAndCaptureWaypoint(
                observation: observation, orderedTracks: order, context: context,
                captureBeforeFetching: capture, defaults: defaults, musicLibraryFetcher: fetcher,
                now: { observation.observedAt }
            )
        }
    }
}
