import Foundation
import Testing
@testable import Overplay

@Suite("Artwork cache service")
struct ArtworkCacheServiceTests {
    @Test("cache keys are stable for normalized URL and size")
    func cacheKeysAreStableForNormalizedURLAndSize() {
        let firstKey = ArtworkCacheService.cacheKey(
            sourceURL: " https://example.com/artwork.jpg ",
            pixelSize: 512
        )
        let secondKey = ArtworkCacheService.cacheKey(
            sourceURL: "https://example.com/artwork.jpg",
            pixelSize: 512
        )
        let differentSizeKey = ArtworkCacheService.cacheKey(
            sourceURL: "https://example.com/artwork.jpg",
            pixelSize: 96
        )

        #expect(firstKey == secondKey)
        #expect(firstKey != differentSizeKey)
    }

    @Test("manifest persists and cached file is reused without download")
    func manifestPersistsAndCachedFileIsReusedWithoutDownload() async throws {
        let rootDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let sourceURL = "https://example.com/artwork.jpg"
        let service = ArtworkCacheService(
            rootDirectory: rootDirectory,
            downloader: { _ in Data("cached-artwork".utf8) }
        )

        let firstURL = try #require(await service.artworkFileURL(
            for: sourceURL,
            pixelSize: 512,
            playlistID: "playlist-1",
            accessedAt: Date(timeIntervalSince1970: 100)
        ))
        let firstManifest = try await service.manifestSnapshot()
        await service.flushPendingManifestSave()

        let cachedOnlyService = ArtworkCacheService(
            rootDirectory: rootDirectory,
            downloader: { _ in throw URLError(.notConnectedToInternet) }
        )
        let cachedURL = try #require(await cachedOnlyService.artworkFileURL(
            for: sourceURL,
            pixelSize: 512,
            playlistID: "playlist-1",
            accessedAt: Date(timeIntervalSince1970: 200)
        ))

        #expect(firstManifest.entries.count == 1)
        #expect(FileManager.default.fileExists(atPath: firstURL.path))
        #expect(cachedURL == firstURL)
        #expect(try Data(contentsOf: cachedURL) == Data("cached-artwork".utf8))
    }

    @Test("read only cached lookup reuses file without updating access metadata")
    func readOnlyCachedLookupReusesFileWithoutUpdatingAccessMetadata() async throws {
        let rootDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let sourceURL = "https://example.com/artwork.jpg"
        let accessedAt = Date(timeIntervalSince1970: 100)
        let service = ArtworkCacheService(
            rootDirectory: rootDirectory,
            downloader: { _ in Data("cached-artwork".utf8) }
        )

        let firstURL = try #require(await service.artworkFileURL(
            for: sourceURL,
            pixelSize: 512,
            playlistID: "playlist-1",
            accessedAt: accessedAt
        ))
        await service.flushPendingManifestSave()
        let cachedOnlyService = ArtworkCacheService(
            rootDirectory: rootDirectory,
            downloader: { _ in throw URLError(.notConnectedToInternet) }
        )

        let cachedURL = try #require(await cachedOnlyService.cachedArtworkFileURL(
            for: sourceURL,
            pixelSize: 512
        ))
        let manifest = try await cachedOnlyService.manifestSnapshot()
        let entry = try #require(manifest.entries.values.first)

        #expect(cachedURL == firstURL)
        #expect(try Data(contentsOf: cachedURL) == Data("cached-artwork".utf8))
        #expect(entry.lastAccessedAt == accessedAt)
        #expect(manifest.playlistUsage["playlist-1"] == accessedAt)
    }

    @Test("eviction removes artwork from least recently used playlists first")
    func evictionRemovesArtworkFromLeastRecentlyUsedPlaylistsFirst() async throws {
        let rootDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let oldSourceURL = "https://example.com/old.jpg"
        let newSourceURL = "https://example.com/new.jpg"
        let service = ArtworkCacheService(
            rootDirectory: rootDirectory,
            maxCacheBytes: 10,
            downloader: { url in
                Data(repeating: url.lastPathComponent == "old.jpg" ? UInt8(1) : UInt8(2), count: 8)
            }
        )

        let oldURL = try #require(await service.artworkFileURL(
            for: oldSourceURL,
            pixelSize: 96,
            playlistID: "old-playlist",
            accessedAt: Date(timeIntervalSince1970: 10)
        ))
        let newURL = try #require(await service.artworkFileURL(
            for: newSourceURL,
            pixelSize: 96,
            playlistID: "new-playlist",
            accessedAt: Date(timeIntervalSince1970: 100)
        ))
        let manifest = try await service.manifestSnapshot()

        #expect(manifest.entries.count == 1)
        #expect(manifest.entries.values.first?.sourceURL == newSourceURL)
        #expect(!FileManager.default.fileExists(atPath: oldURL.path))
        #expect(FileManager.default.fileExists(atPath: newURL.path))
    }

    @Test("failed download returns nil without caching an entry")
    func failedDownloadReturnsNilWithoutCachingAnEntry() async throws {
        let rootDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let service = ArtworkCacheService(
            rootDirectory: rootDirectory,
            downloader: { _ in throw URLError(.badServerResponse) }
        )

        let fileURL = await service.artworkFileURL(
            for: "https://example.com/missing.jpg",
            pixelSize: 512,
            playlistID: "playlist-1"
        )
        let manifest = try await service.manifestSnapshot()

        #expect(fileURL == nil)
        #expect(manifest.entries.isEmpty)
    }

    @Test("manifest writes are debounced until flushed")
    func manifestWritesAreDebouncedUntilFlushed() async throws {
        let rootDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let service = ArtworkCacheService(
            rootDirectory: rootDirectory,
            manifestSaveDelay: .seconds(60),
            downloader: { _ in Data("cached-artwork".utf8) }
        )
        let manifestURL = rootDirectory.appendingPathComponent("manifest.json")

        _ = try #require(await service.artworkFileURL(
            for: "https://example.com/artwork.jpg",
            pixelSize: 512,
            playlistID: "playlist-1"
        ))

        #expect(!FileManager.default.fileExists(atPath: manifestURL.path))

        await service.flushPendingManifestSave()

        #expect(FileManager.default.fileExists(atPath: manifestURL.path))
        let persisted = try JSONDecoder().decode(
            ArtworkCacheManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        #expect(persisted.entries.count == 1)
    }

    @Test("concurrent downloads do not clobber each other's manifest entries")
    func concurrentDownloadsDoNotClobberEachOthersManifestEntries() async throws {
        let rootDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let gate = AsyncGate()
        let service = ArtworkCacheService(
            rootDirectory: rootDirectory,
            downloader: { url in
                if url.lastPathComponent == "slow.jpg" {
                    await gate.wait()
                }
                return Data(url.lastPathComponent.utf8)
            }
        )

        // The slow request suspends the actor inside its download while
        // holding what used to be a stale manifest copy...
        async let slowRequest = service.artworkFileURL(
            for: "https://example.com/slow.jpg",
            pixelSize: 512,
            playlistID: "playlist-1"
        )
        await gate.waitForArrival()

        // ...while the fast request completes fully and records its entry.
        let fastURL = try #require(await service.artworkFileURL(
            for: "https://example.com/fast.jpg",
            pixelSize: 512,
            playlistID: "playlist-1"
        ))

        await gate.open()
        let slowURL = try #require(await slowRequest)

        let manifest = try await service.manifestSnapshot()
        #expect(manifest.entries.count == 2)
        #expect(FileManager.default.fileExists(atPath: fastURL.path))
        #expect(FileManager.default.fileExists(atPath: slowURL.path))
        #expect(await service.cachedArtworkFileURL(for: "https://example.com/fast.jpg", pixelSize: 512) == fastURL)
        #expect(await service.cachedArtworkFileURL(for: "https://example.com/slow.jpg", pixelSize: 512) == slowURL)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("OverplayArtworkCacheTests-\(UUID().uuidString)", isDirectory: true)
    }
}

/// A gate that lets a test park a downloader mid-flight and observe that it
/// has arrived, so actor-reentrancy interleavings can be exercised
/// deterministically.
private actor AsyncGate {
    private var isOpen = false
    private var hasArrived = false
    private var openWaiters: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        hasArrived = true
        for waiter in arrivalWaiters {
            waiter.resume()
        }
        arrivalWaiters.removeAll()

        guard !isOpen else { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in openWaiters {
            waiter.resume()
        }
        openWaiters.removeAll()
    }

    func waitForArrival() async {
        guard !hasArrived else { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }
}
