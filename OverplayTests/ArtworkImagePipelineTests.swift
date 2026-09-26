import Foundation
import CoreGraphics
import Testing
@testable import Overplay

@MainActor
@Suite("Shared artwork image pipeline")
struct ArtworkImagePipelineTests {
    @Test("failed requests do not remain stuck in the decoded in-flight registry")
    func failedRequestCanRecover() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = ArtworkDownloadCounter()
        let disk = ArtworkCacheService(rootDirectory: directory, failureRetryInterval: 0, downloader: { _ in
            await counter.increment()
            if await counter.value == 1 { throw URLError(.notConnectedToInternet) }
            return artworkTestData()
        })
        let pipeline = ArtworkImagePipeline(disk: disk)
        let url = "https://example.com/retry.jpg"
        #expect(await pipeline.image(for: url, size: 128, playlistID: nil) == nil)
        #expect(await pipeline.image(for: url, size: 128, playlistID: nil) != nil)
        #expect(await counter.value == 2)
        await disk.flushPendingManifestSave()
    }

    @Test("decoded memory is shared across playlists and retains both useful sizes")
    func sharedMemory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = ArtworkDownloadCounter()
        let disk = ArtworkCacheService(rootDirectory: directory, downloader: { _ in
            await counter.increment()
            return artworkTestData()
        })
        let pipeline = ArtworkImagePipeline(disk: disk)
        let url = "https://example.com/album.jpg"
        let first = try #require(await pipeline.image(for: url, size: 128, playlistID: "one"))
        let second = try #require(await pipeline.image(for: url, size: 128, playlistID: "two"))
        #expect(first === second)
        #expect(first.width == 128)
        let large = try #require(await pipeline.image(for: url, size: 512, playlistID: "two"))
        #expect(large.width == 512)
        #expect(pipeline.cachedImage(for: url, size: 128) === first)
        #expect(await counter.value == 1)
        await disk.flushPendingManifestSave()
    }
}
