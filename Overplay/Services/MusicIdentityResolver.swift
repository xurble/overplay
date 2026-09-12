import CryptoKit
import Foundation
@preconcurrency import MusicKit

/// Documented Apple Music API resource boundary. No playback or view code
/// performs these requests. A missing relationship is distinct from a failure.
@MainActor
final class MusicIdentityResolver {
    static let shared = MusicIdentityResolver()

    enum Lookup: String, Hashable { case library, catalog, equivalents, isrc }
    struct Scope: Equatable { var storefront: String; var account: String }
    struct Resource: Decodable, Equatable, Sendable {
        var id: String
        var type: String
        var attributes: Attributes?
        struct Attributes: Decodable, Equatable, Sendable {
            var isrc: String?
            var name: String?
            var artistName: String?
            var durationInMillis: Double?
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
            var resource: Resource { Resource(id: id, type: type, attributes: attributes) }
        }
        struct Relationships: Decodable { var catalog: Relationship? }
        struct Relationship: Decodable { var data: [Resource]; var next: String? }
        struct Meta: Decodable { var filters: [String: [String: [Resource]]]? }
    }
    enum ResolutionError: Error { case incompleteResponse, unauthorized, scopeChanged }
    typealias Fetch = (Lookup, [String], Scope) async throws -> [String: [Resource]]
    private struct Key: Hashable { var lookup: Lookup; var id: String }
    private struct Cached { var resources: [Resource]; var expires: Date }
    private var cache: [Key: Cached] = [:]
    private var inFlight: [String: Task<[String: [Resource]], Error>] = [:]
    private var scope: Scope?
    private var generation = 0
    private let currentScope: () async throws -> Scope
    private let fetch: Fetch
    private let now: () -> Date

