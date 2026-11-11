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
    /// Keyed by track UUID, or by `catalog-<song ID>` for album and artist
    /// songs Overplay does not track (`PLAY-018`).
    private let resources = Mutex<[String: Data]>([:])
    /// The account and storefront fingerprint the tracks were filled under.
    private let scope = Mutex<String?>(nil)
    private let directory: URL?
    /// One start's decoded tracks, so a start decodes each cached track once
    /// (PB-9). Bound to the start's task by `decodingOnce`, never shared
    /// process-wide: another caller's decodes are never kept, and a start
    /// whose lookup never returns holds only its own. An entry is reused only
    /// while the cache still holds the data it was decoded from.
    nonisolated final class StartDecodes: Sendable {
        fileprivate let tracks = Mutex<[String: (data: Data, track: Track?)]>([:])
    }
    @TaskLocal static var startDecodes: StartDecodes?
    /// Tests count decodes through this; told each decoded key.
    let decodeObserver = Mutex<(@Sendable (String) -> Void)?>(nil)

    init(directory: URL? = nil) {
        self.directory = directory
    }

    func data(for id: UUID) -> Data? { data(forKey: id.uuidString) }

    func set(_ data: Data?, for id: UUID) { set(data, forKey: id.uuidString) }

    /// A catalog song's native track, so an album or artist plays and
    /// recovers without the network once played on this device.
    func data(forCatalogSongID id: String) -> Data? { data(forKey: "catalog-\(id)") }

    func set(_ data: Data?, forCatalogSongID id: String) { set(data, forKey: "catalog-\(id)") }

    private func data(forKey key: String) -> Data? {
        if let cached = resources.withLock({ $0[key] }) { return cached }
        guard let url = fileURL(for: key), let data = try? Data(contentsOf: url) else { return nil }
        resources.withLock { $0[key] = data }
        return data
    }

    private func set(_ data: Data?, forKey key: String) {
        resources.withLock { $0[key] = data }
        guard let url = fileURL(for: key) else { return }
        if let data {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// The cached track, decoded. Within `decodingOnce` each key is decoded
    /// at most once until its data is set again.
    func track(for id: UUID) -> Track? {
        let key = id.uuidString
        guard let data = data(forKey: key) else { return nil }
        let start = Self.startDecodes
        if let entry = start?.tracks.withLock({ $0[key] }), entry.data == data { return entry.track }
        decodeObserver.withLock { $0 }?(key)
        let track = try? JSONDecoder().decode(Track.self, from: data)
        start?.tracks.withLock { $0[key] = (data, track) }
        return track
    }

    /// Runs one start's work so each cached track is decoded at most once
    /// (PB-9). A nested call shares the enclosing start's decodes; they are
    /// dropped when the outermost call returns.
    @MainActor static func decodingOnce<T>(_ operation: () async throws -> T) async rethrows -> T {
        if startDecodes != nil { return try await operation() }
        return try await $startDecodes.withValue(StartDecodes(), operation: operation)
    }

    func removeAll() {
        resources.withLock { $0.removeAll() }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// Empties the cache only when the Apple Music account or storefront it
    /// was filled under changes. The fingerprint is kept beside the tracks, so
    /// a relaunch, or a failed or offline account check, keeps them: a cold
    /// launch in the car must not need the network (`PLAY-017`).
    func adopt(scope fingerprint: String) {
        let url = directory?.appendingPathComponent("scope")
        let previous = scope.withLock { $0 } ?? url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        guard previous != fingerprint else { return }
        if previous != nil { removeAll() }
        scope.withLock { $0 = fingerprint }
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fingerprint.write(to: url, atomically: true, encoding: .utf8)
    }

    private func fileURL(for key: String) -> URL? {
        let safe = key.replacingOccurrences(of: "/", with: "_")
        return directory?.appendingPathComponent("\(safe).json")
    }

    /// A cached track is current only when it decodes and is the song its
    /// record now names. Removing and re-adding a song, or a sync that
    /// re-matches the record, changes that ID while the disk cache keeps the
    /// old play parameters across launches. Only the decode is shared within a
    /// start; the ID check runs against the record every time.
    @MainActor static func hasCurrentData(for track: TrackRecord) -> Bool {
        guard let cached = shared.track(for: track.id) else { return false }
        // A catalog song prepared because the library ID was gone is current too.
        return [track.libraryID, track.catalogID].contains(cached.id.rawValue)
    }

    /// Resolves whatever can be resolved, committing each track as it
    /// arrives, then reports the failures. One unavailable song must not
    /// prevent the rest of a playlist from playing (`PLAY-017`). Library and
    /// catalog songs are each fetched in one batched lookup per preparation;
    /// a failed lookup is remembered, so the remaining tracks of that domain
    /// fail fast instead of retrying against a struggling service (`LOAD-001`).
    /// Tracks in `refreshing` are resolved again even when cached; a failed
    /// refresh keeps the cached data.
    @MainActor static func prepare(
        _ tracks: [TrackRecord],
        refreshing: Set<UUID> = [],
        libraryLookup: ([String]) async throws -> [String: Song] = { try await loadLibrarySongs($0) },
        catalogLookup: ([String]) async throws -> [String: Song] = { try await loadCatalogSongs($0) }
    ) async throws {
        try await decodingOnce {
            try await prepareOnce(tracks, refreshing: refreshing, libraryLookup: libraryLookup, catalogLookup: catalogLookup)
        }
    }

    @MainActor private static func prepareOnce(
        _ tracks: [TrackRecord],
        refreshing: Set<UUID>,
        libraryLookup: ([String]) async throws -> [String: Song],
        catalogLookup: ([String]) async throws -> [String: Song]
    ) async throws {
        let uncached = tracks.filter { refreshing.contains($0.id) || !hasCurrentData(for: $0) }
        let libraryIDs = Array(Set(uncached.compactMap(\.libraryID))).sorted()
        let catalogIDs = Array(Set(uncached.filter { $0.libraryID == nil }.compactMap(\.catalogID))).sorted()
        // A stored library ID can stop existing in the account library while
        // the song stays in its playlists; identifiers are fill-and-heal, so
        // sync never clears it (#75). Such a song plays from its catalog ID.
        var catalogForLibraryID: [String: String] = [:]
        for track in uncached {
            if let libraryID = track.libraryID, let catalogID = track.catalogID { catalogForLibraryID[libraryID] = catalogID }
        }
        var batches: [MusicResourceReference.Domain: Result<[String: Song], Error>] = [:]
        var fallback: Result<[String: Song], Error>?
        try await prepare(tracks, refreshing: refreshing) { reference in
            if batches[reference.domain] == nil {
                do {
                    let songs = reference.domain == .librarySong
                        ? try await libraryLookup(libraryIDs)
                        : try await catalogLookup(catalogIDs)
                    batches[reference.domain] = .success(songs)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    batches[reference.domain] = .failure(error)
                }
            }
            let songs = try batches[reference.domain]?.get() ?? [:]
            if let song = songs[reference.value] { return try JSONEncoder().encode(Track.song(song)) }

            // Only a definite library miss falls back; a failed request has
            // already thrown above, so the rest fail fast (`LOAD-001`).
            if reference.domain == .librarySong, let catalogID = catalogForLibraryID[reference.value] {
                if fallback == nil {
                    let missing = libraryIDs.filter { songs[$0] == nil }.compactMap { catalogForLibraryID[$0] }
                    do {
                        fallback = .success(try await catalogLookup(missing))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        fallback = .failure(error)
                    }
                    let found = (try? fallback?.get().count) ?? 0
                    MusicKitActivityLog.shared.record(
                        .playbackQueuePreparation, magnitude: Double(found),
                        detail: "prepared \(found) of \(missing.count) songs from the catalog; their library IDs no longer exist"
                    )
                }
                if let song = try fallback?.get()[catalogID] { return try JSONEncoder().encode(Track.song(song)) }
                throw PreparationError(message: "Apple Music returned no library song for \(reference.value) and no catalog song for \(catalogID).")
            }
            throw PreparationError(message: "Apple Music returned no song for \(reference.value).")
        }
    }

    /// Catalog songs in bounded batches, correlated by ID, never by position.
    @MainActor static func loadCatalogSongs(
        _ ids: [String],
        lookup: ([String]) async throws -> [Song] = { batch in
            try await AppleMusicSongLookup.catalogSongs(batch, detail: "playback catalog songs")
        }
    ) async throws -> [String: Song] {
        try await AppleMusicSongLookup.playableCatalogSongs(Array(Set(ids)).sorted(), fetch: lookup)
    }

    @MainActor static func prepare(
        _ tracks: [TrackRecord],
        refreshing: Set<UUID> = [],
        load: (MusicResourceReference) async throws -> Data
    ) async throws {
        var failures: [String] = []
        for track in tracks {
            // Within the start's `decodingOnce` this reuses the decode that
            // built `uncached`; it is checked again here so a record listed
            // twice is loaded once.
            if !refreshing.contains(track.id), hasCurrentData(for: track) { continue }
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

    /// Starting playback waits on these lookups. A weak signal must fail in
    /// seconds, not the default minute, so the queue starts with what is
    /// cached rather than leaving the car silent (`PLAY-017`).
    static let playbackRequestTimeout: TimeInterval = 15

    static func playbackRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = playbackRequestTimeout
        return request
    }

    /// Resolve a cold queue in bounded batches, rather than one network round
    /// trip per song. Correlate by resource ID, never response position.
    @MainActor static func loadLibrarySongs(
        _ ids: [String],
        nativeLookup: ([String]) async throws -> [Song] = { batch in
            try await AppleMusicSongLookup.nativeLibrarySongs(batch, detail: "playback library songs", limit: batch.count)
        },
        request: (URL) async throws -> Data = { url in
            try await AppleMusicSongLookup.playbackWebLibraryData(url, detail: "playback web library songs")
        }
    ) async throws -> [String: Song] {
        try await AppleMusicSongLookup.playableLibrarySongs(Array(Set(ids)).sorted(), native: nativeLookup, request: request)
    }

    /// A persisted web-library ID need not be queryable in the device's native
    /// library. Resolve it through its owning endpoint, retaining Apple's play
    /// parameters even for uploads that have no catalog equivalent.
    @MainActor static func loadLibrarySong(
        _ id: String,
        nativeLookup: (String) async throws -> Song? = AppleMusicSongLookup.nativeLibrarySong,
        request: (URL) async throws -> Data = { url in
            try await AppleMusicSongLookup.playbackWebLibraryData(url, detail: "playback web library song")
        }
    ) async throws -> Song {
        let native = try await nativeLookup(id)
        try Task.checkCancellation()
        if let native, native.id.rawValue == id { return native }

        var hasNextBatch = false
        let answer = try await AppleMusicSongLookup.correlated([id], id: \AppleMusicSongLookup.WebLibraryResource.song.id.rawValue) { batch in
            let response = try await AppleMusicSongLookup.webLibraryResources(batch, request: request)
            hasNextBatch = response.next != nil
            return response.data
        }
        // Strict: a 404 is not an answer about this song, so say which it was.
        if !answer.notFoundByStatus.isEmpty {
            throw PreparationError(message: "Apple Music web library answered 404 (not found) for \(id).")
        }
        let resources = answer.matches[id] ?? []
        try validateLookup(.library(id), returnedIDs: resources.map(\.song.id.rawValue) + answer.unrequested, hasNextBatch: hasNextBatch)
        let resource = resources[0]
        guard resource.type == "library-songs" else {
            throw PreparationError(message: "Apple Music web library returned resource type \(resource.type); expected library-songs.")
        }
        guard resource.song.playParameters != nil else {
            throw PreparationError(message: "Apple Music web library returned song \(id) without playback parameters.")
        }
        return resource.song
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
