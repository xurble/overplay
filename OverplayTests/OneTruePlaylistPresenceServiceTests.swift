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
        #expect(await service(exists: false).prompt(in: container.mainContext, checksPresence: true) == .missing(name: "Overplay"))
        #expect(await service(exists: true).prompt(in: container.mainContext, checksPresence: true) == nil)
        #expect(await service(exists: nil).prompt(in: container.mainContext, checksPresence: true) == nil)
        #expect(await service(canCreate: false, exists: false).prompt(in: container.mainContext, checksPresence: true) == nil)
        // Launch and imports never look it up.
        #expect(await service(exists: false).prompt(in: container.mainContext, checksPresence: false) == nil)
    }

    @Test("with nothing made or asked for, nothing is asked")
    func nothing() async throws {
        let container = try library(selected: false, requested: false)
        #expect(await service(exists: false).prompt(in: container.mainContext, checksPresence: true) == nil)
    }
}
