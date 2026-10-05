import Foundation
import MusicKit
import SwiftData
import Testing
@testable import Overplay

/// IDs and relationships captured by the read-only Designed for iPad probe on
/// 2026-09-27. The native lookup, not metadata similarity, proves each mapping.
@MainActor
struct MusicLibraryIdentityImportTests {
    struct Sample {
        let nativeID: String
        let libraryID: String
        let catalogID: String?
        let title: String
        let artist: String
    }

    private let samples = [
        Sample(nativeID: "-3140821922437280474", libraryID: "i.O1RQbZGuVYYl7v", catalogID: "878984806", title: "Archie, Marry Me", artist: "Alvvays"),
        Sample(nativeID: "-2540034726386153049", libraryID: "i.1YBNxGGsqAAPdr", catalogID: nil, title: "All Nighter", artist: "Elastica"),
        Sample(nativeID: "7155078121927443764", libraryID: "i.1YBNkWOHqAAPdr", catalogID: "925214201", title: "California Stars", artist: "Wilco")
    ]

    @Test("Playlist-native IDs resolve before import; repeated sync preserves UUIDs, membership and history")
    func repeatedImport() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlistID = "identity-probe-\(UUID())"
        let record = PlaylistRecord(musicPlaylistID: playlistID, name: "Probe", role: .oneTruePlaylist)
        context.insert(record)
        var tracks: [TrackRecord] = []
        var items: [PlaylistItemRecord] = []
        for sample in samples {
            let track = TrackRecord(catalogID: sample.catalogID, libraryID: sample.libraryID, title: sample.title, artistName: sample.artist)
            track.equivalentCatalogIDs = ["previous-review-candidate"]
            let item = PlaylistItemRecord(playlistID: record.id, trackID: track.id, skipCount: 2, playthroughCount: 7)
            context.insert(track); context.insert(item)
            tracks.append(track); items.append(item)
        }
        try context.save()
        let trackIDs = tracks.map(\.id)
        let itemIDs = items.map(\.id)
        var lookups: [String] = []
        let adapter = try makeAdapter(playlistID: playlistID, resolve: { id in
            lookups.append(id.rawValue)
            let sample = try #require(samples.first { $0.nativeID == id.rawValue })
            return .library(try song(sample, id: sample.libraryID))
        })
        let service = PlaylistSyncService(sourceRegistry: .init(adapters: [.appleMusic: adapter]))
        for _ in 0..<2 {
            let summary = try await service.syncPlaylist(record, in: context)
            #expect(summary.insertedCount == 0)
            #expect(try TrackRecordRepository.allTracks(in: context).count == 3)
            #expect(try PlaylistItemRepository.items(forPlaylistID: record.id, in: context).count == 3)
        }
        #expect(lookups.count == 6)
        #expect(tracks.map(\.id) == trackIDs)
        #expect(items.map(\.id) == itemIDs)
        #expect(items.allSatisfy { $0.playthroughCount == 7 && $0.skipCount == 2 })
        #expect(tracks.map(\.libraryID) == samples.map { Optional($0.libraryID) })
        #expect(tracks[1].catalogID == nil)
        #expect(tracks.allSatisfy { $0.identityAliases.isEmpty })
        #expect(tracks.allSatisfy { $0.equivalentCatalogIDs == ["previous-review-candidate"] })
        for (track, sample) in zip(tracks, samples) {
            let playable = try JSONDecoder().decode(Track.self, from: #require(track.musicKitPlaybackData))
            #expect(playable.id.rawValue == sample.libraryID)
        }
    }

