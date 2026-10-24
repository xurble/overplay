import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
struct LibraryRestorationTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "LibraryRestorationTests.\(UUID())")!
    }

    private func seed(_ context: ModelContext) throws -> OverplaySettings {
        let settings = OverplaySettings(selectedPlaylistID: "p.otp", selectedPlaylistName: "Overplay")
        settings.completedRebuildID = UUID()
        context.insert(settings)
        context.insert(PlaylistRecord(musicPlaylistID: "p.otp", name: "Overplay", role: .oneTruePlaylist, writePolicy: .managed))
        context.insert(PlaylistRecord(musicPlaylistID: PlaylistRecord.triageBucketMusicPlaylistID,
                                      name: "Triage", role: .triageBucket, writePolicy: .incomingOnly))
        try context.save()
        return settings
    }

    @Test func emptyAndFailedCloudImportsNeverCreateConfiguration() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let service = LibraryRestorationService(defaults: defaults())
        for error in [nil, "No iCloud account"] as [String?] {
            service.cloudImportFinished(error: error)
            await #expect(throws: (any Error).self) {
                try await service.prepare(in: container.mainContext, hasLegacyStore: true, locallyRebuiltID: nil, attempts: 1)
            }
            #expect(!service.isReady)
            #expect(!service.canCreateLibrary)
            #expect(try LibraryRestorationService.isEmpty(in: container.mainContext))
            #expect(!container.mainContext.hasChanges)
        }
    }

    @Test func cloudReceiptAloneDoesNotUnlockAnIncompleteConfiguration() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let settings = OverplaySettings(selectedPlaylistID: "p.otp")
        settings.completedRebuildID = UUID()
        container.mainContext.insert(settings)
        try container.mainContext.save()
        let service = LibraryRestorationService(defaults: defaults())
        service.cloudImportFinished(error: nil)
        await #expect(throws: (any Error).self) {
            try await service.prepare(in: container.mainContext, hasLegacyStore: true, locallyRebuiltID: nil, attempts: 1)
        }
        #expect(!service.isReady)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<PlaylistRecord>()) == 0)
    }

    @Test func partialDeliveryWaitsForMissingReferencesWithoutRepairingThem() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        _ = try seed(container.mainContext)
        let playlist = try #require(try container.mainContext.fetch(FetchDescriptor<PlaylistRecord>()).first)
        let track = TrackRecord(libraryID: "i.song", title: "Song", artistName: "Artist")
        let item = PlaylistItemRecord(playlistID: playlist.id, trackID: track.id)
        item.sourceMusicPlaylistIDs = ["p.source"]
        container.mainContext.insert(item)
        try container.mainContext.save()
        let service = LibraryRestorationService(defaults: defaults())
        service.cloudImportFinished(error: nil)
        var waits = 0
        try await service.prepare(in: container.mainContext, hasLegacyStore: true, locallyRebuiltID: nil, attempts: 2) {
            #expect(!service.isReady)
            #expect(!container.mainContext.hasChanges)
            waits += 1
            container.mainContext.insert(track)
            container.mainContext.insert(PlaylistRecord(musicPlaylistID: "p.source", name: "Source",
                role: .triageSource, writePolicy: .incomingOnly))
            try container.mainContext.save()
        }
        #expect(waits == 1)
        #expect(service.isReady)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<OverplaySettings>()) == 1)
    }

    /// 2026-10-23: a membership written again by another device after a
    /// merge deleted its track kept every launch waiting for that track.
    @Test func aMembershipLeftByAMergeDoesNotKeepRestorationWaiting() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        _ = try seed(context)
        let playlist = try #require(try context.fetch(FetchDescriptor<PlaylistRecord>()).first)
        let keeper = TrackRecord(libraryID: "i.keeper", title: "Song", artistName: "Artist")
        context.insert(keeper)
        context.insert(PlaylistItemRecord(playlistID: playlist.id, trackID: keeper.id))
        let mergedAway = UUID()
        let leftover = PlaylistItemRecord(playlistID: playlist.id, trackID: mergedAway)
        context.insert(leftover)
        try context.save()
        // Without a merge record it may still be arriving: keep waiting.
        #expect(try LibraryRestorationService.restoredSettings(in: context) == nil)

        try ListenLedger.recordLineage(keeper: keeper.id, donor: mergedAway, in: context)
        try context.save()
        #expect(try LibraryRestorationService.restoredSettings(in: context) != nil)

        // Startup's repair folds it into the keeper's membership, and leaves
        // a membership still arriving alone (`LOC-002`).
        let stillArriving = PlaylistItemRecord(playlistID: playlist.id, trackID: UUID())
        context.insert(stillArriving)
        #expect(try PlaylistItemRepository.repairMergeLeftovers(in: context) == 1)
        try context.save()
        let remaining = try PlaylistItemRepository.allItems(in: context).map(\.trackID)
        #expect(remaining.count == 2)
        #expect(Set(remaining) == [keeper.id, stillArriving.trackID])
    }

    /// The survivor must be here too: otherwise the song may have no
    /// membership until it arrives (`LOC-002`).
    @Test func aMembershipLeftByAMergeWaitsForItsSurvivor() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        _ = try seed(context)
        let playlist = try #require(try context.fetch(FetchDescriptor<PlaylistRecord>()).first)
        let mergedAway = UUID()
        context.insert(PlaylistItemRecord(playlistID: playlist.id, trackID: mergedAway))
        let survivor = TrackRecord(libraryID: "i.survivor", title: "Song", artistName: "Artist")
        try ListenLedger.recordLineage(keeper: survivor.id, donor: mergedAway, in: context)
        try context.save()
        #expect(try LibraryRestorationService.restoredSettings(in: context) == nil)

        context.insert(survivor)
        try context.save()
        #expect(try LibraryRestorationService.restoredSettings(in: context) != nil)
    }

    /// Only the leftover's track is excused: a playlist it names that has not
    /// arrived is still waited for.
    @Test func aMembershipLeftByAMergeStillWaitsForItsPlaylist() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        _ = try seed(context)
        let keeper = TrackRecord(libraryID: "i.keeper", title: "Song", artistName: "Artist")
        context.insert(keeper)
        let mergedAway = UUID()
        context.insert(PlaylistItemRecord(playlistID: UUID(), trackID: mergedAway))
        try ListenLedger.recordLineage(keeper: keeper.id, donor: mergedAway, in: context)
        try context.save()

        #expect(try LibraryRestorationService.restoredSettings(in: context) == nil)
    }

    /// Only a membership whose track is missing is excused: one of a donor
    /// track that exists again is still checked.
    @Test func aMergedAwayTrackThatExistsIsStillChecked() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        _ = try seed(context)
        let playlist = try #require(try context.fetch(FetchDescriptor<PlaylistRecord>()).first)
        let keeper = TrackRecord(libraryID: "i.keeper", title: "Song", artistName: "Artist")
        let donor = TrackRecord(libraryID: "i.donor", title: "Song", artistName: "Artist")
        context.insert(keeper)
        context.insert(donor)
        context.insert(PlaylistItemRecord(playlistID: playlist.id, trackID: keeper.id))
        let mergedAway = UUID()
        context.insert(PlaylistItemRecord(playlistID: playlist.id, trackID: mergedAway))
        // Its playlist has not arrived yet.
        context.insert(PlaylistItemRecord(playlistID: UUID(), trackID: donor.id))
        try ListenLedger.recordLineage(keeper: keeper.id, donor: mergedAway, in: context)
        try ListenLedger.recordLineage(keeper: keeper.id, donor: donor.id, in: context)
        try context.save()

        #expect(try LibraryRestorationService.restoredSettings(in: context) == nil)
    }

    @Test func successfulRestorationAllowsOfflineRestartButNotANewStore() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        _ = try seed(container.mainContext)
        let local = defaults()
        let first = LibraryRestorationService(defaults: local)
        await #expect(throws: (any Error).self) {
            try await first.prepare(in: container.mainContext, hasLegacyStore: true, locallyRebuiltID: nil, attempts: 1)
        }
        first.cloudImportFinished(error: nil)
        try await first.prepare(in: container.mainContext, hasLegacyStore: true, locallyRebuiltID: nil, attempts: 1)
        let restart = LibraryRestorationService(defaults: local)
        try await restart.prepare(in: container.mainContext, hasLegacyStore: true, locallyRebuiltID: nil, attempts: 1)
        #expect(restart.isReady)
        let empty = try OverplayTestSupport.makeModelContainer()
        let restoredDefaultsOnly = LibraryRestorationService(defaults: local)
        await #expect(throws: (any Error).self) {
            try await restoredDefaultsOnly.prepare(in: empty.mainContext, hasLegacyStore: true, locallyRebuiltID: nil, attempts: 1)
        }
        #expect(!restoredDefaultsOnly.isReady)
    }

    @Test func explicitLocalCutoverCanOpenWithoutWaitingForItsOwnCloudUpload() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let settings = try seed(container.mainContext)
        let service = LibraryRestorationService(defaults: defaults())
        try await service.prepare(in: container.mainContext, hasLegacyStore: true,
                                  locallyRebuiltID: settings.completedRebuildID, attempts: 1)
        #expect(service.isReady)
    }

    @Test func newSetupRequiresExplicitActionAndRechecksForLateCloudData() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let service = LibraryRestorationService(defaults: defaults())
        service.cloudImportFinished(error: nil)
        await #expect(throws: (any Error).self) {
            try await service.prepare(in: container.mainContext, hasLegacyStore: false, locallyRebuiltID: nil, attempts: 1)
        }
        #expect(service.canCreateLibrary)
        #expect(try LibraryRestorationService.isEmpty(in: container.mainContext))
        _ = try seed(container.mainContext)
        #expect(throws: (any Error).self) { try service.createLibrary(in: container.mainContext, hasLegacyStore: false) }
        #expect(try container.mainContext.fetchCount(FetchDescriptor<OverplaySettings>()) == 1)
    }

    @Test func explicitFirstTimeSetupCreatesExactlyOneConfiguration() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let service = LibraryRestorationService(defaults: defaults())
        service.cloudImportFinished(error: nil)
        await #expect(throws: (any Error).self) {
            try await service.prepare(in: container.mainContext, hasLegacyStore: false, locallyRebuiltID: nil, attempts: 1)
        }
        try service.createLibrary(in: container.mainContext, hasLegacyStore: false)
        #expect(service.isReady)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<OverplaySettings>()) == 1)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<PlaylistRecord>()) == 1)
        #expect(throws: (any Error).self) { try service.createLibrary(in: container.mainContext, hasLegacyStore: false) }
    }

    @Test("an empty store that may start a library goes to setup without waiting")
    func emptyStoreGoesToSetupWithoutWaiting() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        var waits = 0
        func prepare(_ service: LibraryRestorationService, cloudEnabled: Bool) async throws {
            try await service.prepare(in: container.mainContext, cloudEnabled: cloudEnabled, hasLegacyStore: false,
                                      locallyRebuiltID: nil, attempts: 3) { waits += 1 }
        }

        let local = LibraryRestorationService(defaults: defaults())
        await #expect(throws: LibraryRestorationService.RestorationError.setupNeeded) { try await prepare(local, cloudEnabled: false) }
        #expect(waits == 0)

        // With iCloud, an empty store proves nothing until an import finishes.
        let cloud = LibraryRestorationService(defaults: defaults())
        await #expect(throws: LibraryRestorationService.RestorationError.waitingForCloud) { try await prepare(cloud, cloudEnabled: true) }
        #expect(waits == 2)
        cloud.cloudImportFinished(error: nil)
        await #expect(throws: LibraryRestorationService.RestorationError.setupNeeded) { try await prepare(cloud, cloudEnabled: true) }
        #expect(waits == 2)
        #expect(!container.mainContext.hasChanges)
        #expect(try LibraryRestorationService.isEmpty(in: container.mainContext))
    }

    @Test("iCloud with no library goes to setup at once, before any import")
    func emptyCloudGoesStraightToSetup() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let service = LibraryRestorationService(defaults: defaults())
        var checks = 0
        var waits = 0
        await #expect(throws: LibraryRestorationService.RestorationError.setupNeeded) {
            try await service.prepare(in: container.mainContext, cloudEnabled: true, hasLegacyStore: false,
                                      locallyRebuiltID: nil, attempts: 3, wait: { waits += 1 },
                                      checkCloudLibrary: { checks += 1; return .empty })
        }
        #expect(checks == 1 && waits == 0)
        #expect(service.canCreateLibrary)
    }

    @Test("a library in iCloud is restored, however long it takes, and never offers setup")
    func libraryInCloudNeverOffersSetup() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let service = LibraryRestorationService(defaults: defaults())
        var checks = 0
        var waits = 0
        func prepare() async throws {
            try await service.prepare(in: container.mainContext, cloudEnabled: true, hasLegacyStore: false,
                                      locallyRebuiltID: nil, attempts: 3, wait: { waits += 1 },
                                      checkCloudLibrary: { checks += 1; return .exists })
        }
        // Before any import: no 30-second wait, no Retry.
        await #expect(throws: LibraryRestorationService.RestorationError.restoringFromCloud) { try await prepare() }
        #expect(waits == 0)
        // An import that delivered nothing yet still does not make it a first run.
        service.cloudImportFinished(error: nil)
        await #expect(throws: LibraryRestorationService.RestorationError.restoringFromCloud) { try await prepare() }
        #expect(!service.canCreateLibrary)
        #expect(checks == 1)
        #expect(throws: LibraryRestorationService.RestorationError.existingLibrary) {
            try service.createLibrary(in: container.mainContext, hasLegacyStore: false)
        }
        // The library arrives.
        _ = try seed(container.mainContext)
        try await prepare()
        #expect(service.isReady)
    }

    @Test("an unanswered iCloud check is asked again and falls back to waiting for an import")
    func unansweredCheckFallsBackToImports() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let service = LibraryRestorationService(defaults: defaults())
        var checks = 0
        func prepare() async throws {
            try await service.prepare(in: container.mainContext, cloudEnabled: true, hasLegacyStore: false,
                                      locallyRebuiltID: nil, attempts: 1,
                                      checkCloudLibrary: { checks += 1; return .unknown })
        }
        await #expect(throws: LibraryRestorationService.RestorationError.waitingForCloud) { try await prepare() }
        service.cloudImportFinished(error: nil)
        await #expect(throws: LibraryRestorationService.RestorationError.setupNeeded) { try await prepare() }
        #expect(checks == 2)
    }

    @Test("a library waiting for its One True Playlist from an iPhone is restored")
    func libraryWithARequestedOneTruePlaylistIsRestored() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let settings = OverplaySettings()
        settings.pendingOneTruePlaylistRequestedAt = .now
        context.insert(settings)
        context.insert(PlaylistRecord(musicPlaylistID: PlaylistRecord.triageBucketMusicPlaylistID,
                                      name: "Triage", role: .triageBucket, writePolicy: .incomingOnly))
        try context.save()
        let service = LibraryRestorationService(defaults: defaults())
        service.cloudImportFinished(error: nil)
        try await service.prepare(in: context, cloudEnabled: true, hasLegacyStore: false, locallyRebuiltID: nil, attempts: 1)
        #expect(service.isReady)
    }

    @Test("listen history and Recents alone make a store non-empty")
    func listenHistoryAndRecentsAreNotEmpty() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        context.insert(ListenEvent(trackID: UUID(), kind: .playthrough, sessionID: "s", deviceID: "d", source: .playback))
        try context.save()
        #expect(try !LibraryRestorationService.isEmpty(in: context))
    }
}
