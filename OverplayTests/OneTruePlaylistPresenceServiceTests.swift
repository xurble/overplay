import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("One True Playlist presence")
struct OneTruePlaylistPresenceServiceTests {
    private func library(selected: Bool, requested: Bool) throws -> ModelContainer {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let settings = OverplaySettings(selectedPlaylistID: selected ? "p.overplay" : nil,
                                        selectedPlaylistName: selected ? "Overplay" : nil)
        if requested {
            settings.pendingOneTruePlaylistRequestedAt = .now
            settings.pendingOneTruePlaylistSourceName = "Favourites"
        }
        context.insert(settings)
        if selected {
            context.insert(PlaylistRecord(musicPlaylistID: "p.overplay", name: "Overplay", role: .oneTruePlaylist, writePolicy: .managed))
        }
        try context.save()
        return container
    }

    private func service(canCreate: Bool = true, exists: Bool?) -> OneTruePlaylistPresenceService {
        var service = OneTruePlaylistPresenceService()
        service.canCreatePlaylists = { canCreate }
        service.playlistExists = { _ in exists }
        return service
    }

    @Test("a Mac's request is asked about, never made silently, and only where it can be made")
    func requestedByMac() async throws {
        let container = try library(selected: false, requested: true)
        #expect(await service(exists: nil).prompt(in: container.mainContext, checksPresence: true) == .requestedByMac(sourceName: "Favourites"))
        #expect(await service(canCreate: false, exists: nil).prompt(in: container.mainContext, checksPresence: true) == nil)
    }

    @Test("a One True Playlist missing from Apple Music is asked about; an unknown answer asks nothing")
    func missing() async throws {
        let container = try library(selected: true, requested: false)
        #expect(await service(exists: false).prompt(in: container.mainContext, checksPresence: true) == .missing(name: "Overplay", playlistID: "p.overplay"))
        #expect(await service(exists: true).prompt(in: container.mainContext, checksPresence: true) == nil)
        #expect(await service(exists: nil).prompt(in: container.mainContext, checksPresence: true) == nil)
        #expect(await service(canCreate: false, exists: false).prompt(in: container.mainContext, checksPresence: true) == nil)
        // Launch and imports never look it up.
        #expect(await service(exists: false).prompt(in: container.mainContext, checksPresence: false) == nil)
    }

    @Test("presence asks iCloud's web library for the playlist, not this device's library")
    func presenceAsksTheWebLibrary() async throws {
        var requested: [URL] = []
        let found = try await AppleMusicLibraryPlaylistResources.exists(playlistID: "p.overplay") { url in
            requested.append(url)
            return Data(#"{"data":[{"id":"p.overplay"}]}"#.utf8)
        }
        #expect(found)
        #expect(requested.map(\.absoluteString) == ["https://api.music.apple.com/v1/me/library/playlists/p.overplay"])
        let empty = try await AppleMusicLibraryPlaylistResources.exists(playlistID: "p.overplay") { _ in
            Data(#"{"data":[]}"#.utf8)
        }
        #expect(!empty)
        // Any other failure is unknown, which the service treats as no prompt.
        await #expect(throws: URLError.self) {
            try await AppleMusicLibraryPlaylistResources.exists(playlistID: "p.overplay") { _ in throw URLError(.notConnectedToInternet) }
        }
    }

    @Test("saying yes to a stale missing prompt makes nothing")
    func staleMissingPromptMakesNothing() async throws {
        let container = try library(selected: true, requested: false)
        let context = container.mainContext
        #expect(await service(exists: false).isStillMissing("p.overplay", in: context) == true)
        // The library caught up, or the answer is unknown.
        #expect(await service(exists: true).isStillMissing("p.overplay", in: context) == false)
        #expect(await service(exists: nil).isStillMissing("p.overplay", in: context) == nil)
        // Another device made it again: the One True Playlist has a new ID.
        try #require(try PlaylistRepository.oneTruePlaylist(in: context)).musicPlaylistID = "p.remade"
        #expect(await service(exists: false).isStillMissing("p.overplay", in: context) == false)
    }

    @Test("Make It Again reports songs this device could not add")
    func remadeMessage() {
        let full = OneTruePlaylistRebuildService.Result(name: "Overplay", addedCount: 10, skippedCount: 0)
        #expect(OneTruePlaylistPrompt.remadeMessage(full) == "Made “Overplay” again in Apple Music with 10 songs.")
        let partial = OneTruePlaylistRebuildService.Result(name: "Overplay", addedCount: 8, skippedCount: 2)
        #expect(OneTruePlaylistPrompt.remadeMessage(partial).hasSuffix("2 songs couldn’t be added from this device; they stay in Overplay."))
    }

    @Test("with nothing made or asked for, nothing is asked")
    func nothing() async throws {
        let container = try library(selected: false, requested: false)
        #expect(await service(exists: false).prompt(in: container.mainContext, checksPresence: true) == nil)
    }
}
