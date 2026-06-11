import Foundation

protocol AlbumArtworkThemeProviding: Sendable {
    func cachedTheme(
        forArtworkURLTemplate artworkURLTemplate: String?,
        requiresIncreasedContrast: Bool
    ) async -> AlbumArtworkTheme?

    func prepareTheme(
        forArtworkURLTemplate artworkURLTemplate: String?,
        playlistID: String?,
        trackTitle: String?,
        artistName: String?,
        albumTitle: String?,
        requiresIncreasedContrast: Bool
    ) async -> AlbumArtworkTheme
}

actor AlbumArtworkThemeProvider: AlbumArtworkThemeProviding {
    static let shared = AlbumArtworkThemeProvider(store: AlbumArtworkThemeStore.shared)

    nonisolated static let artworkPixelSize = 128

    private let store: AlbumArtworkThemeStore
    private var inFlightTasks: [String: Task<AlbumArtworkTheme, Never>] = [:]

    init(store: AlbumArtworkThemeStore) {
        self.store = store
    }

    func cachedTheme(
        forArtworkURLTemplate artworkURLTemplate: String?,
        requiresIncreasedContrast: Bool
    ) async -> AlbumArtworkTheme? {
        guard let normalizedURL = normalizedArtworkURL(artworkURLTemplate) else {
            return nil
        }

        let key = themeCacheKey(
            normalizedArtworkURL: normalizedURL,
            requiresIncreasedContrast: requiresIncreasedContrast
        )
        let theme = await store.theme(for: key)
        AlbumArtworkThemeDiagnostics.log(
            "provider \(theme == nil ? "disk cache miss" : "disk cache hit"): key=\(key)"
        )
        return theme
    }

    func prepareTheme(
        forArtworkURLTemplate artworkURLTemplate: String?,
        playlistID: String?,
        trackTitle: String?,
        artistName: String?,
        albumTitle: String?,
        requiresIncreasedContrast: Bool
    ) async -> AlbumArtworkTheme {
        guard let normalizedURL = normalizedArtworkURL(artworkURLTemplate) else {
            AlbumArtworkThemeDiagnostics.log("provider fallback: artwork URL template is nil or empty")
            return .fallback
        }

        let key = themeCacheKey(
            normalizedArtworkURL: normalizedURL,
            requiresIncreasedContrast: requiresIncreasedContrast
        )
        let cachedRecord = await store.record(for: key)

        if let task = inFlightTasks[key] {
            return await task.value
        }

        let task = Task(priority: .utility) {
            await self.generateTheme(
                normalizedArtworkURL: normalizedURL,
                cacheKey: key,
                playlistID: playlistID,
                trackTitle: trackTitle,
                artistName: artistName,
                albumTitle: albumTitle,
                requiresIncreasedContrast: requiresIncreasedContrast,
                cachedRecord: cachedRecord
            )
        }
        inFlightTasks[key] = task
        let theme = await task.value
        inFlightTasks[key] = nil
        return theme
    }

    func hasCachedTheme(
        forArtworkURLTemplate artworkURLTemplate: String?,
        requiresIncreasedContrast: Bool
    ) async -> Bool {
        guard let normalizedURL = normalizedArtworkURL(artworkURLTemplate) else {
            return false
        }
        return await store.containsTheme(
            for: themeCacheKey(
                normalizedArtworkURL: normalizedURL,
                requiresIncreasedContrast: requiresIncreasedContrast
            )
        )
    }

    func debugReport(
        forArtworkURLTemplate artworkURLTemplate: String?,
        playlistID: String?,
        trackTitle: String?,
        artistName: String?,
        albumTitle: String?,
        requiresIncreasedContrast: Bool,
        persistGeneratedTheme: Bool = false
    ) async -> AlbumArtworkThemeDebugReport {
        guard let normalizedURL = normalizedArtworkURL(artworkURLTemplate) else {
            return .failure(
                normalizedArtworkURL: nil,
                artworkByteCount: 0,
                artworkDataHash: nil,
                errorMessage: "Current track has no artwork URL."
            )
        }

        guard let fileURL = await ArtworkCacheService.shared.artworkFileURL(
            for: normalizedURL,
            pixelSize: Self.artworkPixelSize,
            playlistID: playlistID,
            priority: .userInitiated
        ) else {
            return .failure(
                normalizedArtworkURL: normalizedURL,
                artworkByteCount: 0,
                artworkDataHash: nil,
                errorMessage: "Artwork cache could not provide image data for this URL."
            )
        }

        let options = AlbumArtworkThemeBuilder.Options(
            requiresIncreasedContrast: requiresIncreasedContrast
        )
        let report = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: fileURL) else {
                return AlbumArtworkThemeDebugReport.failure(
                    normalizedArtworkURL: normalizedURL,
                    artworkByteCount: 0,
                    artworkDataHash: nil,
                    errorMessage: "Could not read cached artwork file at \(fileURL.lastPathComponent)."
                )
            }

            let dataHash = AlbumArtworkThemeStore.artworkDataHash(data)
            return AlbumArtworkThemeBuilder.debugReport(
                from: AlbumArtworkThemeInput(
                    artworkData: data,
                    artworkURLTemplate: normalizedURL,
                    trackTitle: trackTitle,
                    artistName: artistName,
                    albumTitle: albumTitle,
                    options: options
                ),
                artworkDataHash: dataHash
            )
        }.value

        if persistGeneratedTheme, report.errorMessage == nil {
            let key = themeCacheKey(
                normalizedArtworkURL: normalizedURL,
                requiresIncreasedContrast: requiresIncreasedContrast
            )
            await store.setTheme(
                report.theme,
                for: key,
                normalizedArtworkURL: normalizedURL,
                artworkDataHash: report.artworkDataHash,
                requiresIncreasedContrast: requiresIncreasedContrast,
                usedOCR: report.theme.source == .ocr
            )
            AlbumArtworkThemeDiagnostics.log("provider debug persisted theme: key=\(key) fallback=\(report.theme.isFallback) source=\(report.theme.source.rawValue)")
        }

        return report
    }

    private func generateTheme(
        normalizedArtworkURL: String,
        cacheKey: String,
        playlistID: String?,
        trackTitle: String?,
        artistName: String?,
        albumTitle: String?,
        requiresIncreasedContrast: Bool,
        cachedRecord: AlbumArtworkThemeCacheRecord?
    ) async -> AlbumArtworkTheme {
        AlbumArtworkThemeDiagnostics.log(
            "provider prepare miss: key=\(cacheKey) playlistID=\(playlistID ?? "nil") contrast=\(requiresIncreasedContrast) url=\(normalizedArtworkURL)"
        )

        guard let fileURL = await ArtworkCacheService.shared.artworkFileURL(
            for: normalizedArtworkURL,
            pixelSize: Self.artworkPixelSize,
            playlistID: playlistID,
            priority: .background
        ) else {
            AlbumArtworkThemeDiagnostics.log("provider fallback: ArtworkCacheService returned nil for key=\(cacheKey)")
            return cachedRecord?.theme ?? .fallback
        }

        let options = AlbumArtworkThemeBuilder.Options(
            requiresIncreasedContrast: requiresIncreasedContrast
        )
        let result = await Task.detached(priority: .background) {
            guard let data = try? Data(contentsOf: fileURL) else {
                AlbumArtworkThemeDiagnostics.log("provider fallback: could not read artwork data at \(fileURL.path)")
                return (cachedRecord?.theme ?? AlbumArtworkTheme.fallback, nil as String?)
            }

            AlbumArtworkThemeDiagnostics.log("provider artwork data: bytes=\(data.count)")
            let dataHash = AlbumArtworkThemeStore.artworkDataHash(data)
            if cachedRecord?.artworkDataHash == dataHash, let cachedTheme = cachedRecord?.theme {
                AlbumArtworkThemeDiagnostics.log("provider artwork data unchanged: key=\(cacheKey)")
                return (cachedTheme, dataHash)
            }

            let theme = AlbumArtworkThemeBuilder.theme(from: AlbumArtworkThemeInput(
                artworkData: data,
                artworkURLTemplate: normalizedArtworkURL,
                trackTitle: trackTitle,
                artistName: artistName,
                albumTitle: albumTitle,
                options: options
            ))
            return (theme, dataHash)
        }.value

        let theme = result.0
        if result.1 != nil, theme != cachedRecord?.theme || result.1 != cachedRecord?.artworkDataHash {
            await store.setTheme(
                theme,
                for: cacheKey,
                normalizedArtworkURL: normalizedArtworkURL,
                artworkDataHash: result.1,
                requiresIncreasedContrast: requiresIncreasedContrast,
                usedOCR: theme.source == .ocr
            )
        }
        AlbumArtworkThemeDiagnostics.log("provider cached prepared theme: key=\(cacheKey) fallback=\(theme.isFallback) source=\(theme.source.rawValue)")
        return theme
    }

    private nonisolated func normalizedArtworkURL(_ artworkURLTemplate: String?) -> String? {
        guard let artworkURLTemplate else { return nil }
        let normalized = ArtworkCacheService.normalizedSourceURL(artworkURLTemplate)
        return normalized.isEmpty ? nil : normalized
    }

    private nonisolated func themeCacheKey(
        normalizedArtworkURL: String,
        requiresIncreasedContrast: Bool
    ) -> String {
        AlbumArtworkThemeStore.cacheKey(
            normalizedArtworkURL: normalizedArtworkURL,
            artworkPixelSize: Self.artworkPixelSize,
            requiresIncreasedContrast: requiresIncreasedContrast
        )
    }
}
