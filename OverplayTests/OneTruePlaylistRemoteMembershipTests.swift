import Foundation
import MusicKit
import SwiftData
import Testing
@testable import Overplay

/// `PLAYLIST-008`. Shapes observed on 2026-10-05: iPhone playlist entries
/// carry web library `i.` IDs; a Mac's carry native numeric IDs; an iPhone
/// whose library lagged iCloud still listed songs deleted elsewhere.
@MainActor
@Suite("One True Playlist remote membership", .serialized)
struct OneTruePlaylistRemoteMembershipTests {
    final class Recorder {
        var written: [[String]] = []
        var deviceLoads = 0
        var cloudReads = 0
    }

    private static func song(_ id: String) throws -> Song {
        try JSONDecoder().decode(Song.self, from: JSONSerialization.data(withJSONObject: [
            "id": id, "type": "library-songs",
            "attributes": ["name": id, "artistName": "Artist", "albumName": "Album", "genreNames": []]
        ]))
    }

    private static func playlistModel() throws -> Playlist {
        try JSONDecoder().decode(Playlist.self, from: JSONSerialization.data(withJSONObject: [
            "id": "playlist-main", "type": "library-playlists", "attributes": ["name": "Main", "canEdit": true]
        ]))
    }

    private static func entries(_ ids: [String], type: String = "library-songs") -> [AppleMusicLibraryPlaylistResources.Entry] {
        ids.map { .init(id: $0, type: type) }
    }

    /// `device` lists this device's raw entry IDs; `resolved` maps a raw ID to
    /// the library ID the shared resolver would return.
    private static func membership(
        cloud: @escaping () throws -> [AppleMusicLibraryPlaylistResources.Entry],
        device: [String],
        resolved: [String: String] = [:],
        recorder: Recorder
    ) -> OneTruePlaylistRemoteMembership {
        var membership = OneTruePlaylistRemoteMembership()
        membership.cloudEntries = { _ in recorder.cloudReads += 1; return try cloud() }
        membership.loadDeviceCopy = { _ in
            recorder.deviceLoads += 1
            return (try playlistModel(), try device.map { .song(try song($0)) })
        }
        membership.resolve = { song in
            guard let libraryID = resolved[song.id.rawValue] else {
                throw MusicLibrarySongResolver.ResolutionError.unresolved(song.id.rawValue)
            }
            return .library(try Self.song(libraryID))
        }
        membership.write = { _, items in recorder.written.append(items.map(\.id.rawValue)) }
        return membership
    }

    private func retire(_ index: Int, in fixture: PlaybackFixture, skipCount: Int = 0) throws -> PlaylistItemRecord {
        let item = try fixture.item(index)
        item.skipCount = skipCount
        try TrackActionService.evictTrack(item, playlist: fixture.playlist, message: "Retired manually", in: fixture.context)
        #expect(item.suppressedOTPMusicPlaylistIDs == ["playlist-main"])
        return item
    }

    // MARK: - The shared operation

    @Test("iPhone: entries carrying web library IDs are rewritten without the retired song, which is then deleted as 0/0")
    func iPhoneRemovesRetiredSong() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        let retired = try retire(0, in: fixture)
        let recorder = Recorder()
        let ids = ["i.lib-0", "i.lib-1", "i.lib-2"]
        let outcome = try await Self.membership(cloud: { Self.entries(ids) }, device: ids, recorder: recorder)
            .removeSongsHeldOutside(fixture.playlist, in: fixture.context)

