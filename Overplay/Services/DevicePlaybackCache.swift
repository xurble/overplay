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

    /// Memory only while hosting unit tests, so tests never fill or read
    /// the device's cache directory.
    static let shared = DevicePlaybackCache(
        directory: TestHost.isHostingUnitTests
            ? nil : URL.cachesDirectory.appendingPathComponent("Overplay/PlaybackTracks", isDirectory: true)
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

    /// For a whole-library scan: the payload, without keeping it resident,
    /// so one pass does not hold every track's data for the process (PF-9).
    func dataWithoutCaching(for id: UUID) -> Data? {
        let key = id.uuidString
        if let cached = resources.withLock({ $0[key] }) { return cached }
        return fileURL(for: key).flatMap { try? Data(contentsOf: $0) }
    }

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
    /// A catalog copy found by a title-and-artist search is never current: the
    /// library is asked again at every start, so a song that comes back to
    /// the library (perhaps downloaded) plays from there.
    @MainActor static func hasCurrentData(for track: TrackRecord) -> Bool {
        guard let cached = shared.track(for: track.id) else { return false }
        // A catalog song prepared because the library ID was gone is current too.
        return [track.libraryID, track.catalogID].contains(cached.id.rawValue)
    }

    /// Catalog searches by title and artist allowed in one preparation, so a
    /// playlist of gone library-only songs cannot hold up the start.
    static let catalogSearchesPerPreparation = 10

    // MARK: - Catalog search memory (`PLAY-017`)
    //
    // Device-local, beside the tracks and emptied with them; never synced.

    /// Written only when a catalog search strictly matched a library-only
    /// song: the catalog copy cached for the track came from that search.
    struct CatalogSearchMatch: Codable, Equatable {
        var libraryID: String
        var catalogID: String
    }

    /// A search that found no unique match, so later starts do not wait on it
    /// again until it expires or the track's library ID, title, artist or
    /// duration changes.
    struct CatalogSearchMiss: Codable, Equatable {
        var libraryID: String
        var metadataKey: String
        var durationSeconds: Double
        var searchedAt: Date
    }

    /// How long a search with no unique match is remembered.
    static let catalogSearchMissLifetime: TimeInterval = 24 * 3600

    func catalogSearchMatch(for id: UUID) -> CatalogSearchMatch? {
        data(forKey: "search-match-\(id.uuidString)").flatMap { try? JSONDecoder().decode(CatalogSearchMatch.self, from: $0) }
    }

    func setCatalogSearchMatch(_ match: CatalogSearchMatch?, for id: UUID) {
        set(match.flatMap { try? JSONEncoder().encode($0) }, forKey: "search-match-\(id.uuidString)")
    }

    func catalogSearchMiss(for id: UUID) -> CatalogSearchMiss? {
        data(forKey: "search-miss-\(id.uuidString)").flatMap { try? JSONDecoder().decode(CatalogSearchMiss.self, from: $0) }
    }

    func setCatalogSearchMiss(_ miss: CatalogSearchMiss?, for id: UUID) {
        set(miss.flatMap { try? JSONEncoder().encode($0) }, forKey: "search-miss-\(id.uuidString)")
    }

    /// The cached catalog copy a search found for this library-only track,
    /// while the marker names it and it still meets the strict rule.
    @MainActor static func reusableSearchMatch(for track: TrackRecord) -> Data? {
        guard track.catalogID == nil, let libraryID = track.libraryID,
              let marker = shared.catalogSearchMatch(for: track.id), marker.libraryID == libraryID,
              let cached = shared.track(for: track.id), cached.id.rawValue == marker.catalogID,
              let rule = AppleMusicSongLookup.strictMatchRule(title: track.title, artist: track.artistName, durationSeconds: track.durationSeconds),
              PlaybackAttribution.metadataKey(title: cached.title, artist: cached.artistName) == rule.key,
              let duration = cached.duration, duration.isFinite,
              PlaybackAttribution.durationsAgree(rule.durationSeconds, duration) else { return nil }
        return shared.data(for: track.id)
    }

    /// The remembered no-unique-match search for this track, if it still applies.
    @MainActor static func rememberedSearchMiss(for track: TrackRecord, now: Date = .now) -> CatalogSearchMiss? {
        guard let libraryID = track.libraryID,
              let rule = AppleMusicSongLookup.strictMatchRule(title: track.title, artist: track.artistName, durationSeconds: track.durationSeconds),
              let miss = shared.catalogSearchMiss(for: track.id),
              miss.libraryID == libraryID, miss.metadataKey == rule.key, miss.durationSeconds == rule.durationSeconds,
              (0..<catalogSearchMissLifetime).contains(now.timeIntervalSince(miss.searchedAt)) else { return nil }
        return miss
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
        catalogLookup: ([String]) async throws -> [String: Song] = { try await loadCatalogSongs($0) },
        storefront: () async throws -> String = { try await AppleMusicSongLookup.playbackStorefront() },
        catalogSearch: (_ term: String, _ storefront: String) async throws -> [Song] = {
            try await AppleMusicSongLookup.playbackCatalogSearch(term: $0, storefront: $1)
        }
    ) async throws {
        try await decodingOnce {
            try await prepareOnce(
                tracks, refreshing: refreshing, libraryLookup: libraryLookup, catalogLookup: catalogLookup,
                storefront: storefront, catalogSearch: catalogSearch
            )
        }
    }

    @MainActor private static func prepareOnce(
        _ tracks: [TrackRecord],
        refreshing: Set<UUID>,
        libraryLookup: ([String]) async throws -> [String: Song],
        catalogLookup: ([String]) async throws -> [String: Song],
        storefront: () async throws -> String,
        catalogSearch: (String, String) async throws -> [Song]
    ) async throws {
        let uncached = tracks.filter { refreshing.contains($0.id) || !hasCurrentData(for: $0) }
        // A library-only song whose library ID is gone has nothing else to
        // play from, so it is searched for by title and artist (`PLAY-017`).
        var searchTargets: [String: TrackRecord] = [:]
        // A track with a catalog ID takes the fallback above instead.
        for track in uncached {
            if let libraryID = track.libraryID, searchTargets[libraryID] == nil { searchTargets[libraryID] = track }
        }
        var searchesLeft = catalogSearchesPerPreparation
        var searchFailure: Error?
        // Looked up once, and only when a search is about to run.
        var storefrontResult: Result<String, Error>?
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
            if reference.domain == .librarySong, let track = searchTargets[reference.value] {
                // Played on this device only: the match is never stored as
                // the song's identity. A copy an earlier search found plays
                // again while the library still misses (`PLAY-017`).
                if let reused = reusableSearchMatch(for: track) { return reused }
                guard let rule = AppleMusicSongLookup.strictMatchRule(
                    title: track.title, artist: track.artistName, durationSeconds: track.durationSeconds
                ) else {
                    let reason = track.durationSeconds?.isFinite == true ? "the track has no title or artist to match" : "the track has no stored duration to match"
                    throw PreparationError(message: "Apple Music returned no song for \(reference.value), and it was not searched for by title and artist: \(reason).")
                }
                if let miss = rememberedSearchMiss(for: track) {
                    throw PreparationError(message: "Apple Music returned no song for \(reference.value), and the catalog search by title and artist at \(miss.searchedAt.formatted(date: .abbreviated, time: .shortened)) found no unique match; it is searched again after a day.")
                }
                // A failed search or storefront lookup is remembered, so the
                // rest fail fast (`LOAD-001`).
                func searchFailed(_ error: Error) -> PreparationError {
                    let underlying = error as NSError
                    return PreparationError(message: "Apple Music returned no song for \(reference.value), and the catalog search by title and artist failed: \(error.localizedDescription) [\(underlying.domain), code \(underlying.code)]")
                }
                if let searchFailure { throw searchFailed(searchFailure) }
                guard searchesLeft > 0 else {
                    throw PreparationError(message: "Apple Music returned no song for \(reference.value), and this preparation's catalog searches are used up.")
                }
                searchesLeft -= 1
                let candidates: [Song]
                do {
                    if storefrontResult == nil {
                        do { storefrontResult = .success(try await storefront()) }
                        catch is CancellationError { throw CancellationError() }
                        catch { storefrontResult = .failure(error) }
                    }
                    let code = try storefrontResult!.get()
                    candidates = try await catalogSearch("\(track.title) \(track.artistName)", code)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    searchFailure = error
                    throw searchFailed(error)
                }
                let match = AppleMusicSongLookup.strictCatalogMatch(
                    title: track.title, artist: track.artistName, durationSeconds: track.durationSeconds,
                    albumTitle: track.albumTitle, in: candidates
                )
                if case .unique(let song) = match {
                    MusicKitActivityLog.shared.record(
                        .playbackQueuePreparation, magnitude: 1,
                        detail: "prepared ‘\(track.title)’ by \(track.artistName) from catalog song \(song.id.rawValue), found by title and artist; its library ID \(reference.value) no longer exists"
                    )
                    shared.setCatalogSearchMiss(nil, for: track.id)
                    let marker = CatalogSearchMatch(libraryID: reference.value, catalogID: song.id.rawValue)
                    for record in uncached where record.libraryID == reference.value && record.catalogID == nil {
                        shared.setCatalogSearchMatch(marker, for: record.id)
                    }
                    return try JSONEncoder().encode(Track.song(song))
                }
                shared.setCatalogSearchMiss(
                    CatalogSearchMiss(libraryID: reference.value, metadataKey: rule.key, durationSeconds: rule.durationSeconds, searchedAt: .now),
                    for: track.id
                )
                if case .ambiguous(let count) = match {
                    MusicKitActivityLog.shared.record(
                        .playbackQueuePreparation, magnitude: Double(count),
                        detail: "left out ‘\(track.title)’ by \(track.artistName): its library ID \(reference.value) no longer exists and \(count) catalog songs match its title, artist and duration"
                    )
                    throw PreparationError(message: "Apple Music returned no song for \(reference.value), and the catalog search by title and artist was ambiguous (\(count) matches).")
                }
                throw PreparationError(message: "Apple Music returned no song for \(reference.value), and the catalog search by title and artist found no match: no catalog song matches its title, artist and duration.")
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
