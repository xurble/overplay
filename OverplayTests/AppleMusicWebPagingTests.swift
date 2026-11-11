import Foundation
@preconcurrency import MusicKit
import Testing
@testable import Overplay

/// Every pager asks for 100 per page on every page: Apple's `next` may drop
/// the first request's limit (PF-13), and pages then fall back to 25.
@Suite("Apple Music web paging")
@MainActor
struct AppleMusicWebPagingTests {
    private func playlist(_ id: String, next: String? = nil) -> Data {
        let tail = next.map { #","next":"\#($0)""# } ?? ""
        return Data(#"{"data":[{"id":"\#(id)","type":"library-playlists","attributes":{"name":"N"}}]\#(tail)}"#.utf8)
    }

    private func limits(_ url: URL) -> [String?] {
        (URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems ?? []).filter { $0.name == "limit" }.map(\.value)
    }

    @Test("A later playlist page asks for 100")
    func playlistsLaterPage() async throws {
        var requested: [URL] = []
        let links = try await AppleMusicLibraryPlaylistResources.fetchAll { url in
            requested.append(url)
            return requested.count == 1 ? playlist("p.one", next: "/v1/me/library/playlists?offset=100") : playlist("p.two")
        }
        #expect(links.map(\.id) == ["p.one", "p.two"])
        #expect(requested.map(\.absoluteString) == [
            "https://api.music.apple.com/v1/me/library/playlists?limit=100",
            "https://api.music.apple.com/v1/me/library/playlists?offset=100&limit=100"
        ])
    }

    @Test("A later playlist entries page asks for 100")
    func entriesLaterPage() async throws {
        var requested: [URL] = []
        _ = try await AppleMusicLibraryPlaylistResources.fetchEntries(playlistID: "p.x") { url in
            requested.append(url)
            return Data((requested.count == 1
                ? #"{"data":[{"id":"i.a","type":"library-songs"}],"next":"/v1/me/library/playlists/p.x/tracks?offset=100"}"#
                : #"{"data":[{"id":"i.b","type":"library-songs"}]}"#).utf8)
        }
        #expect(requested.count == 2)
        #expect(requested.allSatisfy { limits($0) == ["100"] })
        #expect(requested[1].query?.contains("offset=100") == true)
    }

    @Test("A later Library browser page asks for 100 and keeps its other parameters")
    func browserLaterPage() async throws {
        var requested: [URL] = []
        let songs = try await LibraryBrowser.fetchAll(Song.self, "/v1/me/library/songs?include=catalog") { url in
            requested.append(url)
            return Data((requested.count == 1
                ? #"{"data":[],"next":"/v1/me/library/songs?include=catalog&offset=100"}"#
                : #"{"data":[]}"#).utf8)
        }
        #expect(songs.isEmpty)
        #expect(requested.map(\.absoluteString) == [
            "https://api.music.apple.com/v1/me/library/songs?include=catalog&limit=100",
            "https://api.music.apple.com/v1/me/library/songs?include=catalog&offset=100&limit=100"
        ])
    }

    @Test("A next that states a limit is followed as written, in every pager")
    func existingLimitIsNotDoubled() async throws {
        var playlists: [URL] = []
        _ = try await AppleMusicLibraryPlaylistResources.fetchAll { url in
            playlists.append(url)
            return playlists.count == 1 ? playlist("p.one", next: "/v1/me/library/playlists?offset=100&limit=100") : playlist("p.two")
        }
        #expect(playlists.allSatisfy { limits($0) == ["100"] })

        var entries: [URL] = []
        _ = try await AppleMusicLibraryPlaylistResources.fetchEntries(playlistID: "p.x") { url in
            entries.append(url)
            return Data((entries.count == 1
                ? #"{"data":[{"id":"i.a","type":"library-songs"}],"next":"/v1/me/library/playlists/p.x/tracks?limit=25&offset=100"}"#
                : #"{"data":[]}"#).utf8)
        }
        #expect(limits(entries[1]) == ["25"])

        var browser: [URL] = []
        _ = try await LibraryBrowser.fetchAll(Song.self, "/v1/me/library/songs") { url in
            browser.append(url)
            return Data((browser.count == 1 ? #"{"data":[],"next":"/v1/me/library/songs?offset=100&limit=100"}"# : #"{"data":[]}"#).utf8)
        }
        #expect(browser.allSatisfy { limits($0) == ["100"] })
    }

    @Test("Percent-encoding in a next survives adding the limit")
    func encodingIsPreserved() {
        #expect(AppleMusicLibraryPlaylistResources.requestingFullPages("/v1/me/library/search?term=a%20b%26c&offset=5")
            == "/v1/me/library/search?term=a%20b%26c&offset=5&limit=100")
        #expect(AppleMusicLibraryPlaylistResources.requestingFullPages("/v1/me/library/playlists")
            == "/v1/me/library/playlists?limit=100")
    }

    @Test("Page URLs still fail closed once the limit is added", arguments: [
        "/v1/me/library/playlists",                 // Becomes the first page again: repeated.
        "/v1/me/library/songs?offset=1",            // Wrong path.
        "http://api.music.apple.com/v1/me/library/playlists?offset=1", // Wrong scheme.
        "https://example.com/v1/me/library/playlists?offset=1"         // Wrong host.
    ])
    func badNextFails(next: String) async {
        await #expect(throws: PlaylistSyncError.self) {
            _ = try await AppleMusicLibraryPlaylistResources.fetchAll { _ in playlist("p.one", next: next) }
        }
    }

    @Test("A next page repeating an earlier page's resources still fails")
    func overlappingPageFails() async {
        var requests = 0
        await #expect(throws: PlaylistSyncError.self) {
            _ = try await AppleMusicLibraryPlaylistResources.fetchAll { _ in
                requests += 1
                return playlist("p.one", next: "/v1/me/library/playlists?offset=\(requests)")
            }
        }
        #expect(requests == 2)
    }
}
