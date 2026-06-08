import CryptoKit
import Foundation

nonisolated struct AlbumArtworkThemeCacheRecord: Codable, Equatable, Sendable {
    var key: String
    var normalizedArtworkURL: String
    var artworkDataHash: String?
    var algorithmVersion: Int
    var requiresIncreasedContrast: Bool
    var theme: AlbumArtworkTheme
    var usedOCR: Bool
    var generatedAt: Date
    var lastAccessedAt: Date
}

nonisolated struct AlbumArtworkThemeCacheFile: Codable, Equatable, Sendable {
    var records: [String: AlbumArtworkThemeCacheRecord] = [:]
}

actor AlbumArtworkThemeStore {
    static let shared = AlbumArtworkThemeStore(directoryURL: nil, maxEntries: 10_000)

    private let directoryURL: URL
    private let fileURL: URL
    private let maxEntries: Int
    private var cacheFile: AlbumArtworkThemeCacheFile?

    init(directoryURL: URL?, maxEntries: Int = 10_000) {
        let directoryURL = directoryURL ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Overplay", isDirectory: true)
            .appendingPathComponent("ArtworkThemeCache", isDirectory: true)
        self.directoryURL = directoryURL
        self.fileURL = directoryURL.appendingPathComponent("themes.json")
        self.maxEntries = maxEntries
    }

    nonisolated static func cacheKey(
        normalizedArtworkURL: String,
        artworkPixelSize: Int,
        requiresIncreasedContrast: Bool
    ) -> String {
        let artworkKey = ArtworkCacheService.cacheKey(
            sourceURL: normalizedArtworkURL,
            pixelSize: artworkPixelSize
        )
        return "\(artworkKey)|contrast:\(requiresIncreasedContrast)|theme-v\(AlbumArtworkThemeBuilder.algorithmVersion)"
    }

    nonisolated static func artworkDataHash(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func theme(for key: String, accessedAt: Date = .now) async -> AlbumArtworkTheme? {
        do {
            var cacheFile = try loadCacheFile()
            guard var record = cacheFile.records[key],
                  record.algorithmVersion == AlbumArtworkThemeBuilder.algorithmVersion else {
                return nil
            }

            record.lastAccessedAt = accessedAt
            cacheFile.records[key] = record
            try save(cacheFile)
            self.cacheFile = cacheFile
            return record.theme
        } catch {
            AlbumArtworkThemeDiagnostics.log("theme store read failed: \(error.localizedDescription)")
            return nil
        }
    }

    func record(for key: String) async -> AlbumArtworkThemeCacheRecord? {
        do {
            let cacheFile = try loadCacheFile()
            guard let record = cacheFile.records[key],
                  record.algorithmVersion == AlbumArtworkThemeBuilder.algorithmVersion else {
                return nil
            }
            return record
        } catch {
            AlbumArtworkThemeDiagnostics.log("theme store record read failed: \(error.localizedDescription)")
            return nil
        }
    }

    func containsTheme(for key: String) async -> Bool {
        await record(for: key) != nil
    }

    func setTheme(
        _ theme: AlbumArtworkTheme,
        for key: String,
        normalizedArtworkURL: String,
        artworkDataHash: String?,
        requiresIncreasedContrast: Bool,
        usedOCR: Bool,
        date: Date = .now
    ) async {
        do {
            var cacheFile = try loadCacheFile()
            cacheFile.records[key] = AlbumArtworkThemeCacheRecord(
                key: key,
                normalizedArtworkURL: normalizedArtworkURL,
                artworkDataHash: artworkDataHash,
                algorithmVersion: AlbumArtworkThemeBuilder.algorithmVersion,
                requiresIncreasedContrast: requiresIncreasedContrast,
                theme: theme,
                usedOCR: usedOCR,
                generatedAt: date,
                lastAccessedAt: date
            )
            prune(&cacheFile)
            try save(cacheFile)
            self.cacheFile = cacheFile
        } catch {
            AlbumArtworkThemeDiagnostics.log("theme store write failed: \(error.localizedDescription)")
        }
    }

    private func loadCacheFile() throws -> AlbumArtworkThemeCacheFile {
        if let cacheFile {
            return cacheFile
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let empty = AlbumArtworkThemeCacheFile()
            cacheFile = empty
            return empty
        }

        let data = try Data(contentsOf: fileURL)
        let decoded = try JSONDecoder().decode(AlbumArtworkThemeCacheFile.self, from: data)
        cacheFile = decoded
        return decoded
    }

    private func save(_ cacheFile: AlbumArtworkThemeCacheFile) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(cacheFile)
        try data.write(to: fileURL, options: [.atomic])
    }

    private func prune(_ cacheFile: inout AlbumArtworkThemeCacheFile) {
        guard cacheFile.records.count > maxEntries else { return }
        let recordsToRemove = cacheFile.records.values
            .sorted { $0.lastAccessedAt < $1.lastAccessedAt }
            .prefix(cacheFile.records.count - maxEntries)
        for record in recordsToRemove {
            cacheFile.records[record.key] = nil
        }
    }
}
