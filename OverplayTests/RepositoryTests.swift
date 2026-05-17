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
        #expect(settings.evictAfterSkips == 3)
        #expect(settings.skipThresholdPercentage == 50)
        #expect(settings.minimumSkipListeningSeconds == 10)
        #expect(settings.playthroughThresholdPercentage == 90)
        #expect(settings.playthroughResetsSkipCount)
        #expect(!settings.protectKeptTracks)
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

@MainActor
@Suite("TrackRepository")
struct TrackRepositoryTests {
    @Test("upsert inserts and updates without resetting stats")
    func upsertInsertsAndUpdatesWithoutResettingStats() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext

        let firstSnapshot = TrackSnapshot(
            id: "track-1",
            catalogID: "catalog-1",
            libraryID: "library-1",
            playlistEntryID: "entry-1",
            playlistID: "playlist-1",
            title: "Original Title",
            artistName: "Sample Artist",
            albumTitle: "Original Album",
            artworkURLTemplate: nil,
            durationSeconds: 180
        )
        let inserted = try TrackRepository.upsert(firstSnapshot, in: context)
        inserted.skipCount = 2
        inserted.playthroughCount = 1

        let secondSnapshot = TrackSnapshot(
            id: "track-1",
            catalogID: "catalog-1",
            libraryID: "library-1",
            playlistEntryID: "entry-2",
            playlistID: "playlist-1",
            title: "Updated Title",
            artistName: "Sample Artist",
            albumTitle: "Updated Album",
            artworkURLTemplate: "https://example.com/artwork.jpg",
            durationSeconds: 210
        )
        let updated = try TrackRepository.upsert(secondSnapshot, in: context)
        let tracks = try TrackRepository.allTracks(in: context)

        #expect(tracks.count == 1)
        #expect(updated.id == "track-1")
        #expect(updated.title == "Updated Title")
        #expect(updated.albumTitle == "Updated Album")
        #expect(updated.playlistEntryID == "entry-2")
        #expect(updated.durationSeconds == 210)
        #expect(updated.skipCount == 2)
        #expect(updated.playthroughCount == 1)
    }
}
