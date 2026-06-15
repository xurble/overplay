import CryptoKit
import Foundation

nonisolated struct ArtworkCacheEntry: Codable, Equatable, Sendable {
    var cacheKey: String
    var sourceURL: String
    var pixelSize: Int
    var associatedPlaylistIDs: Set<String>
    var lastAccessedAt: Date
    var byteSize: Int
    var fileName: String
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
    private let downloader: @Sendable (URL) async throws -> Data
    private var manifest: ArtworkCacheManifest?
    private var inFlightDownloads: [String: Task<Data, Error>] = [:]

    init(
        rootDirectory: URL? = nil,
        maxCacheBytes: Int = ArtworkCacheService.defaultMaxCacheBytes,
        downloader: @escaping @Sendable (URL) async throws -> Data = ArtworkCacheService.download
    ) {
        let rootDirectory = rootDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Overplay", isDirectory: true)
            .appendingPathComponent("ArtworkCache", isDirectory: true)
        self.rootDirectory = rootDirectory
        self.manifestURL = rootDirectory.appendingPathComponent("manifest.json")
        self.maxCacheBytes = maxCacheBytes
        self.downloader = downloader
    }

    static func cacheKey(sourceURL: String, pixelSize: Int) -> String {
        let normalizedValue = "\(normalizedSourceURL(sourceURL))|\(pixelSize)"
        let digest = SHA256.hash(data: Data(normalizedValue.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

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
        guard let sourceURL else { return nil }
        let normalizedSourceURL = Self.normalizedSourceURL(sourceURL)
        guard !normalizedSourceURL.isEmpty, let remoteURL = URL(string: normalizedSourceURL) else {
            return nil
        }

        do {
            try ensureCacheDirectoryExists()
            var manifest = try loadManifest()
            let key = Self.cacheKey(sourceURL: normalizedSourceURL, pixelSize: pixelSize)

            if let cachedURL = try cachedFileURL(
                key: key,
                playlistID: playlistID,
                accessedAt: accessedAt,
                manifest: &manifest
            ) {
                try saveManifest(manifest)
                self.manifest = manifest
                return cachedURL
            }

            let data = try await downloadedData(for: remoteURL, cacheKey: key, priority: priority)
            if let cachedURL = try cachedFileURL(
                key: key,
                playlistID: playlistID,
                accessedAt: accessedAt,
                manifest: &manifest
            ) {
                try saveManifest(manifest)
                self.manifest = manifest
                return cachedURL
            }

            let entry = try writeArtwork(
                data,
                sourceURL: normalizedSourceURL,
                pixelSize: pixelSize,
                cacheKey: key,
                playlistID: playlistID,
                accessedAt: accessedAt
            )
            manifest.entries[key] = entry
            if let playlistID {
                manifest.playlistUsage[playlistID] = accessedAt
            }
            try enforceCacheLimit(manifest: &manifest, protectedPlaylistID: protectedPlaylistID)
            try saveManifest(manifest)
            self.manifest = manifest
            return fileURL(for: entry)
        } catch {
            return nil
        }
    }

    func cachedArtworkFileURL(
        for sourceURL: String?,
        pixelSize: Int
    ) async -> URL? {
        guard let sourceURL else { return nil }
        let normalizedSourceURL = Self.normalizedSourceURL(sourceURL)
        guard !normalizedSourceURL.isEmpty, URL(string: normalizedSourceURL) != nil else {
            return nil
        }

        do {
            try ensureCacheDirectoryExists()
            var manifest = try loadManifest()
            let key = Self.cacheKey(sourceURL: normalizedSourceURL, pixelSize: pixelSize)
            guard let entry = manifest.entries[key] else { return nil }
            let url = fileURL(for: entry)

            guard FileManager.default.fileExists(atPath: url.path) else {
                manifest.entries[key] = nil
                try saveManifest(manifest)
                self.manifest = manifest
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
            var manifest = try loadManifest()
            manifest.playlistUsage[playlistID] = date
            try saveManifest(manifest)
            self.manifest = manifest
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
        let (data, response) = try await URLSession.shared.data(from: url)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private func downloadedData(for url: URL, cacheKey: String, priority: TaskPriority) async throws -> Data {
        if let inFlightDownload = inFlightDownloads[cacheKey] {
            return try await inFlightDownload.value
        }

        let downloadTask = Task(priority: priority) {
            try await downloader(url)
        }
        inFlightDownloads[cacheKey] = downloadTask
        defer { inFlightDownloads[cacheKey] = nil }
        return try await downloadTask.value
    }

    private func cachedFileURL(
        key: String,
        playlistID: String?,
        accessedAt: Date,
        manifest: inout ArtworkCacheManifest
    ) throws -> URL? {
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

    private func writeArtwork(
        _ data: Data,
        sourceURL: String,
        pixelSize: Int,
        cacheKey: String,
        playlistID: String?,
        accessedAt: Date
    ) throws -> ArtworkCacheEntry {
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

    private func enforceCacheLimit(
        manifest: inout ArtworkCacheManifest,
        protectedPlaylistID: String?
    ) throws {
        var totalBytes = manifest.entries.values.reduce(0) { $0 + $1.byteSize }
        guard totalBytes > maxCacheBytes else { return }

        let entriesToEvict = manifest.entries.values
            .filter { entry in
                guard let protectedPlaylistID else { return true }
                return !entry.associatedPlaylistIDs.contains(protectedPlaylistID)
            }
            .sorted { left, right in
                let leftUsage = mostRecentPlaylistUsage(for: left, manifest: manifest)
                let rightUsage = mostRecentPlaylistUsage(for: right, manifest: manifest)
                if leftUsage != rightUsage {
                    return leftUsage < rightUsage
                }
                return left.lastAccessedAt < right.lastAccessedAt
            }

        for entry in entriesToEvict where totalBytes > maxCacheBytes {
            try? FileManager.default.removeItem(at: fileURL(for: entry))
            manifest.entries[entry.cacheKey] = nil
            totalBytes -= entry.byteSize
        }
    }

    private func mostRecentPlaylistUsage(
        for entry: ArtworkCacheEntry,
        manifest: ArtworkCacheManifest
    ) -> Date {
        entry.associatedPlaylistIDs
            .compactMap { manifest.playlistUsage[$0] }
            .max() ?? .distantPast
    }

    private func fileExtension(for sourceURL: String) -> String {
        guard let url = URL(string: sourceURL) else { return "img" }
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? "img" : ext
    }

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
        let manifest = try JSONDecoder().decode(ArtworkCacheManifest.self, from: data)
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
