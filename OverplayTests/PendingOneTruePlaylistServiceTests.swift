import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("One True Playlist a Mac asked for")
struct PendingOneTruePlaylistServiceTests {
    private func library(pendingSource: AppleMusicPlaylist?) throws -> ModelContainer {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        context.insert(OverplaySettings())
        context.insert(PlaylistRecord(musicPlaylistID: PlaylistRecord.triageBucketMusicPlaylistID,
                                      name: "Triage", role: .triageBucket, writePolicy: .incomingOnly))
        try context.save()
        try PendingOneTruePlaylistService.request(copying: pendingSource, in: context)
        return container
    }

    private func service(created: @escaping (String?) -> Void, fails: Bool = false) -> PendingOneTruePlaylistService {
        var service = PendingOneTruePlaylistService()
        service.canCreatePlaylists = { true }
        service.createManagedOneTruePlaylist = { name, source, context in
            if fails { throw PlaylistSyncError.playlistNotFound }
            created(source)
            let record = PlaylistRecord(musicPlaylistID: "p.overplay", name: name, role: .oneTruePlaylist, writePolicy: .managed)
            context.insert(record)
            try context.save()
            return record
        }
        return service
    }

    private func settings(_ container: ModelContainer) throws -> OverplaySettings {
        try #require(try container.mainContext.fetch(FetchDescriptor<OverplaySettings>()).first)
    }

    @Test("an iPhone makes the requested copy once and selects it")
    func iPhoneFulfilsTheRequest() async throws {
        let container = try library(pendingSource: AppleMusicPlaylist(id: "p.favourites", name: "Favourites"))
        var sources: [String?] = []
        let service = service { sources.append($0) }

        let playlist = await service.fulfilIfNeeded(in: container.mainContext)
        #expect(playlist?.musicPlaylistID == "p.overplay")
        #expect(sources == ["p.favourites"])
        let settings = try settings(container)
        #expect(settings.selectedPlaylistID == "p.overplay")
        #expect(settings.pendingOneTruePlaylistRequestedAt == nil && settings.pendingOneTruePlaylistSourceID == nil)

        #expect(await service.fulfilIfNeeded(in: container.mainContext) == nil)
        #expect(sources.count == 1)
    }

    @Test("a second caller while the first is making it waits and gets the same playlist")
    func concurrentCallersShareOneCreation() async throws {
        let container = try library(pendingSource: nil)
        var made = 0
        var service = PendingOneTruePlaylistService()
        service.canCreatePlaylists = { true }
        service.createManagedOneTruePlaylist = { name, _, context in
            made += 1
            try await Task.sleep(for: .milliseconds(50))
            let record = PlaylistRecord(musicPlaylistID: "p.overplay", name: name, role: .oneTruePlaylist, writePolicy: .managed)
            context.insert(record)
            try context.save()
            return record
        }
        let context = container.mainContext
        let first = Task { await service.fulfilIfNeeded(in: context)?.musicPlaylistID }
        let second = Task { await service.fulfilIfNeeded(in: context)?.musicPlaylistID }
        let (a, b) = (await first.value, await second.value)
        #expect(made == 1)
        #expect(a == "p.overplay")
        #expect(b == "p.overplay")
    }

    @Test("a Mac leaves the request for an iPhone")
    func macLeavesTheRequest() async throws {
        let container = try library(pendingSource: nil)
        var service = service { _ in Issue.record("a Mac created a playlist") }
        service.canCreatePlaylists = { false }
        #expect(await service.fulfilIfNeeded(in: container.mainContext) == nil)
        #expect(try settings(container).pendingOneTruePlaylistRequestedAt != nil)
    }

    @Test("a failure keeps the request for the next launch or import")
    func failureKeepsTheRequest() async throws {
        let container = try library(pendingSource: nil)
        #expect(await service(created: { _ in }, fails: true).fulfilIfNeeded(in: container.mainContext) == nil)
        let settings = try settings(container)
        #expect(settings.pendingOneTruePlaylistRequestedAt != nil)
        #expect(settings.selectedPlaylistID == nil)
    }

    @Test("a One True Playlist chosen meanwhile answers the request")
    func chosenMeanwhileClearsTheRequest() async throws {
        let container = try library(pendingSource: nil)
        let settings = try settings(container)
        settings.selectedPlaylistID = "p.chosen"
        let service = service { _ in Issue.record("made a second One True Playlist") }
        #expect(await service.fulfilIfNeeded(in: container.mainContext) == nil)
        #expect(settings.pendingOneTruePlaylistRequestedAt == nil)
        #expect(settings.selectedPlaylistID == "p.chosen")
    }
}
