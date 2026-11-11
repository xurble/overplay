import Foundation
@preconcurrency import MusicKit

/// The one place Overplay turns Apple Music song IDs into songs, for both
/// questions: what are this song's IDs (domain, catalog relationship, ISRC),
/// and what is its playable item. Every ID lookup goes through here, so the
/// rules are stated once:
///
/// - The responding endpoint establishes the domain. ID syntax never does.
/// - Results are correlated by ID, never by position, and an item whose ID was
///   not requested is never attributed to a requested one.
/// - A 404, or an ID absent from a valid response, is "not found" for those
///   IDs: a value, not an error. The two stay distinct: a 404 says nothing
///   about any one ID, so it is never remembered as an answer, and a strict
///   caller can throw on it. Every other failure is thrown.
/// - Requests are batched within the limits below. No caller issues one
///   request per song where a batched form exists.
///
/// `MusicIdentityResolver` keeps the identity cache, in-flight coalescing and
/// concurrency gate; this type holds the requests and rules beneath them.
@MainActor
enum AppleMusicSongLookup {
    /// IDs per native-library, catalog or playback web-library request.
    static let batchSize = 100
    /// IDs per web-library request made to establish identity, which also
    /// asks for each song's catalog relationship.
    static let webLibraryIdentityBatchSize = 25

    /// What a batched lookup found, keyed by requested ID. An ID with no key
    /// was not found. `notFoundByStatus` holds the IDs of batches answered
    /// 404, apart from IDs a valid response omitted: never cache them as a
    /// negative answer. `unrequested` holds IDs nobody asked about: they are
    /// never attributed to a requested ID, and each caller decides whether
    /// one stops its fetch.
    struct Answer<Item> {
        var matches: [String: [Item]] = [:]
        var notFoundByStatus: [String] = []
        var unrequested: [String] = []
    }

    /// Runs one request per batch and applies the rule set to each.
    /// - Parameter fetch: One batch's request. A 404 from it reads as nothing
    ///   found for that batch.
    static func correlated<Item>(
        _ ids: some Sequence<String>,
        batchSize: Int = batchSize,
        id: (Item) -> String,
        isNotFound: (Error) -> Bool = isNotFoundResponse,
        fetch: ([String]) async throws -> [Item]
    ) async throws -> Answer<Item> {
        var seen = Set<String>()
        let unique = ids.filter { seen.insert($0).inserted }
        var answer = Answer<Item>()
        for start in stride(from: 0, to: unique.count, by: batchSize) {
            try Task.checkCancellation()
            let batch = Array(unique[start..<min(start + batchSize, unique.count)])
            let requested = Set(batch)
            let items: [Item]
            do {
                items = try await fetch(batch)
            } catch where isNotFound(error) {
                answer.notFoundByStatus += batch
                items = []
            }
            try Task.checkCancellation()
            for item in items {
                let itemID = id(item)
                if requested.contains(itemID) { answer.matches[itemID, default: []].append(item) }
                else { answer.unrequested.append(itemID) }
            }
        }
        return answer
    }

    /// True only for a 404 from Apple Music, including one already named by
    /// `MusicIdentityResolver.naming`.
    nonisolated static func isNotFoundResponse(_ error: Error) -> Bool {
        isNotFound(error, status: { ($0 as? MusicDataRequest.Error)?.status == 404 })
    }

    /// Looks through a named lookup failure, so wrapping cannot turn a 404
    /// into a failure. The status check is injected because MusicKit's error
    /// type cannot be built outside MusicKit.
    nonisolated static func isNotFound(_ error: Error, status: (Error) -> Bool) -> Bool {
        if case MusicIdentityResolver.ResolutionError.notFound = error { return true }
        if case MusicIdentityResolver.ResolutionError.lookupFailed(_, let underlying) = error {
            return isNotFound(underlying, status: status)
        }
        return status(error)
    }

    /// Every requested ID with exactly one match. More than one match is
    /// ambiguous and left out, as an absent song is.
    private static func singleMatches(_ answer: Answer<Song>) -> [String: Song] {
        answer.matches.compactMapValues { $0.count == 1 ? $0[0] : nil }
    }

    /// A response's items across all its pages. A batched lookup uses this to
    /// see a second match for a song that spills past the first page: without
    /// it, the first page's copy would read as a unique answer.
    static func collectPages<Page, Item>(
        first: Page,
        items: (Page) -> [Item],
        hasNext: (Page) -> Bool,
        next: (Page) async throws -> Page?
    ) async throws -> [Item] {
        var collected = items(first)
        var page = first
        while hasNext(page), let following = try await next(page), !items(following).isEmpty {
            collected += items(following)
            page = following
        }
        return collected
    }

