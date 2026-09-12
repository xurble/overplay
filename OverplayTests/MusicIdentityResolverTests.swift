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

    @Test func documentedLibraryRelationship() throws {
        let json = #"{"data":[{"id":"i.a","type":"library-songs","relationships":{"catalog":{"data":[{"id":"10","type":"songs","attributes":{"isrc":"ABC"}}]}}}]}"#
        let values = try MusicIdentityResolver.decode(Data(json.utf8), kind: .library, ids: ["i.a"])
        #expect(values["i.a"]?.first?.id == "10")
        #expect(values["i.a"]?.first?.attributes?.isrc == "ABC")
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
                (id, kind == .library && id == "i.ambiguous" ? [song("1"), song("2")] : [])
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
                (id, kind == .library ? [song(String(id.dropFirst(2)), isrc: "ISRC-" + id)]
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
                (id, kind == .library ? [song("1")] : kind == .catalog ? [song(id, isrc: "KNOWN")] : [])
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
}
