import Foundation
import MusicKit
import Testing
@testable import Overplay

/// The shared lookup's rule set (#111), tested once here. Call sites have
/// their own coverage of what they do with an answer.
@MainActor
@Suite("Apple Music song lookup")
struct AppleMusicSongLookupTests {
    private struct Transport404: Error {}

    private static func id(_ value: String) -> String { value }

    private func correlated(
        _ ids: [String], batchSize: Int = AppleMusicSongLookup.batchSize,
        fetch: ([String]) async throws -> [String]
    ) async throws -> AppleMusicSongLookup.Answer<String> {
        try await AppleMusicSongLookup.correlated(ids, batchSize: batchSize, id: Self.id, isNotFound: { $0 is Transport404 }, fetch: fetch)
    }

    private static func song(_ id: String, type: String = "songs") throws -> Song {
        try JSONDecoder().decode(Song.self, from: JSONSerialization.data(withJSONObject: [
            "id": id, "type": type,
            "attributes": ["name": id, "artistName": "Artist", "albumName": "Album", "genreNames": [],
                           "playParams": ["id": id, "kind": "song"]]
        ]))
    }

    // MARK: Not found is a value

    @Test func a404IsNotFoundForEveryIDInItsBatchOnly() async throws {
        let answer = try await correlated(["a", "b", "c"], batchSize: 2) { batch in
            if batch.contains("a") { throw Transport404() }
            return batch
        }
        #expect(answer.matches == ["c": ["c"]])
        #expect(answer.notFoundByStatus == ["a", "b"])
        #expect(answer.unrequested.isEmpty)
    }

    /// Review of #115: an omitted ID and a 404 must not be conflated.
    @Test func anIDAbsentFromAValidResponseIsNotFoundButNotA404() async throws {
        let answer = try await correlated(["a", "b"]) { _ in ["a"] }
        #expect(answer.matches == ["a": ["a"]])
        #expect(answer.notFoundByStatus.isEmpty)
    }