    @Test("Unresolved native lookup prevents the entire import, including earlier resolved entries")
    func failedResolutionDoesNotPartiallyImport() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let record = PlaylistRecord(musicPlaylistID: "failed-identity", name: "Probe", role: .oneTruePlaylist)
        context.insert(record)
        try context.save()
        let adapter = try makeAdapter(playlistID: record.musicPlaylistID, resolve: { id in
            let sample = try #require(samples.first { $0.nativeID == id.rawValue })
            if sample.catalogID == nil { throw MusicLibrarySongResolver.ResolutionError.unresolved(id.rawValue) }
            return .library(try song(sample, id: sample.libraryID))
        })
        let service = PlaylistSyncService(sourceRegistry: .init(adapters: [.appleMusic: adapter]))
        await #expect(throws: MusicLibrarySongResolver.ResolutionError.self) {
            try await service.syncPlaylist(record, in: context)
        }
        #expect(try TrackRecordRepository.allTracks(in: context).isEmpty)
        #expect(try PlaylistItemRepository.items(forPlaylistID: record.id, in: context).isEmpty)
        #expect(record.lastSyncedAt == nil)
        #expect(!record.hasSyncedPlaylistEntries)
    }

    @Test("A missing library resource is unresolved; an explicit empty catalog relationship is valid")
    func absentResourceDiffersFromNoCatalogMatch() throws {
        // Exact empty response returned for every native numeric ID in the probe.
        #expect(throws: MusicIdentityResolver.ResolutionError.self) {
            try MusicIdentityResolver.decode(Data(#"{"data":[]}"#.utf8), kind: .library, ids: [samples[0].nativeID])
        }
        let upload = samples[1]
        let result = try MusicIdentityResolver.decode(try libraryResponse([upload]), kind: .library, ids: [upload.libraryID])
        #expect(result[upload.libraryID]?.first?.catalog == [])
    }

    @Test("Web lookup misses cannot fall through to raw-ID insertion")
    func webMissDoesNotImport() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let record = PlaylistRecord(musicPlaylistID: "web-miss", name: "Probe", role: .oneTruePlaylist)
        context.insert(record)
        let resolver = MusicIdentityResolver(currentScope: { .init(storefront: "gb", account: "fixture") }, fetch: { kind, ids, _ in
            try MusicIdentityResolver.decode(Data(#"{"data":[]}"#.utf8), kind: kind, ids: ids)
        })
        let adapter = try makeAdapter(playlistID: record.musicPlaylistID, identityResolver: resolver, resolve: { id in
            let sample = try #require(samples.first { $0.nativeID == id.rawValue })
            return .library(try song(sample, id: sample.libraryID))
        })
        let service = PlaylistSyncService(sourceRegistry: .init(adapters: [.appleMusic: adapter]))
        await #expect(throws: MusicIdentityResolver.ResolutionError.self) {
            try await service.syncPlaylist(record, in: context)
        }
        #expect(try TrackRecordRepository.allTracks(in: context).isEmpty)
        #expect(record.lastSyncedAt == nil)
    }

    @Test("Duplicate occurrences resolve once; the API result establishes the domain")
    func occurrencesAndExplicitDomain() async throws {
        let sample = samples[0]
        let native = try song(sample, id: sample.nativeID)
        let catalog = try song(sample, id: #require(sample.catalogID), type: "songs")
        var calls = 0
        let snapshots = try await AppleMusicPlaylistTrackLoader.resolvedSongSnapshots(
            from: [.song(native), .song(native)], playlistID: "copy", resolve: { _ in
                calls += 1
                return .catalog(catalog)
            }
        )
        #expect(calls == 1)
        #expect(snapshots.count == 2)
        #expect(snapshots.allSatisfy { $0.libraryID == nil && $0.catalogID == sample.catalogID })
    }

    private func makeAdapter(
        playlistID: String, identityResolver: MusicIdentityResolver? = nil,
        resolve: @escaping (MusicItemID) async throws -> MusicLibrarySongResolver.Resolution
    ) throws -> AppleMusicPlaylistSourceSync {
        let playlist = try JSONDecoder().decode(Playlist.self, from: JSONSerialization.data(withJSONObject: [
            "id": playlistID, "type": "library-playlists", "attributes": ["name": "Probe", "canEdit": true]
        ]))
        let entries = try samples.enumerated().map { index, sample in
            try JSONDecoder().decode(Playlist.Entry.self, from: JSONSerialization.data(withJSONObject: [
                "id": sample.nativeID, "type": "library-playlist-entries",
                "attributes": ["position": index, "name": sample.title, "artistName": sample.artist]
            ]))
        }
        let songs = try Dictionary(uniqueKeysWithValues: samples.map { ($0.nativeID, try song($0, id: $0.nativeID)) })
        let resolver = identityResolver ?? MusicIdentityResolver(currentScope: { .init(storefront: "gb", account: "fixture") }, fetch: { kind, ids, _ in
            // Duplicate-review suggestions are not a prerequisite for import.
            #expect(kind != .isrc && kind != .equivalents)
            if kind == .library {
                return try MusicIdentityResolver.decode(libraryResponse(samples.filter { ids.contains($0.libraryID) }), kind: kind, ids: ids)
            }
            return Dictionary(uniqueKeysWithValues: ids.map { id in
                (id, kind == .catalog ? [MusicIdentityResolver.Resource(id: id, type: "songs", attributes: .init(isrc: "fixture-recording"))] : [])
            })
        })
        return AppleMusicPlaylistSourceSync(
            playlistFetcher: ProbePlaylistFetcher(playlist: playlist), entryLoader: { _ in entries },
            songResolver: resolve, identityResolver: resolver,
            entryItem: { entry in songs[entry.id.rawValue].map { .song($0) } }
        )
    }

    private func song(_ sample: Sample, id: String, type: String = "library-songs") throws -> Song {
        try JSONDecoder().decode(Song.self, from: JSONSerialization.data(withJSONObject: [
            "id": id, "type": type,
            "attributes": ["name": sample.title, "artistName": sample.artist, "albumName": "Fixture", "genreNames": []]
        ]))
    }

    private func libraryResponse(_ samples: [Sample]) throws -> Data {
        let data: [[String: Any]] = samples.map { sample in
            let catalog: [[String: Any]] = sample.catalogID.map { [["id": $0, "type": "songs"]] } ?? []
            return ["id": sample.libraryID, "type": "library-songs", "relationships": ["catalog": ["data": catalog]]]
        }
        return try JSONSerialization.data(withJSONObject: ["data": data])
    }
}

@MainActor
private struct ProbePlaylistFetcher: MusicLibraryPlaylistFetching {
    let playlist: Playlist
    func fetchAllPlaylists(pageLimit: Int) async throws -> [Playlist] { [playlist] }
    func fetchPlaylist(id: String) async throws -> Playlist? { playlist }
}
