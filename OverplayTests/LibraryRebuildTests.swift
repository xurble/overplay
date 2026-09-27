import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
struct LibraryRebuildTests {
    private func configuration(reversed: Bool = false) -> LibraryRebuildConfiguration {
        let links = [
            LibraryRebuildConfiguration.Playlist(musicPlaylistID: "p.otp", name: "Overplay", role: "oneTruePlaylist", writePolicy: "managed", sortOrder: 0),
            LibraryRebuildConfiguration.Playlist(musicPlaylistID: "p.source", name: "Incoming", role: "triageSource", writePolicy: "incomingOnly", sortOrder: 1)
        ]
        return .init(rebuildID: UUID(), playlists: reversed ? links.reversed() : links)
    }

    private func snapshot(_ libraryID: String, catalogID: String? = nil) -> TrackSnapshot {
        var value = TrackSnapshot(id: libraryID, catalogID: catalogID, libraryID: libraryID,
            playlistEntryID: "entry-\(libraryID)", playlistID: nil, title: libraryID,
            artistName: "Artist", albumTitle: nil, artworkURLTemplate: nil, durationSeconds: 200)
        value.hasDocumentedIdentity = true
        value.entryPlayCount = 900 // lifetime activity is not imported as Overplay plays
        return value
    }

    private func result(_ snapshots: [TrackSnapshot]) -> PlaylistSourceFetchResult {
        .init(snapshots: snapshots, skippedCount: 0, didFetchEntries: true)
    }

