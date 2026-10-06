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

    /// Songs resolved for one playlist fetch, and the ones nothing could
    /// identify (`PLAYLIST-010`). A failed request still throws.
    struct BatchResolution {
        var resolutions: [MusicItemID: Resolution] = [:]
        var unresolved: [MusicItemID] = []
    }

    static let webBatchSize = 25

    /// The same order as `resolve`, with web-library lookups batched
    /// (`LOAD-001`): a lagging device's library can miss a third of a
    /// playlist, and one request per song took ~20 seconds (#65).
    static func resolveAll(
        _ observed: [Song],
        library: (MusicItemID) async throws -> [Song] = librarySongs,
        webLibrary: ([MusicItemID]) async throws -> [String] = webLibrarySongIDs,
        catalog: (MusicItemID) async throws -> [Song] = catalogSongs
    ) async throws -> BatchResolution {
        var result = BatchResolution()
        var seen = Set<MusicItemID>()
        var notInLibrary: [Song] = []
        for song in observed where seen.insert(song.id).inserted {
            let librarySongs = try await library(song.id)
            try Task.checkCancellation()
            if librarySongs.count == 1, let match = librarySongs.first {
                result.resolutions[song.id] = .library(match)
            } else if librarySongs.isEmpty {
                notInLibrary.append(song)
            } else {
                result.unresolved.append(song.id)
            }
        }

        var notInWebLibrary: [Song] = []
        for start in stride(from: 0, to: notInLibrary.count, by: webBatchSize) {
            let batch = Array(notInLibrary[start..<min(start + webBatchSize, notInLibrary.count)])
            let requested = Set(batch.map(\.id.rawValue))
            let returned = Set(try await webLibrary(batch.map(\.id)))
            try Task.checkCancellation()
            // An answer for an ID nobody asked about cannot be attributed.
            if let unexpected = returned.subtracting(requested).first { throw ResolutionError.unresolved(unexpected) }
            for song in batch {
                if returned.contains(song.id.rawValue) {
                    result.resolutions[song.id] = .library(song)
                } else {
                    notInWebLibrary.append(song)
                }
            }
        }
        let viaWeb = notInLibrary.count - notInWebLibrary.count
        if viaWeb > 0 {
            logger.notice("Resolved \(viaWeb) playlist songs through the web library; absent from the on-device library")
        }

        for song in notInWebLibrary {
            let catalogSongs = try await catalog(song.id)
            try Task.checkCancellation()
            if catalogSongs.count == 1, let match = catalogSongs.first, match.id == song.id {
                result.resolutions[song.id] = .catalog(match)
            } else {
                result.unresolved.append(song.id)
            }
        }
        return result
    }

    static func librarySongs(_ id: MusicItemID) async throws -> [Song] {
        var request = MusicLibraryRequest<Song>()
        request.filter(matching: \.id, equalTo: id)
        request.limit = 2
        let items = try await request.response().items
        guard items.isEmpty || !items.hasNextBatch else { throw ResolutionError.unresolved(id.rawValue) }
        return Array(items)
    }

    private static func webLibrarySongIDs(_ id: MusicItemID) async throws -> [String] {
        try await webLibrarySongIDs([id])
    }

    /// IDs of the library-song resources the account's web library returns.
    static func webLibrarySongIDs(_ ids: [MusicItemID]) async throws -> [String] {
        var components = URLComponents(string: "https://api.music.apple.com/v1/me/library/songs")!
        components.queryItems = [URLQueryItem(name: "ids", value: ids.map(\.rawValue).joined(separator: ","))]
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

    static func catalogSongs(_ id: MusicItemID) async throws -> [Song] {
        let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: id)
        let items = try await request.response().items
        guard !items.hasNextBatch else { throw ResolutionError.unresolved(id.rawValue) }
        return Array(items)
    }
}
