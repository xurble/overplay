import Foundation
@preconcurrency import MusicKit
import OSLog

/// Resolves a song observed in a library playlist through an API that owns
/// its identifier. Playlist-entry IDs are not Apple Music web resource IDs.
@MainActor
enum MusicLibrarySongResolver {
    enum Resolution {
        case library(Song)
        case catalog(Song)

        var song: Song {
            switch self { case .library(let song), .catalog(let song): song }
        }

        var identity: (catalogID: String?, libraryID: String?) {
            switch self {
            case .library(let song): (nil, song.id.rawValue)
            case .catalog(let song): (song.id.rawValue, nil)
            }
        }
    }

    enum ResolutionError: LocalizedError {
        case unresolved(String)

        var errorDescription: String? {
            switch self {
            case .unresolved(let id): "Apple Music could not resolve playlist song \(id). The playlist was not imported."
            }
        }
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Overplay", category: "PlaylistSync")

    static func resolve(_ observed: Song) async throws -> Resolution {
        try await resolve(observed, library: librarySongs, webLibrary: webLibrarySongIDs, catalog: catalogSongs)
    }

    static func resolve(
        _ observed: Song,
        library: (MusicItemID) async throws -> [Song],
        webLibrary: (MusicItemID) async throws -> [String],
        catalog: (MusicItemID) async throws -> [Song]
    ) async throws -> Resolution {
        let id = observed.id
        let librarySongs = try await library(id)
        try Task.checkCancellation()
        if librarySongs.count == 1, let song = librarySongs.first {
            return .library(song)
        }
        guard librarySongs.isEmpty else { throw ResolutionError.unresolved(id.rawValue) }

        // A device's on-device library can lack songs its account library and
        // playlists still hold. The web library owns the same ID, and the
        // observed entry is the device's own representation of that song.
        let webIDs = try await webLibrary(id)
        try Task.checkCancellation()
        if webIDs == [id.rawValue] {
            logger.notice("Resolved playlist song \(id.rawValue, privacy: .public) through the web library; absent from the on-device library")
            return .library(observed)
        }
        guard webIDs.isEmpty else { throw ResolutionError.unresolved(id.rawValue) }

        // A playlist can also contain catalog songs not added to the library.
        // Ask the catalog explicitly; never infer this domain from ID syntax.
        let catalogSongs = try await catalog(id)
        try Task.checkCancellation()
        guard catalogSongs.count == 1, let song = catalogSongs.first,
              song.id == id else { throw ResolutionError.unresolved(id.rawValue) }
        return .catalog(song)
    }

    private static func librarySongs(_ id: MusicItemID) async throws -> [Song] {
        var request = MusicLibraryRequest<Song>()
        request.filter(matching: \.id, equalTo: id)
        request.limit = 2
        let items = try await request.response().items
        guard items.isEmpty || !items.hasNextBatch else { throw ResolutionError.unresolved(id.rawValue) }
        return Array(items)
    }

    /// IDs of the library-song resources the account's web library returns.
    private static func webLibrarySongIDs(_ id: MusicItemID) async throws -> [String] {
        var components = URLComponents(string: "https://api.music.apple.com/v1/me/library/songs")!
        components.queryItems = [URLQueryItem(name: "ids", value: id.rawValue)]
        let data: Data
        do {
            data = try await MusicDataRequest(urlRequest: URLRequest(url: components.url!)).response().data
        } catch let error as MusicDataRequest.Error where error.status == 404 {
            return []
        }
        return try webLibrarySongIDs(from: data)
    }

    static func webLibrarySongIDs(from data: Data) throws -> [String] {
        struct Envelope: Decodable {
            struct Resource: Decodable { var id: String; var type: String }
            var data: [Resource]
        }
        return try JSONDecoder().decode(Envelope.self, from: data).data
            .filter { $0.type == "library-songs" }
            .map(\.id)
    }

    private static func catalogSongs(_ id: MusicItemID) async throws -> [Song] {
        let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: id)
        let items = try await request.response().items
        guard !items.hasNextBatch else { throw ResolutionError.unresolved(id.rawValue) }
        return Array(items)
    }
}
