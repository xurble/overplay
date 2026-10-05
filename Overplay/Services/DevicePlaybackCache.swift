import Foundation
import Synchronization
@preconcurrency import MusicKit

/// Rebuildable device-local playback material (`PLAY-017`), keyed by Overplay
/// track UUID. Kept in memory and in the caches directory so a cold launch can
/// play without re-resolving the whole playlist. Never part of SwiftData or
/// CloudKit identity; the system may purge it at any time.
nonisolated final class DevicePlaybackCache: Sendable {
    struct PreparationError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let shared = DevicePlaybackCache(
        directory: URL.cachesDirectory.appendingPathComponent("Overplay/PlaybackTracks", isDirectory: true)
    )
    private let resources = Mutex<[UUID: Data]>([:])
    private let directory: URL?

    init(directory: URL? = nil) {
        self.directory = directory
    }

    func data(for id: UUID) -> Data? {
        if let cached = resources.withLock({ $0[id] }) { return cached }
        guard let url = fileURL(for: id), let data = try? Data(contentsOf: url) else { return nil }
        resources.withLock { $0[id] = data }
        return data
    }

    func set(_ data: Data?, for id: UUID) {
        resources.withLock { $0[id] = data }
        guard let url = fileURL(for: id) else { return }
        if let data {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func removeAll() {
        resources.withLock { $0.removeAll() }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func fileURL(for id: UUID) -> URL? {
        directory?.appendingPathComponent("\(id.uuidString).json")
    }

    /// Resolves whatever can be resolved, committing each track as it
    /// arrives, then reports the failures. One unavailable song must not
    /// prevent the rest of a playlist from playing (`PLAY-017`).
    @MainActor static func prepare(
        _ tracks: [TrackRecord],
        libraryLookup: ([String]) async throws -> [String: Song] = { try await loadLibrarySongs($0) }
    ) async throws {
        let libraryIDs = Array(Set(tracks.filter { track in
            guard let data = shared.data(for: track.id) else { return true }
            return (try? JSONDecoder().decode(Track.self, from: data)) == nil
        }.compactMap(\.libraryID))).sorted()
        var librarySongs: [String: Song]?
        var libraryLookupError: Error?
        try await prepare(tracks) { reference in
            guard reference.domain == .librarySong else { return try await loadResource(reference) }
            // One batched lookup per preparation. A failure is remembered, so
            // the remaining library tracks fail fast instead of each retrying
            // the whole lookup against a struggling service (`LOAD-001`).
            if librarySongs == nil, libraryLookupError == nil {
                do {
                    librarySongs = try await libraryLookup(libraryIDs)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    libraryLookupError = error
                }
            }
            if let libraryLookupError { throw libraryLookupError }
            guard let song = librarySongs?[reference.value] else {
                throw PreparationError(message: "Apple Music returned no song for \(reference.value).")
            }
            return try JSONEncoder().encode(Track.song(song))
        }
    }

    @MainActor static func prepare(
        _ tracks: [TrackRecord],
        load: (MusicResourceReference) async throws -> Data
    ) async throws {
        var failures: [String] = []
        for track in tracks {
            if let cached = shared.data(for: track.id),
               (try? JSONDecoder().decode(Track.self, from: cached)) != nil { continue }
            try Task.checkCancellation()
            let reference: MusicResourceReference
            if let id = track.libraryID { reference = .library(id, scope: track.libraryScope) }
            else if let id = track.catalogID { reference = .catalog(id) }
            else {
                failures.append("Playback preparation failed for ‘\(track.title)’ by \(track.artistName): no saved library or catalog song ID (track \(track.id)).")
                continue
            }
            do {
                shared.set(try await load(reference), for: track.id)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                let detail: String
                if let failure = error as? PreparationError {
                    detail = failure.message
                } else {
                    let underlying = error as NSError
                    detail = "\(error.localizedDescription) [\(underlying.domain), code \(underlying.code)]"
                }
                failures.append("Playback preparation failed for ‘\(track.title)’ by \(track.artistName). \(lookupDescription(reference)): \(detail)")
            }
        }
        guard let first = failures.first else { return }
        throw PreparationError(message: failures.count == 1 ? first : "\(failures.count) tracks could not be prepared. \(first)")
    }

    /// Resolve a cold queue in bounded batches, rather than one network round
    /// trip per song. Correlate by resource ID, never response position.
    @MainActor static func loadLibrarySongs(
        _ ids: [String],
        nativeLookup: ([String]) async throws -> [Song] = nativeLibrarySongs,
        request: (URL) async throws -> Data = { url in
            try await MusicDataRequest(urlRequest: URLRequest(url: url)).response().data
        }
    ) async throws -> [String: Song] {
        let ids = Array(Set(ids)).sorted()
        var result: [String: Song] = [:]
        for start in stride(from: 0, to: ids.count, by: 100) {
            try Task.checkCancellation()
            let batch = Array(ids[start..<min(start + 100, ids.count)])
            let native = try await nativeLookup(batch)
            try Task.checkCancellation()
            let grouped = Dictionary(grouping: native, by: { $0.id.rawValue })
            for id in batch {
                if let matches = grouped[id], matches.count == 1 { result[id] = matches[0] }
            }
            let missing = batch.filter { result[$0] == nil }
            guard !missing.isEmpty else { continue }
            var url = URLComponents(string: "https://api.music.apple.com/v1/me/library/songs")!
            url.queryItems = [URLQueryItem(name: "ids", value: missing.joined(separator: ","))]
            let data = try await request(url.url!)
            try Task.checkCancellation()
            let response = try JSONDecoder().decode(LibrarySongResponse.self, from: data)
            let resources = Dictionary(grouping: response.data, by: { $0.song.id.rawValue })
            // Unresolved IDs are left out; each such track then fails on its own.
            for id in missing {
                let matches = resources[id] ?? []
                guard matches.count == 1, let resource = matches.first,
                      resource.type == "library-songs", resource.song.playParameters != nil else { continue }
                result[id] = resource.song
            }
        }
        return result
    }

    @MainActor private static func nativeLibrarySongs(_ ids: [String]) async throws -> [Song] {
        var request = MusicLibraryRequest<Song>()
        request.filter(matching: \.id, memberOf: ids.map { MusicItemID($0) })
        request.limit = ids.count
        return Array(try await request.response().items)
    }

    @MainActor private static func loadResource(_ reference: MusicResourceReference) async throws -> Data {
        let id = reference.value
        let song: Song
        switch reference.domain {
        case .librarySong:
            song = try await loadLibrarySong(id)
        case .catalogSong:
            let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(id))
            let items = try await request.response().items
            try validateLookup(reference, returnedIDs: items.map { $0.id.rawValue }, hasNextBatch: false)
            song = items[items.startIndex]
        }
        return try JSONEncoder().encode(Track.song(song))
    }

    /// A persisted web-library ID need not be queryable in the device's native
    /// library. Resolve it through its owning endpoint, retaining Apple's play
    /// parameters even for uploads that have no catalog equivalent.
    @MainActor static func loadLibrarySong(
        _ id: String,
        nativeLookup: (String) async throws -> Song? = nativeLibrarySong,
        request: (URL) async throws -> Data = { url in
            try await MusicDataRequest(urlRequest: URLRequest(url: url)).response().data
        }
    ) async throws -> Song {
        let native = try await nativeLookup(id)
        try Task.checkCancellation()
        if let native, native.id.rawValue == id { return native }

        var url = URLComponents(string: "https://api.music.apple.com/v1/me/library/songs")!
        url.queryItems = [URLQueryItem(name: "ids", value: id)]
        let data = try await request(url.url!)
        try Task.checkCancellation()
        let response = try JSONDecoder().decode(LibrarySongResponse.self, from: data)
        try validateLookup(.library(id), returnedIDs: response.data.map { $0.song.id.rawValue }, hasNextBatch: response.next != nil)
        let resource = response.data[0]
        guard resource.type == "library-songs" else {
            throw PreparationError(message: "Apple Music web library returned resource type \(resource.type); expected library-songs.")
        }
        guard resource.song.playParameters != nil else {
            throw PreparationError(message: "Apple Music web library returned song \(id) without playback parameters.")
        }
        return resource.song
    }

    @MainActor private static func nativeLibrarySong(_ id: String) async throws -> Song? {
        var request = MusicLibraryRequest<Song>()
        request.filter(matching: \.id, equalTo: MusicItemID(id))
        request.limit = 2
        let items = try await request.response().items
        guard items.count == 1, !items.hasNextBatch else { return nil }
        return items.first
    }

    private struct LibrarySongResponse: Decodable {
        var data: [Resource]
        var next: String?

        struct Resource: Decodable {
            let type: String
            let song: Song

            private enum CodingKeys: String, CodingKey { case type }

            init(from decoder: any Decoder) throws {
                type = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .type)
                song = try Song(from: decoder)
            }
        }
    }

    private static func lookupDescription(_ reference: MusicResourceReference) -> String {
        let domain = reference.domain == .librarySong ? "Library song" : "Catalog song"
        return "\(domain) lookup for \(reference.value)"
    }

    /// Keep the existing acceptance rules, but expose which condition failed.
    static func validateLookup(
        _ reference: MusicResourceReference, returnedIDs: [String], hasNextBatch: Bool
    ) throws {
        let reason: String
        if returnedIDs.isEmpty {
            reason = "Apple Music returned no songs."
        } else if returnedIDs.count != 1 {
            reason = "Apple Music returned multiple songs (\(returnedIDs.count))."
        } else if hasNextBatch {
            reason = "Apple Music returned an incomplete result with more pages available."
        } else if returnedIDs[0] != reference.value {
            reason = "Apple Music returned a different song identifier."
        } else {
            return
        }
        throw PreparationError(message: "\(reason) Returned IDs: [\(returnedIDs.joined(separator: ", "))]. More pages: \(hasNextBatch).")
    }
}
