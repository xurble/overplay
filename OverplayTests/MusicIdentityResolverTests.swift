import Foundation
import Testing
@testable import Overplay

@MainActor
struct MusicIdentityResolverTests {
    func snapshot(_ id: String, isrc: String? = nil) -> TrackSnapshot {
        let identity = MusicTrackIdentity.ids(fromRawID: id)
        return TrackSnapshot(id: id, catalogID: identity.catalogID, libraryID: identity.libraryID,
            playlistEntryID: nil, playlistID: nil, title: "Song", artistName: "Artist", albumTitle: nil,
            artworkURLTemplate: nil, durationSeconds: nil, isrc: isrc)
    }
    func song(_ id: String, isrc: String? = nil) -> MusicIdentityResolver.Resource {
        .init(id: id, type: "songs", attributes: .init(isrc: isrc))
    }

    func library(_ id: String, catalog: [MusicIdentityResolver.Resource]) -> MusicIdentityResolver.Resource {
        .init(id: id, type: "library-songs", catalog: catalog)
    }

    @Test func documentedLibraryRelationship() throws {
        let json = #"{"data":[{"id":"i.a","type":"library-songs","relationships":{"catalog":{"data":[{"id":"10","type":"songs","attributes":{"isrc":"ABC"}}]}}}]}"#
        let values = try MusicIdentityResolver.decode(Data(json.utf8), kind: .library, ids: ["i.a"])
        #expect(values["i.a"]?.first?.id == "i.a")
        #expect(values["i.a"]?.first?.catalog?.first?.id == "10")
        #expect(values["i.a"]?.first?.catalog?.first?.attributes?.isrc == "ABC")
    }

    @Test func equivalentCorrelationUsesMetadataNotOrder() throws {
        let json = #"{"data":[{"id":"20","type":"songs"},{"id":"10","type":"songs"}],"meta":{"filters":{"equivalents":{"old-a":[{"id":"10","type":"songs"}],"old-b":[{"id":"20","type":"songs"}]}}}}"#
        let values = try MusicIdentityResolver.decode(Data(json.utf8), kind: .equivalents, ids: ["old-a", "old-b"])
        #expect(values["old-a"]?.first?.id == "10")
        #expect(values["old-b"]?.first?.id == "20")
    }