        #expect(recorder.written == [["i.lib-1", "i.lib-2"]])
        #expect(outcome.removedItemIDs == [retired.id])
        #expect(try PlaylistItemRepository.allItems(in: fixture.context).count == 2)
    }

    @Test("Mac: native entry IDs resolve through the shared resolver before the rewrite")
    func macResolvesNativeIDs() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        let retired = try retire(0, in: fixture, skipCount: 2)
        let recorder = Recorder()
        let outcome = try await Self.membership(
            cloud: { Self.entries(["i.lib-0", "i.lib-1", "i.lib-2"]) },
            device: ["-100", "-101", "-102"],
            resolved: ["-100": "i.lib-0", "-101": "i.lib-1", "-102": "i.lib-2"],
            recorder: recorder
        ).removeSongsHeldOutside(fixture.playlist, in: fixture.context)

        #expect(recorder.written == [["-101", "-102"]])
        #expect(outcome.removedItemIDs == [retired.id])
        // Counted rows survive; only the suppression is released.
        #expect(try PlaylistItemRepository.item(id: retired.id, in: fixture.context) != nil)
        #expect(retired.evictedAt != nil && retired.suppressedOTPMusicPlaylistIDs.isEmpty)
    }

    @Test("A song already absent from iCloud needs no rewrite and releases its suppression")
    func alreadyAbsentIsDone() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        let kept = try retire(0, in: fixture, skipCount: 2)
        let unwanted = try retire(1, in: fixture)
        let recorder = Recorder()
        let outcome = try await Self.membership(cloud: { Self.entries(["i.lib-2"]) }, device: ["i.lib-2"], recorder: recorder)
            .removeSongsHeldOutside(fixture.playlist, in: fixture.context)

        #expect(outcome.absentItemIDs == [kept.id, unwanted.id])
        #expect(recorder.deviceLoads == 0 && recorder.written.isEmpty)
        #expect(kept.suppressedOTPMusicPlaylistIDs.isEmpty && kept.evictedAt != nil)
        #expect(try PlaylistItemRepository.item(id: unwanted.id, in: fixture.context) == nil)
    }

    @Test("A lagging device that still lists a song deleted elsewhere does not resurrect it")
    func staleDeviceWithDeletedSongDefers() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        let retired = try retire(0, in: fixture)
        let recorder = Recorder()
        let outcome = try await Self.membership(
            cloud: { Self.entries(["i.lib-0", "i.lib-2"]) },
            device: ["i.lib-0", "i.lib-1", "i.lib-2"],
            resolved: ["i.lib-0": "i.lib-0", "i.lib-1": "i.lib-1", "i.lib-2": "i.lib-2"],
            recorder: recorder
        ).removeSongsHeldOutside(fixture.playlist, in: fixture.context)

        #expect(outcome.deferredItemIDs == [retired.id])
        #expect(recorder.written.isEmpty)
        #expect(retired.suppressedOTPMusicPlaylistIDs == ["playlist-main"])
        #expect(try PlaylistItemRepository.item(id: retired.id, in: fixture.context) != nil)
    }

    @Test("A lagging device missing a song added elsewhere does not drop it")
    func staleDeviceMissingNewSongDefers() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        let retired = try retire(0, in: fixture)
        let recorder = Recorder()
        let outcome = try await Self.membership(
            cloud: { Self.entries(["i.lib-0", "i.lib-1", "i.lib-2", "i.added-elsewhere"]) },
            device: ["i.lib-0", "i.lib-1", "i.lib-2"],
            resolved: ["i.lib-0": "i.lib-0", "i.lib-1": "i.lib-1", "i.lib-2": "i.lib-2"],
            recorder: recorder
        ).removeSongsHeldOutside(fixture.playlist, in: fixture.context)

        #expect(outcome.deferredItemIDs == [retired.id])
        #expect(recorder.written.isEmpty)
    }

    @Test("Every occurrence of a retired song is removed")
    func duplicateOccurrencesRemoved() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        _ = try retire(0, in: fixture)
        let recorder = Recorder()
        let ids = ["i.lib-0", "i.lib-1", "i.lib-0", "i.lib-2"]
        try await Self.membership(cloud: { Self.entries(ids) }, device: ids, recorder: recorder)
            .removeSongsHeldOutside(fixture.playlist, in: fixture.context)

        #expect(recorder.written == [["i.lib-1", "i.lib-2"]])
    }

    @Test("A catalog entry matches by catalog ID; a catalog ID never matches a library entry")
    func domainsComeFromTheResponse() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        let retired = try retire(0, in: fixture, skipCount: 2)
        let recorder = Recorder()
        // `cat-0` as a library-song resource is a different song from catalog `cat-0`.
        let outcome = try await Self.membership(
            cloud: { Self.entries(["cat-0"]) + Self.entries(["i.lib-1"]) },
            device: ["cat-0", "i.lib-1"], recorder: recorder
        ).removeSongsHeldOutside(fixture.playlist, in: fixture.context)
        #expect(outcome.absentItemIDs == [retired.id])

        retired.suppressedOTPMusicPlaylistIDs = ["playlist-main"]
        let catalogOutcome = try await Self.membership(
            cloud: { Self.entries(["cat-0"], type: "songs") + Self.entries(["i.lib-1"]) },
            device: ["cat-0", "i.lib-1"], recorder: recorder
        ).removeSongsHeldOutside(fixture.playlist, in: fixture.context)
        #expect(catalogOutcome.removedItemIDs == [retired.id])
        #expect(recorder.written == [["i.lib-1"]])
    }

    @Test("A merged duplicate in Triage is removed through its confirmed alias and stays in Triage")
    func mergedDuplicateRemovedThroughAlias() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        let bucket = try PlaylistRepository.triageBucket(in: fixture.context)
        let keeperTrack = TrackRecord(catalogID: "cat-keeper", libraryID: "i.keeper", title: "Keeper", artistName: "Artist")
        keeperTrack.confirmedAliases = [.library("i.donor")]
        fixture.context.insert(keeperTrack)
        let keeper = PlaylistItemRecord(playlistID: bucket.id, trackID: keeperTrack.id)
        keeper.suppressedOTPMusicPlaylistIDs = ["playlist-main"]
        fixture.context.insert(keeper)
        try fixture.context.save()
        let recorder = Recorder()
        let ids = ["i.lib-0", "i.donor", "i.lib-1", "i.lib-2"]
        let outcome = try await Self.membership(cloud: { Self.entries(ids) }, device: ids, recorder: recorder)
            .removeSongsHeldOutside(fixture.playlist, in: fixture.context)

        #expect(outcome.removedItemIDs == [keeper.id])
        #expect(recorder.written == [["i.lib-0", "i.lib-1", "i.lib-2"]])
        // An active Triage row is not subject to the retention rule here.
        #expect(try PlaylistItemRepository.item(id: keeper.id, in: fixture.context) != nil)
        #expect(keeper.playlistID == bucket.id && keeper.suppressedOTPMusicPlaylistIDs.isEmpty)
    }

    @Test("An iCloud failure propagates and keeps the suppression")
    func cloudFailureKeepsSuppression() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        let retired = try retire(0, in: fixture)
        let recorder = Recorder()
        await #expect(throws: URLError.self) {
            try await Self.membership(cloud: { throw URLError(.notConnectedToInternet) }, device: [], recorder: recorder)
                .removeSongsHeldOutside(fixture.playlist, in: fixture.context)
        }
        #expect(retired.suppressedOTPMusicPlaylistIDs == ["playlist-main"])
        #expect(try PlaylistItemRepository.item(id: retired.id, in: fixture.context) != nil)
    }

    @Test("An incoming-only playlist is never read or written")
    func incomingOnlyUntouched() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        _ = try retire(0, in: fixture)
        fixture.playlist.writePolicy = .incomingOnly
        let recorder = Recorder()
        let outcome = try await Self.membership(cloud: { Self.entries(["i.lib-0"]) }, device: ["i.lib-0"], recorder: recorder)
            .removeSongsHeldOutside(fixture.playlist, in: fixture.context)
        #expect(outcome == .init())
        #expect(recorder.cloudReads == 0)
    }

    @Test("iCloud entries are read across pages, each domain taken from its resource type")
    func cloudEntriesPaging() async throws {
        let pages = [
            #"{"data":[{"id":"i.a","type":"library-songs"}],"next":"/v1/me/library/playlists/p.x/tracks?offset=1"}"#,
            #"{"data":[{"id":"1","type":"songs"},{"id":"i.v","type":"library-music-videos"}]}"#
        ]
        var requested: [URL] = []
        let entries = try await AppleMusicLibraryPlaylistResources.fetchEntries(playlistID: "p.x") { url in
            requested.append(url)
            return Data(pages[requested.count - 1].utf8)
        }
        #expect(entries.map(\.reference) == [.library("i.a"), .catalog("1"), nil])
        #expect(requested.count == 2)
    }

    // MARK: - Shared entry points

    @Test("Retiring through the playback controller removes the song from Apple Music")
    func retireEntryPointRemoves() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        let recorder = Recorder()
        let ids = ["i.lib-0", "i.lib-1", "i.lib-2"]
        fixture.controller.remoteMembership = Self.membership(cloud: { Self.entries(ids) }, device: ids, recorder: recorder)
        let item = try fixture.item(0)
        let title = try #require(fixture.tracks.first { $0.id == item.trackID }).title

        try fixture.controller.retireTrack(item, playlist: fixture.playlist, message: "Retired manually", context: fixture.context)
        for _ in 0..<200 where recorder.written.isEmpty { await Task.yield() }

        #expect(recorder.written == [ids.filter { $0 != "i.lib-0" }])
        for _ in 0..<200 where fixture.controller.statusMessage == nil { await Task.yield() }
        #expect(fixture.controller.statusMessage == "Removed \(title) from the Apple Music playlist.")
    }

    @Test("Retiring on a lagging device tells the user Apple Music will follow after sync")
    func retireEntryPointDefers() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        let recorder = Recorder()
        fixture.controller.remoteMembership = Self.membership(
            cloud: { Self.entries(["i.lib-0", "i.lib-2"]) }, device: ["i.lib-0", "i.lib-1", "i.lib-2"],
            resolved: ["i.lib-0": "i.lib-0", "i.lib-1": "i.lib-1", "i.lib-2": "i.lib-2"], recorder: recorder
        )
        try fixture.controller.retireTrack(try fixture.item(0), playlist: fixture.playlist, message: "Retired manually", context: fixture.context)
        for _ in 0..<200 where fixture.controller.statusMessage == nil { await Task.yield() }

        #expect(fixture.controller.statusMessage == "Retired. Apple Music will be updated after the next sync.")
        #expect(recorder.written.isEmpty)
    }

    @Test("A completed sync of the One True Playlist retries removals; a retry failure never fails the sync")
    func syncRetriesRemovals() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        var retried: [String] = []
        let adapter = UnchangedSource()
        let service = PlaylistSyncService(sourceRegistry: .init(adapters: [.appleMusic: adapter]), removeSongsHeldOutside: { playlist, _ in
            retried.append(playlist.musicPlaylistID)
            throw URLError(.notConnectedToInternet)
        })

        _ = try await service.syncPlaylist(fixture.playlist, in: fixture.context, runIdentityMerge: false)
        #expect(retried == ["playlist-main"])

        let source = try PlaylistRepository.addTriageSource(AppleMusicPlaylist(id: "source", name: "Source", trackCount: 0), in: fixture.context)
        _ = try await service.syncPlaylist(source, in: fixture.context, runIdentityMerge: false)
        #expect(retried == ["playlist-main"])
    }

    @Test("Promotion skips the add when iCloud already holds the song, and adds when iCloud cannot be checked")
    func promoteSkipsDuplicateAdd() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        var adds = 0
        let first = try retire(0, in: fixture, skipCount: 2)
        let second = try retire(1, in: fixture, skipCount: 2)

        var present = PlaylistMutationService(addRemotely: { _, _, _ in adds += 1 })
        present.remoteMembership.cloudEntries = { _ in Self.entries(["i.lib-0", "i.lib-2"]) }
        let promoted = try await present.promote(item: first, in: fixture.context)
        #expect(adds == 0)
        #expect(promoted.playlistID == fixture.playlist.id && promoted.evictedAt == nil)

        var unknown = PlaylistMutationService(addRemotely: { _, _, _ in adds += 1 })
        unknown.remoteMembership.cloudEntries = { _ in throw URLError(.notConnectedToInternet) }
        _ = try await unknown.promote(item: second, in: fixture.context)
        #expect(adds == 1)
    }
}

@MainActor
private struct UnchangedSource: PlaylistSourceSyncing {
    let source: PlaylistSource = .appleMusic
    func fetchLibraryPlaylists() async throws -> [RemotePlaylistLink] { [] }
    func fetchTrackSnapshots(playlistID: String, playlistName: String?, playlistRecord: PlaylistRecord?,
        skipWhenRemoteUnchanged: Bool, in context: ModelContext) async throws -> PlaylistSourceFetchResult {
        PlaylistSourceFetchResult(snapshots: [], skippedCount: 0, skippedReason: "remoteUnchanged",
            remoteLastModifiedAt: nil, didFetchTracks: false)
    }
}
