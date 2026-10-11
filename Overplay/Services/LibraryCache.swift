import Foundation
@preconcurrency import MusicKit

/// This device's copy of the library lists (`LibraryBrowser`), so a list
/// opens at once. One file per category in the caches folder: disposable,
/// never synced (every device reads the same web library itself). Each entry
/// keeps its artwork's background colour, so a tint can show before the
/// artwork does. A list older than `staleAfter` refreshes in the background
/// when opened; empty lists fill a few seconds after launch.
@MainActor
@Observable
final class LibraryCache {
    static let shared = LibraryCache()

    static let staleAfter: TimeInterval = 30 * 60
    private static let directory = URL.cachesDirectory.appendingPathComponent("Overplay/LibraryBrowser", isDirectory: true)

    private(set) var items: [LibraryBrowser.Category: [LibraryBrowser.Item]] = [:]
    private(set) var songs: [LibraryBrowser.Entry]?
    /// Why the last fetch of a category failed, while it has nothing to show.
    private(set) var failures: [LibraryBrowser.Category: String] = [:]
    private(set) var refreshing: Set<LibraryBrowser.Category> = []

    @ObservationIgnored private var refreshedAt: [LibraryBrowser.Category: Date] = [:]
    @ObservationIgnored private var loadedFromDisk: Set<LibraryBrowser.Category> = []

    private init() {}

    func hasContent(_ category: LibraryBrowser.Category) -> Bool {
        category == .songs ? songs != nil : items[category] != nil
    }

    /// What opening a list does: show the saved copy, fetch when there is
    /// none, refresh in the background when it is old.
    func prepare(_ category: LibraryBrowser.Category) async {
        await loadFromDisk(category)
        if !hasContent(category) {
            await refresh(category)
        } else if Date.now.timeIntervalSince(refreshedAt[category] ?? .distantPast) > Self.staleAfter {
            Task { await refresh(category) }
        }
    }

    /// A few seconds after launch: fill any empty list, one at a time.
    func warmIfEmpty() async {
        for category in LibraryBrowser.Category.allCases {
            await loadFromDisk(category)
            if !hasContent(category) { await refresh(category) }
        }
    }

    func refresh(_ category: LibraryBrowser.Category) async {
        guard refreshing.insert(category).inserted else { return }
        defer { refreshing.remove(category) }
        do {
            let now = Date.now
            if category == .songs {
                var entries = try await LibraryBrowser.allLibrarySongs()
                for index in entries.indices {
                    entries[index].background = await Self.background(for: entries[index].song.artworkURLTemplate)
                }
                songs = entries
                save(SongsFile(refreshedAt: now, songs: entries.map { CachedSong($0) }), as: category)
            } else {
                var fetched = try await LibraryBrowser.items(category)
                for index in fetched.indices {
                    fetched[index].background = await Self.background(for: fetched[index].artworkURL)
                }
                items[category] = fetched
                save(ItemsFile(refreshedAt: now, items: fetched.map { CachedItem($0) }), as: category)
            }
            refreshedAt[category] = now
            failures[category] = nil
        } catch {
            if !hasContent(category) { failures[category] = UserFacingError.message(for: error) }
        }
    }

    /// The background colour Overplay worked out for this artwork, if any.
    private static func background(for artworkURL: String?) async -> AlbumArtworkRGBColor? {
        guard let artworkURL,
              let theme = await AlbumArtworkThemeProvider.shared.cachedTheme(forArtworkURLTemplate: artworkURL,
                                                                             requiresIncreasedContrast: false),
              !theme.isFallback else { return nil }
        return theme.backgroundRGB
    }

    // MARK: - Files

    private func loadFromDisk(_ category: LibraryBrowser.Category) async {
        guard loadedFromDisk.insert(category).inserted, !hasContent(category) else { return }
        let url = Self.fileURL(category)
        // A large library's songs are megabytes: read and decode off the main actor.
        if category == .songs {
            guard let file = await Self.decode(SongsFile.self, from: url) else { return }
            songs = file.songs.map { $0.entry }
            refreshedAt[category] = file.refreshedAt
        } else {
            guard let file = await Self.decode(ItemsFile.self, from: url) else { return }
            items[category] = file.items.compactMap { $0.item }
            refreshedAt[category] = file.refreshedAt
        }
    }

    @concurrent
    private nonisolated static func decode<File: Decodable & Sendable>(_ type: File.Type, from url: URL) async -> File? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(File.self, from: data)
    }

    private func save<File: Encodable & Sendable>(_ file: File, as category: LibraryBrowser.Category) {
        let url = Self.fileURL(category)
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(file) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func fileURL(_ category: LibraryBrowser.Category) -> URL {
        directory.appendingPathComponent("\(category.id.lowercased()).json")
    }

    nonisolated private struct ItemsFile: Codable, Sendable {
        var refreshedAt: Date
        var items: [CachedItem]
    }

    nonisolated private struct SongsFile: Codable, Sendable {
        var refreshedAt: Date
        var songs: [CachedSong]
    }

    nonisolated private struct CachedItem: Codable, Sendable {
        var kind: String
        var libraryID: String
        var title: String
        var subtitle: String?
        var artwork: Artwork?
        var background: AlbumArtworkRGBColor?

        @MainActor init(_ item: LibraryBrowser.Item) {
            kind = item.kind.rawValue
            libraryID = item.libraryID
            title = item.title
            subtitle = item.subtitle
            artwork = item.artwork
            background = item.background
        }

        @MainActor var item: LibraryBrowser.Item? {
            guard let kind = LibraryBrowser.Item.Kind(rawValue: kind) else { return nil }
            return LibraryBrowser.Item(kind: kind, libraryID: libraryID, title: title, subtitle: subtitle,
                                       artwork: artwork, background: background)
        }
    }

    nonisolated private struct CachedSong: Codable, Sendable {
        var song: PlaybackCollectionSong
        var track: Track
        var background: AlbumArtworkRGBColor?

        @MainActor init(_ entry: LibraryBrowser.Entry) {
            song = entry.song
            track = entry.track
            background = entry.background
        }

        @MainActor var entry: LibraryBrowser.Entry {
            LibraryBrowser.Entry(song: song, track: track, background: background)
        }
    }
}
