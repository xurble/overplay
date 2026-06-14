import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("SettingsRepository")
struct SettingsRepositoryTests {
    @Test("creates default settings once")
    func createsDefaultSettingsOnce() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext

        let settings = try SettingsRepository.settings(in: context)
        let fetchedAgain = try SettingsRepository.settings(in: context)

        #expect(settings.id == fetchedAgain.id)
        #expect(settings.selectedPlaylistID == nil)
        #expect(settings.evictAfterSkips == 6)
        #expect(settings.skipThresholdPercentage == 50)
        #expect(settings.minimumSkipListeningSeconds == 10)
        #expect(settings.playthroughThresholdPercentage == 90)
        #expect(settings.playthroughResetsSkipCount)
        #expect(!settings.protectKeptTracks)
        #expect(!settings.triageAutoEvictsOnSkipCount)
    }

    @Test("clamps saved settings into supported ranges")
    func clampsSavedSettings() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let settings = try SettingsRepository.settings(in: context)

        settings.evictAfterSkips = 0
        settings.skipThresholdPercentage = 120
        settings.minimumSkipListeningSeconds = -4
        settings.playthroughThresholdPercentage = 0

        try SettingsRepository.save(settings, in: context)

        #expect(settings.evictAfterSkips == 1)
        #expect(settings.skipThresholdPercentage == 99)
        #expect(settings.minimumSkipListeningSeconds == 0)
        #expect(settings.playthroughThresholdPercentage == 1)
    }
}
