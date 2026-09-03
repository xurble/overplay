import Foundation
import MusicKit
import Testing
@testable import Overplay

@MainActor
@Suite("Apple Music playlist source sync")
struct AppleMusicPlaylistSourceSyncTests {
    @MainActor
    private final class StubFetcher: MusicLibraryPlaylistFetching {
        var playlists: [Playlist] = []
        private(set) var requestedPageLimits: [Int] = []

        func fetchAllPlaylists(pageLimit: Int) async throws -> [Playlist] {
            requestedPageLimits.append(pageLimit)
            return playlists
        }

        func fetchPlaylist(id playlistID: String) async throws -> Playlist? {
            playlists.first { $0.id.rawValue == playlistID }
        }
    }

    /// MusicKit's `Playlist` is `Codable`, so a library playlist can be built
    /// from the Apple Music API shape without touching the device.
    private static func makePlaylist(id: String, name: String) throws -> Playlist {
        let json = """
        {
          "id": "\(id)",
          "type": "library-playlists",
          "href": "/v1/me/library/playlists/\(id)",
          "attributes": { "name": "\(name)", "canEdit": true, "hasCatalog": false }
        }
        """
        return try JSONDecoder().decode(Playlist.self, from: Data(json.utf8))
    }

    @Test("library playlists are fetched without any SwiftData context")
    func libraryPlaylistsAreFetchedWithoutAnySwiftDataContext() async throws {
        // Regression guard for the vestigial `in context:` parameter this
        // used to take: it was never read, and the callers that had no
        // context built a throwaway in-memory ModelContainer with `try!`
        // purely to supply it.
        let fetcher = StubFetcher()
        fetcher.playlists = [
            try Self.makePlaylist(id: "z", name: "Z Road"),
            try Self.makePlaylist(id: "a", name: "A Quiet Library")
        ]
        let sync = AppleMusicPlaylistSourceSync(playlistFetcher: fetcher)

        let links = try await sync.fetchLibraryPlaylists()

        #expect(links.map(\.id) == ["a", "z"])
        #expect(links.allSatisfy { $0.source == .appleMusic })
        #expect(fetcher.requestedPageLimits == [100])
    }

    @Test("library playlists come back in display order")
    func libraryPlaylistsComeBackInDisplayOrder() async throws {
        let fetcher = StubFetcher()
        fetcher.playlists = [
            try Self.makePlaylist(id: "z", name: "Z Road"),
            try Self.makePlaylist(id: "overplay", name: "Overplay"),
            try Self.makePlaylist(id: "a", name: "A Quiet Library")
        ]
        let sync = AppleMusicPlaylistSourceSync(playlistFetcher: fetcher)

        let links = try await sync.fetchLibraryPlaylists()

        #expect(links.map(\.id) == ["overplay", "a", "z"])
    }

    @Test("an empty library returns no links")
    func anEmptyLibraryReturnsNoLinks() async throws {
        let sync = AppleMusicPlaylistSourceSync(playlistFetcher: StubFetcher())

        #expect(try await sync.fetchLibraryPlaylists().isEmpty)
    }

    @Test("a fetch failure propagates instead of crashing")
    func aFetchFailurePropagatesInsteadOfCrashing() async throws {
        // The removed helper used `try!`, so a SwiftData failure was a hard
        // crash in the playlist picker. Every failure on this path must now
        // surface as a thrown error the caller can report.
        struct FailingFetcher: MusicLibraryPlaylistFetching {
            struct Failure: Error {}

            func fetchAllPlaylists(pageLimit: Int) async throws -> [Playlist] {
                throw Failure()
            }

            func fetchPlaylist(id playlistID: String) async throws -> Playlist? {
                throw Failure()
            }
        }

        let sync = AppleMusicPlaylistSourceSync(playlistFetcher: FailingFetcher())

        await #expect(throws: FailingFetcher.Failure.self) {
            try await sync.fetchLibraryPlaylists()
        }
    }
}