    // MARK: - Playable items

    /// Library songs by ID, from the device's own library and then the web
    /// library for the rest. An ID neither answers is left out, so its track
    /// fails on its own (`PLAY-017`).
    static func playableLibrarySongs(
        _ ids: [String],
        native: ([String]) async throws -> [Song],
        request: (URL) async throws -> Data
    ) async throws -> [String: Song] {
        var result = singleMatches(try await correlated(ids, id: \.id.rawValue, fetch: native))
        let missing = ids.filter { result[$0] == nil }
        guard !missing.isEmpty else { return result }
        let web = try await correlated(missing, id: \WebLibraryResource.song.id.rawValue) { batch in
            try await webLibraryResources(batch, request: request).data
        }
        for id in missing {
            guard let matches = web.matches[id], matches.count == 1, let resource = matches.first,
                  resource.type == "library-songs", resource.song.playParameters != nil else { continue }
            result[id] = resource.song
        }
        return result
    }

    /// Catalog songs by ID. An ID the catalog does not answer exactly once is
    /// left out.
    static func playableCatalogSongs(
        _ ids: [String], fetch: ([String]) async throws -> [Song]
    ) async throws -> [String: Song] {
        singleMatches(try await correlated(ids, id: \.id.rawValue, fetch: fetch))
    }

    /// One catalog song by ID, or nil when the catalog does not know it.
    static func catalogSong(
        id: String, detail: String, properties: [PartialMusicAsyncProperty<Song>] = [], limit: Int? = nil
    ) async throws -> Song? {
        let answer = try await correlated([id], id: \Song.id.rawValue) {
            try await catalogSongs($0, detail: detail, properties: properties, limit: limit)
        }
        return answer.matches[id]?.first
    }

    /// One web-library request, decoded with each song's play parameters.
    static func webLibraryResources(
        _ ids: [String], request: (URL) async throws -> Data
    ) async throws -> WebLibraryResponse {
        var url = URLComponents(string: "https://api.music.apple.com/v1/me/library/songs")!
        url.queryItems = [URLQueryItem(name: "ids", value: ids.joined(separator: ","))]
        return try JSONDecoder().decode(WebLibraryResponse.self, from: try await request(url.url!))
    }

    struct WebLibraryResponse: Decodable {
        var data: [WebLibraryResource]
        var next: String?
    }

    struct WebLibraryResource: Decodable {
        let type: String
        let song: Song

        private enum CodingKeys: String, CodingKey { case type }

