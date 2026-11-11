import Foundation
@preconcurrency import MusicKit
import SwiftData
import Testing
@testable import Overplay

/// `PLAY-017`: a library-only song whose library ID is gone is searched for in
/// the catalog by title and artist, and played on this device only on a
/// strict match. On 2026-11-11 "Sofia" by Clairo was left out of the One True
/// Playlist on the Mac: its library ID returned no song and it had no catalog
/// ID to fall back to.
@MainActor
@Suite("Library-only catalog fallback", .serialized)
struct LibraryOnlyCatalogFallbackTests {
    static func song(_ id: String, title: String, artist: String, seconds: Double?, playable: Bool = true) throws -> Song {
        var attributes: [String: Any] = ["name": title, "artistName": artist, "albumName": "Album", "genreNames": []]
        if let seconds { attributes["durationInMillis"] = Int(seconds * 1000) }
        if playable { attributes["playParams"] = ["id": id, "kind": "song"] }
        return try JSONDecoder().decode(Song.self, from: JSONSerialization.data(withJSONObject: [
            "id": id, "type": "songs", "attributes": attributes
        ]))
    }

    static func sofia(duration: Double? = 188) -> TrackRecord {
        TrackRecord(libraryID: "i.1YBmOmQIqAAPdr", title: "Sofia", artistName: "Clairo", durationSeconds: duration)
    }

    static func cachedID(_ track: TrackRecord) throws -> String? {
        try DevicePlaybackCache.shared.data(for: track.id).map { try JSONDecoder().decode(Track.self, from: $0).id.rawValue }
    }

    // MARK: - Preparation

    @Test func aUniqueMatchIsPreparedOnThisDeviceOnly() async throws {
        let track = Self.sofia()
        let updatedAt = track.updatedAt
        defer { DevicePlaybackCache.shared.set(nil, for: track.id) }
        var terms: [String] = []
        let search: (String) async throws -> [Song] = { term in
            terms.append(term)
            return [
                try Self.song("100", title: "Sofia (Live)", artist: "Clairo", seconds: 188),
                try Self.song("101", title: "Sofia", artist: "Someone Else", seconds: 188),
                try Self.song("1453", title: "SOFIA", artist: " clairo ", seconds: 189.5)
            ]
        }

        try await DevicePlaybackCache.prepare([track], libraryLookup: { _ in [:] }, catalogLookup: { _ in
            Issue.record("catalog ID lookup without a catalog ID"); return [:]
        }, catalogSearch: search)

        #expect(terms == ["Sofia Clairo"])
        #expect(try Self.cachedID(track) == "1453")
        // Nothing synced is written: the match is not the song's identity.
        #expect(track.catalogID == nil)
        #expect(track.libraryID == "i.1YBmOmQIqAAPdr")
        #expect(track.confirmedAliases.isEmpty)
        #expect(track.equivalentCatalogIDs.isEmpty)
        #expect(track.isrc == nil)
        #expect(track.updatedAt == updatedAt)

        // The prepared match is current: it is not searched for on every play.
        try await DevicePlaybackCache.prepare([track], libraryLookup: { _ in
            Issue.record("library looked up again"); return [:]
        }, catalogSearch: search)
        #expect(terms.count == 1)
    }

    @Test func aCachedCatalogSongThatNoLongerMatchesIsSearchedAgain() async throws {
        let track = Self.sofia()
        defer { DevicePlaybackCache.shared.set(nil, for: track.id) }
        DevicePlaybackCache.shared.set(try PlaybackFixture.encodedTrack(id: "999", title: "Bags", artist: "Clairo"), for: track.id)
        var searches = 0
        try await DevicePlaybackCache.prepare([track], libraryLookup: { _ in [:] }, catalogSearch: { _ in
            searches += 1
            return [try Self.song("1453", title: "Sofia", artist: "Clairo", seconds: 188)]
        })
        #expect(searches == 1)
        #expect(try Self.cachedID(track) == "1453")
    }

