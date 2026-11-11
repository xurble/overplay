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

    // MARK: - Finding DI-4: duplicate settings rows

    /// A saved library with a One True Playlist and the Inbox, and no settings.
    private func seedPlaylists(_ context: ModelContext) throws {
        context.insert(PlaylistRecord(musicPlaylistID: "p.otp", name: "Overplay", role: .oneTruePlaylist, writePolicy: .managed))
        context.insert(PlaylistRecord(musicPlaylistID: PlaylistRecord.triageBucketMusicPlaylistID,
                                      name: "Triage", role: .triageBucket, writePolicy: .incomingOnly))
        try context.save()
    }

    /// A fresh context, kept by the caller, sees what restoration saved.
    private func settingsRows(_ read: ModelContext) throws -> [OverplaySettings] {
        try read.fetch(FetchDescriptor<OverplaySettings>())
    }

    private func prepareAfterImport(_ service: LibraryRestorationService, _ container: ModelContainer) async throws {
        service.cloudImportFinished(error: nil)
        try await service.prepare(in: container.mainContext, cloudEnabled: true, hasLegacyStore: true,
                                  locallyRebuiltID: nil, attempts: 1)
    }

    /// Restoration reads the kept row and leaves the others; they go only
    /// once an import has settled on a ready device.
    @Test("two settings rows restore from the oldest, and converge on it only after an import")
    func duplicateSettingsRestoreAndConvergeAfterImport() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let oldest = try seed(context)
        oldest.createdAt = Date(timeIntervalSince1970: 1_000)
        let newer = OverplaySettings(createdAt: Date(timeIntervalSince1970: 2_000))
        context.insert(newer)
        try context.save()

        let service = LibraryRestorationService(defaults: defaults())
        try await prepareAfterImport(service, container)

        #expect(service.isReady)
        #expect(Set(try settingsRows(ModelContext(container)).map(\.id)) == [oldest.id, newer.id],
                "Restoration deleted a row")

        let convergence = try service.convergeSettingsAfterImport(in: context)
        #expect(convergence?.removedIDs == [newer.id])
        let rows = try settingsRows(ModelContext(container))
        #expect(rows.map(\.id) == [oldest.id])
        #expect(rows.first?.selectedPlaylistID == "p.otp")
    }

    @Test("rows created at the same moment converge on the lowest UUID")
    func duplicateSettingsTieBreakOnUUID() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        try seedPlaylists(context)
        let created = Date(timeIntervalSince1970: 1_000)
        let high = OverplaySettings(id: UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000000")!,
                                    selectedPlaylistID: "p.otp", createdAt: created)
        let low = OverplaySettings(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                                   selectedPlaylistID: "p.otp", createdAt: created)
        context.insert(high)
        context.insert(low)
        try context.save()

        let service = LibraryRestorationService(defaults: defaults())
        try await prepareAfterImport(service, container)
        try service.convergeSettingsAfterImport(in: context)

        let read = ModelContext(container)
        #expect(try settingsRows(read).map(\.id) == [low.id])
    }

    /// The device that set up the newer row opens from its receipt, then the
    /// older, blank row takes its configuration.
    @Test("the kept row takes what only the removed row knew, and this device's receipt moves to it")
    func convergenceKeepsTheRemovedRowsConfiguration() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        try seedPlaylists(context)
        let blank = OverplaySettings(createdAt: Date(timeIntervalSince1970: 1_000))
        let configured = OverplaySettings(selectedPlaylistID: "p.otp", selectedPlaylistName: "Overplay",
                                          createdAt: Date(timeIntervalSince1970: 2_000))
        let rebuildID = UUID()
        configured.completedRebuildID = rebuildID
        let requested = Date(timeIntervalSince1970: 3_000)
        configured.pendingOneTruePlaylistRequestedAt = requested
        configured.pendingOneTruePlaylistSourceID = "p.source"
        configured.pendingOneTruePlaylistSourceName = "Source"
        context.insert(blank)
        context.insert(configured)
        try context.save()
        let receipts = defaults()
        LibraryRestorationService.recordLocalConfiguration(configured, defaults: receipts)

        let service = LibraryRestorationService(defaults: receipts)
        try await prepareAfterImport(service, container)
        #expect(service.isReady)
        try service.convergeSettingsAfterImport(in: context)

        let read = ModelContext(container)
        let kept = try #require(try settingsRows(read).first)
        #expect(try settingsRows(read).count == 1)
        #expect(kept.id == blank.id)
        #expect(kept.selectedPlaylistID == "p.otp" && kept.selectedPlaylistName == "Overplay")
        #expect(kept.completedRebuildID == rebuildID)
        #expect(kept.pendingOneTruePlaylistRequestedAt == requested)
        #expect(kept.pendingOneTruePlaylistSourceID == "p.source")
        #expect(kept.pendingOneTruePlaylistSourceName == "Source")
        #expect(receipts.string(forKey: "overplay.v2.restoredSettingsID") == blank.id.uuidString)
    }

    @Test("a selection naming a playlist that is gone gives way to one that is here")
    func convergencePrefersASelectionThatResolves() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        try seedPlaylists(context)
        let blank = OverplaySettings(createdAt: Date(timeIntervalSince1970: 500))
        let stale = OverplaySettings(selectedPlaylistID: "p.deleted", selectedPlaylistName: "Old",
                                     createdAt: Date(timeIntervalSince1970: 1_000))
        let current = OverplaySettings(selectedPlaylistID: "p.otp", selectedPlaylistName: "Overplay",
                                       createdAt: Date(timeIntervalSince1970: 2_000))
        for row in [blank, stale, current] { context.insert(row) }
        try context.save()

        let convergence = try #require(try SettingsRepository.convergeDuplicates(in: context))
        #expect(convergence.keeper.id == blank.id)
        #expect(blank.selectedPlaylistID == "p.otp" && blank.selectedPlaylistName == "Overplay")
    }

    /// PR #122 review, finding 1: device A ran Nuke Database (delete all,
    /// then a new row N). This device has some of the deletions and N, but
    /// not yet the old row O's deletion. Deleting N here would sync, then
    /// O's deletion would leave no row on any device, and every device
    /// would wait for good.
    @Test("a Nuke Database's new row arriving before the old row's deletion is never deleted")
    func nukeOrderingKeepsTheNewRow() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let old = try seed(context)
        old.createdAt = Date(timeIntervalSince1970: 1_000)
        try context.save()
        let receipts = defaults()
        LibraryRestorationService.recordLocalConfiguration(old, defaults: receipts)
        // Some deletions arrive: the old One True Playlist goes, so O's
        // library is incomplete. Then N and its Inbox arrive.
        let oldOTP = try #require(try context.fetch(FetchDescriptor<PlaylistRecord>()).first { $0.role == .oneTruePlaylist })
        context.delete(oldOTP)
        let new = OverplaySettings(createdAt: Date(timeIntervalSince1970: 9_000))
        context.insert(new)
        context.insert(PlaylistRecord(musicPlaylistID: PlaylistRecord.triageBucketMusicPlaylistID,
                                      name: "Triage", role: .triageBucket, writePolicy: .incomingOnly))
        try context.save()

        let service = LibraryRestorationService(defaults: receipts)
        await #expect(throws: (any Error).self) { try await prepareAfterImport(service, container) }
        #expect(!service.isReady)
        #expect(try service.convergeSettingsAfterImport(in: context) == nil)
        #expect(Set(try settingsRows(ModelContext(container)).map(\.id)) == [old.id, new.id])

        // O's deletion lands: N is still here, and once A picks its One True
        // Playlist this device restores from it.
        context.delete(try #require(try context.fetch(FetchDescriptor<OverplaySettings>()).first { $0.id == old.id }))
        try context.save()
        #expect(try settingsRows(ModelContext(container)).map(\.id) == [new.id])
        new.selectedPlaylistID = "p.new"
        context.insert(PlaylistRecord(musicPlaylistID: "p.new", name: "Overplay", role: .oneTruePlaylist, writePolicy: .managed))
        try context.save()
        try await prepareAfterImport(service, container)
        #expect(service.isReady)
    }

    /// Finding 1: nothing is deleted while an import may still be arriving.
    @Test("duplicate rows are deleted only on a ready device, after a clean import, with the kept row's library complete")
    func convergenceWaitsUntilTheLibraryHasSettled() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let oldest = try seed(context)
        oldest.createdAt = Date(timeIntervalSince1970: 1_000)
        let newer = OverplaySettings(selectedPlaylistID: "p.otp", createdAt: Date(timeIntervalSince1970: 2_000))
        context.insert(newer)
        try context.save()
        func rowCount() throws -> Int { try settingsRows(ModelContext(container)).count }

        // Not ready, even after a clean import of a complete library.
        let notReady = LibraryRestorationService(defaults: defaults())
        notReady.cloudImportFinished(error: nil)
        #expect(try notReady.convergeSettingsAfterImport(in: context) == nil)
        #expect(try rowCount() == 2)

        let service = LibraryRestorationService(defaults: defaults())
        try await service.prepare(in: context, cloudEnabled: false, hasLegacyStore: true, locallyRebuiltID: nil, attempts: 1)
        #expect(service.isReady)
        #expect(try rowCount() == 2)
        // Ready, but no import yet.
        #expect(try service.convergeSettingsAfterImport(in: context) == nil)
        // The last import failed.
        service.cloudImportFinished(error: nil)
        service.cloudImportFinished(error: "Network")
        #expect(try service.convergeSettingsAfterImport(in: context) == nil)
        // A clean import, but the kept row's library is still arriving.
        service.cloudImportFinished(error: nil)
        let playlist = try #require(try context.fetch(FetchDescriptor<PlaylistRecord>()).first)
        let arriving = PlaylistItemRecord(playlistID: playlist.id, trackID: UUID())
        context.insert(arriving)
        try context.save()
        #expect(try service.convergeSettingsAfterImport(in: context) == nil)
        #expect(try rowCount() == 2)
        // It arrives.
        context.delete(arriving)
        try context.save()
        #expect(try service.convergeSettingsAfterImport(in: context)?.removedIDs == [newer.id])
        #expect(try rowCount() == 1)
    }

    /// PR #122 review, finding 2: two devices set up at once, each with its
    /// own One True Playlist. The one not kept goes into the Inbox, so no song
    /// is left in a playlist nothing shows.
    @Test("converging two rows that each chose a One True Playlist leaves exactly one")
    func convergenceDemotesTheOtherOneTruePlaylist() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        try seedPlaylists(context)
        let other = PlaylistRecord(musicPlaylistID: "p.other", name: "Overplay", role: .oneTruePlaylist, writePolicy: .managed)
        context.insert(other)
        let track = TrackRecord(libraryID: "i.song", title: "Song", artistName: "Artist")
        context.insert(track)
        context.insert(PlaylistItemRecord(playlistID: other.id, trackID: track.id))
        let first = OverplaySettings(selectedPlaylistID: "p.otp", selectedPlaylistName: "Overplay",
                                     createdAt: Date(timeIntervalSince1970: 1_000))
        let second = OverplaySettings(selectedPlaylistID: "p.other", selectedPlaylistName: "Overplay",
                                      createdAt: Date(timeIntervalSince1970: 2_000))
        context.insert(first)
        context.insert(second)
        try context.save()

        let service = LibraryRestorationService(defaults: defaults())
        try await prepareAfterImport(service, container)
        try service.convergeSettingsAfterImport(in: context)

        let read = ModelContext(container)
        let playlists = try read.fetch(FetchDescriptor<PlaylistRecord>())
        let oneTruePlaylists = playlists.filter { $0.isActive && $0.role == .oneTruePlaylist }
        #expect(oneTruePlaylists.map(\.musicPlaylistID) == ["p.otp"])
        #expect(try PlaylistRepository.oneTruePlaylist(in: read)?.musicPlaylistID == "p.otp")
        let demoted = try #require(playlists.first { $0.musicPlaylistID == "p.other" })
        #expect(demoted.role == .triageSource)
        let inbox = try #require(playlists.first { $0.isTriageBucket })
        let item = try #require(try read.fetch(FetchDescriptor<PlaylistItemRecord>()).first { $0.trackID == track.id })
        #expect(item.playlistID == inbox.id)
        #expect(item.sourceMusicPlaylistIDs.contains("p.other"))
    }

    @Test("a device whose receipt names a duplicate row opens offline, and keeps the kept row's receipt")
    func aReceiptForADuplicateRowOpensOffline() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let oldest = try seed(context)
        oldest.createdAt = Date(timeIntervalSince1970: 1_000)
        let accepted = OverplaySettings(selectedPlaylistID: "p.otp", createdAt: Date(timeIntervalSince1970: 2_000))
        context.insert(accepted)
        try context.save()
        let receipts = defaults()
        LibraryRestorationService.recordLocalConfiguration(accepted, defaults: receipts)

        // No import this launch: only the receipt can open the library.
        let service = LibraryRestorationService(defaults: receipts)
        try await service.prepare(in: context, cloudEnabled: true, hasLegacyStore: true, locallyRebuiltID: nil, attempts: 1)

        #expect(service.isReady)
        #expect(try settingsRows(ModelContext(container)).count == 2)
        #expect(receipts.string(forKey: "overplay.v2.restoredSettingsID") == oldest.id.uuidString)
    }

    @Test("a single settings row is left alone")
    func convergenceLeavesASingleRowUntouched() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let settings = try seed(container.mainContext)
        let updated = settings.updatedAt
        let service = LibraryRestorationService(defaults: defaults())
        try await prepareAfterImport(service, container)
        #expect(try service.convergeSettingsAfterImport(in: container.mainContext) == nil)
        let read = ModelContext(container)
        #expect(try settingsRows(read).map(\.updatedAt) == [updated])
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
