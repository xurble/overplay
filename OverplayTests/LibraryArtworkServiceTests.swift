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
}
