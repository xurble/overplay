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
}
