import Foundation
import MusicKit
import SwiftData
import Testing
@testable import Overplay

/// `PLAYLIST-009`. On 2026-10-05 Apple Music refused every edit to the owner's
/// One True Playlist ("only … a playlist that your app has created") although
/// MusicKit reported it as app-made. Rebuilding links a new Overplay-made one.
@MainActor
@Suite("One True Playlist rebuild", .serialized)
struct OneTruePlaylistRebuildTests {
    final class Recorder {
        var created: [(name: String, ids: [String])] = []
        var synced: [String] = []
    }

    private static func track(_ id: String) throws -> Track {
        .song(try JSONDecoder().decode(Song.self, from: JSONSerialization.data(withJSONObject: [
            "id": id, "type": "library-songs",
            "attributes": ["name": id, "artistName": "Artist", "albumName": "Album", "genreNames": []]
        ])))
    }

    private static func service(
        recorder: Recorder,
        playable: @escaping ([TrackRecord]) -> [TrackRecord] = { $0 },
        create: (() throws -> String)? = nil
    ) -> OneTruePlaylistRebuildService {
        var service = OneTruePlaylistRebuildService()
        service.canCreatePlaylists = { true }
        service.addableTracks = { records, _ in
            var tracks: [UUID: Track] = [:]
            for record in playable(records) { tracks[record.id] = try? Self.track(record.libraryID ?? "") }
            return tracks
        }
        service.createPlaylist = { name, items in
            recorder.created.append((name, items.map(\.id.rawValue)))
            return try create?() ?? "p.rebuilt"
        }
        service.sync = { playlist, _ in recorder.synced.append(playlist.musicPlaylistID) }
        return service
    }

    private func activeLibraryIDs(_ fixture: PlaybackFixture) throws -> [String] {
        let inputs = try PlaybackQueueOrchestrator.playlistInputs(for: fixture.playlist.musicPlaylistID, in: fixture.context)
        return PlaylistDisplayOrder.orderedItems(inputs.items.filter { PlaylistPlaybackScope.active.includes($0) }, scope: .active)
            .compactMap { inputs.tracksByID[$0.trackID]?.libraryID }
    }

    @Test("Rebuilding creates an Overplay playlist of the active songs in Overplay's order and relinks the same One True Playlist")
    func rebuildRelinks() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        fixture.settings.selectedPlaylistID = "playlist-main"
        let retired = try fixture.item(1)
        try TrackActionService.evictTrack(retired, playlist: fixture.playlist, message: "Retired manually", in: fixture.context)
        fixture.playlist.remoteEditsRefusedAt = .now
        fixture.playlist.writePolicy = .incomingOnly
        let expected = try activeLibraryIDs(fixture)
        let recorder = Recorder()
        fixture.controller.playlistRebuild = Self.service(recorder: recorder)

        let result = try await fixture.controller.rebuildOneTruePlaylist(context: fixture.context)

        #expect(recorder.created.count == 1)
        #expect(recorder.created.first?.name == "Main")
        #expect(recorder.created.first?.ids == expected)
        #expect(!expected.contains(try #require(fixture.tracks.first { $0.id == retired.trackID }).libraryID ?? ""))
        #expect(result == .init(name: "Main", addedCount: 2, skippedCount: 0))
        #expect(fixture.playlist.musicPlaylistID == "p.rebuilt")
        #expect(fixture.playlist.role == .oneTruePlaylist && fixture.playlist.writePolicy == .managed)
        #expect(fixture.playlist.remoteEditsRefusedAt == nil)
        #expect(fixture.settings.selectedPlaylistID == "p.rebuilt")
        // The retired song stays out of the new playlist under the new identifier.
        #expect(retired.suppressedOTPMusicPlaylistIDs == ["p.rebuilt"])
        #expect(try PlaylistItemRepository.items(forPlaylistID: fixture.playlist.id, in: fixture.context).count == 2)
        #expect(recorder.synced == ["p.rebuilt"])
    }

    @Test("Songs with no addable item on this device are left out and counted")
    func skippedSongsAreCounted() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        let recorder = Recorder()
        fixture.controller.playlistRebuild = Self.service(recorder: recorder, playable: { Array($0.dropLast()) })

        let result = try await fixture.controller.rebuildOneTruePlaylist(context: fixture.context)
        #expect(result.addedCount == 2 && result.skippedCount == 1)
        #expect(recorder.created.first?.ids.count == 2)
    }

    @Test("Nothing changes when no song can be added, when creation fails, or on a Mac")
    func failuresChangeNothing() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        let recorder = Recorder()

        fixture.controller.playlistRebuild = Self.service(recorder: recorder, playable: { _ in [] })
        await #expect(throws: OneTruePlaylistRebuildService.RebuildError.self) {
            _ = try await fixture.controller.rebuildOneTruePlaylist(context: fixture.context)
        }

        fixture.controller.playlistRebuild = Self.service(recorder: recorder, create: { throw URLError(.notConnectedToInternet) })
        await #expect(throws: OneTruePlaylistRebuildService.RebuildError.self) {
            _ = try await fixture.controller.rebuildOneTruePlaylist(context: fixture.context)
        }

        var mac = Self.service(recorder: recorder)
        mac.canCreatePlaylists = { false }
        fixture.controller.playlistRebuild = mac
        await #expect(throws: OneTruePlaylistRebuildService.RebuildError.self) {
            _ = try await fixture.controller.rebuildOneTruePlaylist(context: fixture.context)
        }

        #expect(fixture.playlist.musicPlaylistID == "playlist-main")
        #expect(recorder.synced.isEmpty)
        #expect(recorder.created.count == 1)
    }

    @Test("A sync failure after rebuilding leaves the new playlist linked")
    func syncFailureKeepsNewLink() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        let recorder = Recorder()
        var service = Self.service(recorder: recorder)
        service.sync = { _, _ in throw URLError(.timedOut) }
        fixture.controller.playlistRebuild = service

        _ = try await fixture.controller.rebuildOneTruePlaylist(context: fixture.context)
        #expect(fixture.playlist.musicPlaylistID == "p.rebuilt")
    }

    @Test("Settings reports the rebuild, including songs left out")
    func settingsMessage() async throws {
        #expect(SettingsViewModel.rebuildMessage(.init(name: "Overplay", addedCount: 103, skippedCount: 0))
            == "Rebuilt “Overplay” in Apple Music with 103 songs. Delete the older “Overplay” playlist in the Music app.")
        #expect(SettingsViewModel.rebuildMessage(.init(name: "Overplay", addedCount: 100, skippedCount: 3))
            .hasSuffix("3 songs couldn’t be added from this device; they stay in Overplay."))

        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        let model = SettingsViewModel()
        var dependencies = SettingsViewModel.Dependencies.live(playbackController: fixture.controller)
        dependencies.rebuildOneTruePlaylist = { _ in throw OneTruePlaylistRebuildService.RebuildError.notOnThisDevice }
        await model.rebuildOneTruePlaylist(context: fixture.context, dependencies: dependencies)
        #expect(model.message == "Rebuild the Apple Music playlist from your iPhone or iPad.")
        #expect(!model.isRebuildingPlaylist)
    }
}
