import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
struct LibraryArtworkServiceTests {
    @Test func repairsMetadataWithoutChangingIdentityMembershipOrCounts() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let track = TrackRecord(libraryID: "i.upload", title: "The Hand", artistName: "Artist")
        context.insert(track)
        let item = PlaylistItemRecord(playlistID: UUID(), trackID: track.id, skipCount: 7)
        context.insert(item)
        try context.save()
        let count = try await LibraryArtworkService.repair(in: context) { snapshots in
            var result = snapshots
            result[0].artworkURLTemplate = "https://example.com/art/{w}x{h}.jpg"
            result[0].catalogID = "a-new-match-must-not-change-identity"
            return result
        }
        #expect(count == 1)
        #expect(track.catalogID == nil)
        #expect(track.libraryID == "i.upload")
        #expect(item.skipCount == 7)
        #expect(try context.fetchCount(FetchDescriptor<PlaylistItemRecord>()) == 1)
        #expect(track.artworkURLTemplate == "https://example.com/art/{w}x{h}.jpg")
        #expect(try await LibraryArtworkService.repair(in: context) { _ in
            Issue.record("Already populated artwork must not be fetched again")
            return []
        } == 0)
    }

    @Test func failureDoesNotEraseArtOrPartiallyWriteMetadata() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let track = TrackRecord(libraryID: "i.upload", title: "Song", artistName: "Artist")
        container.mainContext.insert(track)
        try container.mainContext.save()
        await #expect(throws: URLError.self) {
            try await LibraryArtworkService.repair(in: container.mainContext) { _ in
                throw URLError(.notConnectedToInternet)
            }
        }
        #expect(track.artworkURLTemplate == nil)
        #expect(!container.mainContext.hasChanges)
    }

    @Test func anExpiredArtworkCredentialIsDroppedSoItCanBeResolvedAgain() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let expired = "https://store-035.blobstore.apple.com/sq/82/96/ff/image?X-Amz-Signature=aaaa"
        let dead = TrackRecord(libraryID: "i.upload", title: "Uploaded", artistName: "Artist",
                               artworkURLTemplate: expired)
        let alive = TrackRecord(libraryID: "i.other", title: "Catalog", artistName: "Artist",
                                artworkURLTemplate: "https://example.com/art/{w}x{h}.jpg")
        context.insert(dead)
        context.insert(alive)
        try context.save()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OverplayArtworkRepairTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ArtworkCacheService(rootDirectory: directory, downloader: { _ in
            throw NSError(domain: ArtworkCacheService.httpErrorDomain, code: 406)
        })
        #expect(await cache.artworkFileURL(for: expired, pixelSize: 512) == nil)

        #expect(await LibraryArtworkService.discardUnreachableArtwork(in: context, cache: cache) == 1)
        #expect(dead.artworkURLTemplate == nil)
        #expect(alive.artworkURLTemplate == "https://example.com/art/{w}x{h}.jpg")
        #expect(await cache.permanentlyFailedSourceURLs().isEmpty)
        // Now eligible for the repair pass that asks MusicKit for a fresh URL.
        #expect(try await LibraryArtworkService.repair(in: context) { snapshots in
            var result = snapshots
            result[0].artworkURLTemplate = "https://example.com/fresh/{w}x{h}.jpg"
            return result
        } == 1)
        #expect(dead.artworkURLTemplate == "https://example.com/fresh/{w}x{h}.jpg")
    }
}
