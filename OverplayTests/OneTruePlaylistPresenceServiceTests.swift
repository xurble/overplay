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

    @Test("presence checks every page of iCloud's library, including later-page matches")
    func presenceAsksTheWebLibrary() async throws {
        var requested: [URL] = []
        let found = try await AppleMusicLibraryPlaylistResources.exists(playlistID: "p.overplay") { url in
            requested.append(url)
            return Data((requested.count == 1
                ? #"{"data":[{"id":"p.other","type":"library-playlists","attributes":{"name":"Other"}}],"next":"/v1/me/library/playlists?offset=1"}"#
                : #"{"data":[{"id":"p.overplay","type":"library-playlists","attributes":{"name":"Overplay"}}]}"#).utf8)
        }
        #expect(found)
        #expect(requested.map(\.absoluteString) == [
            "https://api.music.apple.com/v1/me/library/playlists?limit=100",
            "https://api.music.apple.com/v1/me/library/playlists?offset=1"
        ])
        var absentPages = 0
        let absent = try await AppleMusicLibraryPlaylistResources.exists(playlistID: "p.overplay") { _ in
            absentPages += 1
            return Data((absentPages == 1
                ? #"{"data":[{"id":"p.other","type":"library-playlists","attributes":{"name":"Other"}}],"next":"/v1/me/library/playlists?offset=1"}"#
                : #"{"data":[]}"#).utf8)
        }
        #expect(!absent)
        #expect(absentPages == 2)
    }

    @Test("failed or incomplete library enumeration never proves a playlist is missing")
    func incompleteMembershipIsUnknown() async throws {
        let container = try library(selected: true, requested: false)
        let context = container.mainContext
        let firstPage = Data(#"{"data":[{"id":"p.other","type":"library-playlists","attributes":{"name":"Other"}}],"next":"/v1/me/library/playlists?offset=1"}"#.utf8)
        let failures: [(String, (URL) async throws -> Data)] = [
            ("network", { _ in throw URLError(.notConnectedToInternet) }),
            ("authorization", { _ in throw URLError(.userAuthenticationRequired) }),
            ("decode", { _ in Data(#"{"data":null}"#.utf8) }),
            ("incomplete", { url in url.query?.contains("offset=") == true ? Data(#"{"data":[],"next":"/v1/me/library/playlists?offset=2"}"#.utf8) : firstPage })
        ]
        for (reason, request) in failures {
            var presence = OneTruePlaylistPresenceService()
            presence.canCreatePlaylists = { true }
            presence.playlistExists = { id in try? await AppleMusicLibraryPlaylistResources.exists(playlistID: id, request: request) }
            #expect(await presence.prompt(in: context, checksPresence: true) == nil, "\(reason) must not prompt")
            #expect(await presence.isStillMissing("p.overplay", in: context) == nil, "\(reason) must not make a playlist")
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