    /// A cached catalog song is current for a library-only record only while
    /// it still meets the strict match.
    @Test(arguments: [
        ("1453", "Sofia", 188_000, 188.0, false, true),
        ("1453", "Bags", 188_000, 188.0, false, false),          // another title
        ("1453", "Sofia", 191_000, 188.0, false, false),         // duration off by 3 s
        ("1453", "Sofia", 188_000, nil, false, false),           // no stored duration
        ("i.old", "Sofia", 188_000, 188.0, false, false),        // a library song, not a catalog match
        ("1453", "Sofia", 188_000, 188.0, true, false)           // the record now has a catalog ID
    ] as [(String, String, Int, Double?, Bool, Bool)])
    func aCachedSearchMatchIsCurrentOnlyWhileItStillMatches(
        cachedID: String, title: String, millis: Int, stored: Double?, hasCatalogID: Bool, current: Bool
    ) throws {
        let track = Self.sofia(duration: stored)
        if hasCatalogID { track.catalogID = "777" }
        defer { DevicePlaybackCache.shared.set(nil, for: track.id) }
        DevicePlaybackCache.shared.set(try PlaybackFixture.encodedTrack(id: cachedID, title: title, artist: "Clairo", durationMillis: millis), for: track.id)
        #expect(DevicePlaybackCache.hasCurrentData(for: track) == current)
    }

    @Test func twoMatchesLeaveTheSongOutAndTheRestPrepared() async throws {
        let track = Self.sofia()
        let present = TrackRecord(libraryID: "i.present", title: "Bags", artistName: "Clairo", durationSeconds: 260)
        defer { for item in [track, present] { DevicePlaybackCache.shared.set(nil, for: item.id) } }
        let presentSong = try Self.song("i.present", title: "Bags", artist: "Clairo", seconds: 260)
        do {
            try await DevicePlaybackCache.prepare([track, present], libraryLookup: { _ in ["i.present": presentSong] }, catalogSearch: { _ in [
                try Self.song("1453", title: "Sofia", artist: "Clairo", seconds: 188),
                try Self.song("1454", title: "Sofia", artist: "Clairo", seconds: 187)
            ] })
            Issue.record("Expected Sofia to be left out")
        } catch {
            #expect(error.localizedDescription.contains("ambiguous (2 matches)"))
        }
        #expect(try Self.cachedID(track) == nil)
        #expect(try Self.cachedID(present) == "i.present")
    }

