import Foundation
@preconcurrency import MusicKit

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

    static func resolve(_ id: MusicItemID) async throws -> Resolution {
        var libraryRequest = MusicLibraryRequest<Song>()
        libraryRequest.filter(matching: \.id, equalTo: id)
        libraryRequest.limit = 2
        let library = try await libraryRequest.response().items
        try Task.checkCancellation()
        if library.count == 1, !library.hasNextBatch, let song = library.first {
            return .library(song)
        }
        guard library.isEmpty else { throw ResolutionError.unresolved(id.rawValue) }

        // A playlist can also contain catalog songs not added to the library.
        // Ask the catalog explicitly; never infer this domain from ID syntax.
        let catalogRequest = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: id)
        let catalog = try await catalogRequest.response().items
        try Task.checkCancellation()
        guard catalog.count == 1, !catalog.hasNextBatch, let song = catalog.first,
              song.id == id else { throw ResolutionError.unresolved(id.rawValue) }
        return .catalog(song)
    }
}
