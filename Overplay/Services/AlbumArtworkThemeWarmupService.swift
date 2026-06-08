import Foundation

nonisolated struct AlbumArtworkThemeWarmupTrack: Equatable, Sendable {
    var artworkURLTemplate: String?
    var playlistID: String?
    var trackTitle: String?
    var artistName: String?
    var albumTitle: String?

    init(
        artworkURLTemplate: String?,
        playlistID: String?,
        trackTitle: String?,
        artistName: String?,
        albumTitle: String?
    ) {
        self.artworkURLTemplate = artworkURLTemplate
        self.playlistID = playlistID
        self.trackTitle = trackTitle
        self.artistName = artistName
        self.albumTitle = albumTitle
    }

    init(snapshot: TrackSnapshot) {
        self.init(
            artworkURLTemplate: snapshot.artworkURLTemplate,
            playlistID: snapshot.playlistID,
            trackTitle: snapshot.title,
            artistName: snapshot.artistName,
            albumTitle: snapshot.albumTitle
        )
    }

    init(track: TrackRecord, playlistID: String?) {
        self.init(
            artworkURLTemplate: track.artworkURLTemplate,
            playlistID: playlistID,
            trackTitle: track.title,
            artistName: track.artistName,
            albumTitle: track.albumTitle
        )
    }
}

actor AlbumArtworkThemeWarmupService {
    static let shared = AlbumArtworkThemeWarmupService()

    private let maxConcurrentTasks = 2
    private var queuedKeys = Set<String>()
    private var inFlightKeys = Set<String>()
    private var queue: [(key: String, track: AlbumArtworkThemeWarmupTrack, requiresIncreasedContrast: Bool)] = []

    func enqueue(
        _ tracks: [AlbumArtworkThemeWarmupTrack],
        requiresIncreasedContrast: Bool = false,
        currentArtworkURLTemplate: String? = nil
    ) async {
        let currentNormalizedURL = currentArtworkURLTemplate.map(ArtworkCacheService.normalizedSourceURL)

        for track in tracks {
            guard let normalizedURL = normalizedArtworkURL(track.artworkURLTemplate),
                  normalizedURL != currentNormalizedURL else {
                continue
            }

            let key = themeCacheKey(
                normalizedArtworkURL: normalizedURL,
                requiresIncreasedContrast: requiresIncreasedContrast
            )
            guard !queuedKeys.contains(key), !inFlightKeys.contains(key) else {
                continue
            }
            guard await !AlbumArtworkThemeProvider.shared.hasCachedTheme(
                forArtworkURLTemplate: normalizedURL,
                requiresIncreasedContrast: requiresIncreasedContrast
            ) else {
                continue
            }

            queuedKeys.insert(key)
            queue.append((key, track, requiresIncreasedContrast))
        }

        processQueue()
    }

    private func processQueue() {
        while inFlightKeys.count < maxConcurrentTasks, !queue.isEmpty {
            let item = queue.removeFirst()
            queuedKeys.remove(item.key)
            inFlightKeys.insert(item.key)

            Task(priority: .background) {
                _ = await AlbumArtworkThemeProvider.shared.prepareTheme(
                    forArtworkURLTemplate: item.track.artworkURLTemplate,
                    playlistID: item.track.playlistID,
                    trackTitle: item.track.trackTitle,
                    artistName: item.track.artistName,
                    albumTitle: item.track.albumTitle,
                    requiresIncreasedContrast: item.requiresIncreasedContrast
                )
                await self.finish(key: item.key)
            }
        }
    }

    private func finish(key: String) async {
        inFlightKeys.remove(key)
        processQueue()
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
            artworkPixelSize: AlbumArtworkThemeProvider.artworkPixelSize,
            requiresIncreasedContrast: requiresIncreasedContrast
        )
    }
}
