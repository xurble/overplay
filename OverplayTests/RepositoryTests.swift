import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("SettingsRepository")
struct SettingsRepositoryTests {
    /// Finding DI-4: a device that imported a Nuke Database's deletion before
    /// its new row made a second row here, locking every device out.
    @Test("reading settings from an empty store creates nothing and returns defaults")
    func readingEmptyStoreCreatesNothing() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext

        let settings = try SettingsRepository.settings(in: context)

        #expect(try context.fetchCount(FetchDescriptor<OverplaySettings>()) == 0)
        #expect(!context.hasChanges)
        #expect(settings.modelContext == nil)
        #expect(settings.selectedPlaylistID == nil)
        #expect(settings.skipThresholdPercentage == 50)
        #expect(settings.minimumSkipListeningSeconds == 10)
        #expect(settings.playthroughThresholdPercentage == 90)
    }

    /// PR #122 re-review: a restored device whose every row went (a Nuke
    /// Database on another device, delivered in an unlucky order) showed
    /// "Preparing Overplay" for good, with no way to Settings. It keeps the
    /// app on unsaved defaults; a device that has not restored still waits.
    @Test("a restored device with no settings row shows the app on unsaved defaults; a new device waits")
    func shownSettingsFallsBackOnlyOnceRestored() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let unsaved = OverplaySettings()

        #expect(AppRouter.shownSettings([], isLibraryReady: true, unsavedDefaults: unsaved) === unsaved)
        #expect(AppRouter.shownSettings([], isLibraryReady: false, unsavedDefaults: unsaved) == nil)
        #expect(try context.fetchCount(FetchDescriptor<OverplaySettings>()) == 0)

        // A row arrives: it replaces the defaults at once.
        let newer = OverplaySettings(createdAt: Date(timeIntervalSince1970: 2_000))
        let older = OverplaySettings(createdAt: Date(timeIntervalSince1970: 1_000))
        context.insert(newer)
        context.insert(older)
        try context.save()
        #expect(AppRouter.shownSettings([newer, older], isLibraryReady: true, unsavedDefaults: unsaved) === older)
        #expect(AppRouter.shownSettings([newer, older], isLibraryReady: false, unsavedDefaults: unsaved) === older)
    }

    @Test("reading settings finds the stored row, whichever device's row is oldest")
    func readingFindsOldestRow() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let now = Date(timeIntervalSince1970: 1_000)
        let newer = OverplaySettings(createdAt: now.addingTimeInterval(5))
        let tiedHigh = OverplaySettings(id: UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000000")!, createdAt: now)
        let tiedLow = OverplaySettings(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, createdAt: now)
        for settings in [newer, tiedHigh, tiedLow] { context.insert(settings) }
        try context.save()

        #expect(try SettingsRepository.settings(in: context).id == tiedLow.id)
    }

    @Test("playback counting never caches unsaved defaults, so the real row is used once it arrives")
    func playbackDoesNotCacheUnsavedDefaults() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let suite = "OverplayTests.Settings.\(UUID().uuidString)"
        let store = PlaybackIntentStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(suite).json"),
                                        defaults: UserDefaults(suiteName: suite)!)
        defer { store.clear() }
        let controller = PlaybackController(player: FakePlaybackPlayer(), intentStore: store,
                                            preparePlaybackTracks: { _, _ in }, sleep: PlaybackFixture.manualSampling)
        #expect(controller.settings(in: context)?.playthroughThresholdPercentage == 90)

        let arrived = OverplaySettings(playthroughThresholdPercentage: 70)
        context.insert(arrived)
        try context.save()
        #expect(controller.settings(in: context)?.id == arrived.id)
    }

    @Test("selecting a playlist saves it even when the store has no settings row")
    func selectingPlaylistSavesWithoutARow() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        try SettingsRepository.selectPlaylist(AppleMusicPlaylist(id: "p.otp", name: "Overplay", trackCount: 0), in: context)
        let settings = try #require(try context.fetch(FetchDescriptor<OverplaySettings>()).first)
        #expect(settings.selectedPlaylistID == "p.otp")
        #expect(try context.fetchCount(FetchDescriptor<OverplaySettings>()) == 1)
    }

    @Test("clamps saved settings into supported ranges")
    func clampsSavedSettings() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let settings = try OverplayTestSupport.seedSettings(in: context)

        settings.skipThresholdPercentage = 120
        settings.minimumSkipListeningSeconds = -4
        settings.playthroughThresholdPercentage = 0

        try SettingsRepository.save(settings, in: context)

        #expect(settings.skipThresholdPercentage == 99)
        #expect(settings.minimumSkipListeningSeconds == 0)
        #expect(settings.playthroughThresholdPercentage == 1)
    }
}