        init(from decoder: any Decoder) throws {
            type = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .type)
            song = try Song(from: decoder)
        }
    }

    // MARK: - Catalog search by title and artist

    /// Results asked for in one playback catalog search.
    static let catalogSearchLimit = 25

    /// What a title-and-artist catalog search found for one track.
    enum CatalogSearchMatch {
        case unique(Song)
        case ambiguous(count: Int)
        case none
    }

    /// The strict rule for playing a library-only song from a catalog
    /// search (`PLAY-017`): exactly one playable result whose normalised title
    /// and artist equal the track's and whose duration is within 2 seconds of
    /// the track's stored duration. Without a stored duration nothing
    /// matches, so the search can never play a different song.
    static func strictCatalogMatch(
        title: String, artist: String, durationSeconds: Double?, in candidates: [Song]
    ) -> CatalogSearchMatch {
        guard let key = PlaybackAttribution.metadataKey(title: title, artist: artist),
              let durationSeconds else { return .none }
        var seen = Set<String>()
        let matches = candidates.filter { song in
            guard song.playParameters != nil,
                  PlaybackAttribution.metadataKey(title: song.title, artist: song.artistName) == key,
                  let duration = song.duration,
                  PlaybackAttribution.durationsAgree(durationSeconds, duration) else { return false }
            return seen.insert(song.id.rawValue).inserted
        }
        switch matches.count {
        case 0: return .none
        case 1: return .unique(matches[0])
        default: return .ambiguous(count: matches.count)
        }
    }

    /// Songs from one catalog search request. A 404 reads as no songs.
    static func catalogSearchSongs(
        term: String, storefront: String, request: (URL) async throws -> Data
    ) async throws -> [Song] {
        struct Response: Decodable {
            struct Results: Decodable { var songs: Page? }
            struct Page: Decodable { var data: [Song] }
            var results: Results
        }
        var url = URLComponents(string: "https://api.music.apple.com")!
        url.path = "/v1/catalog/\(storefront)/search"
        url.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "types", value: "songs"),
            URLQueryItem(name: "limit", value: String(catalogSearchLimit))
        ]
        let data: Data
        do {
            data = try await request(url.url!)
        } catch where isNotFoundResponse(error) {
            return []
        }
        return try JSONDecoder().decode(Response.self, from: data).results.songs?.data ?? []
    }

    // MARK: - Live requests

    /// One playback catalog search, keeping the playback request timeout.
    static func playbackCatalogSearch(term: String) async throws -> [Song] {
        let storefront = try await MusicDataRequest.currentCountryCode
        return try await catalogSearchSongs(term: term, storefront: storefront) { url in
            try await MusicKitActivityLog.shared.measure(.catalogSearch, detail: "playback catalog search") {
                try await MusicDataRequest(urlRequest: DevicePlaybackCache.playbackRequest(url)).response().data
            }
        }
    }

    /// The transport behind a playback web-library lookup, keeping its timeout.
    static func playbackWebLibraryData(_ url: URL, detail: String) async throws -> Data {
        try await MusicKitActivityLog.shared.measure(.catalogResourceFetch, detail: detail) {
            try await MusicDataRequest(urlRequest: DevicePlaybackCache.playbackRequest(url)).response().data
        }
    }

    /// One native-library query for these IDs. `limit` nil leaves MusicKit's
    /// default. `allPages` follows every page (see `collectPages`).
    static func nativeLibrarySongs(
        _ ids: [String], detail: String, limit: Int? = nil, allPages: Bool = false
    ) async throws -> [Song] {
        var request = MusicLibraryRequest<Song>()
        request.filter(matching: \.id, memberOf: ids.map { MusicItemID($0) })
        if let limit { request.limit = limit }
        let first = try await MusicKitActivityLog.shared.measure(.libraryTrackQuery, magnitude: Double(ids.count), detail: detail) {
            try await request.response().items
        }
        guard allPages else { return Array(first) }
        return try await collectPages(first: first, items: { Array($0) }, hasNext: \.hasNextBatch) { page in
            try await MusicKitActivityLog.shared.measure(.libraryTrackQuery, detail: detail) {
                try await page.nextBatch()
            }
        }
    }

    /// One native-library lookup of a single ID; up to two matches, so a song
    /// that is not unique can be told apart. It runs per song because a
    /// native ID can answer with a different song ID (`resolveAll`).
    static func nativeLibrarySongMatches(_ id: MusicItemID) async throws -> [Song] {
        var request = MusicLibraryRequest<Song>()
        request.filter(matching: \.id, equalTo: id)
        request.limit = 2
        let items = try await MusicKitActivityLog.shared.measure(.libraryTrackQuery, magnitude: 1, detail: "resolver library song") {
            try await request.response().items
        }
        guard items.isEmpty || !items.hasNextBatch else { throw MusicLibrarySongResolver.ResolutionError.unresolved(id.rawValue) }
        return Array(items)
    }

    /// The single native-library match for a playback ID, or nil.
    static func nativeLibrarySong(_ id: String) async throws -> Song? {
        var request = MusicLibraryRequest<Song>()
        request.filter(matching: \.id, equalTo: MusicItemID(id))
        request.limit = 2
        let items = try await MusicKitActivityLog.shared.measure(.libraryTrackQuery, magnitude: 1, detail: "playback library song") {
            try await request.response().items
        }
        guard items.count == 1, !items.hasNextBatch else { return nil }
        return items.first
    }

    /// One catalog request for these IDs. A single ID is asked for directly,
    /// as `equalTo` always has been; several go in one `memberOf` request.
    static func catalogSongs(
        _ ids: [String], detail: String, properties: [PartialMusicAsyncProperty<Song>] = [],
        limit: Int? = nil, allPages: Bool = false
    ) async throws -> [Song] {
        var request = ids.count == 1
            ? MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(ids[0]))
            : MusicCatalogResourceRequest<Song>(matching: \.id, memberOf: ids.map { MusicItemID($0) })
        request.properties = properties
        request.limit = limit
        let first = try await MusicKitActivityLog.shared.measure(.catalogResourceFetch, magnitude: Double(ids.count), detail: detail) {
            try await request.response().items
        }
        guard allPages else { return Array(first) }
        return try await collectPages(first: first, items: { Array($0) }, hasNext: \.hasNextBatch) { page in
            try await MusicKitActivityLog.shared.measure(.catalogResourceFetch, detail: detail) {
                try await page.nextBatch()
            }
        }
    }

    /// One catalog lookup of a single ID. More than a page of answers cannot
    /// be told from a complete one, so it is unresolved.
    static func catalogSongMatches(_ id: MusicItemID) async throws -> [Song] {
        let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: id)
        let items = try await MusicKitActivityLog.shared.measure(.catalogResourceFetch, magnitude: 1, detail: "resolver catalog song") {
            try await request.response().items
        }
        guard !items.hasNextBatch else { throw MusicLibrarySongResolver.ResolutionError.unresolved(id.rawValue) }
        return Array(items)
    }

    /// The IDs a batch of web-library requests answers, under the rule set.
    /// `MusicLibrarySongResolver` calls one request at a time instead.
    static func webLibrarySongIDs(_ ids: [String]) async throws -> [String] {
        let answer = try await correlated(ids, batchSize: webLibraryIdentityBatchSize, id: { (returned: String) in returned }) { batch in
            try await fetchWebLibrarySongIDs(batch.map { MusicItemID($0) })
        }
        return Array(answer.matches.keys) + answer.unrequested
    }

    /// IDs of the library-song resources the web library returns for one
    /// request. A 404 is thrown here and read as "not found" by `correlated`.
    static func fetchWebLibrarySongIDs(_ ids: [MusicItemID]) async throws -> [String] {
        var components = URLComponents(string: "https://api.music.apple.com/v1/me/library/songs")!
        components.queryItems = [URLQueryItem(name: "ids", value: ids.map(\.rawValue).joined(separator: ","))]
        let data = try await MusicDataRequest(urlRequest: URLRequest(url: components.url!)).response().data
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

    // MARK: - Identity

    typealias Lookup = MusicIdentityResolver.Lookup
    typealias Scope = MusicIdentityResolver.Scope
    typealias Resource = MusicIdentityResolver.Resource
    typealias Envelope = MusicIdentityResolver.Envelope

    static func liveIdentityResources(
        _ kind: Lookup, ids: [String], scope: Scope
    ) async throws -> [String: [Resource]] {
        try await fetchResources(kind, ids: ids, scope: scope, perform: { request in
            try await MusicKitActivityLog.shared.measure(.catalogResourceFetch, detail: "identity \(kind.rawValue)") {
                try await MusicDataRequest(urlRequest: request).response()
            }.data
        }, isNotFound: isNotFoundResponse)
    }

    /// A 404 throws `notFound` for the whole batch, which the resolver
    /// neither caches nor reads as an answer about any one ID; any other
    /// failure is thrown as `lookupFailed`. The transport is injected
    /// because MusicKit's error type cannot be built outside MusicKit.
    static func fetchResources(
        _ kind: Lookup, ids: [String], scope: Scope,
        perform: (URLRequest) async throws -> Data,
        isNotFound: (Error) -> Bool
    ) async throws -> [String: [Resource]] {
        var url = URLComponents(string: "https://api.music.apple.com")!
        url.path = kind == .library ? "/v1/me/library/songs" : "/v1/catalog/\(scope.storefront)/songs"
        let filter = switch kind { case .library, .catalog: "ids"; case .equivalents: "filter[equivalents]"; case .isrc: "filter[isrc]" }
        url.queryItems = [URLQueryItem(name: filter, value: ids.joined(separator: ","))]
        if kind == .library { url.queryItems?.append(URLQueryItem(name: "include", value: "catalog")) }
        let request = URLRequest(url: url.url!)
        return try await MusicIdentityResolver.naming(kind) {
            do {
                return try decode(try await perform(request), kind: kind, ids: ids)
            } catch where isNotFound(error) {
                throw MusicIdentityResolver.ResolutionError.notFound(kind, underlying: error)
            }
        }
    }

    static func decode(_ data: Data, kind: Lookup, ids: [String]) throws -> [String: [Resource]] {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.next == nil else { throw MusicIdentityResolver.ResolutionError.incompleteResponse }
        var result = Dictionary(uniqueKeysWithValues: ids.map { ($0, [Resource]()) })
        switch kind {
        case .library:
            var returnedIDs: Set<String> = []
            for entry in envelope.data where result[entry.id] != nil {
                guard entry.type == "library-songs", returnedIDs.insert(entry.id).inserted,
                      let relationship = entry.relationships?.catalog, relationship.next == nil else { throw MusicIdentityResolver.ResolutionError.incompleteResponse }
                var resource = entry.resource
                resource.catalog = relationship.data.filter { $0.type == "songs" }
                result[entry.id] = [resource]
            }
            // An absent resource stays empty: unresolved, not "no catalog
            // match". Only a returned library song with an explicitly empty
            // relationship proves that.
        case .catalog:
            for entry in envelope.data where result[entry.id] != nil && entry.type == "songs" { result[entry.id] = [entry.resource] }
        case .equivalents:
            // Correlate through documented meta.filters, never by result order.
            guard envelope.data.isEmpty || envelope.meta?.filters?["equivalents"] != nil else {
                throw MusicIdentityResolver.ResolutionError.incompleteResponse
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
