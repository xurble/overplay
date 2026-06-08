import Foundation
@preconcurrency import MusicKit

@MainActor
protocol MusicLibraryPlaylistFetching {
    func fetchAllPlaylists(pageLimit: Int) async throws -> [Playlist]
}

@MainActor
struct MusicKitLibraryPlaylistFetcher: MusicLibraryPlaylistFetching {
    func fetchAllPlaylists(pageLimit: Int = 100) async throws -> [Playlist] {
        try await MusicLibraryPagination.collect {
            var request = MusicLibraryRequest<Playlist>()
            request.limit = pageLimit
            request.sort(by: \.name, ascending: true)

            let collection = try await request.response().items
            return page(from: collection)
        } nextPage: { collection in
            guard let nextCollection = try await collection.nextBatch(limit: pageLimit) else {
                return nil
            }

            return page(from: nextCollection)
        }
    }

    private func page(
        from collection: MusicItemCollection<Playlist>
    ) -> MusicLibraryPage<Playlist, MusicItemCollection<Playlist>> {
        MusicLibraryPage(
            items: Array(collection),
            nextCursor: collection.hasNextBatch ? collection : nil
        )
    }
}
