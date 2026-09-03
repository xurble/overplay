import Foundation
@preconcurrency import MusicKit

@MainActor
protocol MusicLibraryPlaylistFetching {
    func fetchAllPlaylists(pageLimit: Int) async throws -> [Playlist]

    /// Fetches one library playlist by its library ID.
    ///
    /// Resolving a known playlist does not need the whole library: this is a
    /// single filtered request instead of paging every playlist the user
    /// owns. Returns nil when no playlist carries that ID, which is the
    /// signal for the caller to fall back to name-based ID healing.
    func fetchPlaylist(id playlistID: String) async throws -> Playlist?
}

@MainActor
struct MusicKitLibraryPlaylistFetcher: MusicLibraryPlaylistFetching {
    func fetchAllPlaylists(pageLimit: Int = 100) async throws -> [Playlist] {
        try await MusicLibraryPagination.collect {
            var request = MusicLibraryRequest<Playlist>()
            request.limit = pageLimit
            request.sort(by: \.name, ascending: true)

            let collection = try await MusicKitActivityLog.shared.measure(
                .libraryPlaylistEnumeration,
                detail: "first page",
                resultMagnitude: { Double($0.count) }
            ) {
                try await request.response().items
            }
            return page(from: collection)
        } nextPage: { collection in
            let batch = try await MusicKitActivityLog.shared.measure(
                .libraryPlaylistEnumeration,
                detail: "next page",
                resultMagnitude: { $0.map { Double($0.count) } }
            ) {
                try await collection.nextBatch(limit: pageLimit)
            }
            guard let nextCollection = batch else {
                return nil
            }

            return page(from: nextCollection)
        }
    }

    func fetchPlaylist(id playlistID: String) async throws -> Playlist? {
        guard !playlistID.isEmpty else { return nil }

        var request = MusicLibraryRequest<Playlist>()
        request.filter(matching: \.id, equalTo: MusicItemID(playlistID))
        request.limit = 1

        return try await MusicKitActivityLog.shared.measure(
            .libraryPlaylistLookup,
            detail: "by id",
            resultMagnitude: { $0 == nil ? 0 : 1 }
        ) {
            try await request.response().items.first
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
