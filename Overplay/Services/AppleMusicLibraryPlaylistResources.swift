import Foundation
@preconcurrency import MusicKit

/// The picker persists web library resource IDs, never native enumeration IDs.
@MainActor
enum AppleMusicLibraryPlaylistResources {
    struct Page: Decodable {
        struct Resource: Decodable {
            struct Attributes: Decodable { var name: String }
            var id: String
            var type: String
            var attributes: Attributes
        }
        var data: [Resource]
        var next: String?
    }

    static func fetchAll(
        request: (URL) async throws -> Data = { url in
            try await MusicDataRequest(urlRequest: URLRequest(url: url)).response().data
        }
    ) async throws -> [RemotePlaylistLink] {
        var next: URL? = URL(string: "https://api.music.apple.com/v1/me/library/playlists?limit=100")
        var visited = Set<URL>()
        var identifiers = Set<String>()
        var links: [RemotePlaylistLink] = []
        while let url = next {
            guard visited.insert(url).inserted, url.scheme == "https", url.host == "api.music.apple.com",
                  url.path == "/v1/me/library/playlists" else { throw PlaylistSyncError.incompletePlaylist }
            let page = try JSONDecoder().decode(Page.self, from: await request(url))
            try Task.checkCancellation()
            guard page.next == nil || !page.data.isEmpty else { throw PlaylistSyncError.incompletePlaylist }
            for resource in page.data {
                guard resource.type == "library-playlists", !resource.id.isEmpty,
                      identifiers.insert(resource.id).inserted else { throw PlaylistSyncError.incompletePlaylist }
                links.append(RemotePlaylistLink(id: resource.id, name: resource.attributes.name, source: .appleMusic))
            }
            if let path = page.next {
                guard let url = URL(string: path, relativeTo: url)?.absoluteURL else { throw PlaylistSyncError.incompletePlaylist }
                next = url
            } else { next = nil }
        }
        return links
    }

    /// One occurrence in iCloud's copy of a library playlist. The response
    /// type establishes the domain; other types have no song reference.
    struct Entry: Decodable, Equatable {
        var id: String
        var type: String

        var reference: MusicResourceReference? {
            switch type {
            case "library-songs": .library(id)
            case "songs": .catalog(id)
            default: nil
            }
        }
    }

    /// Every entry of the playlist as iCloud holds it, independent of how far
    /// this device's library has synced. An empty playlist answers 404.
    static func fetchEntries(
        playlistID: String,
        request: (URL) async throws -> Data = { url in
            try await MusicDataRequest(urlRequest: URLRequest(url: url)).response().data
        }
    ) async throws -> [Entry] {
        struct EntryPage: Decodable { var data: [Entry]; var next: String? }
        var components = URLComponents(string: "https://api.music.apple.com")!
        components.path = "/v1/me/library/playlists/\(playlistID)/tracks"
        let path = components.path
        components.queryItems = [URLQueryItem(name: "limit", value: "100")]
        var next = components.url
        var visited = Set<URL>()
        var entries: [Entry] = []
        while let url = next {
            guard visited.insert(url).inserted, url.scheme == "https", url.host == "api.music.apple.com",
                  url.path == path else { throw PlaylistSyncError.incompletePlaylist }
            let data: Data
            do {
                data = try await request(url)
            } catch let error as MusicDataRequest.Error where error.status == 404 && entries.isEmpty {
                return []
            }
            let page = try JSONDecoder().decode(EntryPage.self, from: data)
            try Task.checkCancellation()
            guard page.next == nil || !page.data.isEmpty else { throw PlaylistSyncError.incompletePlaylist }
            entries += page.data
            if let nextPath = page.next {
                guard let url = URL(string: nextPath, relativeTo: url)?.absoluteURL else { throw PlaylistSyncError.incompletePlaylist }
                next = url
            } else { next = nil }
        }
        return entries
    }
}