    @Test func incompleteRelationshipIsNotNegativeEvidence() {
        let json = #"{"data":[{"id":"i.a","type":"library-songs"}]}"#
        #expect(throws: MusicIdentityResolver.ResolutionError.self) {
            try MusicIdentityResolver.decode(Data(json.utf8), kind: .library, ids: ["i.a"])
        }
    }

    @Test func uploadsAndAmbiguousRelationshipsDoNotUseOpaqueHint() async throws {
        let resolver = MusicIdentityResolver(currentScope: { .init(storefront: "gb", account: "a") }, fetch: { kind, ids, _ in
            Dictionary(uniqueKeysWithValues: ids.map { id in
                (id, kind == .library ? [library(id, catalog: id == "i.ambiguous" ? [song("1"), song("2")] : [])] : [])
            })
        })
        var upload = snapshot("i.upload"); upload.catalogID = "opaque"
        let values = try await resolver.enrich([upload, snapshot("i.ambiguous")])
        #expect(values.allSatisfy { $0.catalogID == nil && $0.hasDocumentedIdentity })
        #expect(values[0].libraryID == "i.upload")
    }

    @Test func missingCatalogFindsCandidatesWithoutMergingIdentities() async throws {
        let resolver = MusicIdentityResolver(currentScope: { .init(storefront: "gb", account: "a") }, fetch: { kind, ids, _ in
            Dictionary(uniqueKeysWithValues: ids.map { ($0, kind == .equivalents ? [song("replacement")] : []) })
        })
        let result = try await resolver.enrich([snapshot("missing")])
        #expect(result[0].catalogID == "missing")
        #expect(result[0].equivalentCatalogIDs == ["replacement"])
    }

    @Test func cacheExpiryScopeAndBatchBounds() async throws {
        var date = Date(timeIntervalSince1970: 100)
        var scope = MusicIdentityResolver.Scope(storefront: "gb", account: "a")
        var calls = 0
        let resolver = MusicIdentityResolver(currentScope: { scope }, fetch: { kind, ids, _ in
            calls += 1
            #expect(ids.count <= 25)
            return Dictionary(uniqueKeysWithValues: ids.map { ($0, kind == .catalog && $0 != "missing" ? [song($0)] : []) })
        }, now: { date })
        let input = [snapshot("1"), snapshot("missing")]
        _ = try await resolver.enrich(input); let initial = calls
        _ = try await resolver.enrich(input); #expect(calls == initial)
        date += 3601
        _ = try await resolver.enrich(input); #expect(calls == initial + 2)
        date += 7 * 24 * 3600
        _ = try await resolver.enrich(input); #expect(calls > initial + 2)
        let before = calls
        scope.account = "b"
        _ = try await resolver.enrich(input); #expect(calls > before)
        let beforeStorefront = calls
        scope.storefront = "us"
        _ = try await resolver.enrich(input); #expect(calls > beforeStorefront)
        _ = try await resolver.enrich((0..<60).map { snapshot(String($0)) })
    }

    @Test func failuresAreNotCachedAsAbsence() async throws {
        var fail = true
        let resolver = MusicIdentityResolver(currentScope: { .init(storefront: "gb", account: "a") }, fetch: { _, ids, _ in
            if fail { throw URLError(.notConnectedToInternet) }
            return Dictionary(uniqueKeysWithValues: ids.map { ($0, [song($0)]) })
        })
        await #expect(throws: URLError.self) { try await resolver.enrich([snapshot("1")]) }
        fail = false
        #expect(try await resolver.enrich([snapshot("1")])[0].hasDocumentedIdentity)
    }
    @Test func includedCatalogMetadataAvoidsRedundantRequests() async throws {
        var calls: [MusicIdentityResolver.Lookup: Int] = [:]
        let resolver = MusicIdentityResolver(currentScope: { .init(storefront: "gb", account: "a") }, fetch: { kind, ids, _ in
            calls[kind, default: 0] += 1
            return Dictionary(uniqueKeysWithValues: ids.map { id in
                (id, kind == .library ? [library(id, catalog: [song(String(id.dropFirst(2)), isrc: "ISRC-" + id)])]
                    : kind == .catalog ? [song(id, isrc: "ISRC-i." + id)] : [])
            })
        })
        let result = try await resolver.enrich((0..<60).map { snapshot("i.\($0)") })
        #expect(result.count == 60)
        #expect(result.allSatisfy { $0.isrc != nil && $0.catalogID != nil })
        #expect(calls[.library] == 3)
        #expect(calls[.catalog] == nil)
        #expect(calls[.isrc] == 3)
        #expect(calls.values.reduce(0, +) == 6)
    }

    @Test func incompleteIncludedMetadataStillFetchesCatalog() async throws {
        var catalogCalls = 0
        let resolver = MusicIdentityResolver(currentScope: { .init(storefront: "gb", account: "a") }, fetch: { kind, ids, _ in
            if kind == .catalog { catalogCalls += 1 }
            return Dictionary(uniqueKeysWithValues: ids.map { id in
                (id, kind == .library ? [library(id, catalog: [song("1")])] : kind == .catalog ? [song(id, isrc: "KNOWN")] : [])
            })
        })
        let result = try await resolver.enrich([snapshot("i.a")])
        #expect(catalogCalls == 1)
        #expect(result[0].isrc == "KNOWN")
    }

    @Test func simultaneousScansShareGlobalRequestLimit() async throws {
        var active = 0
        var peak = 0
        var calls = 0
        let resolver = MusicIdentityResolver(currentScope: { .init(storefront: "gb", account: "a") }, fetch: { _, ids, _ in
            active += 1; calls += 1; peak = max(peak, active)
            defer { active -= 1 }
            try await Task.sleep(for: .milliseconds(20))
            return Dictionary(uniqueKeysWithValues: ids.map { ($0, [song($0)]) })
        })
        let first = Task { try await resolver.enrich((0..<150).map { snapshot(String($0)) }) }
        let second = Task { try await resolver.enrich((150..<300).map { snapshot(String($0)) }) }
        let firstResult = try await first.value
        let secondResult = try await second.value
        #expect(firstResult.count == 150 && secondResult.count == 150)
        #expect(peak == 3)
        #expect(active == 0 && calls == 12)
    }

    @Test func simultaneousIdenticalScansCoalesceBatches() async throws {
        var calls = 0
        let resolver = MusicIdentityResolver(currentScope: { .init(storefront: "gb", account: "a") }, fetch: { _, ids, _ in
            calls += 1
            try await Task.sleep(for: .milliseconds(20))
            return Dictionary(uniqueKeysWithValues: ids.map { ($0, [song($0)]) })
        })
        let input = (0..<60).map { snapshot(String($0)) }
        let first = Task { try await resolver.enrich(input) }
        let second = Task { try await resolver.enrich(input) }
        let firstResult = try await first.value
        let secondResult = try await second.value
        #expect(firstResult == secondResult)
        #expect(calls == 3)
    }
    @Test func libraryArtworkSurvivesMissingOrAmbiguousCatalogRelationships() async throws {
        let json = #"{"data":[{"id":"i.upload","type":"library-songs","attributes":{"artwork":{"url":"https://example.com/library/{w}x{h}.jpg"}},"relationships":{"catalog":{"data":[]}}},{"id":"i.ambiguous","type":"library-songs","attributes":{"artwork":{"url":"https://example.com/custom/{w}x{h}.jpg"}},"relationships":{"catalog":{"data":[{"id":"1","type":"songs"},{"id":"2","type":"songs"}]}}}]}"#
        let resolver = MusicIdentityResolver(currentScope: { .init(storefront: "gb", account: "a") }, fetch: { kind, ids, _ in
            #expect(kind == .library)
            return try MusicIdentityResolver.decode(Data(json.utf8), kind: kind, ids: ids)
        })
        let results = try await resolver.enrich([snapshot("i.upload"), snapshot("i.ambiguous")], includeCandidates: false)
        #expect(results.allSatisfy { $0.catalogID == nil && $0.artworkURLTemplate != nil })
        #expect(results[0].artworkURLTemplate == "https://example.com/library/{w}x{h}.jpg")
    }

    // MARK: - #111: not found is a value; every other failure is thrown

    private struct Transport404: Error {}
    private let scope = MusicIdentityResolver.Scope(storefront: "gb", account: "a")

    private func fetch(_ kind: MusicIdentityResolver.Lookup, ids: [String], throwing error: Error) async throws -> [String: [MusicIdentityResolver.Resource]] {
        try await MusicIdentityResolver.fetchResources(kind, ids: ids, scope: scope, perform: { _ in throw error }, isNotFound: { $0 is Transport404 })
    }

    /// A 404 is about the batch, not any one ID: it is kept apart from an
    /// ID a valid response leaves out, so it is never cached as absence.
    @Test func a404IsNotFoundForTheWholeBatchNotAnAnswer() async throws {
        for kind in [MusicIdentityResolver.Lookup.library, .catalog, .equivalents, .isrc] {
            var failure: Error?
            do { _ = try await fetch(kind, ids: ["a", "b"], throwing: Transport404()) } catch { failure = error }
            guard case MusicIdentityResolver.ResolutionError.notFound(let lookup, let underlying) = try #require(failure) else {
                Issue.record("expected a batch not-found for \(kind)"); continue
            }
            #expect(lookup == kind && underlying is Transport404)
        }
    }

    /// Answers as the web API does, through `fetchResources`. A lookup in
    /// `notFound` answers 404 for its whole batch. Library songs "i.N" come
    /// back with catalog song "N" and no ISRC, so the catalog is asked too.
    private func webAPI(
        notFound: @escaping () -> Set<MusicIdentityResolver.Lookup>, catalogKnows: Bool = true,
        asked: @escaping (MusicIdentityResolver.Lookup) -> Void = { _ in }
    ) -> MusicIdentityResolver.Fetch {
        { kind, ids, scope in
            asked(kind)
            return try await MusicIdentityResolver.fetchResources(kind, ids: ids, scope: scope, perform: { _ in
                if notFound().contains(kind) { throw Transport404() }
                let entries: [String] = switch kind {
                case .library: ids.map { #"{"id":"\#($0)","type":"library-songs","relationships":{"catalog":{"data":[{"id":"\#($0.dropFirst(2))","type":"songs"}]}}}"# }
                case .catalog: catalogKnows ? ids.map { #"{"id":"\#($0)","type":"songs","attributes":{"isrc":"ISRC-\#($0)"}}"# } : []
                case .equivalents, .isrc: []
                }
                return Data(#"{"data":[\#(entries.joined(separator: ","))]}"#.utf8)
            }, isNotFound: { $0 is Transport404 })
        }
    }

    /// Review of #115, finding 2: a catalog 404 costs its batch for this
    /// pass only. Nothing is cached, so the next sync asks again.
    @Test func aCatalog404IsNotFoundThisPassOnlyAndIsAskedAgain() async throws {
        var failing = true
        var catalogRequests = 0
        let resolver = MusicIdentityResolver(currentScope: { scope }, fetch: webAPI(
            notFound: { failing ? [.catalog] : [] }, asked: { if $0 == .catalog { catalogRequests += 1 } }
        ))
        let input = [snapshot("5"), snapshot("6"), snapshot("7")]
        let first = try await resolver.enrichReportingNotFound(input, includeCandidates: false, catalogAbsenceIsNotFound: true)
        #expect(first.notFound == ["5", "6", "7"].map { .init(snapshotID: $0, lookup: .catalog) })
        #expect(first.snapshots.allSatisfy { $0 == nil })
        failing = false
        let second = try await resolver.enrichReportingNotFound(input, includeCandidates: false, catalogAbsenceIsNotFound: true)
        #expect(catalogRequests == 2)
        #expect(second.notFound.isEmpty)
        #expect(second.snapshots.allSatisfy { $0?.isrc != nil })
    }

    /// Review of #115, findings 3 and 4: a 404 on any lookup reports every
    /// song in its batch as not found, even a library song and with
    /// `catalogAbsenceIsNotFound` off (the duplicate scan), and strict
    /// `enrich` (copies, artwork repair) throws it.
    @Test(arguments: [MusicIdentityResolver.Lookup.library, .catalog, .equivalents, .isrc])
    func a404OnAnyLookupCostsItsBatchAndStrictEnrichThrows(kind: MusicIdentityResolver.Lookup) async throws {
        var asked: [MusicIdentityResolver.Lookup] = []
        let resolver = MusicIdentityResolver(currentScope: { scope }, fetch: webAPI(
            notFound: { [kind] }, catalogKnows: kind != .equivalents, asked: { asked.append($0) }
        ))
        let input = [snapshot("i.10"), snapshot("i.11")]
        let tolerant = try await resolver.enrichReportingNotFound(input)
        #expect(tolerant.notFound == ["i.10", "i.11"].map { .init(snapshotID: $0, lookup: kind) })
        // A 404-covered song is not asked about further.
        #expect(asked.last == kind)
        #expect(tolerant.snapshots.allSatisfy { $0 == nil })
        var failure: Error?
        do { _ = try await resolver.enrich(input) } catch { failure = error }
        guard case MusicIdentityResolver.ResolutionError.lookupFailed(let lookup, let underlying) = try #require(failure) else {
            Issue.record("strict enrich must throw the \(kind) 404 as a failed lookup"); return
        }
        #expect(lookup == kind && underlying is Transport404)
    }

    @Test func otherFailuresThrowAndNameTheLookup() async throws {
        var failure: Error?
        do { _ = try await fetch(.library, ids: ["a"], throwing: URLError(.notConnectedToInternet)) } catch { failure = error }
        guard case MusicIdentityResolver.ResolutionError.lookupFailed(.library, let underlying) = try #require(failure) else {
            Issue.record("expected a named lookup failure"); return
        }
        #expect(underlying is URLError)
        #expect(UserFacingError.friendly(try #require(failure)) == "The web library lookup failed. You're offline. Check your connection and try again.")
    }

    @Test func cancellationIsNotWrappedOrTreatedAsNotFound() async throws {
        await #expect(throws: CancellationError.self) { try await fetch(.library, ids: ["a"], throwing: CancellationError()) }
        await #expect(throws: URLError.self) { try await fetch(.catalog, ids: ["a"], throwing: URLError(.cancelled)) }
    }

    @Test func aDataRequestStatusOf404IsTheOnlyNotFound() {
        #expect(!MusicIdentityResolver.isNotFoundResponse(URLError(.notConnectedToInternet)))
        #expect(!MusicIdentityResolver.isNotFoundResponse(NSError(domain: "MusicKit.MusicDataRequest.Error", code: 404)))
    }

    @Test func aMissingLibraryIDIsReportedAndOthersStillResolve() async throws {
        let resolver = MusicIdentityResolver(currentScope: { scope }, fetch: { kind, ids, _ in
            Dictionary(uniqueKeysWithValues: ids.map { id in
                (id, kind == .library && id != "i.gone" ? [library(id, catalog: [])] : [])
            })
        })
        let result = try await resolver.enrichReportingNotFound([snapshot("i.a"), snapshot("i.gone"), snapshot("i.gone")], includeCandidates: false)
        #expect(result.snapshots[0]?.libraryID == "i.a")
        #expect(result.snapshots[1] == nil && result.snapshots[2] == nil)
        #expect(result.notFound == [.init(snapshotID: "i.gone", lookup: .library)])
    }

    @Test func strictEnrichStillFailsOnAMissingLibrarySong() async throws {
        let resolver = MusicIdentityResolver(currentScope: { scope }, fetch: { _, ids, _ in
            Dictionary(uniqueKeysWithValues: ids.map { ($0, [MusicIdentityResolver.Resource]()) })
        })
        await #expect(throws: MusicIdentityResolver.ResolutionError.self) { try await resolver.enrich([snapshot("i.gone")]) }
    }

    @Test func aMissingLibrarySongIsAskedAboutAgainNextTime() async throws {
        var calls = 0
        var present = false
        let resolver = MusicIdentityResolver(currentScope: { scope }, fetch: { _, ids, _ in
            calls += 1
            return Dictionary(uniqueKeysWithValues: ids.map { ($0, present ? [library($0, catalog: [])] : []) })
        })
        _ = try await resolver.enrichReportingNotFound([snapshot("i.a")], includeCandidates: false)
        present = true
        let result = try await resolver.enrichReportingNotFound([snapshot("i.a")], includeCandidates: false)
        #expect(calls == 2)
        #expect(result.notFound.isEmpty && result.snapshots[0] != nil)
    }

    @Test func catalogAbsenceIsNotFoundOnlyWhenAskedAndOnlyForCatalogOnlySongs() async throws {
        let resolver = MusicIdentityResolver(currentScope: { scope }, fetch: { kind, ids, _ in
            Dictionary(uniqueKeysWithValues: ids.map { id in
                (id, kind == .library ? [library(id, catalog: [song("777")])] : [])
            })
        })
        let tolerant = try await resolver.enrichReportingNotFound([snapshot("5")], includeCandidates: false)
        #expect(tolerant.notFound.isEmpty)
        let strict = try await resolver.enrichReportingNotFound(
            [snapshot("5"), snapshot("i.a")], includeCandidates: false, catalogAbsenceIsNotFound: true
        )
        #expect(strict.notFound == [.init(snapshotID: "5", lookup: .catalog)])
        // A library song's identity is its library resource, whatever the catalog says.
        #expect(strict.snapshots[1]?.libraryID == "i.a")
    }

    /// `PLAY-017`: playback tracks survive a relaunch and a failed account
    /// check; only a different account or storefront empties them.
    @Test func playbackTracksSurviveRelaunchesAndAreClearedOnlyForAnotherAccount() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let track = UUID()
        var scope = MusicIdentityResolver.Scope(storefront: "gb", account: "a")
        var scopeFails = false
        func launch() -> (MusicIdentityResolver, DevicePlaybackCache) {
            let cache = DevicePlaybackCache(directory: directory)
            let resolver = MusicIdentityResolver(currentScope: {
                if scopeFails { throw URLError(.notConnectedToInternet) }
                return scope
            }, fetch: { _, ids, _ in
                Dictionary(uniqueKeysWithValues: ids.map { ($0, [song($0)]) })
            }, playbackCache: cache)
            return (resolver, cache)
        }

        var (resolver, cache) = launch()
        _ = try await resolver.enrich([snapshot("1")])
        cache.set(Data("song".utf8), for: track)

        (resolver, cache) = launch()
        _ = try await resolver.enrich([snapshot("1")])
        #expect(cache.data(for: track) == Data("song".utf8))

        (resolver, cache) = launch()
        scopeFails = true
        await #expect(throws: URLError.self) { try await resolver.enrich([snapshot("1")]) }
        scopeFails = false
        _ = try await resolver.enrich([snapshot("1")])
        #expect(cache.data(for: track) == Data("song".utf8))

        scope.account = "b"
        _ = try await resolver.enrich([snapshot("1")])
        #expect(cache.data(for: track) == nil)
        cache.set(Data("song".utf8), for: track)

        (resolver, cache) = launch()
        scope.storefront = "us"
        _ = try await resolver.enrich([snapshot("1")])
        #expect(DevicePlaybackCache(directory: directory).data(for: track) == nil)
    }
}
