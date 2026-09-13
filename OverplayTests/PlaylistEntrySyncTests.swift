import Foundation
import MusicKit
import SwiftData
import Testing
@testable import Overplay

@MainActor
struct PlaylistEntrySyncTests {
    @Test("Entry mapping keeps occurrence metadata separate from playable song identity")
    func mapping() throws {
        let entry = try makeEntry(id: "occurrence", position: 7)
        let song = try makeSong()
        let snapshot = try #require(AppleMusicPlaylistTrackLoader.snapshot(from: entry, item: .song(song), playlistID: "source"))
        #expect(snapshot.id == "123")
        #expect(snapshot.catalogID == "123")
        #expect(snapshot.playlistEntryID == "occurrence")
        #expect(snapshot.remotePosition == 7)
        #expect(snapshot.isrc == "USABC1234567")
        #expect(snapshot.entryPlayCount == entry.playCount)
        #expect(snapshot.entryLastPlayedDate == entry.lastPlayedDate)
        #expect(snapshot.title == "Song")
        #expect(snapshot.artistName == "Artist")
        #expect(snapshot.albumTitle == "Album")
        #expect(snapshot.durationSeconds == 180)
        let playback = try JSONDecoder().decode(Track.self, from: #require(snapshot.musicKitPlaybackData))
        #expect(playback.id == song.id)
        #expect(AppleMusicPlaylistTrackLoader.snapshot(from: entry, item: nil, playlistID: "source") == nil)
    }

    @Test("Library song identity survives entry snapshotting")
    func libraryIdentity() throws {
        let json = #"{"id":"i.library","type":"library-songs","attributes":{"name":"Song","artistName":"Artist","albumName":"Album","genreNames":[],"playParams":{"id":"i.library","kind":"song","isLibrary":true,"catalogId":"123"}}}"#
        let song = try JSONDecoder().decode(Song.self, from: Data(json.utf8))
        let snapshot = try #require(AppleMusicPlaylistTrackLoader.snapshot(from: makeEntry(id: "entry", position: 1), item: .song(song), playlistID: "source"))
        #expect(snapshot.libraryID == "i.library")
        #expect(snapshot.catalogID == "123")
        #expect(snapshot.playlistEntryID == "entry")
    }

    @Test("Videos are skipped for song intake but retained in complete rewrites")
    func video() throws {
        let json = #"{"id":"video","type":"music-videos","attributes":{"name":"Video","artistName":"Artist","genreNames":[],"durationInMillis":100000}}"#
        let video = try JSONDecoder().decode(MusicVideo.self, from: Data(json.utf8))
        let entry = try makeEntry(id: "video-entry", position: 2)
        #expect(AppleMusicPlaylistTrackLoader.snapshot(from: entry, item: .musicVideo(video), playlistID: "source") == nil)
        let tracks = try AppleMusicPlaylistTrackLoader.completeTracks(from: [.musicVideo(video), .song(makeSong())])
        #expect(tracks.map(\.id.rawValue) == ["video", "123"])
        #expect(AppleMusicPlaylistTrackLoader.songSnapshots(from: tracks, playlistID: "copy").map(\.id) == ["123"])
    }

    @Test("Complete entry pagination preserves duplicate recordings and page order")
    func pagination() async throws {
        var calls = 0
        let entries = try await AppleMusicPlaylistTrackLoader.collectCompleteEntries(
            firstBatch: ["entry-a"], hasNextBatch: true, identity: { $0 }
        ) {
            calls += 1
            return (entries: calls == 1 ? ["entry-b"] : ["entry-c"], hasNextBatch: calls == 1)
        }
        #expect(entries == ["entry-a", "entry-b", "entry-c"])
        #expect(calls == 2)
    }

    @Test("Missing, empty, repeated and overlapping promised pages fail closed", arguments: [0, 1, 2, 3])
    func badPages(kind: Int) async {
        await #expect(throws: PlaylistSyncError.self) {
            _ = try await AppleMusicPlaylistTrackLoader.collectCompleteEntries(
                firstBatch: ["a"], hasNextBatch: true, identity: { $0 }
            ) {
                switch kind {
                case 0: return nil
                case 1: return (entries: [], hasNextBatch: false)
                case 2: return (entries: ["a"], hasNextBatch: true)
                default: return (entries: ["b", "a"], hasNextBatch: false)
                }
            }
        }
    }