    init(
        currentScope: @escaping () async throws -> Scope = MusicIdentityResolver.liveScope,
        fetch: @escaping Fetch = MusicIdentityResolver.liveFetch,
        now: @escaping () -> Date = { .now }
    ) {
        self.currentScope = currentScope
        self.fetch = fetch
        self.now = now
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
    func enrich(_ snapshots: [TrackSnapshot]) async throws -> [TrackSnapshot] {
        let current: Scope
        do { current = try await currentScope() }
        catch { invalidate(); throw error }
        if scope != current { invalidate(); scope = current }
        let revision = generation
        let libraryIDs = snapshots.compactMap { $0.resolvedIdentity.libraryID }
        let library = try await lookup(.library, ids: libraryIDs, scope: current, revision: revision)
        var result = snapshots
        for index in result.indices {
            guard let id = result[index].resolvedIdentity.libraryID else { continue }
            let resources = library[id] ?? []
            result[index].libraryID = id
            result[index].hasDocumentedIdentity = true
            result[index].catalogID = resources.count == 1 ? resources.first?.id : nil
            result[index].isrc = resources.count == 1 ? resources.first?.attributes?.isrc : result[index].isrc
        }
        let catalogIDs = result.compactMap(\.catalogID)
        let catalog = try await lookup(.catalog, ids: catalogIDs, scope: current, revision: revision)
        let missing = catalogIDs.filter { catalog[$0]?.isEmpty != false }
        let equivalents = try await lookup(.equivalents, ids: missing, scope: current, revision: revision)
        for index in result.indices {
            guard let id = result[index].catalogID else { continue }
            result[index].hasDocumentedIdentity = true
            if let resource = catalog[id]?.first { result[index].isrc = resource.attributes?.isrc ?? result[index].isrc }
            result[index].equivalentCatalogIDs = (equivalents[id] ?? []).map(\.id)
        }
        // ISRC is a candidate signal only. Multiple results never become an
        // authoritative identity, even if Apple calls them equivalents.
        let recordings = try await lookup(.isrc, ids: result.compactMap(\.isrc), scope: current, revision: revision)
        for index in result.indices {
            if let isrc = result[index].isrc {
                result[index].equivalentCatalogIDs = Array(Set(result[index].equivalentCatalogIDs + (recordings[isrc] ?? []).map(\.id))).sorted()
            }
        }
        guard generation == revision else { throw ResolutionError.scopeChanged }
        return result
    }

    private func lookup(_ kind: Lookup, ids: [String], scope: Scope, revision: Int) async throws -> [String: [Resource]] {
        let unique = Array(Set(ids.filter { !$0.isEmpty })).sorted()
        var result: [String: [Resource]] = [:]
        var missing: [String] = []
        for id in unique {
            if let cached = cache[Key(lookup: kind, id: id)], cached.expires > now() { result[id] = cached.resources }
            else { missing.append(id) }
        }
        for start in stride(from: 0, to: missing.count, by: 25) {
            try Task.checkCancellation()
            let batch = Array(missing[start..<min(start + 25, missing.count)])
            let requestKey = "\(revision):\(kind.rawValue):\(batch.joined(separator: ","))"
            let task: Task<[String: [Resource]], Error>
            if let existing = inFlight[requestKey] { task = existing }
            else {
                task = Task { [fetch] in try await fetch(kind, batch, scope) }
                inFlight[requestKey] = task
            }
            let values: [String: [Resource]]
            do { values = try await task.value }
            catch { inFlight[requestKey] = nil; throw error }
            inFlight[requestKey] = nil
            try Task.checkCancellation()
            guard generation == revision else { throw ResolutionError.scopeChanged }
            for id in batch {
                guard let resources = values[id] else { throw ResolutionError.incompleteResponse }
                let ttl: TimeInterval = resources.count == 1 ? 7 * 24 * 3600 : 3600
                cache[Key(lookup: kind, id: id)] = Cached(resources: resources, expires: now().addingTimeInterval(ttl))
                result[id] = resources
            }
            // Bound memory for large libraries; expired entries go first.
            if cache.count > 20_000 { cache = cache.filter { $0.value.expires > now() }; if cache.count > 20_000 { cache.removeAll() } }
        }
        return result
    }

    static func liveScope() async throws -> Scope {
        guard MusicAuthorization.currentStatus == .authorized else { throw ResolutionError.unauthorized }
        let provider = MusicDataRequest.tokenProvider
        let developer = try await provider.developerToken(options: [])
        let user = try await provider.userToken(for: developer, options: [])
        // Never persist or log a token. Only an in-memory fingerprint scopes cache entries.
        let account = SHA256.hash(data: Data(user.utf8)).map { String(format: "%02x", $0) }.joined()
        return Scope(storefront: try await MusicDataRequest.currentCountryCode, account: account)
    }

    static func liveFetch(_ kind: Lookup, ids: [String], scope: Scope) async throws -> [String: [Resource]] {
        var url = URLComponents(string: "https://api.music.apple.com")!
        url.path = kind == .library ? "/v1/me/library/songs" : "/v1/catalog/\(scope.storefront)/songs"
        let filter = switch kind { case .library, .catalog: "ids"; case .equivalents: "filter[equivalents]"; case .isrc: "filter[isrc]" }
        url.queryItems = [URLQueryItem(name: filter, value: ids.joined(separator: ","))]
        if kind == .library { url.queryItems?.append(URLQueryItem(name: "include", value: "catalog")) }
        let response = try await MusicKitActivityLog.shared.measure(.catalogResourceFetch, detail: "identity \(kind.rawValue)") {
            try await MusicDataRequest(urlRequest: URLRequest(url: url.url!)).response()
        }
        return try decode(response.data, kind: kind, ids: ids)
    }

    static func decode(_ data: Data, kind: Lookup, ids: [String]) throws -> [String: [Resource]] {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.next == nil else { throw ResolutionError.incompleteResponse }
        var result = Dictionary(uniqueKeysWithValues: ids.map { ($0, [Resource]()) })
        switch kind {
        case .library:
            for entry in envelope.data where result[entry.id] != nil {
                guard let relationship = entry.relationships?.catalog, relationship.next == nil else { throw ResolutionError.incompleteResponse }
                result[entry.id] = relationship.data.filter { $0.type == "songs" }
            }
        case .catalog:
            for entry in envelope.data where result[entry.id] != nil && entry.type == "songs" { result[entry.id] = [entry.resource] }
        case .equivalents:
            // Correlate through documented meta.filters, never by result order.
            guard envelope.data.isEmpty || envelope.meta?.filters?["equivalents"] != nil else {
                throw ResolutionError.incompleteResponse
            }
            let mapping = envelope.meta?.filters?["equivalents"] ?? [:]
            let byID = envelope.data.firstValueDictionary(keyedBy: \.id)
            for id in ids { result[id] = (mapping[id] ?? []).filter { $0.type == "songs" }.map { byID[$0.id]?.resource ?? $0 } }
        case .isrc:
            for entry in envelope.data where entry.type == "songs" {
                if let isrc = entry.attributes?.isrc, result[isrc] != nil { result[isrc]?.append(entry.resource) }
            }
        }
        return result
    }
}
