import Foundation
import ImageIO
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

    @Test func webArtworkTemplatesAreExpandedAtTheDownloadBoundary() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = ArtworkCacheService(rootDirectory: directory, downloader: { url in
            #expect(url.absoluteString == "https://example.com/cover/512x512bb.jpg")
            return artworkTestData()
        })
        let file = await service.artworkFileURL(for: "https://example.com/cover/{w}x{h}bb.jpg", pixelSize: 128)
        #expect(file != nil)
        #expect(PortableArtworkReference.requestURL("musicKit://native-artwork") == nil)
        #expect(PortableArtworkReference.requestURL("https://example.com/{unknown}") == nil)
    }

    @Test("manifest persists and cached file is reused without download")
    func manifestPersistsAndCachedFileIsReusedWithoutDownload() async throws {
        let rootDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let sourceURL = "https://example.com/artwork.jpg"
        let service = ArtworkCacheService(
            rootDirectory: rootDirectory,
            downloader: { _ in artworkTestData() }
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

        #expect(firstManifest.entries.count == 2)
        #expect(FileManager.default.fileExists(atPath: firstURL.path))
        #expect(cachedURL == firstURL)
        #expect(try artworkDimensions(at: cachedURL) == [512, 256])
    }

    @Test("read only cached lookup reuses file without updating access metadata")
    func readOnlyCachedLookupReusesFileWithoutUpdatingAccessMetadata() async throws {
        let rootDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let sourceURL = "https://example.com/artwork.jpg"
        let accessedAt = Date(timeIntervalSince1970: 100)
        let service = ArtworkCacheService(
            rootDirectory: rootDirectory,
            downloader: { _ in artworkTestData() }
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
        #expect(try artworkDimensions(at: cachedURL) == [512, 256])
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
                artworkTestData()
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

    @Test("recently accessed playlist-less artwork outlives stale playlist artwork")
    func recentlyAccessedPlaylistLessArtworkOutlivesStalePlaylistArtwork() async throws {
        let rootDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let staleSourceURL = "https://example.com/stale.jpg"
        let searchSourceURL = "https://example.com/search.jpg"
        let service = ArtworkCacheService(
            rootDirectory: rootDirectory,
            maxCacheBytes: 10,
            downloader: { _ in artworkTestData() }
        )

        let staleURL = try #require(await service.artworkFileURL(
            for: staleSourceURL,
            pixelSize: 96,
            playlistID: "stale-playlist",
            accessedAt: Date(timeIntervalSince1970: 10)
        ))
        let searchURL = try #require(await service.artworkFileURL(
            for: searchSourceURL,
            pixelSize: 96,
            playlistID: nil,
            accessedAt: Date(timeIntervalSince1970: 100)
        ))
        let manifest = try await service.manifestSnapshot()

        #expect(manifest.entries.count == 1)
        #expect(manifest.entries.values.first?.sourceURL == searchSourceURL)
        #expect(!FileManager.default.fileExists(atPath: staleURL.path))
        #expect(FileManager.default.fileExists(atPath: searchURL.path))
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
            downloader: { _ in artworkTestData() }
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
        #expect(persisted.entries.count == 2)
    }

    @Test("orphaned disk files are re-adopted without downloading")
    func orphanedDiskFilesAreReAdoptedWithoutDownloading() async throws {
        let rootDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let sourceURL = "https://example.com/artwork.jpg"
        let key = ArtworkCacheService.cacheKey(sourceURL: sourceURL, pixelSize: 512)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let orphanURL = rootDirectory.appendingPathComponent("\(key).jpg")
        try artworkTestData().write(to: orphanURL)

        let service = ArtworkCacheService(
            rootDirectory: rootDirectory,
            downloader: { _ in throw URLError(.notConnectedToInternet) }
        )

        let adoptedURL = try #require(await service.artworkFileURL(
            for: sourceURL,
            pixelSize: 512,
            playlistID: "playlist-1"
        ))
        let manifest = try await service.manifestSnapshot()

        #expect(adoptedURL == orphanURL)
        #expect(try Data(contentsOf: adoptedURL) == artworkTestData())
        #expect(manifest.entries[key]?.byteSize == artworkTestData().count)
        #expect(manifest.entries[key]?.associatedPlaylistIDs.contains("playlist-1") == true)
        #expect(manifest.playlistUsage["playlist-1"] != nil)
    }

    @Test("read-only cached lookup re-adopts orphaned disk files")
    func readOnlyCachedLookupReAdoptsOrphanedDiskFiles() async throws {
        let rootDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let sourceURL = "https://example.com/artwork.jpg"
        let key = ArtworkCacheService.cacheKey(sourceURL: sourceURL, pixelSize: 512)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let orphanURL = rootDirectory.appendingPathComponent("\(key).jpg")
        try artworkTestData().write(to: orphanURL)

        let service = ArtworkCacheService(
            rootDirectory: rootDirectory,
            downloader: { _ in throw URLError(.notConnectedToInternet) }
        )

        let adoptedURL = try #require(await service.cachedArtworkFileURL(
            for: sourceURL,
            pixelSize: 512
        ))
        let manifest = try await service.manifestSnapshot()

        #expect(adoptedURL == orphanURL)
        #expect(manifest.entries[key] != nil)
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
                return artworkTestData()
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
        #expect(manifest.entries.count == 4)
        #expect(FileManager.default.fileExists(atPath: fastURL.path))
        #expect(FileManager.default.fileExists(atPath: slowURL.path))
        #expect(await service.cachedArtworkFileURL(for: "https://example.com/fast.jpg", pixelSize: 512) == fastURL)
        #expect(await service.cachedArtworkFileURL(for: "https://example.com/slow.jpg", pixelSize: 512) == slowURL)
    }

    @Test("one download creates real bounded representations and shares albums across playlists")
    func realSizesAndSharedDownload() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = ArtworkDownloadCounter()
        let service = ArtworkCacheService(rootDirectory: directory, downloader: { _ in
            await counter.increment()
            return artworkTestData()
        })
        async let small = service.artworkFileURL(for: "https://example.com/shared.jpg", pixelSize: 128, playlistID: "one")
        async let large = service.artworkFileURL(for: "https://example.com/shared.jpg", pixelSize: 512, playlistID: "two")
        let (smallResult, largeResult) = await (small, large)
        let smallURL = try #require(smallResult)
        let largeURL = try #require(largeResult)
        #expect(try artworkDimensions(at: smallURL) == [128, 64])
        #expect(try artworkDimensions(at: largeURL) == [512, 256])
        #expect(await counter.value == 1)
        let entries = try await service.manifestSnapshot().entries.values
        #expect(entries.allSatisfy { $0.associatedPlaylistIDs == ["one", "two"] })
        await service.flushPendingManifestSave()
    }

    @Test("failed artwork requests are cooled down instead of retried for every row")
    func failureCooldown() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = ArtworkDownloadCounter()
        let service = ArtworkCacheService(rootDirectory: directory, downloader: { _ in
            await counter.increment()
            throw URLError(.notConnectedToInternet)
        })
        for _ in 0..<10 {
            #expect(await service.artworkFileURL(for: "https://example.com/missing.jpg", pixelSize: 128) == nil)
        }
        #expect(await counter.value == 1)
    }

    @Test("thumbnail can be regenerated from cached large artwork offline")
    func regenerateThumbnail() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = ArtworkCacheService(rootDirectory: directory, downloader: { _ in artworkTestData() })
        _ = await service.artworkFileURL(for: "https://example.com/album.jpg", pixelSize: 512)
        let small = try #require(await service.cachedArtworkFileURL(for: "https://example.com/album.jpg", pixelSize: 128))
        try FileManager.default.removeItem(at: small)
        await service.flushPendingManifestSave()
        let offline = ArtworkCacheService(rootDirectory: directory, downloader: { _ in throw URLError(.notConnectedToInternet) })
        let regenerated = try #require(await offline.artworkFileURL(for: "https://example.com/album.jpg", pixelSize: 128))
        #expect(try artworkDimensions(at: regenerated) == [128, 64])
        await offline.flushPendingManifestSave()
    }

    @Test("a re-signed pre-signed artwork URL reuses the cached asset")
    func preSignedURLsShareOneCacheEntry() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = "https://store-035.blobstore.apple.com/sq/82/96/ff/image"
        let monday = "\(base)?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Date=20260927T084722Z"
            + "&X-Amz-Expires=86400&X-Amz-Signature=aaaa"
        let tuesday = "\(base)?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Date=20260928T084722Z"
            + "&X-Amz-Expires=86400&X-Amz-Signature=bbbb"
        #expect(ArtworkCacheService.cacheKey(sourceURL: monday, pixelSize: 512)
            == ArtworkCacheService.cacheKey(sourceURL: tuesday, pixelSize: 512))
        // A non-signing query still distinguishes two different assets.
        #expect(ArtworkCacheService.cacheKey(sourceURL: "\(base)?id=1", pixelSize: 512)
            != ArtworkCacheService.cacheKey(sourceURL: "\(base)?id=2", pixelSize: 512))

        let counter = ArtworkDownloadCounter()
        let service = ArtworkCacheService(rootDirectory: directory, downloader: { _ in
            await counter.increment()
            return artworkTestData()
        })
        #expect(await service.artworkFileURL(for: monday, pixelSize: 512) != nil)
        #expect(await service.artworkFileURL(for: tuesday, pixelSize: 512) != nil)
        #expect(await counter.value == 1)
        await service.flushPendingManifestSave()
    }

    @Test("an expired artwork credential is refused instead of retried every cooldown")
    func permanentFailuresAreNotRetriedAfterTheCooldown() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "https://store-035.blobstore.apple.com/sq/82/96/ff/image?X-Amz-Signature=aaaa"
        let counter = ArtworkDownloadCounter()
        let service = ArtworkCacheService(
            rootDirectory: directory,
            failureRetryInterval: 0,
            downloader: { _ in
                await counter.increment()
                throw NSError(domain: ArtworkCacheService.httpErrorDomain, code: 406)
            }
        )
        for _ in 0..<5 {
            #expect(await service.artworkFileURL(for: source, pixelSize: 512) == nil)
        }
        #expect(await counter.value == 1)
        #expect(await service.hasPermanentlyFailed(source))
        #expect(await service.permanentlyFailedSourceURLs() == [source])

        await service.clearPermanentFailures([source])
        #expect(await service.permanentlyFailedSourceURLs().isEmpty)
        // Reporting is drained; the refusal itself must survive it.
        #expect(await service.hasPermanentlyFailed(source))
    }

    @Test("a transient failure is retried once its cooldown expires")
    func transientFailuresStayRetryable() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "https://example.com/flaky.jpg"
        let counter = ArtworkDownloadCounter()
        let service = ArtworkCacheService(
            rootDirectory: directory,
            failureRetryInterval: 0,
            downloader: { _ in
                await counter.increment()
                throw NSError(domain: ArtworkCacheService.httpErrorDomain, code: 429)
            }
        )
        for _ in 0..<3 {
            #expect(await service.artworkFileURL(for: source, pixelSize: 512) == nil)
        }
        #expect(await counter.value == 3)
        #expect(await service.hasPermanentlyFailed(source) == false)
        #expect(await service.permanentlyFailedSourceURLs().isEmpty)
    }

    @Test("a templated thumbnail is rebuilt from the cached master without downloading")
    func templatedThumbnailReusesTheCachedMaster() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let template = "https://example.com/cover/{w}x{h}bb.jpg"
        let service = ArtworkCacheService(rootDirectory: directory, downloader: { _ in artworkTestData() })
        _ = await service.artworkFileURL(for: template, pixelSize: 512)
        let small = try #require(await service.cachedArtworkFileURL(for: template, pixelSize: 128))
        try FileManager.default.removeItem(at: small)
        await service.flushPendingManifestSave()

        let offline = ArtworkCacheService(rootDirectory: directory, downloader: { _ in
            throw URLError(.notConnectedToInternet)
        })
        let regenerated = try #require(await offline.artworkFileURL(for: template, pixelSize: 128))
        #expect(try artworkDimensions(at: regenerated) == [128, 64])
        await offline.flushPendingManifestSave()
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
