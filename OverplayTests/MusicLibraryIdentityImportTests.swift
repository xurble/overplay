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
        let adapter = try makeAdapter(playlistID: playlistID, resolve: { observed in
            let id = observed.id
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
        let adapter = try makeAdapter(playlistID: record.musicPlaylistID, resolve: { observed in
            let id = observed.id
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
        let adapter = try makeAdapter(playlistID: record.musicPlaylistID, identityResolver: resolver, resolve: { observed in
            let id = observed.id
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
        let snapshots = try await AppleMusicPlaylistTrackLoader.resolveSongs(
            from: [.song(native), .song(native)], playlistID: "copy", resolveAll: Self.perSong { _ in
                calls += 1
                return .catalog(catalog)
            }
        ).requireAll()
        #expect(calls == 1)
        #expect(snapshots.count == 2)
        #expect(snapshots.allSatisfy { $0.libraryID == nil && $0.catalogID == sample.catalogID })
    }

    // MARK: - On-device library lagging the account library (2026-10-05 iPhone probe)

    @Test("A song absent from the on-device library resolves through the web library as the observed entry")
    func webLibraryConfirmsObservedSong() async throws {
        let sample = samples[0]
        let observed = try song(sample, id: sample.libraryID)
        var catalogCalls = 0
        let resolution = try await MusicLibrarySongResolver.resolve(
            observed,
            library: { _ in [] },
            webLibrary: { [$0.rawValue] },
            catalog: { _ in catalogCalls += 1; return [] }
        )
        guard case .library(let resolved) = resolution else { Issue.record("Expected a library resolution"); return }
        #expect(resolved.id == observed.id)
        #expect(resolution.identity.libraryID == sample.libraryID)
        #expect(resolution.identity.catalogID == nil)
        #expect(catalogCalls == 0)
    }

    @Test("An on-device library hit never consults the web library or the catalog")
    func nativeHitWins() async throws {
        let sample = samples[2]
        let native = try song(sample, id: sample.libraryID)
        let resolution = try await MusicLibrarySongResolver.resolve(
            try song(sample, id: sample.nativeID),
            library: { _ in [native] },
            webLibrary: { _ in Issue.record("web library consulted"); return [] },
            catalog: { _ in Issue.record("catalog consulted"); return [] }
        )
        #expect(resolution.identity.libraryID == sample.libraryID)
    }

    @Test("A web-library miss still falls back to an explicit catalog request")
    func webMissFallsBackToCatalog() async throws {
        let sample = samples[0]
        let catalogID = try #require(sample.catalogID)
        let observed = try song(sample, id: catalogID, type: "songs")
        let resolution = try await MusicLibrarySongResolver.resolve(
            observed,
            library: { _ in [] },
            webLibrary: { _ in [] },
            catalog: { _ in [observed] }
        )
        #expect(resolution.identity.catalogID == catalogID)
        #expect(resolution.identity.libraryID == nil)
    }

    @Test("Missing everywhere, or a web library answer for a different ID, is unresolved")
    func unresolvedOutcomes() async throws {
        let sample = samples[0]
        let observed = try song(sample, id: sample.libraryID)
        await #expect(throws: MusicLibrarySongResolver.ResolutionError.self) {
            _ = try await MusicLibrarySongResolver.resolve(
                observed, library: { _ in [] }, webLibrary: { _ in [] }, catalog: { _ in [] })
        }
        await #expect(throws: MusicLibrarySongResolver.ResolutionError.self) {
            _ = try await MusicLibrarySongResolver.resolve(
                observed, library: { _ in [] }, webLibrary: { _ in ["i.someOtherSong"] },
                catalog: { _ in Issue.record("catalog consulted"); return [] })
        }
    }

    @Test("Web library responses count only returned library-song resources")
    func webLibraryResponseParsing() throws {
        #expect(try MusicLibrarySongResolver.webLibrarySongIDs(from: Data(#"{"data":[]}"#.utf8)).isEmpty)
        let ids = try MusicLibrarySongResolver.webLibrarySongIDs(from: libraryResponse(Array(samples.prefix(2))))
        #expect(ids == [samples[0].libraryID, samples[1].libraryID])
        let other = Data(#"{"data":[{"id":"878984806","type":"songs"}]}"#.utf8)
        #expect(try MusicLibrarySongResolver.webLibrarySongIDs(from: other).isEmpty)
    }

    @Test("Playlist sync succeeds when entries carry web library IDs absent from the on-device library")
    func syncWithLaggingOnDeviceLibrary() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let record = PlaylistRecord(musicPlaylistID: "lagging-device-library", name: "Probe", role: .oneTruePlaylist)
        context.insert(record)
        var trackIDs: [UUID] = []
        for sample in samples {
            let track = TrackRecord(catalogID: sample.catalogID, libraryID: sample.libraryID, title: sample.title, artistName: sample.artist)
            context.insert(track)
            context.insert(PlaylistItemRecord(playlistID: record.id, trackID: track.id, skipCount: 1, playthroughCount: 4))
            trackIDs.append(track.id)
        }
        try context.save()
        // As on the iPhone: entries carry `i.` IDs and two songs are missing on device.
        let missingOnDevice: Set<String> = [samples[0].libraryID, samples[2].libraryID]
        let adapter = try makeAdapter(playlistID: record.musicPlaylistID, entrySongID: \.libraryID, resolve: { observed in
            try await MusicLibrarySongResolver.resolve(
                observed,
                library: { id in
                    guard !missingOnDevice.contains(id.rawValue),
                          let sample = samples.first(where: { $0.libraryID == id.rawValue }) else { return [] }
                    return [try song(sample, id: sample.libraryID)]
                },
                webLibrary: { id in samples.contains { $0.libraryID == id.rawValue } ? [id.rawValue] : [] },
                catalog: { _ in Issue.record("catalog consulted"); return [] }
            )
        })
        let service = PlaylistSyncService(sourceRegistry: .init(adapters: [.appleMusic: adapter]))
        let summary = try await service.syncPlaylist(record, in: context)

        #expect(summary.insertedCount == 0)
        #expect(record.lastSyncedAt != nil)
        let tracks = try TrackRecordRepository.allTracks(in: context)
        #expect(Set(tracks.map(\.id)) == Set(trackIDs))
        let items = try PlaylistItemRepository.items(forPlaylistID: record.id, in: context)
        #expect(items.count == 3)
        #expect(items.allSatisfy { $0.playthroughCount == 4 && $0.skipCount == 1 })
        for track in tracks {
            let playable = try JSONDecoder().decode(Track.self, from: #require(track.musicKitPlaybackData))
            #expect(playable.id.rawValue == track.libraryID)
        }
    }

    // MARK: - #64: one unidentifiable song no longer blocks its playlist

    private var fiveSamples: [Sample] {
        samples + [
            Sample(nativeID: "-4", libraryID: "i.four", catalogID: "444", title: "Four", artist: "Band"),
            Sample(nativeID: "-5", libraryID: "i.five", catalogID: "555", title: "Five", artist: "Band")
        ]
    }

    private func seededOTP(_ samples: [Sample], in context: ModelContext) throws -> (PlaylistRecord, [PlaylistItemRecord]) {
        let record = PlaylistRecord(musicPlaylistID: "skips-\(UUID())", name: "Probe", role: .oneTruePlaylist)
        context.insert(record)
        var items: [PlaylistItemRecord] = []
        for sample in samples {
            let track = TrackRecord(catalogID: sample.catalogID, libraryID: sample.libraryID, title: sample.title, artistName: sample.artist)
            let item = PlaylistItemRecord(playlistID: record.id, trackID: track.id, skipCount: 1, playthroughCount: 7)
            context.insert(track); context.insert(item)
            items.append(item)
        }
        try context.save()
        return (record, items)
    }

    @Test("A song nothing can identify is skipped; the rest sync and the playlist keeps retrying")
    func unidentifiableSongIsSkipped() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let samples = fiveSamples
        let (record, items) = try seededOTP(samples, in: context)
        // A retired song absent from the remote playlist: only a complete
        // snapshot may release its stale-membership protection.
        let bucket = try PlaylistRepository.triageBucket(in: context)
        let retiredTrack = TrackRecord(catalogID: "999", title: "Retired", artistName: "Band")
        let retired = PlaylistItemRecord(playlistID: bucket.id, trackID: retiredTrack.id, skipCount: 2)
        retired.evictedAt = .now
        retired.suppressedOTPMusicPlaylistIDs = [record.musicPlaylistID]
        context.insert(retiredTrack); context.insert(retired)
        try context.save()

        var unidentifiable: Set<String> = []
        let adapter = try makeAdapter(playlistID: record.musicPlaylistID, using: samples, resolve: { observed in
            let sample = try #require(samples.first { $0.nativeID == observed.id.rawValue })
            if unidentifiable.contains(sample.nativeID) { throw MusicLibrarySongResolver.ResolutionError.unresolved(sample.nativeID) }
            return .library(try song(sample, id: sample.libraryID))
        })
        let service = PlaylistSyncService(sourceRegistry: .init(adapters: [.appleMusic: adapter]))
        // A complete sync records every song's entry provenance.
        _ = try await service.syncPlaylist(record, in: context)
        let provenance = items[4].entryProvenance
        #expect(!provenance.isEmpty)
        retired.suppressedOTPMusicPlaylistIDs = [record.musicPlaylistID]

        unidentifiable = [samples[4].nativeID]
        let summary = try await service.syncPlaylist(record, in: context)
        #expect(summary.skippedReason == "unresolvedSongs")
        #expect(record.lastSyncedAt != nil)
        #expect(record.lastSyncError == PlaylistSyncService.unresolvedSongsMessage(1))
        // The skipped song's row is untouched: not removed, retired or reset.
        let skipped = items[4]
        #expect(try PlaylistItemRepository.item(id: skipped.id, in: context) != nil)
        #expect(skipped.evictedAt == nil && skipped.playthroughCount == 7 && skipped.skipCount == 1)
        #expect(skipped.entryProvenance == provenance)
        #expect(retired.suppressedOTPMusicPlaylistIDs == [record.musicPlaylistID])

        unidentifiable = []
        _ = try await service.syncPlaylist(record, in: context)
        #expect(record.lastSyncError == nil)
        #expect(retired.suppressedOTPMusicPlaylistIDs.isEmpty)
    }

    @Test("More than a fifth of a playlist unidentifiable still stops the sync, importing nothing")
    func tooManyUnidentifiableSongsAbort() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let samples = fiveSamples
        let record = PlaylistRecord(musicPlaylistID: "too-many", name: "Probe", role: .oneTruePlaylist)
        context.insert(record)
        try context.save()
        let adapter = try makeAdapter(playlistID: record.musicPlaylistID, using: samples, resolve: { observed in
            let sample = try #require(samples.first { $0.nativeID == observed.id.rawValue })
            if sample.nativeID == "-4" || sample.nativeID == "-5" {
                throw MusicLibrarySongResolver.ResolutionError.unresolved(sample.nativeID)
            }
            return .library(try song(sample, id: sample.libraryID))
        })
        let service = PlaylistSyncService(sourceRegistry: .init(adapters: [.appleMusic: adapter]))

        await #expect(throws: MusicLibrarySongResolver.ResolutionError.self) {
            try await service.syncPlaylist(record, in: context)
        }
        #expect(try TrackRecordRepository.allTracks(in: context).isEmpty)
        #expect(record.lastSyncedAt == nil)
        #expect(AppleMusicPlaylistSourceSync.allowsSkipping(1, of: 5))
        #expect(!AppleMusicPlaylistSourceSync.allowsSkipping(2, of: 5))
    }

    /// Adapts a per-song resolver to the batched boundary; an unresolved song
    /// is reported rather than thrown, as the live resolver does.
    static func perSong(
        _ resolve: @escaping (Song) async throws -> MusicLibrarySongResolver.Resolution
    ) -> AppleMusicPlaylistTrackLoader.SongBatchResolver {
        { songs in
            var batch = MusicLibrarySongResolver.BatchResolution()
            for song in songs where batch.resolutions[song.id] == nil && !batch.unresolved.contains(song.id) {
                do { batch.resolutions[song.id] = try await resolve(song) }
                catch is MusicLibrarySongResolver.ResolutionError { batch.unresolved.append(song.id) }
            }
            return batch
        }
    }

    private func makeAdapter(
        playlistID: String, identityResolver: MusicIdentityResolver? = nil,
        entrySongID: (Sample) -> String = \.nativeID,
        using customSamples: [Sample]? = nil,
        resolve: @escaping (Song) async throws -> MusicLibrarySongResolver.Resolution
    ) throws -> AppleMusicPlaylistSourceSync {
        let samples = customSamples ?? self.samples
        let playlist = try JSONDecoder().decode(Playlist.self, from: JSONSerialization.data(withJSONObject: [
            "id": playlistID, "type": "library-playlists", "attributes": ["name": "Probe", "canEdit": true]
        ]))
        let entries = try samples.enumerated().map { index, sample in
            try JSONDecoder().decode(Playlist.Entry.self, from: JSONSerialization.data(withJSONObject: [
                "id": sample.nativeID, "type": "library-playlist-entries",
                "attributes": ["position": index, "name": sample.title, "artistName": sample.artist]
            ]))
        }
        let songs = try Dictionary(uniqueKeysWithValues: samples.map { ($0.nativeID, try song($0, id: entrySongID($0))) })
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
            songResolver: Self.perSong(resolve), identityResolver: resolver,
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
