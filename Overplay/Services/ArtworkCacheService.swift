import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated struct ArtworkCacheEntry: Codable, Equatable, Sendable {
    var cacheKey: String
    var sourceURL: String
    var pixelSize: Int
    var associatedPlaylistIDs: Set<String>
    var lastAccessedAt: Date
    var byteSize: Int
    var fileName: String
    var representationVersion: Int? = 2
}

nonisolated struct ArtworkCacheManifest: Codable, Equatable, Sendable {
    var entries: [String: ArtworkCacheEntry] = [:]
    var playlistUsage: [String: Date] = [:]
}

actor ArtworkCacheService {
    static let shared = ArtworkCacheService()
    static let defaultMaxCacheBytes = 250 * 1024 * 1024

    private let rootDirectory: URL
    private let manifestURL: URL
    private let maxCacheBytes: Int
    private let manifestSaveDelay: Duration
    private let downloader: @Sendable (URL) async throws -> Data
    private var manifest: ArtworkCacheManifest?
    private var inFlightDownloads: [String: Task<[Int: Data], Error>] = [:]
    private let downloadGate = ArtworkWorkGate(limit: 4)
    private let processingGate = ArtworkWorkGate(limit: 2)
    private var failedUntil: [String: Date] = [:]
    private let failureRetryInterval: TimeInterval
    private var protectedPlaylistID: String?
    private let maxLargeCacheBytes: Int
    private var manifestSaveTask: Task<Void, Never>?

    init(
        rootDirectory: URL? = nil,
        maxCacheBytes: Int = ArtworkCacheService.defaultMaxCacheBytes,
        manifestSaveDelay: Duration = .seconds(1),
        maxLargeCacheBytes: Int = 32 * 1024 * 1024,
        failureRetryInterval: TimeInterval = 60,
        downloader: @escaping @Sendable (URL) async throws -> Data = ArtworkCacheService.download
    ) {
        let rootDirectory = rootDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Overplay", isDirectory: true)
            .appendingPathComponent("ArtworkCache", isDirectory: true)
        self.rootDirectory = rootDirectory
        self.manifestURL = rootDirectory.appendingPathComponent("manifest.json")
        self.maxCacheBytes = maxCacheBytes
        self.maxLargeCacheBytes = maxLargeCacheBytes
        self.failureRetryInterval = failureRetryInterval
        self.manifestSaveDelay = manifestSaveDelay
        self.downloader = downloader
    }

    static func cacheKey(sourceURL: String, pixelSize: Int) -> String {
        let normalizedValue = "v2|\(normalizedSourceURL(sourceURL))|\(sizeBucket(pixelSize))"
        let digest = SHA256.hash(data: Data(normalizedValue.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func sizeBucket(_ size: Int) -> Int { size <= 128 ? 128 : 512 }

    func protectPlaylist(_ playlistID: String?) { protectedPlaylistID = playlistID }

    static func normalizedSourceURL(_ sourceURL: String) -> String {
        sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func artworkFileURL(
        for sourceURL: String?,
        pixelSize: Int,
        playlistID: String? = nil,
        priority: TaskPriority = .background,
        accessedAt: Date = .now,
        protectedPlaylistID: String? = nil
    ) async -> URL? {
        let pixelSize = Self.sizeBucket(pixelSize)
        if let protectedPlaylistID { self.protectedPlaylistID = protectedPlaylistID }
        guard let sourceURL else { return nil }
        let normalizedSourceURL = Self.normalizedSourceURL(sourceURL)
        guard !normalizedSourceURL.isEmpty, let remoteURL = URL(string: normalizedSourceURL) else {
            return nil
        }

        do {
            try ensureCacheDirectoryExists()
            let key = Self.cacheKey(sourceURL: normalizedSourceURL, pixelSize: pixelSize)

            if let cachedURL = try refreshedCachedFileURL(key: key, playlistID: playlistID, accessedAt: accessedAt) {
                scheduleManifestSave()
                MusicKitActivityLog.shared.record(.artworkDiskHit, magnitude: Double(pixelSize))
                return cachedURL
            }

            if let adopted = try adoptedDiskEntry(
                key: key,
                sourceURL: normalizedSourceURL,
                pixelSize: pixelSize,
                playlistID: playlistID,
                accessedAt: accessedAt
            ) {
                scheduleManifestSave()
                return fileURL(for: adopted)
            }

            let variants = try await downloadedVariants(for: remoteURL, priority: priority)
            // Another waiter may have persisted these while this actor suspended.
            for size in [128, 512] {
                let variantKey = Self.cacheKey(sourceURL: normalizedSourceURL, pixelSize: size)
                if try refreshedCachedFileURL(key: variantKey, playlistID: playlistID, accessedAt: accessedAt) != nil { continue }
                guard let data = variants[size] else { continue }
                let entry = try writeArtwork(data, sourceURL: normalizedSourceURL, pixelSize: size,
                    cacheKey: variantKey, playlistID: playlistID, accessedAt: accessedAt)
                try withManifest { $0.entries[variantKey] = entry }
            }
            try enforceCacheLimit(protectedPlaylistID: self.protectedPlaylistID, requestedKey: key)
            scheduleManifestSave()
            return try refreshedCachedFileURL(key: key, playlistID: playlistID, accessedAt: accessedAt)
        } catch {
            return nil
        }
    }

    func cachedArtworkFileURL(
        for sourceURL: String?,
        pixelSize: Int
    ) -> URL? {
        let pixelSize = Self.sizeBucket(pixelSize)
        guard let sourceURL else { return nil }
        let normalizedSourceURL = Self.normalizedSourceURL(sourceURL)
        guard !normalizedSourceURL.isEmpty, URL(string: normalizedSourceURL) != nil else {
            return nil
        }

        do {
            try ensureCacheDirectoryExists()
            let key = Self.cacheKey(sourceURL: normalizedSourceURL, pixelSize: pixelSize)
            guard let entry = try loadManifest().entries[key] ?? adoptedDiskEntry(
                key: key,
                sourceURL: normalizedSourceURL,
                pixelSize: pixelSize,
                playlistID: nil,
                accessedAt: .now
            ) else {
                return nil
            }
            let url = fileURL(for: entry)

            guard FileManager.default.fileExists(atPath: url.path) else {
                try withManifest { manifest in
                    manifest.entries[key] = nil
                }
                scheduleManifestSave()
                return nil
            }

            return url
        } catch {
            return nil
        }
    }

    func touchPlaylistUsage(_ playlistID: String?, at date: Date = .now) async {
        guard let playlistID, !playlistID.isEmpty else { return }

        do {
            try ensureCacheDirectoryExists()
            try withManifest { manifest in
                manifest.playlistUsage[playlistID] = date
            }
            scheduleManifestSave()
        } catch {
            // Artwork cache metadata is disposable; failures should not affect playback or UI.
        }
    }

    func manifestSnapshot() throws -> ArtworkCacheManifest {
        try loadManifest()
    }

    func cachedFileExists(for sourceURL: String, pixelSize: Int) throws -> Bool {
        let key = Self.cacheKey(sourceURL: sourceURL, pixelSize: pixelSize)
        let manifest = try loadManifest()
        guard let entry = manifest.entries[key] else { return false }
        return FileManager.default.fileExists(atPath: fileURL(for: entry).path)
    }

    private static func download(from url: URL) async throws -> Data {
        let startedAt = Date.now
        let started = ContinuousClock.now

        func record(magnitude: Double?, detail: String?, error: Error?) {
            MusicKitActivityLog.shared.record(
                .artworkDownload,
                startedAt: startedAt,
                duration: started.duration(to: .now),
                magnitude: magnitude,
                detail: detail,
                error: error
            )
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(from: url)
        } catch {
            record(magnitude: nil, detail: nil, error: error)
            throw error
        }

        let statusCode = (response as? HTTPURLResponse)?.statusCode
        // Record the HTTP status. URLError(.badServerResponse) discards it,
        // and a throttled or refused status from Apple's artwork CDN is
        // exactly the signal worth keeping.
        if let statusCode, !(200..<300).contains(statusCode) {
            record(
                magnitude: Double(data.count),
                detail: "HTTP \(statusCode)",
                error: NSError(
                    domain: "OverplayArtworkHTTP",
                    code: statusCode,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Artwork download returned HTTP \(statusCode)."
                    ]
                )
            )
            throw URLError(.badServerResponse)
        }

        record(magnitude: Double(data.count), detail: statusCode.map { "HTTP \($0)" }, error: nil)
        return data
    }

    private func downloadedVariants(for url: URL, priority: TaskPriority) async throws -> [Int: Data] {
        let key = url.absoluteString
        if let task = inFlightDownloads[key] {
            MusicKitActivityLog.shared.record(.artworkRequestCoalesced)
            return try await task.value
        }
        if let deadline = failedUntil[key], deadline > .now {
            MusicKitActivityLog.shared.record(.artworkRetrySkipped)
            throw URLError(.resourceUnavailable)
        }
        let largeFile = cachedArtworkFileURL(for: key, pixelSize: 512)
        let task = Task(priority: priority) {
            let wait = PerformanceSpan(.artworkWorkWait)
            await downloadGate.acquire(priority: priority)
            wait.finish(detail: "download")
            let data: Data
            do {
                if let largeFile {
                    data = try await Task.detached(priority: priority) { try Data(contentsOf: largeFile) }.value
                } else {
                    data = try await downloader(url)
                }
            } catch {
                await downloadGate.release()
                throw error
            }
            await processingGate.acquire(priority: priority)
            let result = await Task.detached(priority: priority) {
                Result { try Self.makeVariants(data) }
            }.value
            await processingGate.release()
            await downloadGate.release()
            return try result.get()
        }
        inFlightDownloads[key] = task
        defer { inFlightDownloads[key] = nil }
        do {
            let result = try await task.value
            failedUntil[key] = nil
            return result
        } catch {
            failedUntil = failedUntil.filter { $0.value > .now }
            failedUntil[key] = Date.now.addingTimeInterval(failureRetryInterval)
            throw error
        }
    }

    nonisolated static func makeVariants(_ data: Data) throws -> [Int: Data] {
        let span = PerformanceSpan(.artworkDecode)
        defer { span.finish(magnitude: Double(data.count), detail: "disk variants 128/512") }
        guard let source = CGImageSourceCreateWithData(data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary) else { throw URLError(.cannotDecodeContentData) }
        var variants: [Int: Data] = [:]
        for size in [128, 512] {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: size]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw URLError(.cannotDecodeContentData)
            }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw URLError(.cannotDecodeContentData)
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw URLError(.cannotDecodeContentData) }
            variants[size] = output as Data
        }
        return variants
    }

    /// Record visible usage without reloading the bytes. Disk writes remain batched.
    func recordAccess(for sourceURL: String, pixelSize: Int, playlistID: String?) {
        let key = Self.cacheKey(sourceURL: sourceURL, pixelSize: pixelSize)
        _ = try? refreshedCachedFileURL(key: key, playlistID: playlistID, accessedAt: .now)
        scheduleManifestSave()
    }

    /// All manifest mutations flow through this synchronous helper so a
    /// suspension can never interleave between reading and writing actor
    /// state — the lost-update that used to clobber concurrently added
    /// entries during refresh bursts.
    private func withManifest<T>(_ body: (inout ArtworkCacheManifest) -> T) throws -> T {
        var manifest = try loadManifest()
        let result = body(&manifest)
        self.manifest = manifest
        return result
    }

    /// Manifest writes are debounced: requests mutate in-memory state and a
    /// single pending task flushes to disk shortly after. A refresh burst
    /// used to re-encode and rewrite the whole manifest once per request,
    /// serializing this actor. Metadata is disposable, so losing the last
    /// second on a crash is fine — disk re-adoption recovers the files.
    private func scheduleManifestSave() {
        guard manifestSaveTask == nil else { return }
        manifestSaveTask = Task {
            try? await Task.sleep(for: manifestSaveDelay)
            guard !Task.isCancelled else { return }
            manifestSaveTask = nil
            try? persistManifest()
        }
    }

    func flushPendingManifestSave() async {
        manifestSaveTask?.cancel()
        manifestSaveTask = nil
        try? persistManifest()
    }

    private func persistManifest() throws {
        try saveManifest(loadManifest())
    }

    /// The cache key and file name are deterministic, so an image whose
    /// manifest entry was lost (historical manifest clobbering, partial
    /// purges) can be re-adopted from disk instead of re-downloaded.
    private func adoptedDiskEntry(
        key: String,
        sourceURL: String,
        pixelSize: Int,
        playlistID: String?,
        accessedAt: Date
    ) throws -> ArtworkCacheEntry? {
        let fileName = "\(key).\(fileExtension(for: sourceURL))"
        let url = rootDirectory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let byteSize = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        var associatedPlaylistIDs = Set<String>()
        if let playlistID {
            associatedPlaylistIDs.insert(playlistID)
        }

        let entry = ArtworkCacheEntry(
            cacheKey: key,
            sourceURL: sourceURL,
            pixelSize: pixelSize,
            associatedPlaylistIDs: associatedPlaylistIDs,
            lastAccessedAt: accessedAt,
            byteSize: byteSize,
            fileName: fileName
        )
        try withManifest { manifest in
            manifest.entries[key] = entry
            if let playlistID {
                manifest.playlistUsage[playlistID] = accessedAt
            }
        }
        scheduleManifestSave()
        return entry
    }

    private func refreshedCachedFileURL(
        key: String,
        playlistID: String?,
        accessedAt: Date
    ) throws -> URL? {
        try withManifest { manifest -> URL? in
            guard var entry = manifest.entries[key] else { return nil }
            let url = fileURL(for: entry)

            guard FileManager.default.fileExists(atPath: url.path) else {
                manifest.entries[key] = nil
                return nil
            }

            entry.lastAccessedAt = accessedAt
            if let playlistID {
                entry.associatedPlaylistIDs.insert(playlistID)
                manifest.playlistUsage[playlistID] = accessedAt
            }
            manifest.entries[key] = entry
            return url
        }
    }

    private func writeArtwork(
        _ data: Data,
        sourceURL: String,
        pixelSize: Int,
        cacheKey: String,
        playlistID: String?,
        accessedAt: Date
    ) throws -> ArtworkCacheEntry {
        let span = PerformanceSpan(.artworkCacheWrite)
        defer { span.finish(magnitude: Double(data.count)) }
        let fileName = "\(cacheKey).\(fileExtension(for: sourceURL))"
        let url = rootDirectory.appendingPathComponent(fileName)
        try data.write(to: url, options: [.atomic])

        var associatedPlaylistIDs = Set<String>()
        if let playlistID {
            associatedPlaylistIDs.insert(playlistID)
        }

        return ArtworkCacheEntry(
            cacheKey: cacheKey,
            sourceURL: sourceURL,
            pixelSize: pixelSize,
            associatedPlaylistIDs: associatedPlaylistIDs,
            lastAccessedAt: accessedAt,
            byteSize: data.count,
            fileName: fileName
        )
    }

    private func enforceCacheLimit(protectedPlaylistID: String?, requestedKey: String) throws {
        try withManifest { manifest in
            var totalBytes = manifest.entries.values.reduce(0) { $0 + $1.byteSize }
            var largeBytes = manifest.entries.values.filter { $0.pixelSize == 512 }.reduce(0) { $0 + $1.byteSize }
            guard totalBytes > maxCacheBytes || largeBytes > maxLargeCacheBytes else { return }

            let entriesToEvict = manifest.entries.values
                .filter { entry in
                    guard entry.cacheKey != requestedKey else { return false }
                    // Protect playlist thumbnails. Large artwork has its own bounded LRU.
                    guard entry.pixelSize == 128, let protectedPlaylistID else { return true }
                    return !entry.associatedPlaylistIDs.contains(protectedPlaylistID)
                }
                .sorted { left, right in
                    let leftUsage = left.pixelSize == 512 ? left.lastAccessedAt : mostRecentPlaylistUsage(for: left, manifest: manifest)
                    let rightUsage = right.pixelSize == 512 ? right.lastAccessedAt : mostRecentPlaylistUsage(for: right, manifest: manifest)
                    if leftUsage != rightUsage {
                        return leftUsage < rightUsage
                    }
                    return left.lastAccessedAt < right.lastAccessedAt
                }

            for entry in entriesToEvict where totalBytes > maxCacheBytes || (entry.pixelSize == 512 && largeBytes > maxLargeCacheBytes) {
                try? FileManager.default.removeItem(at: fileURL(for: entry))
                manifest.entries[entry.cacheKey] = nil
                totalBytes -= entry.byteSize
                if entry.pixelSize == 512 { largeBytes -= entry.byteSize }
            }
        }
    }

    private func mostRecentPlaylistUsage(
        for entry: ArtworkCacheEntry,
        manifest: ArtworkCacheManifest
    ) -> Date {
        // Entries with no playlist association (Search, History) compete on
        // their own access recency instead of always evicting first.
        entry.associatedPlaylistIDs
            .compactMap { manifest.playlistUsage[$0] }
            .max() ?? entry.lastAccessedAt
    }

    private func fileExtension(for sourceURL: String) -> String { "jpg" }

    private func fileURL(for entry: ArtworkCacheEntry) -> URL {
        rootDirectory.appendingPathComponent(entry.fileName)
    }

    private func ensureCacheDirectoryExists() throws {
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    }

    private func loadManifest() throws -> ArtworkCacheManifest {
        if let manifest {
            return manifest
        }

        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            let manifest = ArtworkCacheManifest()
            self.manifest = manifest
            return manifest
        }

        let data = try Data(contentsOf: manifestURL)
        var manifest = try JSONDecoder().decode(ArtworkCacheManifest.self, from: data)
        // Old entries only labelled their size; their bytes were unbounded sources.
        for entry in manifest.entries.values where entry.representationVersion != 2 {
            try? FileManager.default.removeItem(at: fileURL(for: entry))
            manifest.entries[entry.cacheKey] = nil
        }
        self.manifest = manifest
        return manifest
    }

    private func saveManifest(_ manifest: ArtworkCacheManifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL, options: [.atomic])
    }
}