    @Test(arguments: [190.5, 185.5])
    func aMatchWhoseDurationDiffersByMoreThanTwoSecondsIsLeftOut(seconds: Double) async throws {
        let track = Self.sofia()
        defer { DevicePlaybackCache.shared.set(nil, for: track.id) }
        await #expect(throws: DevicePlaybackCache.PreparationError.self) {
            try await DevicePlaybackCache.prepare([track], libraryLookup: { _ in [:] }, catalogSearch: { _ in
                [try Self.song("1453", title: "Sofia", artist: "Clairo", seconds: seconds)]
            })
        }
        #expect(try Self.cachedID(track) == nil)
    }

    @Test func aTrackWithNoStoredDurationIsLeftOut() async throws {
        let track = Self.sofia(duration: nil)
        defer { DevicePlaybackCache.shared.set(nil, for: track.id) }
        do {
            try await DevicePlaybackCache.prepare([track], libraryLookup: { _ in [:] }, catalogSearch: { _ in
                [try Self.song("1453", title: "Sofia", artist: "Clairo", seconds: 188)]
            })
            Issue.record("Expected Sofia to be left out")
        } catch {
            #expect(error.localizedDescription.contains("no stored duration"))
        }
        #expect(try Self.cachedID(track) == nil)
    }

    @Test func aFailedSearchLeavesOnlyThoseSongsOutAndIsNotRepeated() async throws {
        let gone = [Self.sofia(), TrackRecord(libraryID: "i.gone-2", title: "Amoeba", artistName: "Clairo", durationSeconds: 170)]
        let present = TrackRecord(libraryID: "i.present", title: "Bags", artistName: "Clairo", durationSeconds: 260)
        defer { for item in gone + [present] { DevicePlaybackCache.shared.set(nil, for: item.id) } }
        let presentSong = try Self.song("i.present", title: "Bags", artist: "Clairo", seconds: 260)
        var searches = 0
        do {
            try await DevicePlaybackCache.prepare(gone + [present], libraryLookup: { _ in ["i.present": presentSong] }, catalogSearch: { _ in
                searches += 1
                throw URLError(.timedOut)
            })
            Issue.record("Expected the gone songs to be left out")
        } catch {
            #expect(error.localizedDescription.contains("2 tracks could not be prepared"))
            #expect(error.localizedDescription.contains("catalog search by title and artist failed"))
        }
        #expect(searches == 1)
        #expect(try Self.cachedID(present) == "i.present")
        for track in gone { #expect(try Self.cachedID(track) == nil) }
    }

    @Test func searchesAreBoundedPerPreparation() async throws {
        let limit = DevicePlaybackCache.catalogSearchesPerPreparation
        let tracks = (0...limit).map { TrackRecord(libraryID: "i.bound-\($0)", title: "Song \($0)", artistName: "Artist", durationSeconds: 180) }
        defer { for track in tracks { DevicePlaybackCache.shared.set(nil, for: track.id) } }
        var searches = 0
        await #expect(throws: DevicePlaybackCache.PreparationError.self) {
            try await DevicePlaybackCache.prepare(tracks, libraryLookup: { _ in [:] }, catalogSearch: { _ in
                searches += 1
                return []
            })
        }
        #expect(searches == limit)
    }

    @Test func aTrackWithAStoredCatalogIDUsesTheCatalogIDNotTheSearch() async throws {
        let track = TrackRecord(catalogID: "1453", libraryID: "i.gone", title: "Sofia", artistName: "Clairo", durationSeconds: 188)
        defer { DevicePlaybackCache.shared.set(nil, for: track.id) }
        var catalogRequests: [[String]] = []
        try await DevicePlaybackCache.prepare([track], libraryLookup: { _ in [:] }, catalogLookup: { ids in
            catalogRequests.append(ids)
            return ["1453": try Self.song("1453", title: "Sofia", artist: "Clairo", seconds: 188)]
        }, catalogSearch: { _ in
            Issue.record("searched although the track has a catalog ID"); return []
        })
        #expect(catalogRequests == [["1453"]])
        #expect(try Self.cachedID(track) == "1453")
    }

    @Test func aFailedLibraryRequestDoesNotSearch() async throws {
        let track = Self.sofia()
        defer { DevicePlaybackCache.shared.set(nil, for: track.id) }
        await #expect(throws: DevicePlaybackCache.PreparationError.self) {
            try await DevicePlaybackCache.prepare([track], libraryLookup: { _ in throw URLError(.notConnectedToInternet) }, catalogSearch: { _ in
                Issue.record("searched after a failed library request"); return []
            })
        }
    }

    // MARK: - The strict rule

    @Test func strictMatchNeedsPlayableTitleArtistAndDuration() throws {
        func match(_ songs: [Song], duration: Double? = 188) -> String {
            switch AppleMusicSongLookup.strictCatalogMatch(title: "Sofia", artist: "Clairo", durationSeconds: duration, in: songs) {
            case .unique(let song): song.id.rawValue
            case .ambiguous(let count): "ambiguous \(count)"
            case .none: "none"
            }
        }
        #expect(try match([Self.song("1", title: "Sofía", artist: "CLAIRO", seconds: 186)]) == "1")
        #expect(try match([Self.song("1", title: "Sofia", artist: "Clairo", seconds: 188, playable: false)]) == "none")
        #expect(try match([Self.song("1", title: "Sofia", artist: "Clairo", seconds: nil)]) == "none")
        #expect(try match([Self.song("1", title: "Sofia Remix", artist: "Clairo", seconds: 188)]) == "none")
        #expect(try match([Self.song("1", title: "Sofia", artist: "Clairo & Friends", seconds: 188)]) == "none")
        #expect(try match([Self.song("1", title: "Sofia", artist: "Clairo", seconds: 188)], duration: nil) == "none")
        // The same song listed twice is one match.
        let once = try Self.song("1", title: "Sofia", artist: "Clairo", seconds: 188)
        #expect(match([once, once]) == "1")
        #expect(try match([once, Self.song("2", title: "Sofia", artist: "Clairo", seconds: 189)]) == "ambiguous 2")
    }

    @Test func searchAsksForSongsAndDecodesThem() async throws {
        var requested: URL?
        let songs = try await AppleMusicSongLookup.catalogSearchSongs(term: "Sofia Clairo", storefront: "gb") { url in
            requested = url
            let song: [String: Any] = ["id": "1453", "type": "songs", "attributes": [
                "name": "Sofia", "artistName": "Clairo", "albumName": "Immunity", "genreNames": [],
                "durationInMillis": 188_000, "playParams": ["id": "1453", "kind": "song"]]]
            return try JSONSerialization.data(withJSONObject: ["results": ["songs": ["data": [song]]]])
        }
        let url = try #require(requested)
        #expect(url.path == "/v1/catalog/gb/search")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "term", value: "Sofia Clairo")))
        #expect(query.contains(URLQueryItem(name: "types", value: "songs")))
        #expect(query.contains(URLQueryItem(name: "limit", value: "25")))
        #expect(songs.map(\.id.rawValue) == ["1453"])
        #expect(songs.first?.playParameters != nil)

        let empty = try await AppleMusicSongLookup.catalogSearchSongs(term: "x", storefront: "gb") { _ in
            Data(#"{"results":{}}"#.utf8)
        }
        #expect(empty.isEmpty)
    }

    // MARK: - Through a start

    /// Song 1 is library-only and its library ID is gone.
    static func fixtureWithGoneLibraryOnlySong(
        search: @escaping @MainActor (String) async throws -> [Song]
    ) throws -> PlaybackFixture {
        let fixture = try PlaybackFixture(preparePlaybackTracks: { records, refreshing in
            try await DevicePlaybackCache.prepare(records, refreshing: refreshing, libraryLookup: { _ in [:] }, catalogLookup: { _ in
                Issue.record("catalog ID lookup without a catalog ID"); return [:]
            }, catalogSearch: search)
        })
        let gone = fixture.tracks[1]
        gone.catalogID = nil
        DevicePlaybackCache.shared.set(nil, for: gone.id)
        try fixture.context.save()
        return fixture
    }

    @Test func aUniqueMatchIsQueuedAndAttributedToTheRightTrack() async throws {
        let fixture = try Self.fixtureWithGoneLibraryOnlySong { _ in
            [try Self.song("search-1", title: "Song 1", artist: "Artist 1", seconds: 181)]
        }
        defer { fixture.cleanUp() }
        let gone = fixture.tracks[1]
        // A documented identity takes no IDs from the cache, so the queued
        // catalog ID must come from the queued track itself.
        gone.hasDocumentedIdentity = true
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: gone,
                                              settings: fixture.settings, context: fixture.context)

        #expect(fixture.player.submittedTitles == [["Song 0", "Song 1", "Song 2"]])
        #expect(fixture.player.currentEntry?.item?.identifiers == ["search-1"])
        let member = try #require(fixture.controller.currentMember)
        #expect(member.localTrackID == gone.id.uuidString)
        #expect(member.musicItemIDs.contains("search-1"))
        #expect(fixture.controller.intent?.members.first { $0.localTrackID == gone.id.uuidString }?.musicItemIDs.contains("search-1") == true)
        #expect(gone.catalogID == nil)
        #expect(gone.libraryID == "i.lib-1")
        #expect(gone.confirmedAliases.isEmpty)
    }

    @Test func aFailedSearchLeavesOnlyThatSongOutOfTheQueue() async throws {
        let fixture = try Self.fixtureWithGoneLibraryOnlySong { _ in throw URLError(.timedOut) }
        defer { fixture.cleanUp() }
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[0],
                                              settings: fixture.settings, context: fixture.context)
        #expect(fixture.player.submittedTitles == [["Song 0", "Song 2"]])
        #expect(fixture.controller.currentMember?.localTrackID == fixture.tracks[0].id.uuidString)
    }

    @Test func anAmbiguousSearchLeavesOnlyThatSongOutOfTheQueue() async throws {
        let fixture = try Self.fixtureWithGoneLibraryOnlySong { _ in [
            try Self.song("search-1", title: "Song 1", artist: "Artist 1", seconds: 180),
            try Self.song("search-2", title: "Song 1", artist: "Artist 1", seconds: 181)
        ] }
        defer { fixture.cleanUp() }
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[0],
                                              settings: fixture.settings, context: fixture.context)
        #expect(fixture.player.submittedTitles == [["Song 0", "Song 2"]])
    }
}
