import Foundation
@preconcurrency import MusicKit
import SwiftData
import Synchronization
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
    static func song(
        _ id: String, title: String, artist: String, seconds: Double?, playable: Bool = true, album: String = "Album", isrc: String? = nil
    ) throws -> Song {
        var attributes: [String: Any] = ["name": title, "artistName": artist, "albumName": album, "genreNames": []]
        if let seconds { attributes["durationInMillis"] = Int(seconds * 1000) }
        if let isrc { attributes["isrc"] = isrc }
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

    /// Empties everything this suite may write for these tracks.
    static func forget(_ tracks: [TrackRecord]) {
        for track in tracks {
            DevicePlaybackCache.shared.set(nil, for: track.id)
            DevicePlaybackCache.shared.setCatalogSearchMatch(nil, for: track.id)
            DevicePlaybackCache.shared.setCatalogSearchMiss(nil, for: track.id)
        }
    }

    // MARK: - Preparation

    @Test func aUniqueMatchIsPreparedOnThisDeviceOnly() async throws {
        let track = Self.sofia()
        let updatedAt = track.updatedAt
        defer { Self.forget([track]) }
        var terms: [String] = []
        let search: (String, String) async throws -> [Song] = { term, _ in
            terms.append(term)
            return [
                try Self.song("100", title: "Sofia (Live)", artist: "Clairo", seconds: 188),
                try Self.song("101", title: "Sofia", artist: "Someone Else", seconds: 188),
                try Self.song("1453", title: "SOFIA", artist: " clairo ", seconds: 189.5)
            ]
        }

        try await DevicePlaybackCache.prepare([track], libraryLookup: { _ in [:] }, catalogLookup: { _ in
            Issue.record("catalog ID lookup without a catalog ID"); return [:]
        }, storefront: { "gb" }, catalogSearch: search)

        #expect(terms == ["Sofia Clairo"])
        #expect(try Self.cachedID(track) == "1453")
        #expect(DevicePlaybackCache.shared.catalogSearchMatch(for: track.id) == .init(libraryID: "i.1YBmOmQIqAAPdr", catalogID: "1453"))
        // Nothing synced is written: the match is not the song's identity.
        #expect(track.catalogID == nil)
        #expect(track.libraryID == "i.1YBmOmQIqAAPdr")
        #expect(track.confirmedAliases.isEmpty)
        #expect(track.equivalentCatalogIDs.isEmpty)
        #expect(track.isrc == nil)
        #expect(track.updatedAt == updatedAt)

        // The library is asked again, so a returning song would win; while it
        // still misses, the cached match is reused without a search.
        var libraryRequests = 0
        try await DevicePlaybackCache.prepare([track], libraryLookup: { _ in
            libraryRequests += 1; return [:]
        }, storefront: { "gb" }, catalogSearch: search)
        #expect(libraryRequests == 1)
        #expect(terms.count == 1)
        #expect(try Self.cachedID(track) == "1453")
    }

    @Test func aCachedCatalogSongThatNoLongerMatchesIsSearchedAgain() async throws {
        let track = Self.sofia()
        defer { Self.forget([track]) }
        DevicePlaybackCache.shared.set(try PlaybackFixture.encodedTrack(id: "999", title: "Bags", artist: "Clairo"), for: track.id)
        var searches = 0
        try await DevicePlaybackCache.prepare([track], libraryLookup: { _ in [:] }, storefront: { "gb" }, catalogSearch: { _, _ in
            searches += 1
            return [try Self.song("1453", title: "Sofia", artist: "Clairo", seconds: 188)]
        })
        #expect(searches == 1)
        #expect(try Self.cachedID(track) == "1453")
    }

    /// Review finding 3: a cached catalog copy is reused for a library-only
    /// record only when this device's search wrote it (the marker names it)
    /// and it still meets the strict rule. It is never current, so the
    /// library is always asked first.
    @Test(arguments: [
        ("1453", "Sofia", 188_000, 188.0, false, "i.1YBmOmQIqAAPdr", "1453", true),
        ("1453", "Bags", 188_000, 188.0, false, "i.1YBmOmQIqAAPdr", "1453", false),     // another title
        ("1453", "Sofia", 191_000, 188.0, false, "i.1YBmOmQIqAAPdr", "1453", false),    // duration off by 3 s
        ("1453", "Sofia", 188_000, nil, false, "i.1YBmOmQIqAAPdr", "1453", false),      // no stored duration
        ("1453", "Sofia", 188_000, .infinity, false, "i.1YBmOmQIqAAPdr", "1453", false), // non-finite duration
        ("1453", "Sofia", 188_000, 188.0, true, "i.1YBmOmQIqAAPdr", "1453", false),     // the record now has a catalog ID
        ("1453", "Sofia", 188_000, 188.0, false, "i.other", "1453", false),             // marker for another library ID
        ("1453", "Sofia", 188_000, 188.0, false, "i.1YBmOmQIqAAPdr", "2000", false),    // marker for another catalog song
        ("1453", "Sofia", 188_000, 188.0, false, nil, nil, false)                       // no marker: copied by a merge, say
    ] as [(String, String, Int, Double?, Bool, String?, String?, Bool)])
    func aCachedSearchMatchIsReusedOnlyWithItsMarker(
        cachedID: String, title: String, millis: Int, stored: Double?, hasCatalogID: Bool,
        markerLibraryID: String?, markerCatalogID: String?, reused: Bool
    ) throws {
        let track = Self.sofia(duration: stored)
        if hasCatalogID { track.catalogID = "777" }
        defer { Self.forget([track]) }
        DevicePlaybackCache.shared.set(try PlaybackFixture.encodedTrack(id: cachedID, title: title, artist: "Clairo", durationMillis: millis), for: track.id)
        if let markerLibraryID, let markerCatalogID {
            DevicePlaybackCache.shared.setCatalogSearchMatch(.init(libraryID: markerLibraryID, catalogID: markerCatalogID), for: track.id)
        }
        #expect((DevicePlaybackCache.reusableSearchMatch(for: track) != nil) == reused)
        #expect(!DevicePlaybackCache.hasCurrentData(for: track))
    }

    /// Review finding 3: a song that comes back to the library plays from the
    /// library, not from the streaming catalog copy a search found.
    @Test func aLibrarySongThatComesBackWinsOverTheSearchMatch() async throws {
        let track = Self.sofia()
        defer { Self.forget([track]) }
        var searches = 0
        let search: (String, String) async throws -> [Song] = { _, _ in
            searches += 1
            return [try Self.song("1453", title: "Sofia", artist: "Clairo", seconds: 188)]
        }
        try await DevicePlaybackCache.prepare([track], libraryLookup: { _ in [:] }, storefront: { "gb" }, catalogSearch: search)
        #expect(try Self.cachedID(track) == "1453")

        let returned = try Self.song("i.1YBmOmQIqAAPdr", title: "Sofia", artist: "Clairo", seconds: 188)
        try await DevicePlaybackCache.prepare([track], libraryLookup: { ids in
            #expect(ids == ["i.1YBmOmQIqAAPdr"])
            return ["i.1YBmOmQIqAAPdr": returned]
        }, storefront: { "gb" }, catalogSearch: search)
        #expect(try Self.cachedID(track) == "i.1YBmOmQIqAAPdr")
        #expect(searches == 1)
    }

    /// When the library cannot be asked (offline in the car), the cached
    /// search match is kept, so it is still queued from the cache.
    @Test func aFailedLibraryRequestKeepsTheCachedSearchMatch() async throws {
        let track = Self.sofia()
        defer { Self.forget([track]) }
        try await DevicePlaybackCache.prepare([track], libraryLookup: { _ in [:] }, storefront: { "gb" }, catalogSearch: { _, _ in
            [try Self.song("1453", title: "Sofia", artist: "Clairo", seconds: 188)]
        })
        await #expect(throws: DevicePlaybackCache.PreparationError.self) {
            try await DevicePlaybackCache.prepare([track], libraryLookup: { _ in throw URLError(.notConnectedToInternet) },
                                                  storefront: { "gb" }, catalogSearch: { _, _ in
                Issue.record("searched after a failed library request"); return []
            })
        }
        #expect(try Self.cachedID(track) == "1453")
    }

    /// Review finding 3: a catalog payload this device's search did not
    /// write (a merge's copy, say) is not treated as a match: the library is
    /// asked, and the song is searched for.
    @Test func aMergeCopiedCatalogPayloadIsNotTreatedAsCurrent() async throws {
        let track = Self.sofia()
        defer { Self.forget([track]) }
        DevicePlaybackCache.shared.set(try PlaybackFixture.encodedTrack(id: "1453", title: "Sofia", artist: "Clairo", durationMillis: 188_000), for: track.id)
        var libraryRequests = 0, searches = 0
        try await DevicePlaybackCache.prepare([track], libraryLookup: { _ in
            libraryRequests += 1; return [:]
        }, storefront: { "gb" }, catalogSearch: { _, _ in
            searches += 1
            return [try Self.song("1454", title: "Sofia", artist: "Clairo", seconds: 188)]
        })
        #expect(libraryRequests == 1)
        #expect(searches == 1)
        #expect(try Self.cachedID(track) == "1454")
    }

    @Test func twoMatchesLeaveTheSongOutAndTheRestPrepared() async throws {
        let track = Self.sofia()
        let present = TrackRecord(libraryID: "i.present", title: "Bags", artistName: "Clairo", durationSeconds: 260)
        defer { Self.forget([track, present]) }
        let presentSong = try Self.song("i.present", title: "Bags", artist: "Clairo", seconds: 260)
        do {
            try await DevicePlaybackCache.prepare([track, present], libraryLookup: { _ in ["i.present": presentSong] }, storefront: { "gb" }, catalogSearch: { _, _ in [
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
        defer { Self.forget([track]) }
        await #expect(throws: DevicePlaybackCache.PreparationError.self) {
            try await DevicePlaybackCache.prepare([track], libraryLookup: { _ in [:] }, storefront: { "gb" }, catalogSearch: { _, _ in
                [try Self.song("1453", title: "Sofia", artist: "Clairo", seconds: seconds)]
            })
        }
        #expect(try Self.cachedID(track) == nil)
    }

    /// Review findings 2 and 7: a track the strict rule can never match is
    /// left out without a storefront lookup or a search.
    @Test(arguments: [
        ("Sofia", "Clairo", nil, "no stored duration"),
        ("Sofia", "Clairo", .nan, "no stored duration"),
        ("Sofia", "Clairo", .infinity, "no stored duration"),
        ("  ", "Clairo", 188, "no title or artist"),
        ("Sofia", "", 188, "no title or artist")
    ] as [(String, String, Double?, String)])
    func aTrackTheRuleCannotMatchIsNotSearched(title: String, artist: String, duration: Double?, reason: String) async throws {
        let track = TrackRecord(libraryID: "i.unmatchable", title: title, artistName: artist, durationSeconds: duration)
        defer { Self.forget([track]) }
        do {
            try await DevicePlaybackCache.prepare([track], libraryLookup: { _ in [:] }, storefront: {
                Issue.record("storefront looked up"); return "gb"
            }, catalogSearch: { _, _ in
                Issue.record("searched"); return [try Self.song("1453", title: title, artist: artist, seconds: 188)]
            })
            Issue.record("Expected the track to be left out")
        } catch {
            #expect(error.localizedDescription.contains(reason))
        }
        #expect(try Self.cachedID(track) == nil)
    }

    /// Review finding 2: a search with no unique match is remembered on this
    /// device, so the next start does not wait on it again.
    @Test(arguments: ["none", "ambiguous"])
    func aSearchWithNoUniqueMatchIsNotRepeatedOnTheNextStart(outcome: String) async throws {
        let track = Self.sofia()
        defer { Self.forget([track]) }
        var searches = 0, storefronts = 0
        let search: (String, String) async throws -> [Song] = { _, _ in
            searches += 1
            return outcome == "none" ? [] : [
                try Self.song("1453", title: "Sofia", artist: "Clairo", seconds: 188),
                try Self.song("1454", title: "Sofia", artist: "Clairo", seconds: 188)
            ]
        }
        for _ in 0..<2 {
            await #expect(throws: DevicePlaybackCache.PreparationError.self) {
                try await DevicePlaybackCache.prepare([track], libraryLookup: { _ in [:] }, storefront: {
                    storefronts += 1; return "gb"
                }, catalogSearch: search)
            }
        }
        #expect(searches == 1)
        #expect(storefronts == 1)
        let miss = try #require(DevicePlaybackCache.shared.catalogSearchMiss(for: track.id))
        #expect(miss.libraryID == "i.1YBmOmQIqAAPdr")
        #expect(miss.durationSeconds == 188)
    }

    /// The remembered miss expires after a day, and no longer applies once
    /// the track's title, artist or duration changes.
    @Test(arguments: [
        (-25.0 * 3600, "Sofia", 188.0, true),   // expired
        (-23.0 * 3600, "Sofia", 188.0, false),  // still remembered
        (3600.0, "Sofia", 188.0, true),         // from the future: clock changed
        (-60.0, "Sofia 2", 188.0, true),        // another title
        (-60.0, "Sofia", 200.0, true)           // another duration
    ] as [(Double, String, Double, Bool)])
    func aRememberedMissAppliesOnlyWhileItStillDescribesTheTrack(age: TimeInterval, title: String, duration: Double, searches expected: Bool) async throws {
        let track = TrackRecord(libraryID: "i.1YBmOmQIqAAPdr", title: title, artistName: "Clairo", durationSeconds: duration)
        defer { Self.forget([track]) }
        let key = try #require(PlaybackAttribution.metadataKey(title: "Sofia", artist: "Clairo"))
        DevicePlaybackCache.shared.setCatalogSearchMiss(
            .init(libraryID: "i.1YBmOmQIqAAPdr", metadataKey: key, durationSeconds: 188, searchedAt: Date.now.addingTimeInterval(age)), for: track.id
        )
        var searches = 0
        await #expect(throws: DevicePlaybackCache.PreparationError.self) {
            try await DevicePlaybackCache.prepare([track], libraryLookup: { _ in [:] }, storefront: { "gb" }, catalogSearch: { _, _ in
                searches += 1; return []
            })
        }
        #expect((searches == 1) == expected)
    }

    /// Review finding 4: the storefront is looked up at most once per
    /// preparation, and the searches are skipped when it fails.
    @Test func theStorefrontIsLookedUpOncePerPreparation() async throws {
        let tracks = (0..<3).map { TrackRecord(libraryID: "i.store-\($0)", title: "Song \($0)", artistName: "Artist", durationSeconds: 180) }
        defer { Self.forget(tracks) }
        var storefronts = 0, storefrontsSeen: [String] = []
        await #expect(throws: DevicePlaybackCache.PreparationError.self) {
            try await DevicePlaybackCache.prepare(tracks, libraryLookup: { _ in [:] }, storefront: {
                storefronts += 1; return "gb"
            }, catalogSearch: { _, storefront in
                storefrontsSeen.append(storefront); return []
            })
        }
        #expect(storefronts == 1)
        #expect(storefrontsSeen == ["gb", "gb", "gb"])
    }

    @Test func aFailedStorefrontLookupSkipsTheSearches() async throws {
        let gone = (0..<3).map { TrackRecord(libraryID: "i.store-\($0)", title: "Song \($0)", artistName: "Artist", durationSeconds: 180) }
        let present = TrackRecord(libraryID: "i.present", title: "Bags", artistName: "Clairo", durationSeconds: 260)
        defer { Self.forget(gone + [present]) }
        let presentSong = try Self.song("i.present", title: "Bags", artist: "Clairo", seconds: 260)
        var storefronts = 0
        do {
            try await DevicePlaybackCache.prepare(gone + [present], libraryLookup: { _ in ["i.present": presentSong] }, storefront: {
                storefronts += 1; throw AppleMusicSongLookup.TimedOut(what: "The Apple Music storefront lookup")
            }, catalogSearch: { _, _ in
                Issue.record("searched without a storefront"); return []
            })
            Issue.record("Expected the gone songs to be left out")
        } catch {
            #expect(error.localizedDescription.contains("3 tracks could not be prepared"))
            #expect(error.localizedDescription.contains("did not answer in time"))
        }
        #expect(storefronts == 1)
        #expect(try Self.cachedID(present) == "i.present")
        // A failure is not a remembered miss: the next start may search.
        for track in gone { #expect(DevicePlaybackCache.shared.catalogSearchMiss(for: track.id) == nil) }
    }

    /// The storefront wait ends at the timeout even if the lookup never does.
    @Test func aBoundedLookupEndsAtItsTimeout() async throws {
        let parked = Mutex<CheckedContinuation<Void, Never>?>(nil)
        await #expect(throws: AppleMusicSongLookup.TimedOut.self) {
            _ = try await AppleMusicSongLookup.bounded(by: .zero, what: "A hung lookup") { () async throws -> String in
                // Ignores cancellation, like a wedged service.
                await withCheckedContinuation { continuation in parked.withLock { $0 = continuation } }
                return "late"
            }
        }
        // Let the parked lookup end, so the test leaks nothing.
        while parked.withLock({ $0 == nil }) { await Task.yield() }
        parked.withLock { $0.take() }?.resume()
        let answer = try await AppleMusicSongLookup.bounded(by: .seconds(60), what: "A lookup") { "gb" }
        #expect(answer == "gb")
    }

    @Test func aFailedSearchLeavesOnlyThoseSongsOutAndIsNotRepeated() async throws {
        let gone = [Self.sofia(), TrackRecord(libraryID: "i.gone-2", title: "Amoeba", artistName: "Clairo", durationSeconds: 170)]
        let present = TrackRecord(libraryID: "i.present", title: "Bags", artistName: "Clairo", durationSeconds: 260)
        defer { Self.forget(gone + [present]) }
        let presentSong = try Self.song("i.present", title: "Bags", artist: "Clairo", seconds: 260)
        var searches = 0
        do {
            try await DevicePlaybackCache.prepare(gone + [present], libraryLookup: { _ in ["i.present": presentSong] }, storefront: { "gb" }, catalogSearch: { _, _ in
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
        defer { Self.forget(tracks) }
        var searches = 0
        await #expect(throws: DevicePlaybackCache.PreparationError.self) {
            try await DevicePlaybackCache.prepare(tracks, libraryLookup: { _ in [:] }, storefront: { "gb" }, catalogSearch: { _, _ in
                searches += 1
                return []
            })
        }
        #expect(searches == limit)
    }

    @Test func aTrackWithAStoredCatalogIDUsesTheCatalogIDNotTheSearch() async throws {
        let track = TrackRecord(catalogID: "1453", libraryID: "i.gone", title: "Sofia", artistName: "Clairo", durationSeconds: 188)
        defer { Self.forget([track]) }
        var catalogRequests: [[String]] = []
        try await DevicePlaybackCache.prepare([track], libraryLookup: { _ in [:] }, catalogLookup: { ids in
            catalogRequests.append(ids)
            return ["1453": try Self.song("1453", title: "Sofia", artist: "Clairo", seconds: 188)]
        }, storefront: { "gb" }, catalogSearch: { _, _ in
            Issue.record("searched although the track has a catalog ID"); return []
        })
        #expect(catalogRequests == [["1453"]])
        #expect(try Self.cachedID(track) == "1453")
    }

    @Test func aFailedLibraryRequestDoesNotSearch() async throws {
        let track = Self.sofia()
        defer { Self.forget([track]) }
        await #expect(throws: DevicePlaybackCache.PreparationError.self) {
            try await DevicePlaybackCache.prepare([track], libraryLookup: { _ in throw URLError(.notConnectedToInternet) }, storefront: { "gb" }, catalogSearch: { _, _ in
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
        // Review finding 7: a non-finite stored duration never matches.
        #expect(match([once], duration: .infinity) == "none")
        #expect(match([once], duration: .nan) == "none")
    }

    /// Review finding 6: copies of one recording (same ISRC) on a single and
    /// its album are one song; different or missing ISRCs stay ambiguous.
    @Test func copiesOfOneRecordingAreOneMatch() throws {
        func match(_ songs: [Song], album: String? = "Immunity") -> String {
            switch AppleMusicSongLookup.strictCatalogMatch(title: "Sofia", artist: "Clairo", durationSeconds: 188, albumTitle: album, in: songs) {
            case .unique(let song): song.id.rawValue
            case .ambiguous(let count): "ambiguous \(count)"
            case .none: "none"
            }
        }
        let single = try Self.song("1000", title: "Sofia", artist: "Clairo", seconds: 188, album: "Sofia - Single", isrc: "USAT21901234")
        let album = try Self.song("1453", title: "Sofia", artist: "Clairo", seconds: 188, album: "Immunity", isrc: "USAT21901234")
        let deluxe = try Self.song("999", title: "Sofia", artist: "Clairo", seconds: 187.5, album: "Immunity (Deluxe)", isrc: "usat21901234")
        // The copy on the track's album, whatever the order.
        #expect(match([single, album, deluxe]) == "1453")
        #expect(match([deluxe, album, single]) == "1453")
        #expect(match([single, album], album: "IMMUNITY") == "1453")
        // No album copy: the lowest ID, compared as a number.
        #expect(match([single, album, deluxe], album: "Other") == "999")
        #expect(match([single, album, deluxe], album: nil) == "999")
        // Different recordings, or one without an ISRC, stay ambiguous.
        let other = try Self.song("1454", title: "Sofia", artist: "Clairo", seconds: 188, album: "Immunity", isrc: "USAT21909999")
        let noCode = try Self.song("1455", title: "Sofia", artist: "Clairo", seconds: 188, album: "Immunity")
        #expect(match([single, other]) == "ambiguous 2")
        #expect(match([single, album, noCode]) == "ambiguous 3")
        #expect(match([try Self.song("1", title: "Sofia", artist: "Clairo", seconds: 188), try Self.song("2", title: "Sofia", artist: "Clairo", seconds: 188)]) == "ambiguous 2")
    }

    /// Through a preparation: the album copy is prepared.
    @Test func aSingleAndItsAlbumCopyPrepareTheAlbumCopy() async throws {
        let track = TrackRecord(libraryID: "i.1YBmOmQIqAAPdr", title: "Sofia", artistName: "Clairo", albumTitle: "Immunity", durationSeconds: 188)
        defer { Self.forget([track]) }
        try await DevicePlaybackCache.prepare([track], libraryLookup: { _ in [:] }, storefront: { "gb" }, catalogSearch: { _, _ in [
            try Self.song("1000", title: "Sofia", artist: "Clairo", seconds: 188, album: "Sofia - Single", isrc: "USAT21901234"),
            try Self.song("1453", title: "Sofia", artist: "Clairo", seconds: 188, album: "Immunity", isrc: "USAT21901234")
        ] })
        #expect(try Self.cachedID(track) == "1453")
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
        search: @escaping @MainActor (String, String) async throws -> [Song]
    ) throws -> PlaybackFixture {
        let fixture = try PlaybackFixture(preparePlaybackTracks: { records, refreshing in
            try await DevicePlaybackCache.prepare(records, refreshing: refreshing, libraryLookup: { _ in [:] }, catalogLookup: { _ in
                Issue.record("catalog ID lookup without a catalog ID"); return [:]
            }, storefront: { "gb" }, catalogSearch: search)
        })
        let gone = fixture.tracks[1]
        gone.catalogID = nil
        DevicePlaybackCache.shared.set(nil, for: gone.id)
        try fixture.context.save()
        return fixture
    }

    @Test func aUniqueMatchIsQueuedAndAttributedToTheRightTrack() async throws {
        let fixture = try Self.fixtureWithGoneLibraryOnlySong { _, _ in
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
        let fixture = try Self.fixtureWithGoneLibraryOnlySong { _, _ in throw URLError(.timedOut) }
        defer { fixture.cleanUp() }
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[0],
                                              settings: fixture.settings, context: fixture.context)
        #expect(fixture.player.submittedTitles == [["Song 0", "Song 2"]])
        #expect(fixture.controller.currentMember?.localTrackID == fixture.tracks[0].id.uuidString)
    }

    @Test func anAmbiguousSearchLeavesOnlyThatSongOutOfTheQueue() async throws {
        let fixture = try Self.fixtureWithGoneLibraryOnlySong { _, _ in [
            try Self.song("search-1", title: "Song 1", artist: "Artist 1", seconds: 180),
            try Self.song("search-2", title: "Song 1", artist: "Artist 1", seconds: 181)
        ] }
        defer { fixture.cleanUp() }
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[0],
                                              settings: fixture.settings, context: fixture.context)
        #expect(fixture.player.submittedTitles == [["Song 0", "Song 2"]])
    }
}
