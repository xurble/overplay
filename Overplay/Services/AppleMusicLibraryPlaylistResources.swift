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
}
