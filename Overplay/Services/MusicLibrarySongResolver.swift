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
            case .unresolved(let id): "Apple Music's library, web library and catalog could not identify playlist song \(id). The playlist was not imported."
            }
        }
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Overplay", category: "PlaylistSync")

    static func resolve(_ observed: Song) async throws -> Resolution {
        try await resolve(observed, library: AppleMusicSongLookup.nativeLibrarySongMatches, webLibrary: { id in
            try await MusicKitActivityLog.shared.measure(.catalogResourceFetch, magnitude: 1, detail: "resolver web library song") {
                try await AppleMusicSongLookup.webLibrarySongIDs([id.rawValue])
            }
        }, catalog: AppleMusicSongLookup.catalogSongMatches)
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

    /// The same order as `resolve`, batched (`LOAD-001`). The on-device
    /// library and the catalog take 100 IDs a request; the web library 25.
    /// A lagging device's library can miss a third of a playlist, and one
    /// request per song took ~20 seconds (#65).
    ///
    /// A device's native lookup can answer an observed ID with a different
    /// song ID (Mac persistent IDs answer with web library IDs: probe,
    /// 2026-09-27). A batched answer like that cannot be attributed to any one
    /// song, so those songs fall back to per-song lookups, which alone can
    /// establish that mapping.
    static func resolveAll(
        _ observed: [Song],
        library: ([MusicItemID]) async throws -> [Song] = { ids in
            try await AppleMusicSongLookup.nativeLibrarySongs(
                ids.map(\.rawValue), detail: "resolver library songs", limit: ids.count, allPages: true
            )
        },
        librarySong: (MusicItemID) async throws -> [Song] = AppleMusicSongLookup.nativeLibrarySongMatches,
        webLibrary: ([MusicItemID]) async throws -> [String] = AppleMusicSongLookup.fetchWebLibrarySongIDs,
        catalog: ([MusicItemID]) async throws -> [Song] = { ids in
            try await AppleMusicSongLookup.catalogSongs(ids.map(\.rawValue), detail: "resolver catalog songs", allPages: true)
        }
    ) async throws -> BatchResolution {
        var result = BatchResolution()
        var seen = Set<MusicItemID>()
        let distinct = observed.filter { seen.insert($0.id).inserted }

        let matches = try await nativeMatches(distinct, library: library, librarySong: librarySong)
        var notInLibrary: [Song] = []
        for song in distinct {
            let found = matches[song.id] ?? []
            if found.count == 1, let match = found.first {
                result.resolutions[song.id] = .library(match)
            } else if found.isEmpty {
                notInLibrary.append(song)
            } else {
                // Unique or nothing: two matches cannot both be this song.
                result.unresolved.append(song.id)
            }
        }

        let web = try await AppleMusicSongLookup.correlated(
            notInLibrary.map(\.id.rawValue), batchSize: AppleMusicSongLookup.webLibraryIdentityBatchSize, id: { (id: String) in id }
        ) { batch in
            try await webLibrary(batch.map { MusicItemID($0) })
        }
        // An answer for an ID nobody asked about cannot be attributed.
        if let unexpected = web.unrequested.first { throw ResolutionError.unresolved(unexpected) }
        var notInWebLibrary: [Song] = []
        for song in notInLibrary {
            if web.matches[song.id.rawValue] != nil {
                result.resolutions[song.id] = .library(song)
            } else {
                notInWebLibrary.append(song)
            }
        }
        let viaWeb = notInLibrary.count - notInWebLibrary.count
        if viaWeb > 0 {
            logger.notice("Resolved \(viaWeb) playlist songs through the web library; absent from the on-device library")
        }

        let catalogAnswer = try await AppleMusicSongLookup.correlated(notInWebLibrary.map(\.id.rawValue), id: \Song.id.rawValue) { batch in
            try await catalog(batch.map { MusicItemID($0) })
        }
        for song in notInWebLibrary {
            if let found = catalogAnswer.matches[song.id.rawValue], found.count == 1, let match = found.first {
                result.resolutions[song.id] = .catalog(match)
            } else {
                result.unresolved.append(song.id)
            }
        }
        return result
    }

    /// What the on-device library holds for each song, batched while its
    /// answers can be attributed. A song the lookup did not answer has no key.
    private static func nativeMatches(
        _ songs: [Song],
        library: ([MusicItemID]) async throws -> [Song],
        librarySong: (MusicItemID) async throws -> [Song]
    ) async throws -> [MusicItemID: [Song]] {
        var matches: [MusicItemID: [Song]] = [:]
        var batching = true
        for start in stride(from: 0, to: songs.count, by: AppleMusicSongLookup.batchSize) {
            try Task.checkCancellation()
            let chunk = Array(songs[start..<min(start + AppleMusicSongLookup.batchSize, songs.count)])
            if batching {
                let answer = try await AppleMusicSongLookup.correlated(chunk.map(\.id.rawValue), id: \Song.id.rawValue) { batch in
                    try await library(batch.map { MusicItemID($0) })
                }
                for song in chunk { matches[song.id] = answer.matches[song.id.rawValue] }
                if !answer.unrequested.isEmpty {
                    batching = false
                    logger.notice("On-device library answered \(answer.unrequested.count) songs under other IDs; resolving the rest one at a time")
                }
            }
            if !batching {
                for song in chunk where matches[song.id] == nil {
                    matches[song.id] = try await librarySong(song.id)
                    try Task.checkCancellation()
                }
            }
        }
        return matches
    }
}
