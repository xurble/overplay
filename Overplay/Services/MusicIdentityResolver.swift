import CryptoKit
import Foundation
@preconcurrency import MusicKit

/// Documented Apple Music API resource boundary. No playback or view code
/// performs these requests. A missing relationship is distinct from a failure.
@MainActor
final class MusicIdentityResolver {
    static let shared = MusicIdentityResolver(playbackCache: .shared)

    nonisolated enum Lookup: String, Hashable {
        case library, catalog, equivalents, isrc

        /// What the lookup is called in a message people read.
        var displayName: String { self == .library ? "web library" : "catalog" }

        static func displayNames(_ lookups: some Sequence<Lookup>) -> String {
            Set(lookups.map(\.displayName)).sorted { $0 > $1 }.joined(separator: " and ")
        }
    }
    struct Scope: Equatable {
        var storefront: String
        var account: String
        /// Safe to store: `account` is already a hash of the user token.
        var fingerprint: String {
            SHA256.hash(data: Data("\(storefront)|\(account)".utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }
    struct Resource: Decodable, Equatable, Sendable {
        var id: String
        var type: String
        var attributes: Attributes?
        var catalog: [Resource]? = nil
        struct Attributes: Decodable, Equatable, Sendable {
            var isrc: String?
            var name: String?
            var artistName: String?
            var durationInMillis: Double?
            var artwork: Artwork? = nil
            struct Artwork: Decodable, Equatable, Sendable { var url: String }
        }
    }
    struct Envelope: Decodable {
        var data: [Entry]
        var next: String?
        var meta: Meta?
        struct Entry: Decodable {
            var id: String
            var type: String
            var attributes: Resource.Attributes?
            var relationships: Relationships?
            var resource: Resource { Resource(id: id, type: type, attributes: attributes, catalog: relationships?.catalog?.data) }
        }
        struct Relationships: Decodable { var catalog: Relationship? }
        struct Relationship: Decodable { var data: [Resource]; var next: String? }
        struct Meta: Decodable { var filters: [String: [String: [Resource]]]? }
    }
    enum ResolutionError: LocalizedError {
        case incompleteResponse, unauthorized, scopeChanged
        /// More of a playlist came back unidentified than may be skipped
        /// (`PLAYLIST-010`).
        case tooManyNotFound(lookups: String, count: Int, of: Int)
        /// A request failed for a reason other than "not found".
        case lookupFailed(Lookup, underlying: any Error)
        /// Apple Music answered 404 for a whole batch. Unlike an ID a valid
        /// response leaves out, this says nothing about any one song, so it
        /// is never cached: the songs are not found for this pass only.
        case notFound(Lookup, underlying: any Error)

        var errorDescription: String? {
            switch self {
            case .incompleteResponse: "Apple Music returned an incomplete answer. Overplay will try again."
            case .unauthorized: "Overplay couldn't connect to Apple Music. Check Overplay's Apple Music access in Settings."
            case .scopeChanged: "The Apple Music account changed during the sync. Overplay will try again."
            case .tooManyNotFound(let lookups, let count, let total):
                "Apple Music couldn't identify \(count) of \(total) songs (\(lookups) lookup), so this playlist wasn't synced."
            case .lookupFailed(let lookup, let underlying), .notFound(let lookup, let underlying):
                "The \(lookup.displayName) lookup failed. \(UserFacingError.friendly(underlying))"
            }
        }
    }

    /// One song a lookup answered nothing for, and which lookup that was.
    struct NotFound: Equatable, Sendable {
        var snapshotID: String
        var lookup: Lookup
    }
    struct Enrichment {
        /// One per input, in order; nil where a lookup found nothing.
        var snapshots: [TrackSnapshot?]
        /// Each song once, however many playlist entries hold it.
        var notFound: [NotFound]
    }
    typealias Fetch = (Lookup, [String], Scope) async throws -> [String: [Resource]]
    private struct Key: Hashable { var lookup: Lookup; var id: String }
    private struct Cached { var resources: [Resource]; var expires: Date }
    private var cache: [Key: Cached] = [:]
    private var inFlight: [String: Task<[String: [Resource]], Error>] = [:]
    private var scope: Scope?
    private var generation = 0
    private static let batchSize = 25
    private static let maximumConcurrentRequests = 3
    private var activeRequests = 0
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private let currentScope: () async throws -> Scope
    private let fetch: Fetch
    private let now: () -> Date
    /// The on-disk playback tracks, emptied when the account or storefront
    /// changes. This in-memory resolver forgets its scope at every launch, so
    /// the cache keeps its own.
    private let playbackCache: DevicePlaybackCache?

    init(
        currentScope: @escaping () async throws -> Scope = MusicIdentityResolver.liveScope,
        fetch: @escaping Fetch = AppleMusicSongLookup.liveIdentityResources,
        now: @escaping () -> Date = { .now },
        playbackCache: DevicePlaybackCache? = nil
    ) {
        self.currentScope = currentScope
        self.fetch = fetch
        self.now = now
        self.playbackCache = playbackCache
    }

    func invalidate() {
        cache.removeAll()
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        scope = nil
        generation += 1
    }

    /// Per-resource caches allow overlapping playlists to share batched work.
    /// Memory-only: seven days for successes, one hour for absence/ambiguity;
    /// all entries expire on process exit, account change or storefront change.
    ///
    /// Any song the web library does not know, or any 404, fails the whole
    /// call: copies and rewrites need every song, and artwork repair records
    /// an absence only from a real answer. `enrichReportingNotFound` costs
    /// one song.
    func enrich(_ snapshots: [TrackSnapshot], includeCandidates: Bool = true) async throws -> [TrackSnapshot] {
        try await enrich(snapshots, includeCandidates: includeCandidates, toleratesNotFound: false, catalogAbsenceIsNotFound: false)
            .snapshots.compactMap { $0 }
    }

    /// As `enrich`, but a song a lookup answers nothing for, or whose batch
    /// got a 404 from any lookup, is reported rather than thrown
    /// (`PLAYLIST-010`). A failed request still throws.
    /// - Parameter catalogAbsenceIsNotFound: A song known only by a catalog
    ///   ID is also not found when the catalog answers nothing. Duplicate
    ///   review leaves this off: an absent catalog ID is what it looks for
    ///   replacements of.
    func enrichReportingNotFound(
        _ snapshots: [TrackSnapshot], includeCandidates: Bool = true, catalogAbsenceIsNotFound: Bool = false
    ) async throws -> Enrichment {
        try await enrich(snapshots, includeCandidates: includeCandidates, toleratesNotFound: true,
                         catalogAbsenceIsNotFound: catalogAbsenceIsNotFound)
    }

    private func enrich(
        _ snapshots: [TrackSnapshot], includeCandidates: Bool, toleratesNotFound: Bool, catalogAbsenceIsNotFound: Bool
    ) async throws -> Enrichment {
        guard !snapshots.isEmpty else { return Enrichment(snapshots: [], notFound: []) }
        let current: Scope
        do { current = try await currentScope() }
        catch { invalidate(); throw error }
        if scope != current {
            invalidate()
            scope = current
            playbackCache?.adopt(scope: current.fingerprint)
        }
        let revision = generation
        let libraryIDs = snapshots.compactMap { $0.resolvedIdentity.libraryID }
        let (library, libraryNotFound) = try await lookup(.library, ids: libraryIDs, scope: current, revision: revision,
                                                          toleratesNotFound: toleratesNotFound)
        var result = snapshots
        for index in result.indices { result[index].hasResolvedIdentityCandidates = includeCandidates }
        var absent: [Int: Lookup] = [:]
        for index in result.indices {
            guard let id = result[index].resolvedIdentity.libraryID else { continue }
            if libraryNotFound.contains(id) || (library[id]?.isEmpty == true && toleratesNotFound) {
                absent[index] = .library
                continue
            }
            guard let libraryResources = library[id], libraryResources.count == 1,
                  let libraryResource = libraryResources.first,
                  libraryResource.id == id, libraryResource.type == "library-songs",
                  let resources = libraryResource.catalog else { throw ResolutionError.incompleteResponse }
            // Library artwork belongs to the library resource, independently
            // of whether Apple provides a catalog relationship for that song.
            if let artwork = PortableArtworkReference.validated(libraryResource.attributes?.artwork?.url) {
                result[index].artworkURLTemplate = artwork
            }
            result[index].libraryID = id
            result[index].hasDocumentedIdentity = true
            result[index].catalogID = resources.count == 1 ? resources.first?.id : nil
            result[index].isrc = resources.count == 1 ? resources.first?.attributes?.isrc : result[index].isrc
            // Included catalog resources already supply the recording metadata.
            // Reuse it instead of fetching every library song a second time.
            if resources.count == 1, let resource = resources.first, resource.attributes?.isrc != nil {
                let key = Key(lookup: .catalog, id: resource.id)
                if cache[key].map({ $0.expires <= now() }) ?? true,
                   let expires = cache[Key(lookup: .library, id: id)]?.expires {
                    cache[key] = Cached(resources: [resource], expires: expires)
                }
            }
        }
        var answered = result.indices.filter { absent[$0] == nil }
        let catalogIDs = answered.compactMap { result[$0].catalogID }
        let (catalog, catalogNotFound) = try await lookup(.catalog, ids: catalogIDs, scope: current, revision: revision,
                                                          toleratesNotFound: toleratesNotFound)
        let missing = catalogIDs.filter { !catalogNotFound.contains($0) && catalog[$0]?.isEmpty != false }
        let (equivalents, equivalentsNotFound) = includeCandidates
            ? try await lookup(.equivalents, ids: missing, scope: current, revision: revision, toleratesNotFound: toleratesNotFound)
            : ([:], [])
        for index in answered {
            guard let id = result[index].catalogID else { continue }
            if let lookup: Lookup = catalogNotFound.contains(id) ? .catalog : equivalentsNotFound.contains(id) ? .equivalents : nil {
                absent[index] = lookup
                continue
            }
            if catalogAbsenceIsNotFound, result[index].resolvedIdentity.libraryID == nil, catalog[id]?.isEmpty != false {
                absent[index] = .catalog
                continue
            }
            result[index].hasDocumentedIdentity = true
            if let resource = catalog[id]?.first {
                result[index].isrc = resource.attributes?.isrc ?? result[index].isrc
                if PortableArtworkReference.validated(result[index].artworkURLTemplate) == nil,
                   let url = resource.attributes?.artwork?.url {
                    result[index].artworkURLTemplate = url
                }
            }
            result[index].equivalentCatalogIDs = (equivalents[id] ?? []).map(\.id)
        }
        // ISRC is a candidate signal only. Multiple results never become an
        // authoritative identity, even if Apple calls them equivalents.
        answered.removeAll { absent[$0] != nil }
        let (recordings, recordingsNotFound) = includeCandidates
            ? try await lookup(.isrc, ids: answered.compactMap { result[$0].isrc }, scope: current, revision: revision,
                               toleratesNotFound: toleratesNotFound)
            : ([:], [])
        for index in answered {
            if let isrc = result[index].isrc {
                if recordingsNotFound.contains(isrc) {
                    absent[index] = .isrc
                    continue
                }
                result[index].equivalentCatalogIDs = Array(Set(result[index].equivalentCatalogIDs + (recordings[isrc] ?? []).map(\.id))).sorted()
            }
        }
        for index in result.indices {
            result[index].artworkURLTemplate = PortableArtworkReference.validated(result[index].artworkURLTemplate)
        }
        guard generation == revision else { throw ResolutionError.scopeChanged }
        var seenNotFound = Set<String>()
        let notFound = result.indices.compactMap { index -> NotFound? in
            guard let lookup = absent[index], seenNotFound.insert(result[index].id).inserted else { return nil }
            return NotFound(snapshotID: result[index].id, lookup: lookup)
        }
        return Enrichment(snapshots: result.indices.map { absent[$0] == nil ? result[$0] : nil }, notFound: notFound)
    }

    /// Answers, and the IDs whose batch got a 404 (`notFound`). A strict
    /// caller (`toleratesNotFound` false) gets the 404 thrown instead.
    private func lookup(
        _ kind: Lookup, ids: [String], scope: Scope, revision: Int, toleratesNotFound: Bool
    ) async throws -> (values: [String: [Resource]], notFound: Set<String>) {
        let unique = Array(Set(ids.filter { !$0.isEmpty })).sorted()
        var result: [String: [Resource]] = [:]
        var notFound: Set<String> = []
        var missing: [String] = []
        for id in unique {
            if let cached = cache[Key(lookup: kind, id: id)], cached.expires > now() { result[id] = cached.resources }
            else { missing.append(id) }
        }
        // Start a small window together, rather than paying one round trip
        // per batch. The shared gate also bounds simultaneous scan/sync calls.
        let windowSize = Self.batchSize * Self.maximumConcurrentRequests
        for window in stride(from: 0, to: missing.count, by: windowSize) {
            try Task.checkCancellation()
            let end = min(window + windowSize, missing.count)
            let tasks = stride(from: window, to: end, by: Self.batchSize).map { start in
                let batch = Array(missing[start..<min(start + Self.batchSize, end)])
                return (batch, Task { try await self.lookupBatch(kind, batch: batch, scope: scope, revision: revision) })
            }
            for (batch, task) in tasks {
                do {
                    let values = try await task.value
                    try Task.checkCancellation()
                    result.merge(values) { _, incoming in incoming }
                } catch ResolutionError.notFound(let lookup, let underlying) {
                    try Task.checkCancellation()
                    guard toleratesNotFound else { throw ResolutionError.lookupFailed(lookup, underlying: underlying) }
                    notFound.formUnion(batch)
                }
            }
        }
        return (result, notFound)
    }

    private func lookupBatch(_ kind: Lookup, batch: [String], scope: Scope, revision: Int) async throws -> [String: [Resource]] {
        try Task.checkCancellation()
        guard generation == revision else { throw ResolutionError.scopeChanged }
        // Another scan may have completed this batch while this window waited.
        let cached = batch.compactMap { id -> (String, [Resource])? in
            guard let value = cache[Key(lookup: kind, id: id)], value.expires > now() else { return nil }
            return (id, value.resources)
        }
        if cached.count == batch.count { return Dictionary(uniqueKeysWithValues: cached) }
        let requestKey = "\(revision):\(kind.rawValue):\(batch.joined(separator: ","))"
        let task: Task<[String: [Resource]], Error>
        if let existing = inFlight[requestKey] { task = existing }
        else {
            task = Task { try await self.performFetch(kind, batch: batch, scope: scope, revision: revision) }
            inFlight[requestKey] = task
        }
        defer { inFlight[requestKey] = nil }
        let values = try await task.value
        try Task.checkCancellation()
        guard generation == revision else { throw ResolutionError.scopeChanged }
        // Validate the whole batch before accepting any negative entries.
        guard batch.allSatisfy({ values[$0] != nil }) else { throw ResolutionError.incompleteResponse }
        for id in batch {
            let resources = values[id]!
            // The playlist retries each cycle (`PLAYLIST-010`), so a library
            // song that has not arrived yet is asked about again.
            if kind == .library, resources.isEmpty { continue }
            let matches = kind == .library ? (resources.first?.catalog ?? []) : resources
            let ttl: TimeInterval = matches.count == 1 ? 7 * 24 * 3600 : 3600
            cache[Key(lookup: kind, id: id)] = Cached(resources: resources, expires: now().addingTimeInterval(ttl))
        }
        if cache.count > 20_000 {
            cache = cache.filter { $0.value.expires > now() }
            if cache.count > 20_000 { cache.removeAll() }
        }
        return values
    }

    private func performFetch(_ kind: Lookup, batch: [String], scope: Scope, revision: Int) async throws -> [String: [Resource]] {
        if activeRequests == Self.maximumConcurrentRequests {
            await withCheckedContinuation { requestWaiters.append($0) }
        } else { activeRequests += 1 }
        defer {
            if requestWaiters.isEmpty { activeRequests -= 1 }
            else { requestWaiters.removeFirst().resume() }
        }
        try Task.checkCancellation()
        guard generation == revision else { throw ResolutionError.scopeChanged }
        return try await fetch(kind, batch, scope)
    }

    static func liveScope() async throws -> Scope {
        guard MusicAuthorization.currentStatus == .authorized else { throw ResolutionError.unauthorized }
        let provider = MusicDataRequest.tokenProvider
        let developer = try await provider.developerToken(options: [])
        let user = try await provider.userToken(for: developer, options: [])
        // Never persist or log a token. Only its fingerprint is used to scope caches.
        let account = SHA256.hash(data: Data(user.utf8)).map { String(format: "%02x", $0) }.joined()
        return Scope(storefront: try await MusicDataRequest.currentCountryCode, account: account)
    }

    /// Runs one named lookup. Every failure comes out saying which lookup it
    /// was, except cancellation and Overplay's own resolution errors.
    static func naming<T>(_ kind: Lookup, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled
                || error is ResolutionError || error is MusicLibrarySongResolver.ResolutionError { throw error }
            throw ResolutionError.lookupFailed(kind, underlying: error)
        }
    }
}