    @Test func aNamedLookupFailureStillReadsAsNotFound() {
        let wrapped = MusicIdentityResolver.ResolutionError.lookupFailed(.library, underlying: Transport404())
        #expect(AppleMusicSongLookup.isNotFound(wrapped, status: { $0 is Transport404 }))
        #expect(AppleMusicSongLookup.isNotFound(
            MusicIdentityResolver.ResolutionError.notFound(.catalog, underlying: Transport404()), status: { _ in false }
        ))
        #expect(!AppleMusicSongLookup.isNotFound(
            MusicIdentityResolver.ResolutionError.lookupFailed(.library, underlying: URLError(.badServerResponse)),
            status: { $0 is Transport404 }
        ))
    }

    // MARK: Correlated by ID, never position

    @Test func unrequestedIDsAreNeverAttributed() async throws {
        let answer = try await correlated(["a"]) { _ in ["someone-else"] }
        #expect(answer.matches.isEmpty)
        #expect(answer.unrequested == ["someone-else"])
    }

    @Test func correlationHoldsWhenTheResponseIsShuffled() async throws {
        let answer = try await correlated(["a", "b", "c"]) { $0.reversed() }
        #expect(answer.matches == ["a": ["a"], "b": ["b"], "c": ["c"]])
    }

    @Test func moreThanOneMatchIsKeptForTheCallerToReject() async throws {
        let answer = try await correlated(["a"]) { _ in ["a", "a"] }
        #expect(answer.matches == ["a": ["a", "a"]])
    }

    // MARK: Batched within limits

    @Test(arguments: [
        (0, [Int]()), (1, [1]), (99, [99]), (100, [100]), (101, [100, 1]), (200, [100, 100]), (205, [100, 100, 5])
    ])
    func batchesAtTheBoundary(count: Int, expected: [Int]) async throws {
        var sizes: [Int] = []
        _ = try await correlated((0..<count).map(String.init)) { sizes.append($0.count); return $0 }
        #expect(sizes == expected)
    }

    @Test func aRepeatedIDIsAskedForOnce() async throws {
        var batches: [[String]] = []
        _ = try await correlated(["a", "b", "a"]) { batches.append($0); return $0 }
        #expect(batches == [["a", "b"]])
    }

    @Test func noIDsMeansNoRequest() async throws {
        let answer = try await correlated([]) { _ in Issue.record("a request for no IDs"); return [] }
        #expect(answer.matches.isEmpty)
    }

    // MARK: Every other failure throws

    @Test func aFailedRequestThrows() async throws {
        await #expect(throws: URLError.self) {
            _ = try await correlated(["a"]) { _ in throw URLError(.notConnectedToInternet) }
        }
    }

    @Test func a5xxStyleErrorIsNotNotFound() async throws {
        await #expect(throws: URLError.self) {
            _ = try await correlated(["a"]) { _ in throw URLError(.badServerResponse) }
        }
        #expect(!AppleMusicSongLookup.isNotFoundResponse(URLError(.badServerResponse)))
    }

    @Test func cancellationPropagates() async throws {
        await #expect(throws: CancellationError.self) {
            _ = try await correlated(["a"]) { _ in throw CancellationError() }
        }
    }

    @Test func cancellationStopsBetweenBatches() async throws {
        var fetches = 0
        let task = Task { @MainActor in
            _ = try await correlated(["a", "b"], batchSize: 1) { batch in
                fetches += 1
                withUnsafeCurrentTask { $0?.cancel() }
                return batch
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(fetches == 1)
    }

    // MARK: Pages

    private struct Page { var items: [String]; var hasNext: Bool }

    @Test func pagesArePulledUntilThereAreNoMore() async throws {
        var requests = 0
        let all = try await AppleMusicSongLookup.collectPages(
            first: Page(items: ["a", "b"], hasNext: true),
            items: { (page: Page) in page.items },
            hasNext: \.hasNext
        ) { _ in
            requests += 1
            return requests == 1 ? Page(items: ["a"], hasNext: false) : nil
        }
        #expect(all == ["a", "b", "a"])
        #expect(requests == 1)
    }

    @Test func oneResponsePageMakesNoFurtherRequest() async throws {
        let all = try await AppleMusicSongLookup.collectPages(
            first: Page(items: ["a"], hasNext: false),
            items: { (page: Page) in page.items },
            hasNext: \.hasNext
        ) { _ in Issue.record("no next page"); return nil }
        #expect(all == ["a"])
    }

    @Test func anEmptyPageStopsPaging() async throws {
        var requests = 0
        let all = try await AppleMusicSongLookup.collectPages(
            first: Page(items: ["a"], hasNext: true),
            items: { (page: Page) in page.items },
            hasNext: \.hasNext
        ) { _ in requests += 1; return Page(items: [], hasNext: true) }
        #expect(all == ["a"])
        #expect(requests == 1)
    }

    // MARK: Playable items

    @Test func aNativeHitNeedsNoWebRequest() async throws {
        let native = try Self.song("i.a", type: "library-songs")
        let songs = try await AppleMusicSongLookup.playableLibrarySongs(["i.a"], native: { _ in [native] }, request: { _ in
            Issue.record("web library consulted"); return Data()
        })
        #expect(songs["i.a"]?.id.rawValue == "i.a")
    }

    /// `PLAY-017`: a duplicated native answer is left to the web library
    /// rather than guessing, and costs no other song.
    @Test func anAmbiguousNativeAnswerFallsThroughToTheWebLibrary() async throws {
        let duplicated = try Self.song("i.a", type: "library-songs")
        let other = try Self.song("i.b", type: "library-songs")
        var webIDs: [String] = []
        let songs = try await AppleMusicSongLookup.playableLibrarySongs(["i.a", "i.b"], native: { _ in [duplicated, other, duplicated] }, request: { url in
            webIDs = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value).components(separatedBy: ",")
            return try DevicePlaybackCacheTests.libraryResponse(id: "i.a")
        })
        #expect(webIDs == ["i.a"])
        #expect(songs.count == 2)
        #expect(songs["i.a"]?.playParameters != nil)
    }

    @Test func aNativeFailureDoesNotFallBackToTheWebLibrary() async throws {
        await #expect(throws: URLError.self) {
            _ = try await AppleMusicSongLookup.playableLibrarySongs(["i.a"], native: { _ in throw URLError(.timedOut) }, request: { _ in
                Issue.record("web library consulted after a failed native lookup"); return Data()
            })
        }
    }

    @Test func aDuplicatedCatalogAnswerIsLeftOutAndCostsNoOtherSong() async throws {
        let duplicated = try Self.song("1")
        let other = try Self.song("2")
        let songs = try await AppleMusicSongLookup.playableCatalogSongs(["1", "2"]) { _ in [duplicated, other, duplicated] }
        #expect(Set(songs.keys) == ["2"])
    }

    // MARK: Rebuild (API-2)

    @Test func rebuildAsksForMissingSongsInChunks() async throws {
        let records = (0..<250).map { TrackRecord(catalogID: "cat-\($0)", title: "Song", artistName: "Artist") }
        var sizes: [Int] = []
        let tracks = await OneTruePlaylistRebuildService.catalogTracks(for: records) { ids in
            sizes.append(ids.count)
            return try ids.map { try Self.song($0) }
        }
        #expect(sizes == [100, 100, 50])
        #expect(tracks.count == 250)
    }

    @Test func aFailedRebuildLookupCostsThoseSongsNotTheRebuild() async throws {
        let records = [TrackRecord(catalogID: "1", title: "Song", artistName: "Artist")]
        let tracks = await OneTruePlaylistRebuildService.catalogTracks(for: records) { _ in throw URLError(.timedOut) }
        #expect(tracks.isEmpty)
    }
}