    @Test(arguments: [false, true])
    func completeRebuildHasOneOwnerZeroStatsAndAnIdempotentReceipt(reversed: Bool) async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let config = configuration(reversed: reversed)
        let didBuild = try await LibraryRebuildService.rebuild(config, in: container.mainContext) { link in
            result(link.role == "oneTruePlaylist"
                   ? [snapshot("i.shared", catalogID: "123"), snapshot("i.shared", catalogID: "123")]
                   : [snapshot("i.shared", catalogID: "123"), snapshot("i.upload")])
        }
        #expect(didBuild)
        let context = ModelContext(container)
        let playlists = try PlaylistRepository.allPlaylists(in: context)
        let otp = try #require(playlists.first { $0.role == .oneTruePlaylist })
        let bucket = try #require(playlists.first { $0.isTriageBucket })
        let source = try #require(playlists.first { $0.role == .triageSource })
        #expect(source.writePolicy == .incomingOnly)
        let tracks = try TrackRecordRepository.allTracks(in: context)
        let items = try PlaylistItemRepository.allItems(in: context)
        #expect(tracks.count == 2)
        #expect(items.count == 2)
        let shared = try #require(tracks.first { $0.libraryID == "i.shared" })
        let sharedItem = try #require(items.first { $0.trackID == shared.id })
        #expect(sharedItem.playlistID == otp.id)
        #expect(sharedItem.sourceMusicPlaylistIDs == ["p.source"])
        #expect(Set(sharedItem.entryProvenance.map(\.playlistID)) == ["p.otp", "p.source"])
        #expect(items.first { $0.trackID != shared.id }?.playlistID == bucket.id)
        #expect(items.allSatisfy { $0.skipCount == 0 && $0.playthroughCount == 0 && ($0.applePlayCount ?? 0) == 0 && $0.evictedAt == nil })
        #expect(try context.fetchCount(FetchDescriptor<HistoryEvent>()) == 0)
        let didRepeat = try await LibraryRebuildService.rebuild(config, in: container.mainContext) { _ in
            Issue.record("Completed rebuild must not fetch again")
            return result([])
        }
        #expect(!didRepeat)
    }

    @Test func failedSecondSourcePublishesNoGraphAndCanRetry() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let config = configuration()
        var calls = 0
        do {
            try await LibraryRebuildService.rebuild(config, in: container.mainContext) { _ in
                calls += 1
                if calls == 2 { throw LibraryRebuildService.RebuildError.incompleteSource("Incoming") }
                return result([snapshot("i.first")])
            }
            Issue.record("Expected failed source")
        } catch {}
        #expect(calls == 2)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<TrackRecord>()) == 0)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<PlaylistRecord>()) == 0)
        #expect(try await LibraryRebuildService.rebuild(config, in: container.mainContext) { _ in result([snapshot("i.first")]) })
    }

    @Test func invalidConfigurationAndUnresolvedIdentityFailClosed() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        var config = configuration()
        config.playlists.append(config.playlists[0])
        #expect(throws: (any Error).self) { try config.validate() }
        var unknown = snapshot("native")
        unknown.hasDocumentedIdentity = false
        do {
            try await LibraryRebuildService.rebuild(configuration(), in: container.mainContext) { _ in result([unknown]) }
            Issue.record("Unverified song must not be committed")
        } catch {}
        #expect(try container.mainContext.fetchCount(FetchDescriptor<TrackRecord>()) == 0)
    }

    @Test func existingGraphCannotBeResetByAConfigurationFile() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        container.mainContext.insert(TrackRecord(catalogID: "123", title: "Existing", artistName: "Artist"))
        try container.mainContext.save()
        do {
            try await LibraryRebuildService.rebuild(configuration(), in: container.mainContext) { _ in
                Issue.record("Must reject before fetching")
                return result([])
            }
            Issue.record("Existing graph must not be replaced")
        } catch {}
        #expect(try container.mainContext.fetchCount(FetchDescriptor<TrackRecord>()) == 1)
    }

    @Test func identityDomainsAndLibraryScopesNeverCollide() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let catalog = TrackRecord(catalogID: "123", title: "Catalog", artistName: "Artist")
        let library = TrackRecord(libraryID: "123", title: "Library", artistName: "Artist")
        let otherLibrary = TrackRecord(libraryID: "123", title: "Other library", artistName: "Artist")
        otherLibrary.libraryScope = "another-library"
        catalog.confirmedAliases = [.catalog("alias")]
        library.confirmedAliases = [.library("alias")]
        for track in [catalog, library, otherLibrary] { context.insert(track) }
        try context.save()
        #expect(try TrackRecordRepository.track(catalogID: "alias", libraryID: nil, in: context)?.id == catalog.id)
        #expect(try TrackRecordRepository.track(catalogID: nil, libraryID: "alias", in: context)?.id == library.id)
        #expect(try TrackRecordRepository.track(catalogID: nil, libraryID: "123", libraryScope: "another-library", in: context)?.id == otherLibrary.id)
        let summary = try await TrackIdentityMergeService.mergeDuplicates(in: context)
        #expect(summary.mergedTrackCount == 0)
    }

    @Test func nativePlaybackPayloadIsNotStoredOrUsedAsAMergeKey() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let track = TrackRecord(libraryID: "i.safe", title: "Song", artistName: "Artist", musicKitPlaybackData: Data("native".utf8))
        context.insert(track)
        try context.save()
        let entity = try #require(AppPersistence.schema.entities.first { $0.name == "LibraryTrackV2" })
        #expect(!entity.properties.contains { $0.name == "musicKitPlaybackData" })
        #expect(!entity.properties.contains { $0.name == "identityAliases" })
        #expect(track.identityReferences == [.library("i.safe")])
        #expect(PortableArtworkReference.validated("musicKit://native-artwork") == nil)
        #expect(PortableArtworkReference.validated("https://example.com/{w}x{h}.jpg") != nil)
    }
    @Test func cachePreparationFailureDoesNotPublishAPartialQueue() async throws {
        let first = TrackRecord(libraryID: "i.first", title: "First", artistName: "Artist")
        let second = TrackRecord(catalogID: "second", title: "Second", artistName: "Artist")
        var requests: [MusicResourceReference] = []
        do {
            try await DevicePlaybackCache.prepare([first, second]) { reference in
                requests.append(reference)
                if requests.count == 2 { throw LibraryRebuildService.RebuildError.incompleteSource("Second") }
                return Data("materialized".utf8)
            }
            Issue.record("Expected failure")
        } catch {}
        #expect(requests == [.library("i.first"), .catalog("second")])
        #expect(first.musicKitPlaybackData == nil)
        #expect(second.musicKitPlaybackData == nil)
    }

    @Test func nativeCacheRefreshDoesNotMutateSharedMetadata() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let first = try TrackRecordRepository.upsertWithResult(catalogID: "123", libraryID: nil,
            title: "Song", artistName: "Artist", musicKitPlaybackData: Data("first".utf8), in: context)
        try context.save()
        let date = first.record.updatedAt
        let refreshed = try TrackRecordRepository.upsertWithResult(catalogID: "123", libraryID: nil,
            title: "Song", artistName: "Artist", musicKitPlaybackData: Data("second".utf8), in: context)
        #expect(refreshed.mutation == .unchanged)
        #expect(refreshed.record.updatedAt == date)
        #expect(refreshed.record.musicKitPlaybackData == Data("second".utf8))
        #expect(!context.hasChanges)
    }

    @Test func playlistResourcePaginationRetainsCanonicalIDsAndRejectsLoops() async throws {
        var requests = 0
        let links = try await AppleMusicLibraryPlaylistResources.fetchAll { _ in
            requests += 1
            return Data((requests == 1
                ? #"{"data":[{"id":"p.one","type":"library-playlists","attributes":{"name":"Same"}}],"next":"/v1/me/library/playlists?offset=1"}"#
                : #"{"data":[{"id":"p.two","type":"library-playlists","attributes":{"name":"Same"}}]}"#).utf8)
        }
        #expect(links.map(\.id) == ["p.one", "p.two"])
        #expect(requests == 2)
        do {
            _ = try await AppleMusicLibraryPlaylistResources.fetchAll { _ in
                Data(#"{"data":[{"id":"p.one","type":"library-playlists","attributes":{"name":"Same"}}],"next":"/v1/me/library/playlists?limit=100"}"#.utf8)
            }
            Issue.record("Repeating a page must fail")
        } catch {}
    }

    @Test(arguments: [false, true])
    func multipleLibraryResourcesForOneCatalogSongConvergeWithoutRefreshChurn(reverse: Bool) throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let snapshots = [snapshot("i.a", catalogID: "123"), snapshot("i.z", catalogID: "123")]
        for value in reverse ? snapshots.reversed() : snapshots {
            try TrackRecordRepository.upsert(value, in: context)
        }
        try context.save()
        let tracks = try TrackRecordRepository.allTracks(in: context)
        let track = try #require(tracks.first)
        #expect(tracks.count == 1)
        #expect(track.libraryID == "i.a")
        #expect(track.title == "i.a")
        #expect(track.confirmedAliases.contains(.library("i.z")))
        for value in snapshots + snapshots.reversed() {
            let result = try TrackRecordRepository.upsertWithResult(value, in: context)
            #expect(result.record.id == track.id)
            #expect(result.mutation == .unchanged)
        }
        #expect(!context.hasChanges)
    }

    @Test func cloudDuplicateMergeChoosesTheSameResourceAsImport() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let older = TrackRecord(catalogID: "123", libraryID: "i.z", title: "Z", artistName: "Artist", createdAt: .distantPast)
        let newer = TrackRecord(catalogID: "123", libraryID: "i.a", title: "A", artistName: "Artist")
        context.insert(older)
        context.insert(newer)
        let summary = try await TrackIdentityMergeService.mergeDuplicates(in: context)
        #expect(summary.mergedTrackCount == 1)
        #expect(older.libraryID == "i.a")
        #expect(older.title == "A")
        #expect(older.confirmedAliases.contains(.library("i.z")))
    }

}