    @Test("Pagination propagates fetch failure and cancellation")
    func failedPage() async {
        await #expect(throws: CancellationError.self) {
            _ = try await AppleMusicPlaylistTrackLoader.collectCompleteEntries(
                firstBatch: ["a"], hasNextBatch: true, identity: { $0 }
            ) { throw CancellationError() }
        }
    }

    @Test("Rewrite materialization retains every duplicate and rejects unavailable entries")
    func completeRewrite() throws {
        let song = try makeSong()
        let items: [Playlist.Entry.Item?] = [.song(song), .song(song)]
        #expect(try AppleMusicPlaylistTrackLoader.completeTracks(from: items).map(\.id) == [song.id, song.id])
        #expect(throws: PlaylistSyncError.self) {
            try AppleMusicPlaylistTrackLoader.completeTracks(from: items + [nil])
        }
    }

    @Test("Repeated sync retains each occurrence on one global stats row and preserves local order")
    func duplicateProvenance() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let source = try PlaylistRepository.addTriageSource(AppleMusicPlaylist(id: "source", name: "Source"), in: context)
        let service = PlaylistSyncService()
        let first = try snapshot(entryID: "a", position: 0)
        let second = try snapshot(entryID: "b", position: 4)
        _ = try await service.reconcile(snapshots: [first, second], playlistRecord: source, syncedAt: .now, in: context)
        let items = try PlaylistItemRepository.allItems(in: context)
        let item = try #require(items.first)
        #expect(items.count == 1)
        item.playthroughCount = 8
        item.skipCount = 3
        let itemID = item.id
        let bucket = try PlaylistRepository.triageBucket(in: context)
        let order = PlaybackOrderStore.state(playerID: "main", musicPlaylistID: bucket.musicPlaylistID).orderedTrackIDs
        _ = try await service.reconcile(snapshots: [second, first], playlistRecord: source, syncedAt: .now, in: context)
        #expect(item.id == itemID)
        #expect(item.playthroughCount == 8)
        #expect(item.skipCount == 3)
        #expect(item.entryProvenance.map(\.entryID) == ["b", "a"])
        #expect(item.entryProvenance.map(\.position) == [4, 0])
        #expect(PlaybackOrderStore.state(playerID: "main", musicPlaylistID: bucket.musicPlaylistID).orderedTrackIDs == order)
        try context.save()
        let reloaded = try #require(try PlaylistItemRepository.item(id: itemID, in: ModelContext(container)))
        #expect(reloaded.entryProvenance.count == 2)
        _ = try await service.reconcile(snapshots: [first], playlistRecord: source, syncedAt: .now, in: context)
        #expect(item.entryProvenance.map(\.entryID) == ["a"])
        #expect(item.sourceMusicPlaylistIDs == ["source"])
        try PlaylistRepository.removeTriageSource(source, in: context)
        #expect(item.entryProvenance.isEmpty)
        #expect(item.playthroughCount == 8)
    }

    @Test("Merging and source healing preserve independent occurrences without duplicating observations")
    func mergeAndHeal() throws {
        let keeper = PlaylistItemRecord(playlistID: UUID(), trackID: UUID())
        let donor = PlaylistItemRecord(playlistID: keeper.playlistID, trackID: keeper.trackID)
        keeper.entryProvenance = [PlaylistEntryProvenance(snapshot: try snapshot(entryID: "a", position: 0), playlistID: "old", observedAt: .distantPast)]
        donor.entryProvenance = [PlaylistEntryProvenance(snapshot: try snapshot(entryID: "b", position: 1), playlistID: "old", observedAt: .now)]
        PlaylistItemRepository.mergeStats(from: donor, into: keeper, adoptEvictionStateIfNewer: false)
        #expect(keeper.entryProvenance.count == 2)
        #expect(keeper.replaceSourceMusicPlaylistID(from: "old", to: "new"))
        #expect(keeper.entryProvenance.allSatisfy { $0.playlistID == "new" })
        keeper.entryProvenance = PlaylistEntryProvenance.merging(keeper.entryProvenance + keeper.entryProvenance)
        #expect(keeper.entryProvenance.count == 2)
        #expect(keeper.removeSourceMusicPlaylistID("new"))
        #expect(keeper.entryProvenance.isEmpty)
    }

    @Test("Entry counters carry diagnostic origin into the proof boundary")
    func diagnosticOrigin() throws {
        var observation = try snapshot(entryID: "a", position: 0)
        observation.entryPlayCount = 5
        observation.entryLastPlayedDate = Date(timeIntervalSince1970: 100)
        let provenance = PlaylistEntryProvenance(snapshot: observation, playlistID: "source", observedAt: .now)
        let restored = try JSONDecoder().decode(PlaylistEntryProvenance.self, from: JSONEncoder().encode(provenance))
        #expect(restored == provenance)
        #expect(provenance.playbackEvidence.lastPlayedDate == observation.entryLastPlayedDate)
        #expect(provenance.playbackEvidence.playlistEntryEvidence == true)
        #expect(provenance.playbackEvidence.playCount == 5)
        #expect(provenance.playbackEvidence.musicItemID == "123")
    }

    @Test("Unavailable entries abort source sync before clearing OTP suppression")
    func unavailableSync() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = try JSONDecoder().decode(Playlist.self, from: Data(#"{"id":"source","type":"library-playlists","attributes":{"name":"Source","canEdit":true}}"#.utf8))
        let fetcher = EntryPlaylistFetcher(playlist: playlist)
        let unavailable = try makeEntry(id: "unavailable", position: 0)
        let adapter = AppleMusicPlaylistSourceSync(playlistFetcher: fetcher, entryLoader: { _ in [unavailable] })
        let record = PlaylistRecord(musicPlaylistID: "source", name: "Source", role: .oneTruePlaylist)
        context.insert(record)
        let bucket = try PlaylistRepository.triageBucket(in: context)
        let track = TrackRecord(catalogID: "123", title: "Song", artistName: "Artist")
        context.insert(track)
        let item = PlaylistItemRecord(playlistID: bucket.id, trackID: track.id, suppressedOTPMusicPlaylistIDs: ["source"], playthroughCount: 2)
        context.insert(item)
        try context.save()
        let service = PlaylistSyncService(sourceRegistry: PlaylistSourceSyncRegistry(adapters: [.appleMusic: adapter]))
        await #expect(throws: PlaylistSyncError.self) { try await service.syncPlaylist(record, in: context) }
        #expect(item.suppressedOTPMusicPlaylistIDs == ["source"])
        #expect(item.playthroughCount == 2)
        #expect(record.lastSyncedAt == nil)
        #expect(!record.hasSyncedPlaylistEntries)
    }

    @Test("Track-only syncs fetch entries once before the unchanged shortcut")
    func initialEntryFetch() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let json = #"{"id":"source","type":"library-playlists","attributes":{"name":"Source","canEdit":true,"lastModifiedDate":"2026-09-12T12:00:00Z"}}"#
        let playlist = try JSONDecoder().decode(Playlist.self, from: Data(json.utf8))
        let modified = try #require(playlist.lastModifiedDate)
        let record = PlaylistRecord(musicPlaylistID: "source", name: "Source", lastSyncedAt: .now, remoteLastModifiedAt: modified)
        context.insert(record)
        var reads = 0
        let adapter = AppleMusicPlaylistSourceSync(playlistFetcher: EntryPlaylistFetcher(playlist: playlist), entryLoader: { _ in
            reads += 1
            return []
        })
        let first = try await adapter.fetchTrackSnapshots(playlistID: "source", playlistName: nil, playlistRecord: record, skipWhenRemoteUnchanged: true, in: context)
        #expect(first.didFetchEntries)
        #expect(reads == 1)
        record.hasSyncedPlaylistEntries = true
        let second = try await adapter.fetchTrackSnapshots(playlistID: "source", playlistName: nil, playlistRecord: record, skipWhenRemoteUnchanged: true, in: context)
        #expect(!second.didFetchTracks)
        #expect(reads == 1)
    }

    private func snapshot(entryID: String, position: Int) throws -> TrackSnapshot {
        try #require(AppleMusicPlaylistTrackLoader.snapshot(from: makeEntry(id: entryID, position: position), item: .song(makeSong()), playlistID: "source"))
    }

    private func makeEntry(id: String, position: Int) throws -> Playlist.Entry {
        let json = """
        {"id":"\(id)","type":"library-playlist-entries","attributes":{"position":\(position),"name":"Song","artistName":"Artist","albumName":"Album","genreNames":[],"durationInMillis":180000,"isrc":"ENTRY-ISRC","playCount":5}}
        """
        return try JSONDecoder().decode(Playlist.Entry.self, from: Data(json.utf8))
    }

    private func makeSong() throws -> Song {
        let json = #"{"id":"123","type":"songs","attributes":{"name":"Song","artistName":"Artist","albumName":"Album","durationInMillis":180000,"genreNames":[],"isrc":"USABC1234567"}}"#
        return try JSONDecoder().decode(Song.self, from: Data(json.utf8))
    }
}

@MainActor
private struct EntryPlaylistFetcher: MusicLibraryPlaylistFetching {
    var playlist: Playlist
    func fetchAllPlaylists(pageLimit: Int) async throws -> [Playlist] { [playlist] }
    func fetchPlaylist(id: String) async throws -> Playlist? { playlist }
}
