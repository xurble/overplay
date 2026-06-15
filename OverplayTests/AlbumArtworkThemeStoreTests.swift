import Foundation
import Testing
@testable import Overplay

@Suite("Album artwork theme store")
struct AlbumArtworkThemeStoreTests {
    @Test("theme store round-trips persisted JSON records without rewriting cache hits")
    func themeStoreRoundTripsPersistedJSONRecords() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AlbumArtworkThemeStore(directoryURL: directory, maxEntries: 100)
        let key = AlbumArtworkThemeStore.cacheKey(
            normalizedArtworkURL: "musicKit://artwork/example/{w}x{h}",
            artworkPixelSize: 128,
            requiresIncreasedContrast: false
        )
        let theme = AlbumArtworkTheme(
            backgroundRGB: AlbumArtworkRGBColor(0.18, 0.42, 0.70),
            trackTitleRGB: AlbumArtworkRGBColor(0.96, 0.78, 0.12),
            artistNameRGB: AlbumArtworkRGBColor(0.90, 0.70, 0.18),
            albumNameRGB: AlbumArtworkRGBColor(0.82, 0.62, 0.20),
            isFallback: false,
            source: .ocr
        )

        await store.setTheme(
            theme,
            for: key,
            normalizedArtworkURL: "musicKit://artwork/example/{w}x{h}",
            artworkDataHash: "hash-a",
            requiresIncreasedContrast: false,
            usedOCR: true,
            date: Date(timeIntervalSince1970: 10)
        )

        let reloadedStore = AlbumArtworkThemeStore(directoryURL: directory, maxEntries: 100)
        let cachedTheme = await reloadedStore.theme(for: key, accessedAt: Date(timeIntervalSince1970: 20))
        let record = await reloadedStore.record(for: key)

        #expect(cachedTheme == theme)
        #expect(record?.artworkDataHash == "hash-a")
        #expect(record?.usedOCR == true)
        #expect(record?.algorithmVersion == AlbumArtworkThemeBuilder.algorithmVersion)
        #expect(record?.lastAccessedAt == Date(timeIntervalSince1970: 10))
    }

    @Test("theme store key separates contrast mode and algorithm version")
    func themeStoreKeySeparatesContrastModeAndAlgorithmVersion() {
        let normalKey = AlbumArtworkThemeStore.cacheKey(
            normalizedArtworkURL: "musicKit://artwork/example/{w}x{h}",
            artworkPixelSize: 128,
            requiresIncreasedContrast: false
        )
        let contrastKey = AlbumArtworkThemeStore.cacheKey(
            normalizedArtworkURL: "musicKit://artwork/example/{w}x{h}",
            artworkPixelSize: 128,
            requiresIncreasedContrast: true
        )

        #expect(normalKey != contrastKey)
        #expect(normalKey.contains("theme-v\(AlbumArtworkThemeBuilder.algorithmVersion)"))
        #expect(contrastKey.contains("contrast:true"))
    }

    @Test("theme store overwrites records when artwork bytes change")
    func themeStoreOverwritesRecordsWhenArtworkBytesChange() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AlbumArtworkThemeStore(directoryURL: directory, maxEntries: 100)
        let key = AlbumArtworkThemeStore.cacheKey(
            normalizedArtworkURL: "musicKit://artwork/example/{w}x{h}",
            artworkPixelSize: 128,
            requiresIncreasedContrast: false
        )
        let originalTheme = AlbumArtworkTheme(
            backgroundRGB: AlbumArtworkRGBColor(0.10, 0.10, 0.12),
            trackTitleRGB: .white,
            artistNameRGB: .white,
            albumNameRGB: .white,
            isFallback: false,
            source: .paletteAccent
        )
        let updatedTheme = AlbumArtworkTheme(
            backgroundRGB: AlbumArtworkRGBColor(0.64, 0.20, 0.12),
            trackTitleRGB: AlbumArtworkRGBColor(0.96, 0.88, 0.42),
            artistNameRGB: AlbumArtworkRGBColor(0.90, 0.76, 0.38),
            albumNameRGB: AlbumArtworkRGBColor(0.84, 0.68, 0.34),
            isFallback: false,
            source: .ocr
        )

        await store.setTheme(
            originalTheme,
            for: key,
            normalizedArtworkURL: "musicKit://artwork/example/{w}x{h}",
            artworkDataHash: AlbumArtworkThemeStore.artworkDataHash(Data([1, 2, 3])),
            requiresIncreasedContrast: false,
            usedOCR: false
        )
        let updatedHash = AlbumArtworkThemeStore.artworkDataHash(Data([1, 2, 4]))
        await store.setTheme(
            updatedTheme,
            for: key,
            normalizedArtworkURL: "musicKit://artwork/example/{w}x{h}",
            artworkDataHash: updatedHash,
            requiresIncreasedContrast: false,
            usedOCR: true
        )

        let record = await store.record(for: key)

        #expect(record?.theme == updatedTheme)
        #expect(record?.artworkDataHash == updatedHash)
        #expect(record?.usedOCR == true)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OverplayThemeStoreTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
